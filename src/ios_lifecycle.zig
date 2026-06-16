const std = @import("std");
const command = @import("command.zig");
const ios_devices = @import("ios_devices.zig");

const default_max_output = 32 * 1024 * 1024;

pub fn installPhysical(
    allocator: std.mem.Allocator,
    xcrun_path: []const u8,
    target: []const u8,
    app_path: []const u8,
) !void {
    const result = try ios_devices.runDevicectlCommand(allocator, xcrun_path, &.{ "device", "install", "app", "--device", target, app_path }, default_max_output);
    defer result.deinit(allocator);
    try result.ensureSuccess();
}

pub fn launchPhysical(
    allocator: std.mem.Allocator,
    xcrun_path: []const u8,
    target: []const u8,
    app_id: []const u8,
    url: ?[]const u8,
) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "device", "process", "launch", "--device", target, "--terminate-existing" });
    if (url) |value| try argv.appendSlice(allocator, &.{ "--payload-url", value });
    try argv.append(allocator, app_id);

    const result = try ios_devices.runDevicectlCommand(allocator, xcrun_path, argv.items, default_max_output);
    defer result.deinit(allocator);
    try result.ensureSuccess();
}

pub fn stopPhysicalBestEffort(
    allocator: std.mem.Allocator,
    xcrun_path: []const u8,
    target: []const u8,
    app_id: []const u8,
) !void {
    const process_json = ios_devices.runDevicectlJsonCommand(allocator, xcrun_path, &.{ "device", "info", "processes", "--device", target }) catch return;
    defer allocator.free(process_json);
    const pid = ios_devices.findPidForBundleId(allocator, process_json, app_id) catch null;
    if (pid) |value| {
        const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(pid_text);
        const result = try ios_devices.runDevicectlCommand(allocator, xcrun_path, &.{ "device", "process", "terminate", "--device", target, "--pid", pid_text }, default_max_output);
        defer result.deinit(allocator);
        try result.ensureSuccess();
    }
}

pub fn uninstallPhysicalBestEffort(
    allocator: std.mem.Allocator,
    xcrun_path: []const u8,
    target: []const u8,
    app_id: []const u8,
) !void {
    const result = try ios_devices.runDevicectlCommand(allocator, xcrun_path, &.{ "device", "uninstall", "app", "--device", target, app_id }, default_max_output);
    defer result.deinit(allocator);
    if (isMissingInstalledApp(result)) return;
    try result.ensureSuccess();
}

pub fn isMissingInstalledApp(result: command.ExecResult) bool {
    switch (result.term) {
        .exited => |code| if (code == 0) return false,
        else => return false,
    }
    return std.mem.indexOf(u8, result.stderr, "No installed application with bundle identifier") != null;
}

pub fn isAppNotRunning(result: command.ExecResult) bool {
    switch (result.term) {
        .exited => |code| if (code == 0) return false,
        else => return false,
    }
    return std.mem.indexOf(u8, result.stderr, "found nothing to terminate") != null;
}

test "simctl terminate missing running app is best-effort" {
    const allocator = std.testing.allocator;
    const stdout = try allocator.dupe(u8, "");
    defer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, "The request to terminate \"com.example.mobiletest\" failed. found nothing to terminate");
    defer allocator.free(stderr);

    try std.testing.expect(isAppNotRunning(.{
        .stdout = stdout,
        .stderr = stderr,
        .term = .{ .exited = 3 },
    }));
}

test "simctl terminate success is not classified as already stopped" {
    const allocator = std.testing.allocator;
    const stdout = try allocator.dupe(u8, "");
    defer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, "");
    defer allocator.free(stderr);

    try std.testing.expect(!isAppNotRunning(.{
        .stdout = stdout,
        .stderr = stderr,
        .term = .{ .exited = 0 },
    }));
}
