const std = @import("std");
const stdio = @import("stdio.zig");
const command = @import("command.zig");
const types = @import("types.zig");

const default_max_output = 32 * 1024 * 1024;
const simctl_retry_attempts = 6;
// Mutable so tests can zero it; production code never writes it.
pub var simctl_retry_delay_ms: u64 = 500;

pub fn listSimulators(allocator: std.mem.Allocator, xcrun_path: []const u8) ![]types.DeviceInfo {
    const result = try runSimctlCommand(allocator, xcrun_path, &.{ "list", "devices", "--json" }, 4 * 1024 * 1024);
    defer result.deinit(allocator);
    try result.ensureSuccess();
    return try parseSimulatorsJson(allocator, result.stdout);
}

pub fn listBootableSimulators(allocator: std.mem.Allocator, xcrun_path: []const u8) ![]types.DeviceInfo {
    const result = try runSimctlCommand(allocator, xcrun_path, &.{ "list", "devices", "--json" }, 4 * 1024 * 1024);
    defer result.deinit(allocator);
    try result.ensureSuccess();
    return try parseBootableSimulatorsJson(allocator, result.stdout);
}

pub fn listPhysical(allocator: std.mem.Allocator, xcrun_path: []const u8) ![]types.DeviceInfo {
    const json = try runDevicectlJsonCommand(allocator, xcrun_path, &.{ "list", "devices" });
    defer allocator.free(json);
    return try parsePhysicalDevicesJson(allocator, json);
}

pub fn ensureSimulatorBooted(allocator: std.mem.Allocator, xcrun_path: []const u8, target: ?[]const u8) !void {
    const wanted = target orelse "booted";
    const devices = try listBootableSimulators(allocator, xcrun_path);
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }

    if (!std.mem.eql(u8, wanted, "booted")) {
        for (devices) |device| {
            if (!std.mem.eql(u8, device.serial, wanted)) continue;
            if (std.mem.eql(u8, device.state, "Booted")) return try waitForBootStatus(allocator, xcrun_path, wanted);
            return try bootAndWait(allocator, xcrun_path, wanted);
        }
        return try bootAndWait(allocator, xcrun_path, wanted);
    }

    for (devices) |device| {
        if (std.mem.eql(u8, device.state, "Booted")) return try waitForBootStatus(allocator, xcrun_path, "booted");
    }
    for (devices) |device| {
        if (!std.mem.eql(u8, device.state, "Shutdown")) continue;
        if (try bootAndWaitBestEffort(allocator, xcrun_path, device.serial)) return;
    }
    return error.NoIosSimulatorAvailable;
}

fn bootAndWait(allocator: std.mem.Allocator, xcrun_path: []const u8, target: []const u8) !void {
    var boot = try runSimctlCommand(allocator, xcrun_path, &.{ "boot", target }, default_max_output);
    defer boot.deinit(allocator);
    try boot.ensureSuccess();
    try waitForBootStatus(allocator, xcrun_path, target);
}

fn bootAndWaitBestEffort(allocator: std.mem.Allocator, xcrun_path: []const u8, target: []const u8) !bool {
    var boot = try runSimctlCommand(allocator, xcrun_path, &.{ "boot", target }, default_max_output);
    defer boot.deinit(allocator);
    boot.ensureSuccess() catch return false;
    waitForBootStatus(allocator, xcrun_path, target) catch return false;
    return true;
}

fn waitForBootStatus(allocator: std.mem.Allocator, xcrun_path: []const u8, target: []const u8) !void {
    var status = try runSimctlCommand(allocator, xcrun_path, &.{ "bootstatus", target, "-b" }, default_max_output);
    defer status.deinit(allocator);
    try status.ensureSuccess();
}

