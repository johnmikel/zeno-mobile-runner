const std = @import("std");
const stdio = @import("stdio.zig");

const android = @import("android.zig");
const android_emulator = @import("android_emulator.zig");
const cli_discover = @import("cli_discover.zig");
const cli_output = @import("cli_output.zig");
const config_paths = @import("config_paths.zig");
const ios = @import("ios.zig");
const runner = @import("runner.zig");
const run_options = @import("run_options.zig");
const scenario = @import("scenario.zig");
const trace = @import("trace.zig");

pub const ParsedArgs = struct {
    raw: run_options.RawRunOptions = .{},
    adb_path: []const u8 = "adb",
    emulator_path: []const u8 = "emulator",
    avdmanager_path: []const u8 = "avdmanager",
    xcrun_path: []const u8 = "xcrun",
    adb_path_set: bool = false,
    emulator_path_set: bool = false,
    avdmanager_path_set: bool = false,
    xcrun_path_set: bool = false,
    config_path: ?[]const u8 = null,
    discover_out: ?[]const u8 = null,
    json: bool = false,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--device")) {
            index += 1;
            parsed.raw.serial = if (index < args.len) args[index] else return error.MissingDeviceSerial;
        } else if (std.mem.eql(u8, arg, "--trace-dir")) {
            index += 1;
            parsed.raw.trace_dir = if (index < args.len) args[index] else return error.MissingTraceDir;
        } else if (std.mem.eql(u8, arg, "--app-id")) {
            index += 1;
            parsed.raw.app_id = if (index < args.len) args[index] else return error.MissingAppId;
        } else if (std.mem.eql(u8, arg, "--adb")) {
            index += 1;
            parsed.adb_path = if (index < args.len) args[index] else return error.MissingAdbPath;
            parsed.adb_path_set = true;
        } else if (std.mem.eql(u8, arg, "--emulator")) {
            index += 1;
            parsed.emulator_path = if (index < args.len) args[index] else return error.MissingEmulatorPath;
            parsed.emulator_path_set = true;
        } else if (std.mem.eql(u8, arg, "--avdmanager")) {
            index += 1;
            parsed.avdmanager_path = if (index < args.len) args[index] else return error.MissingAvdmanagerPath;
            parsed.avdmanager_path_set = true;
        } else if (std.mem.eql(u8, arg, "--android-shim")) {
            index += 1;
            parsed.raw.android_shim_path = if (index < args.len) args[index] else return error.MissingAndroidShimPath;
        } else if (std.mem.eql(u8, arg, "--xcrun")) {
            index += 1;
            parsed.xcrun_path = if (index < args.len) args[index] else return error.MissingXcrunPath;
            parsed.xcrun_path_set = true;
        } else if (std.mem.eql(u8, arg, "--ios-shim")) {
            index += 1;
            parsed.raw.ios_shim_path = if (index < args.len) args[index] else return error.MissingIosShimPath;
        } else if (std.mem.eql(u8, arg, "--platform")) {
            index += 1;
            parsed.raw.platform = try parsePlatform(if (index < args.len) args[index] else return error.MissingPlatform);
        } else if (std.mem.eql(u8, arg, "--ios-device-type")) {
            index += 1;
            parsed.raw.ios_device_type = try parseIosDeviceType(if (index < args.len) args[index] else return error.MissingIosDeviceType);
        } else if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            parsed.config_path = if (index < args.len) args[index] else return error.MissingConfigPath;
        } else if (std.mem.eql(u8, arg, "--discover-out")) {
            index += 1;
            parsed.discover_out = if (index < args.len) args[index] else return error.MissingDiscoverOut;
        } else if (std.mem.eql(u8, arg, "--screen-record")) {
            parsed.raw.screen_recording = true;
        } else if (std.mem.eql(u8, arg, "--no-screen-record")) {
            parsed.raw.screen_recording = false;
        } else if (std.mem.eql(u8, arg, "--android-avd")) {
            index += 1;
            parsed.raw.android_avd_name = if (index < args.len) args[index] else return error.MissingAndroidAvdName;
        } else if (std.mem.eql(u8, arg, "--restore-snapshot")) {
            index += 1;
            parsed.raw.android_restore_snapshot = if (index < args.len) args[index] else return error.MissingAndroidSnapshotName;
        } else if (std.mem.eql(u8, arg, "--create-avd-if-missing")) {
            parsed.raw.android_create_avd_if_missing = true;
        } else if (std.mem.eql(u8, arg, "--avd-system-image")) {
            index += 1;
            parsed.raw.android_avd_system_image = if (index < args.len) args[index] else return error.MissingAndroidAvdSystemImage;
        } else if (std.mem.eql(u8, arg, "--avd-device")) {
            index += 1;
            parsed.raw.android_avd_device_profile = if (index < args.len) args[index] else return error.MissingAndroidAvdDeviceProfile;
        } else if (std.mem.eql(u8, arg, "--reset-emulator")) {
            parsed.raw.android_reset_before_run = true;
        } else if (std.mem.eql(u8, arg, "--wait-emulator")) {
            parsed.raw.android_wait_ready = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.unknownFlag;
        } else if (parsed.raw.scenario_path == null) {
            parsed.raw.scenario_path = arg;
        } else {
            return error.unknownFlag;
        }
    }
    return parsed;
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseArgs(raw_args.items);
    const raw = parsed.raw;
    var adb_path = parsed.adb_path;
    var emulator_path = parsed.emulator_path;
    var avdmanager_path = parsed.avdmanager_path;
    var xcrun_path = parsed.xcrun_path;

    const actual_config_path = parsed.config_path orelse config_paths.default_path;
    var owned_config_paths = std.ArrayList([]const u8).empty;
    defer {
        for (owned_config_paths.items) |path| allocator.free(path);
        owned_config_paths.deinit(allocator);
    }
    var config_root: ?[]const u8 = null;
    defer if (config_root) |root| allocator.free(root);

    var loaded_config = try config_paths.loadIfPresent(allocator, parsed.config_path);
    defer if (loaded_config) |*cfg| cfg.deinit(allocator);
    if (loaded_config) |cfg| {
        config_root = try config_paths.rootForPath(allocator, actual_config_path);
        if (!parsed.adb_path_set) {
            if (cfg.tools.adb_path) |path| adb_path = try config_paths.ownCommandPath(allocator, &owned_config_paths, config_root.?, path);
        }
        if (!parsed.emulator_path_set) {
            if (cfg.tools.emulator_path) |path| emulator_path = try config_paths.ownCommandPath(allocator, &owned_config_paths, config_root.?, path);
        }
        if (!parsed.avdmanager_path_set) {
            if (cfg.tools.avdmanager_path) |path| avdmanager_path = try config_paths.ownCommandPath(allocator, &owned_config_paths, config_root.?, path);
        }
        if (!parsed.xcrun_path_set) {
            if (cfg.tools.xcrun_path) |path| xcrun_path = try config_paths.ownCommandPath(allocator, &owned_config_paths, config_root.?, path);
        }
    }
    const resolved = if (loaded_config) |cfg| run_options.resolveRun(raw, cfg) else run_options.resolveRun(raw, null);
    var capture = if (loaded_config) |cfg| run_options.traceCapture(cfg) else trace.CaptureOptions{};
    if (raw.screen_recording) |enabled| capture.capture_screen_recording = enabled;
    const scenario_path = if (raw.scenario_path == null and config_root != null and resolved.scenario_path != null)
        try config_paths.ownFilePath(allocator, &owned_config_paths, config_root.?, resolved.scenario_path.?)
    else
        resolved.scenario_path orelse return error.MissingScenarioPath;
    const trace_dir = if (raw.trace_dir == null and config_root != null and resolved.trace_dir != null)
        try config_paths.ownFilePath(allocator, &owned_config_paths, config_root.?, resolved.trace_dir.?)
    else
        resolved.trace_dir;
    if (parsed.discover_out != null and trace_dir == null) return error.MissingTraceDir;
    const android_shim_path = if (raw.android_shim_path == null and config_root != null and resolved.android_shim_path != null)
        try config_paths.ownFilePath(allocator, &owned_config_paths, config_root.?, resolved.android_shim_path.?)
    else
        resolved.android_shim_path;
    const ios_shim_path = if (raw.ios_shim_path == null and config_root != null and resolved.ios_shim_path != null)
        try config_paths.ownFilePath(allocator, &owned_config_paths, config_root.?, resolved.ios_shim_path.?)
    else
        resolved.ios_shim_path;

    const script = try scenario.parseFile(allocator, scenario_path);
    defer script.deinit(allocator);
    const app_id = if (raw.app_id) |_| resolved.app_id else script.app_id orelse resolved.app_id;

    const run_error: ?anyerror = blk: {
        switch (resolved.platform) {
            .android => {
                if (run_options.androidPreflight(resolved, adb_path, emulator_path, avdmanager_path)) |preflight| {
                    try android_emulator.runPreflight(allocator, preflight);
                }
                var device = try android.AndroidDevice.initWithShim(allocator, adb_path, resolved.serial, app_id, android_shim_path);
                defer device.deinit();
                runAndroidWithTrace(allocator, &device, script, trace_dir, capture) catch |err| break :blk err;
            },
            .ios => {
                var device = try ios.IosDevice.initWithKindAndShim(allocator, xcrun_path, resolved.serial, app_id, iosTargetKind(resolved.ios_device_type), ios_shim_path);
                defer device.deinit();
                runWithTrace(allocator, &device, script, trace_dir, capture) catch |err| break :blk err;
            },
        }
        break :blk null;
    };

    var discovery_payload: std.Io.Writer.Allocating = .init(allocator);
    defer discovery_payload.deinit();
    var run_discovery = cli_output.RunDiscovery{};
    if (parsed.discover_out) |out_path| {
        if (cli_discover.discoverFromTrace(allocator, .{
            .from_trace = trace_dir,
            .out_path = out_path,
            .include_actions = true,
            .validate = true,
            .force = true,
            .json = true,
        })) |discovered_value| {
            var discovered = discovered_value;
            defer discovered.deinit(allocator);
            try cli_discover.writeJson(&discovery_payload.writer, discovered.summary, discovered.validation);
            run_discovery = .{ .json = std.mem.trimEnd(u8, discovery_payload.writer.buffered(), " \t\r\n") };
        } else |err| {
            run_discovery = .{ .error_name = @errorName(err) };
        }
    }

    if (parsed.json) {
        var stdout_io: stdio.Output = .{};
        stdout_io.init(.stdout());
        defer stdout_io.deinit();
        try cli_output.writeRunSummaryJson(
            allocator,
            stdout_io.writer(),
            trace_dir,
            script.name,
            app_id,
            run_error,
            run_discovery,
        );
    }
    if (run_error) |err| return err;
}

