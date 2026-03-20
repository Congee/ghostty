const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const default_socket = "/tmp/ghostty.sock";

pub const Options = struct {};

extern "c" fn setsid() std.c.pid_t;

/// The `daemon` command ensures the ghostty-daemon is running in the
/// background. If not running, it forks and starts one. Prints the
/// socket path on success.
///
/// Usage: ghostty +daemon [options]
///
/// The daemon manages persistent terminal sessions that survive app
/// restarts. Other ghostty commands (+session) communicate with it
/// via the socket.
pub fn run(alloc: Allocator) !u8 {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const socket_path = getSocketPath();

    // Check if daemon is already running
    if (isDaemonRunning(alloc, socket_path)) {
        try stdout.print("Daemon already running at {s}\n", .{socket_path});
        try stdout.flush();
        return 0;
    }

    // Start daemon in background via double-fork
    startDaemon(socket_path) catch |err| {
        try stderr.print("Failed to start daemon: {}\n", .{err});
        try stderr.flush();
        return 1;
    };

    // Wait for daemon to be ready (up to 5 seconds)
    var attempts: u32 = 0;
    while (attempts < 50) : (attempts += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (isDaemonRunning(alloc, socket_path)) {
            try stdout.print("Daemon started at {s}\n", .{socket_path});
            try stdout.flush();
            return 0;
        }
    }

    try stderr.print("Daemon started but not responding at {s}\n", .{socket_path});
    try stderr.flush();
    return 1;
}

pub fn getSocketPath() []const u8 {
    return std.posix.getenv("GHOSTTY_SOCKET") orelse default_socket;
}

fn getAuthKey() []const u8 {
    return std.posix.getenv("GHOSTTY_AUTH_KEY") orelse "";
}

pub fn isDaemonRunning(_: Allocator, socket_path: []const u8) bool {
    if (std.mem.startsWith(u8, socket_path, "tcp:")) {
        const addr_str = socket_path["tcp:".len..];
        const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return false;
        const host = addr_str[0..colon];
        const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch return false;
        const addr = std.net.Address.resolveIp(host, port) catch return false;
        const fd = posix.socket(addr.any.family, posix.SOCK.STREAM, 0) catch return false;
        defer posix.close(fd);
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;
        return probeGsp(fd);
    }
    const path = if (std.mem.startsWith(u8, socket_path, "unix:"))
        socket_path["unix:".len..]
    else
        socket_path;
    const addr = std.net.Address.initUnix(path) catch return false;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(fd);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;
    return probeGsp(fd);
}

/// Send a GSP LIST_SESSIONS probe and check for valid GS magic response.
fn probeGsp(fd: posix.socket_t) bool {
    const probe = [_]u8{ 'G', 'S', 0x02, 0, 0, 0, 0 };
    var sent: usize = 0;
    while (sent < probe.len) {
        const n = posix.write(fd, probe[sent..]) catch return false;
        if (n == 0) return false;
        sent += n;
    }

    var hdr: [7]u8 = undefined;
    var total: usize = 0;
    while (total < hdr.len) {
        const n = posix.read(fd, hdr[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return hdr[0] == 'G' and hdr[1] == 'S';
}

fn startDaemon(socket_path: []const u8) !void {
    // Double-fork to fully detach the daemon from the terminal
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid > 0) {
        // Parent: wait for first child to exit
        _ = std.c.waitpid(pid, null, 0);
        return;
    }

    // First child: become session leader, then fork again
    _ = setsid();

    const pid2 = std.c.fork();
    if (pid2 < 0) std.c.exit(1);
    if (pid2 > 0) std.c.exit(0);

    // Grandchild: this becomes the daemon process (not a session leader,
    // so it cannot accidentally acquire a controlling terminal).

    // Close all inherited file descriptors > 2 to avoid leaking
    // parent's sockets, GUI handles, etc. into the long-lived daemon.
    var close_fd: posix.fd_t = 3;
    while (close_fd < 1024) : (close_fd += 1) {
        _ = std.c.close(close_fd);
    }

    // Redirect stdin/stdout to /dev/null, keep stderr for logging
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    if (devnull >= 0) {
        _ = std.c.dup2(devnull, 0);
        _ = std.c.dup2(devnull, 1);
        if (devnull > 2) _ = std.c.close(devnull);
    }

    // Run daemon main loop in-process (same binary, forked grandchild).
    // Only available on platforms with fork/PTY support.
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux or builtin.os.tag == .freebsd) {
        const daemon_main = @import("../daemon/main.zig");
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const daemon_alloc = gpa.allocator();

        const SessionManager = @import("../daemon/SessionManager.zig");
        var session_mgr = SessionManager.init(daemon_alloc);

        const auth_key = getAuthKey();
        if (std.mem.startsWith(u8, socket_path, "tcp:")) {
            const addr_str = socket_path["tcp:".len..];
            daemon_main.runTcpListener(daemon_alloc, addr_str, &session_mgr, auth_key) catch |err| {
                std.log.err("daemon tcp listener failed: {}", .{err});
            };
        } else {
            const path = if (std.mem.startsWith(u8, socket_path, "unix:"))
                socket_path["unix:".len..]
            else
                socket_path;
            std.fs.cwd().deleteFile(path) catch {};
            daemon_main.runUnixListener(daemon_alloc, path, &session_mgr, auth_key) catch |err| {
                std.log.err("daemon unix listener failed: {}", .{err});
            };
        }

        session_mgr.deinit();
    }
    std.c.exit(0);
}

// ── Tests ──

test "getSocketPath returns default" {
    const path = getSocketPath();
    try std.testing.expectEqualStrings("/tmp/ghostty.sock", path);
}

test "isDaemonRunning returns false for nonexistent socket" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!isDaemonRunning(alloc, "/tmp/ghostty-test-nonexistent-99999.sock"));
}

test "default_socket is /tmp/ghostty.sock" {
    try std.testing.expectEqualStrings("/tmp/ghostty.sock", default_socket);
}
