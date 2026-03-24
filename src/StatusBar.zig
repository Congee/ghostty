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

/// Components keyed by "source:zone". A single source can have entries
/// in multiple zones (e.g. "nvim:left" and "nvim:right").
sources: std.StringArrayHashMapUnmanaged(SourceData) = .{},

/// Thread-safe message queue.
queue: std.ArrayListUnmanaged(Message) = .{},
mu: std.Thread.Mutex = .{},

/// Bumped on every state change so renderers know to re-read.
version: u64 = 0,

/// Plain text fallback for backward compat with SET-STATUS-LEFT/RIGHT.
left_text: []const u8 = "",
center_text: []const u8 = "",
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
        center: ?[]const u8,
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
                if (st.center) |c| alloc.free(c);
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

/// Three-zone layout for the renderer.
pub const SegmentLayout = struct {
    left: []const Segment,
    center: []const Segment,
    right: []const Segment,

    pub const empty: SegmentLayout = .{ .left = &.{}, .center = &.{}, .right = &.{} };

    pub fn hasContent(self: SegmentLayout) bool {
        return self.left.len > 0 or self.center.len > 0 or self.right.len > 0;
    }
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

    // Free source data (keys are "source:zone" composite strings)
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
    if (self.center_text.len > 0) self.alloc.free(self.center_text);
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
            // Key is "source:zone" — use stack buffer for lookup, only
            // heap-allocate when inserting a new entry.
            var key_buf: [256]u8 = undefined;
            const lookup_key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ sc.source, sc.zone }) catch return;

            if (self.sources.getPtr(lookup_key)) |existing| {
                self.alloc.free(existing.zone);
                for (existing.items) |*c| c.deinit(self.alloc);
                if (existing.items.len > 0) self.alloc.free(existing.items);
                existing.zone = sc.zone;
                existing.items = sc.items;
                self.alloc.free(sc.source);
            } else {
                const key = self.alloc.dupe(u8, lookup_key) catch return;
                self.sources.put(self.alloc, key, .{
                    .zone = sc.zone,
                    .items = sc.items,
                }) catch {
                    self.alloc.free(key);
                    log.warn("failed to insert source into status bar", .{});
                    return;
                };
                self.alloc.free(sc.source);
            }
            sc.source = "";
            sc.zone = "";
            sc.items = &.{};
            self.version +%= 1;
        },
        .clear_components => |cc| {
            // Remove ALL entries for this source (any zone).
            // Keys are "source:zone" — match by source prefix before ":".
            var i: usize = 0;
            while (i < self.sources.count()) {
                const key = self.sources.keys()[i];
                const source_part = if (std.mem.indexOfScalar(u8, key, ':')) |sep|
                    key[0..sep]
                else
                    key;

                if (std.mem.eql(u8, source_part, cc.source)) {
                    if (self.sources.fetchOrderedRemove(key)) |kv| {
                        self.alloc.free(kv.key);
                        self.alloc.free(kv.value.zone);
                        for (kv.value.items) |*c| c.deinit(self.alloc);
                        if (kv.value.items.len > 0) self.alloc.free(kv.value.items);
                    }
                } else {
                    i += 1;
                }
            }
            self.version +%= 1;
        },
        .set_text => |*st| {
            if (st.left == null and st.center == null and st.right == null) return;
            if (st.left) |l| {
                if (self.left_text.len > 0) self.alloc.free(self.left_text);
                self.left_text = l;
                st.left = null; // transferred
            }
            if (st.center) |c| {
                if (self.center_text.len > 0) self.alloc.free(self.center_text);
                self.center_text = c;
                st.center = null; // transferred
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
            if (self.center_text.len > 0) self.alloc.free(self.center_text);
            self.center_text = "";
            if (self.right_text.len > 0) self.alloc.free(self.right_text);
            self.right_text = "";
            self.version +%= 1;
        },
    }
}

/// Returns true if the status bar has any content to display.
pub fn hasContent(self: *const StatusBar) bool {
    return self.sources.count() > 0 or self.left_text.len > 0 or self.center_text.len > 0 or self.right_text.len > 0;
}

/// Build segments for rendering. Caller must use arena allocator.
/// Returns a three-zone layout (left, center, right) for vim-style positioning.
/// Holds mu for the duration to prevent races with drain() on other renderer threads.
pub fn buildSegments(self: *StatusBar, arena: Allocator) SegmentLayout {
    self.mu.lock();
    defer self.mu.unlock();

    var left_segs: std.ArrayListUnmanaged(Segment) = .empty;
    var center_segs: std.ArrayListUnmanaged(Segment) = .empty;
    var right_segs: std.ArrayListUnmanaged(Segment) = .empty;

    // Partition source components by zone.
    var it = self.sources.iterator();
    while (it.next()) |entry| {
        const zone = entry.value_ptr.zone;
        const target = if (std.mem.eql(u8, zone, "left"))
            &left_segs
        else if (std.mem.eql(u8, zone, "center"))
            &center_segs
        else
            &right_segs;
        for (entry.value_ptr.items) |comp| {
            target.append(arena, .{
                .text = arena.dupe(u8, comp.text) catch continue,
                .fg = comp.style.fg,
                .bg = comp.style.bg,
                .bold = comp.style.bold,
            }) catch {};
        }
    }

    // Append plain text to each zone.
    if (self.left_text.len > 0) {
        if (left_segs.items.len > 0)
            left_segs.append(arena, .{ .text = " " }) catch {};
        left_segs.append(arena, .{
            .text = arena.dupe(u8, self.left_text) catch "",
        }) catch {};
    }

    if (self.center_text.len > 0) {
        if (center_segs.items.len > 0)
            center_segs.append(arena, .{ .text = " " }) catch {};
        center_segs.append(arena, .{
            .text = arena.dupe(u8, self.center_text) catch "",
        }) catch {};
    }

    if (self.right_text.len > 0) {
        if (right_segs.items.len > 0)
            right_segs.append(arena, .{ .text = " " }) catch {};
        right_segs.append(arena, .{
            .text = arena.dupe(u8, self.right_text) catch "",
        }) catch {};
    }

    return .{
        .left = left_segs.items,
        .center = center_segs.items,
        .right = right_segs.items,
    };
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

    const data = sb.sources.get("daemon:left").?;
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
        .left = try testing.allocator.dupe(u8, "left"),
        .center = try testing.allocator.dupe(u8, "1:~*"),
        .right = null,
    } });
    sb.drain();
    try testing.expectEqualStrings("left", sb.left_text);
    try testing.expectEqualStrings("1:~*", sb.center_text);

    sb.send(.{ .set_text = .{
        .left = null,
        .center = try testing.allocator.dupe(u8, "1:~* 2:build"),
        .right = null,
    } });
    sb.drain();
    try testing.expectEqualStrings("1:~* 2:build", sb.center_text);

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
    try testing.expect(sb.sources.get("tabs:left") != null);
    try testing.expect(sb.sources.get("daemon:left") == null);
}

