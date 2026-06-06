const std = @import("std");
const bundle = @import("bundle.zig");
const cli_output = @import("cli_output.zig");
const observation = @import("json_rpc_observation.zig");
const params_parser = @import("json_rpc_params.zig");
const protocol = @import("json_rpc_protocol.zig");
const rpc_trace = @import("json_rpc_trace.zig");
const runner = @import("runner.zig");
const runner_events = @import("runner_events.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const validation = @import("validation.zig");

pub fn dispatchMethod(
    allocator: std.mem.Allocator,
    device: anytype,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !void {
    if (try dispatchCoreMethod(allocator, device, method, id, writer)) return;
    if (try dispatchAppMethod(device, method, params, id, writer, live_trace)) return;
    if (try dispatchObserveMethod(device, method, id, writer, live_trace)) return;
    if (try dispatchUiMethod(allocator, device, method, params, id, writer, live_trace)) return;
    if (try dispatchWaitMethod(allocator, device, method, params, id, writer, live_trace)) return;
    if (try dispatchAssertMethod(allocator, device, method, params, id, writer, live_trace)) return;
    if (try dispatchScenarioMethod(allocator, method, params, id, writer)) return;
    if (try dispatchTraceMethod(allocator, method, params, id, writer, live_trace)) return;

    try protocol.writeError(writer, id, -32601, "method not found");
}

fn dispatchCoreMethod(
    allocator: std.mem.Allocator,
    device: anytype,
    method: []const u8,
    id: ?std.json.Value,
    writer: anytype,
) !bool {
    if (std.mem.eql(u8, method, "runner.capabilities")) {
        try protocol.writeCapabilitiesResult(writer, id);
        return true;
    }
    if (std.mem.eql(u8, method, "device.list")) {
        const devices = try device.listDevices();
        defer {
            for (devices) |info| info.deinit(allocator);
            allocator.free(devices);
        }
        try protocol.writeDevicesResult(writer, id, devices);
        return true;
    }
    if (std.mem.eql(u8, method, "session.create")) {
        try protocol.writeResultRaw(writer, id, "{\"sessionId\":\"default\"}");
        return true;
    }
    if (std.mem.eql(u8, method, "session.close")) {
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    return false;
}

fn dispatchAppMethod(
    device: anytype,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !bool {
    if (std.mem.eql(u8, method, "app.install")) {
        const path = try params_parser.requiredString(params, "path");
        try device.install(path);
        if (live_trace) |tw| try rpc_trace.recordSimplePayload(tw, "app.install", "path", path);
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "app.launch")) {
        try device.launch();
        if (live_trace) |tw| try tw.recordEvent("app.launch", "{\"status\":\"ok\"}");
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "app.stop")) {
        try device.stop();
        if (live_trace) |tw| try tw.recordEvent("app.stop", "{\"status\":\"ok\"}");
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "app.clearState")) {
        try device.clearState();
        if (live_trace) |tw| try tw.recordEvent("app.clearState", "{\"status\":\"ok\"}");
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "app.openLink")) {
        const url = try params_parser.requiredString(params, "url");
        try device.openLink(url);
        if (live_trace) |tw| try recordAppOpenLink(tw, url);
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    return false;
}

fn recordAppOpenLink(tw: *trace.TraceWriter, url: []const u8) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const writer = payload.writer(tw.allocator);
    try writer.writeAll("{\"status\":\"ok\",\"url\":");
    try trace.writeJsonString(writer, url);
    try writer.writeAll("}");
    try tw.recordEvent("app.openLink", payload.items);
}

