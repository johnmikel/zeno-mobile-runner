const std = @import("std");
const selector = @import("selector.zig");
const types = @import("types.zig");

pub const RedactionRules = struct {
    denylist_text: []const []const u8 = &.{},
    allowlist_text: []const []const u8 = &.{},
    denylist_resource_ids: []const []const u8 = &.{},
    allowlist_resource_ids: []const []const u8 = &.{},
};

pub fn writeSnapshotJson(writer: anytype, snapshot: types.ObservationSnapshot) !void {
    try writer.writeAll("{");
    try jsonField(writer, "id", snapshot.id, true);
    try writer.print(",\"timestampMs\":{d}", .{snapshot.timestamp_ms});
    try writer.print(
        ",\"viewport\":{{\"width\":{d},\"height\":{d}}}",
        .{ snapshot.viewport.width, snapshot.viewport.height },
    );
    try writer.writeAll(",\"displayDensityDpi\":");
    if (snapshot.display_density_dpi) |density| {
        try writer.print("{d}", .{density});
    } else {
        try writer.writeAll("null");
    }
    try jsonNullableField(writer, "activePackage", snapshot.active_package);
    try jsonNullableField(writer, "activeActivity", snapshot.active_activity);
    try jsonNullableField(writer, "screenshotArtifact", snapshot.screenshot_artifact);
    try jsonNullableField(writer, "treeArtifact", snapshot.tree_artifact);
    try jsonNullableField(writer, "focusedNodeId", snapshot.focused_node_id);
    try jsonNullableField(writer, "logDelta", snapshot.log_delta);
    try writer.writeAll(",\"nodes\":[");
    for (snapshot.nodes, 0..) |node, index| {
        if (index > 0) try writer.writeAll(",");
        try writeNodeJson(writer, node);
    }
    try writer.writeAll("]}");
}

pub fn writeNodeJson(writer: anytype, node: types.UiNode) !void {
    try writer.writeAll("{");
    try jsonField(writer, "stableId", node.stable_id, true);
    try jsonField(writer, "className", node.class_name, false);
    try jsonNullableField(writer, "resourceId", node.resource_id);
    try jsonNullableField(writer, "text", node.text);
    try jsonNullableField(writer, "contentDesc", node.content_desc);
    try writer.print(
        ",\"bounds\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
        .{ node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height },
    );
    try writer.print(
        ",\"enabled\":{},\"visible\":{},\"selected\":{}",
        .{ node.enabled, node.visible, node.selected },
    );
    try writer.writeAll("}");
}

pub fn writeSnapshotJsonRedacted(writer: anytype, snapshot: types.ObservationSnapshot, redaction: RedactionRules) !void {
    try writer.writeAll("{");
    try jsonField(writer, "id", snapshot.id, true);
    try writer.print(",\"timestampMs\":{d}", .{snapshot.timestamp_ms});
    try writer.print(
        ",\"viewport\":{{\"width\":{d},\"height\":{d}}}",
        .{ snapshot.viewport.width, snapshot.viewport.height },
    );
    try writer.writeAll(",\"displayDensityDpi\":");
    if (snapshot.display_density_dpi) |density| {
        try writer.print("{d}", .{density});
    } else {
        try writer.writeAll("null");
    }
    try jsonNullableField(writer, "activePackage", snapshot.active_package);
    try jsonNullableField(writer, "activeActivity", snapshot.active_activity);
    try jsonNullableField(writer, "screenshotArtifact", snapshot.screenshot_artifact);
    try jsonNullableField(writer, "treeArtifact", snapshot.tree_artifact);
    try jsonNullableField(writer, "focusedNodeId", snapshot.focused_node_id);
    try jsonNullableFieldRedacted(writer, "logDelta", snapshot.log_delta, redaction);
    try writer.writeAll(",\"nodes\":[");
    for (snapshot.nodes, 0..) |node, index| {
        if (index > 0) try writer.writeAll(",");
        try writeNodeJsonRedacted(writer, node, redaction);
    }
    try writer.writeAll("]}");
}

