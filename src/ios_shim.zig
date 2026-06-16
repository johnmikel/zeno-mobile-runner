const std = @import("std");
const selectors = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

pub const CommandKind = enum {
    snapshot,
    screenshot,
    tap,
    type_text,
    erase_text,
    hide_keyboard,
    swipe,
    press_back,
    app_state,
    settle,
    accept_system_alert,
    query,
};

pub const Command = struct {
    kind: CommandKind,
    selector: ?[]const u8 = null,
    text: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    x1: ?i32 = null,
    y1: ?i32 = null,
    x2: ?i32 = null,
    y2: ?i32 = null,
    duration_ms: ?u32 = null,
    max_chars: ?u32 = null,
};

pub const SnapshotResponse = struct {
    nodes: []types.UiNode,
    viewport: types.Viewport = .{},

    pub fn deinit(self: SnapshotResponse, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| node.deinit(allocator);
        allocator.free(self.nodes);
    }
};

pub fn writeCommandJson(writer: anytype, command: Command) !void {
    try writer.writeAll("{\"cmd\":");
    try trace.writeJsonString(writer, commandName(command.kind));
    if (command.selector) |selector| {
        try writer.writeAll(",\"selector\":");
        try trace.writeJsonString(writer, selector);
    }
    if (command.text) |text| {
        try writer.writeAll(",\"text\":");
        try trace.writeJsonString(writer, text);
    }
    if (command.x) |value| try writer.print(",\"x\":{d}", .{value});
    if (command.y) |value| try writer.print(",\"y\":{d}", .{value});
    if (command.x1) |value| try writer.print(",\"x1\":{d}", .{value});
    if (command.y1) |value| try writer.print(",\"y1\":{d}", .{value});
    if (command.x2) |value| try writer.print(",\"x2\":{d}", .{value});
    if (command.y2) |value| try writer.print(",\"y2\":{d}", .{value});
    if (command.duration_ms) |value| try writer.print(",\"durationMs\":{d}", .{value});
    if (command.max_chars) |value| try writer.print(",\"maxChars\":{d}", .{value});
    try writer.writeAll("}\n");
}

pub fn parseSnapshotResponse(allocator: std.mem.Allocator, content: []const u8) !SnapshotResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.IosShimResponseMustBeObject;
    const status = fieldString(parsed.value.object, "status") orelse return error.IosShimMissingStatus;
    if (!std.mem.eql(u8, status, "ok")) return error.IosShimResponseNotOk;
    const viewport = parseViewport(parsed.value.object.get("viewport"));
    const nodes_value = parsed.value.object.get("nodes") orelse return error.IosShimMissingNodes;
    if (nodes_value != .array) return error.IosShimNodesMustBeArray;

    var nodes = std.ArrayList(types.UiNode).empty;
    errdefer {
        for (nodes.items) |*node| node.deinit(allocator);
        nodes.deinit(allocator);
    }

    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) return error.IosShimNodeMustBeObject;
        const object = node_value.object;
        const stable_id_source = fieldString(object, "id") orelse return error.IosShimNodeMissingId;
        const class_name_source = fieldString(object, "type") orelse "XCUIElementTypeOther";
        const bounds_value = object.get("bounds") orelse return error.IosShimNodeMissingBounds;
        if (bounds_value != .object) return error.IosShimBoundsMustBeObject;

        const text = nonEmptyFieldString(object, "label") orelse nonEmptyFieldString(object, "value");
        const content_desc = fieldString(object, "identifier");
        try nodes.append(allocator, .{
            .stable_id = try allocator.dupe(u8, stable_id_source),
            .class_name = try allocator.dupe(u8, class_name_source),
            .text = try dupeOptional(allocator, text),
            .content_desc = try dupeOptional(allocator, content_desc),
            .resource_id = try dupeOptional(allocator, content_desc),
            .bounds = .{
                .x = try intField(bounds_value.object, "x"),
                .y = try intField(bounds_value.object, "y"),
                .width = try intField(bounds_value.object, "width"),
                .height = try intField(bounds_value.object, "height"),
            },
            .enabled = boolField(object, "enabled", true),
            .visible = boolField(object, "visible", true),
            .selected = boolField(object, "selected", false),
        });
    }

    return .{
        .nodes = try nodes.toOwnedSlice(allocator),
        .viewport = viewport,
    };
}

pub fn parseSnapshotNodes(allocator: std.mem.Allocator, content: []const u8) ![]types.UiNode {
    const snapshot = try parseSnapshotResponse(allocator, content);
    return snapshot.nodes;
}

pub fn parseOkResponse(content: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{});
    if (parsed.value != .object) return error.IosShimResponseMustBeObject;
    const status = fieldString(parsed.value.object, "status") orelse return error.IosShimMissingStatus;
    if (!std.mem.eql(u8, status, "ok")) return error.IosShimResponseNotOk;
}

pub fn parseAcceptSystemAlertResponse(content: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{});
    if (parsed.value != .object) return error.IosShimResponseMustBeObject;
    const status = fieldString(parsed.value.object, "status") orelse return error.IosShimMissingStatus;
    if (!std.mem.eql(u8, status, "ok")) return error.IosShimResponseNotOk;
    const accepted = parsed.value.object.get("accepted") orelse return false;
    if (accepted != .bool) return false;
    return accepted.bool;
}

pub const SelectorActionResponse = enum {
    ok,
    selector_unavailable,
};

