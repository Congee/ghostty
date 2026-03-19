//! Minimal VT100/xterm sequence parser for the daemon. Parses a byte stream
//! and updates a DaemonSession's cell grid (cursor movement, character output,
//! colors, erasing, scrolling).
//!
//! This is intentionally simplified — it handles the sequences needed for
//! a working shell (bash/zsh prompt, basic editing, colors). The full Ghostty
//! terminal emulator can replace this once the daemon integrates with the
//! build system.
const VtParser = @This();

const std = @import("std");
const Protocol = @import("Protocol.zig");
const SessionManager = @import("SessionManager.zig");

const log = std.log.scoped(.vt_parser);

/// Parser state machine states.
const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    osc_string,
    osc_string_escape,
    dcs_string, // Sixel: ESC P ... ESC backslash
    dcs_string_escape,
    apc_string, // Kitty graphics: ESC _ ... ESC backslash
    apc_string_escape,
};

state: State = .ground,

/// CSI parameter accumulation.
params: [16]u16 = [_]u16{0} ** 16,
param_count: u8 = 0,
/// Track whether we've seen any digit for the current param.
param_has_digit: bool = false,

/// CSI intermediate bytes (e.g., '?' in \x1b[?25h).
intermediate: u8 = 0,

/// OSC string accumulation (for OSC 52 clipboard, titles, etc.)
osc_buf: [4096]u8 = undefined,
osc_len: u16 = 0,

/// Callback for clipboard data (OSC 52). Set by the caller.
clipboard_callback: ?*const fn (data: []const u8) void = null,

/// Callback for image data (Kitty/Sixel). Type + raw payload.
image_callback: ?*const fn (img_type: Protocol.ImageType, data: []const u8) void = null,

/// DCS/APC string accumulation (for Sixel/Kitty graphics).
/// Uses the same osc_buf since they don't overlap.
dcs_apc_is_kitty: bool = false,

/// Current SGR (Select Graphic Rendition) state.
fg: Color = .{ .r = 255, .g = 255, .b = 255 },
bg: Color = .{ .r = 0, .g = 0, .b = 0 },
has_fg: bool = false,
has_bg: bool = false,
bold: bool = false,
italic: bool = false,
underline: bool = false,
strikethrough: bool = false,
inverse: bool = false,

/// UTF-8 multi-byte accumulation.
utf8_buf: [4]u8 = undefined,
utf8_len: u8 = 0,
utf8_expected: u8 = 0,

/// Scroll region (top and bottom, 0-indexed, inclusive).
scroll_top: u16 = 0,
scroll_bottom: u16 = 0, // Set to rows-1 on init

pub const Color = struct { r: u8, g: u8, b: u8 };

/// Standard 256-color palette (first 16 colors).
const ansi_colors = [16]Color{
    .{ .r = 0, .g = 0, .b = 0 }, // 0 black
    .{ .r = 205, .g = 0, .b = 0 }, // 1 red
    .{ .r = 0, .g = 205, .b = 0 }, // 2 green
    .{ .r = 205, .g = 205, .b = 0 }, // 3 yellow
    .{ .r = 0, .g = 0, .b = 238 }, // 4 blue
    .{ .r = 205, .g = 0, .b = 205 }, // 5 magenta
    .{ .r = 0, .g = 205, .b = 205 }, // 6 cyan
    .{ .r = 229, .g = 229, .b = 229 }, // 7 white
    .{ .r = 127, .g = 127, .b = 127 }, // 8 bright black
    .{ .r = 255, .g = 0, .b = 0 }, // 9 bright red
    .{ .r = 0, .g = 255, .b = 0 }, // 10 bright green
    .{ .r = 255, .g = 255, .b = 0 }, // 11 bright yellow
    .{ .r = 92, .g = 92, .b = 255 }, // 12 bright blue
    .{ .r = 255, .g = 0, .b = 255 }, // 13 bright magenta
    .{ .r = 0, .g = 255, .b = 255 }, // 14 bright cyan
    .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
};

pub fn init(rows: u16) VtParser {
    return .{
        .scroll_bottom = if (rows > 0) rows - 1 else 0,
    };
}

/// Feed a buffer of bytes through the parser, updating the session's cell grid.
pub fn feed(self: *VtParser, session: *SessionManager.DaemonSession, data: []const u8) void {
    for (data) |byte| {
        self.processByte(session, byte);
    }
}

fn processByte(self: *VtParser, s: *SessionManager.DaemonSession, byte: u8) void {
    // If we're not in ground state, discard any in-progress UTF-8 sequence.
    // This prevents stale utf8_expected from misinterpreting bytes after
    // an escape sequence interrupts a multi-byte character.
    if (self.state != .ground and self.utf8_expected > 0) {
        self.utf8_expected = 0;
        self.utf8_len = 0;
    }

    switch (self.state) {
        .ground => self.processGround(s, byte),
        .escape => self.processEscape(s, byte),
        .escape_intermediate => self.processEscapeIntermediate(s, byte),
        .csi_entry => self.processCsiEntry(s, byte),
        .csi_param => self.processCsiParam(s, byte),
        .osc_string => self.processOscString(s, byte),
        .osc_string_escape => self.processOscStringEscape(s, byte),
        .dcs_string => self.processDcsApcString(byte),
        .dcs_string_escape => self.processDcsApcStringEscape(byte),
        .apc_string => self.processDcsApcString(byte),
        .apc_string_escape => self.processDcsApcStringEscape(byte),
    }
}

