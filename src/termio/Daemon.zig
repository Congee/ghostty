//! Daemon backend for termio. Connects to a ghostty-daemon via Unix or TCP
//! socket, sends input/resize, and receives cell data (FULL_STATE/DELTA).
//! The received cell data is fed into the terminal as rendered text.
const Daemon = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Protocol = @import("gsp");

const log = std.log.scoped(.io_daemon);

alloc: Allocator,
/// Connection file descriptor to the daemon.
fd: posix.socket_t,
/// Auth key for HMAC challenge-response (empty = no auth).
auth_key: []const u8,
/// Session ID we're attached to (0 = not yet attached).
attached_session_id: u32 = 0,
/// Reader thread handle.
reader_thread: ?std.Thread = null,
/// Whether the reader should keep running.
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
/// The termio instance (set during threadEnter).
io: ?*termio.Termio = null,
/// Mutex for write-side serialization (header+payload must be atomic).
write_mutex: std.Thread.Mutex = .{},

pub const Config = struct {
    /// Daemon address: "unix:/path" or "tcp:host:port"
    address: []const u8,
    /// Auth key (empty = no auth).
    auth_key: []const u8 = "",
};

pub const ThreadData = struct {
    pub fn deinit(_: *ThreadData, _: Allocator) void {}
    pub fn changeConfig(_: *ThreadData, _: *termio.DerivedConfig) void {}
};

pub fn init(alloc: Allocator, cfg: Config) !Daemon {
    const fd = try connectToDaemon(cfg.address);
    errdefer posix.close(fd);

    // Authenticate if needed
    if (cfg.auth_key.len > 0) {
        try authenticate(alloc, fd, cfg.auth_key);
    }

    const auth_key = if (cfg.auth_key.len > 0)
        try alloc.dupe(u8, cfg.auth_key)
    else
        "";
    errdefer if (auth_key.len > 0) alloc.free(auth_key);

    return .{
        .alloc = alloc,
        .fd = fd,
        .auth_key = auth_key,
    };
}

pub fn deinit(self: *Daemon) void {
    self.running.store(false, .release);
    posix.close(self.fd);
    if (self.reader_thread) |t| {
        t.join();
        self.reader_thread = null;
    }
    if (self.auth_key.len > 0) self.alloc.free(self.auth_key);
}

pub fn initTerminal(_: *Daemon, _: *terminal.Terminal) void {}

pub fn threadEnter(
    self: *Daemon,
    _: Allocator,
    io: *termio.Termio,
    _: *termio.Termio.ThreadData,
) !void {
    self.io = io;

    // Create a session on the daemon
    var create_payload: [4]u8 = undefined;
    const cols: u16 = io.terminal.cols;
    const rows: u16 = io.terminal.rows;
    std.mem.writeInt(u16, create_payload[0..2], cols, .little);
    std.mem.writeInt(u16, create_payload[2..4], rows, .little);
    try self.sendMessageLocked(.create, &create_payload);

    // Read response — should be session_created (no reader thread yet, safe)
    var msg = try readMessage(self.alloc, self.fd);
    defer self.alloc.free(msg.payload_buf);
    if (msg.msg_type == .session_created and msg.payload.len >= 4) {
        self.attached_session_id = std.mem.readInt(u32, msg.payload[0..4], .little);
        log.info("created session id={}", .{self.attached_session_id});

        // Attach to it
        var attach_payload: [4]u8 = undefined;
        std.mem.writeInt(u32, attach_payload[0..4], self.attached_session_id, .little);
        try self.sendMessageLocked(.attach, &attach_payload);
    } else if (msg.msg_type == .error_msg) {
        log.err("daemon error: {s}", .{msg.payload});
        return error.DaemonError;
    }

    // Start the reader thread to receive FULL_STATE/DELTA
    self.running.store(true, .release);
    self.reader_thread = try std.Thread.spawn(.{}, readerThread, .{self});
    self.reader_thread.?.setName("daemon-rx") catch {};
}

pub fn threadReenter(self: *Daemon, _: Allocator, _: *termio.Termio, _: *termio.Termio.ThreadData) !void {
    _ = self;
}

pub fn threadExit(self: *Daemon, _: *termio.Termio.ThreadData) void {
    self.running.store(false, .release);
}

pub fn threadPark(self: *Daemon, _: *termio.Termio.ThreadData) void {
    _ = self;
}

pub fn focusGained(_: *Daemon, _: *termio.Termio.ThreadData, _: bool) !void {}

