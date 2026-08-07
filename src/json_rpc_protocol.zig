const std = @import("std");
const device_registry = @import("device_registry.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");
const version = @import("version.zig");

pub const capabilities_json =
    "{\"name\":\"zmr\",\"version\":\"" ++ version.runner_version ++
    "\",\"protocolVersion\":\"" ++ version.protocol_version ++
    "\",\"protocol\":{\"version\":\"" ++ version.protocol_version ++
    "\",\"minimumCompatibleVersion\":\"" ++ version.protocol_min_compatible_version ++
    "\",\"stability\":\"" ++ version.protocol_stability ++
    "\",\"breakingChangePolicy\":\"" ++ version.protocol_breaking_change_policy ++
    "\"},\"platforms\":[\"android\",\"ios\"],\"platformSupport\":{\"android\":{\"status\":\"supported\",\"deviceTypes\":[\"emulator\",\"physical\"],\"automation\":[\"adb\",\"uiautomator\",\"android-shim\"]},\"ios\":{\"status\":\"supported\",\"deviceTypes\":[\"simulator\",\"physical\"],\"automation\":[\"simctl\",\"devicectl\",\"xctest-shim\"],\"physicalDevices\":true}},\"iosPreview\":false,\"transports\":[\"stdio\",\"tcp\"],\"methods\":[\"runner.capabilities\",\"device.list\",\"session.create\",\"session.close\",\"app.install\",\"app.launch\",\"app.stop\",\"app.openLink\",\"app.clearState\",\"app.clearKeychain\",\"observe.snapshot\",\"observe.semanticSnapshot\",\"ui.tap\",\"ui.type\",\"ui.eraseText\",\"ui.hideKeyboard\",\"ui.swipe\",\"ui.pressBack\",\"ui.scrollUntilVisible\",\"wait.until\",\"wait.any\",\"wait.gone\",\"assert.visible\",\"assert.notVisible\",\"assert.healthy\",\"scenario.validate\",\"trace.events\",\"trace.explore\",\"trace.discover\",\"trace.explain\",\"trace.export\"]}";

pub fn writeCapabilitiesResult(writer: anytype, id: ?std.json.Value) !void {
    try writeResultRaw(writer, id, capabilities_json);
}

pub fn writeDevicesResult(writer: anytype, id: ?std.json.Value, devices: []const types.DeviceInfo) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":[");
    for (devices, 0..) |info, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"serial\":");
        try trace.writeJsonString(writer, info.serial);
        try writer.writeAll(",\"state\":");
        try trace.writeJsonString(writer, info.state);
        try writer.print(",\"ready\":{}", .{device_registry.isKnownReadyState(info.state)});
        try writer.writeAll("}");
    }
    try writer.writeAll("]}\n");
}

pub fn writeTraceDisabledResult(writer: anytype, id: ?std.json.Value) !void {
    try writeResultRaw(writer, id, "{\"traceDir\":null,\"message\":\"start zmr serve with --trace-dir to enable live RPC trace export\"}");
}

pub fn writeTraceExportResult(
    writer: anytype,
    id: ?std.json.Value,
    trace_dir: []const u8,
    out_path: []const u8,
    redacted: bool,
    omit_screenshots: bool,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"traceDir\":");
    try trace.writeJsonString(writer, trace_dir);
    try writer.writeAll(",\"out\":");
    try trace.writeJsonString(writer, out_path);
    try writer.writeAll(",\"redacted\":");
    try writer.writeAll(if (redacted) "true" else "false");
    try writer.writeAll(",\"omitScreenshots\":");
    try writer.writeAll(if (omit_screenshots) "true" else "false");
    try writer.writeAll("}}\n");
}

pub fn writeMatchedIndexResult(writer: anytype, id: ?std.json.Value, index: usize) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"matchedIndex\":");
    try writer.print("{d}", .{index});
    try writer.writeAll("}}\n");
}

pub fn writeResultRaw(writer: anytype, id: ?std.json.Value, raw_json: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":");
    try writer.writeAll(raw_json);
    try writer.writeAll("}\n");
}

pub fn writeError(writer: anytype, id: ?std.json.Value, code: i32, message: []const u8) !void {
    try writeErrorWithPublicCode(writer, id, code, message, null);
}

pub fn writeErrorWithPublicCode(
    writer: anytype,
    id: ?std.json.Value,
    code: i32,
    message: []const u8,
    public_code: ?[]const u8,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try trace.writeJsonString(writer, message);
    if (public_code) |value| {
        try writer.writeAll(",\"publicCode\":");
        try trace.writeJsonString(writer, value);
    }
    try writer.writeAll("}}\n");
}

pub fn writeId(writer: anytype, id: ?std.json.Value) !void {
    const value = id orelse {
        try writer.writeAll("null");
        return;
    };
    switch (value) {
        .null => try writer.writeAll("null"),
        .string => |actual| try trace.writeJsonString(writer, actual),
        .integer => |actual| try writer.print("{d}", .{actual}),
        else => try writer.writeAll("null"),
    }
}
