const std = @import("std");
const stdio = @import("stdio.zig");
const action_registry = @import("action_registry.zig");
const importer_json = @import("importer_json.zig");
const model = @import("importer_model.zig");
const scenario = @import("scenario.zig");
const trace = @import("trace.zig");

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

    var imported = try parseFlowYamlSliceAt(allocator, content, options, source_path, 0);
    defer imported.deinit(allocator);

    const report_path = if (options.compatibility_report_path) |path|
        try allocator.dupe(u8, path)
    else
        try std.fmt.allocPrint(allocator, "{s}.compatibility.json", .{out_path});
    errdefer allocator.free(report_path);

    var supported_count: usize = 0;
    var rewritten_count: usize = 0;
    var unsupported_count: usize = 0;
    for (imported.compatibility) |item| switch (item.status) {
        .supported => supported_count += 1,
        .rewritten => rewritten_count += 1,
        .unsupported => unsupported_count += 1,
    };

    try writeCompatibilityReport(allocator, report_path, source_path, imported);
    if (options.strict and unsupported_count > 0) return error.UnsupportedImportCommand;

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
        .supported_count = supported_count,
        .rewritten_count = rewritten_count,
        .unsupported_count = unsupported_count,
        .compatibility_report_path = report_path,
    };
}

fn fileExists(path: []const u8) bool {
    stdio.access(path) catch return false;
    return true;
}

fn appendCompatibility(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(model.CompatibilityItem),
    item: []const u8,
    line: u32,
    column: u32,
    source_file: ?[]const u8,
) !void {
    const command = if (splitColon(item)) |pair| pair.key else item;
    if (action_registry.find(.yaml, command) orelse action_registry.find(.json, command)) |spec| {
        const rewritten = !containsAlias(spec.json_aliases, command);
        const message = if (rewritten)
            try std.fmt.allocPrint(allocator, "rewritten to canonical action {s}", .{spec.id})
        else
            try allocator.dupe(u8, "supported without semantic rewrite");
        errdefer allocator.free(message);
        try items.append(allocator, .{
            .command = try allocator.dupe(u8, command),
            .status = if (rewritten) .rewritten else .supported,
            .line = line,
            .column = column,
            .message = message,
            .canonical_action = try allocator.dupe(u8, spec.id),
            .source_file = try dupeOptional(allocator, source_file),
        });
        return;
    }

    const diagnostic = action_registry.unsupported(command);
    const message = if (diagnostic) |value|
        try allocator.dupe(u8, value.reason)
    else
        try allocator.dupe(u8, "command is not supported by the ZMR 1.0 mobile contract");
    errdefer allocator.free(message);
    try items.append(allocator, .{
        .command = try allocator.dupe(u8, command),
        .status = .unsupported,
        .line = line,
        .column = column,
        .message = message,
        .canonical_action = if (diagnostic) |value| try dupeOptional(allocator, value.replacement) else null,
        .source_file = try dupeOptional(allocator, source_file),
    });
}

fn containsAlias(aliases: []const []const u8, value: []const u8) bool {
    for (aliases) |alias| if (std.mem.eql(u8, alias, value)) return true;
    return false;
}

fn firstNonSpaceColumn(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    return index + 1;
}

fn leadingIndent(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    return index;
}

fn isHeaderBoundary(line: []const u8) bool {
    const trimmed = trim(line);
    return std.mem.eql(u8, trimmed, "---") or
        (leadingIndent(line) == 0 and splitColon(trimmed) != null);
}