fn processGround(self: *VtParser, s: *SessionManager.DaemonSession, byte: u8) void {
    // Handle UTF-8 continuation bytes
    if (self.utf8_expected > 0) {
        if (byte & 0xC0 == 0x80) {
            self.utf8_buf[self.utf8_len] = byte;
            self.utf8_len += 1;
            if (self.utf8_len == self.utf8_expected) {
                const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
                self.utf8_expected = 0;
                self.utf8_len = 0;
                self.putChar(s, cp);
            }
            return;
        } else {
            // Invalid continuation — discard accumulated bytes
            self.utf8_expected = 0;
            self.utf8_len = 0;
        }
    }

    switch (byte) {
        0x1b => self.state = .escape,
        '\r' => s.cursor_x = 0,
        '\n' => self.linefeed(s),
        '\t' => {
            // Advance to next tab stop (every 8 columns)
            const next = (s.cursor_x / 8 + 1) * 8;
            s.cursor_x = @min(next, s.cols -| 1);
        },
        0x08 => s.cursor_x -|= 1, // BS
        0x07 => {}, // BEL — ignore
        0x00...0x06, 0x0e...0x1a, 0x1c...0x1f => {}, // Other C0 — ignore
        0xC2...0xDF => { // 2-byte UTF-8 lead (0xC0-0xC1 are overlong, rejected)
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 2;
        },
        0xE0...0xEF => { // 3-byte UTF-8 lead
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 3;
        },
        0xF0...0xF7 => { // 4-byte UTF-8 lead
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 4;
        },
        else => self.putChar(s, @as(u32, byte)),
    }
}

fn processEscape(self: *VtParser, s: *SessionManager.DaemonSession, byte: u8) void {
    switch (byte) {
        '[' => {
            self.state = .csi_entry;
            self.resetParams();
        },
        ']' => {
            self.osc_len = 0;
            self.state = .osc_string;
        },
        '(' => self.state = .escape_intermediate, // Charset designation — skip
        ')' => self.state = .escape_intermediate,
        'P' => { // DCS — Sixel graphics
            self.osc_len = 0;
            self.dcs_apc_is_kitty = false;
            self.state = .dcs_string;
        },
        '_' => { // APC — Kitty graphics protocol
            self.osc_len = 0;
            self.dcs_apc_is_kitty = true;
            self.state = .apc_string;
        },
        'M' => {
            // Reverse Index — cursor up, scroll down if at top
            if (s.cursor_y == self.scroll_top) {
                self.scrollDown(s);
            } else {
                s.cursor_y -|= 1;
            }
            self.state = .ground;
        },
        'D' => {
            // Index — same as LF
            self.linefeed(s);
            self.state = .ground;
        },
        'E' => {
            // Next Line
            s.cursor_x = 0;
            self.linefeed(s);
            self.state = .ground;
        },
        'c' => {
            // Full Reset (RIS)
            self.resetState(s);
            self.state = .ground;
        },
        '7' => { // DECSC — Save cursor position + attributes
            s.saved_cursor_x = s.cursor_x;
            s.saved_cursor_y = s.cursor_y;
            self.state = .ground;
        },
        '8' => { // DECRC — Restore cursor position + attributes
            s.cursor_x = @min(s.saved_cursor_x, s.cols -| 1);
            s.cursor_y = @min(s.saved_cursor_y, s.rows -| 1);
            self.state = .ground;
        },
        '=' => self.state = .ground, // Keypad application mode — ignore
        '>' => self.state = .ground, // Keypad numeric mode — ignore
        else => self.state = .ground, // Unknown — back to ground
    }
}

fn processEscapeIntermediate(self: *VtParser, _: *SessionManager.DaemonSession, byte: u8) void {
    // Eat one byte after ESC ( or ESC )
    _ = byte;
    self.state = .ground;
}

fn processCsiEntry(self: *VtParser, s: *SessionManager.DaemonSession, byte: u8) void {
    switch (byte) {
        '?' => {
            self.intermediate = '?';
            self.state = .csi_param;
        },
        '>' => {
            self.intermediate = '>';
            self.state = .csi_param;
        },
        '0'...'9' => {
            self.params[0] = byte - '0';
            self.param_has_digit = true;
            self.state = .csi_param;
        },
        ';' => {
            self.param_count = 1;
            self.state = .csi_param;
        },
        else => {
            self.state = .csi_param;
            self.processCsiParam(s, byte);
        },
    }
}

fn processCsiParam(self: *VtParser, s: *SessionManager.DaemonSession, byte: u8) void {
    switch (byte) {
        '0'...'9' => {
            const idx = if (self.param_has_digit or self.param_count > 0)
                self.param_count
            else
                0;
            if (idx < self.params.len) {
                self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
                self.param_has_digit = true;
            }
        },
        ';' => {
            if (!self.param_has_digit and self.param_count == 0) {
                self.param_count = 1; // First param was default
            } else {
                self.param_count +|= 1;
            }
            self.param_has_digit = false;
            if (self.param_count < self.params.len) {
                self.params[self.param_count] = 0;
            }
        },
        else => {
            // Final byte — dispatch
            if (self.param_has_digit) self.param_count +|= 1;
            self.dispatchCsi(s, byte);
            self.state = .ground;
        },
    }
}

fn processOscString(self: *VtParser, s: *SessionManager.DaemonSession, byte: u8) void {
    switch (byte) {
        0x1b => self.state = .osc_string_escape,
        0x07 => {
            // BEL terminates OSC (ST)
            self.dispatchOsc(s);
            self.state = .ground;
        },
        else => {
            // Accumulate OSC content
            if (self.osc_len < self.osc_buf.len) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
        },
    }
}

