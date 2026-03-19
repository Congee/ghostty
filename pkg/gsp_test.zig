/// Tests for status bar component protocol: JSON parsing, VT escape generation,
/// priority-based layout, click region tracking, and tab width calculation.
const std = @import("std");

// ── Types (mirroring renderer/State.zig, standalone for testability) ──

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

const ClickRegion = struct {
    x_start: u16,
    x_end: u16,
    click_id: []const u8,
};

// ── Extracted pure functions ──

fn parseHexColor(s: []const u8) ?[3]u8 {
    if (s.len != 7 or s[0] != '#') return null;
    return .{
        std.fmt.parseInt(u8, s[1..3], 16) catch return null,
        std.fmt.parseInt(u8, s[3..5], 16) catch return null,
        std.fmt.parseInt(u8, s[5..7], 16) catch return null,
    };
}

/// Generate VT SGR escape sequence for a component's style + text.
/// Returns the byte sequence that would be fed to the terminal.
fn writeComponentEsc(writer: anytype, comp: TestComponent) !void {
    if (comp.style.fg) |fg| {
        try writer.print("\x1b[38;2;{d};{d};{d}m", .{ fg[0], fg[1], fg[2] });
    }
    if (comp.style.bg) |bg| {
        try writer.print("\x1b[48;2;{d};{d};{d}m", .{ bg[0], bg[1], bg[2] });
    }
    if (comp.style.bold) try writer.writeAll("\x1b[1m");
    if (comp.style.italic) try writer.writeAll("\x1b[3m");
    if (comp.style.underline) try writer.writeAll("\x1b[4m");
    if (comp.style.strikethrough) try writer.writeAll("\x1b[9m");
    try writer.writeAll(comp.text);
    try writer.writeAll("\x1b[0m\x1b[7m");
}

/// Calculate the display width of a tab entry: " idx:label" or " idx:label*"
fn tabWidth(index: usize, label_len: usize, is_active: bool) u16 {
    var w: u16 = 1; // leading space
    var iv = index;
    var digits: u16 = 1;
    while (iv >= 10) : (iv /= 10) digits += 1;
    w += digits + 1; // digits + ':'
    w += @intCast(label_len);
    if (is_active) w += 1; // '*'
    return w;
}

/// Priority-based layout: given a budget and a slice of components sorted by
/// priority descending, returns which indices fit.
fn layoutComponents(
    components: []const TestComponent,
    budget: u16,
    result_indices: []usize,
) usize {
    var used: u16 = 0;
    var count: usize = 0;
    for (components, 0..) |comp, i| {
        const w: u16 = @intCast(comp.text.len);
        if (w <= budget - used) {
            if (count < result_indices.len) {
                result_indices[count] = i;
                count += 1;
            }
            used += w;
        }
    }
    return count;
}

/// Build click regions from a sequence of components starting at col_pos.
fn buildClickRegions(
    components: []const TestComponent,
    start_col: u16,
    regions: []ClickRegion,
) usize {
    var col = start_col;
    var count: usize = 0;
    for (components) |comp| {
        const w: u16 = @intCast(comp.text.len);
        if (comp.click_id) |id| {
            if (count < regions.len) {
                regions[count] = .{
                    .x_start = col,
                    .x_end = col + w,
                    .click_id = id,
                };
                count += 1;
            }
        }
        col += w;
    }
    return count;
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
    errdefer alloc.free(zone);
    const source = try alloc.dupe(u8, (root.get("source") orelse return error.MissingField).string);
    errdefer alloc.free(source);
    const comps_arr = (root.get("components") orelse return error.MissingField).array;

    var items = try alloc.alloc(TestComponent, comps_arr.items.len);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*c| {
            alloc.free(c.text);
            if (c.click_id) |id| alloc.free(id);
        }
        alloc.free(items);
    }
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
        initialized += 1;
    }

    return .{ .zone = zone, .source = source, .components = items };
}

fn freeResult(alloc: std.mem.Allocator, result: anytype) void {
    alloc.free(result.zone);
    alloc.free(result.source);
    for (result.components) |*c| {
        alloc.free(c.text);
        if (c.click_id) |id| alloc.free(id);
    }
    alloc.free(result.components);
}

// ── Tests: Hex Color Parsing ──

test "parseHexColor valid" {
    const c = parseHexColor("#ff8040").?;
    try std.testing.expectEqual(@as(u8, 0xff), c[0]);
    try std.testing.expectEqual(@as(u8, 0x80), c[1]);
    try std.testing.expectEqual(@as(u8, 0x40), c[2]);
}

test "parseHexColor black" {
    const c = parseHexColor("#000000").?;
    try std.testing.expectEqual(@as(u8, 0), c[0]);
    try std.testing.expectEqual(@as(u8, 0), c[1]);
    try std.testing.expectEqual(@as(u8, 0), c[2]);
}

