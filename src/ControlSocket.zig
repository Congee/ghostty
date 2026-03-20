//! ControlSocket provides a Unix domain socket interface for external
//! tools to control the status bar and query session state.
//!
//! Protocol: line-based text commands over a Unix stream socket.
//!   SET-STATUS-LEFT <text>    — Set left status bar text
//!   SET-STATUS-RIGHT <text>   — Set right status bar text
//!   SET-STATUS <left> | <right> — Set both (pipe-separated)
//!   CLEAR-STATUS              — Clear the status bar
//!   LIST-SESSIONS             — List all sessions (JSON response)
//!   LIST-TABS                 — List tabs with index, title, active flag (JSON)
//!   GET-FOCUSED               — Get focused tab index and session info (JSON)
//!   RENAME-TAB <name>         — Rename the focused tab
//!   PING                      — Health check (responds PONG)
//!
//! Each command is a single line terminated by \n.
//! Responses are single lines terminated by \n.
const ControlSocket = @This();

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");
const App = @import("App.zig");
const renderer = @import("renderer.zig");
const Component = renderer.State.Component;

const log = std.log.scoped(.control_socket);

// Temporary file-based debug logging (macOS unified log not visible)
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.cwd().createFile("/tmp/ghostty-ctl-debug.log", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    file.writeAll(msg) catch {};
}

alloc: Allocator,
path: []const u8,
socket_fd: ?posix.socket_t = null,
listen_thread: ?std.Thread = null,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// Click subscribers: source_id → fd. When a component with action=notify
/// is clicked, write CLICK <id> <button>\n to the subscribed fd.
click_subscribers: std.StringHashMap(posix.fd_t),
click_mutex: std.Thread.Mutex = .{},

/// The app to query for sessions.
app: *App,

/// The surface to update (for status bar). This is the focused surface.
/// Updated on each command by looking at app.focused_surface.
surface_fn: *const fn (*App) ?*Surface,

pub fn init(
    alloc: Allocator,
    app: *App,
    socket_path: ?[]const u8,
) !ControlSocket {
    // Determine socket path
    const path = if (socket_path) |p|
        try alloc.dupe(u8, p)
    else
        try std.fmt.allocPrint(alloc, "/tmp/ghostty-ctl-{d}.sock", .{std.c.getpid()});

    return .{
        .alloc = alloc,
        .path = path,
        .app = app,
        .surface_fn = &getFocusedCoreSurface,
        .click_subscribers = std.StringHashMap(posix.fd_t).init(alloc),
    };
}

fn getFocusedCoreSurface(app: *App) ?*Surface {
    return app.focused_surface;
}

