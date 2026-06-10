const std = @import("std");

const cli_output = @import("cli_output.zig");
const validation = @import("validation.zig");

pub const ParsedArgs = struct {
    path: []const u8,
    json: bool = false,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var path: ?[]const u8 = null;
    var json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        } else if (path == null) {
            path = arg;
        } else {
            return error.UnknownFlag;
        }
    }
    return ParsedArgs{
        .path = path orelse return error.MissingScenarioPath,
        .json = json,
    };
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseArgs(raw_args.items);
    const result = try validation.validateFile(allocator, parsed.path);
    defer result.deinit(allocator);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (parsed.json) {
        try cli_output.writeValidationJson(stdout, parsed.path, result);
    } else {
        try cli_output.writeValidationText(stdout, parsed.path, result);
    }
    if (!result.ok) std.process.exit(1);
}
