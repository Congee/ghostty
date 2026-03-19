//! Handles a single client connected to the daemon. Processes GSP messages
//! from the client and sends back screen state (full state on attach,
//! deltas on changes).
const ClientConnection = @This();

const std = @import("std");
const posix = std.posix;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const Protocol = @import("gsp");
const SessionManager = @import("SessionManager.zig");
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;

const log = std.log.scoped(.client_conn);

alloc: Allocator,
fd: posix.socket_t,
session_mgr: *SessionManager,

/// The session this client is currently attached to (null = not attached).
attached_session_id: ?u32 = null,

/// Auth state.
authenticated: bool,

/// Pre-shared key for auth (empty = no auth required).
auth_key: []const u8,

/// Server-generated challenge nonce for HMAC auth.
challenge: [Protocol.challenge_len]u8 = undefined,
challenge_sent: bool = false,

pub fn init(
    alloc: Allocator,
    fd: posix.socket_t,
    session_mgr: *SessionManager,
    auth_key: []const u8,
) ClientConnection {
    return .{
        .alloc = alloc,
        .fd = fd,
        .session_mgr = session_mgr,
        .attached_session_id = null,
        .authenticated = auth_key.len == 0, // No key = pre-authenticated
        .auth_key = auth_key,
    };
}

/// Main loop: read messages, process them, send responses.
/// Returns when the client disconnects or encounters an error.
pub fn run(self: *ClientConnection) void {
    log.info("client connected fd={}", .{self.fd});
    defer {
        self.detachIfAttached();
        log.info("client disconnected fd={}", .{self.fd});
    }

    while (true) {
        var msg = Protocol.readMessage(self.alloc, self.fd) catch |err| {
            switch (err) {
                error.ConnectionClosed => return,
                else => {
                    log.warn("read error fd={}: {}", .{ self.fd, err });
                    return;
                },
            }
        };
        defer if (msg.payload.len > 0) self.alloc.free(msg.payload);

        self.handleMessage(&msg) catch |err| {
            log.warn("handle error fd={}: {}", .{ self.fd, err });
            self.sendError("internal error") catch return;
        };
    }
}

fn handleMessage(self: *ClientConnection, msg: *Protocol.Message) !void {
    // Auth gate: only AUTH and PING allowed before authentication
    if (!self.authenticated) {
        switch (msg.msg_type) {
            .auth => return self.handleAuth(msg.payload),
            else => {
                try self.sendError("not authenticated");
                return;
            },
        }
    }

    switch (msg.msg_type) {
        .auth => try self.handleAuth(msg.payload),
        .list_sessions => try self.handleListSessions(),
        .create => try self.handleCreate(msg.payload),
        .attach => try self.handleAttach(msg.payload),
        .detach => self.handleDetach(),
        .input => try self.handleInput(msg.payload),
        .resize => try self.handleResize(msg.payload),
        .destroy => try self.handleDestroy(msg.payload),
        .scroll => try self.handleScroll(msg.payload),
        else => try self.sendError("unexpected message type"),
    }
}

fn handleAuth(self: *ClientConnection, payload: []const u8) !void {
    if (self.auth_key.len == 0) {
        // No auth required
        self.authenticated = true;
        try self.sendEmpty(.auth_ok);
        return;
    }

    if (!self.challenge_sent) {
        // Step 1: Generate and send challenge nonce.
        // Accept both plaintext key (legacy) and empty payload (HMAC flow).
        // If the client sent the correct plaintext key, accept it directly
        // for backward compatibility.
        if (constTimeEqlSlice(payload, self.auth_key)) {
            self.authenticated = true;
            log.info("client authenticated (plaintext) fd={}", .{self.fd});
            try self.sendEmpty(.auth_ok);
            return;
        }

        // Generate random challenge
        crypto.random.bytes(&self.challenge);
        self.challenge_sent = true;

        const encoded = try Protocol.encode(self.alloc, .auth_challenge, &self.challenge);
        defer self.alloc.free(encoded);
        try Protocol.writeMessage(self.fd, encoded);
        return;
    }

    // Step 2: Verify HMAC response.
    if (payload.len != Protocol.hmac_len) {
        log.warn("auth failed (bad hmac length {}) fd={}", .{ payload.len, self.fd });
        self.challenge_sent = false;
        try self.sendEmpty(.auth_fail);
        return;
    }

    // Compute expected HMAC: HMAC-SHA256(key, challenge)
    var expected: [Protocol.hmac_len]u8 = undefined;
    HmacSha256.create(&expected, &self.challenge, self.auth_key);

    if (crypto.timing_safe.eql([Protocol.hmac_len]u8, payload[0..Protocol.hmac_len].*, expected)) {
        self.authenticated = true;
        log.info("client authenticated (HMAC) fd={}", .{self.fd});
        try self.sendEmpty(.auth_ok);
    } else {
        log.warn("auth failed (HMAC mismatch) fd={}", .{self.fd});
        self.challenge_sent = false;
        try self.sendEmpty(.auth_fail);
    }
}