fn writeCompatibilityReport(
    allocator: std.mem.Allocator,
    path: []const u8,
    source_path: []const u8,
    imported: model.ImportedScenario,
) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(stdio.io(), dir);
    }
    var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
    defer file.close(stdio.io());
    var buffer: [8192]u8 = undefined;
    var file_writer = file.writerStreaming(stdio.io(), &buffer);
    var supported_count: usize = 0;
    var rewritten_count: usize = 0;
    var unsupported_count: usize = 0;
    for (imported.compatibility) |item| switch (item.status) {
        .supported => supported_count += 1,
        .rewritten => rewritten_count += 1,
        .unsupported => unsupported_count += 1,
    };
    const writer = &file_writer.interface;
    try writer.writeAll("{\"version\":1,\"source\":");
    try trace.writeJsonString(writer, source_path);
    try writer.print(",\"summary\":{{\"supported\":{d},\"rewritten\":{d},\"unsupported\":{d}}},\"commands\":[", .{ supported_count, rewritten_count, unsupported_count });
    for (imported.compatibility, 0..) |item, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"command\":");
        try trace.writeJsonString(writer, item.command);
        try writer.writeAll(",\"status\":");
        try trace.writeJsonString(writer, @tagName(item.status));
        try writer.print(",\"line\":{d},\"column\":{d},\"message\":", .{ item.line, item.column });
        try trace.writeJsonString(writer, item.message);
        try writer.writeAll(",\"sourceFile\":");
        if (item.source_file) |value| try trace.writeJsonString(writer, value) else try writer.writeAll("null");
        try writer.writeAll(",\"canonicalAction\":");
        if (item.canonical_action) |value| try trace.writeJsonString(writer, value) else try writer.writeAll("null");
        try writer.writeAll("}");
    }
    try writer.writeAll("]}\n");
    try writer.flush();
    _ = allocator;
}

fn parseFlowYamlSliceAt(
    allocator: std.mem.Allocator,
    content: []const u8,
    options: ImportOptions,
    source_path: ?[]const u8,
    depth: u8,
) !model.ImportedScenario {
    var header_app_id: ?[]const u8 = null;
    defer if (header_app_id) |value| allocator.free(value);
    var header_name: ?[]const u8 = null;
    defer if (header_name) |value| allocator.free(value);

    var steps = std.ArrayList(model.ImportedStep).empty;
    var on_start = std.ArrayList(model.ImportedStep).empty;
    var on_complete = std.ArrayList(model.ImportedStep).empty;
    var compatibility = std.ArrayList(model.CompatibilityItem).empty;
    errdefer {
        for (steps.items) |step| step.deinit(allocator);
        steps.deinit(allocator);
        for (on_start.items) |step| step.deinit(allocator);
        on_start.deinit(allocator);
        for (on_complete.items) |step| step.deinit(allocator);
        on_complete.deinit(allocator);
        for (compatibility.items) |item| item.deinit(allocator);
        compatibility.deinit(allocator);
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
                } else if (std.mem.eql(u8, pair.key, "onFlowStart") or std.mem.eql(u8, pair.key, "onStart")) {
                    index += 1;
                    const hook_start = index;
                    while (index < lines.items.len and !isHeaderBoundary(lines.items[index])) : (index += 1) {}
                    const hook_steps = try parseIndentedCommandList(allocator, lines.items[hook_start..index], hook_start, &compatibility, source_path);
                    try on_start.appendSlice(allocator, hook_steps);
                    if (hook_steps.len > 0) allocator.free(hook_steps);
                    continue;
                } else if (std.mem.eql(u8, pair.key, "onFlowComplete") or std.mem.eql(u8, pair.key, "onComplete")) {
                    index += 1;
                    const hook_start = index;
                    while (index < lines.items.len and !isHeaderBoundary(lines.items[index])) : (index += 1) {}
                    const hook_steps = try parseIndentedCommandList(allocator, lines.items[hook_start..index], hook_start, &compatibility, source_path);
                    try on_complete.appendSlice(allocator, hook_steps);
                    if (hook_steps.len > 0) allocator.free(hook_steps);
                    continue;
                }
            }
            index += 1;
            continue;
        }

        in_commands = true;
        if (!std.mem.startsWith(u8, trimmed, "- ")) return error.ImportExpectedCommand;
        const item = trim(trimmed[2..]);
        const source_line: u32 = @intCast(index + 1);
        const source_column: u32 = @intCast(firstNonSpaceColumn(raw));
        const command_indent = leadingIndent(raw);
        index += 1;
        const block_start = index;
        while (index < lines.items.len) : (index += 1) {
            const next_raw = lines.items[index];
            const next = trim(next_raw);
            if (leadingIndent(next_raw) == command_indent and
                (std.mem.startsWith(u8, next, "- ") or std.mem.eql(u8, next, "---"))) break;
        }
        if (std.mem.eql(u8, commandKey(item), "runFlow")) {
            if (depth >= 32) return error.ImportFlowDepthExceeded;
            const reference = try parseRunFlowReference(allocator, item, lines.items[block_start..index]);
            defer allocator.free(reference);
            const parent_path = source_path orelse return error.UnsupportedImportCommand;
            const parent_dir = std.fs.path.dirname(parent_path) orelse ".";
            const nested_path = try std.fs.path.join(allocator, &.{ parent_dir, reference });
            defer allocator.free(nested_path);
            const nested_content = try stdio.readFileAlloc(allocator, nested_path, 4 * 1024 * 1024);
            defer allocator.free(nested_content);
            var nested = try parseFlowYamlSliceAt(allocator, nested_content, options, nested_path, depth + 1);
            defer nested.deinit(allocator);
            for (nested.steps) |step| try steps.append(allocator, step);
            for (nested.compatibility) |item_info| try compatibility.append(allocator, item_info);
            if (nested.steps.len > 0) allocator.free(nested.steps);
            if (nested.compatibility.len > 0) allocator.free(nested.compatibility);
            nested.steps = &.{};
            nested.compatibility = &.{};
            try appendCompatibility(allocator, &compatibility, item, source_line, source_column, source_path);
            continue;
        }
        const parsed_step = parseFlowYamlCommand(allocator, item, lines.items[block_start..index]) catch |err| {
            if (err != error.UnsupportedImportCommand) return err;
            try appendCompatibility(allocator, &compatibility, item, source_line, source_column, source_path);
            continue;
        };
        try steps.append(allocator, parsed_step);
        try appendCompatibility(allocator, &compatibility, item, source_line, source_column, source_path);
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

    if (steps.items.len == 0 and !(options.strict and compatibility.items.len > 0)) return error.ImportNoSupportedCommands;

    return .{
        .name = name,
        .app_id = app_id,
        .on_start = try on_start.toOwnedSlice(allocator),
        .on_complete = try on_complete.toOwnedSlice(allocator),
        .compatibility = try compatibility.toOwnedSlice(allocator),
        .steps = try steps.toOwnedSlice(allocator),
    };
}