fn writeNodeJsonRedacted(writer: anytype, node: types.UiNode, redaction: RedactionRules) !void {
    try writer.writeAll("{");
    try jsonField(writer, "stableId", node.stable_id, true);
    try jsonField(writer, "className", node.class_name, false);
    const sensitive_node = if (node.resource_id) |id| isSensitiveResourceId(id, redaction) else false;
    try jsonNullableResourceIdRedacted(writer, "resourceId", node.resource_id, redaction);
    try jsonNullableFieldRedactedWithContext(writer, "text", node.text, sensitive_node, redaction);
    try jsonNullableFieldRedactedWithContext(writer, "contentDesc", node.content_desc, sensitive_node, redaction);
    try writer.print(
        ",\"bounds\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
        .{ node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height },
    );
    try writer.print(
        ",\"enabled\":{},\"visible\":{},\"selected\":{}",
        .{ node.enabled, node.visible, node.selected },
    );
    try writer.writeAll("}");
}

pub fn writeSelectorJson(writer: anytype, wanted: selector.Selector) !void {
    try writer.writeAll("{");
    var first = true;
    if (wanted.id) |value| {
        try jsonField(writer, "id", value, first);
        first = false;
    }
    if (wanted.stable_id) |value| {
        try jsonField(writer, "stableId", value, first);
        first = false;
    }
    if (wanted.text) |value| {
        try jsonField(writer, "text", value, first);
        first = false;
    }
    if (wanted.text_contains) |value| {
        try jsonField(writer, "textContains", value, first);
        first = false;
    }
    if (wanted.content_desc) |value| {
        try jsonField(writer, "contentDesc", value, first);
        first = false;
    }
    if (wanted.content_desc_contains) |value| {
        try jsonField(writer, "contentDescContains", value, first);
        first = false;
    }
    if (wanted.class_name) |value| {
        try jsonField(writer, "className", value, first);
    }
    try writer.writeAll("}");
}

fn jsonField(writer: anytype, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeAll(",");
    try writer.print("\"{s}\":", .{key});
    try writeJsonString(writer, value);
}

fn jsonNullableField(writer: anytype, key: []const u8, value: ?[]const u8) !void {
    try writer.print(",\"{s}\":", .{key});
    if (value) |actual| {
        try writeJsonString(writer, actual);
    } else {
        try writer.writeAll("null");
    }
}

fn jsonNullableFieldRedacted(writer: anytype, key: []const u8, value: ?[]const u8, redaction: RedactionRules) !void {
    try jsonNullableFieldRedactedWithContext(writer, key, value, false, redaction);
}

fn jsonNullableFieldRedactedWithContext(writer: anytype, key: []const u8, value: ?[]const u8, force_secret: bool, redaction: RedactionRules) !void {
    try writer.print(",\"{s}\":", .{key});
    if (value) |actual| {
        try writeRedactedJsonStringForKeyWithRules(writer, key, actual, force_secret, redaction);
    } else {
        try writer.writeAll("null");
    }
}

fn jsonNullableResourceIdRedacted(writer: anytype, key: []const u8, value: ?[]const u8, redaction: RedactionRules) !void {
    try writer.print(",\"{s}\":", .{key});
    if (value) |actual| {
        if (resourceIdDenied(actual, redaction) and !resourceIdAllowed(actual, redaction)) {
            try writeJsonString(writer, "[REDACTED:resourceId]");
        } else {
            try writeJsonString(writer, actual);
        }
    } else {
        try writer.writeAll("null");
    }
}

pub fn writeRedactedJsonPayload(allocator: std.mem.Allocator, writer: anytype, payload: []const u8, redaction: RedactionRules) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        try writeRedactedJsonStringWithRules(writer, payload, redaction);
        return;
    };
    defer parsed.deinit();
    try writeJsonValueRedacted(writer, parsed.value, null, redaction);
}

