//! StatusBar is a reactive object that lives on App (one per window).
//! It receives messages from various sources (tabs, control socket) and
//! maintains component state keyed by source. The renderer reads from
//! this object to build the status bar display.
//!
//! Thread safety: `send()` is safe to call from any thread (enqueues
//! under a lightweight mutex). `drain()` + `segments()` are called by
//! the renderer thread.
const StatusBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("renderer.zig");
const Component = renderer.State.Component;

const log = std.log.scoped(.status_bar);

alloc: Allocator,

/// Components keyed by source. Each source owns its components independently.
/// Key: source name (heap-allocated), Value: SourceData.
sources: std.StringArrayHashMapUnmanaged(SourceData) = .{},

/// Thread-safe message queue.
queue: std.ArrayListUnmanaged(Message) = .{},
mu: std.Thread.Mutex = .{},

/// Bumped on every state change so renderers know to re-read.
version: u64 = 0,

/// Plain text fallback for backward compat with SET-STATUS-LEFT/RIGHT.
left_text: []const u8 = "",
right_text: []const u8 = "",

/// Click regions computed during the last render pass.
click_regions: []const ClickRegion = &.{},

pub const SourceData = struct {
    zone: []const u8,
    items: []const Component,
};

pub const Message = union(enum) {
    set_components: struct {
        source: []const u8,
        zone: []const u8,
        items: []const Component,
    },
    clear_components: struct {
        source: []const u8,
    },
    set_text: struct {
        left: ?[]const u8,
        right: ?[]const u8,
    },
    clear_text: void,

    pub fn deinit(self: *Message, alloc: Allocator) void {
        switch (self.*) {
            .set_components => |sc| {
                if (sc.source.len > 0) alloc.free(sc.source);
                if (sc.zone.len > 0) alloc.free(sc.zone);
                for (sc.items) |*c| c.deinit(alloc);
                if (sc.items.len > 0) alloc.free(sc.items);
            },
            .clear_components => |cc| {
                if (cc.source.len > 0) alloc.free(cc.source);
            },
            .set_text => |st| {
                if (st.left) |l| alloc.free(l);
                if (st.right) |r| alloc.free(r);
            },
            .clear_text => {},
        }
    }
};

/// A styled segment for rendering. Built from components + plain text.
pub const Segment = struct {
    text: []const u8,
    fg: ?[3]u8 = null,
    bg: ?[3]u8 = null,
    bold: bool = false,
};

/// A region in the status bar that is clickable, computed during render.
pub const ClickRegion = renderer.State.ClickRegion;

pub fn init(alloc: Allocator) StatusBar {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *StatusBar) void {
    // Free queued messages
    for (self.queue.items) |*msg| msg.deinit(self.alloc);
    self.queue.deinit(self.alloc);

    // Free source data
    var it = self.sources.iterator();
    while (it.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.free(entry.value_ptr.zone);
        for (entry.value_ptr.items) |*c| c.deinit(self.alloc);
        if (entry.value_ptr.items.len > 0) self.alloc.free(entry.value_ptr.items);
    }
    self.sources.deinit(self.alloc);

    // Free plain text
    if (self.left_text.len > 0) self.alloc.free(self.left_text);
    if (self.right_text.len > 0) self.alloc.free(self.right_text);

    // Free click regions
    if (self.click_regions.len > 0) self.alloc.free(self.click_regions);
}

/// Send a message (thread-safe, called from main/IO thread).
pub fn send(self: *StatusBar, msg: Message) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.queue.append(self.alloc, msg) catch |err| {
        log.warn("failed to enqueue status bar message: {}", .{err});
        // Free the message data since we couldn't enqueue it
        var m = msg;
        m.deinit(self.alloc);
    };
}

