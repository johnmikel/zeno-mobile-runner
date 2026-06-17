const std = @import("std");
const test_io = @import("test_io.zig");
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
