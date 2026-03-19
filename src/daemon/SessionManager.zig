//! Manages daemon-owned terminal sessions. Each session runs headlessly
//! with its own Terminal, PTY, and subprocess. The SessionManager provides
//! the session lifecycle (create, list, destroy) and serializes terminal
//! state for connected clients.
const SessionManager = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Protocol = @import("gsp");
const PtyReader = @import("PtyReader.zig");
const vt = @import("../terminal/main.zig");

const log = std.log.scoped(.session_mgr);

// Platform-specific C imports for PTY operations.
const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("util.h"); // openpty()
    }),
    .freebsd => @cImport({
        @cInclude("termios.h");
        @cInclude("libutil.h");
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("pty.h");
    }),
};

const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
const TIOCSWINSZ = if (builtin.os.tag == .macos) 2148037735 else c.TIOCSWINSZ;

extern "c" fn setsid() std.c.pid_t;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// A daemon-owned session.
pub const DaemonSession = struct {
    id: u32,
    name: []const u8,
    title: []const u8,
    pwd: []const u8,
    command: [:0]const u8,

    /// True when a client is attached.
    attached: bool = false,

    /// True when the child process has exited.
    child_exited: bool = false,

    /// Terminal dimensions.
    cols: u16,
    rows: u16,

    /// The real Ghostty terminal emulator (handles all VT sequences,
    /// alternate screen, cursor save/restore, scrollback, etc.).
    terminal: vt.Terminal,

    /// Wire-format cell cache, populated by snapshotCells() after feeding
    /// PTY data to the terminal. Flat array: cells[row * cols + col].
    cells: []Protocol.WireCell,

    /// Cursor snapshot (from terminal, updated by snapshotCells).
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_visible: bool = true,

    /// Dirty row tracking — set when snapshotCells detects changes.
    dirty_rows: std.DynamicBitSet,

    /// The PTY file descriptor (master side).
    pty_fd: ?posix.fd_t = null,

    /// The child process PID.
    child_pid: ?std.c.pid_t = null,

    /// Allocator for this session's owned memory.
    alloc: Allocator,

    pub fn deinit(self: *DaemonSession) void {
        // Kill child if still running
        if (self.child_pid) |pid| {
            _ = std.c.kill(pid, std.c.SIG.HUP);
            // Reap to avoid zombies
            _ = std.c.waitpid(pid, null, std.c.W.NOHANG);
        }
        if (self.pty_fd) |fd| posix.close(fd);
        // All strings are heap-allocated (via dupe/dupeZ), always free.
        self.alloc.free(self.name);
        self.alloc.free(self.title);
        self.alloc.free(self.pwd);
        self.alloc.free(self.command);
        self.alloc.free(self.cells);
        self.dirty_rows.deinit();
        self.terminal.deinit(self.alloc);
    }

    /// Feed PTY output through the terminal emulator and snapshot the
    /// resulting cell grid into the wire-format cache.
    pub fn feedAndSnapshot(self: *DaemonSession, data: []const u8) void {
        var stream = self.terminal.vtStream();
        stream.nextSlice(data);
        self.snapshotCells();
    }

    /// Convert the terminal's screen to WireCell format, tracking dirty rows.
    fn snapshotCells(self: *DaemonSession) void {
        const screen = self.terminal.screens.active;
        const cursor = screen.cursor;

        self.cursor_x = cursor.x;
        self.cursor_y = cursor.y;
        self.cursor_visible = self.terminal.modes.get(.cursor_visible);

        // Iterate visible rows
        var row_it = screen.pages.rowIterator(
            .right_down,
            .{ .active = .{ .x = 0, .y = 0 } },
            null,
        );

        var row_idx: u16 = 0;
        while (row_it.next()) |pin| {
            if (row_idx >= self.rows) break;

            const term_cells = pin.cells(.all);
            const row_start = @as(usize, row_idx) * @as(usize, self.cols);
            var row_changed = false;

            for (0..@min(term_cells.len, self.cols)) |col_idx| {
                const wire = cellToWire(term_cells[col_idx], pin);
                const idx = row_start + col_idx;
                if (!std.meta.eql(self.cells[idx], wire)) {
                    self.cells[idx] = wire;
                    row_changed = true;
                }
            }

            if (row_changed) self.dirty_rows.set(row_idx);
            row_idx += 1;
        }
    }

    /// Convert a terminal Cell to WireCell format.
    fn cellToWire(cell: vt.Cell, pin: vt.Pin) Protocol.WireCell {
        const cp: u32 = switch (cell.content_tag) {
            .codepoint, .codepoint_grapheme => cell.content.codepoint,
            else => 0,
        };

        var fg_r: u8 = 255;
        var fg_g: u8 = 255;
        var fg_b: u8 = 255;
        var bg_r: u8 = 0;
        var bg_g: u8 = 0;
        var bg_b: u8 = 0;
        var flags: u8 = 0;

        if (cell.style_id != 0) {
            {
                const style = pin.node.data.styles.get(pin.node.data.memory, cell.style_id);
                switch (style.fg_color) {
                    .none => {},
                    .palette => |idx| {
                        const rgb = paletteToRgb(idx);
                        fg_r = rgb[0];
                        fg_g = rgb[1];
                        fg_b = rgb[2];
                        flags |= 0x20;
                    },
                    .rgb => |rgb| {
                        fg_r = rgb.r;
                        fg_g = rgb.g;
                        fg_b = rgb.b;
                        flags |= 0x20;
                    },
                }
                switch (style.bg_color) {
                    .none => {},
                    .palette => |idx| {
                        const rgb = paletteToRgb(idx);
                        bg_r = rgb[0];
                        bg_g = rgb[1];
                        bg_b = rgb[2];
                        flags |= 0x40;
                    },
                    .rgb => |rgb| {
                        bg_r = rgb.r;
                        bg_g = rgb.g;
                        bg_b = rgb.b;
                        flags |= 0x40;
                    },
                }
                if (style.flags.bold) flags |= 0x01;
                if (style.flags.italic) flags |= 0x02;
                if (style.flags.underline != .none) flags |= 0x04;
                if (style.flags.strikethrough) flags |= 0x08;
                if (style.flags.inverse) flags |= 0x10;
            }
        }

        return .{
            .codepoint = cp,
            .fg_r = fg_r, .fg_g = fg_g, .fg_b = fg_b,
            .bg_r = bg_r, .bg_g = bg_g, .bg_b = bg_b,
            .style_flags = flags,
            .wide = if (cell.wide == .wide) 1 else 0,
        };
    }

    /// Convert a 256-color palette index to RGB.
    fn paletteToRgb(idx: u8) [3]u8 {
        // Standard 16 ANSI colors
        const ansi = [16][3]u8{
            .{ 0, 0, 0 },       .{ 205, 0, 0 },     .{ 0, 205, 0 },     .{ 205, 205, 0 },
            .{ 0, 0, 238 },     .{ 205, 0, 205 },    .{ 0, 205, 205 },   .{ 229, 229, 229 },
            .{ 127, 127, 127 }, .{ 255, 0, 0 },      .{ 0, 255, 0 },     .{ 255, 255, 0 },
            .{ 92, 92, 255 },   .{ 255, 0, 255 },    .{ 0, 255, 255 },   .{ 255, 255, 255 },
        };
        if (idx < 16) return ansi[idx];
        if (idx < 232) {
            const ci = idx - 16;
            const b_val = ci % 6;
            const g_val = (ci / 6) % 6;
            const r_val = ci / 36;
            return .{
                if (r_val == 0) 0 else @as(u8, @truncate(@as(u16, r_val) * 40 + 55)),
                if (g_val == 0) 0 else @as(u8, @truncate(@as(u16, g_val) * 40 + 55)),
                if (b_val == 0) 0 else @as(u8, @truncate(@as(u16, b_val) * 40 + 55)),
            };
        }
        const gray: u8 = @truncate(@as(u16, idx - 232) * 10 + 8);
        return .{ gray, gray, gray };
    }

    /// Mark all rows as dirty (e.g., after resize or new attach).
    pub fn markAllDirty(self: *DaemonSession) void {
        self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.rows }, true);
    }

    /// Clear all dirty flags (after sending a delta).
    pub fn clearDirty(self: *DaemonSession) void {
        self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.rows }, false);
    }

    /// Get cell at (col, row).
    pub fn getCell(self: *const DaemonSession, col: u16, row: u16) Protocol.WireCell {
        return self.cells[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }

    /// Set cell at (col, row) and mark the row dirty.
    pub fn setCell(self: *DaemonSession, col: u16, row: u16, cell: Protocol.WireCell) void {
        const idx = @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
        self.cells[idx] = cell;
        self.dirty_rows.set(row);
    }

    /// Serialize the full screen state (for FULL_STATE message).
    pub fn serializeFullState(self: *const DaemonSession, alloc: Allocator) ![]u8 {
        const cell_count = @as(usize, self.rows) * @as(usize, self.cols);
        const payload_size = Protocol.FullStateHeader.size + cell_count * Protocol.WireCell.size;

        const payload = try alloc.alloc(u8, payload_size);
        errdefer alloc.free(payload);

        // Write header
        const hdr: Protocol.FullStateHeader = .{
            .rows = self.rows,
            .cols = self.cols,
            .cursor_x = self.cursor_x,
            .cursor_y = self.cursor_y,
            .cursor_visible = if (self.cursor_visible) 1 else 0,
        };
        const hdr_bytes: *const [Protocol.FullStateHeader.size]u8 = @ptrCast(&hdr);
        @memcpy(payload[0..Protocol.FullStateHeader.size], hdr_bytes);

        // Write cells
        const cell_bytes: [*]const u8 = @ptrCast(self.cells.ptr);
        @memcpy(
            payload[Protocol.FullStateHeader.size..],
            cell_bytes[0 .. cell_count * Protocol.WireCell.size],
        );

        return payload;
    }

    /// Serialize only dirty rows (for DELTA message). Returns null if nothing dirty.
    pub fn serializeDelta(self: *DaemonSession, alloc: Allocator) !?[]u8 {
        // Count dirty rows
        var num_dirty: u16 = 0;
        for (0..self.rows) |r| {
            if (self.dirty_rows.isSet(r)) num_dirty += 1;
        }
        if (num_dirty == 0) return null;

        const row_payload_size = Protocol.DeltaRowHeader.size + @as(usize, self.cols) * Protocol.WireCell.size;
        const payload_size = Protocol.DeltaHeader.size + @as(usize, num_dirty) * row_payload_size;

        const payload = try alloc.alloc(u8, payload_size);
        errdefer alloc.free(payload);

        // Write delta header
        const dhdr: Protocol.DeltaHeader = .{
            .num_rows = num_dirty,
            .cursor_x = self.cursor_x,
            .cursor_y = self.cursor_y,
            .cursor_visible = if (self.cursor_visible) 1 else 0,
        };
        const dhdr_bytes: *const [Protocol.DeltaHeader.size]u8 = @ptrCast(&dhdr);
        @memcpy(payload[0..Protocol.DeltaHeader.size], dhdr_bytes);

        // Write each dirty row
        var offset: usize = Protocol.DeltaHeader.size;
        for (0..self.rows) |r| {
            if (!self.dirty_rows.isSet(r)) continue;

            const rh: Protocol.DeltaRowHeader = .{
                .row_index = @intCast(r),
                .num_cols = self.cols,
            };
            const rh_bytes: *const [Protocol.DeltaRowHeader.size]u8 = @ptrCast(&rh);
            @memcpy(payload[offset..][0..Protocol.DeltaRowHeader.size], rh_bytes);
            offset += Protocol.DeltaRowHeader.size;

            // Copy row cells
            const row_start = r * @as(usize, self.cols);
            const cell_bytes: [*]const u8 = @ptrCast(self.cells.ptr + row_start);
            @memcpy(
                payload[offset..][0 .. @as(usize, self.cols) * Protocol.WireCell.size],
                cell_bytes[0 .. @as(usize, self.cols) * Protocol.WireCell.size],
            );
            offset += @as(usize, self.cols) * Protocol.WireCell.size;
        }

        self.clearDirty();
        return payload;
    }
};

