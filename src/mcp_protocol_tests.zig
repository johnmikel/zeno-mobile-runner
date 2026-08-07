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

    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"semantic_snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"install_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"launch_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"appId\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"arguments\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"stop_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"clear_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"clear_keychain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"tap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"swipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"hide_keyboard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"erase_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"scroll_until_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"wait_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"wait_not_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"wait_any\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"assert_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"assert_not_visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"assert_healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"scenario_validate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"trace_explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"trace_explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"trace_discover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"name\":\"trace_export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"goal\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"inputSchema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"selector\":{\"type\":\"object\",\"additionalProperties\":false,\"minProperties\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"stableId\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.written(), "\"selectors\":{\"type\":\"array\",\"minItems\":1,\"items\":{\"type\":\"object\",\"additionalProperties\":false,\"minProperties\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tools.written(), "\n"));
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
