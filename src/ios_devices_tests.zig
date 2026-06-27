const std = @import("std");
const ios_devices = @import("ios_devices.zig");

test "ios device discovery filters booted simulators" {
    const allocator = std.testing.allocator;
    const devices = try ios_devices.parseSimulatorsJson(allocator,
        \\{"devices":{"iOS 18.0":[
        \\{"udid":"booted","state":"Booted","isAvailable":true},
        \\{"udid":"shutdown","state":"Shutdown","isAvailable":true},
        \\{"udid":"unavailable","state":"Booted","isAvailable":false}
        \\]}}
    );
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }

    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("booted", devices[0].serial);
}

test "ios device discovery exposes bootable simulator candidates for auto boot" {
    const allocator = std.testing.allocator;
    const devices = try ios_devices.parseBootableSimulatorsJson(allocator,
        \\{"devices":{"iOS 18.0":[
        \\{"name":"iPhone 16","udid":"booted","state":"Booted","isAvailable":true},
        \\{"name":"iPhone 15","udid":"shutdown","state":"Shutdown","isAvailable":true},
        \\{"name":"iPad Pro","udid":"ipad-shutdown","state":"Shutdown","isAvailable":true},
        \\{"name":"Unavailable","udid":"missing","state":"Shutdown","isAvailable":false}
        \\]}}
    );
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }

    try std.testing.expectEqual(@as(usize, 3), devices.len);
    try std.testing.expectEqualStrings("booted", devices[0].serial);
    try std.testing.expectEqualStrings("Booted", devices[0].state);
    try std.testing.expectEqualStrings("shutdown", devices[1].serial);
    try std.testing.expectEqualStrings("Shutdown", devices[1].state);
    try std.testing.expectEqualStrings("ipad-shutdown", devices[2].serial);
}
