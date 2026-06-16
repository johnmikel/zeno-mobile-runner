const std = @import("std");
const stdio = @import("stdio.zig");
const importer_json = @import("importer_json.zig");
const model = @import("importer_model.zig");

pub const ImportOptions = model.ImportOptions;
pub const ImportResult = model.ImportResult;

pub fn importFlowYamlFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    out_path: []const u8,
    options: ImportOptions,
) !ImportResult {
    if (!options.force and fileExists(out_path)) return error.ImportOutputExists;

    const content = try stdio.readFileAlloc(allocator, source_path, 4 * 1024 * 1024);
    defer allocator.free(content);

    var imported = try parseFlowYamlSlice(allocator, content, options);
    defer imported.deinit(allocator);

    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(stdio.io(), dir);
    }

    var file = try std.Io.Dir.cwd().createFile(stdio.io(), out_path, .{ .truncate = true });
    defer file.close(stdio.io());
    var write_buffer: [8192]u8 = undefined;
    var file_writer = file.writerStreaming(stdio.io(), &write_buffer);
    try importer_json.writeScenarioJson(&file_writer.interface, imported);
    try file_writer.interface.flush();

    return .{
        .out_path = try allocator.dupe(u8, out_path),
        .name = try allocator.dupe(u8, imported.name),
        .app_id = try dupeOptional(allocator, imported.app_id),
        .step_count = imported.steps.len,
    };
}

fn fileExists(path: []const u8) bool {
    stdio.access(path) catch return false;
    return true;
}

fn parseFlowYamlSlice(allocator: std.mem.Allocator, content: []const u8, options: ImportOptions) !model.ImportedScenario {
    var header_app_id: ?[]const u8 = null;
    defer if (header_app_id) |value| allocator.free(value);
    var header_name: ?[]const u8 = null;
    defer if (header_name) |value| allocator.free(value);

    var steps = std.ArrayList(model.ImportedStep).empty;
    errdefer {
        for (steps.items) |step| step.deinit(allocator);
        steps.deinit(allocator);
    }

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, content, '\n');
    while (split.next()) |line| {
        try lines.append(allocator, std.mem.trimEnd(u8, line, "\r"));
    }

    var in_commands = false;
    var index: usize = 0;
    while (index < lines.items.len) {
        const raw = lines.items[index];
        const trimmed = trim(raw);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "---")) {
            in_commands = true;
            index += 1;
            continue;
        }
        if (!in_commands and !std.mem.startsWith(u8, trimmed, "- ")) {
            if (splitColon(trimmed)) |pair| {
                if (std.mem.eql(u8, pair.key, "appId")) {
                    if (header_app_id) |value| allocator.free(value);
                    header_app_id = try parseScalarString(allocator, pair.value);
                } else if (std.mem.eql(u8, pair.key, "name")) {
                    if (header_name) |value| allocator.free(value);
                    header_name = try parseScalarString(allocator, pair.value);
                }
            }
            index += 1;
            continue;
        }

        in_commands = true;
        if (!std.mem.startsWith(u8, trimmed, "- ")) return error.ImportExpectedCommand;
        const item = trim(trimmed[2..]);
        index += 1;
        const block_start = index;
        while (index < lines.items.len) : (index += 1) {
            const next = trim(lines.items[index]);
            if (std.mem.startsWith(u8, next, "- ") or std.mem.eql(u8, next, "---")) break;
        }
        try steps.append(allocator, try parseFlowYamlCommand(allocator, item, lines.items[block_start..index]));
    }

    const name = if (options.name) |value|
        try allocator.dupe(u8, value)
    else if (header_name) |value|
        try allocator.dupe(u8, value)
    else
        try allocator.dupe(u8, "Imported mobile flow");
    errdefer allocator.free(name);

    const app_id = if (options.app_id) |value|
        try allocator.dupe(u8, value)
    else
        try dupeOptional(allocator, header_app_id);
    errdefer if (app_id) |value| allocator.free(value);

    return .{
        .name = name,
        .app_id = app_id,
        .steps = try steps.toOwnedSlice(allocator),
    };
}

