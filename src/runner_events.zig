const std = @import("std");
const runner_diagnostics = @import("runner_diagnostics.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

pub fn eventString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    try buffer.writer(allocator).writeAll("{\"value\":");
    try trace.writeJsonString(buffer.writer(allocator), value);
    try buffer.writer(allocator).writeAll("}");
    return try buffer.toOwnedSlice(allocator);
}

pub fn recordNativeWait(tw: *trace.TraceWriter, kind: []const u8, wanted: selector.Selector, matched_index: ?usize, timeout_ms: u64) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    try payload.writer(tw.allocator).writeAll("{\"status\":\"ok\",\"strategy\":\"nativeSelector\"");
    if (matched_index) |index| try payload.writer(tw.allocator).print(",\"matchedIndex\":{d}", .{index});
    try payload.writer(tw.allocator).writeAll(",\"selector\":");
    try trace.writeSelectorJson(payload.writer(tw.allocator), wanted);
    try payload.writer(tw.allocator).print(",\"timeoutMs\":{d}}}", .{timeout_ms});
    try tw.recordEvent(kind, payload.items);
}

pub fn recordNativeWaitTimeout(tw: *trace.TraceWriter, kind: []const u8, selectors: []const selector.Selector, timeout_ms: u64) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    try payload.writer(tw.allocator).print("{{\"status\":\"timeout\",\"strategy\":\"nativeSelector\",\"timeoutMs\":{d},\"selectors\":[", .{timeout_ms});
    for (selectors, 0..) |wanted, index| {
        if (index > 0) try payload.writer(tw.allocator).writeAll(",");
        try trace.writeSelectorJson(payload.writer(tw.allocator), wanted);
    }
    try payload.writer(tw.allocator).writeAll("]}");
    try tw.recordEvent(kind, payload.items);
}

pub fn recordNativeWaitTimeoutWithDiagnostics(device: anytype, tw: *trace.TraceWriter, kind: []const u8, selectors: []const selector.Selector, timeout_ms: u64) !void {
    var snap = device.snapshot(tw) catch {
        try recordNativeWaitTimeout(tw, kind, selectors, timeout_ms);
        return;
    };
    defer snap.deinit(device.allocator);
    try recordDiagnosticWithStrategyAndTimeout(tw, kind, "timeout", "nativeSelector", selectors, snap, timeout_ms);
}

pub fn recordSelectorArrayStatus(tw: *trace.TraceWriter, kind: []const u8, status: []const u8, selectors: []const selector.Selector, timeout_ms: u64) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const out = payload.writer(tw.allocator);
    try out.writeAll("{\"status\":");
    try trace.writeJsonString(out, status);
    try out.writeAll(",\"selectors\":[");
    for (selectors, 0..) |wanted, index| {
        if (index > 0) try out.writeAll(",");
        try trace.writeSelectorJson(out, wanted);
    }
    try out.print("],\"timeoutMs\":{d}}}", .{timeout_ms});
    try tw.recordEvent(kind, payload.items);
}

pub fn recordSelectorEvent(tw: *trace.TraceWriter, kind: []const u8, wanted: selector.Selector) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    try payload.writer(tw.allocator).writeAll("{\"selector\":");
    try trace.writeSelectorJson(payload.writer(tw.allocator), wanted);
    try payload.writer(tw.allocator).writeAll("}");
    try tw.recordEvent(kind, payload.items);
}

pub fn recordActionStatus(tw: *trace.TraceWriter, kind: []const u8, status: []const u8, err: ?anyerror, url: ?[]const u8) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const out = payload.writer(tw.allocator);
    try out.writeAll("{\"status\":");
    try trace.writeJsonString(out, status);
    if (err) |actual| {
        try out.writeAll(",\"error\":");
        try trace.writeJsonString(out, @errorName(actual));
    }
    if (url) |value| {
        try out.writeAll(",\"url\":");
        try trace.writeJsonString(out, value);
    }
    try out.writeAll("}");
    try tw.recordEvent(kind, payload.items);
}

pub fn recordSwipe(tw: *trace.TraceWriter, x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
    const payload = try std.fmt.allocPrint(
        tw.allocator,
        "{{\"status\":\"ok\",\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"durationMs\":{d}}}",
        .{ x1, y1, x2, y2, duration_ms },
    );
    defer tw.allocator.free(payload);
    try tw.recordEvent("ui.swipe", payload);
}