pub fn deinit(self: *ControlSocket) void {
    self.stop();
    if (self.socket_fd) |fd| {
        posix.close(fd);
        self.socket_fd = null;
    }
    // Close subscriber connections
    {
        self.click_mutex.lock();
        defer self.click_mutex.unlock();
        var it = self.click_subscribers.iterator();
        while (it.next()) |entry| {
            posix.close(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.click_subscribers.deinit();
    }
    std.fs.cwd().deleteFile(self.path) catch {};
    self.alloc.free(self.path);
}

pub fn start(self: *ControlSocket) !void {
    // Remove stale socket file
    std.fs.cwd().deleteFile(self.path) catch {};

    // Create and bind the socket
    const addr = try std.net.Address.initUnix(self.path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 5);
    self.socket_fd = fd;
    self.running.store(true, .release);

    log.info("control socket listening on {s}", .{self.path});

    // Start accept loop in background thread
    self.listen_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    self.listen_thread.?.setName("ctl-sock") catch {};
}

pub fn stop(self: *ControlSocket) void {
    debugLog("stop() called", .{});
    self.running.store(false, .release);
    // Close the listening socket to unblock accept
    if (self.socket_fd) |fd| {
        posix.close(fd);
        self.socket_fd = null;
    }
    if (self.listen_thread) |t| {
        t.join();
        self.listen_thread = null;
    }
}

fn acceptLoop(self: *ControlSocket) void {
    debugLog("accept loop started on {s}, running={}", .{ self.path, self.running.load(.acquire) });
    while (self.running.load(.acquire)) {
        const fd = self.socket_fd orelse {
            debugLog("accept loop: socket_fd is null", .{});
            return;
        };
        const conn = posix.accept(fd, null, null, 0) catch |err| {
            if (!self.running.load(.acquire)) return;
            log.warn("accept error: {}", .{err});
            continue;
        };
        debugLog("accepted connection fd={}", .{conn});
        if (!self.handleConnection(conn)) {
            posix.close(conn);
        }
    }
    debugLog("accept loop exited, running={}", .{self.running.load(.acquire)});
}

/// Returns true if the connection should be kept open (subscriptions).
fn handleConnection(self: *ControlSocket, conn: posix.socket_t) bool {
    var buf: [4096]u8 = undefined;
    const n = posix.read(conn, &buf) catch |err| {
        log.warn("handleConnection: read error fd={} err={}", .{ conn, err });
        return false;
    };
    if (n == 0) {
        log.info("handleConnection: empty read fd={}", .{conn});
        return false;
    }

    const line = std.mem.trimRight(u8, buf[0..n], "\r\n");
    debugLog("handleConnection: received '{s}' fd={}", .{ line, conn });

    // SUBSCRIBE-CLICKS: keep connection open for push notifications
    if (std.mem.startsWith(u8, line, "SUBSCRIBE-CLICKS ")) {
        const source = line["SUBSCRIBE-CLICKS ".len..];
        self.click_mutex.lock();
        defer self.click_mutex.unlock();

        // If source already subscribed, close old fd before replacing
        if (self.click_subscribers.getEntry(source)) |entry| {
            posix.close(entry.value_ptr.*);
            entry.value_ptr.* = conn;
        } else {
            const key = self.alloc.dupe(u8, source) catch {
                _ = posix.write(conn, "ERR alloc failed\n") catch {};
                return false;
            };
            self.click_subscribers.put(key, conn) catch {
                self.alloc.free(key);
                _ = posix.write(conn, "ERR alloc failed\n") catch {};
                return false;
            };
        }
        _ = posix.write(conn, "OK subscribed\n") catch {};
        log.info("click subscriber registered: {s} fd={}", .{ source, conn });
        return true; // Keep connection open
    }

    var resp_buf: [8192]u8 = undefined;
    const response = self.handleCommand(line, &resp_buf) catch |err| {
        const msg = std.fmt.bufPrint(&buf, "ERR {}\n", .{err}) catch return false;
        _ = posix.write(conn, msg) catch {};
        return false;
    };

    debugLog("handleConnection: responding with {d} bytes fd={}", .{ response.len, conn });
    _ = posix.write(conn, response) catch |err| {
        log.warn("handleConnection: write error fd={} err={}", .{ conn, err });
    };
    return false;
}

fn handleCommand(self: *ControlSocket, line: []const u8, resp_buf: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, line, "PING")) {
        return "PONG\n";
    }

    if (std.mem.startsWith(u8, line, "CLEAR-STATUS")) {
        const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
        try surface.setStatusBar(null, null);
        return "OK\n";
    }

    if (std.mem.startsWith(u8, line, "SET-STATUS-LEFT ")) {
        const text = line["SET-STATUS-LEFT ".len..];
        const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
        try surface.setStatusBar(text, null);
        return "OK\n";
    }

    if (std.mem.startsWith(u8, line, "SET-STATUS-RIGHT ")) {
        const text = line["SET-STATUS-RIGHT ".len..];
        const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
        try surface.setStatusBar(null, text);
        return "OK\n";
    }

    if (std.mem.startsWith(u8, line, "SET-STATUS ")) {
        const text = line["SET-STATUS ".len..];
        // Split on " | "
        if (std.mem.indexOf(u8, text, " | ")) |idx| {
            const left = text[0..idx];
            const right = text[idx + 3 ..];
            const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
            try surface.setStatusBar(left, right);
        } else {
            const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
            try surface.setStatusBar(text, null);
        }
        return "OK\n";
    }

    if (std.mem.startsWith(u8, line, "LIST-SESSIONS")) {
        self.app.logSessions();
        return "OK\n";
    }

    if (std.mem.startsWith(u8, line, "LIST-TABS")) {
        return self.listTabs(resp_buf);
    }

    if (std.mem.startsWith(u8, line, "GET-STATUS-BAR")) {
        return self.getStatusBar(resp_buf);
    }

    if (std.mem.startsWith(u8, line, "GET-FOCUSED")) {
        return self.getFocused(resp_buf);
    }

    if (std.mem.startsWith(u8, line, "SET-COMPONENTS ")) {
        const json = line["SET-COMPONENTS ".len..];
        const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
        const components = parseComponents(self.alloc, json) catch return "ERR invalid JSON\n";
        surface.setComponents(components.zone, components.source, components.items) catch {
            freeComponents(self.alloc, components.items);
            return "ERR failed to set components\n";
        };
        return "OK\n";
    }

    if (std.mem.startsWith(u8, line, "CLEAR-COMPONENTS ")) {
        const source = line["CLEAR-COMPONENTS ".len..];
        const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
        surface.clearComponents(source) catch {};
        return "OK\n";
    }

    if (std.mem.startsWith(u8, line, "RENAME-TAB ")) {
        const name = line["RENAME-TAB ".len..];
        const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
        surface.session.setName(name) catch return "ERR alloc failed\n";
        surface.refreshStatusBar() catch {};
        return "OK\n";
    }

    return "ERR unknown command\n";
}

