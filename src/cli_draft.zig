const std = @import("std");

const cli_output = @import("cli_output.zig");
const trace = @import("trace.zig");
const version = @import("version.zig");

const max_draft_selectors = 3;

pub const ParsedArgs = struct {
    from_trace: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    include_actions: bool = false,
    force: bool = false,
    json: bool = false,
};

pub const DraftSummary = struct {
    ok: bool = true,
    out_path: []const u8,
    trace_dir: []const u8,
    source_snapshot: []const u8,
    name: []const u8,
    app_id: ?[]const u8 = null,
    selector_count: usize,
    step_count: usize,
    warnings: []const []const u8 = &.{},
};

pub const OwnedDraft = struct {
    summary: DraftSummary,
    owned_strings: std.ArrayList([]const u8),
    warnings: std.ArrayList([]const u8),

    pub fn deinit(self: *OwnedDraft, allocator: std.mem.Allocator) void {
        for (self.owned_strings.items) |value| allocator.free(value);
        self.owned_strings.deinit(allocator);
        self.warnings.deinit(allocator);
    }
};

const TraceMetadata = struct {
    scenario_name: []const u8,
    app_id: ?[]const u8,
    events_path: []const u8,
    artifacts_dir: []const u8,
    snapshot_count: usize,
};

const SelectorKind = enum {
    resource_id,
    content_desc,
    text,
};

const DraftSelector = struct {
    kind: SelectorKind,
    value: []const u8,
};

const DraftActionStep = struct {
    json: []const u8,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--from-trace")) {
            index += 1;
            parsed.from_trace = if (index < args.len) args[index] else return error.MissingTraceDir;
        } else if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            parsed.out_path = if (index < args.len) args[index] else return error.MissingDraftOut;
        } else if (std.mem.eql(u8, arg, "--name")) {
            index += 1;
            parsed.name = if (index < args.len) args[index] else return error.MissingParam;
        } else if (std.mem.eql(u8, arg, "--app-id")) {
            index += 1;
            parsed.app_id = if (index < args.len) args[index] else return error.MissingAppId;
        } else if (std.mem.eql(u8, arg, "--include-actions")) {
            parsed.include_actions = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            parsed.force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else {
            return error.UnknownFlag;
        }
    }

    if (parsed.from_trace == null) return error.MissingTraceDir;
    if (parsed.out_path == null) return error.MissingDraftOut;
    return parsed;
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseArgs(raw_args.items);
    var draft = try draftFromTrace(allocator, parsed);
    defer draft.deinit(allocator);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (parsed.json) {
        try writeJson(stdout, draft.summary);
        return;
    }

    try stdout.print("wrote {s}\n", .{draft.summary.out_path});
    try stdout.writeAll("next: zmr validate --json ");
    try cli_output.writeShellArg(stdout, draft.summary.out_path);
    try stdout.writeAll("\n");
}

pub fn draftFromTrace(allocator: std.mem.Allocator, parsed: ParsedArgs) !OwnedDraft {
    const from_trace = parsed.from_trace orelse return error.MissingTraceDir;
    const out_path = parsed.out_path orelse return error.MissingDraftOut;

    var owned = OwnedDraft{
        .summary = .{
            .out_path = undefined,
            .trace_dir = undefined,
            .source_snapshot = undefined,
            .name = undefined,
            .selector_count = 0,
            .step_count = 0,
        },
        .owned_strings = .empty,
        .warnings = .empty,
    };
    errdefer owned.deinit(allocator);

    const manifest_path = try std.fs.path.join(allocator, &.{ from_trace, "trace.json" });
    defer allocator.free(manifest_path);
    const manifest_content = try std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(manifest_content);

    var parsed_manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_content, .{});
    defer parsed_manifest.deinit();
    if (parsed_manifest.value != .object) return error.InvalidTraceManifest;
    const metadata = traceMetadata(parsed_manifest.value.object);

    const snapshot_path = try latestSnapshotPath(allocator, &owned, from_trace, metadata);
    const selectors = try parseSemanticSelectors(allocator, snapshot_path, &owned);
    defer freeSelectors(allocator, selectors);
    const action_steps = if (parsed.include_actions)
        try parseReplaySteps(allocator, &owned, from_trace, metadata)
    else
        try allocator.alloc(DraftActionStep, 0);
    defer allocator.free(action_steps);

    const draft_name = if (parsed.name) |explicit|
        try ownString(allocator, &owned, explicit)
    else if (metadata.scenario_name.len > 0)
        try ownFmt(allocator, &owned, "draft from {s}", .{metadata.scenario_name})
    else
        try ownString(allocator, &owned, "draft from trace");

    const app_id = if (parsed.app_id) |explicit|
        try ownString(allocator, &owned, explicit)
    else if (metadata.app_id) |from_manifest|
        try ownString(allocator, &owned, from_manifest)
    else
        null;

    try writeScenarioFile(out_path, draft_name, app_id, action_steps, selectors, parsed.force);

    owned.summary.out_path = try ownString(allocator, &owned, out_path);
    owned.summary.trace_dir = try ownString(allocator, &owned, from_trace);
    owned.summary.source_snapshot = snapshot_path;
    owned.summary.name = draft_name;
    owned.summary.app_id = app_id;
    owned.summary.selector_count = selectors.len;
    owned.summary.step_count = (if (action_steps.len > 0) action_steps.len else 1) + 1 + selectors.len;
    try appendWarning(allocator, &owned, "draft requires human review before commit");
    if (selectors.len == 0) try appendWarning(allocator, &owned, "no stable visible selectors were found in the semantic snapshot");
    owned.summary.warnings = owned.warnings.items;

    return owned;
}