pub fn resize(self: *Daemon, grid_size: renderer.GridSize, _: renderer.ScreenSize) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], grid_size.columns, .little);
    std.mem.writeInt(u16, payload[2..4], grid_size.rows, .little);
    self.sendMessageLocked(.resize, &payload) catch |err| {
        log.warn("resize send failed: {}", .{err});
    };
}

pub fn queueWrite(
    self: *Daemon,
    _: Allocator,
    _: *termio.Termio.ThreadData,
    data: []const u8,
    _: bool,
) !void {
    self.sendMessageLocked(.input, data) catch |err| {
        log.warn("input send failed: {}", .{err});
    };
}

pub fn childExitedAbnormally(_: *Daemon, _: Allocator, _: *terminal.Terminal, _: u32, _: u64) !void {}

// ── Reader Thread ──

fn readerThread(self: *Daemon) void {
    log.info("daemon reader thread started", .{});
    while (self.running.load(.acquire)) {
        const msg = readMessage(self.alloc, self.fd) catch |err| {
            if (!self.running.load(.acquire)) return;
            log.warn("read error: {}", .{err});
            return;
        };
        defer self.alloc.free(msg.payload_buf);

        switch (msg.msg_type) {
            .attached => log.info("attached to session", .{}),
            .full_state => self.applyFullState(msg.payload),
            .delta => self.applyDelta(msg.payload),
            .session_exited => {
                log.info("session exited", .{});
                return;
            },
            .detached => {
                log.info("detached from session", .{});
                return;
            },
            .error_msg => log.err("daemon error: {s}", .{msg.payload}),
            else => log.debug("unhandled message type: {}", .{msg.msg_type}),
        }
    }
}

fn applyFullState(self: *Daemon, payload: []const u8) void {
    // Header: rows(2) + cols(2) + cursor_x(2) + cursor_y(2) + cursor_visible(1) + padding(3)
    if (payload.len < 12) return;
    const io = self.io orelse return;

    const rows = std.mem.readInt(u16, payload[0..2], .little);
    const cols = std.mem.readInt(u16, payload[2..4], .little);
    const cursor_x = std.mem.readInt(u16, payload[4..6], .little);
    const cursor_y = std.mem.readInt(u16, payload[6..8], .little);
    const cursor_visible = payload[8] != 0;

    const cell_count = @as(usize, rows) * @as(usize, cols);
    const expected = 12 + cell_count * 12;
    if (payload.len < expected) return;

    // Write cells into the terminal
    io.renderer_state.mutex.lock();
    defer io.renderer_state.mutex.unlock();
    const t: *terminal.Terminal = io.renderer_state.terminal;

    // Clear and write each cell
    t.eraseDisplay(.complete, false);
    t.modes.set(.cursor_visible, cursor_visible);

    var offset: usize = 12;
    var row: u16 = 0;
    while (row < rows and row < t.rows) : (row += 1) {
        t.setCursorPos(row + 1, 1);
        var col: u16 = 0;
        while (col < cols and col < t.cols) : (col += 1) {
            const base = offset;
            const cp = std.mem.readInt(u32, payload[base..][0..4], .little);
            if (cp >= 0x20) {
                t.print(@intCast(cp)) catch |err| {
                    log.debug("terminal print error cp=0x{x}: {}", .{ cp, err });
                };
            }
            offset += 12;
        }
    }
    t.setCursorPos(cursor_y + 1, cursor_x + 1);

    io.renderer_wakeup.notify() catch {};
}

fn applyDelta(self: *Daemon, payload: []const u8) void {
    if (payload.len < 8) return;
    const io = self.io orelse return;

    const cursor_x = std.mem.readInt(u16, payload[2..4], .little);
    const cursor_y = std.mem.readInt(u16, payload[4..6], .little);
    const cursor_visible = payload[6] != 0;
    const num_rows = std.mem.readInt(u16, payload[0..2], .little);

    io.renderer_state.mutex.lock();
    defer io.renderer_state.mutex.unlock();
    const t: *terminal.Terminal = io.renderer_state.terminal;

    t.modes.set(.cursor_visible, cursor_visible);

    var offset: usize = 8;
    var i: u16 = 0;
    while (i < num_rows) : (i += 1) {
        if (offset + 4 > payload.len) break;
        const row_idx = std.mem.readInt(u16, payload[offset..][0..2], .little);
        const num_cols = std.mem.readInt(u16, payload[offset + 2 ..][0..2], .little);
        offset += 4;

        const row_bytes = @as(usize, num_cols) * 12;
        if (offset + row_bytes > payload.len) break;

        t.setCursorPos(row_idx + 1, 1);
        // Erase the row
        t.eraseLine(.complete, false);

        var col: u16 = 0;
        while (col < num_cols) : (col += 1) {
            const base = offset + @as(usize, col) * 12;
            const cp = std.mem.readInt(u32, payload[base..][0..4], .little);
            if (cp >= 0x20) {
                t.print(@intCast(cp)) catch |err| {
                    log.debug("terminal print error cp=0x{x}: {}", .{ cp, err });
                };
            } else {
                // Blank cell — print space to advance cursor (cheaper than setCursorPos)
                t.print(' ') catch {};
            }
        }
        offset += row_bytes;
    }
    t.setCursorPos(cursor_y + 1, cursor_x + 1);

    io.renderer_wakeup.notify() catch {};
}

