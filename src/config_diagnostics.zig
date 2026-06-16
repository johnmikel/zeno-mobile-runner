const std = @import("std");
const stdio = @import("stdio.zig");

pub fn errorFieldPathForFile(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !?[]const u8 {
    const content = stdio.readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);
    return try errorFieldPathForSlice(allocator, content, err);
}

pub fn errorFieldPathForSlice(allocator: std.mem.Allocator, content: []const u8, err: anyerror) !?[]const u8 {
    if (err == error.ConfigMustBeObject) return try allocator.dupe(u8, "$");
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;

    return switch (err) {
        error.MissingConfigSchemaVersion,
        error.ConfigSchemaVersionMustBeInteger,
        error.UnsupportedConfigVersion,
        => try allocator.dupe(u8, "$.schemaVersion"),
        error.ConfigUnknownField => try findUnknownFieldPath(allocator, object),
        error.ConfigScriptsMustBeObject => try objectTypeFieldPath(allocator, object, "scripts", "$.scripts"),
        error.ConfigPlatformMustBeObject => try firstObjectTypeFieldPath(allocator, object, &.{ "android", "ios" }),
        error.ConfigToolsMustBeObject => try objectTypeFieldPath(allocator, object, "tools", "$.tools"),
        error.ConfigArtifactsMustBeObject => try objectTypeFieldPath(allocator, object, "artifacts", "$.artifacts"),
        error.ConfigRedactionMustBeObject => try objectTypeFieldPath(allocator, object, "redaction", "$.redaction"),
        error.ConfigFieldMustBeBool => try findBoolFieldPath(allocator, object),
        error.ConfigFieldMustBeString => try findStringFieldPath(allocator, object),
        error.ConfigFieldMustBeNonEmptyString => try findNonEmptyStringFieldPath(allocator, object),
        error.ConfigFieldMustBeStringArray => try findStringArrayFieldPath(allocator, object),
        else => null,
    };
}

fn findUnknownFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    const root_allowed = [_][]const u8{ "schemaVersion", "appId", "android", "ios", "artifacts", "redaction", "tools", "scripts" };
    if (try unknownInObject(allocator, object, "$", root_allowed[0..])) |path| return path;

    const platform_allowed = [_][]const u8{
        "enabled",
        "defaultDevice",
        "smokeScenario",
        "traceDir",
        "avdName",
        "restoreSnapshot",
        "createAvdIfMissing",
        "avdSystemImage",
        "avdDeviceProfile",
        "resetBeforeRun",
        "waitReady",
    };
    if (try unknownInNestedObject(allocator, object, "android", "$.android", platform_allowed[0..])) |path| return path;
    if (try unknownInNestedObject(allocator, object, "ios", "$.ios", platform_allowed[0..])) |path| return path;

    const tools_allowed = [_][]const u8{ "adbPath", "emulatorPath", "avdmanagerPath", "androidShimPath", "xcrunPath", "iosShimPath", "zigPath" };
    if (try unknownInNestedObject(allocator, object, "tools", "$.tools", tools_allowed[0..])) |path| return path;

    const artifact_allowed = [_][]const u8{ "screenshots", "hierarchy", "logs", "screenRecording" };
    if (try unknownInNestedObject(allocator, object, "artifacts", "$.artifacts", artifact_allowed[0..])) |path| return path;

    const redaction_allowed = [_][]const u8{ "denylistText", "allowlistText", "denylistResourceIds", "allowlistResourceIds" };
    if (try unknownInNestedObject(allocator, object, "redaction", "$.redaction", redaction_allowed[0..])) |path| return path;

    return null;
}

fn unknownInNestedObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, prefix: []const u8, allowed: []const []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .object) return null;
    return try unknownInObject(allocator, value.object, prefix, allowed);
}

fn unknownInObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, prefix: []const u8, allowed: []const []const u8) !?[]const u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsString(allowed, entry.key_ptr.*)) {
            return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        }
    }
    return null;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn objectTypeFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, path: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .object) return try allocator.dupe(u8, path);
    return null;
}

fn firstObjectTypeFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap, keys: []const []const u8) !?[]const u8 {
    for (keys) |key| {
        const value = object.get(key) orelse continue;
        if (value != .object) return try std.fmt.allocPrint(allocator, "$.{s}", .{key});
    }
    return null;
}

fn findBoolFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    const platform_bool_keys = [_][]const u8{ "enabled", "resetBeforeRun", "waitReady", "createAvdIfMissing" };
    if (try fieldWithUnexpectedTag(allocator, object, "android", "$.android", platform_bool_keys[0..], .bool)) |path| return path;
    if (try fieldWithUnexpectedTag(allocator, object, "ios", "$.ios", platform_bool_keys[0..], .bool)) |path| return path;

    const artifact_bool_keys = [_][]const u8{ "screenshots", "hierarchy", "logs", "screenRecording" };
    if (try fieldWithUnexpectedTag(allocator, object, "artifacts", "$.artifacts", artifact_bool_keys[0..], .bool)) |path| return path;
    return null;
}

