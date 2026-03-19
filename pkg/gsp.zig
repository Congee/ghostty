//! GSP (Ghostty Sync Protocol) — Binary framed protocol for daemon-client
//! communication. Wire format: [magic:2][type:1][len:4][payload]
//!
//! All multi-byte integers are little-endian.
const Protocol = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const posix = std.posix;
const log = std.log.scoped(.gsp);

/// Magic bytes identifying a GSP frame.
pub const magic: [2]u8 = .{ 'G', 'S' };

/// Protocol version (embedded in AUTH handshake, not per-frame).
pub const version: u8 = 1;

/// Maximum payload size (16 MiB — enough for a full 500x200 screen).
pub const max_payload_len: u32 = 16 * 1024 * 1024;

/// Header is fixed 7 bytes: magic(2) + type(1) + len(4).
pub const header_len = 7;

/// HMAC-SHA256 digest length.
pub const hmac_len = 32;

/// Challenge nonce length.
pub const challenge_len = 32;

/// Message types.
pub const MessageType = enum(u8) {
    // Client -> Server
    auth = 0x01,
    list_sessions = 0x02,
    attach = 0x03,
    detach = 0x04,
    create = 0x05,
    input = 0x06,
    resize = 0x07,
    destroy = 0x08,
    scroll = 0x0a,

    // Server -> Client
    auth_challenge = 0x09,
    auth_ok = 0x80,
    auth_fail = 0x81,
    session_list = 0x82,
    full_state = 0x83,
    delta = 0x84,
    attached = 0x85,
    detached = 0x86,
    error_msg = 0x87,
    session_created = 0x88,
    session_exited = 0x89,
    scroll_data = 0x8a,
    clipboard = 0x8b,
    /// Inline image data (Kitty graphics or Sixel).
    /// Payload: type(1) + col(2) + row(2) + width(2) + height(2) + data_len(4) + data
    image = 0x8c,
};

/// A decoded GSP message (header + owned payload).
pub const Message = struct {
    msg_type: MessageType,
    payload: []const u8,

    pub fn deinit(self: *Message, alloc: Allocator) void {
        if (self.payload.len > 0) alloc.free(self.payload);
        self.* = undefined;
    }
};

// ── Payload structs ──

pub const AuthPayload = struct {
    key: []const u8,
};

pub const AttachPayload = struct {
    session_id: u32,
};

pub const ResizePayload = struct {
    cols: u16,
    rows: u16,
};

pub const ImageType = enum(u8) {
    kitty = 0,
    sixel = 1,
};

pub const CreatePayload = struct {
    /// Optional command to run (empty = default shell).
    command: []const u8,
};

pub const SessionEntry = struct {
    id: u32,
    name: []const u8,
    title: []const u8,
    pwd: []const u8,
    attached: bool,
    child_exited: bool,
};

/// A single cell in the wire format. Designed for efficient bulk transfer.
/// 12 bytes per cell: codepoint(4) + fg(3) + bg(3) + style_flags(1) + wide(1)
pub const WireCell = extern struct {
    codepoint: u32 = 0,
    fg_r: u8 = 0,
    fg_g: u8 = 0,
    fg_b: u8 = 0,
    bg_r: u8 = 0,
    bg_g: u8 = 0,
    bg_b: u8 = 0,
    /// Packed style flags: bit 0 = bold, bit 1 = italic, bit 2 = underline,
    /// bit 3 = strikethrough, bit 4 = inverse, bit 5 = has_fg, bit 6 = has_bg
    style_flags: u8 = 0,
    /// 0 = narrow, 1 = wide left, 2 = wide right
    wide: u8 = 0,

    pub const size = 12;

    comptime {
        std.debug.assert(@sizeOf(WireCell) == size);
    }
};

/// Full screen state header (precedes rows*cols WireCells).
pub const FullStateHeader = extern struct {
    rows: u16,
    cols: u16,
    cursor_x: u16,
    cursor_y: u16,
    cursor_visible: u8,
    _padding: [3]u8 = .{ 0, 0, 0 },

    pub const size = 12;

    comptime {
        std.debug.assert(@sizeOf(FullStateHeader) == size);
    }
};

/// Delta update: header + N dirty row entries.
pub const DeltaHeader = extern struct {
    /// Number of dirty rows following this header.
    num_rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    cursor_visible: u8,
    _padding: u8 = 0,

    pub const size = 8;

    comptime {
        std.debug.assert(@sizeOf(DeltaHeader) == size);
    }
};

/// Each dirty row in a delta: row_index(2) + cols cells.
pub const DeltaRowHeader = extern struct {
    row_index: u16,
    num_cols: u16,

    pub const size = 4;

    comptime {
        std.debug.assert(@sizeOf(DeltaRowHeader) == size);
    }
};

// ── Encoding ──