fn writeJsonValueRedacted(writer: anytype, value: std.json.Value, key_context: ?[]const u8, redaction: RedactionRules) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |actual| try writer.writeAll(if (actual) "true" else "false"),
        .integer => |actual| try writer.print("{d}", .{actual}),
        .float => |actual| try writer.print("{d}", .{actual}),
        .number_string => |actual| try writer.writeAll(actual),
        .string => |actual| {
            if (key_context) |key| {
                try writeRedactedJsonStringForKeyWithRules(writer, key, actual, false, redaction);
            } else {
                try writeRedactedJsonStringWithRules(writer, actual, redaction);
            }
        },
        .array => |array| {
            try writer.writeAll("[");
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeAll(",");
                try writeJsonValueRedacted(writer, item, key_context, redaction);
            }
            try writer.writeAll("]");
        },
        .object => |object| {
            try writer.writeAll("{");
            var first = true;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writeJsonString(writer, entry.key_ptr.*);
                try writer.writeAll(":");
                try writeJsonValueRedacted(writer, entry.value_ptr.*, entry.key_ptr.*, redaction);
            }
            try writer.writeAll("}");
        },
    }
}

pub fn writeRedactedJsonString(writer: anytype, value: []const u8) !void {
    try writeRedactedJsonStringForKeyWithRules(writer, "", value, false, .{});
}

pub fn writeRedactedJsonStringForKey(writer: anytype, key: []const u8, value: []const u8, force_secret: bool) !void {
    try writeRedactedJsonStringForKeyWithRules(writer, key, value, force_secret, .{});
}

fn writeRedactedJsonStringWithRules(writer: anytype, value: []const u8, redaction: RedactionRules) !void {
    try writeRedactedJsonStringForKeyWithRules(writer, "", value, false, redaction);
}

fn writeRedactedJsonStringForKeyWithRules(writer: anytype, key: []const u8, value: []const u8, force_secret: bool, redaction: RedactionRules) !void {
    if (force_secret or isSensitiveLabel(key)) {
        try writeJsonString(writer, "[REDACTED:secret]");
    } else if (textDenied(value, redaction) and !textAllowed(value, redaction)) {
        try writeJsonString(writer, "[REDACTED:custom]");
    } else if (looksLikeToken(value)) {
        try writeJsonString(writer, "[REDACTED:token]");
    } else if (looksLikeEmail(value)) {
        try writeJsonString(writer, "[REDACTED:email]");
    } else {
        try writeJsonString(writer, value);
    }
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...7, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeAll(&.{ch}),
        }
    }
    try writer.writeAll("\"");
}

fn isSensitiveLabel(value: []const u8) bool {
    const needles = [_][]const u8{
        "password",
        "token",
        "secret",
        "authorization",
        "auth",
        "cookie",
        "apikey",
        "api_key",
        "bearer",
    };
    for (needles) |needle| {
        if (indexOfIgnoreCase(value, needle) != null) return true;
    }
    return false;
}

fn isSensitiveResourceId(value: []const u8, redaction: RedactionRules) bool {
    if (resourceIdAllowed(value, redaction)) return false;
    return isSensitiveLabel(value) or resourceIdDenied(value, redaction);
}

fn resourceIdDenied(value: []const u8, redaction: RedactionRules) bool {
    return matchesAnyIgnoreCase(value, redaction.denylist_resource_ids);
}

fn resourceIdAllowed(value: []const u8, redaction: RedactionRules) bool {
    return matchesAnyIgnoreCase(value, redaction.allowlist_resource_ids);
}

fn textDenied(value: []const u8, redaction: RedactionRules) bool {
    return matchesAnyIgnoreCase(value, redaction.denylist_text);
}

fn textAllowed(value: []const u8, redaction: RedactionRules) bool {
    return matchesAnyIgnoreCase(value, redaction.allowlist_text);
}

fn matchesAnyIgnoreCase(value: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfIgnoreCase(value, needle) != null) return true;
    }
    return false;
}

fn looksLikeEmail(value: []const u8) bool {
    if (value.len < 5 or value.len > 254) return false;
    if (std.mem.indexOfAny(u8, value, " \t\r\n<>") != null) return false;
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    if (at == 0 or at + 3 >= value.len) return false;
    return std.mem.indexOfScalar(u8, value[at + 1 ..], '.') != null;
}

fn looksLikeToken(value: []const u8) bool {
    if (indexOfIgnoreCase(value, "bearer ") != null) return true;
    if (value.len < 40) return false;
    const first_dot = std.mem.indexOfScalar(u8, value, '.') orelse return false;
    const second_dot = std.mem.indexOfScalarPos(u8, value, first_dot + 1, '.') orelse return false;
    return second_dot + 1 < value.len;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, offset| {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return index;
    }
    return null;
}
