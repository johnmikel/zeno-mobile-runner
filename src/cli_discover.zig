const std = @import("std");

const cli_draft = @import("cli_draft.zig");
const cli_output = @import("cli_output.zig");
const trace = @import("trace.zig");
const validation = @import("validation.zig");
const version = @import("version.zig");

pub const ParsedArgs = struct {
    from_trace: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    include_actions: bool = false,
    validate: bool = false,
    force: bool = false,
    json: bool = false,
};

pub const DiscoverSummary = struct {
    ok: bool,
    draft: cli_draft.DraftSummary,
    validated: bool,
};

pub const JsonOptions = struct {
    mode: []const u8 = "discover",
    goal: ?[]const u8 = null,
    autonomous: ?bool = null,
    review_required: ?bool = null,
    guardrails: []const []const u8 = &.{},
};

pub const OwnedDiscover = struct {
    draft: cli_draft.OwnedDraft,
    validation: ?validation.Result = null,
    summary: DiscoverSummary,

    pub fn deinit(self: *OwnedDiscover, allocator: std.mem.Allocator) void {
        if (self.validation) |result| result.deinit(allocator);
        self.draft.deinit(allocator);
    }
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
        } else if (std.mem.eql(u8, arg, "--validate")) {
            parsed.validate = true;
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
    var discovered = try discoverFromTrace(allocator, parsed);
    defer discovered.deinit(allocator);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (parsed.json) {
        try writeJson(stdout, discovered.summary, discovered.validation);
    } else {
        try stdout.print("wrote {s}\n", .{discovered.summary.draft.out_path});
        if (discovered.validation) |result| {
            if (result.ok) {
                try stdout.print("validated {s}\n", .{discovered.summary.draft.out_path});
            } else {
                try stdout.print("validation failed {s}\n", .{discovered.summary.draft.out_path});
            }
        }
        try stdout.writeAll("next: zmr validate --json ");
        try cli_output.writeShellArg(stdout, discovered.summary.draft.out_path);
        try stdout.writeAll("\n");
    }
    if (!discovered.summary.ok) std.process.exit(1);
}

pub fn discoverFromTrace(allocator: std.mem.Allocator, parsed: ParsedArgs) !OwnedDiscover {
    var draft = try cli_draft.draftFromTrace(allocator, .{
        .from_trace = parsed.from_trace,
        .out_path = parsed.out_path,
        .name = parsed.name,
        .app_id = parsed.app_id,
        .include_actions = parsed.include_actions,
        .force = parsed.force,
        .json = parsed.json,
    });
    errdefer draft.deinit(allocator);

    var validation_result: ?validation.Result = null;
    errdefer if (validation_result) |result| result.deinit(allocator);
    if (parsed.validate) {
        validation_result = try validation.validateFile(allocator, draft.summary.out_path);
    }

    const ok = draft.summary.ok and (validation_result == null or validation_result.?.ok);
    return .{
        .draft = draft,
        .validation = validation_result,
        .summary = .{
            .ok = ok,
            .draft = draft.summary,
            .validated = parsed.validate,
        },
    };
}

pub fn writeJson(writer: anytype, summary: DiscoverSummary, validation_result: ?validation.Result) !void {
    try writeJsonWithOptions(writer, summary, validation_result, .{});
}

pub fn writeJsonWithOptions(writer: anytype, summary: DiscoverSummary, validation_result: ?validation.Result, options: JsonOptions) !void {
    const draft = summary.draft;
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (summary.ok) "true" else "false");
    try writer.writeAll(",\"mode\":");
    try trace.writeJsonString(writer, options.mode);
    try writer.writeAll(",\"schemaVersion\":1");
    try writer.writeAll(",\"runnerVersion\":");
    try trace.writeJsonString(writer, version.runner_version);
    try writer.writeAll(",\"protocolVersion\":");
    try trace.writeJsonString(writer, version.protocol_version);
    if (options.goal) |goal| {
        try writer.writeAll(",\"goal\":");
        try trace.writeJsonString(writer, goal);
    }
    if (options.autonomous) |autonomous| {
        try writer.writeAll(",\"autonomous\":");
        try writer.writeAll(if (autonomous) "true" else "false");
    }
    if (options.review_required) |review_required| {
        try writer.writeAll(",\"reviewRequired\":");
        try writer.writeAll(if (review_required) "true" else "false");
    }
    if (options.guardrails.len > 0) {
        try writer.writeAll(",\"guardrails\":[");
        for (options.guardrails, 0..) |guardrail, index| {
            if (index > 0) try writer.writeAll(",");
            try trace.writeJsonString(writer, guardrail);
        }
        try writer.writeAll("]");
    }
    try writer.writeAll(",\"out\":");
    try trace.writeJsonString(writer, draft.out_path);
    try writer.writeAll(",\"traceDir\":");
    try trace.writeJsonString(writer, draft.trace_dir);
    try writer.writeAll(",\"sourceSnapshot\":");
    try trace.writeJsonString(writer, draft.source_snapshot);
    try writer.writeAll(",\"name\":");
    try trace.writeJsonString(writer, draft.name);
    try writer.writeAll(",\"appId\":");
    if (draft.app_id) |actual| {
        try trace.writeJsonString(writer, actual);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"selectorCount\":{d},\"stepCount\":{d}", .{ draft.selector_count, draft.step_count });
    try cli_draft.writeReplayJson(writer, draft.replay);
    try writer.writeAll(",\"warnings\":[");
    for (draft.warnings, 0..) |warning, index| {
        if (index > 0) try writer.writeAll(",");
        try trace.writeJsonString(writer, warning);
    }
    try writer.writeAll("],\"validated\":");
    try writer.writeAll(if (summary.validated) "true" else "false");
    try writer.writeAll(",\"validation\":");
    if (validation_result) |result| {
        try writeValidationObject(writer, draft.out_path, result);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"nextCommands\":[\"zmr validate --json ");
    try cli_output.writeShellArgJsonContent(writer, draft.out_path);
    try writer.writeAll("\",\"zmr run ");
    try cli_output.writeShellArgJsonContent(writer, draft.out_path);
    try writer.writeAll(" --json --trace-dir ");
    try cli_output.writeShellArgJsonContent(writer, draft.trace_dir);
    try writer.writeAll("\"]}\n");
}

fn writeValidationObject(writer: anytype, path: []const u8, result: validation.Result) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (result.ok) "true" else "false");
    try writer.writeAll(",\"path\":");
    try trace.writeJsonString(writer, path);
    if (result.ok) {
        try writer.writeAll(",\"name\":");
        try trace.writeJsonString(writer, result.name.?);
        try writer.writeAll(",\"appId\":");
        if (result.app_id) |app_id| {
            try trace.writeJsonString(writer, app_id);
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"stepCount\":{d}", .{result.step_count});
    } else {
        try writer.writeAll(",\"errorCode\":");
        try trace.writeJsonString(writer, result.error_code.?);
        try writer.writeAll(",\"message\":");
        try trace.writeJsonString(writer, result.message.?);
        if (result.path) |field_path| {
            try writer.writeAll(",\"fieldPath\":");
            try trace.writeJsonString(writer, field_path);
        }
        if (result.line) |line| try writer.print(",\"line\":{d}", .{line});
        if (result.column) |column| try writer.print(",\"column\":{d}", .{column});
    }
    try writer.writeAll("}");
}
