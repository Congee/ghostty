//! DEPRECATED: In-process session management is superseded by the daemon
//! architecture (src/daemon/). The daemon owns sessions in a separate process,
//! eliminating the race conditions between Surface.init and reattach that
//! plagued this approach. This module remains for backward compatibility
//! until daemon mode is the default.
//!
//! A Session represents a persistent terminal session that can survive
//! surface (window/tab) destruction. It owns the Termio (terminal IO),
//! the IO thread, and the terminal state. Sessions are heap-allocated
//! so that pointers to their internal state (e.g. &session.io.terminal)
//! remain stable across surface attach/detach cycles.
const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const termio = @import("termio.zig");
const rendererpkg = @import("renderer.zig");
const Surface = @import("Surface.zig");
const xev = @import("global.zig").xev;

const log = std.log.scoped(.session);

/// The allocator used to create this session.
alloc: Allocator,

/// A unique identifier for this session.
id: u32,

/// The terminal IO state. Owns the terminal emulator, pty, and subprocess.
io: termio.Termio,

/// The IO thread manager.
io_thread: termio.Thread,

/// The actual OS thread running the IO loop.
io_thr: std.Thread,

/// The surface currently attached to this session, if any.
attached_surface: ?*Surface = null,

/// Set to true when the child process has exited.
child_exited: bool = false,

/// The last known terminal size. Used to detect if a resize is needed
/// when reattaching to a new surface.
last_size: rendererpkg.Size,

/// User-assigned session name (e.g. "dev", "logs"). If null, the session
/// is identified by its id and command/title.
name: ?[]u8 = null,

/// The terminal title (set via OSC 0/2). Captured from Surface's set_title
/// handler so it survives surface destruction for the session picker.
/// Stored with a sentinel null terminator for safe use with C-style APIs.
title: ?[:0]u8 = null,

/// Heap-allocated thread data preserved across park/resume cycles.
/// When the IO thread parks, it moves its stack-local ThreadData here
/// so it survives thread exit. On resume, the new thread picks it up.
parked_thread_data: ?*termio.Termio.ThreadData = null,

/// Create a new heap-allocated session. The caller must eventually call
/// `destroy` to free the session.
pub fn create(
    alloc: Allocator,
    id: u32,
    io_thread: termio.Thread,
    size: rendererpkg.Size,
) !*Session {
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);

    self.* = .{
        .alloc = alloc,
        .id = id,
        .io = undefined, // Initialized by caller (Surface.init)
        .io_thread = io_thread,
        .io_thr = undefined, // Set when IO thread is spawned
        .last_size = size,
    };

    return self;
}

/// Full teardown: stop the IO thread, deinit all state, free memory.
pub fn destroy(self: *Session) void {
    // Stop the IO thread
    self.io_thread.stop.notify() catch |err|
        log.err("error notifying io thread to stop, may stall err={}", .{err});
    self.io_thr.join();

    // Clean up name and title
    if (self.name) |n| {
        self.alloc.free(n);
        self.name = null;
    }
    if (self.title) |t| {
        self.alloc.free(t);
        self.title = null;
    }

    // Clean up parked thread data if any
    if (self.parked_thread_data) |ptd| {
        ptd.deinit();
        self.alloc.destroy(ptd);
        self.parked_thread_data = null;
    }

    // Deinit in order
    self.io_thread.deinit();
    self.io.deinit();

    log.info("session destroyed id={}", .{self.id});

    const alloc = self.alloc;
    alloc.destroy(self);
}

/// Detach the session from its current surface. The IO thread and child
/// process remain alive (via park_mode), but the surface pointer is cleared.
pub fn detach(self: *Session) void {
    log.info("session detached id={}", .{self.id});
    self.attached_surface = null;
}

/// Prepare the session for reattachment: reconnect Termio pointers and
/// reinitialize the IO thread. Does NOT start the IO thread — call
/// startReattachedIO() after the renderer thread is running.
pub fn prepareReattach(self: *Session, surface: *Surface) !void {
    log.info("session preparing reattach id={} surface={x}", .{ self.id, @intFromPtr(surface) });
    self.attached_surface = surface;

    // If the child already exited, we can't reattach
    if (self.child_exited) return error.ChildExited;

    // Free parked thread data — threadReenter creates fresh state
    if (self.parked_thread_data) |ptd| {
        // Don't deinit the backend — the subprocess/pty are still alive.
        // Just free the heap allocation.
        self.alloc.destroy(ptd);
        self.parked_thread_data = null;
    }

    // Reinitialize the IO thread (new xev loop, async handles)
    self.io_thread.deinit();
    self.io_thread = try termio.Thread.init(self.alloc);

    // Reconnect Termio pointers to the new surface/renderer.
    self.io.reconnectPointers(.{
        .renderer_state = &surface.renderer_state,
        .renderer_wakeup = surface.renderer_thread.wakeup,
        .renderer_mailbox = surface.renderer_thread.mailbox,
        .surface_mailbox = .{ .surface = surface, .app = .{
            .rt_app = surface.rt_app,
            .mailbox = &surface.app.mailbox,
        } },
        .size = surface.size,
    });
}

/// Start the IO thread for a reattached session. Must be called after
/// the renderer thread is started so that renderer notifications work.
pub fn startReattachedIO(self: *Session) !void {
    // Set resume_mode so threadMain_ calls threadReenter (skips subprocess start)
    self.io_thread.resume_mode = true;

    // Use the exact same threadMain entry point as a new session.
    self.io_thr = try std.Thread.spawn(
        .{},
        termio.Thread.threadMain,
        .{ &self.io_thread, &self.io },
    );
    self.io_thr.setName("io") catch {};

    log.info("session IO resumed id={}", .{self.id});
}

