//! Integration tests for the daemon: exercises the full client-server flow
//! over a real Unix socket pair.
const std = @import("std");
const posix = std.posix;
const Protocol = @import("Protocol.zig");
const SessionManager = @import("SessionManager.zig");
const ClientConnection = @import("ClientConnection.zig");

extern "c" fn socketpair(domain: c_int, sock_type: c_int, protocol: c_int, sv: *[2]posix.fd_t) c_int;

/// Create a connected Unix socket pair for testing.
pub fn createSocketPair() ![2]posix.socket_t {
    var fds: [2]posix.fd_t = undefined;
    if (socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) < 0) {
        return error.SocketPairFailed;
    }
    return fds;
}

test "full flow: create session, attach, send input, get full state" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    // Run server side in a thread
    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *ClientConnection) void {
            c.run();
        }
    }.run, .{&conn});

    // Client: send CREATE
    {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], 10, .little); // cols
        std.mem.writeInt(u16, payload[2..4], 5, .little); // rows
        const msg = try Protocol.encode(alloc, .create, &payload);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }

    // Client: read SESSION_CREATED response
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.session_created, resp.msg_type);
        try std.testing.expect(resp.payload.len >= 4);
        const session_id = std.mem.readInt(u32, resp.payload[0..4], .little);
        try std.testing.expectEqual(@as(u32, 1), session_id);
    }

    // Client: send LIST_SESSIONS
    {
        const msg = try Protocol.encodeEmpty(alloc, .list_sessions);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }

    // Client: read SESSION_LIST response
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.session_list, resp.msg_type);

        const entries = try Protocol.decodeSessionList(alloc, resp.payload);
        defer Protocol.freeSessionList(alloc, entries);
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqual(@as(u32, 1), entries[0].id);
    }

    // Client: send ATTACH
    {
        const msg = try Protocol.encodeU32(alloc, .attach, 1);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }

    // Client: read ATTACHED confirmation
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.attached, resp.msg_type);
    }

    // Client: read FULL_STATE
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.full_state, resp.msg_type);

        // Verify full state header
        try std.testing.expect(resp.payload.len >= Protocol.FullStateHeader.size);
        const hdr: *const Protocol.FullStateHeader = @ptrCast(@alignCast(resp.payload.ptr));
        try std.testing.expectEqual(@as(u16, 5), hdr.rows);
        try std.testing.expectEqual(@as(u16, 10), hdr.cols);
    }

    // Client: send DETACH
    {
        const msg = try Protocol.encodeEmpty(alloc, .detach);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }

    // Close client to end server loop
    posix.close(client_fd);
    client_fd = -1; // Prevent double close in defer

    server_thread.join();
}

test "auth flow: plaintext rejected then plaintext accepted" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "mysecret");
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(c_conn: *ClientConnection) void {
            c_conn.run();
        }
    }.run, .{&conn});

    // Try LIST without auth — should get error
    {
        const msg = try Protocol.encodeEmpty(alloc, .list_sessions);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.error_msg, resp.msg_type);
    }

    // Send correct plaintext key (backward compat)
    {
        const msg = try Protocol.encode(alloc, .auth, "mysecret");
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.auth_ok, resp.msg_type);
    }

    // Now LIST should work
    {
        const msg = try Protocol.encodeEmpty(alloc, .list_sessions);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.session_list, resp.msg_type);
    }

    posix.close(client_fd);
    client_fd = -1;
    server_thread.join();
}

test "HMAC challenge-response auth" {
    const alloc = std.testing.allocator;
    const crypto = std.crypto;
    const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "hmac-secret");
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(c_conn: *ClientConnection) void {
            c_conn.run();
        }
    }.run, .{&conn});

    // Step 1: Send AUTH with empty payload to request challenge
    {
        const msg = try Protocol.encodeEmpty(alloc, .auth);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }

    // Step 2: Read challenge
    var challenge: [Protocol.challenge_len]u8 = undefined;
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.auth_challenge, resp.msg_type);
        try std.testing.expectEqual(@as(usize, Protocol.challenge_len), resp.payload.len);
        @memcpy(&challenge, resp.payload[0..Protocol.challenge_len]);
    }

    // Step 3: Compute HMAC with wrong key — should fail
    {
        var bad_hmac: [Protocol.hmac_len]u8 = undefined;
        HmacSha256.create(&bad_hmac, &challenge, "wrong-key");
        const msg = try Protocol.encode(alloc, .auth, &bad_hmac);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.auth_fail, resp.msg_type);
    }

    // Step 4: Request new challenge (old one invalidated)
    {
        const msg = try Protocol.encodeEmpty(alloc, .auth);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.auth_challenge, resp.msg_type);
        @memcpy(&challenge, resp.payload[0..Protocol.challenge_len]);
    }

    // Step 5: Compute HMAC with correct key — should succeed
    {
        var good_hmac: [Protocol.hmac_len]u8 = undefined;
        HmacSha256.create(&good_hmac, &challenge, "hmac-secret");
        const msg = try Protocol.encode(alloc, .auth, &good_hmac);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.auth_ok, resp.msg_type);
    }

    // Verify we're authenticated: LIST should work
    {
        const msg = try Protocol.encodeEmpty(alloc, .list_sessions);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.session_list, resp.msg_type);
    }

    posix.close(client_fd);
    client_fd = -1;
    server_thread.join();
}