fn parseFlowYamlCommand(allocator: std.mem.Allocator, item: []const u8, block: []const []const u8) anyerror!model.ImportedStep {
    if (item.len == 0) return error.ImportExpectedCommand;
    if (splitColon(item)) |pair| {
        return try parseFlowYamlCommandWithValue(allocator, pair.key, pair.value, block);
    }
    if (std.mem.eql(u8, item, "launchApp")) return .launch;
    if (std.mem.eql(u8, item, "stopApp")) return .stop;
    if (std.mem.eql(u8, item, "killApp") or std.mem.eql(u8, item, "forceStop")) return .kill_app;
    if (std.mem.eql(u8, item, "clearState") or std.mem.eql(u8, item, "clearAppState")) return .clear_state;
    if (std.mem.eql(u8, item, "clearKeychain")) return .clear_keychain;
    if (std.mem.eql(u8, item, "grantPermissions")) return .{ .grant_permissions = try parseStringListFromBlock(allocator, block, "permissions") };
    if (std.mem.eql(u8, item, "hideKeyboard")) return .hide_keyboard;
    if (std.mem.eql(u8, item, "back") or std.mem.eql(u8, item, "pressBack")) return .press_back;
    if (std.mem.eql(u8, item, "pressKey")) return .{ .press_key = try parseRequiredScalarOrBlockValue(allocator, "", block, "key") };
    if (std.mem.eql(u8, item, "takeScreenshot")) return .snapshot;
    if (std.mem.eql(u8, item, "eraseText")) return .{ .erase_text = 80 };
    if (std.mem.eql(u8, item, "waitForAnimationToEnd")) return .{ .sleep_ms = 1000 };
    return error.UnsupportedImportCommand;
}

fn commandKey(item: []const u8) []const u8 {
    return if (splitColon(item)) |pair| pair.key else item;
}

fn parseRunFlowReference(allocator: std.mem.Allocator, item: []const u8, block: []const []const u8) ![]const u8 {
    if (splitColon(item)) |pair| {
        if (pair.value.len > 0) return try parseScalarString(allocator, pair.value);
    }
    for (block) |line| {
        const pair = splitColon(trim(line)) orelse continue;
        if (std.mem.eql(u8, pair.key, "file") or std.mem.eql(u8, pair.key, "path") or std.mem.eql(u8, pair.key, "flow")) {
            return try parseScalarString(allocator, pair.value);
        }
    }
    return error.ImportMissingFlowPath;
}