fn traceMetadata(object: std.json.ObjectMap) TraceMetadata {
    return .{
        .scenario_name = optionalString(object, "scenarioName") orelse "",
        .app_id = optionalString(object, "appId"),
        .events_path = optionalString(object, "eventsPath") orelse "events.jsonl",
        .artifacts_dir = optionalString(object, "artifactsDir") orelse "artifacts",
        .snapshot_count = optionalUsize(object, "snapshotCount") orelse 0,
    };
}

fn parseReplaySteps(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    trace_dir: []const u8,
    metadata: TraceMetadata,
) ![]DraftActionStep {
    const events_path = try std.fs.path.join(allocator, &.{ trace_dir, metadata.events_path });
    defer allocator.free(events_path);
    const content = std.fs.cwd().readFileAlloc(allocator, events_path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            try appendWarning(allocator, owned, "trace events were not found; action replay was skipped");
            return try allocator.alloc(DraftActionStep, 0);
        },
        else => return err,
    };
    defer allocator.free(content);

    var steps = std.ArrayList(DraftActionStep).empty;
    errdefer steps.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            try appendWarning(allocator, owned, "invalid trace event was skipped");
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event = parsed.value.object;
        const kind = optionalString(event, "kind") orelse continue;
        const payload_value = event.get("payload") orelse continue;
        if (payload_value != .object) continue;

        if (try replayStepJson(allocator, owned, kind, payload_value.object)) |json| {
            try steps.append(allocator, .{ .json = json });
        }
    }

    return try steps.toOwnedSlice(allocator);
}

