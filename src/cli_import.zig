const std = @import("std");
const stdio = @import("stdio.zig");

const cli_output = @import("cli_output.zig");
const importer = @import("importer.zig");

pub const ParsedArgs = struct {
    format: []const u8,
    source_path: []const u8,
    out_path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    force: bool = false,
    json: bool = false,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var format: ?[]const u8 = null;
    var source_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;
    var force = false;
    var json = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            out_path = if (index < args.len) args[index] else return error.MissingImportOut;
        } else if (std.mem.eql(u8, arg, "--name")) {
            index += 1;
            name = if (index < args.len) args[index] else return error.MissingImportName;
        } else if (std.mem.eql(u8, arg, "--app-id")) {
            index += 1;
            app_id = if (index < args.len) args[index] else return error.MissingAppId;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.unknownFlag;
        } else if (format == null) {
            format = arg;
        } else if (source_path == null) {
            source_path = arg;
        } else {
            return error.unknownFlag;
        }
    }
    if (format == null) return error.MissingImportFormat;
    if (source_path == null) return error.MissingImportPath;
    if (out_path == null) return error.MissingImportOut;
    return ParsedArgs{
        .format = format.?,
        .source_path = source_path.?,
        .out_path = out_path,
        .name = name,
        .app_id = app_id,
        .force = force,
        .json = json,
    };
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseArgs(raw_args.items);
    if (!std.mem.eql(u8, parsed.format, "flow-yaml")) return error.UnsupportedImportFormat;

    const result = try importer.importFlowYamlFile(allocator, parsed.source_path, parsed.out_path.?, .{
        .name = parsed.name,
        .app_id = parsed.app_id,
        .force = parsed.force,
    });
    defer result.deinit(allocator);

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    if (parsed.json) {
        try cli_output.writeImportJson(stdout, parsed.format, parsed.source_path, result);
    } else {
        try stdout.print("wrote {s}\n", .{result.out_path});
        try stdout.writeAll("next: zmr validate ");
        try cli_output.writeShellArg(stdout, result.out_path);
        try stdout.writeAll("\n");
    }
    try stdout_io.flush();
}
