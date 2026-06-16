const std = @import("std");
const stdio = @import("stdio.zig");
const android = @import("android.zig");
const command = @import("command.zig");
const config = @import("config.zig");
const doctor_hints = @import("doctor_hints.zig");
const ios = @import("ios.zig");
const types = @import("types.zig");
const validation = @import("validation.zig");

pub const Status = doctor_hints.Status;

pub const Check = struct {
    name: []const u8,
    status: Status,
    detail: []const u8,
    error_code: ?[]const u8 = null,
    field_path: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    count: ?usize = null,
    ready_count: ?usize = null,
    script_count: ?usize = null,
    script_names: ?[]const []const u8 = null,

    pub fn deinit(self: Check, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.detail);
        if (self.error_code) |error_code| allocator.free(error_code);
        if (self.field_path) |field_path| allocator.free(field_path);
        if (self.hint) |hint| allocator.free(hint);
        if (self.script_names) |script_names| freeStringList(allocator, script_names);
    }
};

pub const Options = struct {
    zig_path: []const u8 = "zig",
    adb_path: []const u8 = "adb",
    android_shim_path: ?[]const u8 = null,
    android_smoke_scenario: ?[]const u8 = null,
    xcrun_path: []const u8 = "xcrun",
    ios_shim_path: ?[]const u8 = null,
    ios_smoke_scenario: ?[]const u8 = null,
};

pub fn checkConfigLoaded(allocator: std.mem.Allocator, path: []const u8, scripts: []const config.ScriptCommand) !Check {
    const name = try allocator.dupe(u8, "config");
    errdefer allocator.free(name);
    const detail = try allocator.dupe(u8, path);
    errdefer allocator.free(detail);
    const script_names = try duplicateScriptNames(allocator, scripts);
    errdefer freeStringList(allocator, script_names);

    return .{
        .name = name,
        .status = .ok,
        .detail = detail,
        .script_count = scripts.len,
        .script_names = script_names,
    };
}

fn duplicateScriptNames(allocator: std.mem.Allocator, scripts: []const config.ScriptCommand) ![]const []const u8 {
    if (scripts.len == 0) return &.{};

    var names = try allocator.alloc([]const u8, scripts.len);
    errdefer allocator.free(names);
    var written: usize = 0;
    errdefer {
        for (names[0..written]) |name| allocator.free(name);
    }

    for (scripts, 0..) |script, index| {
        names[index] = try allocator.dupe(u8, script.name);
        written += 1;
    }
    return names;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub fn checkConfigError(allocator: std.mem.Allocator, path: []const u8, err: anyerror, field_path: ?[]const u8) !Check {
    const status: Status = if (err == error.FileNotFound) .missing else .warning;
    return .{
        .name = try allocator.dupe(u8, "config"),
        .status = status,
        .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ path, @errorName(err) }),
        .error_code = try allocator.dupe(u8, configErrorCode(err)),
        .field_path = if (field_path) |value| try allocator.dupe(u8, value) else null,
        .hint = try doctor_hints.hintForCheck(allocator, "config", status),
    };
}

fn configErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "config.file_not_found",
        error.ConfigMustBeObject => "config.must_be_object",
        error.MissingConfigSchemaVersion => "config.missing_schema_version",
        error.ConfigSchemaVersionMustBeInteger => "config.schema_version_type",
        error.UnsupportedConfigVersion => "config.unsupported_version",
        error.ConfigUnknownField => "config.unknown_field",
        error.ConfigPlatformMustBeObject,
        error.ConfigToolsMustBeObject,
        error.ConfigArtifactsMustBeObject,
        error.ConfigRedactionMustBeObject,
        error.ConfigScriptsMustBeObject,
        error.ConfigFieldMustBeBool,
        error.ConfigFieldMustBeString,
        error.ConfigFieldMustBeStringArray,
        => "config.field_type",
        error.ConfigFieldMustBeNonEmptyString => "config.empty_string",
        else => "config.invalid",
    };
}

