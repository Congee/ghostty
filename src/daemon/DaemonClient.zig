//! Client library for connecting to a ghostty-daemon. This provides the
//! API that Surface.zig (or any other consumer) uses to interact with
//! remote terminal sessions.
//!
//! Usage:
//!   var client = try DaemonClient.connect(alloc, "unix:/tmp/ghostty-daemon.sock", "");
//!   defer client.disconnect();
//!   const id = try client.createSession(80, 24, null);
//!   try client.attach(id);
//!   // client.screen now has the full cell grid
//!   try client.sendInput("ls\r");
//!   // Poll for updates:
//!   while (try client.pollUpdate(100)) {}
const DaemonClient = @This();

const std = @import("std");
const posix = std.posix;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const Protocol = @import("gsp");
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;

const log = std.log.scoped(.daemon_client);

alloc: Allocator,
fd: posix.socket_t = -1,
authenticated: bool = false,

/// The currently attached session id (null = not attached).
attached_session_id: ?u32 = null,

/// Local cell grid — populated by FULL_STATE and DELTA messages.
screen: ?Screen = null,

pub const Screen = struct {
    rows: u16,
    cols: u16,
    cells: []Protocol.WireCell,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_visible: bool = true,

    pub fn getCell(self: *const Screen, col: u16, row: u16) Protocol.WireCell {
        return self.cells[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }
};

/// Connect to a daemon at the given address. Handles auth if key is non-empty.
pub fn connect(alloc: Allocator, addr: []const u8, auth_key: []const u8) !DaemonClient {
    var client: DaemonClient = .{ .alloc = alloc };

    if (std.mem.startsWith(u8, addr, "unix:")) {
        const path = addr["unix:".len..];
        const sock_addr = try std.net.Address.initUnix(path);
        client.fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(client.fd);
        try posix.connect(client.fd, &sock_addr.any, sock_addr.getOsSockLen());
    } else if (std.mem.startsWith(u8, addr, "tcp:")) {
        const addr_str = addr["tcp:".len..];
        const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.InvalidAddress;
        const host = addr_str[0..colon];
        const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch return error.InvalidAddress;
        const sock_addr = try std.net.Address.parseIp4(host, port);
        client.fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(client.fd);
        try posix.connect(client.fd, &sock_addr.any, sock_addr.getOsSockLen());
    } else {
        return error.InvalidAddress;
    }

    // Authenticate via HMAC challenge-response if key provided
    if (auth_key.len > 0) {
        // Step 1: Send AUTH with empty payload to request challenge
        const auth_msg = try Protocol.encodeEmpty(alloc, .auth);
        defer alloc.free(auth_msg);
        try Protocol.writeMessage(client.fd, auth_msg);

        // Step 2: Read challenge nonce
        var challenge_resp = try Protocol.readMessage(alloc, client.fd);
        defer challenge_resp.deinit(alloc);
        if (challenge_resp.msg_type != .auth_challenge or
            challenge_resp.payload.len != Protocol.challenge_len)
        {
            return error.AuthFailed;
        }

        // Step 3: Compute HMAC-SHA256(key, challenge) and send
        var hmac_out: [Protocol.hmac_len]u8 = undefined;
        HmacSha256.create(&hmac_out, challenge_resp.payload, auth_key);

        const hmac_msg = try Protocol.encode(alloc, .auth, &hmac_out);
        defer alloc.free(hmac_msg);
        try Protocol.writeMessage(client.fd, hmac_msg);

        // Step 4: Read auth result
        var auth_result = try Protocol.readMessage(alloc, client.fd);
        defer auth_result.deinit(alloc);
        if (auth_result.msg_type != .auth_ok) return error.AuthFailed;
    }
    client.authenticated = true;

    log.info("connected to daemon at {s}", .{addr});
    return client;
}

/// Disconnect from the daemon.
pub fn disconnect(self: *DaemonClient) void {
    if (self.screen) |*s| {
        self.alloc.free(s.cells);
        self.screen = null;
    }
    if (self.fd >= 0) {
        posix.close(self.fd);
        self.fd = -1;
    }
}

/// List all sessions on the daemon.
pub fn listSessions(self: *DaemonClient) ![]Protocol.SessionEntry {
    const msg = try Protocol.encodeEmpty(self.alloc, .list_sessions);
    defer self.alloc.free(msg);
    try Protocol.writeMessage(self.fd, msg);

    var resp = try Protocol.readMessage(self.alloc, self.fd);
    defer resp.deinit(self.alloc);
    if (resp.msg_type != .session_list) return error.UnexpectedResponse;

    return Protocol.decodeSessionList(self.alloc, resp.payload);
}

/// Create a new session. Returns the session id.
pub fn createSession(self: *DaemonClient, cols: u16, rows: u16, command: ?[]const u8) !u32 {
    var payload_buf: [1024]u8 = undefined;
    var payload_len: usize = 4;
    std.mem.writeInt(u16, payload_buf[0..2], cols, .little);
    std.mem.writeInt(u16, payload_buf[2..4], rows, .little);

    if (command) |cmd| {
        if (cmd.len > payload_buf.len - 6) return error.CommandTooLong;
        std.mem.writeInt(u16, payload_buf[4..6], @intCast(cmd.len), .little);
        @memcpy(payload_buf[6..][0..cmd.len], cmd);
        payload_len = 6 + cmd.len;
    }

    const msg = try Protocol.encode(self.alloc, .create, payload_buf[0..payload_len]);
    defer self.alloc.free(msg);
    try Protocol.writeMessage(self.fd, msg);

    var resp = try Protocol.readMessage(self.alloc, self.fd);
    defer resp.deinit(self.alloc);
    if (resp.msg_type != .session_created) return error.CreateFailed;
    if (resp.payload.len < 4) return error.InvalidResponse;

    return std.mem.readInt(u32, resp.payload[0..4], .little);
}

/// Attach to a session. Populates self.screen with full state.
pub fn attach(self: *DaemonClient, session_id: u32) !void {
    const msg = try Protocol.encodeU32(self.alloc, .attach, session_id);
    defer self.alloc.free(msg);
    try Protocol.writeMessage(self.fd, msg);

    // Read ATTACHED confirmation
    var resp1 = try Protocol.readMessage(self.alloc, self.fd);
    defer resp1.deinit(self.alloc);
    if (resp1.msg_type != .attached) return error.AttachFailed;

    // Read FULL_STATE
    var resp2 = try Protocol.readMessage(self.alloc, self.fd);
    defer resp2.deinit(self.alloc);
    if (resp2.msg_type != .full_state) return error.UnexpectedResponse;

    try self.applyFullState(resp2.payload);
    self.attached_session_id = session_id;
}

/// Detach from the current session.
pub fn detach(self: *DaemonClient) !void {
    const msg = try Protocol.encodeEmpty(self.alloc, .detach);
    defer self.alloc.free(msg);
    try Protocol.writeMessage(self.fd, msg);
    self.attached_session_id = null;
}

/// Send keyboard input to the attached session.
pub fn sendInput(self: *DaemonClient, data: []const u8) !void {
    const msg = try Protocol.encode(self.alloc, .input, data);
    defer self.alloc.free(msg);
    try Protocol.writeMessage(self.fd, msg);
}

/// Resize the attached session.
pub fn resize(self: *DaemonClient, cols: u16, rows: u16) !void {
    const msg = try Protocol.encodeResize(self.alloc, cols, rows);
    defer self.alloc.free(msg);
    try Protocol.writeMessage(self.fd, msg);
}

/// Poll for an incoming message (delta, session_exited, etc.).
/// Returns true if a message was processed, false on timeout.
/// timeout_ms = 0 for non-blocking, -1 for infinite wait.
pub fn pollUpdate(self: *DaemonClient, timeout_ms: i32) !bool {
    var pfd = [1]posix.pollfd{.{
        .fd = self.fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const n = try posix.poll(&pfd, timeout_ms);
    if (n == 0) return false;

    if (pfd[0].revents & posix.POLL.HUP != 0) return error.ConnectionClosed;
    if (pfd[0].revents & posix.POLL.IN == 0) return false;

    var msg = try Protocol.readMessage(self.alloc, self.fd);
    defer msg.deinit(self.alloc);

    switch (msg.msg_type) {
        .delta => try self.applyDelta(msg.payload),
        .session_exited => {
            log.info("session exited", .{});
            self.attached_session_id = null;
        },
        .error_msg => {
            log.warn("server error: {s}", .{msg.payload});
        },
        else => {},
    }

    return true;
}

// ── Internal ──

fn applyFullState(self: *DaemonClient, payload: []const u8) !void {
    if (payload.len < Protocol.FullStateHeader.size) return error.InvalidResponse;

    const hdr: *const Protocol.FullStateHeader = @ptrCast(@alignCast(payload.ptr));
    const rows = hdr.rows;
    const cols = hdr.cols;
    const cell_count = @as(usize, rows) * @as(usize, cols);
    const expected = Protocol.FullStateHeader.size + cell_count * Protocol.WireCell.size;

    if (payload.len < expected) return error.InvalidResponse;

    // Allocate or resize screen
    if (self.screen) |*s| {
        if (s.rows != rows or s.cols != cols) {
            self.alloc.free(s.cells);
            s.cells = try self.alloc.alloc(Protocol.WireCell, cell_count);
        }
    } else {
        self.screen = .{
            .rows = rows,
            .cols = cols,
            .cells = try self.alloc.alloc(Protocol.WireCell, cell_count),
        };
    }

    var s = &self.screen.?;
    s.rows = rows;
    s.cols = cols;
    s.cursor_x = hdr.cursor_x;
    s.cursor_y = hdr.cursor_y;
    s.cursor_visible = hdr.cursor_visible != 0;

    // Copy cell data
    const cell_bytes = payload[Protocol.FullStateHeader.size..][0 .. cell_count * Protocol.WireCell.size];
    const cells_ptr: [*]const Protocol.WireCell = @ptrCast(@alignCast(cell_bytes.ptr));
    @memcpy(s.cells, cells_ptr[0..cell_count]);
}

fn applyDelta(self: *DaemonClient, payload: []const u8) !void {
    if (payload.len < Protocol.DeltaHeader.size) return error.InvalidResponse;
    var s = &(self.screen orelse return error.NotAttached);

    const dhdr: *const Protocol.DeltaHeader = @ptrCast(@alignCast(payload.ptr));
    s.cursor_x = dhdr.cursor_x;
    s.cursor_y = dhdr.cursor_y;
    s.cursor_visible = dhdr.cursor_visible != 0;

    var offset: usize = Protocol.DeltaHeader.size;
    for (0..dhdr.num_rows) |_| {
        if (offset + Protocol.DeltaRowHeader.size > payload.len) return error.InvalidResponse;
        const rh: *const Protocol.DeltaRowHeader = @ptrCast(@alignCast(payload.ptr + offset));
        offset += Protocol.DeltaRowHeader.size;

        const row_cells = @as(usize, rh.num_cols) * Protocol.WireCell.size;
        if (offset + row_cells > payload.len) return error.InvalidResponse;

        if (rh.row_index >= s.rows or rh.num_cols > s.cols) return error.InvalidResponse;

        const src: [*]const Protocol.WireCell = @ptrCast(@alignCast(payload.ptr + offset));
        const dst_start = @as(usize, rh.row_index) * @as(usize, s.cols);
        @memcpy(s.cells[dst_start..][0..rh.num_cols], src[0..rh.num_cols]);
        offset += row_cells;
    }
}

// ── Tests ──

test "DaemonClient connect and create session" {
    // This test requires a running daemon, so we use a socket pair for unit testing.
    const alloc = std.testing.allocator;
    const SessionManager = @import("SessionManager.zig");
    const ClientConnection = @import("ClientConnection.zig");

    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const c_sock = @import("integration_test.zig");
    const fds = try c_sock.createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    // Server thread
    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *ClientConnection) void {
            c.run();
        }
    }.run, .{&conn});

    // Use the client library with the raw fd
    var client: DaemonClient = .{
        .alloc = alloc,
        .fd = client_fd,
        .authenticated = true,
    };

    // Create session
    const id = try client.createSession(10, 5, null);
    try std.testing.expectEqual(@as(u32, 1), id);

    // List sessions
    const entries = try client.listSessions();
    defer Protocol.freeSessionList(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);

    // Attach
    try client.attach(id);
    try std.testing.expect(client.screen != null);
    try std.testing.expectEqual(@as(u16, 10), client.screen.?.cols);
    try std.testing.expectEqual(@as(u16, 5), client.screen.?.rows);

    // Detach
    try client.detach();
    try std.testing.expect(client.attached_session_id == null);

    // Clean up — disconnect triggers server to see ConnectionClosed
    client.disconnect();
    client_fd = -1;
    server_thread.join();
}

