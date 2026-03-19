const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const daemon_cli = @import("daemon.zig");
const cmds = @import("session_commands.zig");

pub const Options = struct {};

/// Manage daemon sessions from the command line.
///
/// Usage:
///   ghostty +session list              List all sessions
///   ghostty +session create            Create a new session
///   ghostty +session attach <id>       Attach to session (prints cell data)
///   ghostty +session destroy <id>      Destroy a session
///
/// The daemon must be running (use `ghostty +daemon` to start it).
pub fn run(alloc: Allocator) !u8 {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // Parse subcommand from args
    var args = std.process.args();
    _ = args.next(); // skip binary name
    // Skip until we find "+session"
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "+session")) break;
    }

    const subcommand = args.next() orelse {
        try stderr.print("Usage: ghostty +session <list|create|attach|destroy> [args]\n", .{});
        try stderr.flush();
        return 1;
    };

    const socket_path = daemon_cli.getSocketPath();

    // Ensure daemon is running
    if (!daemon_cli.isDaemonRunning(alloc, socket_path)) {
        try stderr.print("Daemon not running. Start it with: ghostty +daemon\n", .{});
        try stderr.flush();
        return 1;
    }

    // Connect to daemon
    const addr = try std.net.Address.initUnix(socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    if (mem.eql(u8, subcommand, "list")) {
        return cmds.sessionList(alloc, fd, stdout);
    } else if (mem.eql(u8, subcommand, "create")) {
        return cmds.sessionCreate(alloc, fd, stdout);
    } else if (mem.eql(u8, subcommand, "attach")) {
        const id_str = args.next() orelse {
            try stderr.print("Usage: ghostty +session attach <id>\n", .{});
            try stderr.flush();
            return 1;
        };
        const id = std.fmt.parseInt(u32, id_str, 10) catch {
            try stderr.print("Invalid session id: {s}\n", .{id_str});
            try stderr.flush();
            return 1;
        };
        return cmds.sessionAttach(alloc, fd, id, stdout);
    } else if (mem.eql(u8, subcommand, "destroy")) {
        const id_str = args.next() orelse {
            try stderr.print("Usage: ghostty +session destroy <id>\n", .{});
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
        try stderr.print("Unknown subcommand: {s}\n", .{subcommand});
        try stderr.print("Usage: ghostty +session <list|create|attach|destroy> [args]\n", .{});
        try stderr.flush();
        return 1;
    }
}

// ── Tests ──

const Protocol = @import("../daemon/Protocol.zig");
const SessionManager = @import("../daemon/SessionManager.zig");
const ClientConnection = @import("../daemon/ClientConnection.zig");

extern "c" fn socketpair(domain: c_int, sock_type: c_int, protocol: c_int, sv: *[2]posix.fd_t) c_int;

fn createSocketPair() ![2]posix.socket_t {
    var fds: [2]posix.fd_t = undefined;
    if (socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) < 0) {
        return error.SocketPairFailed;
    }
    return fds;
}

test "sessionList shows empty list" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const t = try std.Thread.spawn(.{}, struct {
        fn f(c: *ClientConnection) void { c.run(); }
    }.f, .{&conn});

    var out_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const result = try cmds.sessionList(alloc, client_fd, &fbs.writer().interface);
    try std.testing.expectEqual(@as(u8, 0), result);

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "No sessions") != null);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}

test "sessionCreate returns session id" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const t = try std.Thread.spawn(.{}, struct {
        fn f(c: *ClientConnection) void { c.run(); }
    }.f, .{&conn});

    var out_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const result = try cmds.sessionCreate(alloc, client_fd, &fbs.writer().interface);
    try std.testing.expectEqual(@as(u8, 0), result);

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Created session 1") != null);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}

test "sessionDestroy removes session" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const fds = try createSocketPair();
    const server_fd = fds[0];
    var client_fd = fds[1];
    defer if (client_fd != -1) posix.close(client_fd);

    var conn = ClientConnection.init(alloc, server_fd, &mgr, "");
    const t = try std.Thread.spawn(.{}, struct {
        fn f(c: *ClientConnection) void { c.run(); }
    }.f, .{&conn});

    // Create then destroy
    var buf1: [4096]u8 = undefined;
    var fbs1 = std.io.fixedBufferStream(&buf1);
    _ = try cmds.sessionCreate(alloc, client_fd, &fbs1.writer().interface);

    var buf2: [4096]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf2);
    const result = try cmds.sessionDestroy(alloc, client_fd, 1, &fbs2.writer().interface);
    try std.testing.expectEqual(@as(u8, 0), result);

    const output = fbs2.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Destroyed session 1") != null);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}
