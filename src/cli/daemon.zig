const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const Protocol = @import("../daemon/Protocol.zig");

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
        std.time.sleep(100 * std.time.ns_per_ms);
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

pub fn isDaemonRunning(alloc: Allocator, socket_path: []const u8) bool {
    const addr = std.net.Address.initUnix(socket_path) catch return false;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(fd);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;

    // Send LIST_SESSIONS and check for valid response
    const msg = Protocol.encodeEmpty(alloc, .list_sessions) catch return false;
    defer alloc.free(msg);
    Protocol.writeMessage(fd, msg) catch return false;

    var hdr: [Protocol.header_len]u8 = undefined;
    var total: usize = 0;
    while (total < hdr.len) {
        const n = posix.read(fd, hdr[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }

    return hdr[0] == Protocol.magic[0] and hdr[1] == Protocol.magic[1];
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

    // First child: fork again and exit
    const pid2 = std.c.fork();
    if (pid2 < 0) std.c.exit(1);
    if (pid2 > 0) std.c.exit(0);

    // Grandchild: this becomes the daemon process
    _ = setsid();

    // Redirect stdin/stdout to /dev/null, keep stderr for logging
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (devnull >= 0) {
        _ = std.c.dup2(devnull, 0);
        _ = std.c.dup2(devnull, 1);
        if (devnull > 2) _ = std.c.close(devnull);
    }

    // Run daemon main loop directly (no exec needed)
    const daemon_main = @import("../daemon/main.zig");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const SessionManager = @import("../daemon/SessionManager.zig");
    var session_mgr = SessionManager.init(alloc);

    // Remove stale socket and start listening
    std.fs.cwd().deleteFile(socket_path) catch {};
    daemon_main.runUnixListener(alloc, socket_path, &session_mgr, "") catch {};

    session_mgr.deinit();
    std.c.exit(0);
}