pub fn runSimctlCommand(
    allocator: std.mem.Allocator,
    xcrun_path: []const u8,
    extra: []const []const u8,
    max_output_bytes: usize,
) !command.ExecResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, xcrun_path);
    try argv.append(allocator, "simctl");
    try argv.appendSlice(allocator, extra);

    var attempt: usize = 0;
    while (true) {
        const result = try command.run(allocator, argv.items, max_output_bytes);
        if (attempt + 1 >= simctl_retry_attempts or !isRetriableSimctlFailure(result)) {
            return result;
        }
        result.deinit(allocator);
        attempt += 1;
        stdio.sleepNs(simctl_retry_delay_ms * std.time.ns_per_ms);
    }
}

pub fn runDevicectlCommand(
    allocator: std.mem.Allocator,
    xcrun_path: []const u8,
    extra: []const []const u8,
    max_output_bytes: usize,
) !command.ExecResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, xcrun_path);
    try argv.append(allocator, "devicectl");
    try argv.appendSlice(allocator, extra);
    return try command.run(allocator, argv.items, max_output_bytes);
}

pub fn runDevicectlJsonCommand(
    allocator: std.mem.Allocator,
    xcrun_path: []const u8,
    extra: []const []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/zmr-devicectl-{d}.json", .{stdio.nowNs()});
    defer allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(stdio.io(), path) catch {};

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, xcrun_path);
    try argv.append(allocator, "devicectl");
    try argv.appendSlice(allocator, extra);
    try argv.appendSlice(allocator, &.{ "--json-output", path, "--quiet" });

    const result = try command.run(allocator, argv.items, default_max_output);
    defer result.deinit(allocator);
    try result.ensureSuccess();
    return try std.Io.Dir.cwd().readFileAlloc(stdio.io(), path, allocator, .limited(default_max_output));
}

pub fn parseSimulatorsJson(allocator: std.mem.Allocator, content: []const u8) ![]types.DeviceInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.SimctlDevicesMustBeObject;
    const devices_value = parsed.value.object.get("devices") orelse return error.SimctlDevicesMissingDevices;
    if (devices_value != .object) return error.SimctlDevicesMustBeObject;

    var devices = std.ArrayList(types.DeviceInfo).empty;
    errdefer {
        for (devices.items) |device| device.deinit(allocator);
        devices.deinit(allocator);
    }

    var runtime_iterator = devices_value.object.iterator();
    while (runtime_iterator.next()) |runtime_entry| {
        const runtime_devices = runtime_entry.value_ptr.*;
        if (runtime_devices != .array) continue;
        for (runtime_devices.array.items) |device_value| {
            if (device_value != .object) continue;
            const object = device_value.object;
            if (fieldBool(object, "isAvailable") == false) continue;
            const udid = fieldString(object, "udid") orelse continue;
            const state = fieldString(object, "state") orelse continue;
            if (!std.mem.eql(u8, state, "Booted")) continue;
            try devices.append(allocator, .{
                .serial = try allocator.dupe(u8, udid),
                .state = try allocator.dupe(u8, state),
            });
        }
    }

    return try devices.toOwnedSlice(allocator);
}

pub fn parseBootableSimulatorsJson(allocator: std.mem.Allocator, content: []const u8) ![]types.DeviceInfo {
    return try parseSimulatorsJsonWithStates(allocator, content, &.{ "Booted", "Shutdown" });
}

fn parseSimulatorsJsonWithStates(allocator: std.mem.Allocator, content: []const u8, wanted_states: []const []const u8) ![]types.DeviceInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.SimctlDevicesMustBeObject;
    const devices_value = parsed.value.object.get("devices") orelse return error.SimctlDevicesMissingDevices;
    if (devices_value != .object) return error.SimctlDevicesMustBeObject;

    var devices = std.ArrayList(types.DeviceInfo).empty;
    errdefer {
        for (devices.items) |device| device.deinit(allocator);
        devices.deinit(allocator);
    }

    var runtime_iterator = devices_value.object.iterator();
    while (runtime_iterator.next()) |runtime_entry| {
        const runtime_devices = runtime_entry.value_ptr.*;
        if (runtime_devices != .array) continue;
        for (runtime_devices.array.items) |device_value| {
            if (device_value != .object) continue;
            const object = device_value.object;
            if (fieldBool(object, "isAvailable") == false) continue;
            const udid = fieldString(object, "udid") orelse continue;
            const state = fieldString(object, "state") orelse continue;
            if (!stateAllowed(state, wanted_states)) continue;
            try devices.append(allocator, .{
                .serial = try allocator.dupe(u8, udid),
                .state = try allocator.dupe(u8, state),
            });
        }
    }

    return try devices.toOwnedSlice(allocator);
}