fn parseFlowYamlCommandWithValue(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    block: []const []const u8,
) anyerror!model.ImportedStep {
    if (std.mem.eql(u8, key, "tapOn")) {
        return .{ .tap = try parseSelectorValueOrBlock(allocator, value, block) };
    }
    if (std.mem.eql(u8, key, "longPressOn")) {
        return .{ .long_press = .{
            .selector = try parseSelectorValueOrBlock(allocator, value, block),
            .duration_ms = @intCast((try parseOptionalU64FromBlock(block, "durationMs") orelse try parseOptionalU64FromBlock(block, "duration") orelse 800)),
        } };
    }
    if (std.mem.eql(u8, key, "doubleTapOn")) {
        return .{ .double_tap = try parseSelectorValueOrBlock(allocator, value, block) };
    }
    if (std.mem.eql(u8, key, "pressKey")) {
        return .{ .press_key = try parseRequiredScalarOrBlockValue(allocator, value, block, "key") };
    }
    if (std.mem.eql(u8, key, "repeat")) {
        const times = try parseBoundedBlockCount(block, "times", 1);
        return .{ .repeat = .{ .count = times, .steps = try parseNestedCommandList(allocator, block) } };
    }
    if (std.mem.eql(u8, key, "retry")) {
        const retries = (try parseOptionalU64FromBlock(block, "maxRetries")) orelse (try parseOptionalU64FromBlock(block, "retries")) orelse 1;
        if (retries > 99) return error.ImportNumberOutOfRange;
        return .{ .retry = .{ .count = @intCast(retries + 1), .steps = try parseNestedCommandList(allocator, block) } };
    }
    if (std.mem.eql(u8, key, "whenVisible")) {
        return .{ .when_visible = .{
            .selector = try parseConditionalSelector(allocator, value, block, "visible"),
            .steps = try parseNestedCommandList(allocator, block),
        } };
    }
    if (std.mem.eql(u8, key, "whenNotVisible")) {
        return .{ .when_not_visible = .{
            .selector = try parseConditionalSelector(allocator, value, block, "notVisible"),
            .steps = try parseNestedCommandList(allocator, block),
        } };
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
    if (std.mem.eql(u8, key, "launchApp")) return .{ .launch_app = try parseLaunchOptionsFromYaml(allocator, value, block) };
    if (std.mem.eql(u8, key, "stopApp")) return .stop;
    if (std.mem.eql(u8, key, "killApp") or std.mem.eql(u8, key, "forceStop")) return .kill_app;
    if (std.mem.eql(u8, key, "clearState") or std.mem.eql(u8, key, "clearAppState")) return .clear_state;
    if (std.mem.eql(u8, key, "clearKeychain")) return .clear_keychain;
    if (std.mem.eql(u8, key, "grantPermissions")) return .{ .grant_permissions = try parseStringListFromBlock(allocator, block, "permissions") };
    if (std.mem.eql(u8, key, "setOrientation")) return .{ .set_orientation = try parseScalarString(allocator, value) };
    if (std.mem.eql(u8, key, "setClipboard") or std.mem.eql(u8, key, "copyText")) return .{ .set_clipboard = try parseRequiredScalarOrBlockValue(allocator, value, block, "text") };
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

fn parseLaunchOptionsFromYaml(
    allocator: std.mem.Allocator,
    value: []const u8,
    block: []const []const u8,
) !scenario.LaunchOptions {
    var options = scenario.LaunchOptions{};
    errdefer options.deinit(allocator);
    if (value.len > 0) {
        options.app_id = try parseScalarString(allocator, value);
        return options;
    }

    var base_indent: ?usize = null;
    for (block) |line| {
        if (trim(line).len == 0 or std.mem.startsWith(u8, trim(line), "#")) continue;
        base_indent = leadingIndent(line);
        break;
    }
    const indent = base_indent orelse return options;
    var index: usize = 0;
    while (index < block.len) : (index += 1) {
        const raw = block[index];
        const trimmed = trim(raw);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        if (leadingIndent(raw) < indent) break;
        if (leadingIndent(raw) != indent) continue;
        const pair = splitColon(trimmed) orelse continue;
        if (std.mem.eql(u8, pair.key, "appId")) {
            if (options.app_id) |old| allocator.free(old);
            options.app_id = try parseScalarString(allocator, pair.value);
        } else if (std.mem.eql(u8, pair.key, "stopApp")) {
            options.stop_app = try parseYamlBool(pair.value);
        } else if (std.mem.eql(u8, pair.key, "clearState")) {
            options.clear_state = try parseYamlBool(pair.value);
        } else if (std.mem.eql(u8, pair.key, "clearKeychain")) {
            options.clear_keychain = try parseYamlBool(pair.value);
        } else if (std.mem.eql(u8, pair.key, "arguments")) {
            const arguments = try parseLaunchArgumentsFromYaml(allocator, block[index + 1 ..], leadingIndent(raw));
            if (options.arguments.len > 0) {
                for (options.arguments) |argument| argument.deinit(allocator);
                allocator.free(options.arguments);
            }
            options.arguments = arguments;
        } else if (std.mem.eql(u8, pair.key, "permissions")) {
            return error.UnsupportedImportCommand;
        }
    }
    return options;
}

fn parseLaunchArgumentsFromYaml(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    header_indent: usize,
) ![]scenario.LaunchArgument {
    var arguments = std.ArrayList(scenario.LaunchArgument).empty;
    errdefer {
        for (arguments.items) |argument| argument.deinit(allocator);
        arguments.deinit(allocator);
    }
    for (lines) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        if (leadingIndent(line) <= header_indent) break;
        const pair = splitColon(trimmed) orelse continue;
        if (pair.key.len == 0) continue;
        try arguments.append(allocator, .{
            .name = try allocator.dupe(u8, pair.key),
            .value = try parseLaunchArgumentFromYaml(allocator, pair.value),
        });
    }
    return try arguments.toOwnedSlice(allocator);
}

fn parseLaunchArgumentFromYaml(allocator: std.mem.Allocator, value: []const u8) !scenario.LaunchArgumentValue {
    const normalized = normalizeScalar(value);
    const quoted = normalized.len >= 2 and
        ((normalized[0] == '"' and normalized[normalized.len - 1] == '"') or
            (normalized[0] == '\'' and normalized[normalized.len - 1] == '\''));
    if (!quoted and equalsIgnoreCase(normalized, "true")) return .{ .boolean = true };
    if (!quoted and equalsIgnoreCase(normalized, "false")) return .{ .boolean = false };
    if (!quoted) {
        if (std.fmt.parseInt(i64, normalized, 10)) |integer| return .{ .integer = integer } else |_| {}
        if (std.fmt.parseFloat(f64, normalized)) |double| return .{ .double = double } else |_| {}
    }
    return .{ .string = try parseScalarString(allocator, value) };
}

fn parseYamlBool(value: []const u8) !bool {
    const normalized = normalizeScalar(value);
    if (equalsIgnoreCase(normalized, "true")) return true;
    if (equalsIgnoreCase(normalized, "false")) return false;
    return error.ImportInvalidBoolean;
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

fn parseStringListFromBlock(allocator: std.mem.Allocator, block: []const []const u8, key: []const u8) ![][]const u8 {
    var values = std.ArrayList([]const u8).empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    var collecting = false;
    for (block) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        if (!collecting) {
            const pair = splitColon(trimmed) orelse continue;
            if (!std.mem.eql(u8, pair.key, key)) continue;
            collecting = true;
            if (pair.value.len > 0) try values.append(allocator, try parseScalarString(allocator, pair.value));
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, "- ")) break;
        try values.append(allocator, try parseScalarString(allocator, trim(trimmed[2..])));
    }
    if (values.items.len == 0) return error.ImportMissingValue;
    return try values.toOwnedSlice(allocator);
}

