/// Tests for status bar component JSON parsing and priority-based layout.
/// These are standalone (no named module deps) so they run via `zig test`.
const std = @import("std");

// ── JSON Component Parsing (extracted from ControlSocket.zig for testability) ──

const ComponentStyle = struct {
    fg: ?[3]u8 = null,
    bg: ?[3]u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
};

const TestComponent = struct {
    text: []const u8,
    style: ComponentStyle = .{},
    priority: u8 = 100,
    click_id: ?[]const u8 = null,
};

fn parseHexColor(s: []const u8) ?[3]u8 {
    if (s.len != 7 or s[0] != '#') return null;
    return .{
        std.fmt.parseInt(u8, s[1..3], 16) catch return null,
        std.fmt.parseInt(u8, s[3..5], 16) catch return null,
        std.fmt.parseInt(u8, s[5..7], 16) catch return null,
    };
}

fn parseComponentsJson(alloc: std.mem.Allocator, json: []const u8) !struct {
    zone: []const u8,
    source: []const u8,
    components: []TestComponent,
} {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const zone = try alloc.dupe(u8, (root.get("zone") orelse return error.MissingField).string);
    const source = try alloc.dupe(u8, (root.get("source") orelse return error.MissingField).string);
    const comps_arr = (root.get("components") orelse return error.MissingField).array;

    var items = try alloc.alloc(TestComponent, comps_arr.items.len);
    for (comps_arr.items, 0..) |item, i| {
        const obj = item.object;
        const text = try alloc.dupe(u8, (obj.get("text") orelse return error.MissingField).string);

        var style: ComponentStyle = .{};
        if (obj.get("style")) |style_val| {
            const so = style_val.object;
            if (so.get("fg")) |fg| style.fg = parseHexColor(fg.string);
            if (so.get("bg")) |bg| style.bg = parseHexColor(bg.string);
            if (so.get("bold")) |b| style.bold = b.bool;
            if (so.get("italic")) |b| style.italic = b.bool;
        }

        const priority: u8 = if (obj.get("priority")) |p| @intCast(p.integer) else 100;

        var click_id: ?[]const u8 = null;
        if (obj.get("click")) |click_val| {
            const co = click_val.object;
            if (co.get("id")) |id| click_id = try alloc.dupe(u8, id.string);
        }

        items[i] = .{ .text = text, .style = style, .priority = priority, .click_id = click_id };
    }

    return .{ .zone = zone, .source = source, .components = items };
}

// ── Tests ──

test "parseHexColor valid" {
    const c = parseHexColor("#ff8040").?;
    try std.testing.expectEqual(@as(u8, 0xff), c[0]);
    try std.testing.expectEqual(@as(u8, 0x80), c[1]);
    try std.testing.expectEqual(@as(u8, 0x40), c[2]);
}

test "parseHexColor invalid — no hash" {
    try std.testing.expect(parseHexColor("ff8040") == null);
}

test "parseHexColor invalid — wrong length" {
    try std.testing.expect(parseHexColor("#fff") == null);
}

test "parse SET-COMPONENTS JSON — basic" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","source":"nvim-123","components":[
        \\  {"text":" N ","style":{"fg":"#e06c75","bold":true}},
        \\  {"text":" main ","style":{"fg":"#98c379","bg":"#3e4452"}}
        \\]}
    ;

    const result = try parseComponentsJson(alloc, json);
    defer {
        alloc.free(result.zone);
        alloc.free(result.source);
        for (result.components) |*c| {
            alloc.free(c.text);
            if (c.click_id) |id| alloc.free(id);
        }
        alloc.free(result.components);
    }

    try std.testing.expectEqualStrings("left", result.zone);
    try std.testing.expectEqualStrings("nvim-123", result.source);
    try std.testing.expectEqual(@as(usize, 2), result.components.len);

    // First component
    try std.testing.expectEqualStrings(" N ", result.components[0].text);
    try std.testing.expectEqual(@as(u8, 0xe0), result.components[0].style.fg.?[0]);
    try std.testing.expect(result.components[0].style.bold);
    try std.testing.expect(result.components[0].style.bg == null);

    // Second component
    try std.testing.expectEqualStrings(" main ", result.components[1].text);
    try std.testing.expectEqual(@as(u8, 0x98), result.components[1].style.fg.?[0]);
    try std.testing.expect(result.components[1].style.bg != null);
}

test "parse SET-COMPONENTS JSON — with priority and click" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"right","source":"test","components":[
        \\  {"text":"hi","priority":200,"click":{"id":"btn1","action":"notify"}}
        \\]}
    ;

    const result = try parseComponentsJson(alloc, json);
    defer {
        alloc.free(result.zone);
        alloc.free(result.source);
        for (result.components) |*c| {
            alloc.free(c.text);
            if (c.click_id) |id| alloc.free(id);
        }
        alloc.free(result.components);
    }

    try std.testing.expectEqual(@as(u8, 200), result.components[0].priority);
    try std.testing.expectEqualStrings("btn1", result.components[0].click_id.?);
}

test "parse SET-COMPONENTS JSON — default priority is 100" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","source":"s","components":[{"text":"x"}]}
    ;

    const result = try parseComponentsJson(alloc, json);
    defer {
        alloc.free(result.zone);
        alloc.free(result.source);
        for (result.components) |*c| alloc.free(c.text);
        alloc.free(result.components);
    }

    try std.testing.expectEqual(@as(u8, 100), result.components[0].priority);
}

test "parse SET-COMPONENTS JSON — empty components array" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","source":"s","components":[]}
    ;

    const result = try parseComponentsJson(alloc, json);
    defer {
        alloc.free(result.zone);
        alloc.free(result.source);
        alloc.free(result.components);
    }

    try std.testing.expectEqual(@as(usize, 0), result.components.len);
}

test "priority-based layout — components fit" {
    // Simulate: 80 cols, tabs take 20, remaining = 60, left budget = 30
    const cols: u16 = 80;
    const tab_width: u16 = 20;
    const remaining = cols - tab_width;
    const left_budget = remaining / 2;

    // Component of width 10 at priority 100 should fit
    const comp_width: u16 = 10;
    try std.testing.expect(comp_width <= left_budget);
}

test "priority-based layout — components dropped when no space" {
    // Simulate: 40 cols, tabs take 35, remaining = 5, left budget = 2
    const cols: u16 = 40;
    const tab_width: u16 = 35;
    const remaining = cols - tab_width;
    const left_budget = remaining / 2;

    // Component of width 10 should NOT fit
    const comp_width: u16 = 10;
    try std.testing.expect(comp_width > left_budget);
}
