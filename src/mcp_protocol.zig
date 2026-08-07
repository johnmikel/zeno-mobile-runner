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

const selector_relation_schema_json =
    "{\"type\":\"object\",\"additionalProperties\":false,\"minProperties\":1,\"properties\":{\"id\":{\"type\":\"string\"},\"resourceId\":{\"type\":\"string\"},\"stableId\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},\"textContains\":{\"type\":\"string\"},\"textRegex\":{\"type\":\"string\"},\"contentDesc\":{\"type\":\"string\"},\"contentDescContains\":{\"type\":\"string\"},\"contentDescRegex\":{\"type\":\"string\"},\"className\":{\"type\":\"string\"},\"enabled\":{\"type\":\"boolean\"},\"checked\":{\"type\":\"boolean\"},\"focused\":{\"type\":\"boolean\"},\"selected\":{\"type\":\"boolean\"}}}";

const selector_schema_json =
    "{\"type\":\"object\",\"additionalProperties\":false,\"minProperties\":1,\"properties\":{" ++
    "\"id\":{\"type\":\"string\"},\"resourceId\":{\"type\":\"string\"},\"stableId\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},\"textContains\":{\"type\":\"string\"},\"textRegex\":{\"type\":\"string\"},\"contentDesc\":{\"type\":\"string\"},\"contentDescContains\":{\"type\":\"string\"},\"contentDescRegex\":{\"type\":\"string\"},\"className\":{\"type\":\"string\"}," ++
    "\"index\":{\"type\":\"integer\",\"minimum\":0},\"point\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"x\",\"y\"],\"properties\":{\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"}}}," ++
    "\"enabled\":{\"type\":\"boolean\"},\"checked\":{\"type\":\"boolean\"},\"focused\":{\"type\":\"boolean\"},\"selected\":{\"type\":\"boolean\"}," ++
    "\"above\":" ++ selector_relation_schema_json ++ ",\"below\":" ++ selector_relation_schema_json ++ ",\"left\":" ++ selector_relation_schema_json ++ ",\"leftOf\":" ++ selector_relation_schema_json ++ ",\"right\":" ++ selector_relation_schema_json ++ ",\"rightOf\":" ++ selector_relation_schema_json ++ ",\"child\":" ++ selector_relation_schema_json ++ ",\"descendant\":" ++ selector_relation_schema_json ++
    "}}";

// Tool descriptions carry the rules an agent gets wrong, not a restatement of
// the schema. Each line here exists because the mistake is cheap to make and
// expensive to debug from the other side of the protocol.
const semantic_snapshot_description =
    "Semantic UI tree: roles, names, stable selectors, bounds. This is ground truth - author selectors from this, never from a screenshot. " ++
    "An icon that looks like a Favourite button in a picture often carries no text at all in the tree. " ++
    "Copy text values verbatim, including case and punctuation. " ++
    "Selector matching is exact by default: 'text' must equal the whole string, so 'Sign in' does not match 'Sign in with Apple' - use 'textContains' for a substring or 'textRegex' for a bounded pattern. " ++
    "With compact=true the payload uses the abbreviated keys in its uiSchema legend; those abbreviations are NOT selector field names - always select with the full names (text, resourceId, contentDesc).";

const run_scenario_description =
    "Run a whole scenario in one call and return a typed verdict plus replayable evidence. This is the main tool: prefer one scenario over a sequence of single actions. " ++
    "Pass exactly one of 'scenario' (inline JSON, the same shape as a committed .zmr/*.json) or 'path'. The scenario is validated before it runs, so no separate validate call is needed. " ++
    "Every action - launch, tap, type, swipe, waits, assertions - is a step inside the scenario, not a separate tool. " ++
    "Returns status, the failed step index when it fails, the trace directory, and the evidence digest. On failure call trace_explain before editing selectors. " ++
    "The scenario you pass is the artifact worth keeping: write it to .zmr/ and commit it so CI replays the same check with no model in the loop.";

const scenario_schema_json =
    "{\"type\":\"object\",\"required\":[\"name\",\"steps\"],\"properties\":{\"name\":{\"type\":\"string\"},\"appId\":{\"type\":\"string\"},\"steps\":{\"type\":\"array\",\"minItems\":1,\"items\":{\"type\":\"object\"}}}}";

const tool_list_json =
    "{\"tools\":[" ++
    "{\"name\":\"snapshot\",\"description\":\"Raw observation snapshot: active app, viewport, screenshot artifact, full UI node list. Prefer semantic_snapshot for authoring selectors; use this when you need the unfiltered tree.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"semantic_snapshot\",\"description\":\"" ++ semantic_snapshot_description ++ "\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"compact\":{\"type\":\"boolean\"}}}}," ++
    "{\"name\":\"run_scenario\",\"description\":\"" ++ run_scenario_description ++ "\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"oneOf\":[{\"required\":[\"scenario\"]},{\"required\":[\"path\"]}],\"properties\":{\"scenario\":" ++ scenario_schema_json ++ ",\"path\":{\"type\":\"string\"},\"traceDir\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"scenario_validate\",\"description\":\"Validate a scenario without running it. Returns fieldPath, line and column for the first problem. run_scenario already validates, so use this only to check a file you are not about to run.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"oneOf\":[{\"required\":[\"scenario\"]},{\"required\":[\"path\"]}],\"properties\":{\"scenario\":" ++ scenario_schema_json ++ ",\"path\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"trace_explain\",\"description\":\"Explain the active trace: status, the failed step index, the error code, and the text actually on screen when it failed. Call this after a failed run_scenario before changing any selector - it usually names the real cause.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}}," ++
    "{\"name\":\"trace_discover\",\"description\":\"Turn evidence already in the active trace into a reviewable scenario draft. Writes a file for a human to review; it does not crawl the app or invent steps.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"out\"],\"properties\":{\"out\":{\"type\":\"string\"},\"includeActions\":{\"type\":\"boolean\"},\"validate\":{\"type\":\"boolean\"},\"force\":{\"type\":\"boolean\"},\"name\":{\"type\":\"string\"},\"appId\":{\"type\":\"string\"},\"goal\":{\"type\":\"string\"}}}}," ++
    "{\"name\":\"trace_export\",\"description\":\"Package the active trace as a .zmrtrace bundle whose manifest binds every artifact to a SHA-256 digest. Change one byte and validation fails - this is the artifact a reviewer can verify instead of trust.\",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"out\"],\"properties\":{\"out\":{\"type\":\"string\"},\"redact\":{\"type\":\"boolean\"},\"omitScreenshots\":{\"type\":\"boolean\"}}}}" ++
    "]}";
