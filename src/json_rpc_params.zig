const std = @import("std");
const json_fields = @import("json_fields.zig");
const scenario = @import("scenario.zig");
const selector = @import("selector.zig");

pub fn field(params: ?std.json.Value, key: []const u8) ?std.json.Value {
    return json_fields.field(params, key);
}

pub fn selectorParam(allocator: std.mem.Allocator, params: ?std.json.Value) !selector.Selector {
    const selector_value = field(params, "selector") orelse return error.MissingSelector;
    return try selector.parseFromJson(allocator, selector_value);
}

pub fn selectors(allocator: std.mem.Allocator, params: ?std.json.Value) ![]selector.Selector {
    const selectors_value = field(params, "selectors") orelse return error.MissingSelectors;
    if (selectors_value != .array) return error.SelectorsMustBeArray;
    var parsed_selectors = std.ArrayList(selector.Selector).empty;
    errdefer {
        for (parsed_selectors.items) |wanted| wanted.deinit(allocator);
        parsed_selectors.deinit(allocator);
    }
    for (selectors_value.array.items) |selector_value| {
        try parsed_selectors.append(allocator, try selector.parseFromJson(allocator, selector_value));
    }
    if (parsed_selectors.items.len == 0) return error.SelectorsMustNotBeEmpty;
    return try parsed_selectors.toOwnedSlice(allocator);
}

pub fn requiredString(params: ?std.json.Value, key: []const u8) ![]const u8 {
    return try json_fields.requiredString(params, key, error.MissingParam, error.ParamMustBeString);
}

pub fn optionalString(params: ?std.json.Value, key: []const u8) !?[]const u8 {
    const value = field(params, key) orelse return null;
    return switch (value) {
        .string => |actual| actual,
        else => error.ParamMustBeString,
    };
}

pub fn requiredI32(params: ?std.json.Value, key: []const u8) !i32 {
    return try json_fields.requiredI32(params, key, error.MissingParam, error.ParamMustBeInteger);
}

pub fn optionalU64(params: ?std.json.Value, key: []const u8, default_value: u64) !u64 {
    return try json_fields.optionalU64(params, key, default_value, error.ParamMustBeInteger);
}

pub fn optionalBool(params: ?std.json.Value, key: []const u8, default_value: bool) !bool {
    return try json_fields.optionalBool(params, key, default_value, error.ParamMustBeBool);
}

pub fn optionalDirection(params: ?std.json.Value, key: []const u8, default_value: scenario.ScrollDirection) !scenario.ScrollDirection {
    const value = field(params, key) orelse return default_value;
    if (value != .string) return error.ParamMustBeString;
    if (std.mem.eql(u8, value.string, "down")) return .down;
    if (std.mem.eql(u8, value.string, "up")) return .up;
    return error.unknownScrollDirection;
}
