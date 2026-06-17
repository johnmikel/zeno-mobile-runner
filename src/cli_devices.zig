const std = @import("std");
const stdio = @import("stdio.zig");
const android = @import("android.zig");
const device_registry = @import("device_registry.zig");
const ios = @import("ios.zig");
const run_options = @import("run_options.zig");
const types = @import("types.zig");

pub const IosDevicesScope = enum {
    simulator,
    physical,
    all,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var platform: run_options.Platform = .android;
    var ios_devices_scope: IosDevicesScope = .simulator;
    var adb_path: []const u8 = "adb";
    var xcrun_path: []const u8 = "xcrun";
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--platform")) {
            platform = try parsePlatform(args.next() orelse return error.MissingPlatform);
        } else if (std.mem.eql(u8, arg, "--ios-device-type")) {
            ios_devices_scope = try parseIosDevicesScope(args.next() orelse return error.MissingIosDeviceType);
        } else if (std.mem.eql(u8, arg, "--adb")) {
            adb_path = args.next() orelse return error.MissingAdbPath;
        } else if (std.mem.eql(u8, arg, "--xcrun")) {
            xcrun_path = args.next() orelse return error.MissingXcrunPath;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            return error.unknownFlag;
        }
    }

    const devices = switch (platform) {
        .android => try android.listDevices(allocator, adb_path),
        .ios => try listIosDevicesForScope(allocator, xcrun_path, ios_devices_scope),
    };
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    if (json) {
        try device_registry.writeJson(stdout, registryPlatform(platform), devices);
    } else if (devices.len == 0) {
        try stdout.print("No {s} devices found.\n", .{@tagName(platform)});
    } else {
        for (devices) |device| {
            try stdout.print("{s}\t{s}\n", .{ device.serial, device.state });
        }
    }
    try stdout_io.flush();
}

fn parsePlatform(value: []const u8) !run_options.Platform {
    if (std.mem.eql(u8, value, "android")) return .android;
    if (std.mem.eql(u8, value, "ios")) return .ios;
    return error.UnsupportedPlatform;
}

pub fn parseIosDevicesScope(value: []const u8) !IosDevicesScope {
    if (std.mem.eql(u8, value, "simulator")) return .simulator;
    if (std.mem.eql(u8, value, "physical")) return .physical;
    if (std.mem.eql(u8, value, "all")) return .all;
    return error.UnsupportedIosDeviceType;
}

fn listIosDevicesForScope(allocator: std.mem.Allocator, xcrun_path: []const u8, scope: IosDevicesScope) ![]types.DeviceInfo {
    return switch (scope) {
        .simulator => try ios.listDevices(allocator, xcrun_path),
        .physical => try ios.listPhysicalDevices(allocator, xcrun_path),
        .all => blk: {
            const simulators = try ios.listDevices(allocator, xcrun_path);
            errdefer {
                for (simulators) |device| device.deinit(allocator);
                allocator.free(simulators);
            }
            const physical = try ios.listPhysicalDevices(allocator, xcrun_path);
            errdefer {
                for (physical) |device| device.deinit(allocator);
                allocator.free(physical);
            }
            const combined = try allocator.alloc(types.DeviceInfo, simulators.len + physical.len);
            @memcpy(combined[0..simulators.len], simulators);
            @memcpy(combined[simulators.len..], physical);
            allocator.free(simulators);
            allocator.free(physical);
            break :blk combined;
        },
    };
}

pub fn registryPlatform(platform: run_options.Platform) device_registry.Platform {
    return switch (platform) {
        .android => .android,
        .ios => .ios,
    };
}