pub fn recordTraceDiscover(tw: *trace.TraceWriter, status: []const u8, out_path: []const u8, include_actions: bool, validated: bool) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const out = payload.writer(tw.allocator);
    try out.writeAll("{\"status\":");
    try trace.writeJsonString(out, status);
    try out.writeAll(",\"out\":");
    try trace.writeJsonString(out, out_path);
    try out.print(",\"includeActions\":{},\"validated\":{}}}", .{ include_actions, validated });
    try tw.recordEvent("trace.discover", payload.items);
}

pub fn recordTraceExplore(tw: *trace.TraceWriter, status: []const u8, out_path: []const u8, goal: []const u8, include_actions: bool, validated: bool) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const out = payload.writer(tw.allocator);
    try out.writeAll("{\"status\":");
    try trace.writeJsonString(out, status);
    try out.writeAll(",\"out\":");
    try trace.writeJsonString(out, out_path);
    try out.writeAll(",\"goal\":");
    try trace.writeJsonString(out, goal);
    try out.print(",\"includeActions\":{},\"validated\":{}}}", .{ include_actions, validated });
    try tw.recordEvent("trace.explore", payload.items);
}

pub fn recordStepError(tw: *trace.TraceWriter, index: usize, err: anyerror) !void {
    const payload = try std.fmt.allocPrint(
        tw.allocator,
        "{{\"index\":{d},\"error\":\"{s}\"}}",
        .{ index, @errorName(err) },
    );
    defer tw.allocator.free(payload);
    try tw.recordEvent("step.error", payload);
}

pub fn recordScenarioEnd(
    tw: *trace.TraceWriter,
    name: []const u8,
    status: []const u8,
    failed_index: ?usize,
    err: ?anyerror,
) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const writer = payload.writer(tw.allocator);
    try writer.writeAll("{\"value\":");
    try trace.writeJsonString(writer, name);
    try writer.writeAll(",\"status\":");
    try trace.writeJsonString(writer, status);
    if (failed_index) |index| {
        try writer.print(",\"failedStepIndex\":{d}", .{index});
    }
    if (err) |actual| {
        try writer.writeAll(",\"error\":");
        try trace.writeJsonString(writer, @errorName(actual));
    }
    try writer.writeAll("}");
    try tw.recordEvent("scenario.end", payload.items);
}

pub fn recordSelectorMiss(
    tw: *trace.TraceWriter,
    kind: []const u8,
    wanted: selector.Selector,
    snap: types.ObservationSnapshot,
) !void {
    const selectors = [_]selector.Selector{wanted};
    try recordDiagnostic(tw, kind, "not_found", selectors[0..], snap);
}

pub fn recordWaitTimeout(
    tw: *trace.TraceWriter,
    kind: []const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
) !void {
    try recordDiagnostic(tw, kind, "timeout", selectors, snap);
}

pub fn recordObservationRetry(tw: *trace.TraceWriter, kind: []const u8, err: anyerror) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const writer = payload.writer(tw.allocator);
    try writer.writeAll("{\"status\":\"retry\",\"kind\":");
    try trace.writeJsonString(writer, kind);
    try writer.writeAll(",\"error\":");
    try trace.writeJsonString(writer, @errorName(err));
    try writer.writeAll("}");
    try tw.recordEvent("observe.retry", payload.items);
}

pub fn recordDiagnostic(
    tw: *trace.TraceWriter,
    kind: []const u8,
    status: []const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
) !void {
    try recordDiagnosticWithStrategy(tw, kind, status, null, selectors, snap);
}

pub fn recordDiagnosticWithStrategy(
    tw: *trace.TraceWriter,
    kind: []const u8,
    status: []const u8,
    strategy: ?[]const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
) !void {
    try runner_diagnostics.record(tw, kind, status, strategy, selectors, snap);
}

pub fn recordDiagnosticWithStrategyAndTimeout(
    tw: *trace.TraceWriter,
    kind: []const u8,
    status: []const u8,
    strategy: ?[]const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
    timeout_ms: u64,
) !void {
    try runner_diagnostics.recordWithOptions(tw, kind, status, strategy, selectors, snap, .{ .timeout_ms = timeout_ms });
}

pub fn writeSelectorDiagnosticJson(
    writer: anytype,
    status: []const u8,
    strategy: ?[]const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
) !void {
    try runner_diagnostics.writeSelectorDiagnosticJson(writer, status, strategy, selectors, snap);
}
