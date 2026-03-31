//! `ghostty +cmd` — Send commands to a running Ghostty instance via control socket.
//!
//! Usage:
//!   ghostty +cmd ping
//!   ghostty +cmd get-text
//!   ghostty +cmd list-tabs
//!   ghostty +cmd new-tab
//!   ghostty +cmd goto-tab next
//!   ghostty +cmd close-tab
//!   ghostty +cmd get-dimensions
//!
//! The socket path is read from $GHOSTTY_SOCKET or defaults to /tmp/ghostty.sock.
//! Extra arguments after the subcommand are appended to the socket command.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    pub fn deinit(self: *Options) void {
        _ = self;
    }

    pub fn help() !void {}
};

/// Send a command to a running Ghostty instance via the control socket.
/// The socket path is read from $GHOSTTY_SOCKET or defaults to /tmp/ghostty.sock.
pub fn run(alloc: Allocator) !u8 {
    _ = alloc;

    // Collect args after "+cmd"
    var args = std.process.args();
    _ = args.skip(); // ghostty
    _ = args.skip(); // +cmd

    const subcmd = args.next() orelse {
        var buffer: [1024]u8 = undefined;
        const stderr_file: std.fs.File = .stderr();
        var stderr_writer = stderr_file.writer(&buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print("Usage: ghostty +cmd <command> [args...]\n", .{});
        return 1;
    };

    // Build the command string: subcmd + remaining args
    var cmd_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const w = fbs.writer();

    // Map CLI subcommand names to protocol commands
    const protocol_cmd = mapCommand(subcmd);
    try w.writeAll(protocol_cmd);

    // Append remaining args
    while (args.next()) |arg| {
        try w.writeByte(' ');
        try w.writeAll(arg);
    }
    try w.writeByte('\n');

    const command = fbs.getWritten();

    // Connect to socket
    const socket_path = std.posix.getenv("GHOSTTY_SOCKET") orelse "/tmp/ghostty.sock";

    const addr = try std.net.Address.initUnix(socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| {
        var ebuf: [1024]u8 = undefined;
        const stderr_file: std.fs.File = .stderr();
        var stderr_writer = stderr_file.writer(&ebuf);
        const stderr = &stderr_writer.interface;
        try stderr.print("Failed to connect to {s}: {}\n", .{ socket_path, err });
        return 1;
    };

    // Send command
    _ = try posix.write(fd, command);

    // Read and print response directly to stdout fd.
    const stdout_fd = std.fs.File.stdout().handle;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        _ = posix.write(stdout_fd, buf[0..n]) catch break;
    }

    return 0;
}

/// Map CLI-friendly names to protocol command names.
fn mapCommand(name: []const u8) []const u8 {
    const map = .{
        .{ "ping", "PING" },
        .{ "get-text", "GET-TEXT" },
        .{ "list-tabs", "LIST-TABS" },
        .{ "new-tab", "NEW-TAB" },
        .{ "close-tab", "CLOSE-TAB" },
        .{ "goto-tab", "GOTO-TAB" },
        .{ "get-dimensions", "GET-DIMENSIONS" },
        .{ "get-focused", "GET-FOCUSED" },
        .{ "get-status-bar", "GET-STATUS-BAR" },
        .{ "rename-tab", "RENAME-TAB" },
        .{ "new-split", "NEW-SPLIT" },
        .{ "close-pane", "CLOSE-PANE" },
        .{ "resize-split", "RESIZE-SPLIT" },
        .{ "goto-split", "GOTO-SPLIT" },
        .{ "equalize-splits", "EQUALIZE-SPLITS" },
        .{ "toggle-zoom", "TOGGLE-ZOOM" },
        .{ "list-panes", "LIST-PANES" },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }

    // Pass through as-is (already uppercase protocol command)
    return name;
}
