const std = @import("std");
const stdio = @import("stdio.zig");
const android_device_info = @import("android_device_info.zig");
const command = @import("command.zig");

const default_timeout_ms = 15_000;

pub const PreflightOptions = struct {
    adb_path: []const u8 = "adb",
    emulator_path: []const u8 = "emulator",
    avdmanager_path: []const u8 = "avdmanager",
    device_serial: ?[]const u8 = null,
    avd_name: ?[]const u8 = null,
    restore_snapshot: ?[]const u8 = null,
    create_avd_if_missing: bool = false,
    avd_system_image: ?[]const u8 = null,
    avd_device_profile: ?[]const u8 = null,
    reset_before_run: bool = false,
    wait_ready: bool = false,
    ensure_ready: bool = false,
    event_log_path: ?[]const u8 = null,
};

pub fn hasWork(options: PreflightOptions) bool {
    return options.ensure_ready or options.reset_before_run or options.wait_ready or options.create_avd_if_missing or options.avd_name != null or options.restore_snapshot != null;
}

pub fn runPreflight(allocator: std.mem.Allocator, options: PreflightOptions) !void {
    if (!hasWork(options)) return;

    const must_run_lifecycle = options.reset_before_run or options.restore_snapshot != null or options.create_avd_if_missing;
    if (options.ensure_ready and !must_run_lifecycle and try requestedDeviceReady(allocator, options)) {
        if (options.wait_ready) try waitReady(allocator, options);
        return;
    }

    var owned_avd: ?[]u8 = null;
    defer if (owned_avd) |avd| allocator.free(avd);
    const avd_name = if (options.avd_name) |avd|
        avd
    else blk: {
        if (!options.ensure_ready) break :blk null;
        var list = try runEmulator(allocator, options, &.{"-list-avds"});
        defer list.deinit(allocator);
        try list.ensureSuccess();
        const first = (try firstAvdNameFromList(list.stdout)) orelse return error.NoAndroidAvdAvailable;
        owned_avd = try allocator.dupe(u8, first);
        break :blk owned_avd.?;
    };

    if ((options.reset_before_run or options.restore_snapshot != null or options.create_avd_if_missing or avd_name != null) and avd_name == null) {
        return error.MissingAndroidAvdName;
    }
    if (options.create_avd_if_missing and options.avd_system_image == null) {
        return error.MissingAndroidAvdSystemImage;
    }

    if (options.create_avd_if_missing) {
        try createAvdIfMissing(allocator, options, avd_name.?);
    }

    if (options.reset_before_run) {
        const reset = runAdb(allocator, options, &.{ "emu", "kill" }) catch null;
        if (reset) |result| result.deinit(allocator);
    }

    if (avd_name) |avd| {
        try startEmulator(allocator, options, avd);
    }

    if (options.wait_ready or options.ensure_ready) {
        try waitReady(allocator, options);
    }
}

fn requestedDeviceReady(allocator: std.mem.Allocator, options: PreflightOptions) !bool {
    const devices = android_device_info.listDevices(allocator, options.adb_path) catch return false;
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }
    for (devices) |device| {
        if (!std.mem.eql(u8, device.state, "device")) continue;
        if (options.device_serial) |serial| {
            if (std.mem.eql(u8, device.serial, serial)) return true;
        } else {
            return true;
        }
    }
    return false;
}

fn createAvdIfMissing(allocator: std.mem.Allocator, options: PreflightOptions, avd: []const u8) !void {
    var list = try runEmulator(allocator, options, &.{"-list-avds"});
    defer list.deinit(allocator);
    try list.ensureSuccess();
    if (avdListContains(list.stdout, avd)) return;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ options.avdmanager_path, "create", "avd", "--name", avd, "--package", options.avd_system_image.? });
    if (options.avd_device_profile) |profile| {
        try argv.appendSlice(allocator, &.{ "--device", profile });
    }
    try argv.append(allocator, "--force");
    try recordCommand(allocator, options.event_log_path, argv.items);
    var result = try command.runWithInputTimeout(allocator, argv.items, "no\n", 1024 * 1024, default_timeout_ms);
    defer result.deinit(allocator);
    try result.ensureSuccess();
}

fn avdListContains(output: []const u8, avd: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (std.mem.eql(u8, line, avd)) return true;
    }
    return false;
}

pub fn firstAvdNameFromList(output: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        return line;
    }
    return null;
}

fn runEmulator(allocator: std.mem.Allocator, options: PreflightOptions, extra: []const []const u8) !command.ExecResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.emulator_path);
    try argv.appendSlice(allocator, extra);
    try recordCommand(allocator, options.event_log_path, argv.items);
    return try command.runWithTimeout(allocator, argv.items, 1024 * 1024, default_timeout_ms);
}

fn startEmulator(allocator: std.mem.Allocator, options: PreflightOptions, avd: []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.emulator_path);
    try argv.appendSlice(allocator, &.{ "-avd", avd });
    if (options.restore_snapshot) |snapshot| {
        try argv.appendSlice(allocator, &.{ "-snapshot", snapshot });
    } else {
        try argv.append(allocator, "-no-snapshot-load");
    }
    try argv.appendSlice(allocator, &.{ "-netdelay", "none", "-netspeed", "full" });
    try recordCommand(allocator, options.event_log_path, argv.items);

    _ = try std.process.spawn(stdio.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn waitReady(allocator: std.mem.Allocator, options: PreflightOptions) !void {
    var wait_result = try runAdb(allocator, options, &.{"wait-for-device"});
    defer wait_result.deinit(allocator);
    try wait_result.ensureSuccess();

    for (0..120) |_| {
        var prop = try runAdb(allocator, options, &.{ "shell", "getprop", "sys.boot_completed" });
        defer prop.deinit(allocator);
        try prop.ensureSuccess();
        const value = std.mem.trim(u8, prop.stdout, " \t\r\n");
        if (std.mem.eql(u8, value, "1")) return;
        stdio.sleepNs(2 * std.time.ns_per_s);
    }
    return error.AndroidEmulatorBootTimedOut;
}

fn runAdb(allocator: std.mem.Allocator, options: PreflightOptions, extra: []const []const u8) !command.ExecResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.adb_path);
    if (options.device_serial) |serial| {
        try argv.appendSlice(allocator, &.{ "-s", serial });
    }
    try argv.appendSlice(allocator, extra);
    try recordCommand(allocator, options.event_log_path, argv.items);
    return try command.runWithTimeout(allocator, argv.items, 1024 * 1024, default_timeout_ms);
}

fn recordCommand(allocator: std.mem.Allocator, maybe_path: ?[]const u8, argv: []const []const u8) !void {
    const path = maybe_path orelse return;
    const existing = stdio.readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const had_existing_file = existing.ptr != "".ptr;
    defer if (had_existing_file) allocator.free(existing);

    var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
    defer file.close(stdio.io());
    var write_buffer: [8192]u8 = undefined;
    var file_writer = file.writerStreaming(stdio.io(), &write_buffer);
    const writer = &file_writer.interface;
    if (existing.len > 0) try writer.writeAll(existing);

    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try line.append(allocator, ' ');
        try line.appendSlice(allocator, arg);
    }
    try line.append(allocator, '\n');
    try writer.writeAll(line.items);
    try writer.flush();
}
