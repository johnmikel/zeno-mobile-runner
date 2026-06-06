const std = @import("std");
const trace = @import("trace.zig");
const version = @import("version.zig");

pub fn writeInitializeResult(writer: anytype, id: ?std.json.Value, protocol_version: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"protocolVersion\":");
    try trace.writeJsonString(writer, protocol_version);
    try writer.writeAll(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"zmr\",\"version\":");
    try trace.writeJsonString(writer, version.runner_version);
    try writer.writeAll("}}}\n");
}

pub fn writeToolListResult(writer: anytype, id: ?std.json.Value) !void {
    try writeResultRaw(writer, id, tool_list_json);
}

pub fn writeToolTextResult(writer: anytype, id: ?std.json.Value, text: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try trace.writeJsonString(writer, text);
    try writer.writeAll("}]}}\n");
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

pub fn writeErrorWithPublicCode(writer: anytype, id: ?std.json.Value, code: i32, message: []const u8, public_code: ?[]const u8) !void {
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

const tool_list_json =
    "{\"tools\":[" ++
    "{\"name\":\"snapshot\",\"description\":\"Capture the current mobile observation snapshot as JSON.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"semantic_snapshot\",\"description\":\"Capture an agent-optimized mobile semantic tree with roles, names, selectors, bounds, and recommended actions.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"install_app\",\"description\":\"Install an app artifact on the selected device.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"launch_app\",\"description\":\"Launch the configured app on the selected device.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"stop_app\",\"description\":\"Stop the configured app on the selected device.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"clear_state\",\"description\":\"Clear the configured app state where the platform supports it.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"tap\",\"description\":\"Tap a visible element by selector.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"selector\"],\"properties\":{\"selector\":{\"type\":\"object\"}}}}," ++
    "{\"name\":\"type\",\"description\":\"Type text, optionally after focusing an element by selector.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"text\"],\"properties\":{\"selector\":{\"type\":\"object\"},\"text\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"hide_keyboard\",\"description\":\"Dismiss the software keyboard when the platform can do so.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"erase_text\",\"description\":\"Erase text, optionally after focusing an element by selector.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"selector\":{\"type\":\"object\"},\"maxChars\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"swipe\",\"description\":\"Swipe between absolute screen coordinates.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"x1\",\"y1\",\"x2\",\"y2\"],\"properties\":{\"x1\":{\"type\":\"integer\"},\"y1\":{\"type\":\"integer\"},\"x2\":{\"type\":\"integer\"},\"y2\":{\"type\":\"integer\"},\"durationMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"press_back\",\"description\":\"Press Android back or the platform-equivalent navigation action.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"open_link\",\"description\":\"Open a deep link URL in the target app.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"url\"],\"properties\":{\"url\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"wait_visible\",\"description\":\"Wait for an element selector to become visible.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"selector\"],\"properties\":{\"selector\":{\"type\":\"object\"},\"timeoutMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"wait_not_visible\",\"description\":\"Wait for an element selector to no longer be visible.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"selector\"],\"properties\":{\"selector\":{\"type\":\"object\"},\"timeoutMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"wait_any\",\"description\":\"Wait for the first visible selector from an ordered selector list.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"selectors\"],\"properties\":{\"selectors\":{\"type\":\"array\",\"minItems\":1,\"items\":{\"type\":\"object\"}},\"timeoutMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"scroll_until_visible\",\"description\":\"Scroll until an element selector is visible.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"selector\"],\"properties\":{\"selector\":{\"type\":\"object\"},\"direction\":{\"type\":\"string\",\"enum\":[\"down\",\"up\"]},\"timeoutMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"assert_visible\",\"description\":\"Assert that an element selector is visible within the timeout.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"selector\"],\"properties\":{\"selector\":{\"type\":\"object\"},\"timeoutMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"assert_not_visible\",\"description\":\"Assert that an element selector is not visible within the timeout.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"selector\"],\"properties\":{\"selector\":{\"type\":\"object\"},\"timeoutMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"assert_healthy\",\"description\":\"Assert that the app is free of common crash and error overlays.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"timeoutMs\":{\"type\":\"integer\",\"minimum\":0}}}}," ++
    "{\"name\":\"scenario_validate\",\"description\":\"Validate a ZMR scenario file and return structured diagnostics.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"trace_events\",\"description\":\"Read live trace events from a traced MCP session.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"afterSeq\":{\"type\":\"integer\",\"minimum\":0},\"limit\":{\"type\":\"integer\",\"minimum\":1}}}}," ++
    "{\"name\":\"trace_discover\",\"description\":\"Generate a reviewable scenario draft from the active trace directory.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"out\"],\"properties\":{\"out\":{\"type\":\"string\"},\"includeActions\":{\"type\":\"boolean\"},\"validate\":{\"type\":\"boolean\"},\"force\":{\"type\":\"boolean\"},\"name\":{\"type\":\"string\"},\"appId\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"trace_export\",\"description\":\"Export the active trace directory as a .zmrtrace bundle.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"out\"],\"properties\":{\"out\":{\"type\":\"string\"},\"redact\":{\"type\":\"boolean\"},\"omitScreenshots\":{\"type\":\"boolean\"}}}}" ++
    "]}";
