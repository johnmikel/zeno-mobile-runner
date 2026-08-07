const std = @import("std");
const test_io = @import("test_io.zig");
const action_registry = @import("action_registry.zig");
const json_rpc_protocol = @import("json_rpc_protocol.zig");
const types = @import("types.zig");

test "capabilities result includes protocol metadata and agent methods" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try json_rpc_protocol.writeCapabilitiesResult(&out.writer, std.json.Value{ .integer = 1 });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"protocolVersion\":\"2026-04-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"observe.semanticSnapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"scenario.validate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"trace.explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"trace.discover\"") != null);
}

test "capabilities result exposes the canonical action registry" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try json_rpc_protocol.writeCapabilitiesResult(&out.writer, std.json.Value{ .integer = 3 });

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    const actions = result.get("actions").?.array;
    try std.testing.expectEqual(action_registry.all().len, actions.items.len);
    try std.testing.expectEqualStrings("app.launch", actions.items[0].object.get("id").?.string);
    try std.testing.expect(actions.items[0].object.get("jsonAliases") != null);
    try std.testing.expect(actions.items[0].object.get("yamlAliases") != null);
    try std.testing.expect(actions.items[0].object.get("requiredCapability") != null);
    try std.testing.expect(actions.items[0].object.get("riskClass") != null);
}

test "device result marks ready states consistently" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const devices = [_]types.DeviceInfo{
        .{ .serial = "booted", .state = "Booted" },
        .{ .serial = "off", .state = "unavailable" },
    };
    try json_rpc_protocol.writeDevicesResult(&out.writer, std.json.Value{ .integer = 2 }, devices[0..]);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"serial\":\"booted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ready\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"serial\":\"off\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ready\":false") != null);
}