/// Write a JSON-escaped string (handles ", \, and control characters).
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try std.fmt.format(w, "\\u{x:0>4}", .{ch});
            },
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');
}

/// GET-STATUS-BAR: returns the current status bar text for the focused surface.
fn getStatusBar(self: *ControlSocket, buf: []u8) []const u8 {
    const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    surface.renderer_state.mutex.lock();
    defer surface.renderer_state.mutex.unlock();

    if (surface.renderer_state.status_bar) |sb| {
        w.writeAll(sb.left) catch return "ERR buffer overflow\n";
        w.writeByte('\n') catch return "ERR buffer overflow\n";
    } else {
        w.writeAll("(none)\n") catch return "ERR buffer overflow\n";
    }
    return fbs.getWritten();
}

/// LIST-TABS: returns JSON array of tab info.
/// Format: [{"index":0,"title":"zsh","active":true}, ...]
fn listTabs(self: *ControlSocket, buf: []u8) []const u8 {
    const focused = self.surface_fn(self.app);
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeByte('[') catch return "ERR buffer overflow\n";

    for (self.app.surfaces.items, 0..) |surf, i| {
        const core = &surf.core_surface;
        const label = core.session.displayLabel();
        const is_active = if (focused) |f| (core == f) else false;

        if (i > 0) w.writeByte(',') catch return "ERR buffer overflow\n";
        std.fmt.format(w, "{{\"index\":{d},\"title\":", .{i}) catch return "ERR buffer overflow\n";
        writeJsonString(w, label) catch return "ERR buffer overflow\n";
        std.fmt.format(w, ",\"active\":{s}}}", .{
            if (is_active) "true" else "false",
        }) catch return "ERR buffer overflow\n";
    }

    w.writeAll("]\n") catch return "ERR buffer overflow\n";
    return fbs.getWritten();
}

/// GET-FOCUSED: returns JSON with focused tab info.
fn getFocused(self: *ControlSocket, buf: []u8) []const u8 {
    const surface = self.surface_fn(self.app) orelse return "ERR no focused surface\n";

    // Find the index of the focused surface
    var idx: usize = 0;
    for (self.app.surfaces.items, 0..) |surf, i| {
        if (&surf.core_surface == surface) {
            idx = i;
            break;
        }
    }

    const info = surface.session.getInfo();
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    std.fmt.format(w, "{{\"index\":{d},\"id\":{d},\"name\":", .{ idx, info.id }) catch return "ERR buffer overflow\n";
    writeJsonString(w, info.name orelse "") catch return "ERR buffer overflow\n";
    w.writeAll(",\"title\":") catch return "ERR buffer overflow\n";
    writeJsonString(w, info.title orelse "") catch return "ERR buffer overflow\n";
    std.fmt.format(w, ",\"tabs\":{d}}}\n", .{
        self.app.surfaces.items.len,
    }) catch return "ERR buffer overflow\n";
    return fbs.getWritten();
}

