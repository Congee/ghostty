//! Tests for CLI session management commands. Exercises sessionList,
//! sessionCreate, sessionDestroy over socket pairs.
const std = @import("std");
const posix = std.posix;
const Protocol = @import("gsp");
const SessionManager = @import("SessionManager.zig");
const ClientConnection = @import("ClientConnection.zig");

extern "c" fn socketpair(domain: c_int, sock_type: c_int, protocol: c_int, sv: *[2]posix.fd_t) c_int;

fn createSocketPair() ![2]posix.socket_t {
    var fds: [2]posix.fd_t = undefined;
    if (socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) < 0) {
        return error.SocketPairFailed;
    }
    return fds;
}

fn runServer(conn: *ClientConnection) void {
    conn.run();
}

// ── sessionList ──

fn doSessionList(alloc: std.mem.Allocator, fd: posix.socket_t) !struct { code: u8, output: []const u8 } {
    const msg = try Protocol.encodeEmpty(alloc, .list_sessions);
    defer alloc.free(msg);
    try Protocol.writeMessage(fd, msg);

    var resp = try Protocol.readMessage(alloc, fd);
    defer resp.deinit(alloc);

    if (resp.msg_type != .session_list) return .{ .code = 1, .output = "bad response" };

    const entries = try Protocol.decodeSessionList(alloc, resp.payload);
    defer Protocol.freeSessionList(alloc, entries);

    if (entries.len == 0) return .{ .code = 0, .output = "empty" };
    return .{ .code = 0, .output = "has_sessions" };
}

test "CLI: list sessions on empty daemon" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const t = try std.Thread.spawn(.{}, runServer, .{&conn});

    const result = try doSessionList(alloc, client_fd);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("empty", result.output);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}

// ── sessionCreate ──

fn doSessionCreate(alloc: std.mem.Allocator, fd: posix.socket_t) !u32 {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 80, .little);
    std.mem.writeInt(u16, payload[2..4], 24, .little);
    const msg = try Protocol.encode(alloc, .create, &payload);
    defer alloc.free(msg);
    try Protocol.writeMessage(fd, msg);

    var resp = try Protocol.readMessage(alloc, fd);
    defer resp.deinit(alloc);
    if (resp.msg_type != .session_created or resp.payload.len < 4) return error.CreateFailed;
    return std.mem.readInt(u32, resp.payload[0..4], .little);
}

test "CLI: create session returns incrementing ids" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const t = try std.Thread.spawn(.{}, runServer, .{&conn});

    const id1 = try doSessionCreate(alloc, client_fd);
    const id2 = try doSessionCreate(alloc, client_fd);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);

    // List should now show 2
    const result = try doSessionList(alloc, client_fd);
    try std.testing.expectEqualStrings("has_sessions", result.output);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}

// ── sessionDestroy ──

test "CLI: destroy session" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const t = try std.Thread.spawn(.{}, runServer, .{&conn});

    // Create
    const id = try doSessionCreate(alloc, client_fd);
    try std.testing.expectEqual(@as(u32, 1), id);

    // Destroy
    const destroy_msg = try Protocol.encodeU32(alloc, .destroy, id);
    defer alloc.free(destroy_msg);
    try Protocol.writeMessage(client_fd, destroy_msg);

    var resp = try Protocol.readMessage(alloc, client_fd);
    defer resp.deinit(alloc);
    try std.testing.expectEqual(Protocol.MessageType.detached, resp.msg_type);

    // List should be empty
    const result = try doSessionList(alloc, client_fd);
    try std.testing.expectEqualStrings("empty", result.output);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}

test "CLI: destroy nonexistent session returns error" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const t = try std.Thread.spawn(.{}, runServer, .{&conn});

    const msg = try Protocol.encodeU32(alloc, .destroy, 999);
    defer alloc.free(msg);
    try Protocol.writeMessage(client_fd, msg);

    var resp = try Protocol.readMessage(alloc, client_fd);
    defer resp.deinit(alloc);
    try std.testing.expectEqual(Protocol.MessageType.error_msg, resp.msg_type);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}