fn runAndroidWithTrace(
    allocator: std.mem.Allocator,
    device: *android.AndroidDevice,
    script: scenario.Scenario,
    trace_dir: ?[]const u8,
    capture: trace.CaptureOptions,
) !void {
    if (trace_dir == null or !capture.capture_screen_recording) {
        return try runWithTrace(allocator, device, script, trace_dir, capture);
    }

    var trace_writer = try trace.TraceWriter.initWithOptions(allocator, trace_dir.?, capture);
    defer trace_writer.deinit();

    var recording = device.startScreenRecording("/sdcard/zmr-trace-screenrecord.mp4") catch null;
    defer if (recording) |*rec| {
        if (rec.stopAndPull(&trace_writer, "screenrecord.mp4")) |artifact_path| {
            allocator.free(artifact_path);
            trace_writer.recordEvent("trace.screenRecording", "{\"artifact\":\"artifacts/screenrecord.mp4\"}") catch {};
        } else |_| {}
        rec.deinit();
    };

    return try runner.runScenario(allocator, device, script, &trace_writer, .{});
}

fn runWithTrace(
    allocator: std.mem.Allocator,
    device: anytype,
    script: scenario.Scenario,
    trace_dir: ?[]const u8,
    capture: trace.CaptureOptions,
) !void {
    var trace_writer: ?trace.TraceWriter = null;
    if (trace_dir) |dir| {
        trace_writer = try trace.TraceWriter.initWithOptions(allocator, dir, capture);
    }
    defer if (trace_writer) |*tw| tw.deinit();

    if (trace_writer) |*tw| return try runner.runScenario(allocator, device, script, tw, .{});
    return try runner.runScenario(allocator, device, script, null, .{});
}

pub fn parsePlatform(value: []const u8) !run_options.Platform {
    if (std.mem.eql(u8, value, "android")) return .android;
    if (std.mem.eql(u8, value, "ios")) return .ios;
    return error.UnsupportedPlatform;
}

fn parseIosDeviceType(value: []const u8) !run_options.IosDeviceType {
    if (std.mem.eql(u8, value, "simulator")) return .simulator;
    if (std.mem.eql(u8, value, "physical")) return .physical;
    return error.UnsupportedIosDeviceType;
}

fn iosTargetKind(value: run_options.IosDeviceType) ios.TargetKind {
    return switch (value) {
        .simulator => .simulator,
        .physical => .physical,
    };
}