test "parseHexColor invalid — no hash" {
    try std.testing.expect(parseHexColor("ff8040") == null);
}

test "parseHexColor invalid — wrong length" {
    try std.testing.expect(parseHexColor("#fff") == null);
}

test "parseHexColor invalid — not hex" {
    try std.testing.expect(parseHexColor("#gggggg") == null);
}

// ── Tests: VT Escape Generation ──

test "writeComponentEsc — plain text" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeComponentEsc(fbs.writer(), .{ .text = "hello" });
    const out = fbs.getWritten();
    // Should contain the text and end with reset+reverse
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[0m\x1b[7m"));
}

test "writeComponentEsc — fg color" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeComponentEsc(fbs.writer(), .{
        .text = "X",
        .style = .{ .fg = .{ 255, 0, 128 } },
    });
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;255;0;128m") != null);
}

test "writeComponentEsc — bg color" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeComponentEsc(fbs.writer(), .{
        .text = "X",
        .style = .{ .bg = .{ 10, 20, 30 } },
    });
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[48;2;10;20;30m") != null);
}

test "writeComponentEsc — bold + italic" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeComponentEsc(fbs.writer(), .{
        .text = "X",
        .style = .{ .bold = true, .italic = true },
    });
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3m") != null);
}

test "writeComponentEsc — underline + strikethrough" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeComponentEsc(fbs.writer(), .{
        .text = "X",
        .style = .{ .underline = true, .strikethrough = true },
    });
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[9m") != null);
}

test "writeComponentEsc — no style produces no SGR before text" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeComponentEsc(fbs.writer(), .{ .text = "hi" });
    const out = fbs.getWritten();
    // First bytes should be the text directly (no SGR prefix)
    try std.testing.expectEqualStrings("hi", out[0..2]);
}

// ── Tests: Tab Width Calculation ──

test "tabWidth — single digit index" {
    // " 0:zsh" = 1 + 1 + 1 + 3 = 6
    try std.testing.expectEqual(@as(u16, 6), tabWidth(0, 3, false));
}

test "tabWidth — single digit active" {
    // " 0:zsh*" = 6 + 1 = 7
    try std.testing.expectEqual(@as(u16, 7), tabWidth(0, 3, true));
}

test "tabWidth — double digit index" {
    // " 10:vim" = 1 + 2 + 1 + 3 = 7
    try std.testing.expectEqual(@as(u16, 7), tabWidth(10, 3, false));
}

test "tabWidth — triple digit index" {
    // " 100:x" = 1 + 3 + 1 + 1 = 6
    try std.testing.expectEqual(@as(u16, 6), tabWidth(100, 1, false));
}

// ── Tests: Priority-Based Layout ──

test "layoutComponents — all fit within budget" {
    const comps = [_]TestComponent{
        .{ .text = "AAAA", .priority = 200 },
        .{ .text = "BB", .priority = 100 },
    };
    var indices: [10]usize = undefined;
    const count = layoutComponents(&comps, 30, &indices);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), indices[0]);
    try std.testing.expectEqual(@as(usize, 1), indices[1]);
}

test "layoutComponents — second component dropped when no space" {
    const comps = [_]TestComponent{
        .{ .text = "AAAA", .priority = 200 },
        .{ .text = "BBBBBB", .priority = 100 }, // 6 chars, won't fit in budget 5
    };
    var indices: [10]usize = undefined;
    const count = layoutComponents(&comps, 5, &indices);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), indices[0]);
}

