const std = @import("std");
const cli_output = @import("cli_output.zig");
const errors = @import("errors.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_trace = @import("mcp_trace.zig");
const params_parser = @import("json_rpc_params.zig");
const rpc_trace = @import("json_rpc_trace.zig");
const runner = @import("runner.zig");
const runner_events = @import("runner_events.zig");
const selector = @import("selector.zig");
const semantic = @import("semantic.zig");
const trace = @import("trace.zig");
const validation = @import("validation.zig");

pub fn serveStdioWithTrace(allocator: std.mem.Allocator, device: anytype, live_trace: ?*trace.TraceWriter) !void {
    var stdin = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    while (true) {
        const line = stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 16 * 1024 * 1024) catch |err| {
            try mcp_protocol.writeError(stdout, null, -32700, @errorName(err));
            continue;
        };
        const owned_line = line orelse break;
        defer allocator.free(owned_line);
        const trimmed = std.mem.trim(u8, owned_line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try dispatchLine(allocator, device, trimmed, stdout, live_trace);
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
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try trace.writeSnapshotJson(payload.writer(allocator), snap);
        try mcp_protocol.writeToolTextResult(writer, id, payload.items);
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
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try semantic.writeSemanticSnapshotJson(payload.writer(allocator), snap);
        try mcp_protocol.writeToolTextResult(writer, id, payload.items);
        return;
    }

    if (std.mem.eql(u8, tool_name, "install_app")) {
        const path = try requiredParamString(arguments, "path");
        try device.install(path);
        if (live_trace) |tw| try rpc_trace.recordSimplePayload(tw, "app.install", "path", path);
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "launch_app")) {
        try device.launch();
        if (live_trace) |tw| try tw.recordEvent("app.launch", "{\"status\":\"ok\"}");
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "stop_app")) {
        try device.stop();
        if (live_trace) |tw| try tw.recordEvent("app.stop", "{\"status\":\"ok\"}");
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "clear_state")) {
        try device.clearState();
        if (live_trace) |tw| try tw.recordEvent("app.clearState", "{\"status\":\"ok\"}");
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "tap")) {
        const wanted = try parseArgumentsSelector(allocator, arguments);
        defer wanted.deinit(allocator);
        try runner.tapSelector(device, wanted, live_trace, .{});
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "type")) {
        const text = try requiredParamString(arguments, "text");
        if (paramField(arguments, "selector")) |selector_value| {
            const wanted = try selector.parseFromJson(allocator, selector_value);
            defer wanted.deinit(allocator);
            try runner.typeTextSelector(device, wanted, text, live_trace, .{});
        } else {
            try device.typeText(text);
            if (live_trace) |tw| try rpc_trace.recordSimplePayload(tw, "ui.type", "text", text);
        }
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "swipe")) {
        const x1 = try params_parser.requiredI32(arguments, "x1");
        const y1 = try params_parser.requiredI32(arguments, "y1");
        const x2 = try params_parser.requiredI32(arguments, "x2");
        const y2 = try params_parser.requiredI32(arguments, "y2");
        const duration_ms = @as(u32, @intCast(try optionalParamU64(arguments, "durationMs", 300)));
        try device.swipe(x1, y1, x2, y2, duration_ms);
        if (live_trace) |tw| try runner_events.recordSwipe(tw, x1, y1, x2, y2, duration_ms);
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "hide_keyboard")) {
        try device.hideKeyboard();
        if (live_trace) |tw| try tw.recordEvent("ui.hideKeyboard", "{\"status\":\"ok\"}");
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "erase_text")) {
        const max_chars = @as(u32, @intCast(try optionalParamU64(arguments, "maxChars", 80)));
        if (paramField(arguments, "selector")) |selector_value| {
            const wanted = try selector.parseFromJson(allocator, selector_value);
            defer wanted.deinit(allocator);
            try runner.eraseTextSelector(device, wanted, max_chars, live_trace, .{});
        } else {
            try device.eraseText(max_chars);
            if (live_trace) |tw| {
                const payload = try std.fmt.allocPrint(tw.allocator, "{{\"maxChars\":{d}}}", .{max_chars});
                defer tw.allocator.free(payload);
                try tw.recordEvent("ui.eraseText", payload);
            }
        }
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "press_back")) {
        try device.pressBack();
        if (live_trace) |tw| try tw.recordEvent("ui.pressBack", "{\"status\":\"ok\"}");
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "open_link")) {
        const url = try requiredParamString(arguments, "url");
        try device.openLink(url);
        if (live_trace) |tw| try runner_events.recordActionStatus(tw, "app.openLink", "ok", null, url);
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "wait_visible")) {
        const wanted = try parseArgumentsSelector(allocator, arguments);
        defer wanted.deinit(allocator);
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 5000);
        const visible = try runner.waitUntilVisible(device, wanted, timeout_ms, live_trace, .{});
        try writeVisibleToolResult(writer, id, visible);
        return;
    }

    if (std.mem.eql(u8, tool_name, "wait_not_visible")) {
        const wanted = try parseArgumentsSelector(allocator, arguments);
        defer wanted.deinit(allocator);
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 5000);
        const gone = try runner.waitUntilNotVisible(device, wanted, timeout_ms, live_trace, .{});
        try writeVisibleToolResult(writer, id, !gone);
        return;
    }

    if (std.mem.eql(u8, tool_name, "wait_any")) {
        const selectors = try params_parser.selectors(allocator, arguments);
        defer {
            for (selectors) |wanted| wanted.deinit(allocator);
            allocator.free(selectors);
        }
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 5000);
        const matched = try runner.waitUntilAnyVisible(device, selectors, timeout_ms, live_trace, .{});
        try writeMatchedIndexToolResult(allocator, writer, id, matched);
        return;
    }

    if (std.mem.eql(u8, tool_name, "scroll_until_visible")) {
        const wanted = try parseArgumentsSelector(allocator, arguments);
        defer wanted.deinit(allocator);
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 5000);
        const visible = try runner.scrollUntilVisible(
            device,
            wanted,
            timeout_ms,
            try params_parser.optionalDirection(arguments, "direction", .down),
            live_trace,
            .{},
        );
        try writeVisibleToolResult(writer, id, visible);
        return;
    }

    if (std.mem.eql(u8, tool_name, "assert_visible")) {
        const wanted = try parseArgumentsSelector(allocator, arguments);
        defer wanted.deinit(allocator);
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 5000);
        if (!try runner.assertVisible(device, wanted, timeout_ms, live_trace, .{})) return error.AssertionFailed;
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "assert_not_visible")) {
        const wanted = try parseArgumentsSelector(allocator, arguments);
        defer wanted.deinit(allocator);
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 5000);
        if (!try runner.assertNotVisible(device, wanted, timeout_ms, live_trace, .{})) return error.AssertionFailed;
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "assert_healthy")) {
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 0);
        if (!try runner.assertHealthy(device, timeout_ms, live_trace, .{})) return error.AssertionFailed;
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "scenario_validate")) {
        const path = try requiredParamString(arguments, "path");
        var result = try validation.validateFile(allocator, path);
        defer result.deinit(allocator);
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try cli_output.writeValidationJson(payload.writer(allocator), path, result);
        try mcp_protocol.writeToolTextResult(writer, id, std.mem.trimRight(u8, payload.items, " \t\r\n"));
        return;
    }

    if (std.mem.eql(u8, tool_name, "trace_events")) {
        try mcp_trace.writeEventsToolResult(allocator, writer, id, live_trace, try optionalParamU64(arguments, "afterSeq", 0), @min(try optionalParamU64(arguments, "limit", 100), 1000));
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

fn writeVisibleToolResult(writer: anytype, id: ?std.json.Value, visible: bool) !void {
    try mcp_protocol.writeToolTextResult(writer, id, if (visible) "{\"visible\":true}" else "{\"visible\":false}");
}

fn writeMatchedIndexToolResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    matched: ?usize,
) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    const payload_writer = payload.writer(allocator);
    if (matched) |index| {
        try payload_writer.print("{{\"matchedIndex\":{d}}}", .{index});
    } else {
        try payload_writer.writeAll("{\"matchedIndex\":null}");
    }
    try mcp_protocol.writeToolTextResult(writer, id, payload.items);
}

fn parseArgumentsSelector(allocator: std.mem.Allocator, arguments: ?std.json.Value) !selector.Selector {
    const selector_value = paramField(arguments, "selector") orelse return error.MissingSelector;
    return try selector.parseFromJson(allocator, selector_value);
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