// ── SessionManager fields ──

alloc: Allocator,
sessions: std.AutoArrayHashMap(u32, *DaemonSession),
pty_readers: std.AutoArrayHashMap(u32, *PtyReader),
next_id: u32 = 1,
mutex: std.Thread.Mutex = .{},

/// If true, skip PTY spawning (for tests).
skip_pty: bool = false,

pub fn init(alloc: Allocator) SessionManager {
    return .{
        .alloc = alloc,
        .sessions = std.AutoArrayHashMap(u32, *DaemonSession).init(alloc),
        .pty_readers = std.AutoArrayHashMap(u32, *PtyReader).init(alloc),
    };
}

/// Create a test-mode manager that skips PTY spawning.
pub fn initTest(alloc: Allocator) SessionManager {
    return .{
        .alloc = alloc,
        .sessions = std.AutoArrayHashMap(u32, *DaemonSession).init(alloc),
        .pty_readers = std.AutoArrayHashMap(u32, *PtyReader).init(alloc),
        .skip_pty = true,
    };
}

/// Acquire the session manager lock. Callers from client threads must
/// hold this lock for any session/map mutation.
pub fn lock(self: *SessionManager) void {
    self.mutex.lock();
}

pub fn unlock(self: *SessionManager) void {
    self.mutex.unlock();
}