// ── JSON Component Parsing ──

const ParsedComponents = struct {
    zone: []const u8,
    source: []const u8,
    items: []Component,
};

fn parseComponents(alloc: Allocator, json: []const u8) !ParsedComponents {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const zone = (root.get("zone") orelse return error.MissingField).string;
    const source = (root.get("source") orelse return error.MissingField).string;
    const comps_arr = (root.get("components") orelse return error.MissingField).array;

    var items = try alloc.alloc(Component, comps_arr.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*c| c.deinit(alloc);
        alloc.free(items);
    }

    for (comps_arr.items, 0..) |item, i| {
        items[i] = try parseOneComponent(alloc, item);
        initialized += 1;
    }

    const zone_dup = try alloc.dupe(u8, zone);
    errdefer alloc.free(zone_dup);
    const source_dup = try alloc.dupe(u8, source);

    return .{
        .zone = zone_dup,
        .source = source_dup,
        .items = items,
    };
}

fn parseOneComponent(alloc: Allocator, val: std.json.Value) !Component {
    const obj = val.object;
    const text = try alloc.dupe(u8, (obj.get("text") orelse return error.MissingField).string);
    errdefer alloc.free(text);

    var style: Component.ComponentStyle = .{};
    if (obj.get("style")) |style_val| {
        const so = style_val.object;
        if (so.get("fg")) |fg| style.fg = parseHexColor(fg.string);
        if (so.get("bg")) |bg| style.bg = parseHexColor(bg.string);
        if (so.get("bold")) |b| style.bold = b.bool;
        if (so.get("italic")) |b| style.italic = b.bool;
        if (so.get("underline")) |b| style.underline = b.bool;
        if (so.get("strikethrough")) |b| style.strikethrough = b.bool;
    }

    var click: ?Component.ClickAction = null;
    if (obj.get("click")) |click_val| {
        const co = click_val.object;
        const id = try alloc.dupe(u8, (co.get("id") orelse return error.MissingField).string);
        errdefer alloc.free(id);
        const action_str = (co.get("action") orelse return error.MissingField).string;

        const action: Component.ClickAction.Action = if (std.mem.eql(u8, action_str, "notify"))
            .notify
        else if (std.mem.startsWith(u8, action_str, "key:")) blk: {
            const k = try alloc.dupe(u8, action_str["key:".len..]);
            errdefer alloc.free(k);
            break :blk .{ .key = k };
        } else if (std.mem.startsWith(u8, action_str, "cmd:")) blk: {
            const c = try alloc.dupe(u8, action_str["cmd:".len..]);
            errdefer alloc.free(c);
            break :blk .{ .cmd = c };
        } else
            .notify;

        click = .{ .id = id, .action = action };
    }

    const priority: u8 = if (obj.get("priority")) |p|
        @intCast(p.integer)
    else
        100;

    return .{ .text = text, .style = style, .click = click, .priority = priority };
}

fn parseHexColor(s: []const u8) ?[3]u8 {
    if (s.len != 7 or s[0] != '#') return null;
    return .{
        std.fmt.parseInt(u8, s[1..3], 16) catch return null,
        std.fmt.parseInt(u8, s[3..5], 16) catch return null,
        std.fmt.parseInt(u8, s[5..7], 16) catch return null,
    };
}

fn freeComponents(alloc: Allocator, items: []Component) void {
    for (items) |*c| c.deinit(alloc);
    alloc.free(items);
}

/// Dispatch a click event to the subscriber for the given source.
/// Called from Surface when a component with action=notify is clicked.
pub fn dispatchClick(self: *ControlSocket, source_id: []const u8, click_id: []const u8) void {
    self.click_mutex.lock();
    defer self.click_mutex.unlock();

    const fd = self.click_subscribers.get(source_id) orelse return;

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "CLICK {s}\n", .{click_id}) catch return;
    _ = posix.write(fd, msg) catch |err| {
        // Subscriber disconnected — clean up
        log.info("click subscriber disconnected: {s} err={}", .{ source_id, err });
        if (self.click_subscribers.fetchRemove(source_id)) |kv| {
            posix.close(kv.value);
            self.alloc.free(kv.key);
        }
    };
}
