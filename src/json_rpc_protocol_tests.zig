const std = @import("std");
const json_rpc_protocol = @import("json_rpc_protocol.zig");
const types = @import("types.zig");

test "capabilities result includes protocol metadata and agent methods" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try json_rpc_protocol.writeCapabilitiesResult(out.writer(std.testing.allocator), std.json.Value{ .integer = 1 });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"protocolVersion\":\"2026-04-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"observe.semanticSnapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"scenario.validate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"trace.explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"trace.discover\"") != null);
}

test "device result marks ready states consistently" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const devices = [_]types.DeviceInfo{
        .{ .serial = "booted", .state = "Booted" },
        .{ .serial = "off", .state = "unavailable" },
    };
    try json_rpc_protocol.writeDevicesResult(out.writer(std.testing.allocator), std.json.Value{ .integer = 2 }, devices[0..]);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"serial\":\"booted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ready\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"serial\":\"off\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ready\":false") != null);
}