fn processOscStringEscape(self: *VtParser, s: *SessionManager.DaemonSession, byte: u8) void {
    if (byte == '\\') {
        // ESC \ = ST (String Terminator)
        self.dispatchOsc(s);
    } else {
        // Not a valid ST — discard accumulated content
        self.osc_len = 0;
    }
    self.state = .ground;
}

fn processDcsApcString(self: *VtParser, byte: u8) void {
    switch (byte) {
        0x1b => {
            if (self.dcs_apc_is_kitty) {
                self.state = .apc_string_escape;
            } else {
                self.state = .dcs_string_escape;
            }
        },
        0x07 => { // BEL can also terminate (some terminals)
            self.dispatchDcsApc();
            self.state = .ground;
        },
        else => {
            if (self.osc_len < self.osc_buf.len) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
        },
    }
}

fn processDcsApcStringEscape(self: *VtParser, byte: u8) void {
    if (byte == '\\') {
        self.dispatchDcsApc();
    }
    self.state = .ground;
}

fn dispatchDcsApc(self: *VtParser) void {
    const data = self.osc_buf[0..self.osc_len];
    defer self.osc_len = 0;

    if (data.len == 0) return;

    if (self.image_callback) |cb| {
        const img_type: Protocol.ImageType = if (self.dcs_apc_is_kitty) .kitty else .sixel;
        cb(img_type, data);
    }
}

fn dispatchOsc(self: *VtParser, s: *SessionManager.DaemonSession) void {
    const content = self.osc_buf[0..self.osc_len];
    defer self.osc_len = 0;

    if (content.len < 2) return;

    // OSC 52 — clipboard: "52;c;base64data"
    if (content.len >= 3 and content[0] == '5' and content[1] == '2' and content[2] == ';') {
        // Find the second semicolon (after selection parameter)
        if (std.mem.indexOfScalar(u8, content[3..], ';')) |idx| {
            const clipboard_data = content[3 + idx + 1 ..];
            if (self.clipboard_callback) |cb| {
                cb(clipboard_data);
            }
        }
        return;
    }

    // OSC 0 — set icon name + window title
    if (content[0] == '0' and content[1] == ';') {
        updateSessionTitle(s, content[2..]);
        return;
    }

    // OSC 1 — set icon name (treat as title)
    if (content[0] == '1' and content[1] == ';') {
        updateSessionTitle(s, content[2..]);
        return;
    }

    // OSC 2 — set window title
    if (content[0] == '2' and content[1] == ';') {
        updateSessionTitle(s, content[2..]);
        return;
    }
}

/// Update the session's title from an OSC sequence. Allocates a new
/// copy; on allocation failure the title is left unchanged.
fn updateSessionTitle(s: *SessionManager.DaemonSession, new_title: []const u8) void {
    if (std.mem.eql(u8, s.title, new_title)) return;
    const copy = s.alloc.dupe(u8, new_title) catch return;
    s.alloc.free(s.title);
    s.title = copy;
}

// ── CSI dispatch ──

fn dispatchCsi(self: *VtParser, s: *SessionManager.DaemonSession, final: u8) void {
    if (self.intermediate == '?') {
        self.dispatchDecPrivate(s, final);
        return;
    }

    switch (final) {
        'A' => { // CUU — Cursor Up
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            s.cursor_y -|= n;
        },
        'B' => { // CUD — Cursor Down
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            s.cursor_y = @min(s.cursor_y +| n, s.rows -| 1);
        },
        'C' => { // CUF — Cursor Forward
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            s.cursor_x = @min(s.cursor_x +| n, s.cols -| 1);
        },
        'D' => { // CUB — Cursor Back
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            s.cursor_x -|= n;
        },
        'E' => { // CNL — Cursor Next Line
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            s.cursor_y = @min(s.cursor_y +| n, s.rows -| 1);
            s.cursor_x = 0;
        },
        'F' => { // CPL — Cursor Previous Line
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            s.cursor_y -|= n;
            s.cursor_x = 0;
        },
        'G' => { // CHA — Cursor Horizontal Absolute
            const col: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] - 1 else 0;
            s.cursor_x = @min(col, s.cols -| 1);
        },
        'H', 'f' => { // CUP — Cursor Position
            const row: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] - 1 else 0;
            const col: u16 = if (self.param_count > 1 and self.params[1] > 0) self.params[1] - 1 else 0;
            s.cursor_y = @min(row, s.rows -| 1);
            s.cursor_x = @min(col, s.cols -| 1);
        },
        'J' => self.eraseInDisplay(s),
        'K' => self.eraseInLine(s),
        'L' => { // IL — Insert Lines
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            self.insertLines(s, n);
        },
        'M' => { // DL — Delete Lines
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            self.deleteLines(s, n);
        },
        'P' => { // DCH — Delete Characters
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            self.deleteChars(s, n);
        },
        '@' => { // ICH — Insert Characters
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            self.insertChars(s, n);
        },
        'X' => { // ECH — Erase Characters
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            const end = @min(s.cursor_x + n, s.cols);
            for (s.cursor_x..end) |col| {
                s.setCell(@intCast(col), s.cursor_y, self.blankCell());
            }
        },
        'd' => { // VPA — Vertical Position Absolute
            const row: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] - 1 else 0;
            s.cursor_y = @min(row, s.rows -| 1);
        },
        'm' => self.handleSgr(),
        'r' => { // DECSTBM — Set Scrolling Region
            const top: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] - 1 else 0;
            const bot: u16 = if (self.param_count > 1 and self.params[1] > 0) self.params[1] - 1 else s.rows -| 1;
            self.scroll_top = @min(top, s.rows -| 1);
            self.scroll_bottom = @min(bot, s.rows -| 1);
            // CUP to home after setting scroll region
            s.cursor_x = 0;
            s.cursor_y = 0;
        },
        'S' => { // SU — Scroll Up
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            for (0..n) |_| self.scrollUp(s);
        },
        'T' => { // SD — Scroll Down
            const n: u16 = if (self.param_count > 0 and self.params[0] > 0) self.params[0] else 1;
            for (0..n) |_| self.scrollDown(s);
        },
        'n' => {}, // DSR — Device Status Report — ignore (we don't send responses)
        'c' => {}, // DA — Device Attributes — ignore
        'h', 'l' => {}, // SM/RM — Set/Reset Mode — ignore non-private modes
        else => {}, // Unknown CSI — ignore
    }
}

