const std = @import("std");
const stdio = @import("stdio.zig");
const trace = @import("trace.zig");

pub const Transport = enum {
    stdio,
    tcp,
};

pub const ParsedArgs = struct {
    trace_dir: []const u8,
    transport: Transport = .stdio,
    port: u16 = 7788,
    json: bool = false,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{ .trace_dir = "" };
    var trace_dir: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--trace-dir")) {
            index += 1;
            trace_dir = if (index < args.len) args[index] else return error.MissingRecordTraceDir;
        } else if (std.mem.eql(u8, arg, "--transport")) {
            index += 1;
            const value = if (index < args.len) args[index] else return error.MissingRecordTransport;
            parsed.transport = if (std.mem.eql(u8, value, "stdio")) .stdio else if (std.mem.eql(u8, value, "tcp")) .tcp else return error.InvalidRecordTransport;
        } else if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            const value = if (index < args.len) args[index] else return error.MissingRecordPort;
            parsed.port = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidRecordPort;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.unknownFlag;
        } else if (trace_dir == null) {
            trace_dir = arg;
        } else {
            return error.unknownFlag;
        }
    }
    parsed.trace_dir = trace_dir orelse return error.MissingRecordTraceDir;
    return parsed;
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);
    const parsed = try parseArgs(raw_args.items);

    // Record is intentionally non-destructive: an existing trace directory is
    // preserved so agents can resume or export it after a server session.
    try std.Io.Dir.cwd().createDirPath(stdio.io(), parsed.trace_dir);

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const writer = stdout_io.writer();
    if (parsed.json) {
        try writer.writeAll("{\"mode\":\"record\",\"traceDir\":");
        try trace.writeJsonString(writer, parsed.trace_dir);
        try writer.writeAll(",\"transport\":");
        try trace.writeJsonString(writer, @tagName(parsed.transport));
        try writer.writeAll(",\"port\":");
        try writer.print("{d}", .{parsed.port});
        try writer.writeAll(",\"serveCommand\":");
        try trace.writeJsonString(writer, if (parsed.transport == .tcp) "zmr serve --transport tcp" else "zmr serve --transport stdio");
        try writer.writeAll(",\"next\":{\"discover\":\"zmr discover --from-trace <trace-dir> --out <scenario.json> --validate\",\"draft\":\"zmr draft --from-trace <trace-dir> --out <scenario.json>\",\"explain\":\"zmr explain <trace-dir> --json\"}}\n");
    } else {
        try writer.print("recording workspace ready at {s}\n", .{parsed.trace_dir});
        try writer.writeAll("start the protocol with `zmr serve --trace-dir ");
        try writer.writeAll(parsed.trace_dir);
        try writer.writeAll("` or `zmr mcp --trace-dir ");
        try writer.writeAll(parsed.trace_dir);
        try writer.writeAll("`, then use `zmr discover --from-trace ");
        try writer.writeAll(parsed.trace_dir);
        try writer.writeAll(" --out <scenario.json> --validate`.\n");
    }
    try stdout_io.flush();
}