pub fn deinit(self: *SessionManager) void {
    // Stop all PTY readers first
    var rit = self.pty_readers.iterator();
    while (rit.next()) |entry| {
        entry.value_ptr.*.stop();
        self.alloc.destroy(entry.value_ptr.*);
    }
    self.pty_readers.deinit();

    var it = self.sessions.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.deinit();
        self.alloc.destroy(entry.value_ptr.*);
    }
    self.sessions.deinit();
}

/// Create a new session with the given dimensions. Spawns a PTY and shell
/// unless in test mode.
pub fn createSession(
    self: *SessionManager,
    cols: u16,
    rows: u16,
    command: ?[]const u8,
) !*DaemonSession {
    // Safe ID increment — skip 0 on wrap to avoid sentinel collision.
    const id = self.next_id;
    self.next_id +%= 1;
    if (self.next_id == 0) self.next_id = 1;

    const cell_count = @as(usize, rows) * @as(usize, cols);
    const cells = try self.alloc.alloc(Protocol.WireCell, cell_count);
    errdefer self.alloc.free(cells);
    @memset(cells, Protocol.WireCell{});

    var dirty = try std.DynamicBitSet.initFull(self.alloc, rows);
    errdefer dirty.deinit();

    // Initialize the real Ghostty terminal emulator
    var terminal = try vt.Terminal.init(self.alloc, .{
        .cols = cols,
        .rows = rows,
    });
    errdefer terminal.deinit(self.alloc);

    const session = try self.alloc.create(DaemonSession);

    const cmd_copy: [:0]u8 = if (command) |cmd|
        try self.alloc.dupeZ(u8, cmd)
    else
        try self.alloc.dupeZ(u8, "");

    session.* = .{
        .id = id,
        .name = try self.alloc.dupe(u8, ""),
        .title = try self.alloc.dupe(u8, ""),
        .pwd = try self.alloc.dupe(u8, ""),
        .command = cmd_copy,
        .cols = cols,
        .rows = rows,
        .terminal = terminal,
        .cells = cells,
        .dirty_rows = dirty,
        .alloc = self.alloc,
    };
    // After session is fully initialized, use deinit for cleanup on error.
    errdefer {
        session.deinit();
        self.alloc.destroy(session);
    }

    // Spawn PTY + shell (skip in test mode)
    if (!self.skip_pty) {
        spawnPty(session) catch |err| {
            log.err("failed to spawn PTY: {}", .{err});
            return err;
        };
    }

    try self.sessions.put(id, session);

    // Start PTY reader thread for this session (if PTY is active)
    if (!self.skip_pty and session.pty_fd != null) start_reader: {
        const reader = try self.alloc.create(PtyReader);
        reader.* = PtyReader.init(self.alloc, self, id);
        reader.start() catch |err| {
            log.err("failed to start pty reader for session {}: {}", .{ id, err });
            self.alloc.destroy(reader);
            break :start_reader;
        };
        self.pty_readers.put(id, reader) catch |err| {
            log.err("failed to track pty reader for session {}: {}", .{ id, err });
            reader.stop();
            self.alloc.destroy(reader);
        };
    }

    log.info("session created id={} cols={} rows={}", .{ id, cols, rows });
    return session;
}

