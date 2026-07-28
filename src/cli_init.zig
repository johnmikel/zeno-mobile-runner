const std = @import("std");
const stdio = @import("stdio.zig");

const cli_output = @import("cli_output.zig");
const scaffold = @import("scaffold.zig");

pub const ParsedArgs = struct {
    path: []const u8 = "zmr-scenario.json",
    dir: []const u8 = ".",
    app_id: []const u8 = "com.example.mobiletest",
    /// Whether --app-id was supplied. `init --app` must not fall back to the
    /// example id: it writes the id into config.json and both smoke scenarios,
    /// so a silent default makes every later run target the example app. If
    /// that app happens to be installed, the run passes and the trace records
    /// evidence from an application the user never asked about.
    app_id_set: bool = false,
    app_scaffold: bool = false,
    force: bool = false,
    json: bool = false,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var path_set = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--app-id")) {
            index += 1;
            parsed.app_id = if (index < args.len) args[index] else return error.MissingAppId;
            parsed.app_id_set = true;
        } else if (std.mem.eql(u8, arg, "--app")) {
            parsed.app_scaffold = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            parsed.dir = if (index < args.len) args[index] else return error.MissingDirectory;
        } else if (std.mem.eql(u8, arg, "--force")) {
            parsed.force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.unknownFlag;
        } else if (parsed.app_scaffold) {
            return error.unknownFlag;
        } else if (!path_set) {
            parsed.path = arg;
            path_set = true;
        } else {
            return error.unknownFlag;
        }
    }
    return parsed;
}

/// Read the app's bundle id out of an Expo `app.json`, so the common case needs
/// no flag. Returns null when the file is missing, unreadable, not the expected
/// shape, or simply has no id yet — a fresh `create-expo-app` project has no
/// `ios.bundleIdentifier` until `expo prebuild` runs.
pub fn deriveExpoAppId(allocator: std.mem.Allocator, dir: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, "app.json" });
    defer allocator.free(path);

    const content = stdio.readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const expo = parsed.value.object.get("expo") orelse return null;
    if (expo != .object) return null;

    // iOS first: ZMR's iOS path is the one that needs an exact bundle id.
    if (expo.object.get("ios")) |ios| {
        if (ios == .object) {
            if (ios.object.get("bundleIdentifier")) |value| {
                if (value == .string and value.string.len > 0) {
                    return try allocator.dupe(u8, value.string);
                }
            }
        }
    }
    if (expo.object.get("android")) |android| {
        if (android == .object) {
            if (android.object.get("package")) |value| {
                if (value == .string and value.string.len > 0) {
                    return try allocator.dupe(u8, value.string);
                }
            }
        }
    }
    return null;
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    var parsed = try parseArgs(raw_args.items);
    var derived_app_id: ?[]const u8 = null;
    defer if (derived_app_id) |id| allocator.free(id);
    if (parsed.app_scaffold and !parsed.app_id_set) {
        derived_app_id = try deriveExpoAppId(allocator, parsed.dir);
        parsed.app_id = derived_app_id orelse return error.AppIdRequired;
    }

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    if (parsed.app_scaffold) {
        try scaffold.writeAppScaffold(allocator, parsed.dir, parsed.app_id, parsed.force);
        if (parsed.json) {
            try cli_output.writeInitAppJson(stdout, parsed.dir, parsed.app_id);
        } else {
            for (scaffold.app_created_files) |path| {
                try stdout.print("created {s}/{s}\n", .{ parsed.dir, path });
            }
            try stdout.writeAll("next: zmr doctor --strict --json --config ");
            try cli_output.writeJoinedPathShellArg(stdout, parsed.dir, scaffold.app_config_file);
            try stdout.writeAll("\n");
        }
        try stdout_io.flush();
        return;
    }

    try scaffold.writeStarterScenario(allocator, parsed.path, parsed.app_id, parsed.force);
    if (parsed.json) {
        try cli_output.writeInitScenarioJson(stdout, parsed.path, parsed.app_id);
    } else {
        try stdout.print("created {s}\n", .{parsed.path});
        try stdout.writeAll("next: zmr validate ");
        try cli_output.writeShellArg(stdout, parsed.path);
        try stdout.writeAll("\n");
    }
    try stdout_io.flush();
}