pub fn parseSelectorActionResponse(content: []const u8) !SelectorActionResponse {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{});
    if (parsed.value != .object) return error.IosShimResponseMustBeObject;
    const status = fieldString(parsed.value.object, "status") orelse return error.IosShimMissingStatus;
    if (std.mem.eql(u8, status, "ok")) return .ok;

    const code = fieldString(parsed.value.object, "code") orelse return error.IosShimResponseNotOk;
    if (std.mem.eql(u8, code, "selector.not_found") or
        std.mem.eql(u8, code, "selector.not_hittable"))
    {
        return .selector_unavailable;
    }

    return error.IosShimResponseNotOk;
}

test "selector action response maps native selector misses to unavailable" {
    try std.testing.expectEqual(SelectorActionResponse.ok, try parseSelectorActionResponse("{\"status\":\"ok\"}"));
    try std.testing.expectEqual(
        SelectorActionResponse.selector_unavailable,
        try parseSelectorActionResponse("{\"status\":\"error\",\"code\":\"selector.not_found\",\"message\":\"missing\"}"),
    );
    try std.testing.expectEqual(
        SelectorActionResponse.selector_unavailable,
        try parseSelectorActionResponse("{\"status\":\"error\",\"code\":\"selector.not_hittable\",\"message\":\"covered\"}"),
    );
}

test "selector action response keeps unsupported selectors as hard errors" {
    try std.testing.expectError(
        error.IosShimResponseNotOk,
        parseSelectorActionResponse("{\"status\":\"error\",\"code\":\"selector.unsupported\",\"message\":\"bad\"}"),
    );
}

pub fn parseQueryResponse(content: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{});
    if (parsed.value != .object) return error.IosShimResponseMustBeObject;
    const status = fieldString(parsed.value.object, "status") orelse return error.IosShimMissingStatus;
    if (!std.mem.eql(u8, status, "ok")) return error.IosShimResponseNotOk;
    const exists = parsed.value.object.get("exists") orelse return error.IosShimMissingExists;
    if (exists != .bool) return error.IosShimExistsMustBeBool;
    return exists.bool;
}

pub fn parseAppStateRunning(content: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{});
    if (parsed.value != .object) return error.IosShimResponseMustBeObject;
    const status = fieldString(parsed.value.object, "status") orelse return error.IosShimMissingStatus;
    if (!std.mem.eql(u8, status, "ok")) return error.IosShimResponseNotOk;
    const state = parsed.value.object.get("state") orelse return error.IosShimMissingState;
    return switch (state) {
        .integer => |value| value >= 3,
        .string => |value| std.mem.eql(u8, value, "running") or
            std.mem.eql(u8, value, "runningForeground") or
            std.mem.eql(u8, value, "runningBackground"),
        else => error.IosShimStateMustBeIntegerOrString,
    };
}

pub fn parseScreenshotPng(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.IosShimResponseMustBeObject;
    const status = fieldString(parsed.value.object, "status") orelse return error.IosShimMissingStatus;
    if (!std.mem.eql(u8, status, "ok")) return error.IosShimResponseNotOk;
    const format = fieldString(parsed.value.object, "format") orelse return error.IosShimMissingScreenshotFormat;
    if (!std.mem.eql(u8, format, "png")) return error.IosShimUnsupportedScreenshotFormat;
    const encoded = fieldString(parsed.value.object, "base64") orelse return error.IosShimMissingScreenshotData;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    return bytes;
}

pub fn selectorString(allocator: std.mem.Allocator, wanted: selectors.Selector) !?[]u8 {
    var count: usize = 0;
    var prefix: []const u8 = "";
    var value: []const u8 = "";

    if (wanted.id) |actual| {
        count += 1;
        prefix = "resourceId=";
        value = actual;
    }
    if (wanted.text) |actual| {
        count += 1;
        prefix = "text=";
        value = actual;
    }
    if (wanted.text_contains) |actual| {
        count += 1;
        prefix = "textContains=";
        value = actual;
    }
    if (wanted.content_desc) |actual| {
        count += 1;
        prefix = "identifier=";
        value = actual;
    }
    if (wanted.content_desc_contains) |actual| {
        count += 1;
        prefix = "identifierContains=";
        value = actual;
    }
    if (wanted.class_name) |actual| {
        count += 1;
        prefix = "type=";
        value = actual;
    }

    if (count != 1) return null;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, value });
}

fn commandName(kind: CommandKind) []const u8 {
    return switch (kind) {
        .snapshot => "snapshot",
        .screenshot => "screenshot",
        .tap => "tap",
        .type_text => "type",
        .erase_text => "eraseText",
        .hide_keyboard => "hideKeyboard",
        .swipe => "swipe",
        .press_back => "pressBack",
        .app_state => "appState",
        .settle => "settle",
        .accept_system_alert => "acceptSystemAlert",
        .query => "query",
    };
}

fn fieldString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn nonEmptyFieldString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = fieldString(object, key) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn boolField(object: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = object.get(key) orelse return default;
    if (value != .bool) return default;
    return value.bool;
}

fn intField(object: std.json.ObjectMap, key: []const u8) !i32 {
    const value = object.get(key) orelse return error.IosShimBoundsMissingField;
    if (value != .integer) return error.IosShimBoundsFieldMustBeInteger;
    if (value.integer < std.math.minInt(i32) or value.integer > std.math.maxInt(i32)) return error.IosShimBoundsFieldMustBeInteger;
    return @intCast(value.integer);
}

fn parseViewport(value: ?std.json.Value) types.Viewport {
    const actual = value orelse return .{};
    if (actual != .object) return .{};
    const width = optionalU32Field(actual.object, "width") orelse return .{};
    const height = optionalU32Field(actual.object, "height") orelse return .{};
    return .{ .width = width, .height = height };
}

fn optionalU32Field(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |actual| return try allocator.dupe(u8, actual);
    return null;
}
