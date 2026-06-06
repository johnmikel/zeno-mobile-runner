const std = @import("std");
const bundle = @import("bundle.zig");
const cli_discover = @import("cli_discover.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const runner_events = @import("runner_events.zig");
const trace = @import("trace.zig");

pub fn writeEventsToolResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    live_trace: ?*trace.TraceWriter,
    after_seq: u64,
    limit: u64,
) !void {
    const tw = live_trace orelse {
        try mcp_protocol.writeToolTextResult(writer, id, "{\"traceDir\":null,\"events\":[]}");
        return;
    };

    const events_path = try std.fs.path.join(allocator, &.{ tw.root_dir, "events.jsonl" });
    defer allocator.free(events_path);
    const content = std.fs.cwd().readFileAlloc(allocator, events_path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    const payload_writer = payload.writer(allocator);
    try payload_writer.writeAll("{\"traceDir\":");
    try trace.writeJsonString(payload_writer, tw.root_dir);
    try payload_writer.print(",\"afterSeq\":{d},\"events\":[", .{after_seq});
    var emitted: u64 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        if (emitted >= limit) break;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const seq_value = parsed.value.object.get("seq") orelse continue;
        if (seq_value != .integer or seq_value.integer <= 0) continue;
        const seq = @as(u64, @intCast(seq_value.integer));
        if (seq <= after_seq) continue;
        if (emitted > 0) try payload_writer.writeAll(",");
        try payload_writer.writeAll(line);
        emitted += 1;
    }
    try payload_writer.writeAll("]}");
    try mcp_protocol.writeToolTextResult(writer, id, payload.items);
}

pub fn writeExportToolResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    live_trace: ?*trace.TraceWriter,
    out_path: []const u8,
    redact: bool,
    omit_screenshots: bool,
) !void {
    const tw = live_trace orelse {
        try mcp_protocol.writeToolTextResult(writer, id, "{\"traceDir\":null,\"message\":\"start zmr mcp with --trace-dir to enable export\"}");
        return;
    };

    try tw.flushManifest();
    try bundle.exportTraceBundleWithOptions(allocator, tw.root_dir, out_path, .{
        .redact = redact,
        .omit_screenshots = omit_screenshots,
    });

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    const payload_writer = payload.writer(allocator);
    try payload_writer.writeAll("{\"traceDir\":");
    try trace.writeJsonString(payload_writer, tw.root_dir);
    try payload_writer.writeAll(",\"out\":");
    try trace.writeJsonString(payload_writer, out_path);
    try payload_writer.print(",\"redacted\":{},\"omitScreenshots\":{}}}", .{ redact, omit_screenshots });
    try mcp_protocol.writeToolTextResult(writer, id, payload.items);
}

pub fn writeDiscoverToolResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    live_trace: ?*trace.TraceWriter,
    out_path: []const u8,
    include_actions: bool,
    validate: bool,
    force: bool,
    name: ?[]const u8,
    app_id: ?[]const u8,
) !void {
    const tw = live_trace orelse {
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":false,\"mode\":\"discover\",\"traceDir\":null,\"message\":\"start zmr mcp with --trace-dir to enable live trace discovery\"}");
        return;
    };

    try tw.flushManifest();
    var discovered = try cli_discover.discoverFromTrace(allocator, .{
        .from_trace = tw.root_dir,
        .out_path = out_path,
        .name = name,
        .app_id = app_id,
        .include_actions = include_actions,
        .validate = validate,
        .force = force,
        .json = true,
    });
    defer discovered.deinit(allocator);
    try runner_events.recordTraceDiscover(
        tw,
        if (discovered.summary.ok) "ok" else "failed",
        discovered.summary.draft.out_path,
        include_actions,
        discovered.summary.validated,
    );

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    try cli_discover.writeJson(payload.writer(allocator), discovered.summary, discovered.validation);
    try mcp_protocol.writeToolTextResult(writer, id, std.mem.trimRight(u8, payload.items, " \t\r\n"));
}