/// Destroy a session by id. Stops the PTY reader, kills the child, frees resources.
pub fn destroySession(self: *SessionManager, id: u32) bool {
    // Stop PTY reader first
    if (self.pty_readers.fetchSwapRemove(id)) |kv| {
        kv.value.stop();
        self.alloc.destroy(kv.value);
    }

    if (self.sessions.fetchSwapRemove(id)) |kv| {
        kv.value.deinit();
        self.alloc.destroy(kv.value);
        log.info("session destroyed id={}", .{id});
        return true;
    }
    return false;
}

/// Get a session by id.
pub fn getSession(self: *SessionManager, id: u32) ?*DaemonSession {
    return self.sessions.get(id);
}

/// Set the client fd on the session's PTY reader for delta pushing.
pub fn setSessionClientFd(self: *SessionManager, session_id: u32, fd: posix.fd_t) void {
    if (self.pty_readers.get(session_id)) |reader| {
        reader.setClientFd(fd);
    }
}

/// Get a list of all sessions as protocol entries.
pub fn listSessions(self: *SessionManager, alloc: Allocator) ![]Protocol.SessionEntry {
    const entries = try alloc.alloc(Protocol.SessionEntry, self.sessions.count());

    var i: usize = 0;
    var it = self.sessions.iterator();
    while (it.next()) |entry| {
        const s = entry.value_ptr.*;
        entries[i] = .{
            .id = s.id,
            .name = s.name,
            .title = s.title,
            .pwd = s.pwd,
            .attached = s.attached,
            .child_exited = s.child_exited,
        };
        i += 1;
    }

    return entries;
}