// ── Protocol Helpers ──

const Message = struct {
    msg_type: Protocol.MessageType,
    payload: []const u8,
    /// The backing allocation (may be larger than payload). Free with alloc.free().
    /// Empty slice means no allocation (zero-length payload).
    payload_buf: []u8,
};

/// Send a message with write-side mutex held (safe for concurrent callers).
fn sendMessageLocked(self: *Daemon, msg_type: Protocol.MessageType, payload: []const u8) !void {
    self.write_mutex.lock();
    defer self.write_mutex.unlock();
    try sendMessage(self.fd, msg_type, payload);
}

fn sendMessage(fd: posix.socket_t, msg_type: Protocol.MessageType, payload: []const u8) !void {
    // Build header + payload into a single buffer to avoid interleaving
    var header: [Protocol.header_len]u8 = undefined;
    header[0] = Protocol.magic[0];
    header[1] = Protocol.magic[1];
    header[2] = @intFromEnum(msg_type);
    std.mem.writeInt(u32, header[3..7], @intCast(payload.len), .little);

    _ = try posix.write(fd, &header);
    if (payload.len > 0) {
        _ = try posix.write(fd, payload);
    }
}

fn readMessage(alloc: Allocator, fd: posix.socket_t) !Message {
    var header: [Protocol.header_len]u8 = undefined;
    try readExact(fd, &header);

    if (header[0] != Protocol.magic[0] or header[1] != Protocol.magic[1]) {
        return error.InvalidMagic;
    }

    const msg_type: Protocol.MessageType = @enumFromInt(header[2]);
    const payload_len = std.mem.readInt(u32, header[3..7], .little);

    if (payload_len == 0) {
        return .{ .msg_type = msg_type, .payload = &.{}, .payload_buf = &.{} };
    }

    if (payload_len > Protocol.max_payload_len) return error.PayloadTooLarge;
    const buf = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(buf);
    try readExact(fd, buf);

    return .{ .msg_type = msg_type, .payload = buf, .payload_buf = buf };
}

fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch |err| {
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

fn connectToDaemon(address: []const u8) !posix.socket_t {
    if (std.mem.startsWith(u8, address, "unix:")) {
        const path = address["unix:".len..];
        return connectUnix(path);
    } else if (std.mem.startsWith(u8, address, "tcp:")) {
        const addr_str = address["tcp:".len..];
        return connectTcp(addr_str);
    } else {
        // Default: treat as unix path
        return connectUnix(address);
    }
}

fn connectUnix(path: []const u8) !posix.socket_t {
    const addr = try std.net.Address.initUnix(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    log.info("connected to daemon at {s}", .{path});
    return fd;
}

fn connectTcp(addr_str: []const u8) !posix.socket_t {
    // Parse "host:port"
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.InvalidAddress;
    const host = addr_str[0..colon];
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch return error.InvalidPort;

    const addr_list = try std.net.Address.resolveIp(host, port);
    const fd = try posix.socket(addr_list.any.family, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr_list.any, addr_list.getOsSockLen());
    log.info("connected to daemon at {s}:{}", .{ host, port });
    return fd;
}

fn authenticate(alloc: Allocator, fd: posix.socket_t, auth_key: []const u8) !void {
    // Send empty AUTH to request challenge
    try sendMessage(fd, .auth, &.{});

    // Read challenge
    const msg = try readMessage(alloc, fd);
    defer alloc.free(msg.payload_buf);
    if (msg.msg_type != .auth_challenge or msg.payload.len != Protocol.challenge_len) {
        return error.AuthFailed;
    }

    // Compute HMAC-SHA256
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, msg.payload, auth_key);

    // Send HMAC response
    try sendMessage(fd, .auth, &mac);

    // Read result
    const result = try readMessage(alloc, fd);
    defer alloc.free(result.payload_buf);
    if (result.msg_type != .auth_ok) {
        return error.AuthFailed;
    }

    log.info("authenticated with daemon", .{});
}
