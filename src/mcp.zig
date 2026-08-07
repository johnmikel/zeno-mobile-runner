const std = @import("std");
const stdio = @import("stdio.zig");
const cli_output = @import("cli_output.zig");
const errors = @import("errors.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_trace = @import("mcp_trace.zig");
const params_parser = @import("json_rpc_params.zig");
const rpc_trace = @import("json_rpc_trace.zig");
const runner = @import("runner.zig");
const runner_events = @import("runner_events.zig");
const scenario = @import("scenario.zig");
const selector = @import("selector.zig");
const semantic = @import("semantic.zig");
const trace = @import("trace.zig");
const validation = @import("validation.zig");

pub fn serveStdioWithTrace(allocator: std.mem.Allocator, device: anytype, live_trace: ?*trace.TraceWriter) !void {
    var stdin_io: stdio.Input = .{};
    stdin_io.init(.stdin());
    const stdin = stdin_io.reader();

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();

    while (true) {
        const line = stdio.readLineAlloc(stdin, allocator, 16 * 1024 * 1024) catch |err| {
            try mcp_protocol.writeError(stdout, null, -32700, @errorName(err));
            try stdout_io.flush();
            continue;
        };
        const owned_line = line orelse break;
        defer allocator.free(owned_line);
        const trimmed = std.mem.trim(u8, owned_line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try dispatchLine(allocator, device, trimmed, stdout, live_trace);
        try stdout_io.flush();
    }
}

fn dispatchLine(
    allocator: std.mem.Allocator,
    device: anytype,
    line: []const u8,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
        try mcp_protocol.writeError(writer, null, -32700, @errorName(err));
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try mcp_protocol.writeError(writer, null, -32600, "request must be an object");
        return;
    }
    const object = parsed.value.object;
    const id = object.get("id");
    const method_value = object.get("method") orelse {
        try mcp_protocol.writeError(writer, id, -32600, "missing method");
        return;
    };
    if (method_value != .string) {
        try mcp_protocol.writeError(writer, id, -32600, "method must be a string");
        return;
    }

    dispatchMethod(allocator, device, method_value.string, object.get("params"), id, writer, live_trace) catch |err| {
        const classified = errors.classify(err);
        try mcp_protocol.writeErrorWithPublicCode(writer, id, -32000, @errorName(err), classified.code);
        return;
    };
}

fn dispatchMethod(
    allocator: std.mem.Allocator,
    device: anytype,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !void {
    if (std.mem.eql(u8, method, "initialize")) {
        const protocol_version = optionalParamString(params, "protocolVersion") orelse "2024-11-05";
        try mcp_protocol.writeInitializeResult(writer, id, protocol_version);
        return;
    }

    if (std.mem.eql(u8, method, "ping")) {
        try mcp_protocol.writeResultRaw(writer, id, "{}");
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        try mcp_protocol.writeToolListResult(writer, id);
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const tool_name = try requiredParamString(params, "name");
        const arguments = paramField(params, "arguments");
        try callTool(allocator, device, tool_name, arguments, id, writer, live_trace);
        return;
    }

    try mcp_protocol.writeError(writer, id, -32601, "method not found");
}

fn callTool(
    allocator: std.mem.Allocator,
    device: anytype,
    tool_name: []const u8,
    arguments: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !void {
    if (std.mem.eql(u8, tool_name, "snapshot")) {
        var snap = try device.snapshot(live_trace);
        defer snap.deinit(device.allocator);
        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try trace.writeSnapshotJson(&payload.writer, snap);
        try mcp_protocol.writeToolTextResult(writer, id, payload.writer.buffered());
        return;
    }

    if (std.mem.eql(u8, tool_name, "semantic_snapshot")) {
        var snap = try device.snapshot(live_trace);
        defer snap.deinit(device.allocator);
        if (live_trace) |tw| {
            const path = try tw.writeSnapshot(snap);
            defer tw.allocator.free(path);
            try tw.recordEvent("observe.semanticSnapshot", "{\"status\":\"ok\"}");
        }
        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try semantic.writeSemanticSnapshotJson(&payload.writer, snap);
        try mcp_protocol.writeToolTextResult(writer, id, payload.writer.buffered());
        return;
    }

    if (std.mem.eql(u8, tool_name, "run_scenario")) {
        try runScenarioTool(allocator, device, arguments, id, writer, live_trace);
        return;
    }

    if (std.mem.eql(u8, tool_name, "scenario_validate")) {
        if (optionalParamString(arguments, "path")) |path| {
            var result = try validation.validateFile(allocator, path);
            defer result.deinit(allocator);
            var payload: std.Io.Writer.Allocating = .init(allocator);
            defer payload.deinit();
            try cli_output.writeValidationJson(&payload.writer, path, result);
            try mcp_protocol.writeToolTextResult(writer, id, std.mem.trimEnd(u8, payload.writer.buffered(), " \t\r\n"));
            return;
        }
        const inline_json = try inlineScenarioJson(allocator, arguments);
        defer allocator.free(inline_json);
        var result = try validation.validateSlice(allocator, inline_json);
        defer result.deinit(allocator);
        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try cli_output.writeValidationJson(&payload.writer, "<inline>", result);
        try mcp_protocol.writeToolTextResult(writer, id, std.mem.trimEnd(u8, payload.writer.buffered(), " \t\r\n"));
        return;
    }

    if (std.mem.eql(u8, tool_name, "trace_discover")) {
        try mcp_trace.writeDiscoverToolResult(
            allocator,
            writer,
            id,
            live_trace,
            try requiredParamString(arguments, "out"),
            try optionalParamBool(arguments, "includeActions", false),
            try optionalParamBool(arguments, "validate", false),
            try optionalParamBool(arguments, "force", false),
            optionalParamString(arguments, "name"),
            optionalParamString(arguments, "appId"),
        );
        return;
    }

    if (std.mem.eql(u8, tool_name, "trace_explain")) {
        try mcp_trace.writeExplainToolResult(allocator, writer, id, live_trace);
        return;
    }

    if (std.mem.eql(u8, tool_name, "trace_export")) {
        const out_path = try requiredParamString(arguments, "out");
        const omit_screenshots = try optionalParamBool(arguments, "omitScreenshots", false);
        const redact = try optionalParamBool(arguments, "redact", false) or omit_screenshots;
        try mcp_trace.writeExportToolResult(allocator, writer, id, live_trace, out_path, redact, omit_screenshots);
        return;
    }

    try mcp_protocol.writeError(writer, id, -32602, "unknown tool");
}

/// Re-serialize an inline `scenario` argument so the ordinary scenario parser
/// sees exactly the bytes a committed `.zmr/*.json` would contain. Keeping one
/// parser means an inline scenario and a committed one cannot diverge.
fn inlineScenarioJson(allocator: std.mem.Allocator, arguments: ?std.json.Value) ![]u8 {
    const value = paramField(arguments, "scenario") orelse return error.MissingScenarioPath;
    if (value != .object) return error.ScenarioMustBeObject;
    var payload: std.Io.Writer.Allocating = .init(allocator);
    errdefer payload.deinit();
    try std.json.Stringify.value(value, .{}, &payload.writer);
    return try payload.toOwnedSlice();
}

/// The whole point of the collapsed surface: one call runs a scenario end to
/// end and answers with a verdict plus the evidence to check it, instead of an
/// agent replaying twenty single-action calls and keeping a transcript.
fn runScenarioTool(
    allocator: std.mem.Allocator,
    device: anytype,
    arguments: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !void {
    const has_path = optionalParamString(arguments, "path") != null;
    const has_inline = paramField(arguments, "scenario") != null;
    if (has_path and has_inline) return error.ConflictingScenarioSources;

    var script = if (optionalParamString(arguments, "path")) |path|
        try scenario.parseFile(allocator, path)
    else blk: {
        const json = try inlineScenarioJson(allocator, arguments);
        defer allocator.free(json);
        break :blk try scenario.parseSlice(allocator, json);
    };
    defer script.deinit(allocator);

    var failure: ?anyerror = null;
    runner.runScenario(allocator, device, script, live_trace, .{}) catch |err| {
        failure = err;
    };

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"status\":");
    try trace.writeJsonString(&payload.writer, if (failure == null) "passed" else "failed");
    try payload.writer.writeAll(",\"name\":");
    try trace.writeJsonString(&payload.writer, script.name);
    try payload.writer.print(",\"stepCount\":{d}", .{script.steps.len});
    if (failure) |err| {
        const classified = errors.classify(err);
        try payload.writer.writeAll(",\"error\":");
        try trace.writeJsonString(&payload.writer, classified.code);
        try payload.writer.writeAll(",\"message\":");
        try trace.writeJsonString(&payload.writer, classified.message);
    }
    if (live_trace) |tw| {
        try payload.writer.writeAll(",\"traceDir\":");
        try trace.writeJsonString(&payload.writer, tw.root_dir);
        try payload.writer.print(",\"eventCount\":{d}", .{tw.event_count});
    }
    try payload.writer.writeAll(",\"nextCommands\":[");
    if (failure == null) {
        try payload.writer.writeAll("\"trace_export\"");
    } else {
        try payload.writer.writeAll("\"trace_explain\"");
    }
    try payload.writer.writeAll("]}");
    try mcp_protocol.writeToolTextResult(writer, id, payload.writer.buffered());
}

fn writeVisibleToolResult(writer: anytype, id: ?std.json.Value, visible: bool) !void {
    try mcp_protocol.writeToolTextResult(writer, id, if (visible) "{\"visible\":true}" else "{\"visible\":false}");
}

fn writeMatchedIndexToolResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    matched: ?usize,
) !void {
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    const payload_writer = &payload.writer;
    if (matched) |index| {
        try payload_writer.print("{{\"matchedIndex\":{d}}}", .{index});
    } else {
        try payload_writer.writeAll("{\"matchedIndex\":null}");
    }
    try mcp_protocol.writeToolTextResult(writer, id, payload_writer.buffered());
}

fn parseArgumentsSelector(allocator: std.mem.Allocator, arguments: ?std.json.Value) !selector.Selector {
    const selector_value = paramField(arguments, "selector") orelse return error.MissingSelector;
    return try selector.parseFromJson(allocator, selector_value);
}

fn parseMcpLaunchOptions(allocator: std.mem.Allocator, arguments: ?std.json.Value) !scenario.LaunchOptions {
    var options = scenario.LaunchOptions{};
    errdefer options.deinit(allocator);

    if (try params_parser.optionalString(arguments, "appId")) |app_id| {
        options.app_id = try allocator.dupe(u8, app_id);
    }
    options.stop_app = try params_parser.optionalBool(arguments, "stopApp", true);
    options.clear_state = try params_parser.optionalBool(arguments, "clearState", false);
    options.clear_keychain = try params_parser.optionalBool(arguments, "clearKeychain", false);

    const arguments_value = params_parser.field(arguments, "arguments") orelse return options;
    if (arguments_value != .object) return error.StepLaunchArgumentsMustBeObject;

    var launch_arguments = std.ArrayList(scenario.LaunchArgument).empty;
    errdefer {
        for (launch_arguments.items) |argument| argument.deinit(allocator);
        launch_arguments.deinit(allocator);
    }

    var iterator = arguments_value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.*.len == 0) return error.StepLaunchArgumentNameEmpty;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        const value = parseMcpLaunchArgumentValue(allocator, entry.value_ptr.*) catch |err| {
            allocator.free(name);
            return err;
        };
        launch_arguments.append(allocator, .{ .name = name, .value = value }) catch |err| {
            allocator.free(name);
            value.deinit(allocator);
            return err;
        };
    }
    options.arguments = try launch_arguments.toOwnedSlice(allocator);
    return options;
}