fn dispatchDecPrivate(self: *VtParser, s: *SessionManager.DaemonSession, final: u8) void {
    switch (final) {
        'h' => { // DECSET
            for (self.params[0..self.param_count]) |p| {
                switch (p) {
                    1 => s.application_cursor_keys = true,
                    25 => s.cursor_visible = true,
                    1049 => {
                        // Save cursor then switch to alt screen
                        s.saved_cursor_x = s.cursor_x;
                        s.saved_cursor_y = s.cursor_y;
                        s.switchToAltScreen();
                    },
                    1047 => s.switchToAltScreen(),
                    2004 => s.bracketed_paste = true,
                    else => {},
                }
            }
        },
        'l' => { // DECRST
            for (self.params[0..self.param_count]) |p| {
                switch (p) {
                    1 => s.application_cursor_keys = false,
                    25 => s.cursor_visible = false,
                    1049 => {
                        // Switch back to main screen then restore cursor
                        s.switchToMainScreen();
                        s.cursor_x = s.saved_cursor_x;
                        s.cursor_y = s.saved_cursor_y;
                    },
                    1047 => s.switchToMainScreen(),
                    2004 => s.bracketed_paste = false,
                    else => {},
                }
            }
        },
        else => {},
    }
}

// ── Character output ──

fn putChar(self: *VtParser, s: *SessionManager.DaemonSession, codepoint: u32) void {
    if (s.cursor_x >= s.cols) {
        // Auto-wrap
        s.cursor_x = 0;
        self.linefeed(s);
    }

    const cell = self.makeCell(codepoint);
    s.setCell(s.cursor_x, s.cursor_y, cell);
    s.cursor_x += 1;
}

fn makeCell(self: *const VtParser, codepoint: u32) Protocol.WireCell {
    var flags: u8 = 0;
    if (self.bold) flags |= 0x01;
    if (self.italic) flags |= 0x02;
    if (self.underline) flags |= 0x04;
    if (self.strikethrough) flags |= 0x08;
    if (self.inverse) flags |= 0x10;
    if (self.has_fg) flags |= 0x20;
    if (self.has_bg) flags |= 0x40;

    return .{
        .codepoint = codepoint,
        .fg_r = self.fg.r,
        .fg_g = self.fg.g,
        .fg_b = self.fg.b,
        .bg_r = self.bg.r,
        .bg_g = self.bg.g,
        .bg_b = self.bg.b,
        .style_flags = flags,
        .wide = 0,
    };
}

fn blankCell(self: *const VtParser) Protocol.WireCell {
    return self.makeCell(@as(u32, ' '));
}

// ── Line operations ──

fn linefeed(self: *VtParser, s: *SessionManager.DaemonSession) void {
    if (s.cursor_y >= self.scroll_bottom) {
        self.scrollUp(s);
    } else {
        s.cursor_y += 1;
    }
}

fn scrollUp(self: *VtParser, s: *SessionManager.DaemonSession) void {
    // Save the top row to scrollback before it's overwritten
    const top: usize = self.scroll_top;
    const bot: usize = self.scroll_bottom;
    if (top == 0) s.pushScrollback(0);
    const cols: usize = s.cols;

    var row = top;
    while (row < bot) : (row += 1) {
        const dst_start = row * cols;
        const src_start = (row + 1) * cols;
        @memcpy(
            s.cells[dst_start..][0..cols],
            s.cells[src_start..][0..cols],
        );
        s.dirty_rows.set(row);
    }

    // Blank the bottom line
    const blank = self.blankCell();
    const bot_start = bot * cols;
    for (0..cols) |col| {
        s.cells[bot_start + col] = blank;
    }
    s.dirty_rows.set(bot);
}

fn scrollDown(self: *VtParser, s: *SessionManager.DaemonSession) void {
    // Move lines down within scroll region, blank the top line
    const top: usize = self.scroll_top;
    const bot: usize = self.scroll_bottom;
    const cols: usize = s.cols;

    var row = bot;
    while (row > top) : (row -= 1) {
        const dst_start = row * cols;
        const src_start = (row - 1) * cols;
        @memcpy(
            s.cells[dst_start..][0..cols],
            s.cells[src_start..][0..cols],
        );
        s.dirty_rows.set(row);
    }

    // Blank the top line
    const blank = self.blankCell();
    const top_start = top * cols;
    for (0..cols) |col| {
        s.cells[top_start + col] = blank;
    }
    s.dirty_rows.set(top);
}

// ── Erase operations ──