/// Called by the IO thread when parking: preserve ThreadData on the heap
/// so it survives thread exit.
pub fn parkThreadData(self: *Session, data: *const termio.Termio.ThreadData) !void {
    const ptd = try self.alloc.create(termio.Termio.ThreadData);
    ptd.* = data.*;
    self.parked_thread_data = ptd;
}

/// Update the session title. Called from Surface when handling set_title.
pub fn setTitle(self: *Session, new_title: []const u8) !void {
    if (self.title) |old| self.alloc.free(old);
    self.title = try self.alloc.dupeZ(u8, new_title);
}

/// Set a user-assigned session name.
pub fn setName(self: *Session, new_name: []const u8) !void {
    if (self.name) |old| self.alloc.free(old);
    self.name = try self.alloc.dupe(u8, new_name);
}

/// Return the best display label for this session: user-assigned name,
/// then OSC title, then "shell" as fallback.
pub fn displayLabel(self: *const Session) []const u8 {
    if (self.name) |n| return n;
    if (self.title) |t| return t;
    return "shell";
}

/// Metadata about a session, suitable for display in a session picker.
pub const SessionInfo = struct {
    id: u32,
    name: ?[]const u8,
    title: ?[]const u8,
    pwd: ?[]const u8,
    command: ?[:0]const u8,
    attached: bool,
    child_exited: bool,

    /// Return the best display label for this session.
    pub fn displayLabel(self: SessionInfo) []const u8 {
        return self.name orelse
            self.title orelse
            if (self.command) |cmd| std.mem.sliceTo(cmd, 0) else
            "unnamed";
    }
};

/// Get a snapshot of session metadata for display purposes.
pub fn getInfo(self: *const Session) SessionInfo {
    // Get live pwd from terminal state
    const pwd: ?[]const u8 = blk: {
        self.io.renderer_state.mutex.lock();
        defer self.io.renderer_state.mutex.unlock();
        break :blk self.io.renderer_state.terminal.getPwd();
    };

    // Get command name from subprocess
    const command: ?[:0]const u8 = switch (self.io.backend) {
        .exec => |exec| if (exec.subprocess.args.len > 0) exec.subprocess.args[0] else null,
    };

    return .{
        .id = self.id,
        .name = self.name,
        .title = self.title,
        .pwd = pwd,
        .command = command,
        .attached = self.attached_surface != null,
        .child_exited = self.child_exited,
    };
}

// --- Tests ---

test "setTitle stores null-terminated string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We can't create a full Session (needs Termio), so test setTitle/setName
    // on a partial struct by testing the allocator behavior directly.
    var title: ?[:0]u8 = null;
    defer if (title) |t| alloc.free(t);

    title = try alloc.dupeZ(u8, "hello world");
    try testing.expectEqualStrings("hello world", title.?);
    // Verify sentinel: indexing past len should give 0
    try testing.expectEqual(@as(u8, 0), title.?[title.?.len]);
}

test "setTitle replaces old title" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var title: ?[:0]u8 = try alloc.dupeZ(u8, "first");
    defer if (title) |t| alloc.free(t);

    // Replace
    alloc.free(title.?);
    title = try alloc.dupeZ(u8, "second");
    try testing.expectEqualStrings("second", title.?);
    try testing.expectEqual(@as(u8, 0), title.?[title.?.len]);
}

test "SessionInfo displayLabel priority" {
    const testing = std.testing;

    // Name takes priority over title
    const with_name: SessionInfo = .{
        .id = 1,
        .name = "dev",
        .title = "zsh",
        .pwd = "/home",
        .command = "zsh",
        .attached = false,
        .child_exited = false,
    };
    try testing.expectEqualStrings("dev", with_name.displayLabel());

    // Title when no name
    const with_title: SessionInfo = .{
        .id = 2,
        .name = null,
        .title = "vim",
        .pwd = null,
        .command = null,
        .attached = true,
        .child_exited = false,
    };
    try testing.expectEqualStrings("vim", with_title.displayLabel());

    // Command when no name or title
    const with_cmd: SessionInfo = .{
        .id = 3,
        .name = null,
        .title = null,
        .pwd = null,
        .command = "/bin/zsh",
        .attached = false,
        .child_exited = false,
    };
    try testing.expectEqualStrings("/bin/zsh", with_cmd.displayLabel());

    // Fallback
    const empty: SessionInfo = .{
        .id = 4,
        .name = null,
        .title = null,
        .pwd = null,
        .command = null,
        .attached = false,
        .child_exited = true,
    };
    try testing.expectEqualStrings("unnamed", empty.displayLabel());
}

test "StatusBar in renderer State" {
    const renderer_state = @import("renderer.zig");
    const testing = std.testing;
    const alloc = testing.allocator;

    // Test StatusBar clone and deinit
    const sb = renderer_state.State.StatusBar{
        .left = try alloc.dupe(u8, "session:main"),
        .right = try alloc.dupe(u8, "14:32"),
    };
    defer sb.deinit(alloc);

    var clone = try sb.clone(alloc);
    defer clone.deinit(alloc);

    try testing.expectEqualStrings("session:main", clone.left);
    try testing.expectEqualStrings("14:32", clone.right);
}
