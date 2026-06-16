const std = @import("std");
const stdio = @import("stdio.zig");

const cli_output = @import("cli_output.zig");
const scaffold = @import("scaffold.zig");

pub const ParsedArgs = struct {
    path: []const u8 = "zmr-scenario.json",
    dir: []const u8 = ".",
    app_id: []const u8 = "com.example.mobiletest",
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

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseArgs(raw_args.items);
    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    if (parsed.app_scaffold) {
        try scaffold.writeAppScaffold(allocator, parsed.dir, parsed.app_id, parsed.force);
        if (parsed.json) return try cli_output.writeInitAppJson(stdout, parsed.dir, parsed.app_id);
        for (scaffold.app_created_files) |path| {
            try stdout.print("created {s}/{s}\n", .{ parsed.dir, path });
        }
        try stdout.writeAll("next: zmr doctor --strict --json --config ");
        try cli_output.writeJoinedPathShellArg(stdout, parsed.dir, scaffold.app_config_file);
        try stdout.writeAll("\n");
        return;
    }

    try scaffold.writeStarterScenario(allocator, parsed.path, parsed.app_id, parsed.force);
    if (parsed.json) return try cli_output.writeInitScenarioJson(stdout, parsed.path, parsed.app_id);
    try stdout.print("created {s}\n", .{parsed.path});
    try stdout.writeAll("next: zmr validate ");
    try cli_output.writeShellArg(stdout, parsed.path);
    try stdout.writeAll("\n");
}