test "layoutComponents — zero budget includes nothing" {
    const comps = [_]TestComponent{
        .{ .text = "A", .priority = 200 },
    };
    var indices: [10]usize = undefined;
    const count = layoutComponents(&comps, 0, &indices);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "layoutComponents — empty components" {
    const comps = [_]TestComponent{};
    var indices: [10]usize = undefined;
    const count = layoutComponents(&comps, 100, &indices);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "layoutComponents — priority sort makes high-priority fit" {
    // Simulate what refreshStatusBar does: sort by priority descending first
    var comps = [_]TestComponent{
        .{ .text = "LLLLLLLLLL", .priority = 50 }, // 10 chars, low priority
        .{ .text = "HI", .priority = 200 }, // 2 chars, high priority
    };
    // Sort by priority descending (as refreshStatusBar does)
    std.mem.sort(TestComponent, &comps, {}, struct {
        fn cmp(_: void, a: TestComponent, b: TestComponent) bool {
            return a.priority > b.priority;
        }
    }.cmp);

    // Budget: 5 — "HI" (2) fits, "LLLLLLLLLL" (10) doesn't
    var indices: [10]usize = undefined;
    const count = layoutComponents(&comps, 5, &indices);
    try std.testing.expectEqual(@as(usize, 1), count);
    // After sort, index 0 is the high-priority component
    try std.testing.expectEqualStrings("HI", comps[indices[0]].text);
}

// ── Tests: Click Region Building ──

test "buildClickRegions — no clickable components" {
    const comps = [_]TestComponent{
        .{ .text = "AAAA" },
        .{ .text = "BB" },
    };
    var regions: [10]ClickRegion = undefined;
    const count = buildClickRegions(&comps, 0, &regions);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "buildClickRegions — one clickable component" {
    const comps = [_]TestComponent{
        .{ .text = "AAA", .click_id = "btn1" },
    };
    var regions: [10]ClickRegion = undefined;
    const count = buildClickRegions(&comps, 0, &regions);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u16, 0), regions[0].x_start);
    try std.testing.expectEqual(@as(u16, 3), regions[0].x_end);
    try std.testing.expectEqualStrings("btn1", regions[0].click_id);
}

test "buildClickRegions — mixed clickable and non-clickable" {
    const comps = [_]TestComponent{
        .{ .text = "AA" }, // cols 0-1, no click
        .{ .text = "BBB", .click_id = "b" }, // cols 2-4
        .{ .text = "C" }, // col 5, no click
        .{ .text = "DD", .click_id = "d" }, // cols 6-7
    };
    var regions: [10]ClickRegion = undefined;
    const count = buildClickRegions(&comps, 0, &regions);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 2), regions[0].x_start);
    try std.testing.expectEqual(@as(u16, 5), regions[0].x_end);
    try std.testing.expectEqual(@as(u16, 6), regions[1].x_start);
    try std.testing.expectEqual(@as(u16, 8), regions[1].x_end);
}

test "buildClickRegions — with start offset" {
    const comps = [_]TestComponent{
        .{ .text = "XX", .click_id = "x" },
    };
    var regions: [10]ClickRegion = undefined;
    const count = buildClickRegions(&comps, 10, &regions);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u16, 10), regions[0].x_start);
    try std.testing.expectEqual(@as(u16, 12), regions[0].x_end);
}

// ── Tests: JSON Parsing ──

test "parse SET-COMPONENTS JSON — basic" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","source":"nvim-123","components":[
        \\  {"text":" N ","style":{"fg":"#e06c75","bold":true}},
        \\  {"text":" main ","style":{"fg":"#98c379","bg":"#3e4452"}}
        \\]}
    ;

    const result = try parseComponentsJson(alloc, json);
    defer freeResult(alloc, result);

    try std.testing.expectEqualStrings("left", result.zone);
    try std.testing.expectEqualStrings("nvim-123", result.source);
    try std.testing.expectEqual(@as(usize, 2), result.components.len);

    try std.testing.expectEqualStrings(" N ", result.components[0].text);
    try std.testing.expectEqual(@as(u8, 0xe0), result.components[0].style.fg.?[0]);
    try std.testing.expect(result.components[0].style.bold);
    try std.testing.expect(result.components[0].style.bg == null);

    try std.testing.expectEqualStrings(" main ", result.components[1].text);
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
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(u8, 200), result.components[0].priority);
    try std.testing.expectEqualStrings("btn1", result.components[0].click_id.?);
}

test "parse SET-COMPONENTS JSON — default priority is 100" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","source":"s","components":[{"text":"x"}]}
    ;

    const result = try parseComponentsJson(alloc, json);
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(u8, 100), result.components[0].priority);
}

test "parse SET-COMPONENTS JSON — empty components array" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","source":"s","components":[]}
    ;

    const result = try parseComponentsJson(alloc, json);
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(usize, 0), result.components.len);
}

test "parse SET-COMPONENTS JSON — missing zone" {
    const alloc = std.testing.allocator;
    const json =
        \\{"source":"s","components":[]}
    ;
    const result = parseComponentsJson(alloc, json);
    if (result) |r| {
        freeResult(alloc, r);
        return error.ExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.MissingField, err);
    }
}

test "parse SET-COMPONENTS JSON — missing source" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","components":[]}
    ;
    const result = parseComponentsJson(alloc, json);
    if (result) |r| {
        freeResult(alloc, r);
        return error.ExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.MissingField, err);
    }
}

test "parse SET-COMPONENTS JSON — missing text in component" {
    const alloc = std.testing.allocator;
    const json =
        \\{"zone":"left","source":"s","components":[{"style":{"bold":true}}]}
    ;
    const result = parseComponentsJson(alloc, json);
    if (result) |r| {
        freeResult(alloc, r);
        return error.ExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.MissingField, err);
    }
}
