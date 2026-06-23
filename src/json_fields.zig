const std = @import("std");

pub fn field(params: ?std.json.Value, key: []const u8) ?std.json.Value {
    const value = params orelse return null;
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn requiredString(params: ?std.json.Value, key: []const u8, missing_error: anyerror, type_error: anyerror) ![]const u8 {
    const value = field(params, key) orelse return missing_error;
    return stringValue(value, type_error);
}

pub fn requiredStringFromObject(object: std.json.ObjectMap, key: []const u8, missing_error: anyerror, type_error: anyerror) ![]const u8 {
    const value = object.get(key) orelse return missing_error;
    return stringValue(value, type_error);
}

pub fn optionalStringFromObject(object: std.json.ObjectMap, key: []const u8, type_error: anyerror) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return try stringValue(value, type_error);
}

pub fn requiredI32(params: ?std.json.Value, key: []const u8, missing_error: anyerror, type_error: anyerror) !i32 {
    const value = field(params, key) orelse return missing_error;
    return i32Value(value, type_error);
}

pub fn requiredI32FromObject(object: std.json.ObjectMap, key: []const u8, missing_error: anyerror, type_error: anyerror) !i32 {
    const value = object.get(key) orelse return missing_error;
    return i32Value(value, type_error);
}

pub fn requiredF64FromObject(object: std.json.ObjectMap, key: []const u8, missing_error: anyerror, type_error: anyerror) !f64 {
    const value = object.get(key) orelse return missing_error;
    return f64Value(value, type_error);
}

pub fn optionalU64(params: ?std.json.Value, key: []const u8, default_value: u64, type_error: anyerror) !u64 {
    const value = field(params, key) orelse return default_value;
    return u64Value(value, type_error);
}

pub fn optionalU64FromObject(object: std.json.ObjectMap, key: []const u8, default_value: u64, type_error: anyerror) !u64 {
    const value = object.get(key) orelse return default_value;
    return u64Value(value, type_error);
}

pub fn optionalBool(params: ?std.json.Value, key: []const u8, default_value: bool, type_error: anyerror) !bool {
    const value = field(params, key) orelse return default_value;
    return boolValue(value, type_error);
}

pub fn optionalBoolFromObject(object: std.json.ObjectMap, key: []const u8, default_value: bool, type_error: anyerror) !bool {
    const value = object.get(key) orelse return default_value;
    return boolValue(value, type_error);
}

fn stringValue(value: std.json.Value, type_error: anyerror) ![]const u8 {
    return switch (value) {
        .string => |actual| actual,
        else => type_error,
    };
}

fn i32Value(value: std.json.Value, type_error: anyerror) !i32 {
    return switch (value) {
        .integer => |actual| @as(i32, @intCast(actual)),
        else => type_error,
    };
}

fn u64Value(value: std.json.Value, type_error: anyerror) !u64 {
    return switch (value) {
        .integer => |actual| @as(u64, @intCast(actual)),
        else => type_error,
    };
}

fn f64Value(value: std.json.Value, type_error: anyerror) !f64 {
    return switch (value) {
        .float => |actual| actual,
        .integer => |actual| @as(f64, @floatFromInt(actual)),
        else => type_error,
    };
}

fn boolValue(value: std.json.Value, type_error: anyerror) !bool {
    return switch (value) {
        .bool => |actual| actual,
        else => type_error,
    };
}