fn parseFlowYamlCommand(allocator: std.mem.Allocator, item: []const u8, block: []const []const u8) !model.ImportedStep {
    if (item.len == 0) return error.ImportExpectedCommand;
    if (splitColon(item)) |pair| {
        return try parseFlowYamlCommandWithValue(allocator, pair.key, pair.value, block);
    }
    if (std.mem.eql(u8, item, "launchApp")) return .launch;
    if (std.mem.eql(u8, item, "stopApp")) return .stop;
    if (std.mem.eql(u8, item, "clearState") or std.mem.eql(u8, item, "clearAppState")) return .clear_state;
    if (std.mem.eql(u8, item, "hideKeyboard")) return .hide_keyboard;
    if (std.mem.eql(u8, item, "back") or std.mem.eql(u8, item, "pressBack")) return .press_back;
    if (std.mem.eql(u8, item, "takeScreenshot")) return .snapshot;
    if (std.mem.eql(u8, item, "eraseText")) return .{ .erase_text = 80 };
    if (std.mem.eql(u8, item, "waitForAnimationToEnd")) return .{ .sleep_ms = 1000 };
    return error.UnsupportedImportCommand;
}

fn parseFlowYamlCommandWithValue(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    block: []const []const u8,
) !model.ImportedStep {
    if (std.mem.eql(u8, key, "tapOn")) {
        return .{ .tap = try parseSelectorValueOrBlock(allocator, value, block) };
    }
    if (std.mem.eql(u8, key, "inputText")) {
        return .{ .type_text = try parseRequiredScalarOrBlockValue(allocator, value, block, "text") };
    }
    if (std.mem.eql(u8, key, "eraseText")) {
        const parsed = if (value.len == 0) try parseOptionalU32FromBlock(block, "characters") else try parseU32(value);
        return .{ .erase_text = parsed orelse 80 };
    }
    if (std.mem.eql(u8, key, "hideKeyboard")) return .hide_keyboard;
    if (std.mem.eql(u8, key, "back") or std.mem.eql(u8, key, "pressBack")) return .press_back;
    if (std.mem.eql(u8, key, "launchApp")) return .launch;
    if (std.mem.eql(u8, key, "stopApp")) return .stop;
    if (std.mem.eql(u8, key, "clearState") or std.mem.eql(u8, key, "clearAppState")) return .clear_state;
    if (std.mem.eql(u8, key, "takeScreenshot")) return .snapshot;
    if (std.mem.eql(u8, key, "openLink")) {
        return .{ .open_link = try parseRequiredScalarOrBlockValue(allocator, value, block, "link") };
    }
    if (std.mem.eql(u8, key, "assertVisible")) {
        return .{ .assert_visible = try parseSelectorValueOrBlock(allocator, value, block) };
    }
    if (std.mem.eql(u8, key, "assertNotVisible")) {
        return .{ .assert_not_visible = try parseSelectorValueOrBlock(allocator, value, block) };
    }
    if (std.mem.eql(u8, key, "waitUntilVisible")) {
        return .{ .wait_visible = .{
            .selector = try parseSelectorValueOrBlock(allocator, value, block),
            .timeout_ms = (try parseOptionalU64FromBlock(block, "timeout")) orelse 5000,
        } };
    }
    if (std.mem.eql(u8, key, "waitUntilNotVisible")) {
        return .{ .wait_not_visible = .{
            .selector = try parseSelectorValueOrBlock(allocator, value, block),
            .timeout_ms = (try parseOptionalU64FromBlock(block, "timeout")) orelse 5000,
        } };
    }
    if (std.mem.eql(u8, key, "scrollUntilVisible")) {
        var scroll = model.ScrollStep{
            .selector = try parseSelectorValueOrBlock(allocator, value, block),
            .direction = (try parseDirectionFromBlock(block)) orelse "down",
            .timeout_ms = (try parseOptionalU64FromBlock(block, "timeout")) orelse 5000,
        };
        errdefer scroll.deinit(allocator);
        if (try parseOptionalU64FromBlock(block, "timeoutMs")) |timeout| scroll.timeout_ms = timeout;
        return .{ .scroll_until_visible = scroll };
    }
    if (std.mem.eql(u8, key, "waitForAnimationToEnd")) {
        return .{ .sleep_ms = if (value.len == 0) ((try parseOptionalU64FromBlock(block, "timeout")) orelse 1000) else try parseU64(value) };
    }
    return error.UnsupportedImportCommand;
}

fn parseSelectorValueOrBlock(allocator: std.mem.Allocator, value: []const u8, block: []const []const u8) !model.SelectorSpec {
    if (value.len > 0) return .{ .text = try parseScalarString(allocator, value) };
    const parsed = try parseSelectorBlock(allocator, block);
    if (!parsed.hasAny()) return error.ImportMissingSelector;
    return parsed;
}