/// Drain pending messages and apply them. Called by the renderer thread.
/// Holds mu for the entire operation so readers (e.g. ControlSocket IO
/// thread) see consistent state when they acquire mu.
pub fn drain(self: *StatusBar) void {
    self.mu.lock();
    defer self.mu.unlock();

    if (self.queue.items.len == 0) return;

    // Swap the queue so send() can enqueue new messages if it
    // manages to acquire mu after we release (between frames).
    var pending = self.queue;
    self.queue = .{};

    defer {
        for (pending.items) |*msg| msg.deinit(self.alloc);
        pending.deinit(self.alloc);
    }

    for (pending.items) |*msg| {
        self.applyMessage(msg);
    }
}

fn applyMessage(self: *StatusBar, msg: *Message) void {
    switch (msg.*) {
        .set_components => |*sc| {
            // If source already exists, free old data
            if (self.sources.getPtr(sc.source)) |existing| {
                self.alloc.free(existing.zone);
                for (existing.items) |*c| c.deinit(self.alloc);
                if (existing.items.len > 0) self.alloc.free(existing.items);
                // Update in place — reuse the existing key
                existing.zone = sc.zone;
                existing.items = sc.items;
                // Free the source key from the message since we reused the map key
                self.alloc.free(sc.source);
            } else {
                // New source
                self.sources.put(self.alloc, sc.source, .{
                    .zone = sc.zone,
                    .items = sc.items,
                }) catch {
                    log.warn("failed to insert source into status bar", .{});
                    return;
                };
            }
            // Null out transferred fields so Message.deinit won't free them
            sc.source = "";
            sc.zone = "";
            sc.items = &.{};
            self.version +%= 1;
        },
        .clear_components => |cc| {
            if (self.sources.fetchOrderedRemove(cc.source)) |kv| {
                self.alloc.free(kv.key);
                self.alloc.free(kv.value.zone);
                for (kv.value.items) |*c| c.deinit(self.alloc);
                if (kv.value.items.len > 0) self.alloc.free(kv.value.items);
            }
            self.version +%= 1;
        },
        .set_text => |*st| {
            if (st.left == null and st.right == null) return;
            if (st.left) |l| {
                if (self.left_text.len > 0) self.alloc.free(self.left_text);
                self.left_text = l;
                st.left = null; // transferred
            }
            if (st.right) |r| {
                if (self.right_text.len > 0) self.alloc.free(self.right_text);
                self.right_text = r;
                st.right = null; // transferred
            }
            self.version +%= 1;
        },
        .clear_text => {
            if (self.left_text.len > 0) self.alloc.free(self.left_text);
            self.left_text = "";
            if (self.right_text.len > 0) self.alloc.free(self.right_text);
            self.right_text = "";
            self.version +%= 1;
        },
    }
}

/// Returns true if the status bar has any content to display.
pub fn hasContent(self: *const StatusBar) bool {
    return self.sources.count() > 0 or self.left_text.len > 0 or self.right_text.len > 0;
}

