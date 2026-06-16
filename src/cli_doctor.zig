const std = @import("std");
const stdio = @import("stdio.zig");

const cli_output = @import("cli_output.zig");
const config = @import("config.zig");
const config_paths = @import("config_paths.zig");
const doctor = @import("doctor.zig");

pub const ParsedArgs = struct {
    options: doctor.Options = .{},
    json: bool = false,
    strict: bool = false,
    config_path: ?[]const u8 = null,
    explicit_config: bool = false,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--adb")) {
            index += 1;
            parsed.options.adb_path = if (index < args.len) args[index] else return error.MissingAdbPath;
        } else if (std.mem.eql(u8, arg, "--android-shim")) {
            index += 1;
            parsed.options.android_shim_path = if (index < args.len) args[index] else return error.MissingAndroidShimPath;
        } else if (std.mem.eql(u8, arg, "--xcrun")) {
            index += 1;
            parsed.options.xcrun_path = if (index < args.len) args[index] else return error.MissingXcrunPath;
        } else if (std.mem.eql(u8, arg, "--ios-shim")) {
            index += 1;
            parsed.options.ios_shim_path = if (index < args.len) args[index] else return error.MissingIosShimPath;
        } else if (std.mem.eql(u8, arg, "--zig")) {
            index += 1;
            parsed.options.zig_path = if (index < args.len) args[index] else return error.MissingZigPath;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            parsed.strict = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            parsed.config_path = if (index < args.len) args[index] else return error.MissingConfigPath;
            parsed.explicit_config = true;
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
    try runParsed(allocator, parsed);
}

fn runParsed(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var options = parsed.options;
    const actual_config_path = parsed.config_path orelse config_paths.default_path;
    var config_check: ?doctor.Check = null;
    defer if (config_check) |check| check.deinit(allocator);
    var owned_option_paths = std.ArrayList([]const u8).empty;
    defer {
        for (owned_option_paths.items) |path| allocator.free(path);
        owned_option_paths.deinit(allocator);
    }

    var loaded_config = config_paths.loadIfPresent(allocator, parsed.config_path) catch |err| blk: {
        const field_path = try config.errorFieldPathForFile(allocator, actual_config_path, err);
        defer if (field_path) |value| allocator.free(value);
        config_check = try doctor.checkConfigError(allocator, actual_config_path, err, field_path);
        break :blk null;
    };
    defer if (loaded_config) |*cfg| cfg.deinit(allocator);
    if (loaded_config) |cfg| {
        const config_root = try config_paths.rootForPath(allocator, actual_config_path);
        defer allocator.free(config_root);
        if (parsed.explicit_config) config_check = try doctor.checkConfigLoaded(allocator, actual_config_path, cfg.scripts);
        if (std.mem.eql(u8, options.adb_path, "adb")) {
            if (cfg.tools.adb_path) |path| options.adb_path = try config_paths.ownCommandPath(allocator, &owned_option_paths, config_root, path);
        }
        if (options.android_shim_path == null) {
            if (cfg.tools.android_shim_path) |path| options.android_shim_path = try config_paths.ownFilePath(allocator, &owned_option_paths, config_root, path);
        }
        if (cfg.android.smoke_scenario) |path| options.android_smoke_scenario = try config_paths.ownFilePath(allocator, &owned_option_paths, config_root, path);
        if (std.mem.eql(u8, options.xcrun_path, "xcrun")) {
            if (cfg.tools.xcrun_path) |path| options.xcrun_path = try config_paths.ownCommandPath(allocator, &owned_option_paths, config_root, path);
        }
        if (options.ios_shim_path == null) {
            if (cfg.tools.ios_shim_path) |path| options.ios_shim_path = try config_paths.ownFilePath(allocator, &owned_option_paths, config_root, path);
        }
        if (cfg.ios.smoke_scenario) |path| options.ios_smoke_scenario = try config_paths.ownFilePath(allocator, &owned_option_paths, config_root, path);
        if (std.mem.eql(u8, options.zig_path, "zig")) {
            if (cfg.tools.zig_path) |path| options.zig_path = try config_paths.ownCommandPath(allocator, &owned_option_paths, config_root, path);
        }
    }

    const checks = try doctor.run(allocator, options);
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    if (parsed.json) {
        try cli_output.writeDoctorJson(stdout, config_check, checks);
    } else {
        try cli_output.writeDoctorText(stdout, config_check, checks);
    }
    if (parsed.strict and !cli_output.doctorChecksHealthy(config_check, checks)) std.process.exit(1);
}