fn parseBoundedBlockCount(block: []const []const u8, key: []const u8, default_value: u64) !u32 {
    const value = (try parseOptionalU64FromBlock(block, key)) orelse default_value;
    if (value == 0 or value > 100) return error.ImportNumberOutOfRange;
    return @intCast(value);
}

fn parseNestedCommandList(allocator: std.mem.Allocator, block: []const []const u8) anyerror![]model.ImportedStep {
    var commands_line: ?usize = null;
    for (block, 0..) |line, index| {
        const trimmed = trim(line);
        const pair = splitColon(trimmed) orelse continue;
        if (std.mem.eql(u8, pair.key, "commands") or std.mem.eql(u8, pair.key, "steps")) {
            commands_line = index;
            break;
        }
    }
    const start = commands_line orelse return error.ImportMissingValue;
    var command_indent: ?usize = null;
    for (block[start + 1 ..]) |line| {
        if (trim(line).len == 0) continue;
        if (std.mem.startsWith(u8, trim(line), "- ")) {
            command_indent = leadingIndent(line);
            break;
        }
    }
    const indent = command_indent orelse return error.ImportMissingValue;
    var steps = std.ArrayList(model.ImportedStep).empty;
    errdefer {
        for (steps.items) |step| step.deinit(allocator);
        steps.deinit(allocator);
    }
    var index = start + 1;
    while (index < block.len) {
        const raw = block[index];
        const trimmed = trim(raw);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            index += 1;
            continue;
        }
        if (leadingIndent(raw) < indent) break;
        if (leadingIndent(raw) != indent or !std.mem.startsWith(u8, trimmed, "- ")) {
            index += 1;
            continue;
        }
        const item = trim(trimmed[2..]);
        index += 1;
        const block_start = index;
        while (index < block.len) : (index += 1) {
            const next = trim(block[index]);
            if (leadingIndent(block[index]) == indent and std.mem.startsWith(u8, next, "- ")) break;
        }
        try steps.append(allocator, try parseFlowYamlCommand(allocator, item, block[block_start..index]));
    }
    if (steps.items.len == 0) return error.ImportMissingValue;
    return try steps.toOwnedSlice(allocator);
}