test "reconnection: disconnect and re-attach gets fresh FULL_STATE" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    // First client: create and attach
    const fds1 = try createSocketPair();
    const server_fd1 = fds1[0];
    var client_fd1 = fds1[1];

    var conn1 = ClientConnection.init(alloc, server_fd1, &mgr, "");
    const t1 = try std.Thread.spawn(.{}, struct {
        fn run(c: *ClientConnection) void { c.run(); }
    }.run, .{&conn1});

    // Create session
    {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], 10, .little);
        std.mem.writeInt(u16, payload[2..4], 5, .little);
        const msg = try Protocol.encode(alloc, .create, &payload);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd1, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd1);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.session_created, resp.msg_type);
    }

    // Attach
    {
        const msg = try Protocol.encodeU32(alloc, .attach, 1);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd1, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd1);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.attached, resp.msg_type);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd1);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.full_state, resp.msg_type);
    }

    // Disconnect first client (simulating network drop)
    posix.close(client_fd1);
    client_fd1 = -1;
    t1.join();

    // Session should still exist
    mgr.lock();
    const session = mgr.getSession(1);
    try std.testing.expect(session != null);
    try std.testing.expect(!session.?.attached); // detachIfAttached cleaned up
    mgr.unlock();

    // Second client: reconnect and re-attach
    const fds2 = try createSocketPair();
    const server_fd2 = fds2[0];
    var client_fd2 = fds2[1];
    defer if (client_fd2 != -1) posix.close(client_fd2);

    var conn2 = ClientConnection.init(alloc, server_fd2, &mgr, "");
    const t2 = try std.Thread.spawn(.{}, struct {
        fn run(c: *ClientConnection) void { c.run(); }
    }.run, .{&conn2});

    // Re-attach to same session
    {
        const msg = try Protocol.encodeU32(alloc, .attach, 1);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd2, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd2);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.attached, resp.msg_type);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd2);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.full_state, resp.msg_type);
        // Verify dimensions preserved
        const hdr: *const Protocol.FullStateHeader = @ptrCast(@alignCast(resp.payload.ptr));
        try std.testing.expectEqual(@as(u16, 10), hdr.cols);
        try std.testing.expectEqual(@as(u16, 5), hdr.rows);
    }

    posix.close(client_fd2);
    client_fd2 = -1;
    t2.join();
}

test "destroy session" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(c_conn: *ClientConnection) void {
            c_conn.run();
        }
    }.run, .{&conn});

    // Create a session
    {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], 80, .little);
        std.mem.writeInt(u16, payload[2..4], 24, .little);
        const msg = try Protocol.encode(alloc, .create, &payload);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.session_created, resp.msg_type);
    }

    // Destroy it
    {
        const msg = try Protocol.encodeU32(alloc, .destroy, 1);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.detached, resp.msg_type);
    }

    // Verify list is empty
    {
        const msg = try Protocol.encodeEmpty(alloc, .list_sessions);
        defer alloc.free(msg);
        try Protocol.writeMessage(client_fd, msg);
    }
    {
        var resp = try Protocol.readMessage(alloc, client_fd);
        defer resp.deinit(alloc);
        try std.testing.expectEqual(Protocol.MessageType.session_list, resp.msg_type);
        const entries = try Protocol.decodeSessionList(alloc, resp.payload);
        defer Protocol.freeSessionList(alloc, entries);
        try std.testing.expectEqual(@as(usize, 0), entries.len);
    }

    posix.close(client_fd);
    client_fd = -1;
    server_thread.join();
}