/// Build segments for rendering. Caller must use arena allocator.
/// Returns segments in order: left-zone components, tab text, right-zone components.
/// Holds mu for the duration to prevent races with drain() on other renderer threads.
pub fn buildSegments(self: *StatusBar, arena: Allocator) []const Segment {
    self.mu.lock();
    defer self.mu.unlock();

    var left_segs: std.ArrayListUnmanaged(Segment) = .empty;
    var right_segs: std.ArrayListUnmanaged(Segment) = .empty;

    // Single pass: partition source components by zone.
    var it = self.sources.iterator();
    while (it.next()) |entry| {
        const is_left = std.mem.eql(u8, entry.value_ptr.zone, "left");
        const target = if (is_left) &left_segs else &right_segs;
        for (entry.value_ptr.items) |comp| {
            target.append(arena, .{
                .text = arena.dupe(u8, comp.text) catch continue,
                .fg = comp.style.fg,
                .bg = comp.style.bg,
                .bold = comp.style.bold,
            }) catch {};
        }
    }

    // Assemble: left components, tab text, separator, right components, right text.
    var segs: std.ArrayListUnmanaged(Segment) = .empty;
    segs.appendSlice(arena, left_segs.items) catch {};

    if (self.left_text.len > 0) {
        if (segs.items.len > 0) {
            segs.append(arena, .{ .text = " " }) catch {};
        }
        segs.append(arena, .{
            .text = arena.dupe(u8, self.left_text) catch "",
        }) catch {};
    }

    const has_right = right_segs.items.len > 0 or self.right_text.len > 0;
    if (has_right) {
        segs.append(arena, .{ .text = "  " }) catch {};
        segs.appendSlice(arena, right_segs.items) catch {};
        if (self.right_text.len > 0) {
            segs.append(arena, .{
                .text = arena.dupe(u8, self.right_text) catch "",
            }) catch {};
        }
    }

    return segs.items;
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "send and drain set_components" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    var items = try testing.allocator.alloc(Component, 1);
    items[0] = .{
        .text = try testing.allocator.dupe(u8, "git:main"),
        .style = .{ .fg = .{ 0, 255, 0 } },
    };

    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "daemon"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = items,
    } });

    try testing.expect(sb.sources.count() == 0); // not drained yet
    sb.drain();
    try testing.expect(sb.sources.count() == 1);

    const data = sb.sources.get("daemon").?;
    try testing.expectEqualStrings("left", data.zone);
    try testing.expect(data.items.len == 1);
    try testing.expectEqualStrings("git:main", data.items[0].text);
}

test "clear_components removes source" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    // Add a source
    var items = try testing.allocator.alloc(Component, 1);
    items[0] = .{ .text = try testing.allocator.dupe(u8, "branch") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "daemon"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = items,
    } });
    sb.drain();
    try testing.expect(sb.sources.count() == 1);

    // Clear it
    sb.send(.{ .clear_components = .{
        .source = try testing.allocator.dupe(u8, "daemon"),
    } });
    sb.drain();
    try testing.expect(sb.sources.count() == 0);
}

test "set_text and clear_text" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    sb.send(.{ .set_text = .{
        .left = try testing.allocator.dupe(u8, "1:~*"),
        .right = null,
    } });
    sb.drain();
    try testing.expectEqualStrings("1:~*", sb.left_text);

    sb.send(.{ .set_text = .{
        .left = try testing.allocator.dupe(u8, "1:~* 2:build"),
        .right = null,
    } });
    sb.drain();
    try testing.expectEqualStrings("1:~* 2:build", sb.left_text);

    sb.send(.{ .clear_text = {} });
    sb.drain();
    try testing.expectEqualStrings("", sb.left_text);
}

test "independent sources" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    // Set tabs source
    var tab_items = try testing.allocator.alloc(Component, 1);
    tab_items[0] = .{ .text = try testing.allocator.dupe(u8, "1:~*") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "tabs"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = tab_items,
    } });

    // Set daemon source
    var daemon_items = try testing.allocator.alloc(Component, 1);
    daemon_items[0] = .{ .text = try testing.allocator.dupe(u8, "git:main") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "daemon"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = daemon_items,
    } });

    sb.drain();
    try testing.expect(sb.sources.count() == 2);

    // Clear only daemon — tabs should survive
    sb.send(.{ .clear_components = .{
        .source = try testing.allocator.dupe(u8, "daemon"),
    } });
    sb.drain();
    try testing.expect(sb.sources.count() == 1);
    try testing.expect(sb.sources.get("tabs") != null);
    try testing.expect(sb.sources.get("daemon") == null);
}

test "hasContent" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    try testing.expect(!sb.hasContent());

    sb.send(.{ .set_text = .{
        .left = try testing.allocator.dupe(u8, "tabs"),
        .right = null,
    } });
    sb.drain();
    try testing.expect(sb.hasContent());
}

test "version bumps on changes" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    const v0 = sb.version;
    sb.send(.{ .set_text = .{
        .left = try testing.allocator.dupe(u8, "x"),
        .right = null,
    } });
    sb.drain();
    try testing.expect(sb.version > v0);
}