fn replayStepJson(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    kind: []const u8,
    payload: std.json.ObjectMap,
) !?[]const u8 {
    if (isControlEvent(kind)) return null;
    if (!isSuccessfulPayload(payload)) return null;

    if (std.mem.eql(u8, kind, "app.launch")) {
        return try ownString(allocator, owned, "{\"action\":\"launch\"}");
    }
    if (std.mem.eql(u8, kind, "app.openLink")) {
        const url = optionalString(payload, "url") orelse return try warnMissingReplayField(allocator, owned, kind);
        return try actionWithStringField(allocator, owned, "openLink", "url", url);
    }
    if (std.mem.eql(u8, kind, "ui.tap")) {
        const selector_value = payload.get("selector") orelse return try warnMissingReplayField(allocator, owned, kind);
        if (selector_value != .object) return try warnMissingReplayField(allocator, owned, kind);
        return try actionWithSelector(allocator, owned, "tap", selector_value);
    }
    if (std.mem.eql(u8, kind, "ui.type")) {
        const text = optionalString(payload, "text") orelse return try warnMissingReplayField(allocator, owned, kind);
        if (isRedactedTraceText(text)) {
            try appendWarningFmt(allocator, owned, "redacted trace text action was skipped: {s}", .{kind});
            return null;
        }
        if (payload.get("selector")) |selector_value| {
            if (selector_value == .object) return try actionWithSelectorAndString(allocator, owned, "typeText", selector_value, "text", text);
        }
        return try actionWithStringField(allocator, owned, "typeText", "text", text);
    }
    if (std.mem.eql(u8, kind, "ui.eraseText")) {
        const max_chars = optionalUsize(payload, "maxChars") orelse return try warnMissingReplayField(allocator, owned, kind);
        if (payload.get("selector")) |selector_value| {
            if (selector_value == .object) return try actionWithSelectorAndInt(allocator, owned, "eraseText", selector_value, "maxChars", max_chars);
        }
        return try actionWithIntField(allocator, owned, "eraseText", "maxChars", max_chars);
    }
    if (std.mem.eql(u8, kind, "ui.hideKeyboard")) {
        return try ownString(allocator, owned, "{\"action\":\"hideKeyboard\"}");
    }
    if (std.mem.eql(u8, kind, "ui.pressBack")) {
        return try ownString(allocator, owned, "{\"action\":\"pressBack\"}");
    }
    if (std.mem.eql(u8, kind, "wait.visible")) {
        const selector_value = payload.get("selector") orelse return try warnMissingReplayField(allocator, owned, kind);
        if (selector_value != .object) return try warnMissingReplayField(allocator, owned, kind);
        return try actionWithSelector(allocator, owned, "waitVisible", selector_value);
    }
    if (std.mem.eql(u8, kind, "wait.notVisible")) {
        const selector_value = payload.get("selector") orelse return try warnMissingReplayField(allocator, owned, kind);
        if (selector_value != .object) return try warnMissingReplayField(allocator, owned, kind);
        return try actionWithSelector(allocator, owned, "waitNotVisible", selector_value);
    }
    if (std.mem.eql(u8, kind, "wait.any")) {
        const selector_value = payload.get("selector") orelse return try warnMissingReplayField(allocator, owned, kind);
        if (selector_value != .object) return try warnMissingReplayField(allocator, owned, kind);
        return try actionWithSelector(allocator, owned, "waitVisible", selector_value);
    }
    if (std.mem.eql(u8, kind, "ui.scrollUntilVisible")) {
        const selector_value = payload.get("selector") orelse return try warnMissingReplayField(allocator, owned, kind);
        if (selector_value != .object) return try warnMissingReplayField(allocator, owned, kind);
        return try actionWithSelector(allocator, owned, "scrollUntilVisible", selector_value);
    }
    if (std.mem.eql(u8, kind, "assert.healthy")) {
        return try ownString(allocator, owned, "{\"action\":\"assertHealthy\"}");
    }

    try appendWarningFmt(allocator, owned, "unsupported trace action was skipped: {s}", .{kind});
    return null;
}

fn latestSnapshotPath(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    trace_dir: []const u8,
    metadata: TraceMetadata,
) ![]const u8 {
    if (metadata.snapshot_count > 0) {
        const candidate_name = try std.fmt.allocPrint(allocator, "snapshot-{d}.json", .{metadata.snapshot_count});
        defer allocator.free(candidate_name);
        const candidate = try std.fs.path.join(allocator, &.{ trace_dir, metadata.artifacts_dir, candidate_name });
        errdefer allocator.free(candidate);
        if (pathExists(candidate)) {
            try owned.owned_strings.append(allocator, candidate);
            return candidate;
        }
        allocator.free(candidate);
    }

    const artifacts_path = try std.fs.path.join(allocator, &.{ trace_dir, metadata.artifacts_dir });
    defer allocator.free(artifacts_path);
    var dir = try std.fs.cwd().openDir(artifacts_path, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    var best_number: usize = 0;
    var best_name: ?[]u8 = null;
    defer if (best_name) |value| allocator.free(value);
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const number = snapshotNumber(entry.name) orelse continue;
        if (best_name == null or number > best_number) {
            if (best_name) |value| allocator.free(value);
            best_name = try allocator.dupe(u8, entry.name);
            best_number = number;
        }
    }

    const selected_name = best_name orelse return error.SemanticSnapshotMissing;
    const path = try std.fs.path.join(allocator, &.{ trace_dir, metadata.artifacts_dir, selected_name });
    errdefer allocator.free(path);
    try owned.owned_strings.append(allocator, path);
    return path;
}