fn findStringFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    if (try scriptValueWithUnexpectedTag(allocator, object, .string, false)) |path| return path;
    if (try directFieldWithUnexpectedTag(allocator, object, "appId", "$.appId", .string, false)) |path| return path;
    const platform_string_keys = [_][]const u8{ "defaultDevice", "smokeScenario", "traceDir", "avdName", "restoreSnapshot", "avdSystemImage", "avdDeviceProfile" };
    if (try fieldWithUnexpectedTag(allocator, object, "android", "$.android", platform_string_keys[0..], .string)) |path| return path;
    if (try fieldWithUnexpectedTag(allocator, object, "ios", "$.ios", platform_string_keys[0..], .string)) |path| return path;
    const tools_string_keys = [_][]const u8{ "adbPath", "emulatorPath", "avdmanagerPath", "androidShimPath", "xcrunPath", "iosShimPath", "zigPath" };
    if (try fieldWithUnexpectedTag(allocator, object, "tools", "$.tools", tools_string_keys[0..], .string)) |path| return path;
    return null;
}

fn findNonEmptyStringFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    if (try scriptValueWithUnexpectedTag(allocator, object, .string, true)) |path| return path;
    if (try emptyDirectStringFieldPath(allocator, object, "appId", "$.appId")) |path| return path;
    const platform_string_keys = [_][]const u8{ "defaultDevice", "smokeScenario", "traceDir", "avdName", "restoreSnapshot", "avdSystemImage", "avdDeviceProfile" };
    if (try emptyNestedStringFieldPath(allocator, object, "android", "$.android", platform_string_keys[0..])) |path| return path;
    if (try emptyNestedStringFieldPath(allocator, object, "ios", "$.ios", platform_string_keys[0..])) |path| return path;
    const tools_string_keys = [_][]const u8{ "adbPath", "emulatorPath", "avdmanagerPath", "androidShimPath", "xcrunPath", "iosShimPath", "zigPath" };
    if (try emptyNestedStringFieldPath(allocator, object, "tools", "$.tools", tools_string_keys[0..])) |path| return path;
    const redaction_keys = [_][]const u8{ "denylistText", "allowlistText", "denylistResourceIds", "allowlistResourceIds" };
    if (try emptyStringArrayItemPath(allocator, object, "redaction", "$.redaction", redaction_keys[0..])) |path| return path;
    return null;
}

fn findStringArrayFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    const redaction_keys = [_][]const u8{ "denylistText", "allowlistText", "denylistResourceIds", "allowlistResourceIds" };
    const redaction = object.get("redaction") orelse return null;
    if (redaction != .object) return null;
    for (redaction_keys) |key| {
        const value = redaction.object.get(key) orelse continue;
        if (value != .array) return try std.fmt.allocPrint(allocator, "$.redaction.{s}", .{key});
        for (value.array.items, 0..) |item, index| {
            if (item != .string) return try std.fmt.allocPrint(allocator, "$.redaction.{s}[{d}]", .{ key, index });
        }
    }
    return null;
}

fn fieldWithUnexpectedTag(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_key: []const u8, prefix: []const u8, keys: []const []const u8, expected: std.meta.Tag(std.json.Value)) !?[]const u8 {
    const parent = object.get(parent_key) orelse return null;
    if (parent != .object) return null;
    for (keys) |key| {
        if (try directFieldWithUnexpectedTag(allocator, parent.object, key, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, key }), expected, true)) |path| return path;
    }
    return null;
}

fn directFieldWithUnexpectedTag(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, path: []const u8, expected: std.meta.Tag(std.json.Value), free_path: bool) !?[]const u8 {
    defer if (free_path) allocator.free(path);
    const value = object.get(key) orelse return null;
    if (value == .null and expected == .string) return null;
    if (std.meta.activeTag(value) != expected) return try allocator.dupe(u8, path);
    return null;
}

fn scriptValueWithUnexpectedTag(allocator: std.mem.Allocator, object: std.json.ObjectMap, expected: std.meta.Tag(std.json.Value), reject_empty: bool) !?[]const u8 {
    const scripts = object.get("scripts") orelse return null;
    if (scripts != .object) return null;
    var iterator = scripts.object.iterator();
    while (iterator.next()) |entry| {
        const path = try std.fmt.allocPrint(allocator, "$.scripts.{s}", .{entry.key_ptr.*});
        errdefer allocator.free(path);
        if (std.meta.activeTag(entry.value_ptr.*) != expected) return path;
        if (reject_empty and entry.value_ptr.string.len == 0) return path;
        allocator.free(path);
    }
    return null;
}

fn emptyDirectStringFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, path: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .string and value.string.len == 0) return try allocator.dupe(u8, path);
    return null;
}

fn emptyNestedStringFieldPath(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_key: []const u8, prefix: []const u8, keys: []const []const u8) !?[]const u8 {
    const parent = object.get(parent_key) orelse return null;
    if (parent != .object) return null;
    for (keys) |key| {
        const value = parent.object.get(key) orelse continue;
        const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, key });
        defer allocator.free(path);
        if (value == .string and value.string.len == 0) return try allocator.dupe(u8, path);
    }
    return null;
}

fn emptyStringArrayItemPath(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_key: []const u8, prefix: []const u8, keys: []const []const u8) !?[]const u8 {
    const parent = object.get(parent_key) orelse return null;
    if (parent != .object) return null;
    for (keys) |key| {
        const value = parent.object.get(key) orelse continue;
        if (value != .array) continue;
        for (value.array.items, 0..) |item, index| {
            if (item == .string and item.string.len == 0) return try std.fmt.allocPrint(allocator, "{s}.{s}[{d}]", .{ prefix, key, index });
        }
    }
    return null;
}