test "hasContent" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    try testing.expect(!sb.hasContent());

    sb.send(.{ .set_text = .{
        .left = try testing.allocator.dupe(u8, "tabs"),
        .center = null,
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
        .center = null,
        .right = null,
    } });
    sb.drain();
    try testing.expect(sb.version > v0);
}

test "same source different zones coexist" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    // Send left zone
    var left_items = try testing.allocator.alloc(Component, 1);
    left_items[0] = .{ .text = try testing.allocator.dupe(u8, "mode:N") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = left_items,
    } });

    // Send right zone from same source
    var right_items = try testing.allocator.alloc(Component, 1);
    right_items[0] = .{ .text = try testing.allocator.dupe(u8, "39:1") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "right"),
        .items = right_items,
    } });

    sb.drain();

    // Both entries should exist
    try testing.expect(sb.sources.count() == 2);
    try testing.expect(sb.sources.get("nvim:left") != null);
    try testing.expect(sb.sources.get("nvim:right") != null);
    try testing.expectEqualStrings("mode:N", sb.sources.get("nvim:left").?.items[0].text);
    try testing.expectEqualStrings("39:1", sb.sources.get("nvim:right").?.items[0].text);
}

test "clear_components removes all zones for source" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    // Add left and right zones for same source
    var left_items = try testing.allocator.alloc(Component, 1);
    left_items[0] = .{ .text = try testing.allocator.dupe(u8, "left") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = left_items,
    } });

    var right_items = try testing.allocator.alloc(Component, 1);
    right_items[0] = .{ .text = try testing.allocator.dupe(u8, "right") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "right"),
        .items = right_items,
    } });

    // Add a different source that should survive
    var other_items = try testing.allocator.alloc(Component, 1);
    other_items[0] = .{ .text = try testing.allocator.dupe(u8, "other") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "daemon"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = other_items,
    } });

    sb.drain();
    try testing.expect(sb.sources.count() == 3);

    // Clear nvim — should remove both nvim:left and nvim:right
    sb.send(.{ .clear_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
    } });
    sb.drain();

    try testing.expect(sb.sources.count() == 1);
    try testing.expect(sb.sources.get("nvim:left") == null);
    try testing.expect(sb.sources.get("nvim:right") == null);
    try testing.expect(sb.sources.get("daemon:left") != null);
}

test "buildSegments three-zone layout" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    // Components in left and right zones
    var left_items = try testing.allocator.alloc(Component, 1);
    left_items[0] = .{ .text = try testing.allocator.dupe(u8, "N"), .style = .{ .bold = true } };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = left_items,
    } });

    var right_items = try testing.allocator.alloc(Component, 1);
    right_items[0] = .{ .text = try testing.allocator.dupe(u8, "39:1") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "right"),
        .items = right_items,
    } });

    // Center text from tabs
    sb.send(.{ .set_text = .{
        .left = null,
        .center = try testing.allocator.dupe(u8, "1:vi* 2:zsh"),
        .right = null,
    } });

    sb.drain();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const layout = sb.buildSegments(arena_state.allocator());

    // Left zone: component
    try testing.expect(layout.left.len == 1);
    try testing.expectEqualStrings("N", layout.left[0].text);
    try testing.expect(layout.left[0].bold);

    // Center zone: text
    try testing.expect(layout.center.len == 1);
    try testing.expectEqualStrings("1:vi* 2:zsh", layout.center[0].text);

    // Right zone: component
    try testing.expect(layout.right.len == 1);
    try testing.expectEqualStrings("39:1", layout.right[0].text);
}

test "update same source same zone replaces" {
    var sb = StatusBar.init(testing.allocator);
    defer sb.deinit();

    var items1 = try testing.allocator.alloc(Component, 1);
    items1[0] = .{ .text = try testing.allocator.dupe(u8, "old") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = items1,
    } });
    sb.drain();

    var items2 = try testing.allocator.alloc(Component, 1);
    items2[0] = .{ .text = try testing.allocator.dupe(u8, "new") };
    sb.send(.{ .set_components = .{
        .source = try testing.allocator.dupe(u8, "nvim"),
        .zone = try testing.allocator.dupe(u8, "left"),
        .items = items2,
    } });
    sb.drain();

    // Should still be 1 entry, updated
    try testing.expect(sb.sources.count() == 1);
    try testing.expectEqualStrings("new", sb.sources.get("nvim:left").?.items[0].text);
}