fn parseSemanticSelectors(
    allocator: std.mem.Allocator,
    path: []const u8,
    owned: *OwnedDraft,
) ![]DraftSelector {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSemanticSnapshot;
    const nodes_value = parsed.value.object.get("nodes") orelse return error.InvalidSemanticSnapshot;
    if (nodes_value != .array) return error.InvalidSemanticSnapshot;

    var selectors = std.ArrayList(DraftSelector).empty;
    errdefer freeSelectors(allocator, selectors.items);

    var skipped_unstable = false;
    for (nodes_value.array.items) |node_value| {
        if (selectors.items.len >= max_draft_selectors) break;
        if (node_value != .object) continue;
        const node = node_value.object;
        if (!boolField(node, "visible") or !boolField(node, "enabled")) continue;

        const selected = selectNodeSelector(node) orelse {
            skipped_unstable = true;
            continue;
        };
        if (hasSelector(selectors.items, selected.kind, selected.value)) continue;

        try selectors.append(allocator, .{
            .kind = selected.kind,
            .value = try allocator.dupe(u8, selected.value),
        });
        if (selected.kind == .text) {
            try appendWarning(allocator, owned, "text selectors can be less stable than resource IDs or accessibility labels");
        }
    }

    if (skipped_unstable) {
        try appendWarning(allocator, owned, "visible nodes with generated or class-only selectors were skipped");
    }

    return try selectors.toOwnedSlice(allocator);
}

fn freeSelectors(allocator: std.mem.Allocator, selectors: []DraftSelector) void {
    for (selectors) |draft_selector| allocator.free(draft_selector.value);
    allocator.free(selectors);
}

fn selectNodeSelector(node: std.json.ObjectMap) ?DraftSelector {
    if (node.get("selector")) |value| {
        if (value == .object) {
            if (nonEmptyString(value.object, "resourceId")) |actual| return .{ .kind = .resource_id, .value = actual };
            if (nonEmptyString(value.object, "contentDesc")) |actual| return .{ .kind = .content_desc, .value = actual };
            if (nonEmptyString(value.object, "text")) |actual| return .{ .kind = .text, .value = actual };
        }
    }
    if (node.get("source")) |value| {
        if (value == .object) {
            if (nonEmptyString(value.object, "resourceId")) |actual| return .{ .kind = .resource_id, .value = actual };
            if (nonEmptyString(value.object, "contentDesc")) |actual| return .{ .kind = .content_desc, .value = actual };
            if (nonEmptyString(value.object, "text")) |actual| return .{ .kind = .text, .value = actual };
        }
    }
    return null;
}

fn hasSelector(selectors: []const DraftSelector, kind: SelectorKind, value: []const u8) bool {
    for (selectors) |draft_selector| {
        if (draft_selector.kind == kind and std.mem.eql(u8, draft_selector.value, value)) return true;
    }
    return false;
}

fn writeScenarioFile(
    out_path: []const u8,
    name: []const u8,
    app_id: ?[]const u8,
    action_steps: []const DraftActionStep,
    selectors: []const DraftSelector,
    force: bool,
) !void {
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) try std.fs.cwd().makePath(dir);
    }
    var file = if (force)
        try std.fs.cwd().createFile(out_path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(out_path, .{ .exclusive = true });
    defer file.close();

    var write_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(&write_buffer);
    try writeScenarioJson(&file_writer.interface, name, app_id, action_steps, selectors);
    try file_writer.interface.flush();
}

fn writeScenarioJson(
    writer: anytype,
    name: []const u8,
    app_id: ?[]const u8,
    action_steps: []const DraftActionStep,
    selectors: []const DraftSelector,
) !void {
    try writer.writeAll("{\"name\":");
    try trace.writeJsonString(writer, name);
    if (app_id) |actual| {
        try writer.writeAll(",\"appId\":");
        try trace.writeJsonString(writer, actual);
    }
    try writer.writeAll(",\"steps\":[");
    if (action_steps.len == 0) {
        try writer.writeAll("{\"action\":\"launch\"}");
    } else {
        for (action_steps, 0..) |step, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll(step.json);
        }
    }
    try writer.writeAll(",{\"action\":\"snapshot\"}");
    for (selectors) |draft_selector| {
        try writer.writeAll(",{\"action\":\"assertVisible\",\"selector\":{");
        switch (draft_selector.kind) {
            .resource_id => try writer.writeAll("\"resourceId\":"),
            .content_desc => try writer.writeAll("\"contentDesc\":"),
            .text => try writer.writeAll("\"text\":"),
        }
        try trace.writeJsonString(writer, draft_selector.value);
        try writer.writeAll("}}");
    }
    try writer.writeAll("]}\n");
}

