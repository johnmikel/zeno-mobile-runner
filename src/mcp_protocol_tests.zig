const std = @import("std");
const test_io = @import("test_io.zig");
const mcp_protocol = @import("mcp_protocol.zig");

test "mcp protocol writes initialize and tool list responses" {
    var initialize = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer initialize.deinit();
    try mcp_protocol.writeInitializeResult(&initialize.writer, .{ .integer = 1 }, "2024-11-05");

    try std.testing.expect(std.mem.indexOf(u8, initialize.written(), "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, initialize.written(), "\"protocolVersion\":\"2024-11-05\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, initialize.written(), "\"serverInfo\":{\"name\":\"zmr\"") != null);

    var tools = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer tools.deinit();
    try mcp_protocol.writeToolListResult(&tools.writer, .{ .integer = 2 });

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tools.written(), "\n"));
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"inputSchema\"") != null);
}

// An agent that has to send one tool call per tap burns a round-trip and a
// slice of its context on every step, and what it leaves behind is a
// transcript rather than a committed scenario. The surface is deliberately
// small: observe, run a whole scenario, explain a failure. Every per-action
// tool that used to live here is a scenario step instead.
const expected_tools = [_][]const u8{
    "snapshot",
    "semantic_snapshot",
    "run_scenario",
    "scenario_validate",
    "trace_explain",
    "trace_discover",
    "trace_export",
};

const removed_tools = [_][]const u8{
    "install_app",   "launch_app",     "stop_app",             "clear_state",    "clear_keychain",
    "open_link",     "tap",            "type",                 "erase_text",     "hide_keyboard",
    "swipe",         "press_back",     "scroll_until_visible", "wait_visible",   "wait_not_visible",
    "wait_any",      "assert_visible", "assert_not_visible",   "assert_healthy", "trace_events",
    "trace_explore",
};

test "mcp exposes exactly the collapsed agent surface" {
    var tools = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer tools.deinit();
    try mcp_protocol.writeToolListResult(&tools.writer, .{ .integer = 2 });
    const payload = tools.written();

    for (expected_tools) |name| {
        const needle = try std.fmt.allocPrint(std.testing.allocator, "\"name\":\"{s}\"", .{name});
        defer std.testing.allocator.free(needle);
        if (std.mem.indexOf(u8, payload, needle) == null) {
            std.debug.print("missing expected tool: {s}\n", .{name});
            return error.MissingExpectedTool;
        }
    }

    for (removed_tools) |name| {
        const needle = try std.fmt.allocPrint(std.testing.allocator, "\"name\":\"{s}\"", .{name});
        defer std.testing.allocator.free(needle);
        if (std.mem.indexOf(u8, payload, needle) != null) {
            std.debug.print("per-action tool still exposed: {s}\n", .{name});
            return error.RemovedToolStillExposed;
        }
    }

    // Nothing beyond the declared set: count tool objects, not just presence.
    try std.testing.expectEqual(expected_tools.len, std.mem.count(u8, payload, "\"inputSchema\""));
}

test "run_scenario accepts an inline scenario and reports evidence" {
    var tools = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer tools.deinit();
    try mcp_protocol.writeToolListResult(&tools.writer, .{ .integer = 2 });
    const payload = tools.written();

    const run = std.mem.indexOf(u8, payload, "\"name\":\"run_scenario\"") orelse
        return error.MissingRunScenarioTool;
    const rest = payload[run..];
    const schema_end = std.mem.indexOf(u8, rest[1..], "{\"name\":\"") orelse rest.len - 1;
    const tool = rest[0 .. schema_end + 1];

    // Exactly one source of the scenario, so an agent cannot pass two and
    // wonder which won.
    try std.testing.expect(std.mem.indexOf(u8, tool, "\"scenario\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool, "\"path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool, "\"oneOf\"") != null);
}

test "mcp protocol writes text results and public errors" {
    var result = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer result.deinit();
    try mcp_protocol.writeToolTextResult(&result.writer, .{ .string = "abc" }, "{\"ok\":true}");

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true}\"}]}}\n",
        result.written(),
    );

    var err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err.deinit();
    try mcp_protocol.writeErrorWithPublicCode(&err.writer, .{ .integer = 9 }, -32000, "WaitTimeout", "runner.wait_timeout");

    try std.testing.expect(std.mem.indexOf(u8, err.written(), "\"code\":-32000") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "\"message\":\"WaitTimeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "\"publicCode\":\"runner.wait_timeout\"") != null);
}
