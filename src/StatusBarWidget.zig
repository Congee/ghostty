//! StatusBarWidget composes status bar content from multiple widget sources.
//! Widgets are evaluated on demand and their output is concatenated into
//! left-aligned and right-aligned segments for the status bar.
//!
//! Built-in widgets:
//!   {session}   — Session name or id
//!   {title}     — Terminal title
//!   {pwd}       — Current working directory (basename)
//!   {command}   — Running command name
//!   {prefix}    — Shows prefix key indicator when in leader sequence
//!   {time}      — Current time (HH:MM)
//!   {time:fmt}  — Current time with custom format
//!   {tabs}      — Tab list like tmux: [0:zsh* 1:vim 2:htop]
//!
//! Any literal text is passed through as-is.
const StatusBarWidget = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");

const log = std.log.scoped(.status_bar_widget);

alloc: Allocator,

/// The format string for the left side.
left_fmt: []const u8,
/// The format string for the right side.
right_fmt: []const u8,

pub fn init(alloc: Allocator, left_fmt: ?[]const u8, right_fmt: ?[]const u8) StatusBarWidget {
    return .{
        .alloc = alloc,
        .left_fmt = left_fmt orelse " {tabs} {pwd}",
        .right_fmt = right_fmt orelse "{prefix} {time} ",
    };
}

/// Info about a single tab for the {tabs} widget.
pub const TabInfo = struct {
    index: u32,
    label: []const u8,
    is_active: bool,
};

/// Context for widget evaluation.
pub const Context = struct {
    session: ?*const Session = null,
    prefix_active: bool = false,
    prefix_key: ?[]const u8 = null,
    /// Tab list for the {tabs} widget. Provided by the apprt.
    tabs: []const TabInfo = &.{},
};

/// Evaluate the format string with the given context, returning owned text.
pub fn renderLeft(self: *const StatusBarWidget, ctx: Context) ![]u8 {
    return self.render(self.left_fmt, ctx);
}

pub fn renderRight(self: *const StatusBarWidget, ctx: Context) ![]u8 {
    return self.render(self.right_fmt, ctx);
}

fn render(self: *const StatusBarWidget, fmt: []const u8, ctx: Context) ![]u8 {
    var result = std.ArrayList(u8).init(self.alloc);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, fmt, i + 1, '}')) |end| {
                const tag = fmt[i + 1 .. end];
                try self.expandTag(&result, tag, ctx);
                i = end + 1;
                continue;
            }
        }
        try result.append(fmt[i]);
        i += 1;
    }

    return result.toOwnedSlice();
}

fn expandTag(self: *const StatusBarWidget, out: *std.ArrayList(u8), tag: []const u8, ctx: Context) !void {
    _ = self;

    if (std.mem.eql(u8, tag, "session")) {
        if (ctx.session) |s| {
            try out.appendSlice(s.displayLabel());
        }
        return;
    }

    if (std.mem.eql(u8, tag, "title")) {
        if (ctx.session) |s| {
            if (s.title) |t| try out.appendSlice(t);
        }
        return;
    }

    if (std.mem.eql(u8, tag, "pwd")) {
        if (ctx.session) |s| {
            const info = s.getInfo();
            if (info.pwd) |pwd| {
                // Show basename only
                if (std.mem.lastIndexOfScalar(u8, pwd, '/')) |idx| {
                    try out.appendSlice(pwd[idx + 1 ..]);
                } else {
                    try out.appendSlice(pwd);
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, tag, "command")) {
        if (ctx.session) |s| {
            const info = s.getInfo();
            if (info.command) |cmd| {
                const name = std.mem.sliceTo(cmd, 0);
                // Show basename of command
                if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| {
                    try out.appendSlice(name[idx + 1 ..]);
                } else {
                    try out.appendSlice(name);
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, tag, "tabs")) {
        if (ctx.tabs.len == 0) return;
        for (ctx.tabs, 0..) |tab, i| {
            if (i > 0) try out.append(' ');
            // Format: [index:label] for active, [index:label] for all
            try out.append('[');
            var idx_buf: [10]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{tab.index}) catch return;
            try out.appendSlice(idx_str);
            try out.append(':');
            try out.appendSlice(tab.label);
            if (tab.is_active) try out.append('*');
            try out.append(']');
        }
        return;
    }

    if (std.mem.eql(u8, tag, "prefix")) {
        if (ctx.prefix_active) {
            try out.appendSlice(ctx.prefix_key orelse "^B");
            try out.appendSlice("-");
        }
        return;
    }

    if (std.mem.eql(u8, tag, "time")) {
        const ts = std.time.timestamp();
        const day_seconds: u64 = @intCast(@mod(ts, 86400));
        const hours = day_seconds / 3600;
        const minutes = (day_seconds % 3600) / 60;
        var buf: [5]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ hours, minutes }) catch return;
        try out.appendSlice(&buf);
        return;
    }

    // Unknown tag — pass through as literal
    try out.append('{');
    try out.appendSlice(tag);
    try out.append('}');
}