pub fn writeJson(writer: anytype, summary: DraftSummary) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (summary.ok) "true" else "false");
    try writer.writeAll(",\"mode\":\"draft\",\"schemaVersion\":1");
    try writer.writeAll(",\"runnerVersion\":");
    try trace.writeJsonString(writer, version.runner_version);
    try writer.writeAll(",\"protocolVersion\":");
    try trace.writeJsonString(writer, version.protocol_version);
    try writer.writeAll(",\"out\":");
    try trace.writeJsonString(writer, summary.out_path);
    try writer.writeAll(",\"traceDir\":");
    try trace.writeJsonString(writer, summary.trace_dir);
    try writer.writeAll(",\"sourceSnapshot\":");
    try trace.writeJsonString(writer, summary.source_snapshot);
    try writer.writeAll(",\"name\":");
    try trace.writeJsonString(writer, summary.name);
    try writer.writeAll(",\"appId\":");
    if (summary.app_id) |actual| {
        try trace.writeJsonString(writer, actual);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"selectorCount\":{d},\"stepCount\":{d}", .{ summary.selector_count, summary.step_count });
    try writer.writeAll(",\"warnings\":[");
    for (summary.warnings, 0..) |warning, index| {
        if (index > 0) try writer.writeAll(",");
        try trace.writeJsonString(writer, warning);
    }
    try writer.writeAll("],\"nextCommands\":[\"zmr validate --json ");
    try cli_output.writeShellArgJsonContent(writer, summary.out_path);
    try writer.writeAll("\",\"zmr run ");
    try cli_output.writeShellArgJsonContent(writer, summary.out_path);
    try writer.writeAll(" --json --trace-dir ");
    try cli_output.writeShellArgJsonContent(writer, summary.trace_dir);
    try writer.writeAll("\"]}\n");
}

fn actionWithStringField(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    action: []const u8,
    key: []const u8,
    value: []const u8,
) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    try writer.writeAll("{\"action\":");
    try trace.writeJsonString(writer, action);
    try writer.writeAll(",");
    try trace.writeJsonString(writer, key);
    try writer.writeAll(":");
    try trace.writeJsonString(writer, value);
    try writer.writeAll("}");
    return try ownBytes(allocator, owned, buffer.items);
}

fn actionWithIntField(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    action: []const u8,
    key: []const u8,
    value: usize,
) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    try writer.writeAll("{\"action\":");
    try trace.writeJsonString(writer, action);
    try writer.writeAll(",");
    try trace.writeJsonString(writer, key);
    try writer.print(":{d}}}", .{value});
    return try ownBytes(allocator, owned, buffer.items);
}

fn actionWithSelector(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    action: []const u8,
    selector_value: std.json.Value,
) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    try writer.writeAll("{\"action\":");
    try trace.writeJsonString(writer, action);
    try writer.writeAll(",\"selector\":");
    try writeJsonValue(writer, selector_value);
    try writer.writeAll("}");
    return try ownBytes(allocator, owned, buffer.items);
}

fn actionWithSelectorAndString(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    action: []const u8,
    selector_value: std.json.Value,
    key: []const u8,
    value: []const u8,
) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    try writer.writeAll("{\"action\":");
    try trace.writeJsonString(writer, action);
    try writer.writeAll(",\"selector\":");
    try writeJsonValue(writer, selector_value);
    try writer.writeAll(",");
    try trace.writeJsonString(writer, key);
    try writer.writeAll(":");
    try trace.writeJsonString(writer, value);
    try writer.writeAll("}");
    return try ownBytes(allocator, owned, buffer.items);
}