fn parseIndentedCommandList(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    base_line: usize,
    compatibility: *std.ArrayList(model.CompatibilityItem),
    source_path: ?[]const u8,
) anyerror![]model.ImportedStep {
    var command_indent: ?usize = null;
    for (lines) |line| {
        if (std.mem.startsWith(u8, trim(line), "- ")) {
            command_indent = leadingIndent(line);
            break;
        }
    }
    const indent = command_indent orelse return try allocator.alloc(model.ImportedStep, 0);
    var steps = std.ArrayList(model.ImportedStep).empty;
    errdefer {
        for (steps.items) |step| step.deinit(allocator);
        steps.deinit(allocator);
    }
    var index: usize = 0;
    while (index < lines.len) {
        const raw = lines[index];
        const trimmed = trim(raw);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            index += 1;
            continue;
        }
        if (leadingIndent(raw) < indent) break;
        if (leadingIndent(raw) != indent or !std.mem.startsWith(u8, trimmed, "- ")) {
            index += 1;
            continue;
        }
        const item = trim(trimmed[2..]);
        const source_line: u32 = @intCast(base_line + index + 1);
        const source_column: u32 = @intCast(firstNonSpaceColumn(raw));
        index += 1;
        const block_start = index;
        while (index < lines.len) : (index += 1) {
            const next = trim(lines[index]);
            if (leadingIndent(lines[index]) == indent and std.mem.startsWith(u8, next, "- ")) break;
        }
        const parsed = parseFlowYamlCommand(allocator, item, lines[block_start..index]) catch |err| {
            if (err != error.UnsupportedImportCommand) return err;
            try appendCompatibility(allocator, compatibility, item, source_line, source_column, source_path);
            continue;
        };
        try steps.append(allocator, parsed);
        try appendCompatibility(allocator, compatibility, item, source_line, source_column, source_path);
    }
    return try steps.toOwnedSlice(allocator);
}

fn parseConditionalSelector(
    allocator: std.mem.Allocator,
    value: []const u8,
    block: []const []const u8,
    condition_key: []const u8,
) anyerror!model.SelectorSpec {
    if (value.len > 0) return .{ .text = try parseScalarString(allocator, value) };
    for (block) |line| {
        const pair = splitColon(trim(line)) orelse continue;
        if (std.mem.eql(u8, pair.key, "selector") or std.mem.eql(u8, pair.key, condition_key)) {
            return .{ .text = try parseScalarString(allocator, pair.value) };
        }
    }
    return error.ImportMissingSelector;
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