fn dispatchObserveMethod(
    device: anytype,
    method: []const u8,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !bool {
    if (std.mem.eql(u8, method, "observe.snapshot")) {
        var snap = try device.snapshot(live_trace);
        defer snap.deinit(device.allocator);
        if (live_trace) |tw| try observation.recordArtifact(tw, "observe.snapshot", snap);
        try observation.writeResult(writer, id, snap, .raw);
        return true;
    }
    if (std.mem.eql(u8, method, "observe.semanticSnapshot")) {
        var snap = try device.snapshot(live_trace);
        defer snap.deinit(device.allocator);
        if (live_trace) |tw| try observation.recordArtifact(tw, "observe.semanticSnapshot", snap);
        try observation.writeResult(writer, id, snap, .semantic);
        return true;
    }
    return false;
}

fn dispatchUiMethod(
    allocator: std.mem.Allocator,
    device: anytype,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !bool {
    if (std.mem.eql(u8, method, "ui.tap")) {
        const wanted = try params_parser.selectorParam(allocator, params);
        defer wanted.deinit(allocator);
        try runner.tapSelector(device, wanted, live_trace, .{});
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "ui.type")) {
        const text = try params_parser.requiredString(params, "text");
        if (params_parser.field(params, "selector")) |selector_value| {
            const wanted = try selector.parseFromJson(allocator, selector_value);
            defer wanted.deinit(allocator);
            try runner.typeTextSelector(device, wanted, text, live_trace, .{});
            try protocol.writeResultRaw(writer, id, "true");
            return true;
        }
        try device.typeText(text);
        if (live_trace) |tw| try rpc_trace.recordSimplePayload(tw, "ui.type", "text", text);
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "ui.eraseText")) {
        const max_chars = @as(u32, @intCast(try params_parser.optionalU64(params, "maxChars", 80)));
        if (params_parser.field(params, "selector")) |selector_value| {
            const wanted = try selector.parseFromJson(allocator, selector_value);
            defer wanted.deinit(allocator);
            try runner.eraseTextSelector(device, wanted, max_chars, live_trace, .{});
            try protocol.writeResultRaw(writer, id, "true");
            return true;
        }
        try device.eraseText(max_chars);
        if (live_trace) |tw| {
            const payload = try std.fmt.allocPrint(tw.allocator, "{{\"maxChars\":{d}}}", .{max_chars});
            defer tw.allocator.free(payload);
            try tw.recordEvent("ui.eraseText", payload);
        }
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "ui.hideKeyboard")) {
        try device.hideKeyboard();
        if (live_trace) |tw| try tw.recordEvent("ui.hideKeyboard", "{\"status\":\"ok\"}");
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "ui.swipe")) {
        const x1 = try params_parser.requiredI32(params, "x1");
        const y1 = try params_parser.requiredI32(params, "y1");
        const x2 = try params_parser.requiredI32(params, "x2");
        const y2 = try params_parser.requiredI32(params, "y2");
        const duration_ms = @as(u32, @intCast(try params_parser.optionalU64(params, "durationMs", 300)));
        try device.swipe(x1, y1, x2, y2, duration_ms);
        if (live_trace) |tw| try runner_events.recordSwipe(tw, x1, y1, x2, y2, duration_ms);
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "ui.pressBack")) {
        try device.pressBack();
        if (live_trace) |tw| try tw.recordEvent("ui.pressBack", "{\"status\":\"ok\"}");
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "ui.scrollUntilVisible")) {
        const wanted = try params_parser.selectorParam(allocator, params);
        defer wanted.deinit(allocator);
        const ok = try runner.scrollUntilVisible(
            device,
            wanted,
            try params_parser.optionalU64(params, "timeoutMs", 5000),
            try params_parser.optionalDirection(params, "direction", .down),
            live_trace,
            .{},
        );
        try protocol.writeResultRaw(writer, id, if (ok) "true" else "false");
        return true;
    }
    return false;
}

