const std = @import("std");
const errors = @import("errors.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_trace = @import("mcp_trace.zig");
const runner = @import("runner.zig");
const selector = @import("selector.zig");
const semantic = @import("semantic.zig");
const trace = @import("trace.zig");

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
        }
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "press_back")) {
        try device.pressBack();
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "open_link")) {
        try device.openLink(try requiredParamString(arguments, "url"));
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, tool_name, "wait_visible")) {
        const wanted = try parseArgumentsSelector(allocator, arguments);
        defer wanted.deinit(allocator);
        const timeout_ms = try optionalParamU64(arguments, "timeoutMs", 5000);
        const visible = try runner.waitUntilVisible(device, wanted, timeout_ms, live_trace, .{});
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try mcp_protocol.writeId(writer, id);
        try writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"visible\\\":");
        try writer.writeAll(if (visible) "true" else "false");
        try writer.writeAll("}\"}]}}\n");
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

    if (std.mem.eql(u8, tool_name, "trace_export")) {
        const out_path = try requiredParamString(arguments, "out");
        const omit_screenshots = try optionalParamBool(arguments, "omitScreenshots", false);
        const redact = try optionalParamBool(arguments, "redact", false) or omit_screenshots;
        try mcp_trace.writeExportToolResult(allocator, writer, id, live_trace, out_path, redact, omit_screenshots);
        return;
    }

    try mcp_protocol.writeError(writer, id, -32602, "unknown tool");
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