fn actionWithSelectorAndInt(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    action: []const u8,
    selector_value: std.json.Value,
    key: []const u8,
    value: usize,
) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    try writer.writeAll("{\"action\":");
    try trace.writeJsonString(writer, action);
    try writer.writeAll(",\"selector\":");
    try writeJsonValue(writer, selector_value);
    try writer.writeAll(",");
    try trace.writeJsonString(writer, key);
    try writer.print(":{d}}}", .{value});
    return try ownBytes(allocator, owned, buffer.items);
}

fn warnMissingReplayField(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    kind: []const u8,
) !?[]const u8 {
    try appendWarningFmt(allocator, owned, "trace action was skipped because required replay fields were missing: {s}", .{kind});
    return null;
}

fn isControlEvent(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "scenario.start") or
        std.mem.eql(u8, kind, "scenario.end") or
        std.mem.eql(u8, kind, "step.done") or
        std.mem.eql(u8, kind, "step.error") or
        std.mem.eql(u8, kind, "step.optional") or
        std.mem.eql(u8, kind, "step.whenVisible.skipped") or
        std.mem.eql(u8, kind, "step.repeat.iteration") or
        std.mem.eql(u8, kind, "observe.snapshot") or
        std.mem.eql(u8, kind, "observe.semanticSnapshot") or
        std.mem.eql(u8, kind, "observe.snapshot.semanticExtraction") or
        std.mem.eql(u8, kind, "observe.retry") or
        std.mem.eql(u8, kind, "trace.export");
}

fn isSuccessfulPayload(payload: std.json.ObjectMap) bool {
    const status_value = payload.get("status") orelse return true;
    return status_value == .string and std.mem.eql(u8, status_value.string, "ok");
}

fn isRedactedTraceText(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "[REDACTED:");
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |actual| try writer.writeAll(if (actual) "true" else "false"),
        .integer => |actual| try writer.print("{d}", .{actual}),
        .float => |actual| try writer.print("{d}", .{actual}),
        .number_string => |actual| try writer.writeAll(actual),
        .string => |actual| try trace.writeJsonString(writer, actual),
        .array => |array| {
            try writer.writeAll("[");
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeAll(",");
                try writeJsonValue(writer, item);
            }
            try writer.writeAll("]");
        },
        .object => |object| {
            try writer.writeAll("{");
            var iterator = object.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try trace.writeJsonString(writer, entry.key_ptr.*);
                try writer.writeAll(":");
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeAll("}");
        },
    }
}

fn appendWarning(allocator: std.mem.Allocator, owned: *OwnedDraft, warning: []const u8) !void {
    for (owned.warnings.items) |existing| {
        if (std.mem.eql(u8, existing, warning)) return;
    }
    try owned.warnings.append(allocator, warning);
}

fn appendWarningFmt(
    allocator: std.mem.Allocator,
    owned: *OwnedDraft,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const warning = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(warning);
    for (owned.warnings.items) |existing| {
        if (std.mem.eql(u8, existing, warning)) {
            allocator.free(warning);
            return;
        }
    }
    try owned.owned_strings.append(allocator, warning);
    try owned.warnings.append(allocator, warning);
}

fn ownString(allocator: std.mem.Allocator, owned: *OwnedDraft, value: []const u8) ![]const u8 {
    const copy = try allocator.dupe(u8, value);
    try owned.owned_strings.append(allocator, copy);
    return copy;
}

fn ownBytes(allocator: std.mem.Allocator, owned: *OwnedDraft, value: []const u8) ![]const u8 {
    return try ownString(allocator, owned, value);
}

fn ownFmt(allocator: std.mem.Allocator, owned: *OwnedDraft, comptime fmt: []const u8, args: anytype) ![]const u8 {
    const copy = try std.fmt.allocPrint(allocator, fmt, args);
    try owned.owned_strings.append(allocator, copy);
    return copy;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |actual| if (actual.len > 0) actual else null,
        else => null,
    };
}

fn nonEmptyString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return optionalString(object, key);
}

fn optionalUsize(object: std.json.ObjectMap, key: []const u8) ?usize {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |actual| if (actual >= 0) @as(usize, @intCast(actual)) else null,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |actual| actual,
        else => false,
    };
}

fn snapshotNumber(name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, name, "snapshot-")) return null;
    if (!std.mem.endsWith(u8, name, ".json")) return null;
    const number = name["snapshot-".len .. name.len - ".json".len];
    if (number.len == 0) return null;
    return std.fmt.parseInt(usize, number, 10) catch null;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
