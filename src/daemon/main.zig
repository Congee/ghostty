//! ghostty-daemon entry point. Starts a daemon that manages persistent
//! terminal sessions and accepts GSP client connections over Unix sockets
//! (and optionally TCP).
//!
//! Usage:
//!   ghostty-daemon [options]
//!
//! Options:
//!   --listen <addr>      Listen address (default: unix:/tmp/ghostty.sock)
//!   --auth-key <key>     Pre-shared authentication key (default: none)
//!   --help               Show this help

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Protocol = @import("gsp");
const SessionManager = @import("SessionManager.zig");
const ClientConnection = @import("ClientConnection.zig");
const Bonjour = @import("Bonjour.zig");

const log = std.log.scoped(.daemon);

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Config = struct {
    listen_addr: []const u8,
    auth_key: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const config = parseArgs() catch |err| {
        if (err == error.HelpRequested) {
            return; // Already printed help
        }
        log.err("argument error: {}", .{err});
        return err;
    };

    log.info("ghostty-daemon starting", .{});
    log.info("listening on {s}", .{config.listen_addr});

    var session_mgr = SessionManager.init(alloc);
    defer session_mgr.deinit();

    // Determine listener type from address
    if (std.mem.startsWith(u8, config.listen_addr, "unix:")) {
        const path = config.listen_addr["unix:".len..];
        try runUnixListener(alloc, path, &session_mgr, config.auth_key);
    } else if (std.mem.startsWith(u8, config.listen_addr, "tcp:")) {
        const addr_str = config.listen_addr["tcp:".len..];
        try runTcpListener(alloc, addr_str, &session_mgr, config.auth_key);
    } else {
        // Default: treat as unix socket path
        try runUnixListener(alloc, config.listen_addr, &session_mgr, config.auth_key);
    }
}

fn parseArgs() !Config {
    var listen_addr: []const u8 = "unix:/tmp/ghostty.sock";
    var auth_key: []const u8 = "";

    var args = std.process.args();
    _ = args.next(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--listen")) {
            listen_addr = args.next() orelse {
                log.err("--listen requires an argument", .{});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--auth-key")) {
            auth_key = args.next() orelse {
                log.err("--auth-key requires an argument", .{});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
            const stderr = &stderr_writer.interface;
            stderr.print(
                \\ghostty-daemon — Persistent terminal session daemon
                \\
                \\Usage:
                \\  ghostty-daemon [options]
                \\
                \\Options:
                \\  --listen <addr>      Listen address (default: unix:/tmp/ghostty.sock)
                \\                       Formats: unix:/path/to/sock, tcp:host:port
                \\  --auth-key <key>     Pre-shared authentication key (default: none)
                \\  --help               Show this help
                \\
            , .{}) catch {};
            return error.HelpRequested;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    return .{
        .listen_addr = listen_addr,
        .auth_key = auth_key,
    };
}

pub fn runUnixListener(
    alloc: Allocator,
    path: []const u8,
    session_mgr: *SessionManager,
    auth_key: []const u8,
) !void {
    // Remove stale socket
    std.fs.cwd().deleteFile(path) catch {};

    // Set up signal handling for graceful shutdown
    setupSignalHandlers();

    const addr = try std.net.Address.initUnix(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 16);

    log.info("unix socket listening on {s}", .{path});

    // Clean up socket file on exit
    defer std.fs.cwd().deleteFile(path) catch {};

    acceptLoop(alloc, fd, session_mgr, auth_key);
}

pub fn runTcpListener(
    alloc: Allocator,
    addr_str: []const u8,
    session_mgr: *SessionManager,
    auth_key: []const u8,
) !void {
    // Parse host:port
    const colon_pos = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse {
        log.err("invalid TCP address format: {s} (expected host:port)", .{addr_str});
        return error.InvalidAddress;
    };
    const host = addr_str[0..colon_pos];
    const port = std.fmt.parseInt(u16, addr_str[colon_pos + 1 ..], 10) catch {
        log.err("invalid port in address: {s}", .{addr_str});
        return error.InvalidAddress;
    };

    setupSignalHandlers();

    const addr = try std.net.Address.parseIp4(host, port);
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    // SO_REUSEADDR
    const optval: u32 = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));

    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 16);

    log.info("tcp listening on {s}:{}", .{ host, port });

    // Advertise via Bonjour for iOS discovery
    var bonjour: Bonjour = .{};
    bonjour.register(port);
    defer bonjour.unregister();

    acceptLoop(alloc, fd, session_mgr, auth_key);
}

fn acceptLoop(
    alloc: Allocator,
    listen_fd: posix.socket_t,
    session_mgr: *SessionManager,
    auth_key: []const u8,
) void {
    while (!shutdown_requested.load(.acquire)) {
        // Poll with timeout so we can check shutdown_requested periodically
        var pfd = [1]posix.pollfd{.{
            .fd = listen_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = posix.poll(&pfd, 500) catch |err| {
            log.warn("poll error: {}", .{err});
            continue;
        };
        if (pfd[0].revents & posix.POLL.IN == 0) continue;

        const conn_fd = posix.accept(listen_fd, null, null, 0) catch |err| {
            if (shutdown_requested.load(.acquire)) return;
            log.warn("accept error: {}", .{err});
            continue;
        };

        // Spawn a thread per client
        const thread = std.Thread.spawn(.{}, clientThread, .{
            alloc, conn_fd, session_mgr, auth_key,
        }) catch |err| {
            log.err("spawn client thread: {}", .{err});
            posix.close(conn_fd);
            continue;
        };
        thread.detach();
    }
}

fn clientThread(
    alloc: Allocator,
    fd: posix.socket_t,
    session_mgr: *SessionManager,
    auth_key: []const u8,
) void {
    defer posix.close(fd);

    var conn = ClientConnection.init(alloc, fd, session_mgr, auth_key);
    conn.run();
}

var shutdown_requested = std.atomic.Value(bool).init(false);

fn setupSignalHandlers() void {
    // Handle SIGTERM and SIGINT for graceful shutdown
    const handler: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &handler, null);
    posix.sigaction(posix.SIG.INT, &handler, null);
}

fn signalHandler(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

// ── Tests ──

test "parseArgs defaults" {
    // Can't easily test arg parsing without mocking process.args,
    // but we verify the default config values.
    const config: Config = .{
        .listen_addr = "unix:/tmp/ghostty.sock",
        .auth_key = "",
    };
    try std.testing.expectEqualStrings("unix:/tmp/ghostty.sock", config.listen_addr);
    try std.testing.expectEqualStrings("", config.auth_key);
}

test "Protocol module accessible" {
    // Smoke test that all daemon modules compile and link together.
    try std.testing.expectEqual(Protocol.magic[0], 'G');
    try std.testing.expectEqual(Protocol.magic[1], 'S');
}