fn dispatchWaitMethod(
    allocator: std.mem.Allocator,
    device: anytype,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !bool {
    if (std.mem.eql(u8, method, "wait.until")) {
        const visible_value = params_parser.field(params, "visible") orelse return error.WaitUntilNeedsVisibleSelector;
        const wanted = try selector.parseFromJson(allocator, visible_value);
        defer wanted.deinit(allocator);
        const timeout_ms = try params_parser.optionalU64(params, "timeoutMs", 5000);
        const ok = try runner.waitUntilVisible(device, wanted, timeout_ms, live_trace, .{});
        try protocol.writeResultRaw(writer, id, if (ok) "true" else "false");
        return true;
    }
    if (std.mem.eql(u8, method, "wait.any")) {
        const selectors = try params_parser.selectors(allocator, params);
        defer {
            for (selectors) |wanted| wanted.deinit(allocator);
            allocator.free(selectors);
        }
        const matched = try runner.waitUntilAnyVisible(device, selectors, try params_parser.optionalU64(params, "timeoutMs", 5000), live_trace, .{});
        if (matched) |index| {
            try protocol.writeMatchedIndexResult(writer, id, index);
        } else {
            try protocol.writeResultRaw(writer, id, "false");
        }
        return true;
    }
    if (std.mem.eql(u8, method, "wait.gone")) {
        const wanted = try params_parser.selectorParam(allocator, params);
        defer wanted.deinit(allocator);
        const ok = try runner.waitUntilNotVisible(device, wanted, try params_parser.optionalU64(params, "timeoutMs", 5000), live_trace, .{});
        try protocol.writeResultRaw(writer, id, if (ok) "true" else "false");
        return true;
    }
    return false;
}

fn dispatchAssertMethod(
    allocator: std.mem.Allocator,
    device: anytype,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !bool {
    if (std.mem.eql(u8, method, "assert.visible")) {
        const wanted = try params_parser.selectorParam(allocator, params);
        defer wanted.deinit(allocator);
        if (!try runner.waitUntilVisible(device, wanted, try params_parser.optionalU64(params, "timeoutMs", 5000), live_trace, .{})) return error.AssertionFailed;
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "assert.notVisible")) {
        const wanted = try params_parser.selectorParam(allocator, params);
        defer wanted.deinit(allocator);
        if (!try runner.waitUntilNotVisible(device, wanted, try params_parser.optionalU64(params, "timeoutMs", 5000), live_trace, .{})) return error.AssertionFailed;
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    if (std.mem.eql(u8, method, "assert.healthy")) {
        if (!try runner.assertHealthy(device, try params_parser.optionalU64(params, "timeoutMs", 0), live_trace, .{})) return error.AssertionFailed;
        try protocol.writeResultRaw(writer, id, "true");
        return true;
    }
    return false;
}

fn dispatchScenarioMethod(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
) !bool {
    if (std.mem.eql(u8, method, "scenario.validate")) {
        const path = try params_parser.requiredString(params, "path");
        var result = try validation.validateFile(allocator, path);
        defer result.deinit(allocator);
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        try cli_output.writeValidationJson(payload.writer(allocator), path, result);
        try protocol.writeResultRaw(writer, id, std.mem.trimRight(u8, payload.items, " \t\r\n"));
        return true;
    }
    return false;
}

fn dispatchTraceMethod(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !bool {
    if (std.mem.eql(u8, method, "trace.events")) {
        const after_seq = try params_parser.optionalU64(params, "afterSeq", 0);
        const limit = @min(try params_parser.optionalU64(params, "limit", 100), 1000);
        try rpc_trace.writeEventsResult(allocator, writer, id, live_trace, after_seq, limit);
        return true;
    }
    if (std.mem.eql(u8, method, "trace.discover")) {
        try rpc_trace.writeDiscoverResult(
            allocator,
            writer,
            id,
            live_trace,
            try params_parser.requiredString(params, "out"),
            try params_parser.optionalBool(params, "includeActions", false),
            try params_parser.optionalBool(params, "validate", false),
            try params_parser.optionalBool(params, "force", false),
            try params_parser.optionalString(params, "name"),
            try params_parser.optionalString(params, "appId"),
        );
        return true;
    }
    if (std.mem.eql(u8, method, "trace.export")) {
        const tw = live_trace orelse {
            try protocol.writeTraceDisabledResult(writer, id);
            return true;
        };
        const out_path = try params_parser.requiredString(params, "out");
        const redact = try params_parser.optionalBool(params, "redact", false);
        const omit_screenshots = try params_parser.optionalBool(params, "omitScreenshots", false);
        const effective_redact = redact or omit_screenshots;
        try tw.recordEvent("trace.export", "{\"status\":\"started\"}");
        try tw.flushManifest();
        try bundle.exportTraceBundleWithOptions(allocator, tw.root_dir, out_path, .{
            .redact = effective_redact,
            .omit_screenshots = omit_screenshots,
        });
        try protocol.writeTraceExportResult(writer, id, tw.root_dir, out_path, effective_redact, omit_screenshots);
        return true;
    }
    return false;
}