fn parseMcpLaunchArgumentValue(allocator: std.mem.Allocator, value: std.json.Value) !scenario.LaunchArgumentValue {
    return switch (value) {
        .string => |actual| .{ .string = try allocator.dupe(u8, actual) },
        .bool => |actual| .{ .boolean = actual },
        .integer => |actual| .{ .integer = actual },
        .float => |actual| .{ .double = actual },
        else => error.StepLaunchArgumentValueUnsupported,
    };
}

fn paramField(params: ?std.json.Value, key: []const u8) ?std.json.Value {
    const value = params orelse return null;
    if (value != .object) return null;
    return value.object.get(key);
}

fn requiredParamString(params: ?std.json.Value, key: []const u8) ![]const u8 {
    const value = paramField(params, key) orelse return error.MissingParam;
    return switch (value) {
        .string => |actual| actual,
        else => error.ParamMustBeString,
    };
}

fn optionalParamString(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = paramField(params, key) orelse return null;
    return switch (value) {
        .string => |actual| actual,
        else => null,
    };
}

fn optionalParamU64(params: ?std.json.Value, key: []const u8, default_value: u64) !u64 {
    const value = paramField(params, key) orelse return default_value;
    return switch (value) {
        .integer => |actual| @as(u64, @intCast(actual)),
        else => error.ParamMustBeInteger,
    };
}