/// Free a session entry list (does not free the string contents since
/// they point into session-owned memory).
pub fn freeSessionEntries(alloc: Allocator, entries: []Protocol.SessionEntry) void {
    alloc.free(entries);
}

/// Write input bytes to a session's PTY.
pub fn writeInput(self: *SessionManager, session_id: u32, data: []const u8) !void {
    const session = self.getSession(session_id) orelse return error.SessionNotFound;
    const fd = session.pty_fd orelse return error.NoPty;
    try Protocol.writeAll(fd, data);
}

/// Resize a session's PTY and terminal grid.
pub fn resizeSession(self: *SessionManager, session_id: u32, new_cols: u16, new_rows: u16) !void {
    const session = self.getSession(session_id) orelse return error.SessionNotFound;

    // Update PTY window size
    if (session.pty_fd) |fd| {
        var ws = c.winsize{
            .ws_row = new_rows,
            .ws_col = new_cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws)) < 0) {
            log.warn("TIOCSWINSZ failed for session {}", .{session_id});
        }
    }

    // Resize the terminal emulator (handles reflow, etc.)
    try session.terminal.resize(self.alloc, new_cols, new_rows);

    // Resize the wire-format cache
    const new_count = @as(usize, new_rows) * @as(usize, new_cols);
    const new_cells = try self.alloc.alloc(Protocol.WireCell, new_count);
    @memset(new_cells, Protocol.WireCell{});
    self.alloc.free(session.cells);
    session.cells = new_cells;
    session.cols = new_cols;
    session.rows = new_rows;

    session.dirty_rows.deinit();
    session.dirty_rows = try std.DynamicBitSet.initFull(self.alloc, new_rows);

    // Snapshot after resize to populate new cache
    session.snapshotCells();
}

