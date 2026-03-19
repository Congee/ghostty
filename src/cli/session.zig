const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const Protocol = @import("../daemon/Protocol.zig");
const daemon_cli = @import("daemon.zig");

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
        return sessionList(alloc, fd, stdout);
    } else if (mem.eql(u8, subcommand, "create")) {
        return sessionCreate(alloc, fd, stdout);
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
        return sessionAttach(alloc, fd, id, stdout);
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
        return sessionDestroy(alloc, fd, id, stdout);
    } else {
        try stderr.print("Unknown subcommand: {s}\n", .{subcommand});
        try stderr.print("Usage: ghostty +session <list|create|attach|destroy> [args]\n", .{});
        try stderr.flush();
        return 1;
    }
}

fn sessionList(
    alloc: Allocator,
    fd: posix.socket_t,
    stdout: anytype,
) !u8 {
    const msg = try Protocol.encodeEmpty(alloc, .list_sessions);
    defer alloc.free(msg);
    try Protocol.writeMessage(fd, msg);

    var resp = try Protocol.readMessage(alloc, fd);
    defer resp.deinit(alloc);

    if (resp.msg_type != .session_list) {
        try stdout.print("Unexpected response\n", .{});
        try stdout.flush();
        return 1;
    }

    const entries = try Protocol.decodeSessionList(alloc, resp.payload);
    defer Protocol.freeSessionList(alloc, entries);

    if (entries.len == 0) {
        try stdout.print("No sessions\n", .{});
        try stdout.flush();
        return 0;
    }

    try stdout.print("{s:<6} {s:<10} {s:<20} {s:<8} {s}\n", .{ "ID", "STATUS", "TITLE", "ATTACHED", "PWD" });
    for (entries) |e| {
        const status: []const u8 = if (e.child_exited) "exited" else "running";
        const attached: []const u8 = if (e.attached) "yes" else "no";
        const title = if (e.name.len > 0) e.name else if (e.title.len > 0) e.title else "(unnamed)";
        try stdout.print("{d:<6} {s:<10} {s:<20} {s:<8} {s}\n", .{
            e.id, status, title, attached, e.pwd,
        });
    }
    try stdout.flush();
    return 0;
}

fn sessionCreate(
    alloc: Allocator,
    fd: posix.socket_t,
    stdout: anytype,
) !u8 {
    // Create with default 80x24
    var payload: [4]u8 = undefined;
    mem.writeInt(u16, payload[0..2], 80, .little);
    mem.writeInt(u16, payload[2..4], 24, .little);

    const msg = try Protocol.encode(alloc, .create, &payload);
    defer alloc.free(msg);
    try Protocol.writeMessage(fd, msg);

    var resp = try Protocol.readMessage(alloc, fd);
    defer resp.deinit(alloc);

    if (resp.msg_type == .session_created and resp.payload.len >= 4) {
        const id = mem.readInt(u32, resp.payload[0..4], .little);
        try stdout.print("Created session {d}\n", .{id});
        try stdout.flush();
        return 0;
    }

    try stdout.print("Failed to create session\n", .{});
    try stdout.flush();
    return 1;
}

fn sessionAttach(
    alloc: Allocator,
    fd: posix.socket_t,
    id: u32,
    stdout: anytype,
) !u8 {
    const msg = try Protocol.encodeU32(alloc, .attach, id);
    defer alloc.free(msg);
    try Protocol.writeMessage(fd, msg);

    // Read ATTACHED
    var resp1 = try Protocol.readMessage(alloc, fd);
    defer resp1.deinit(alloc);
    if (resp1.msg_type == .error_msg) {
        try stdout.print("Error: {s}\n", .{resp1.payload});
        try stdout.flush();
        return 1;
    }

    // Read FULL_STATE
    var resp2 = try Protocol.readMessage(alloc, fd);
    defer resp2.deinit(alloc);
    if (resp2.msg_type == .full_state and resp2.payload.len >= 12) {
        const rows = mem.readInt(u16, resp2.payload[0..2], .little);
        const cols = mem.readInt(u16, resp2.payload[2..4], .little);
        try stdout.print("Attached to session {d} ({d}x{d})\n", .{ id, cols, rows });

        // Print cell grid as text
        const cell_count = @as(usize, rows) * @as(usize, cols);
        if (resp2.payload.len >= 12 + cell_count * Protocol.WireCell.size) {
            for (0..rows) |row| {
                for (0..cols) |col| {
                    const idx = 12 + (row * @as(usize, cols) + col) * Protocol.WireCell.size;
                    const cp = mem.readInt(u32, resp2.payload[idx..][0..4], .little);
                    if (cp >= 0x20 and cp < 0x7f) {
                        try stdout.print("{c}", .{@as(u8, @truncate(cp))});
                    } else {
                        try stdout.print(" ", .{});
                    }
                }
                try stdout.print("\n", .{});
            }
        }
        try stdout.flush();

        // Now relay stdin to daemon and daemon deltas to stdout
        // (simple interactive loop)
        try relayLoop(alloc, fd, stdout);
        return 0;
    }

    try stdout.print("Unexpected response\n", .{});
    try stdout.flush();
    return 1;
}

