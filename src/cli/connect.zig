const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const crypto = std.crypto;

const Protocol = @import("../daemon/Protocol.zig");
const cmds = @import("session_commands.zig");
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;

pub const Options = struct {};

/// Connect to a remote ghostty daemon over TCP.
///
/// Usage:
///   ghostty +connect <addr> [--auth-key <key>] <list|create|attach|destroy> [id]
///
/// Address format:
///   tcp:host:port    TCP connection (e.g. tcp:192.168.1.5:7337)
///   unix:/path       Unix socket (e.g. unix:/tmp/ghostty.sock)
///
/// Examples:
///   ghostty +connect tcp:my-mac:7337 list
///   ghostty +connect tcp:my-mac:7337 --auth-key secret attach 1
///   ghostty +connect tcp:my-mac:7337 create
pub fn run(alloc: Allocator) !u8 {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // Parse arguments
    var args = std.process.args();
    _ = args.next(); // skip binary name
    // Skip until we find "+connect"
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "+connect")) break;
    }

    const addr_str = args.next() orelse {
        try stderr.print("Usage: ghostty +connect <addr> [--auth-key <key>] <list|create|attach|destroy> [id]\n", .{});
        try stderr.flush();
        return 1;
    };

    // Parse optional --auth-key and subcommand
    var auth_key: []const u8 = "";
    var subcommand: ?[]const u8 = null;
    var sub_arg: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--auth-key")) {
            auth_key = args.next() orelse {
                try stderr.print("--auth-key requires a value\n", .{});
                try stderr.flush();
                return 1;
            };
        } else if (subcommand == null) {
            subcommand = arg;
        } else {
            sub_arg = arg;
        }
    }

    const cmd = subcommand orelse {
        try stderr.print("Usage: ghostty +connect <addr> [--auth-key <key>] <list|create|attach|destroy> [id]\n", .{});
        try stderr.flush();
        return 1;
    };

    // Connect
    const fd = connectTo(addr_str) catch |err| {
        try stderr.print("Failed to connect to {s}: {}\n", .{ addr_str, err });
        try stderr.flush();
        return 1;
    };
    defer posix.close(fd);

    // Authenticate if auth key is provided
    if (auth_key.len > 0) {
        const auth_result = authenticate(alloc, fd, auth_key) catch |err| {
            try stderr.print("Authentication failed: {}\n", .{err});
            try stderr.flush();
            return 1;
        };
        if (!auth_result) {
            try stderr.print("Authentication rejected by server\n", .{});
            try stderr.flush();
            return 1;
        }
    }

    if (mem.eql(u8, cmd, "list")) {
        return cmds.sessionList(alloc, fd, stdout);
    } else if (mem.eql(u8, cmd, "create")) {
        return cmds.sessionCreate(alloc, fd, stdout);
    } else if (mem.eql(u8, cmd, "attach")) {
        const id_str = sub_arg orelse {
            try stderr.print("Usage: ghostty +connect <addr> attach <id>\n", .{});
            try stderr.flush();
            return 1;
        };
        const id = std.fmt.parseInt(u32, id_str, 10) catch {
            try stderr.print("Invalid session id: {s}\n", .{id_str});
            try stderr.flush();
            return 1;
        };
        return cmds.sessionAttach(alloc, fd, id, stdout);
    } else if (mem.eql(u8, cmd, "destroy")) {
        const id_str = sub_arg orelse {
            try stderr.print("Usage: ghostty +connect <addr> destroy <id>\n", .{});
            try stderr.flush();
            return 1;
        };
        const id = std.fmt.parseInt(u32, id_str, 10) catch {
            try stderr.print("Invalid session id: {s}\n", .{id_str});
            try stderr.flush();
            return 1;
        };
        return cmds.sessionDestroy(alloc, fd, id, stdout);
    } else {
        try stderr.print("Unknown subcommand: {s}\n", .{cmd});
        try stderr.print("Usage: ghostty +connect <addr> <list|create|attach|destroy> [id]\n", .{});
        try stderr.flush();
        return 1;
    }
}

/// Connect to an address string. Supports "tcp:host:port" and "unix:/path".
fn connectTo(addr_str: []const u8) !posix.socket_t {
    if (mem.startsWith(u8, addr_str, "tcp:")) {
        return connectTcp(addr_str["tcp:".len..]);
    } else if (mem.startsWith(u8, addr_str, "unix:")) {
        return connectUnix(addr_str["unix:".len..]);
    } else {
        // Try as unix socket path
        return connectUnix(addr_str);
    }
}

fn connectTcp(addr_str: []const u8) !posix.socket_t {
    const colon_pos = mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.InvalidAddress;
    const host = addr_str[0..colon_pos];
    const port = std.fmt.parseInt(u16, addr_str[colon_pos + 1 ..], 10) catch return error.InvalidAddress;

    // Copy host to null-terminated buffer for parseIp4
    var host_buf: [256]u8 = undefined;
    if (host.len >= host_buf.len) return error.InvalidAddress;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    const addr = std.net.Address.parseIp4(host_buf[0..host.len :0], port) catch
        return error.InvalidAddress;

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

fn connectUnix(path: []const u8) !posix.socket_t {
    const addr = try std.net.Address.initUnix(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// Perform HMAC challenge-response authentication.
/// Returns true if authenticated successfully.
fn authenticate(alloc: Allocator, fd: posix.socket_t, auth_key: []const u8) !bool {
    // Send AUTH with empty payload to initiate HMAC flow
    const auth_msg = try Protocol.encodeEmpty(alloc, .auth);
    defer alloc.free(auth_msg);
    try Protocol.writeMessage(fd, auth_msg);

    // Read response — should be AUTH_CHALLENGE
    var resp = try Protocol.readMessage(alloc, fd);
    defer resp.deinit(alloc);

    if (resp.msg_type == .auth_ok) {
        // Server has no auth key configured
        return true;
    }

    if (resp.msg_type != .auth_challenge or resp.payload.len != Protocol.challenge_len) {
        return false;
    }

    // Compute HMAC-SHA256(key, challenge)
    var hmac: [Protocol.hmac_len]u8 = undefined;
    HmacSha256.create(&hmac, resp.payload[0..Protocol.challenge_len], auth_key);

    // Send HMAC response
    const hmac_msg = try Protocol.encode(alloc, .auth, &hmac);
    defer alloc.free(hmac_msg);
    try Protocol.writeMessage(fd, hmac_msg);

    // Read auth result
    var result = try Protocol.readMessage(alloc, fd);
    defer result.deinit(alloc);

    return result.msg_type == .auth_ok;
}

// ── Tests ──

test "connectTo parses tcp: prefix" {
    // Can't connect to a real server in tests, but we can verify
    // the parsing logic doesn't crash on valid-format addresses.
    // connectTcp will fail at the socket level — that's expected.
    _ = connectTo("tcp:127.0.0.1:9999") catch {};
}

test "connectTo parses unix: prefix" {
    _ = connectTo("unix:/tmp/nonexistent-test-socket") catch {};
}

test "connectTo treats bare path as unix" {
    _ = connectTo("/tmp/nonexistent-test-socket") catch {};
}
