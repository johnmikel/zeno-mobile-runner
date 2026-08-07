const std = @import("std");
const types = @import("types.zig");

pub fn parseHierarchy(allocator: std.mem.Allocator, xml: []const u8) ![]types.UiNode {
    var nodes = std.ArrayList(types.UiNode).empty;
    errdefer {
        for (nodes.items) |node| node.deinit(allocator);
        nodes.deinit(allocator);
    }

    var cursor: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, xml, cursor, "<node")) |start| {
        const end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break;
        const tag = xml[start..end];
        const class_name = try attrOwned(allocator, tag, "class") orelse try allocator.dupe(u8, "");
        errdefer allocator.free(class_name);
        const resource_id = try attrOwned(allocator, tag, "resource-id");
        errdefer if (resource_id) |value| allocator.free(value);
        var text = try attrOwned(allocator, tag, "text");
        errdefer if (text) |value| allocator.free(value);
        var content_desc = try attrOwned(allocator, tag, "content-desc");
        errdefer if (content_desc) |value| allocator.free(value);
        const bounds_text = try attrOwned(allocator, tag, "bounds");
        defer if (bounds_text) |value| allocator.free(value);

        const bounds = if (bounds_text) |value| parseBounds(value) catch types.Bounds{} else types.Bounds{};
        const enabled = parseBoolAttr(tag, "enabled", true);
        const checked = parseBoolAttr(tag, "checked", false);
        const focused = parseBoolAttr(tag, "focused", false);
        const selected = parseBoolAttr(tag, "selected", false);
        const visible = bounds.width > 0 and bounds.height > 0;
        text = emptyToNullOwned(allocator, text);
        content_desc = emptyToNullOwned(allocator, content_desc);
        const stable_id = try stableId(allocator, index, class_name, resource_id, text, content_desc, bounds);

        try nodes.append(allocator, .{
            .stable_id = stable_id,
            .class_name = class_name,
            .resource_id = resource_id,
            .text = text,
            .content_desc = content_desc,
            .bounds = bounds,
            .enabled = enabled,
            .visible = visible,
            .checked = checked,
            .focused = focused,
            .selected = selected,
        });

        index += 1;
        cursor = end + 1;
    }

    return try nodes.toOwnedSlice(allocator);
}

fn emptyToNullOwned(allocator: std.mem.Allocator, value: ?[]const u8) ?[]const u8 {
    if (value) |actual| {
        if (actual.len == 0) {
            allocator.free(actual);
            return null;
        }
    }
    return value;
}

fn attrOwned(allocator: std.mem.Allocator, tag: []const u8, name: []const u8) !?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, tag, cursor, name)) |pos| {
        const eq = pos + name.len;
        if (eq + 1 < tag.len and tag[eq] == '=' and tag[eq + 1] == '"') {
            const value_start = eq + 2;
            const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, '"') orelse return error.MalformedAttribute;
            return try xmlUnescape(allocator, tag[value_start..value_end]);
        }
        cursor = pos + name.len;
    }
    return null;
}

fn xmlUnescape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&lt;")) {
            try out.append(allocator, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
            try out.append(allocator, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
            try out.append(allocator, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, input[i..], "&apos;")) {
            try out.append(allocator, '\'');
            i += 6;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parseBoolAttr(tag: []const u8, name: []const u8, default_value: bool) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, tag, cursor, name)) |pos| {
        const eq = pos + name.len;
        if (eq + 1 < tag.len and tag[eq] == '=' and tag[eq + 1] == '"') {
            const value_start = eq + 2;
            const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, '"') orelse return default_value;
            return std.mem.eql(u8, tag[value_start..value_end], "true");
        }
        cursor = pos + name.len;
    }
    return default_value;
}

pub fn parseBounds(input: []const u8) !types.Bounds {
    if (input.len < 10 or input[0] != '[') return error.MalformedBounds;
    const comma_1 = std.mem.indexOfScalar(u8, input, ',') orelse return error.MalformedBounds;
    const close_1 = std.mem.indexOfScalarPos(u8, input, comma_1, ']') orelse return error.MalformedBounds;
    const open_2 = std.mem.indexOfScalarPos(u8, input, close_1, '[') orelse return error.MalformedBounds;
    const comma_2 = std.mem.indexOfScalarPos(u8, input, open_2, ',') orelse return error.MalformedBounds;
    const close_2 = std.mem.indexOfScalarPos(u8, input, comma_2, ']') orelse return error.MalformedBounds;

    const x1 = try std.fmt.parseInt(i32, input[1..comma_1], 10);
    const y1 = try std.fmt.parseInt(i32, input[comma_1 + 1 .. close_1], 10);
    const x2 = try std.fmt.parseInt(i32, input[open_2 + 1 .. comma_2], 10);
    const y2 = try std.fmt.parseInt(i32, input[comma_2 + 1 .. close_2], 10);

    return .{
        .x = x1,
        .y = y1,
        .width = @max(0, x2 - x1),
        .height = @max(0, y2 - y1),
    };
}

fn stableId(
    allocator: std.mem.Allocator,
    index: usize,
    class_name: []const u8,
    resource_id: ?[]const u8,
    text: ?[]const u8,
    content_desc: ?[]const u8,
    bounds: types.Bounds,
) ![]const u8 {
    if (resource_id) |value| {
        if (value.len > 0) return try std.fmt.allocPrint(allocator, "rid:{s}:{d}", .{ value, index });
    }
    if (content_desc) |value| {
        if (value.len > 0) return try std.fmt.allocPrint(allocator, "desc:{s}:{d}", .{ value, index });
    }
    if (text) |value| {
        if (value.len > 0) return try std.fmt.allocPrint(allocator, "text:{s}:{d}", .{ value, index });
    }
    return try std.fmt.allocPrint(
        allocator,
        "node:{s}:{d}:{d}:{d}:{d}:{d}",
        .{ class_name, bounds.x, bounds.y, bounds.width, bounds.height, index },
    );
}
