const std = @import("std");
const fake_device = @import("fake_device.zig");
const runner = @import("runner.zig");
const scenario = @import("scenario.zig");

test "runner executes launchApp options and clearKeychain" {
    const allocator = std.testing.allocator;
    const script_json =
        \\{
        \\  "name": "launch options",
        \\  "steps": [
        \\    {"action":"launchApp","appId":"com.example.other","stopApp":false,"clearState":true,"clearKeychain":true,"arguments":{"flag":true}},
        \\    {"action":"clearKeychain"}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    var device = fake_device.FakeDevice.init(allocator, &.{});
    defer device.deinit();
    try runner.runScenario(allocator, &device, script, null, .{ .settle_ms = 0 });

    try std.testing.expect(device.launched);
    try std.testing.expect(!device.stopped);
    try std.testing.expect(device.cleared);
    try std.testing.expect(device.cleared_keychain);
    try std.testing.expectEqual(@as(usize, 1), device.launch_argument_count);
    try std.testing.expectEqualStrings("com.example.other", device.launch_app_id.?);
}