fn eraseInDisplay(self: *VtParser, s: *SessionManager.DaemonSession) void {
    const mode: u16 = if (self.param_count > 0) self.params[0] else 0;
    const blank = self.blankCell();

    switch (mode) {
        0 => {
            // Erase from cursor to end
            for (s.cursor_x..s.cols) |col| {
                s.setCell(@intCast(col), s.cursor_y, blank);
            }
            for ((s.cursor_y + 1)..s.rows) |row| {
                for (0..s.cols) |col| {
                    s.setCell(@intCast(col), @intCast(row), blank);
                }
            }
        },
        1 => {
            // Erase from start to cursor
            for (0..s.cursor_y) |row| {
                for (0..s.cols) |col| {
                    s.setCell(@intCast(col), @intCast(row), blank);
                }
            }
            for (0..(s.cursor_x + 1)) |col| {
                s.setCell(@intCast(col), s.cursor_y, blank);
            }
        },
        2, 3 => {
            // Erase entire display
            for (0..s.rows) |row| {
                for (0..s.cols) |col| {
                    s.setCell(@intCast(col), @intCast(row), blank);
                }
            }
        },
        else => {},
    }
}

fn eraseInLine(self: *VtParser, s: *SessionManager.DaemonSession) void {
    const mode: u16 = if (self.param_count > 0) self.params[0] else 0;
    const blank = self.blankCell();

    switch (mode) {
        0 => {
            // Erase from cursor to end of line
            for (s.cursor_x..s.cols) |col| {
                s.setCell(@intCast(col), s.cursor_y, blank);
            }
        },
        1 => {
            // Erase from start to cursor
            for (0..(s.cursor_x + 1)) |col| {
                s.setCell(@intCast(col), s.cursor_y, blank);
            }
        },
        2 => {
            // Erase entire line
            for (0..s.cols) |col| {
                s.setCell(@intCast(col), s.cursor_y, blank);
            }
        },
        else => {},
    }
}

fn insertLines(self: *VtParser, s: *SessionManager.DaemonSession, n: u16) void {
    const bot: usize = self.scroll_bottom;
    const cur: usize = s.cursor_y;
    const cols: usize = s.cols;
    const count: usize = @min(n, bot - cur + 1);

    // Shift lines down
    var row = bot;
    while (row >= cur + count) : (row -= 1) {
        const dst_start = row * cols;
        const src_start = (row - count) * cols;
        @memcpy(s.cells[dst_start..][0..cols], s.cells[src_start..][0..cols]);
        s.dirty_rows.set(row);
        if (row == 0) break;
    }

    // Blank inserted lines
    const blank = self.blankCell();
    for (cur..cur + count) |r| {
        for (0..cols) |col| s.cells[r * cols + col] = blank;
        s.dirty_rows.set(r);
    }
}

fn deleteLines(self: *VtParser, s: *SessionManager.DaemonSession, n: u16) void {
    const bot: usize = self.scroll_bottom;
    const cur: usize = s.cursor_y;
    const cols: usize = s.cols;
    const count: usize = @min(n, bot - cur + 1);

    // Shift lines up
    var row = cur;
    while (row + count <= bot) : (row += 1) {
        const dst_start = row * cols;
        const src_start = (row + count) * cols;
        @memcpy(s.cells[dst_start..][0..cols], s.cells[src_start..][0..cols]);
        s.dirty_rows.set(row);
    }

    // Blank vacated lines at bottom
    const blank = self.blankCell();
    for ((bot + 1 - count)..(bot + 1)) |r| {
        for (0..cols) |col| s.cells[r * cols + col] = blank;
        s.dirty_rows.set(r);
    }
}

fn deleteChars(self: *VtParser, s: *SessionManager.DaemonSession, n: u16) void {
    const cols: usize = s.cols;
    const cur_x: usize = s.cursor_x;
    const count: usize = @min(n, cols - cur_x);
    const row_start = @as(usize, s.cursor_y) * cols;

    // Shift cells left
    var col = cur_x;
    while (col + count < cols) : (col += 1) {
        s.cells[row_start + col] = s.cells[row_start + col + count];
    }

    // Blank vacated cells at end
    const blank = self.blankCell();
    while (col < cols) : (col += 1) {
        s.cells[row_start + col] = blank;
    }
    s.dirty_rows.set(s.cursor_y);
}

fn insertChars(self: *VtParser, s: *SessionManager.DaemonSession, n: u16) void {
    const cols: usize = s.cols;
    const cur_x: usize = s.cursor_x;
    const count: usize = @min(n, cols - cur_x);
    const row_start = @as(usize, s.cursor_y) * cols;

    // Shift cells right
    var col = cols - 1;
    while (col >= cur_x + count) : (col -= 1) {
        s.cells[row_start + col] = s.cells[row_start + col - count];
        if (col == 0) break;
    }

    // Blank inserted cells
    const blank = self.blankCell();
    for (cur_x..cur_x + count) |c| {
        s.cells[row_start + c] = blank;
    }
    s.dirty_rows.set(s.cursor_y);
}

// ── SGR (Select Graphic Rendition) ──