// ── PTY management ──

/// Spawn a PTY + child process for a session. The session's `command`
/// field is used if non-empty, otherwise `$SHELL` or `/bin/sh`.
fn spawnPty(session: *DaemonSession) !void {
    var master_fd: posix.fd_t = undefined;
    var slave_fd: posix.fd_t = undefined;

    // Set initial size
    var ws = c.winsize{
        .ws_row = session.rows,
        .ws_col = session.cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    // Open PTY pair using libc openpty
    if (c.openpty(&master_fd, &slave_fd, null, null, &ws) < 0) {
        return error.OpenptyFailed;
    }
    errdefer {
        _ = std.c.close(master_fd);
        _ = std.c.close(slave_fd);
    }

    // Set CLOEXEC on master
    cloexec: {
        const flags = posix.fcntl(master_fd, posix.F.GETFD, 0) catch break :cloexec;
        _ = posix.fcntl(master_fd, posix.F.SETFD, flags | posix.FD_CLOEXEC) catch break :cloexec;
    }

    // Enable IUTF8 (required on macOS, good practice elsewhere)
    var attrs: c.termios = undefined;
    if (c.tcgetattr(master_fd, &attrs) == 0) {
        attrs.c_iflag |= c.IUTF8;
        _ = c.tcsetattr(master_fd, c.TCSANOW, &attrs);
    }

    // Fork
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // ── Child process ──
        _ = std.c.close(master_fd);

        // Reset signal handlers to defaults (matching pty.zig childPreExec)
        const default_sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        const signals = [_]u6{
            posix.SIG.ABRT, posix.SIG.ALRM, posix.SIG.BUS,
            posix.SIG.CHLD, posix.SIG.FPE,  posix.SIG.HUP,
            posix.SIG.ILL,  posix.SIG.INT,  posix.SIG.PIPE,
            posix.SIG.SEGV, posix.SIG.TRAP, posix.SIG.TERM,
            posix.SIG.QUIT,
        };
        for (signals) |sig| {
            posix.sigaction(sig, &default_sa, null);
        }

        // Create new session and set controlling terminal
        _ = setsid();
        _ = c.ioctl(slave_fd, TIOCSCTTY, @as(c_ulong, 0));

        // Redirect stdio to slave PTY
        _ = std.c.dup2(slave_fd, 0);
        _ = std.c.dup2(slave_fd, 1);
        _ = std.c.dup2(slave_fd, 2);
        if (slave_fd > 2) _ = std.c.close(slave_fd);

        // Use session command if non-empty, else $SHELL
        const shell: [*:0]const u8 = if (session.command.len > 0)
            session.command.ptr
        else
            std.c.getenv("SHELL") orelse "/bin/sh";

        // Inherit the parent's environment (crucial for PATH, HOME, etc.)
        // and override TERM.
        _ = setenv("TERM", "xterm-256color", 1);

        const argv = [_:null]?[*:0]const u8{shell};
        _ = std.c.execve(shell, &argv, std.c.environ);
        std.c.exit(1);
    }

    // ── Parent process ──
    _ = std.c.close(slave_fd);
    session.pty_fd = master_fd;
    session.child_pid = pid;

    log.info("spawned shell pid={} fd={}", .{ pid, master_fd });
}

// ── Tests ──

test "create and destroy session" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const session = try mgr.createSession(80, 24, null);
    try std.testing.expectEqual(@as(u32, 1), session.id);
    try std.testing.expectEqual(@as(u16, 80), session.cols);
    try std.testing.expectEqual(@as(u16, 24), session.rows);

    // Cell grid should be initialized
    try std.testing.expectEqual(@as(usize, 80 * 24), session.cells.len);

    // All rows should be dirty initially
    for (0..24) |r| {
        try std.testing.expect(session.dirty_rows.isSet(r));
    }

    // Verify session appears in list
    const entries = try mgr.listSessions(alloc);
    defer SessionManager.freeSessionEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u32, 1), entries[0].id);

    // Destroy
    try std.testing.expect(mgr.destroySession(1));
    try std.testing.expect(!mgr.destroySession(1)); // double destroy = false
}