/// Encode a message into a freshly allocated buffer: header + payload.
pub fn encode(alloc: Allocator, msg_type: MessageType, payload: []const u8) ![]u8 {
    const total = header_len + payload.len;
    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);

    buf[0] = magic[0];
    buf[1] = magic[1];
    buf[2] = @intFromEnum(msg_type);
    mem.writeInt(u32, buf[3..7], @intCast(payload.len), .little);
    if (payload.len > 0) @memcpy(buf[header_len..], payload);

    return buf;
}

/// Encode a message with no payload.
pub fn encodeEmpty(alloc: Allocator, msg_type: MessageType) ![]u8 {
    return encode(alloc, msg_type, &.{});
}

/// Encode a u32 as payload (e.g. session_id for ATTACH).
pub fn encodeU32(alloc: Allocator, msg_type: MessageType, value: u32) ![]u8 {
    var payload: [4]u8 = undefined;
    mem.writeInt(u32, &payload, value, .little);
    return encode(alloc, msg_type, &payload);
}

/// Encode a RESIZE message.
pub fn encodeResize(alloc: Allocator, cols: u16, rows: u16) ![]u8 {
    var payload: [4]u8 = undefined;
    mem.writeInt(u16, payload[0..2], cols, .little);
    mem.writeInt(u16, payload[2..4], rows, .little);
    return encode(alloc, .resize, &payload);
}

/// Encode a session list response. Single allocation (header + payload).
pub fn encodeSessionList(alloc: Allocator, entries: []const SessionEntry) ![]u8 {
    // Calculate total payload size
    var payload_size: usize = 4; // entry count (u32)
    for (entries) |e| {
        // id(4) + name_len(2) + name + title_len(2) + title + pwd_len(2) + pwd + flags(1)
        payload_size += 4 + 2 + e.name.len + 2 + e.title.len + 2 + e.pwd.len + 1;
    }

    // Allocate header + payload in one buffer
    const total = header_len + payload_size;
    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);

    // Write GSP header
    buf[0] = magic[0];
    buf[1] = magic[1];
    buf[2] = @intFromEnum(MessageType.session_list);
    mem.writeInt(u32, buf[3..7], @intCast(payload_size), .little);

    // Write payload starting after header
    var offset: usize = header_len;

    // Entry count
    mem.writeInt(u32, buf[offset..][0..4], @intCast(entries.len), .little);
    offset += 4;

    for (entries) |e| {
        // Session ID
        mem.writeInt(u32, buf[offset..][0..4], e.id, .little);
        offset += 4;

        // Name
        mem.writeInt(u16, buf[offset..][0..2], @intCast(e.name.len), .little);
        offset += 2;
        @memcpy(buf[offset..][0..e.name.len], e.name);
        offset += e.name.len;

        // Title
        mem.writeInt(u16, buf[offset..][0..2], @intCast(e.title.len), .little);
        offset += 2;
        @memcpy(buf[offset..][0..e.title.len], e.title);
        offset += e.title.len;

        // PWD
        mem.writeInt(u16, buf[offset..][0..2], @intCast(e.pwd.len), .little);
        offset += 2;
        @memcpy(buf[offset..][0..e.pwd.len], e.pwd);
        offset += e.pwd.len;

        // Flags: bit 0 = attached, bit 1 = child_exited
        var flags: u8 = 0;
        if (e.attached) flags |= 0x01;
        if (e.child_exited) flags |= 0x02;
        buf[offset] = flags;
        offset += 1;
    }

    return buf;
}

// ── Decoding ──

/// Read error for protocol decoding.
pub const ReadError = error{
    InvalidMagic,
    InvalidMessageType,
    PayloadTooLarge,
    UnexpectedEof,
    ConnectionClosed,
} || Allocator.Error || posix.ReadError;

/// Read exactly `len` bytes from a fd, returning error on short read.
/// Assumes blocking fd — WouldBlock is treated as an error.
fn readExact(fd: posix.socket_t, buf: []u8) ReadError!void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch |err| return @errorCast(err);
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

/// Read a complete GSP message from a file descriptor.
pub fn readMessage(alloc: Allocator, fd: posix.socket_t) ReadError!Message {
    var hdr: [header_len]u8 = undefined;
    try readExact(fd, &hdr);

    if (hdr[0] != magic[0] or hdr[1] != magic[1]) return error.InvalidMagic;

    const msg_type = std.meta.intToEnum(MessageType, hdr[2]) catch return error.InvalidMessageType;
    const payload_len = mem.readInt(u32, hdr[3..7], .little);

    if (payload_len > max_payload_len) return error.PayloadTooLarge;

    if (payload_len == 0) {
        return .{ .msg_type = msg_type, .payload = &.{} };
    }

    const payload = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(payload);
    try readExact(fd, payload);

    return .{ .msg_type = msg_type, .payload = payload };
}

/// Write all bytes to a file descriptor. Assumes blocking fd.
pub fn writeAll(fd: posix.socket_t, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        total += posix.write(fd, data[total..]) catch |err| return err;
    }
}

/// Write a complete encoded message to a file descriptor.
pub fn writeMessage(fd: posix.socket_t, data: []const u8) !void {
    return writeAll(fd, data);
}