fn handleSgr(self: *VtParser) void {
    if (self.param_count == 0) {
        self.resetSgr();
        return;
    }

    var i: usize = 0;
    while (i < self.param_count) : (i += 1) {
        const p = self.params[i];
        switch (p) {
            0 => self.resetSgr(),
            1 => self.bold = true,
            3 => self.italic = true,
            4 => self.underline = true,
            7 => self.inverse = true,
            9 => self.strikethrough = true,
            22 => self.bold = false,
            23 => self.italic = false,
            24 => self.underline = false,
            27 => self.inverse = false,
            29 => self.strikethrough = false,
            30...37 => {
                self.fg = ansi_colors[p - 30];
                self.has_fg = true;
            },
            38 => {
                i += 1;
                if (i < self.param_count and self.params[i] == 5) {
                    // 256-color: ESC[38;5;Nm
                    i += 1;
                    if (i < self.param_count) {
                        self.fg = color256(self.params[i]);
                        self.has_fg = true;
                    }
                } else if (i < self.param_count and self.params[i] == 2) {
                    // True color: ESC[38;2;R;G;Bm
                    if (i + 3 <= self.param_count) {
                        self.fg = .{
                            .r = @truncate(self.params[i + 1]),
                            .g = @truncate(self.params[i + 2]),
                            .b = @truncate(self.params[i + 3]),
                        };
                        self.has_fg = true;
                        i += 3;
                    }
                }
            },
            39 => {
                self.fg = .{ .r = 255, .g = 255, .b = 255 };
                self.has_fg = false;
            },
            40...47 => {
                self.bg = ansi_colors[p - 40];
                self.has_bg = true;
            },
            48 => {
                i += 1;
                if (i < self.param_count and self.params[i] == 5) {
                    i += 1;
                    if (i < self.param_count) {
                        self.bg = color256(self.params[i]);
                        self.has_bg = true;
                    }
                } else if (i < self.param_count and self.params[i] == 2) {
                    if (i + 3 <= self.param_count) {
                        self.bg = .{
                            .r = @truncate(self.params[i + 1]),
                            .g = @truncate(self.params[i + 2]),
                            .b = @truncate(self.params[i + 3]),
                        };
                        self.has_bg = true;
                        i += 3;
                    }
                }
            },
            49 => {
                self.bg = .{ .r = 0, .g = 0, .b = 0 };
                self.has_bg = false;
            },
            90...97 => {
                self.fg = ansi_colors[p - 90 + 8];
                self.has_fg = true;
            },
            100...107 => {
                self.bg = ansi_colors[p - 100 + 8];
                self.has_bg = true;
            },
            else => {},
        }
    }
}

fn resetSgr(self: *VtParser) void {
    self.fg = .{ .r = 255, .g = 255, .b = 255 };
    self.bg = .{ .r = 0, .g = 0, .b = 0 };
    self.has_fg = false;
    self.has_bg = false;
    self.bold = false;
    self.italic = false;
    self.underline = false;
    self.strikethrough = false;
    self.inverse = false;
}

// ── Helpers ──

fn resetParams(self: *VtParser) void {
    self.params = [_]u16{0} ** 16;
    self.param_count = 0;
    self.param_has_digit = false;
    self.intermediate = 0;
}

fn resetState(self: *VtParser, s: *SessionManager.DaemonSession) void {
    self.resetSgr();
    self.scroll_top = 0;
    self.scroll_bottom = s.rows -| 1;
    s.cursor_x = 0;
    s.cursor_y = 0;
    s.cursor_visible = true;
    // Clear screen
    const blank = self.blankCell();
    for (0..s.rows) |row| {
        for (0..s.cols) |col| {
            s.cells[row * @as(usize, s.cols) + col] = blank;
        }
        s.dirty_rows.set(row);
    }
}

/// Decode a UTF-8 byte sequence into a Unicode codepoint.
/// Returns U+FFFD (replacement character) for invalid sequences.
fn decodeUtf8(bytes: []const u8) u32 {
    switch (bytes.len) {
        2 => {
            const cp = (@as(u32, bytes[0] & 0x1F) << 6) |
                @as(u32, bytes[1] & 0x3F);
            if (cp < 0x80) return 0xFFFD; // overlong
            return cp;
        },
        3 => {
            const cp = (@as(u32, bytes[0] & 0x0F) << 12) |
                (@as(u32, bytes[1] & 0x3F) << 6) |
                @as(u32, bytes[2] & 0x3F);
            if (cp < 0x800) return 0xFFFD; // overlong
            if (cp >= 0xD800 and cp <= 0xDFFF) return 0xFFFD; // surrogate
            return cp;
        },
        4 => {
            const cp = (@as(u32, bytes[0] & 0x07) << 18) |
                (@as(u32, bytes[1] & 0x3F) << 12) |
                (@as(u32, bytes[2] & 0x3F) << 6) |
                @as(u32, bytes[3] & 0x3F);
            if (cp < 0x10000 or cp > 0x10FFFF) return 0xFFFD;
            return cp;
        },
        else => return 0xFFFD,
    }
}

/// Convert a 256-color index to RGB.
fn color256(idx: u16) Color {
    if (idx < 16) return ansi_colors[idx];
    if (idx < 232) {
        // 6x6x6 color cube
        const ci = idx - 16;
        const b_idx = ci % 6;
        const g_idx = (ci / 6) % 6;
        const r_idx = ci / 36;
        return .{
            .r = if (r_idx == 0) 0 else @truncate(r_idx * 40 + 55),
            .g = if (g_idx == 0) 0 else @truncate(g_idx * 40 + 55),
            .b = if (b_idx == 0) 0 else @truncate(b_idx * 40 + 55),
        };
    }
    // Grayscale ramp
    const gray: u8 = @truncate((idx - 232) * 10 + 8);
    return .{ .r = gray, .g = gray, .b = gray };
}

// ── Tests ──

test "basic character output" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    s.clearDirty();

    var parser = VtParser.init(s.rows);
    parser.feed(s, "Hi");

    try std.testing.expectEqual(@as(u32, 'H'), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'i'), s.getCell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u16, 2), s.cursor_x);
    try std.testing.expectEqual(@as(u16, 0), s.cursor_y);
}

test "CR LF moves cursor" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 5, null);
    var parser = VtParser.init(s.rows);

    parser.feed(s, "AB\r\nCD");

    try std.testing.expectEqual(@as(u32, 'A'), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), s.getCell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'C'), s.getCell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u32, 'D'), s.getCell(1, 1).codepoint);
}

