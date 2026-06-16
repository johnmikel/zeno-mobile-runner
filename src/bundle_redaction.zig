const std = @import("std");

pub const Options = struct {
    redact: bool = false,
    omit_screenshots: bool = false,
};

pub fn redactEntry(allocator: std.mem.Allocator, archive_path: []const u8, bytes: []const u8, options: Options) ![]u8 {
    if (std.mem.eql(u8, archive_path, "trace.json")) {
        return try redactTraceManifest(allocator, bytes, options);
    }
    if (std.mem.endsWith(u8, archive_path, ".json") or std.mem.eql(u8, archive_path, "events.jsonl")) {
        return redactJsonishText(allocator, bytes);
    }
    if (isTextPath(archive_path)) {
        return redactFreeText(allocator, bytes);
    }
    return try allocator.dupe(u8, bytes);
}

fn redactTraceManifest(allocator: std.mem.Allocator, bytes: []const u8, options: Options) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return try redactJsonishText(allocator, bytes);

    const arena_allocator = parsed.arena.allocator();
    var redaction = std.json.ObjectMap{};
    try redaction.put(arena_allocator, "enabled", .{ .bool = true });
    try redaction.put(arena_allocator, "screenshots", .{ .string = if (options.omit_screenshots) "omitted" else "placeholder" });
    try redaction.put(arena_allocator, "screenRecordings", .{ .string = "omitted" });
    try redaction.put(arena_allocator, "textArtifacts", .{ .string = "scrubbed" });
    try redaction.put(arena_allocator, "screenshotsOmitted", .{ .bool = options.omit_screenshots });
    try redaction.put(arena_allocator, "screenshotsRedacted", .{ .bool = !options.omit_screenshots });
    try redaction.put(arena_allocator, "screenRecordingsOmitted", .{ .bool = true });
    try parsed.value.object.put(arena_allocator, "redaction", .{ .object = redaction });

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeJsonValueRedacted(&out.writer, parsed.value, null);
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

fn redactJsonishText(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return redactFreeText(allocator, bytes);
    };
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeJsonValueRedacted(&out.writer, parsed.value, null);
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

fn writeJsonValueRedacted(writer: anytype, value: std.json.Value, key_context: ?[]const u8) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |actual| try writer.writeAll(if (actual) "true" else "false"),
        .integer => |actual| try writer.print("{d}", .{actual}),
        .float => |actual| try writer.print("{d}", .{actual}),
        .number_string => |actual| try writer.writeAll(actual),
        .string => |actual| try writeRedactedJsonStringForKey(writer, key_context orelse "", actual),
        .array => |array| {
            try writer.writeAll("[");
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeAll(",");
                try writeJsonValueRedacted(writer, item, key_context);
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
                try writeJsonValueRedacted(writer, entry.value_ptr.*, entry.key_ptr.*);
            }
            try writer.writeAll("}");
        },
    }
}

fn writeRedactedJsonStringForKey(writer: anytype, key: []const u8, value: []const u8) !void {
    if (isSensitiveLabel(key)) {
        try writeJsonString(writer, "[REDACTED:secret]");
    } else if (looksLikeBearerOrToken(value)) {
        try writeJsonString(writer, "[REDACTED:token]");
    } else if (looksLikeEmail(value)) {
        try writeJsonString(writer, "[REDACTED:email]");
    } else {
        try writeJsonString(writer, value);
    }
}

fn redactFreeText(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var sensitive_tag = false;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == '<') {
            sensitive_tag = tagLooksSensitive(bytes[index..@min(bytes.len, index + 240)]);
        } else if (bytes[index] == '>') {
            sensitive_tag = false;
        }

        if (sensitive_tag and (startsWithAt(bytes, index, "text=\"") or startsWithAt(bytes, index, "content-desc=\""))) {
            const prefix_len: usize = if (startsWithAt(bytes, index, "text=\"")) 6 else 14;
            try writer.writeAll(bytes[index .. index + prefix_len]);
            try writer.writeAll("[REDACTED:secret]");
            index += prefix_len;
            while (index < bytes.len and bytes[index] != '"') : (index += 1) {}
            if (index < bytes.len) {
                try writer.writeByte('"');
                index += 1;
            }
            continue;
        }

        if (emailEnd(bytes, index)) |end| {
            try writer.writeAll("[REDACTED:email]");
            index = end;
            continue;
        }
        if (bearerEnd(bytes, index)) |end| {
            try writer.writeAll("[REDACTED:token]");
            index = end;
            continue;
        }
        try writer.writeByte(bytes[index]);
        index += 1;
    }
    return try out.toOwnedSlice();
}

fn emailEnd(bytes: []const u8, start: usize) ?usize {
    if (start > 0 and !isDelimiter(bytes[start - 1])) return null;
    var end = start;
    while (end < bytes.len and !isDelimiter(bytes[end])) : (end += 1) {}
    const value = bytes[start..end];
    return if (looksLikeEmail(value)) end else null;
}

fn bearerEnd(bytes: []const u8, start: usize) ?usize {
    if (!startsWithIgnoreCase(bytes[start..], "bearer ")) return null;
    var end = start;
    while (end < bytes.len and bytes[end] != '"' and bytes[end] != '\'' and bytes[end] != '<' and bytes[end] != '>') : (end += 1) {}
    return end;
}

fn tagLooksSensitive(bytes: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, bytes, '>') orelse bytes.len;
    return isSensitiveLabel(bytes[0..end]);
}

fn isScreenshotPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".png") or std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg");
}

pub fn isPlaceholderScreenshotPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".png");
}

pub fn isVisualArtifactPath(path: []const u8) bool {
    return isScreenshotPath(path) or std.mem.endsWith(u8, path, ".mp4") or std.mem.endsWith(u8, path, ".webm");
}

pub const redacted_screenshot_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
};

fn isTextPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".xml") or std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".txt") or std.mem.endsWith(u8, path, ".log");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...7, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeByte(ch),
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

fn looksLikeEmail(value: []const u8) bool {
    if (value.len < 5 or value.len > 254) return false;
    if (std.mem.indexOfAny(u8, value, " \t\r\n<>\"'") != null) return false;
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    if (at == 0 or at + 3 >= value.len) return false;
    return std.mem.indexOfScalar(u8, value[at + 1 ..], '.') != null;
}

fn looksLikeBearerOrToken(value: []const u8) bool {
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

fn startsWithAt(bytes: []const u8, index: usize, needle: []const u8) bool {
    return index + needle.len <= bytes.len and std.mem.eql(u8, bytes[index .. index + needle.len], needle);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |needle_ch, index| {
        if (std.ascii.toLower(haystack[index]) != std.ascii.toLower(needle_ch)) return false;
    }
    return true;
}

fn isDelimiter(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\r', '\n', '<', '>', '"', '\'', '=', ',', ';', ')' => true,
        else => false,
    };
}