/// Decode a session list payload.
pub fn decodeSessionList(alloc: Allocator, payload: []const u8) ![]SessionEntry {
    if (payload.len < 4) return error.UnexpectedEof;

    const count = mem.readInt(u32, payload[0..4], .little);
    const entries = try alloc.alloc(SessionEntry, count);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*e| {
            alloc.free(e.name);
            alloc.free(e.title);
            alloc.free(e.pwd);
        }
        alloc.free(entries);
    }

    var offset: usize = 4;
    for (entries) |*e| {
        if (offset + 4 > payload.len) return error.UnexpectedEof;
        e.id = mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        // Name
        if (offset + 2 > payload.len) return error.UnexpectedEof;
        const name_len = mem.readInt(u16, payload[offset..][0..2], .little);
        offset += 2;
        if (offset + name_len > payload.len) return error.UnexpectedEof;
        e.name = try alloc.dupe(u8, payload[offset..][0..name_len]);
        offset += name_len;

        // Title
        if (offset + 2 > payload.len) return error.UnexpectedEof;
        const title_len = mem.readInt(u16, payload[offset..][0..2], .little);
        offset += 2;
        if (offset + title_len > payload.len) return error.UnexpectedEof;
        e.title = try alloc.dupe(u8, payload[offset..][0..title_len]);
        offset += title_len;

        // PWD
        if (offset + 2 > payload.len) return error.UnexpectedEof;
        const pwd_len = mem.readInt(u16, payload[offset..][0..2], .little);
        offset += 2;
        if (offset + pwd_len > payload.len) return error.UnexpectedEof;
        e.pwd = try alloc.dupe(u8, payload[offset..][0..pwd_len]);
        offset += pwd_len;

        // Flags
        if (offset >= payload.len) return error.UnexpectedEof;
        const flags = payload[offset];
        offset += 1;
        e.attached = (flags & 0x01) != 0;
        e.child_exited = (flags & 0x02) != 0;
        initialized += 1;
    }

    return entries;
}

/// Free a decoded session list.
pub fn freeSessionList(alloc: Allocator, entries: []SessionEntry) void {
    for (entries) |*e| {
        alloc.free(e.name);
        alloc.free(e.title);
        alloc.free(e.pwd);
    }
    alloc.free(entries);
}

// ── Tests ──

test "encode and decode roundtrip — empty message" {
    const alloc = std.testing.allocator;
    var data = try encodeEmpty(alloc, .list_sessions);
    defer alloc.free(data);

    try std.testing.expectEqual(@as(usize, header_len), data.len);
    try std.testing.expectEqual(magic[0], data[0]);
    try std.testing.expectEqual(magic[1], data[1]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(MessageType.list_sessions)), data[2]);
    try std.testing.expectEqual(@as(u32, 0), mem.readInt(u32, data[3..7], .little));
}

test "encode and decode roundtrip — u32 payload" {
    const alloc = std.testing.allocator;
    var data = try encodeU32(alloc, .attach, 42);
    defer alloc.free(data);

    try std.testing.expectEqual(@as(usize, header_len + 4), data.len);
    try std.testing.expectEqual(@as(u32, 4), mem.readInt(u32, data[3..7], .little));
    try std.testing.expectEqual(@as(u32, 42), mem.readInt(u32, data[7..11], .little));
}

test "encode and decode session list" {
    const alloc = std.testing.allocator;

    const entries = [_]SessionEntry{
        .{
            .id = 1,
            .name = "dev",
            .title = "zsh",
            .pwd = "/home/user",
            .attached = true,
            .child_exited = false,
        },
        .{
            .id = 2,
            .name = "",
            .title = "vim",
            .pwd = "/tmp",
            .attached = false,
            .child_exited = true,
        },
    };

    const encoded = try encodeSessionList(alloc, &entries);
    defer alloc.free(encoded);

    // Skip the header to get payload
    const payload = encoded[header_len..];
    const decoded = try decodeSessionList(alloc, payload);
    defer freeSessionList(alloc, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(u32, 1), decoded[0].id);
    try std.testing.expectEqualStrings("dev", decoded[0].name);
    try std.testing.expectEqualStrings("zsh", decoded[0].title);
    try std.testing.expectEqualStrings("/home/user", decoded[0].pwd);
    try std.testing.expect(decoded[0].attached);
    try std.testing.expect(!decoded[0].child_exited);

    try std.testing.expectEqual(@as(u32, 2), decoded[1].id);
    try std.testing.expectEqualStrings("", decoded[1].name);
    try std.testing.expectEqualStrings("vim", decoded[1].title);
    try std.testing.expectEqualStrings("/tmp", decoded[1].pwd);
    try std.testing.expect(!decoded[1].attached);
    try std.testing.expect(decoded[1].child_exited);
}

test "WireCell size is 12 bytes" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(WireCell));
}

test "FullStateHeader size is 12 bytes" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(FullStateHeader));
}

test "DeltaHeader size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DeltaHeader));
}

test "DeltaRowHeader size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(DeltaRowHeader));
}