test "CSI cursor position (CUP)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 5, null);
    var parser = VtParser.init(s.rows);

    // ESC[3;5H — move to row 3, col 5 (1-based → 2,4 0-based)
    parser.feed(s, "\x1b[3;5H");

    try std.testing.expectEqual(@as(u16, 4), s.cursor_x);
    try std.testing.expectEqual(@as(u16, 2), s.cursor_y);
}

test "SGR colors" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // Set red foreground (31), write 'R', reset (0)
    parser.feed(s, "\x1b[31mR\x1b[0m");

    const cell = s.getCell(0, 0);
    try std.testing.expectEqual(@as(u32, 'R'), cell.codepoint);
    try std.testing.expectEqual(@as(u8, 205), cell.fg_r);
    try std.testing.expectEqual(@as(u8, 0), cell.fg_g);
    try std.testing.expect((cell.style_flags & 0x20) != 0); // has_fg
}

test "erase in display (ED 2)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(5, 3, null);
    var parser = VtParser.init(s.rows);

    parser.feed(s, "ABCDE");
    try std.testing.expectEqual(@as(u32, 'A'), s.getCell(0, 0).codepoint);

    parser.feed(s, "\x1b[2J");

    try std.testing.expectEqual(@as(u32, ' '), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, ' '), s.getCell(4, 2).codepoint);
}

test "scroll up when cursor at bottom" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(5, 3, null);
    var parser = VtParser.init(s.rows);

    parser.feed(s, "AAA\r\nBBB\r\nCCC\r\nDDD");

    // After 4 lines in 3-row terminal:
    // Row 0 should now have "BBB" (scrolled up)
    // Row 1 should have "CCC"
    // Row 2 should have "DDD"
    try std.testing.expectEqual(@as(u32, 'B'), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'C'), s.getCell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u32, 'D'), s.getCell(0, 2).codepoint);
}

test "auto-wrap at end of line" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(3, 3, null);
    var parser = VtParser.init(s.rows);

    parser.feed(s, "ABCD");

    // 'D' should wrap to next line
    try std.testing.expectEqual(@as(u32, 'A'), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), s.getCell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'C'), s.getCell(2, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'D'), s.getCell(0, 1).codepoint);
}

test "erase in line (EL)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(5, 3, null);
    var parser = VtParser.init(s.rows);

    parser.feed(s, "ABCDE");
    // Cursor at col 5 (past end), move to col 2
    parser.feed(s, "\x1b[1;3H"); // row 1, col 3 → (2, 0)
    parser.feed(s, "\x1b[K"); // Erase from cursor to end of line

    try std.testing.expectEqual(@as(u32, 'A'), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), s.getCell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u32, ' '), s.getCell(2, 0).codepoint);
    try std.testing.expectEqual(@as(u32, ' '), s.getCell(3, 0).codepoint);
}

test "cursor visibility" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    try std.testing.expect(s.cursor_visible);
    parser.feed(s, "\x1b[?25l"); // Hide cursor
    try std.testing.expect(!s.cursor_visible);
    parser.feed(s, "\x1b[?25h"); // Show cursor
    try std.testing.expect(s.cursor_visible);
}

test "256-color palette" {
    try std.testing.expectEqual(@as(u8, 0), color256(0).r); // black
    try std.testing.expectEqual(@as(u8, 255), color256(15).r); // bright white
    // Color cube: index 196 = rgb(5,0,0) → (255, 0, 0)
    try std.testing.expectEqual(@as(u8, 255), color256(196).r);
    try std.testing.expectEqual(@as(u8, 0), color256(196).g);
    // Grayscale: index 232 → gray 8
    try std.testing.expectEqual(@as(u8, 8), color256(232).r);
}

test "Kitty graphics APC sequence captured" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    var captured_type: ?Protocol.ImageType = null;
    var captured_len: usize = 0;

    const Ctx = struct {
        var cb_type: ?Protocol.ImageType = null;
        var cb_len: usize = 0;
        fn callback(img_type: Protocol.ImageType, data: []const u8) void {
            cb_type = img_type;
            cb_len = data.len;
        }
    };
    Ctx.cb_type = null;
    Ctx.cb_len = 0;
    parser.image_callback = &Ctx.callback;

    // ESC _ G ... ESC backslash (Kitty graphics)
    parser.feed(s, "\x1b_Gf=100,a=T;AAAA\x1b\\");

    captured_type = Ctx.cb_type;
    captured_len = Ctx.cb_len;

    try std.testing.expectEqual(Protocol.ImageType.kitty, captured_type.?);
    try std.testing.expect(captured_len > 0);
}

test "Sixel DCS sequence captured" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    const Ctx = struct {
        var cb_type: ?Protocol.ImageType = null;
        fn callback(img_type: Protocol.ImageType, _: []const u8) void {
            cb_type = img_type;
        }
    };
    Ctx.cb_type = null;
    parser.image_callback = &Ctx.callback;

    // ESC P ... ESC backslash (Sixel DCS)
    parser.feed(s, "\x1bPq#0;2;0;0;0~-\x1b\\");

    try std.testing.expectEqual(Protocol.ImageType.sixel, Ctx.cb_type.?);
}

test "UTF-8 2-byte character (é)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // é = U+00E9 = 0xC3 0xA9
    parser.feed(s, "\xc3\xa9");

    try std.testing.expectEqual(@as(u32, 0xE9), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u16, 1), s.cursor_x);
}

test "UTF-8 3-byte character (中)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // 中 = U+4E2D = 0xE4 0xB8 0xAD
    parser.feed(s, "\xe4\xb8\xad");

    try std.testing.expectEqual(@as(u32, 0x4E2D), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u16, 1), s.cursor_x);
}