test "session cell operations" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const session = try mgr.createSession(10, 5, null);

    // Clear dirty then set a cell
    session.clearDirty();
    for (0..5) |r| {
        try std.testing.expect(!session.dirty_rows.isSet(r));
    }

    const cell = Protocol.WireCell{ .codepoint = 'A', .fg_r = 255 };
    session.setCell(3, 2, cell);

    try std.testing.expect(session.dirty_rows.isSet(2));
    try std.testing.expect(!session.dirty_rows.isSet(0));

    const got = session.getCell(3, 2);
    try std.testing.expectEqual(@as(u32, 'A'), got.codepoint);
    try std.testing.expectEqual(@as(u8, 255), got.fg_r);
}

test "serialize full state" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const session = try mgr.createSession(4, 2, null);
    session.setCell(0, 0, .{ .codepoint = 'H' });
    session.setCell(1, 0, .{ .codepoint = 'i' });

    const payload = try session.serializeFullState(alloc);
    defer alloc.free(payload);

    // Header + 4*2 cells * 12 bytes each = 12 + 96 = 108
    try std.testing.expectEqual(
        @as(usize, Protocol.FullStateHeader.size + 8 * Protocol.WireCell.size),
        payload.len,
    );

    // Parse header back
    const hdr: *const Protocol.FullStateHeader = @ptrCast(@alignCast(payload.ptr));
    try std.testing.expectEqual(@as(u16, 2), hdr.rows);
    try std.testing.expectEqual(@as(u16, 4), hdr.cols);
}

test "serialize delta — only dirty rows" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const session = try mgr.createSession(4, 3, null);

    // Clear all dirty, then dirty only row 1
    session.clearDirty();
    session.setCell(0, 1, .{ .codepoint = 'X' });

    const payload = try session.serializeDelta(alloc);
    try std.testing.expect(payload != null);
    defer alloc.free(payload.?);

    // Should have: DeltaHeader(8) + 1 * (DeltaRowHeader(4) + 4 cells * 12) = 8 + 52 = 60
    const expected = Protocol.DeltaHeader.size + Protocol.DeltaRowHeader.size + 4 * Protocol.WireCell.size;
    try std.testing.expectEqual(expected, payload.?.len);

    // After delta, nothing dirty
    const no_delta = try session.serializeDelta(alloc);
    try std.testing.expect(no_delta == null);
}

test "multiple sessions get unique ids" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s1 = try mgr.createSession(10, 5, null);
    const s2 = try mgr.createSession(10, 5, null);
    const s3 = try mgr.createSession(10, 5, null);

    try std.testing.expectEqual(@as(u32, 1), s1.id);
    try std.testing.expectEqual(@as(u32, 2), s2.id);
    try std.testing.expectEqual(@as(u32, 3), s3.id);
    try std.testing.expectEqual(@as(usize, 3), mgr.sessions.count());
}

test "resize session" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const session = try mgr.createSession(10, 5, null);
    session.setCell(2, 1, .{ .codepoint = 'Z' });
    session.clearDirty();

    // Resize to larger
    try mgr.resizeSession(1, 20, 10);

    try std.testing.expectEqual(@as(u16, 20), session.cols);
    try std.testing.expectEqual(@as(u16, 10), session.rows);
    try std.testing.expectEqual(@as(usize, 20 * 10), session.cells.len);

    // Original cell should be preserved
    try std.testing.expectEqual(@as(u32, 'Z'), session.getCell(2, 1).codepoint);

    // All rows dirty after resize
    for (0..10) |r| {
        try std.testing.expect(session.dirty_rows.isSet(r));
    }
}
