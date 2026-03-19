/// Shared session management functions used by both `+session` and `+connect`.
/// These operate on an already-connected daemon socket fd.
const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const Protocol = @import("gsp");

pub fn sessionList(
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

pub fn sessionCreate(
    alloc: Allocator,
    fd: posix.socket_t,
    stdout: anytype,
) !u8 {
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

pub fn sessionAttach(
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

        // Interactive relay loop
        try relayLoop(alloc, fd, stdout);
        return 0;
    }

    try stdout.print("Unexpected response\n", .{});
    try stdout.flush();
    return 1;
}

pub fn sessionDestroy(
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

/// Simple interactive relay: stdin → daemon INPUT, daemon DELTA → stdout.
/// Ctrl-] detaches.
pub fn relayLoop(alloc: Allocator, fd: posix.socket_t, stdout: anytype) !void {
    const stdin_fd = std.posix.STDIN_FILENO;

    // Set stdin to raw mode
    var orig_termios: std.posix.termios = undefined;
    const have_termios = blk: {
        orig_termios = std.posix.tcgetattr(stdin_fd) catch break :blk false;
        break :blk true;
    };

    if (have_termios) {
        var raw = orig_termios;
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

            const input_msg = Protocol.encode(alloc, .input, input_buf[0..n]) catch break;
            defer alloc.free(input_msg);
            Protocol.writeMessage(fd, input_msg) catch break;
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