test "UTF-8 4-byte character (emoji 😀)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80
    parser.feed(s, "\xf0\x9f\x98\x80");

    try std.testing.expectEqual(@as(u32, 0x1F600), s.getCell(0, 0).codepoint);
}

test "UTF-8 mixed with ASCII" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // "Aé" — ASCII A then UTF-8 é
    parser.feed(s, "A\xc3\xa9B");

    try std.testing.expectEqual(@as(u32, 'A'), s.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 0xE9), s.getCell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), s.getCell(2, 0).codepoint);
}

test "UTF-8 invalid continuation replaced" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // 0xC3 followed by non-continuation byte 'X'
    parser.feed(s, "\xc3X");

    // The invalid sequence is discarded, then 'X' is processed as ASCII
    try std.testing.expectEqual(@as(u32, 'X'), s.getCell(0, 0).codepoint);
}

test "decodeUtf8 helper" {
    // 2-byte: é = U+00E9
    try std.testing.expectEqual(@as(u32, 0xE9), decodeUtf8(&[_]u8{ 0xC3, 0xA9 }));
    // 3-byte: 中 = U+4E2D
    try std.testing.expectEqual(@as(u32, 0x4E2D), decodeUtf8(&[_]u8{ 0xE4, 0xB8, 0xAD }));
    // 4-byte: 😀 = U+1F600
    try std.testing.expectEqual(@as(u32, 0x1F600), decodeUtf8(&[_]u8{ 0xF0, 0x9F, 0x98, 0x80 }));
    // Overlong 2-byte → replacement
    try std.testing.expectEqual(@as(u32, 0xFFFD), decodeUtf8(&[_]u8{ 0xC0, 0x80 }));
    // Invalid length → replacement
    try std.testing.expectEqual(@as(u32, 0xFFFD), decodeUtf8(&[_]u8{0x80}));
}

test "OSC 0 sets session title (BEL terminator)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // OSC 0;my title BEL
    parser.feed(s, "\x1b]0;my title\x07");

    try std.testing.expectEqualStrings("my title", s.title);
}

test "OSC 2 sets session title (ST terminator)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    // OSC 2;zsh ESC backslash (ST)
    parser.feed(s, "\x1b]2;zsh\x1b\\");

    try std.testing.expectEqualStrings("zsh", s.title);
}

test "OSC title updates replace previous" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    parser.feed(s, "\x1b]0;first\x07");
    try std.testing.expectEqualStrings("first", s.title);

    parser.feed(s, "\x1b]2;second\x07");
    try std.testing.expectEqualStrings("second", s.title);
}

test "alternate screen buffer (mode 1049)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(5, 3, null);
    var parser = VtParser.init(s.rows);

    // Write to main screen
    parser.feed(s, "HELLO");
    try std.testing.expectEqual(@as(u32, 'H'), s.getCell(0, 0).codepoint);
    try std.testing.expect(!s.alt_screen_active);

    // Switch to alt screen (ESC[?1049h)
    parser.feed(s, "\x1b[?1049h");
    try std.testing.expect(s.alt_screen_active);
    // Alt screen should be blank
    try std.testing.expectEqual(@as(u32, 0), s.getCell(0, 0).codepoint);

    // Write on alt screen
    parser.feed(s, "VIM");
    try std.testing.expectEqual(@as(u32, 'V'), s.getCell(0, 0).codepoint);

    // Switch back to main screen (ESC[?1049l)
    parser.feed(s, "\x1b[?1049l");
    try std.testing.expect(!s.alt_screen_active);
    // Main screen should be restored
    try std.testing.expectEqual(@as(u32, 'H'), s.getCell(0, 0).codepoint);
}

test "cursor save/restore (DECSC/DECRC)" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 5, null);
    var parser = VtParser.init(s.rows);

    // Move cursor to (3, 2)
    parser.feed(s, "\x1b[3;4H"); // row 3, col 4 (1-based) = (3, 2) 0-based
    try std.testing.expectEqual(@as(u16, 3), s.cursor_x);
    try std.testing.expectEqual(@as(u16, 2), s.cursor_y);

    // Save cursor (ESC 7)
    parser.feed(s, "\x1b7");

    // Move cursor elsewhere
    parser.feed(s, "\x1b[1;1H");
    try std.testing.expectEqual(@as(u16, 0), s.cursor_x);
    try std.testing.expectEqual(@as(u16, 0), s.cursor_y);

    // Restore cursor (ESC 8)
    parser.feed(s, "\x1b8");
    try std.testing.expectEqual(@as(u16, 3), s.cursor_x);
    try std.testing.expectEqual(@as(u16, 2), s.cursor_y);
}

test "bracketed paste mode" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    try std.testing.expect(!s.bracketed_paste);

    // Enable bracketed paste (ESC[?2004h)
    parser.feed(s, "\x1b[?2004h");
    try std.testing.expect(s.bracketed_paste);

    // Disable bracketed paste (ESC[?2004l)
    parser.feed(s, "\x1b[?2004l");
    try std.testing.expect(!s.bracketed_paste);
}

test "application cursor keys mode" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    const s = try mgr.createSession(10, 3, null);
    var parser = VtParser.init(s.rows);

    try std.testing.expect(!s.application_cursor_keys);

    // Enable (ESC[?1h)
    parser.feed(s, "\x1b[?1h");
    try std.testing.expect(s.application_cursor_keys);

    // Disable (ESC[?1l)
    parser.feed(s, "\x1b[?1l");
    try std.testing.expect(!s.application_cursor_keys);
}