fn handleListSessions(self: *ClientConnection) !void {
    self.session_mgr.lock();
    const entries = self.session_mgr.listSessions(self.alloc) catch |err| {
        self.session_mgr.unlock();
        return err;
    };
    self.session_mgr.unlock();
    defer SessionManager.freeSessionEntries(self.alloc, entries);

    const encoded = try Protocol.encodeSessionList(self.alloc, entries);
    defer self.alloc.free(encoded);

    try Protocol.writeMessage(self.fd, encoded);
}

fn handleCreate(self: *ClientConnection, payload: []const u8) !void {
    // Default dimensions if not specified
    var cols: u16 = 80;
    var rows: u16 = 24;
    var command: ?[]const u8 = null;

    // Parse: cols(2) + rows(2) + command_len(2) + command
    if (payload.len >= 4) {
        cols = std.mem.readInt(u16, payload[0..2], .little);
        rows = std.mem.readInt(u16, payload[2..4], .little);
        if (cols == 0) cols = 80;
        if (rows == 0) rows = 24;

        if (payload.len >= 6) {
            const cmd_len = std.mem.readInt(u16, payload[4..6], .little);
            if (cmd_len > 0 and payload.len >= 6 + cmd_len) {
                command = payload[6..][0..cmd_len];
            }
        }
    }

    self.session_mgr.lock();
    const session = self.session_mgr.createSession(cols, rows, command) catch |err| {
        self.session_mgr.unlock();
        log.err("create session failed: {}", .{err});
        try self.sendError("failed to create session");
        return;
    };
    self.session_mgr.unlock();

    // Send session_created with the session ID
    const encoded = try Protocol.encodeU32(self.alloc, .session_created, session.id);
    defer self.alloc.free(encoded);
    try Protocol.writeMessage(self.fd, encoded);
}

fn handleAttach(self: *ClientConnection, payload: []const u8) !void {
    if (payload.len < 4) {
        try self.sendError("invalid attach payload");
        return;
    }

    const session_id = std.mem.readInt(u32, payload[0..4], .little);

    // Detach from current session first
    self.detachIfAttached();

    self.session_mgr.lock();
    const session = self.session_mgr.getSession(session_id) orelse {
        self.session_mgr.unlock();
        try self.sendError("session not found");
        return;
    };

    session.attached = true;
    self.attached_session_id = session_id;

    // Wire up delta pushing — PTY reader will send deltas to this client
    self.session_mgr.setSessionClientFd(session_id, self.fd);

    // Serialize full state while holding lock
    session.markAllDirty();
    const full_state = session.serializeFullState(self.alloc) catch |err| {
        self.session_mgr.unlock();
        return err;
    };
    session.clearDirty();
    self.session_mgr.unlock();
    defer self.alloc.free(full_state);

    // Send ATTACHED confirmation
    try self.sendEmpty(.attached);

    // Send full state
    const encoded = try Protocol.encode(self.alloc, .full_state, full_state);
    defer self.alloc.free(encoded);
    try Protocol.writeMessage(self.fd, encoded);

    log.info("client attached to session {} fd={}", .{ session_id, self.fd });
}

fn handleDetach(self: *ClientConnection) void {
    self.detachIfAttached();
}

fn handleInput(self: *ClientConnection, payload: []const u8) !void {
    const session_id = self.attached_session_id orelse {
        try self.sendError("not attached");
        return;
    };

    self.session_mgr.lock();
    self.session_mgr.writeInput(session_id, payload) catch |err| {
        self.session_mgr.unlock();
        log.warn("write input failed: {}", .{err});
        try self.sendError("write failed");
        return;
    };
    self.session_mgr.unlock();
}