fn parseSelectorBlock(allocator: std.mem.Allocator, block: []const []const u8) !model.SelectorSpec {
    var out = model.SelectorSpec{};
    errdefer out.deinit(allocator);
    for (block) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        const pair = splitColon(trimmed) orelse continue;
        if (std.mem.eql(u8, pair.key, "id")) {
            replaceString(allocator, &out.id, try parseScalarString(allocator, pair.value));
        } else if (std.mem.eql(u8, pair.key, "text")) {
            replaceString(allocator, &out.text, try parseScalarString(allocator, pair.value));
        } else if (std.mem.eql(u8, pair.key, "textContains") or std.mem.eql(u8, pair.key, "contains")) {
            replaceString(allocator, &out.text_contains, try parseScalarString(allocator, pair.value));
        } else if (std.mem.eql(u8, pair.key, "contentDescription") or std.mem.eql(u8, pair.key, "contentDesc")) {
            replaceString(allocator, &out.content_desc, try parseScalarString(allocator, pair.value));
        } else if (std.mem.eql(u8, pair.key, "element") and pair.value.len > 0) {
            if (!out.hasAny()) out.text = try parseScalarString(allocator, pair.value);
        }
    }
    return out;
}

fn parseRequiredScalarOrBlockValue(allocator: std.mem.Allocator, value: []const u8, block: []const []const u8, block_key: []const u8) ![]const u8 {
    if (value.len > 0) return try parseScalarString(allocator, value);
    for (block) |line| {
        const pair = splitColon(trim(line)) orelse continue;
        if (std.mem.eql(u8, pair.key, block_key) or std.mem.eql(u8, pair.key, "value")) {
            return try parseScalarString(allocator, pair.value);
        }
    }
    return error.ImportMissingValue;
}

fn parseDirectionFromBlock(block: []const []const u8) !?[]const u8 {
    for (block) |line| {
        const pair = splitColon(trim(line)) orelse continue;
        if (!std.mem.eql(u8, pair.key, "direction")) continue;
        const value = normalizeScalar(pair.value);
        if (equalsIgnoreCase(value, "DOWN")) return "down";
        if (equalsIgnoreCase(value, "UP")) return "up";
        return error.UnsupportedImportDirection;
    }
    return null;
}

fn parseOptionalU64FromBlock(block: []const []const u8, key: []const u8) !?u64 {
    for (block) |line| {
        const pair = splitColon(trim(line)) orelse continue;
        if (std.mem.eql(u8, pair.key, key)) return try parseU64(pair.value);
    }
    return null;
}

fn parseOptionalU32FromBlock(block: []const []const u8, key: []const u8) !?u32 {
    const value = (try parseOptionalU64FromBlock(block, key)) orelse return null;
    if (value > std.math.maxInt(u32)) return error.ImportNumberOutOfRange;
    return @intCast(value);
}

fn replaceString(allocator: std.mem.Allocator, target: *?[]const u8, value: []const u8) void {
    if (target.*) |old| allocator.free(old);
    target.* = value;
}

const Pair = struct {
    key: []const u8,
    value: []const u8,
};

fn splitColon(line: []const u8) ?Pair {
    const index = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{
        .key = trim(line[0..index]),
        .value = trim(line[index + 1 ..]),
    };
}

fn parseScalarString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const normalized = normalizeScalar(value);
    if (normalized.len >= 2 and normalized[0] == '"' and normalized[normalized.len - 1] == '"') {
        return try unescapeDoubleQuoted(allocator, normalized[1 .. normalized.len - 1]);
    }
    if (normalized.len >= 2 and normalized[0] == '\'' and normalized[normalized.len - 1] == '\'') {
        return try allocator.dupe(u8, normalized[1 .. normalized.len - 1]);
    }
    return try allocator.dupe(u8, normalized);
}

fn normalizeScalar(value: []const u8) []const u8 {
    return trim(value);
}

fn unescapeDoubleQuoted(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '\\' or index + 1 >= value.len) {
            try out.append(allocator, value[index]);
            continue;
        }
        index += 1;
        switch (value[index]) {
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            else => try out.append(allocator, value[index]),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parseU64(value: []const u8) !u64 {
    return try std.fmt.parseInt(u64, normalizeScalar(value), 10);
}

fn parseU32(value: []const u8) !?u32 {
    const parsed = try parseU64(value);
    if (parsed > std.math.maxInt(u32)) return error.ImportNumberOutOfRange;
    return @intCast(parsed);
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn equalsIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |actual| return try allocator.dupe(u8, actual);
    return null;
}
