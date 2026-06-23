const std = @import("std");
const json_fields = @import("json_fields.zig");
const selector = @import("selector.zig");

pub fn requiredString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = try json_fields.requiredStringFromObject(object, key, error.RequiredStringMissing, error.RequiredFieldMustBeString);
    return try allocator.dupe(u8, value);
}

pub fn requiredStringOrError(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, missing_error: anyerror) ![]const u8 {
    const value = try json_fields.requiredStringFromObject(object, key, missing_error, error.RequiredFieldMustBeString);
    return try allocator.dupe(u8, value);
}

pub fn optionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = try json_fields.optionalStringFromObject(object, key, error.OptionalFieldMustBeString) orelse return null;
    return try allocator.dupe(u8, value);
}

pub fn requiredI32OrError(object: std.json.ObjectMap, key: []const u8, missing_error: anyerror) !i32 {
    return try json_fields.requiredI32FromObject(object, key, missing_error, error.RequiredFieldMustBeInteger);
}

pub fn requiredF64OrError(object: std.json.ObjectMap, key: []const u8, missing_error: anyerror, type_error: anyerror) !f64 {
    return try json_fields.requiredF64FromObject(object, key, missing_error, type_error);
}

pub fn optionalU64(object: std.json.ObjectMap, key: []const u8, default_value: u64) !u64 {
    return try json_fields.optionalU64FromObject(object, key, default_value, error.OptionalFieldMustBeInteger);
}

pub fn optionalBool(object: std.json.ObjectMap, key: []const u8, default_value: bool) !bool {
    return try json_fields.optionalBoolFromObject(object, key, default_value, error.OptionalFieldMustBeBool);
}

pub fn parseSelectorField(allocator: std.mem.Allocator, object: std.json.ObjectMap) !selector.Selector {
    const selector_value = object.get("selector") orelse return error.StepMissingSelector;
    return try selector.parseFromJson(allocator, selector_value);
}

pub fn parseSelectorArrayField(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]selector.Selector {
    const selectors_value = object.get("selectors") orelse return error.StepMissingSelectors;
    if (selectors_value != .array) return error.SelectorsMustBeArray;
    var selectors = std.ArrayList(selector.Selector).empty;
    errdefer {
        for (selectors.items) |wanted| wanted.deinit(allocator);
        selectors.deinit(allocator);
    }
    for (selectors_value.array.items) |selector_value| {
        try selectors.append(allocator, try selector.parseFromJson(allocator, selector_value));
    }
    if (selectors.items.len == 0) return error.SelectorsMustNotBeEmpty;
    return try selectors.toOwnedSlice(allocator);
}