fn optionalParamBool(params: ?std.json.Value, key: []const u8, default_value: bool) !bool {
    const value = paramField(params, key) orelse return default_value;
    return switch (value) {
        .bool => |actual| actual,
        else => error.ParamMustBeBool,
    };
}

test "run_scenario executes an inline scenario and answers with a verdict" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    var device = fake_device.FakeDevice.init(allocator, &.{});
    defer device.deinit();

    // The whole point of the collapsed surface: the agent hands over a
    // scenario, not a sequence of taps, and the scenario it hands over is
    // byte-for-byte what it can commit to .zmr/.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"scenario":{"name":"inline smoke","appId":"com.example.mobiletest","steps":[{"action":"launch"},{"action":"stop"}]}}
    ,
        .{},
    );
    defer parsed.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try callTool(allocator, &device, "run_scenario", parsed.value, .{ .integer = 1 }, &output.writer, null);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "inline smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "trace_export") != null);
    try std.testing.expect(device.launched);
}

test "run_scenario refuses two scenario sources at once" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    var device = fake_device.FakeDevice.init(allocator, &.{});
    defer device.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"path":"a.json","scenario":{"name":"n","steps":[{"action":"launch"}]}}
    ,
        .{},
    );
    defer parsed.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    // Ambiguity here would leave the agent unsure which scenario ran, and the
    // evidence would describe one while the agent reasoned about the other.
    try std.testing.expectError(
        error.ConflictingScenarioSources,
        callTool(allocator, &device, "run_scenario", parsed.value, .{ .integer = 1 }, &output.writer, null),
    );
}
