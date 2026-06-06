const std = @import("std");

const bundle = @import("bundle.zig");
const report = @import("report.zig");

pub const ReportArgs = struct {
    input_path: []const u8,
    out_path: ?[]const u8 = null,
    junit_path: ?[]const u8 = null,
};

pub const ExplainArgs = struct {
    trace_dir: ?[]const u8 = null,
    json: bool = false,
};

pub const ExportArgs = struct {
    trace_dir: []const u8,
    out_path: ?[]const u8 = null,
    redact: bool = false,
    omit_screenshots: bool = false,
};

pub fn parseReportArgs(args: []const []const u8) !ReportArgs {
    if (args.len == 0) return error.MissingReportInput;
    var parsed = ReportArgs{ .input_path = args[0] };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            parsed.out_path = if (index < args.len) args[index] else return error.MissingReportOutput;
        } else if (std.mem.eql(u8, arg, "--junit")) {
            index += 1;
            parsed.junit_path = if (index < args.len) args[index] else return error.MissingJUnitOutput;
        } else {
            return error.UnknownFlag;
        }
    }
    if (parsed.out_path == null) return error.MissingReportOutput;
    return parsed;
}

pub fn parseExplainArgs(args: []const []const u8) !ExplainArgs {
    var parsed = ExplainArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (parsed.trace_dir == null) {
            parsed.trace_dir = arg;
        } else {
            return error.UnknownFlag;
        }
    }
    if (parsed.trace_dir == null) return error.MissingTraceDir;
    return parsed;
}

pub fn parseExportArgs(args: []const []const u8) !ExportArgs {
    if (args.len == 0) return error.MissingTraceDir;
    var parsed = ExportArgs{ .trace_dir = args[0] };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            parsed.out_path = if (index < args.len) args[index] else return error.MissingTraceBundleOutput;
        } else if (std.mem.eql(u8, arg, "--redact")) {
            parsed.redact = true;
        } else if (std.mem.eql(u8, arg, "--omit-screenshots")) {
            parsed.redact = true;
            parsed.omit_screenshots = true;
        } else {
            return error.UnknownFlag;
        }
    }
    if (parsed.out_path == null) return error.MissingTraceBundleOutput;
    return parsed;
}

pub fn runReport(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseReportArgs(raw_args.items);
    try report.writeHtmlReport(allocator, parsed.input_path, parsed.out_path.?);
    try std.fs.File.stdout().deprecatedWriter().print("wrote {s}\n", .{parsed.out_path.?});
    if (parsed.junit_path) |junit_path| {
        try report.writeJUnitReport(allocator, parsed.input_path, junit_path);
        try std.fs.File.stdout().deprecatedWriter().print("wrote {s}\n", .{junit_path});
    }
}

pub fn runExplain(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseExplainArgs(raw_args.items);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (parsed.json) return try report.writeTraceExplanationJson(allocator, parsed.trace_dir.?, stdout);
    try report.writeTraceExplanation(allocator, parsed.trace_dir.?, stdout);
}

pub fn runExport(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseExportArgs(raw_args.items);
    try bundle.exportTraceBundleWithOptions(allocator, parsed.trace_dir, parsed.out_path.?, .{
        .redact = parsed.redact,
        .omit_screenshots = parsed.omit_screenshots,
    });
    try std.fs.File.stdout().deprecatedWriter().print("wrote {s}\n", .{parsed.out_path.?});
}