fn stateAllowed(state: []const u8, wanted_states: []const []const u8) bool {
    for (wanted_states) |wanted| {
        if (std.mem.eql(u8, state, wanted)) return true;
    }
    return false;
}

pub fn parsePhysicalDevicesJson(allocator: std.mem.Allocator, content: []const u8) ![]types.DeviceInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.DevicectlDevicesMustBeObject;
    const result_value = parsed.value.object.get("result") orelse return error.DevicectlDevicesMissingResult;
    if (result_value != .object) return error.DevicectlDevicesMustBeObject;
    const devices_value = result_value.object.get("devices") orelse return error.DevicectlDevicesMissingDevices;
    if (devices_value != .array) return error.DevicectlDevicesMustBeArray;

    var devices = std.ArrayList(types.DeviceInfo).empty;
    errdefer {
        for (devices.items) |device| device.deinit(allocator);
        devices.deinit(allocator);
    }

    for (devices_value.array.items) |device_value| {
        if (device_value != .object) continue;
        const object = device_value.object;
        const hardware = fieldObject(object, "hardwareProperties") orelse continue;
        if (!fieldStringEquals(hardware, "platform", "iOS")) continue;
        if (!fieldStringEquals(hardware, "reality", "physical")) continue;
        const serial = fieldString(object, "identifier") orelse fieldString(hardware, "udid") orelse continue;
        const connection = fieldObject(object, "connectionProperties");
        const state = if (connection) |value|
            fieldString(value, "tunnelState") orelse fieldString(value, "pairingState") orelse "available"
        else
            "available";
        try devices.append(allocator, .{
            .serial = try allocator.dupe(u8, serial),
            .state = try allocator.dupe(u8, state),
        });
    }

    return try devices.toOwnedSlice(allocator);
}

pub fn findPidForBundleId(allocator: std.mem.Allocator, content: []const u8, app_id: []const u8) !?i64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    return findPidInValue(parsed.value, app_id);
}

fn isRetriableSimctlFailure(result: command.ExecResult) bool {
    if (result.timed_out) return false;
    switch (result.term) {
        .exited => |code| if (code == 0) return false,
        else => return false,
    }
    return std.mem.indexOf(u8, result.stderr, "CoreSimulatorService connection became invalid") != null or
        std.mem.indexOf(u8, result.stderr, "Failed to initialize simulator device set") != null or
        std.mem.indexOf(u8, result.stderr, "simdiskimaged") != null or
        std.mem.indexOf(u8, result.stderr, "Connection refused") != null;
}

fn findPidInValue(value: std.json.Value, app_id: []const u8) ?i64 {
    switch (value) {
        .object => |object| {
            var has_bundle = false;
            var pid: ?i64 = null;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* == .string and std.mem.eql(u8, entry.value_ptr.string, app_id)) {
                    has_bundle = true;
                }
                if (std.mem.indexOf(u8, entry.key_ptr.*, "pid") != null or std.mem.indexOf(u8, entry.key_ptr.*, "processIdentifier") != null) {
                    if (entry.value_ptr.* == .integer) pid = entry.value_ptr.integer;
                }
                if (findPidInValue(entry.value_ptr.*, app_id)) |nested| return nested;
            }
            if (has_bundle) return pid;
            return null;
        },
        .array => |array| {
            for (array.items) |item| {
                if (findPidInValue(item, app_id)) |pid| return pid;
            }
            return null;
        },
        else => return null,
    }
}

fn fieldObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn fieldStringEquals(object: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = fieldString(object, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn fieldString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn fieldBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    if (value != .bool) return true;
    return value.bool;
}
