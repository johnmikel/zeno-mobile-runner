const std = @import("std");
const mcp_protocol = @import("mcp_protocol.zig");

test "mcp protocol writes initialize and tool list responses" {
    const allocator = std.testing.allocator;

    var initialize = std.ArrayList(u8).empty;
    defer initialize.deinit(allocator);
    try mcp_protocol.writeInitializeResult(initialize.writer(allocator), .{ .integer = 1 }, "2024-11-05");

    try std.testing.expect(std.mem.indexOf(u8, initialize.items, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, initialize.items, "\"protocolVersion\":\"2024-11-05\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, initialize.items, "\"serverInfo\":{\"name\":\"zmr\"") != null);

    var tools = std.ArrayList(u8).empty;
    defer tools.deinit(allocator);
    try mcp_protocol.writeToolListResult(tools.writer(allocator), .{ .integer = 2 });

    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"semantic_snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"install_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"launch_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"stop_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"clear_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"tap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"swipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"hide_keyboard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"erase_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"scroll_until_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"wait_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"wait_not_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"wait_any\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"assert_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"assert_not_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"assert_healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"scenario_validate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"trace_explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"trace_discover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"name\":\"trace_export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.items, "\"inputSchema\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tools.items, "\n"));
}

test "mcp protocol writes text results and public errors" {
    const allocator = std.testing.allocator;

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try mcp_protocol.writeToolTextResult(result.writer(allocator), .{ .string = "abc" }, "{\"ok\":true}");

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true}\"}]}}\n",
        result.items,
    );

    var err = std.ArrayList(u8).empty;
    defer err.deinit(allocator);
    try mcp_protocol.writeErrorWithPublicCode(err.writer(allocator), .{ .integer = 9 }, -32000, "WaitTimeout", "runner.wait_timeout");

    try std.testing.expect(std.mem.indexOf(u8, err.items, "\"code\":-32000") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.items, "\"message\":\"WaitTimeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.items, "\"publicCode\":\"runner.wait_timeout\"") != null);
}