fn sessionDestroy(
    alloc: Allocator,
    fd: posix.socket_t,
    id: u32,
    stdout: anytype,
) !u8 {
    const msg = try Protocol.encodeU32(alloc, .destroy, id);
    defer alloc.free(msg);
    try Protocol.writeMessage(fd, msg);

    var resp = try Protocol.readMessage(alloc, fd);
    defer resp.deinit(alloc);

    if (resp.msg_type == .detached) {
        try stdout.print("Destroyed session {d}\n", .{id});
        try stdout.flush();
        return 0;
    }
    if (resp.msg_type == .error_msg) {
        try stdout.print("Error: {s}\n", .{resp.payload});
        try stdout.flush();
        return 1;
    }

    try stdout.print("Unexpected response\n", .{});
    try stdout.flush();
    return 1;
}

/// Simple interactive relay: stdin → daemon INPUT, daemon DELTA → stdout
fn relayLoop(alloc: Allocator, fd: posix.socket_t, stdout: anytype) !void {
    const stdin_fd = std.posix.STDIN_FILENO;

    // Set stdin to raw mode
    var orig_termios: std.posix.termios = undefined;
    const have_termios = blk: {
        orig_termios = std.posix.tcgetattr(stdin_fd) catch break :blk false;
        break :blk true;
    };

    if (have_termios) {
        var raw = orig_termios;
        // Disable canonical mode, echo, signals
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin_fd, .NOW, raw);
    }
    defer if (have_termios) {
        std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
    };

    var input_buf: [256]u8 = undefined;

    while (true) {
        var pfds = [2]posix.pollfd{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&pfds, -1) catch break;

        // stdin → daemon
        if (pfds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(stdin_fd, &input_buf) catch break;
            if (n == 0) break;

            // Ctrl-] to detach
            if (n == 1 and input_buf[0] == 0x1d) {
                try stdout.print("\r\nDetached.\r\n", .{});
                try stdout.flush();
                break;
            }

            const msg = Protocol.encode(alloc, .input, input_buf[0..n]) catch break;
            defer alloc.free(msg);
            Protocol.writeMessage(fd, msg) catch break;
        }

        // daemon → stdout (delta updates)
        if (pfds[1].revents & posix.POLL.IN != 0) {
            var resp = Protocol.readMessage(alloc, fd) catch break;
            defer resp.deinit(alloc);

            switch (resp.msg_type) {
                .delta => {},
                .session_exited => {
                    try stdout.print("\r\nSession exited.\r\n", .{});
                    try stdout.flush();
                    break;
                },
                else => {},
            }
        }

        if (pfds[1].revents & posix.POLL.HUP != 0) break;
    }
}

// ── Tests ──

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
    const result = try sessionList(alloc, client_fd, &fbs.writer().interface);
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
    const result = try sessionCreate(alloc, client_fd, &fbs.writer().interface);
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
    _ = try sessionCreate(alloc, client_fd, &fbs1.writer().interface);

    var buf2: [4096]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf2);
    const result = try sessionDestroy(alloc, client_fd, 1, &fbs2.writer().interface);
    try std.testing.expectEqual(@as(u8, 0), result);

    const output = fbs2.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Destroyed session 1") != null);

    posix.close(client_fd);
    client_fd = -1;
    t.join();
}