test "applyFullState parses header and cells" {
    const alloc = std.testing.allocator;
    var client: DaemonClient = .{ .alloc = alloc };
    defer client.disconnect();

    // Build a fake FULL_STATE payload (2x2 grid)
    const hdr = Protocol.FullStateHeader{
        .rows = 2,
        .cols = 2,
        .cursor_x = 1,
        .cursor_y = 0,
        .cursor_visible = 1,
    };
    const cells = [4]Protocol.WireCell{
        .{ .codepoint = 'A' },
        .{ .codepoint = 'B' },
        .{ .codepoint = 'C' },
        .{ .codepoint = 'D' },
    };

    const hdr_bytes: *const [Protocol.FullStateHeader.size]u8 = @ptrCast(&hdr);
    const cell_bytes: *const [4 * Protocol.WireCell.size]u8 = @ptrCast(&cells);

    var payload: [Protocol.FullStateHeader.size + 4 * Protocol.WireCell.size]u8 = undefined;
    @memcpy(payload[0..Protocol.FullStateHeader.size], hdr_bytes);
    @memcpy(payload[Protocol.FullStateHeader.size..], cell_bytes);

    try client.applyFullState(&payload);

    try std.testing.expect(client.screen != null);
    const s = client.screen.?;
    try std.testing.expectEqual(@as(u16, 2), s.rows);
    try std.testing.expectEqual(@as(u16, 2), s.cols);
    try std.testing.expectEqual(@as(u16, 1), s.cursor_x);
    try std.testing.expectEqual(@as(u32, 'A'), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'D'), s.getCell(1, 1).codepoint);
}