pub fn run(allocator: std.mem.Allocator, options: Options) ![]Check {
    var checks = std.ArrayList(Check).empty;
    errdefer {
        for (checks.items) |check| check.deinit(allocator);
        checks.deinit(allocator);
    }

    try checks.append(allocator, try checkCommand(allocator, "zig", &.{ options.zig_path, "version" }));
    try checks.append(allocator, try checkCommand(allocator, "adb", &.{ options.adb_path, "version" }));
    try checks.append(allocator, try checkAndroidDevices(allocator, options.adb_path));
    if (options.android_shim_path) |path| try checks.append(allocator, try checkPath(allocator, "android-shim", path));
    if (options.android_smoke_scenario) |path| try checks.append(allocator, try checkScenarioPath(allocator, "android-smoke-scenario", path));
    try checks.append(allocator, try checkCommand(allocator, "xcrun", &.{ options.xcrun_path, "--version" }));
    try checks.append(allocator, try checkIosSimulators(allocator, options.xcrun_path));
    try checks.append(allocator, try checkIosPhysicalDevices(allocator, options.xcrun_path));
    if (options.ios_shim_path) |path| try checks.append(allocator, try checkPath(allocator, "ios-shim", path));
    if (options.ios_smoke_scenario) |path| try checks.append(allocator, try checkScenarioPath(allocator, "ios-smoke-scenario", path));

    return try checks.toOwnedSlice(allocator);
}

fn checkPath(allocator: std.mem.Allocator, name: []const u8, path: []const u8) !Check {
    stdio.accessWithOptions(path, .{ .read = true }) catch |err| {
        return .{
            .name = try allocator.dupe(u8, name),
            .status = .missing,
            .error_code = try allocator.dupe(u8, doctor_hints.setupErrorCode(name, .missing)),
            .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ path, @errorName(err) }),
            .hint = try doctor_hints.hintForCheck(allocator, name, .missing),
        };
    };
    return .{
        .name = try allocator.dupe(u8, name),
        .status = .ok,
        .detail = try allocator.dupe(u8, path),
    };
}

fn checkScenarioPath(allocator: std.mem.Allocator, name: []const u8, path: []const u8) !Check {
    const result = try validation.validateFile(allocator, path);
    defer result.deinit(allocator);

    if (result.ok) {
        return .{
            .name = try allocator.dupe(u8, name),
            .status = .ok,
            .detail = try std.fmt.allocPrint(allocator, "{s}: ok ({s}, {d} steps)", .{ path, result.name.?, result.step_count }),
        };
    }

    const status: Status = if (result.error_code != null and std.mem.eql(u8, result.error_code.?, "scenario.file_not_found")) .missing else .warning;
    const code = result.error_code orelse "scenario.invalid";
    return .{
        .name = try allocator.dupe(u8, name),
        .status = status,
        .detail = try scenarioValidationDetail(allocator, path, result),
        .error_code = try allocator.dupe(u8, code),
        .hint = try doctor_hints.hintForCheck(allocator, name, status),
    };
}

fn scenarioValidationDetail(allocator: std.mem.Allocator, path: []const u8, result: validation.Result) ![]const u8 {
    const code = result.error_code orelse "scenario.invalid";
    const message = result.message orelse "scenario is invalid";
    if (result.path) |field_path| {
        if (result.line) |line| {
            if (result.column) |column| {
                return try std.fmt.allocPrint(allocator, "{s}: invalid [{s}] {s} at {s} line {d} column {d}", .{ path, code, message, field_path, line, column });
            }
        }
        return try std.fmt.allocPrint(allocator, "{s}: invalid [{s}] {s} at {s}", .{ path, code, message, field_path });
    }
    if (result.line) |line| {
        if (result.column) |column| {
            return try std.fmt.allocPrint(allocator, "{s}: invalid [{s}] {s} line {d} column {d}", .{ path, code, message, line, column });
        }
    }
    return try std.fmt.allocPrint(allocator, "{s}: invalid [{s}] {s}", .{ path, code, message });
}