fn handleResize(self: *ClientConnection, payload: []const u8) !void {
    if (payload.len < 4) {
        try self.sendError("invalid resize payload");
        return;
    }

    const session_id = self.attached_session_id orelse {
        try self.sendError("not attached");
        return;
    };

    const cols = std.mem.readInt(u16, payload[0..2], .little);
    const rows = std.mem.readInt(u16, payload[2..4], .little);

    self.session_mgr.lock();
    self.session_mgr.resizeSession(session_id, cols, rows) catch |err| {
        self.session_mgr.unlock();
        log.warn("resize failed: {}", .{err});
        try self.sendError("resize failed");
        return;
    };
    self.session_mgr.unlock();
}

fn handleDestroy(self: *ClientConnection, payload: []const u8) !void {
    if (payload.len < 4) {
        try self.sendError("invalid destroy payload");
        return;
    }

    const session_id = std.mem.readInt(u32, payload[0..4], .little);

    // If we're attached to this session, detach first (clears PTY reader fd)
    if (self.attached_session_id) |id| {
        if (id == session_id) {
            self.detachIfAttached();
        }
    }

    self.session_mgr.lock();
    const destroyed = self.session_mgr.destroySession(session_id);
    self.session_mgr.unlock();

    if (destroyed) {
        try self.sendEmpty(.detached);
    } else {
        try self.sendError("session not found");
    }
}

fn handleScroll(self: *ClientConnection, payload: []const u8) !void {
    _ = payload;
    // Scrollback is managed by the terminal emulator internally.
    // TODO: implement scrollback serialization from terminal.PageList
    try self.sendEmpty(.scroll_data);
}

// ── Helpers ──

fn detachIfAttached(self: *ClientConnection) void {
    if (self.attached_session_id) |id| {
        self.session_mgr.lock();
        if (self.session_mgr.getSession(id)) |session| {
            session.attached = false;
        }
        // Clear delta push fd
        self.session_mgr.setSessionClientFd(id, -1);
        self.session_mgr.unlock();
        self.attached_session_id = null;
        log.info("client detached from session {} fd={}", .{ id, self.fd });
    }
}

/// Constant-time comparison of variable-length slices via HMAC.
/// Both inputs are always hashed regardless of length to avoid leaking
/// length information through timing.
fn constTimeEqlSlice(a: []const u8, b: []const u8) bool {
    var ha: [HmacSha256.mac_length]u8 = undefined;
    var hb: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&ha, a, "ghostty-auth-cmp");
    HmacSha256.create(&hb, b, "ghostty-auth-cmp");
    return crypto.timing_safe.eql([HmacSha256.mac_length]u8, ha, hb);
}

fn sendEmpty(self: *ClientConnection, msg_type: Protocol.MessageType) !void {
    const encoded = try Protocol.encodeEmpty(self.alloc, msg_type);
    defer self.alloc.free(encoded);
    try Protocol.writeMessage(self.fd, encoded);
}

fn sendError(self: *ClientConnection, err_msg: []const u8) !void {
    const encoded = try Protocol.encode(self.alloc, .error_msg, err_msg);
    defer self.alloc.free(encoded);
    try Protocol.writeMessage(self.fd, encoded);
}

/// Send a delta update to the client for the currently attached session.
/// Called by the daemon's render loop. Returns false if no session attached
/// or nothing changed.
pub fn sendDelta(self: *ClientConnection) !bool {
    const session_id = self.attached_session_id orelse return false;
    const session = self.session_mgr.getSession(session_id) orelse return false;

    const payload = try session.serializeDelta(self.alloc) orelse return false;
    defer self.alloc.free(payload);

    const encoded = try Protocol.encode(self.alloc, .delta, payload);
    defer self.alloc.free(encoded);
    try Protocol.writeMessage(self.fd, encoded);

    return true;
}

// ── Tests ──

test "ClientConnection init — no auth required" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.init(alloc);
    defer mgr.deinit();

    // Use an invalid fd since we won't actually do I/O in this test
    const conn = ClientConnection.init(alloc, -1, &mgr, "");
    try std.testing.expect(conn.authenticated);
    try std.testing.expect(conn.attached_session_id == null);
}

test "ClientConnection init — auth required" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.init(alloc);
    defer mgr.deinit();

    const conn = ClientConnection.init(alloc, -1, &mgr, "secret");
    try std.testing.expect(!conn.authenticated);
}
