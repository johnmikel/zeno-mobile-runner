const std = @import("std");
const trace = @import("trace.zig");

pub const DiagnosticEvent = struct {
    kind: ?[]u8 = null,
    status: ?[]u8 = null,
    snapshot_id: ?[]u8 = null,
    artifact_status: ?[]u8 = null,
    semantic_status: ?[]u8 = null,
    error_name: ?[]u8 = null,
    screenshot_artifact: ?[]u8 = null,
    source: ?[]u8 = null,
    active_package: ?[]u8 = null,
    active_activity: ?[]u8 = null,
    visible_texts: ?[]u8 = null,
    nearest_matches: ?[]u8 = null,

    pub fn deinit(self: *DiagnosticEvent, allocator: std.mem.Allocator) void {
        if (self.kind) |value| allocator.free(value);
        if (self.status) |value| allocator.free(value);
        if (self.snapshot_id) |value| allocator.free(value);
        if (self.artifact_status) |value| allocator.free(value);
        if (self.semantic_status) |value| allocator.free(value);
        if (self.error_name) |value| allocator.free(value);
        if (self.screenshot_artifact) |value| allocator.free(value);
        if (self.source) |value| allocator.free(value);
        if (self.active_package) |value| allocator.free(value);
        if (self.active_activity) |value| allocator.free(value);
        if (self.visible_texts) |value| allocator.free(value);
        if (self.nearest_matches) |value| allocator.free(value);
    }

    pub fn fromPayload(allocator: std.mem.Allocator, kind_value: []const u8, payload: std.json.ObjectMap) !DiagnosticEvent {
        return .{
            .kind = try allocator.dupe(u8, kind_value),
            .status = try dupeOptionalString(allocator, stringField(payload, "status")),
            .snapshot_id = try dupeOptionalString(allocator, stringField(payload, "snapshotId")),
            .artifact_status = try dupeOptionalString(allocator, stringField(payload, "artifactStatus")),
            .semantic_status = try dupeOptionalString(allocator, stringField(payload, "semanticStatus")),
            .error_name = try dupeOptionalString(allocator, stringField(payload, "error")),
            .screenshot_artifact = try dupeOptionalString(allocator, stringField(payload, "screenshotArtifact")),
            .source = try dupeOptionalString(allocator, stringField(payload, "source")),
            .active_package = try dupeOptionalString(allocator, stringField(payload, "activePackage")),
            .active_activity = try dupeOptionalString(allocator, stringField(payload, "activeActivity")),
            .visible_texts = if (payload.get("visibleTexts")) |value| try joinStringArray(allocator, value, 8) else null,
            .nearest_matches = if (payload.get("nearestTextMatches")) |value| try joinNearestMatches(allocator, value, 5) else null,
        };
    }
};

pub fn writeJson(writer: anytype, diagnostic: DiagnosticEvent) !void {
    try writer.writeAll("{\"kind\":");
    try trace.writeJsonString(writer, diagnostic.kind.?);
    if (diagnostic.status) |value| {
        try writer.writeAll(",\"status\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.snapshot_id) |value| {
        try writer.writeAll(",\"snapshotId\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.artifact_status) |value| {
        try writer.writeAll(",\"artifactStatus\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.semantic_status) |value| {
        try writer.writeAll(",\"semanticStatus\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.error_name) |value| {
        try writer.writeAll(",\"error\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.screenshot_artifact) |value| {
        try writer.writeAll(",\"screenshotArtifact\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.source) |value| {
        try writer.writeAll(",\"source\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.active_package) |value| {
        try writer.writeAll(",\"activePackage\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.active_activity) |value| {
        try writer.writeAll(",\"activeActivity\":");
        try trace.writeJsonString(writer, value);
    }
    if (diagnostic.visible_texts) |value| {
        try writer.writeAll(",\"visibleTexts\":");
        try writeJoinedStringArrayJson(writer, value);
    }
    if (diagnostic.nearest_matches) |value| {
        try writer.writeAll(",\"nearestTextMatches\":");
        try writeJoinedStringArrayJson(writer, value);
    }
    try writer.writeAll("}");
}

pub fn writePartialJson(writer: anytype, partial: DiagnosticEvent) !void {
    try writer.writeAll("{\"kind\":");
    try trace.writeJsonString(writer, partial.kind.?);
    if (partial.status) |value| {
        try writer.writeAll(",\"status\":");
        try trace.writeJsonString(writer, value);
    }
    if (partial.artifact_status) |value| {
        try writer.writeAll(",\"artifactStatus\":");
        try trace.writeJsonString(writer, value);
    }
    if (partial.semantic_status) |value| {
        try writer.writeAll(",\"semanticStatus\":");
        try trace.writeJsonString(writer, value);
    }
    if (partial.error_name) |value| {
        try writer.writeAll(",\"error\":");
        try trace.writeJsonString(writer, value);
    }
    if (partial.screenshot_artifact) |value| {
        try writer.writeAll(",\"screenshotArtifact\":");
        try trace.writeJsonString(writer, value);
    }
    if (partial.source) |value| {
        try writer.writeAll(",\"source\":");
        try trace.writeJsonString(writer, value);
    }
    try writer.writeAll("}");
}

fn writeJoinedStringArrayJson(writer: anytype, value: []const u8) !void {
    try writer.writeAll("[");
    var first = true;
    var parts = std.mem.splitSequence(u8, value, " | ");
    while (parts.next()) |part| {
        if (!first) try writer.writeAll(",");
        first = false;
        try trace.writeJsonString(writer, part);
    }
    try writer.writeAll("]");
}

fn joinStringArray(allocator: std.mem.Allocator, value: std.json.Value, limit: usize) !?[]u8 {
    if (value != .array or value.array.items.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var written: usize = 0;
    for (value.array.items) |item| {
        if (item != .string) continue;
        if (written > 0) try writer.writeAll(" | ");
        try writer.writeAll(item.string);
        written += 1;
        if (written >= limit) break;
    }
    if (written == 0) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

fn joinNearestMatches(allocator: std.mem.Allocator, value: std.json.Value, limit: usize) !?[]u8 {
    if (value != .array or value.array.items.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var written: usize = 0;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const text = stringField(item.object, "text") orelse continue;
        if (written > 0) try writer.writeAll(" | ");
        try writer.writeAll(text);
        if (intField(item.object, "score")) |score| {
            try writer.print(" (score {d})", .{score});
        }
        written += 1;
        if (written >= limit) break;
    }
    if (written == 0) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |actual| return try allocator.dupe(u8, actual);
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn intField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |actual| actual,
        else => null,
    };
}