fn checkAndroidDevices(allocator: std.mem.Allocator, adb_path: []const u8) !Check {
    const devices = android.listDevices(allocator, adb_path) catch |err| {
        return .{
            .name = try allocator.dupe(u8, "android-devices"),
            .status = .missing,
            .error_code = try allocator.dupe(u8, "setup.android.devices_unavailable"),
            .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ adb_path, @errorName(err) }),
            .hint = try doctor_hints.hintForCheck(allocator, "android-devices", .missing),
        };
    };
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }
    if (devices.len == 0) {
        return .{
            .name = try allocator.dupe(u8, "android-devices"),
            .status = .warning,
            .error_code = try allocator.dupe(u8, "setup.android.no_devices"),
            .detail = try allocator.dupe(u8, "0 Android device(s)"),
            .hint = try doctor_hints.hintForCheck(allocator, "android-devices", .warning),
            .count = 0,
            .ready_count = 0,
        };
    }
    return .{
        .name = try allocator.dupe(u8, "android-devices"),
        .status = .ok,
        .detail = try std.fmt.allocPrint(allocator, "{d} Android device(s)", .{devices.len}),
        .count = devices.len,
        .ready_count = devices.len,
    };
}

fn checkIosSimulators(allocator: std.mem.Allocator, xcrun_path: []const u8) !Check {
    const devices = ios.listDevices(allocator, xcrun_path) catch |err| {
        return .{
            .name = try allocator.dupe(u8, "ios-simulators"),
            .status = .missing,
            .error_code = try allocator.dupe(u8, "setup.ios.simulators_unavailable"),
            .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ xcrun_path, @errorName(err) }),
            .hint = try doctor_hints.hintForCheck(allocator, "ios-simulators", .missing),
        };
    };
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }
    if (devices.len == 0) {
        return .{
            .name = try allocator.dupe(u8, "ios-simulators"),
            .status = .warning,
            .error_code = try allocator.dupe(u8, "setup.ios.no_booted_simulators"),
            .detail = try allocator.dupe(u8, "0 booted iOS simulator(s)"),
            .hint = try doctor_hints.hintForCheck(allocator, "ios-simulators", .warning),
            .count = 0,
            .ready_count = 0,
        };
    }
    return .{
        .name = try allocator.dupe(u8, "ios-simulators"),
        .status = .ok,
        .detail = try std.fmt.allocPrint(allocator, "{d} booted iOS simulator(s)", .{devices.len}),
        .count = devices.len,
        .ready_count = devices.len,
    };
}

fn checkIosPhysicalDevices(allocator: std.mem.Allocator, xcrun_path: []const u8) !Check {
    const devices = ios.listPhysicalDevices(allocator, xcrun_path) catch |err| {
        return .{
            .name = try allocator.dupe(u8, "ios-physical-devices"),
            .status = .missing,
            .error_code = try allocator.dupe(u8, "setup.ios.physical_devices_unavailable"),
            .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ xcrun_path, @errorName(err) }),
            .hint = try doctor_hints.hintForCheck(allocator, "ios-physical-devices", .missing),
        };
    };
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }
    if (devices.len == 0) {
        return .{
            .name = try allocator.dupe(u8, "ios-physical-devices"),
            .status = .warning,
            .error_code = try allocator.dupe(u8, "setup.ios.no_physical_devices"),
            .detail = try allocator.dupe(u8, "0 physical iOS device(s)"),
            .hint = try doctor_hints.hintForCheck(allocator, "ios-physical-devices", .warning),
            .count = 0,
            .ready_count = 0,
        };
    }
    var ready_count: usize = 0;
    for (devices) |device| {
        if (isReadyPhysicalDeviceState(device.state)) ready_count += 1;
    }
    if (ready_count == 0) {
        const breakdown = try physicalStateBreakdown(allocator, devices);
        defer allocator.free(breakdown);
        return .{
            .name = try allocator.dupe(u8, "ios-physical-devices"),
            .status = .warning,
            .error_code = try allocator.dupe(u8, "setup.ios.no_ready_physical_devices"),
            .detail = try std.fmt.allocPrint(allocator, "0 ready physical iOS device(s); {d} listed{s}", .{ devices.len, breakdown }),
            .hint = try doctor_hints.hintForCheck(allocator, "ios-physical-devices", .warning),
            .count = devices.len,
            .ready_count = 0,
        };
    }
    if (ready_count < devices.len) {
        const breakdown = try physicalStateBreakdown(allocator, devices);
        defer allocator.free(breakdown);
        return .{
            .name = try allocator.dupe(u8, "ios-physical-devices"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(allocator, "{d} ready physical iOS device(s); {d} listed{s}", .{ ready_count, devices.len, breakdown }),
            .count = devices.len,
            .ready_count = ready_count,
        };
    }
    return .{
        .name = try allocator.dupe(u8, "ios-physical-devices"),
        .status = .ok,
        .detail = try std.fmt.allocPrint(allocator, "{d} ready physical iOS device(s)", .{ready_count}),
        .count = devices.len,
        .ready_count = ready_count,
    };
}

fn isReadyPhysicalDeviceState(state: []const u8) bool {
    return std.mem.eql(u8, state, "connected") or std.mem.eql(u8, state, "available");
}

fn physicalStateBreakdown(allocator: std.mem.Allocator, devices: []const types.DeviceInfo) ![]const u8 {
    var disconnected: usize = 0;
    var paired: usize = 0;
    var unavailable: usize = 0;
    var other: usize = 0;

    for (devices) |device| {
        if (std.mem.eql(u8, device.state, "disconnected")) {
            disconnected += 1;
        } else if (std.mem.eql(u8, device.state, "paired")) {
            paired += 1;
        } else if (std.mem.eql(u8, device.state, "unavailable")) {
            unavailable += 1;
        } else if (!isReadyPhysicalDeviceState(device.state)) {
            other += 1;
        }
    }

    var parts: std.Io.Writer.Allocating = .init(allocator);
    defer parts.deinit();
    const writer = &parts.writer;
    var wrote = false;
    if (disconnected > 0) {
        try writer.print("disconnected={d}", .{disconnected});
        wrote = true;
    }
    if (paired > 0) {
        if (wrote) try writer.writeAll(", ");
        try writer.print("paired={d}", .{paired});
        wrote = true;
    }
    if (unavailable > 0) {
        if (wrote) try writer.writeAll(", ");
        try writer.print("unavailable={d}", .{unavailable});
        wrote = true;
    }
    if (other > 0) {
        if (wrote) try writer.writeAll(", ");
        try writer.print("other={d}", .{other});
        wrote = true;
    }

    if (!wrote) return try allocator.dupe(u8, "");
    return try std.fmt.allocPrint(allocator, " ({s})", .{parts.writer.buffered()});
}

pub fn checkCommand(allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8) !Check {
    const result = command.run(allocator, argv, 1024 * 1024) catch |err| {
        return .{
            .name = try allocator.dupe(u8, name),
            .status = .missing,
            .error_code = try allocator.dupe(u8, doctor_hints.setupErrorCode(name, .missing)),
            .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ argv[0], @errorName(err) }),
            .hint = try doctor_hints.hintForCheck(allocator, name, .missing),
        };
    };
    defer result.deinit(allocator);

    if (result.term == .exited and result.term.exited == 0) {
        return .{
            .name = try allocator.dupe(u8, name),
            .status = .ok,
            .detail = try firstLine(allocator, result.stdout),
        };
    }

    const code = if (result.term == .exited) result.term.exited else 255;
    return .{
        .name = try allocator.dupe(u8, name),
        .status = .warning,
        .error_code = try allocator.dupe(u8, doctor_hints.setupErrorCode(name, .warning)),
        .detail = try std.fmt.allocPrint(allocator, "exit {d}: {s}", .{ code, std.mem.trim(u8, result.stderr, " \t\r\n") }),
        .hint = try doctor_hints.hintForCheck(allocator, name, .warning),
    };
}

fn firstLine(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return try allocator.dupe(u8, trimmed[0..end]);
}
