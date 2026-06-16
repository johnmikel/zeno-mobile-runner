const std = @import("std");
const bundle = @import("bundle.zig");
const cli_discover = @import("cli_discover.zig");
const cli_explore = @import("cli_explore.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const report = @import("report.zig");
const runner_events = @import("runner_events.zig");
const stdio = @import("stdio.zig");
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
        var no_trace_payload: std.Io.Writer.Allocating = .init(allocator);
        defer no_trace_payload.deinit();
        try no_trace_payload.writer.print("{{\"traceDir\":null,\"afterSeq\":{d},\"nextSeq\":{d},\"latestSeq\":0,\"events\":[]}}", .{ after_seq, after_seq });
        try mcp_protocol.writeToolTextResult(writer, id, no_trace_payload.writer.buffered());
        return;
    };

    const events_path = try std.fs.path.join(allocator, &.{ tw.root_dir, "events.jsonl" });
    defer allocator.free(events_path);
    const content = stdio.readFileAlloc(allocator, events_path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    const payload_writer = &payload.writer;
    try payload_writer.writeAll("{\"traceDir\":");
    try trace.writeJsonString(payload_writer, tw.root_dir);
    try payload_writer.print(",\"afterSeq\":{d},\"nextSeq\":", .{after_seq});
    var events_json: std.Io.Writer.Allocating = .init(allocator);
    defer events_json.deinit();
    const events_writer = &events_json.writer;
    var next_seq = after_seq;
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
        if (emitted > 0) try events_writer.writeAll(",");
        try events_writer.writeAll(line);
        next_seq = seq;
        emitted += 1;
    }
    try payload_writer.print("{d},\"latestSeq\":{d},\"events\":[", .{ next_seq, tw.event_count });
    try payload_writer.writeAll(events_writer.buffered());
    try payload_writer.writeAll("]}");
    try mcp_protocol.writeToolTextResult(writer, id, payload_writer.buffered());
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

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    const payload_writer = &payload.writer;
    try payload_writer.writeAll("{\"traceDir\":");
    try trace.writeJsonString(payload_writer, tw.root_dir);
    try payload_writer.writeAll(",\"out\":");
    try trace.writeJsonString(payload_writer, out_path);
    try payload_writer.print(",\"redacted\":{},\"omitScreenshots\":{}}}", .{ redact, omit_screenshots });
    try mcp_protocol.writeToolTextResult(writer, id, payload_writer.buffered());
}

pub fn writeExplainToolResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    live_trace: ?*trace.TraceWriter,
) !void {
    const tw = live_trace orelse {
        try mcp_protocol.writeToolTextResult(writer, id, "{\"traceDir\":null,\"message\":\"start zmr mcp with --trace-dir to enable live trace explanation\"}");
        return;
    };

    try tw.flushManifest();
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try report.writeTraceExplanationJson(allocator, tw.root_dir, &payload.writer);
    try mcp_protocol.writeToolTextResult(writer, id, std.mem.trimEnd(u8, payload.writer.buffered(), " \t\r\n"));
    try tw.recordEvent("trace.explain", "{\"status\":\"ok\"}");
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

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try cli_discover.writeJson(&payload.writer, discovered.summary, discovered.validation);
    try mcp_protocol.writeToolTextResult(writer, id, std.mem.trimEnd(u8, payload.writer.buffered(), " \t\r\n"));
}

pub fn writeExploreToolResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    live_trace: ?*trace.TraceWriter,
    out_path: []const u8,
    goal: []const u8,
    include_actions: bool,
    validate: bool,
    force: bool,
    name: ?[]const u8,
    app_id: ?[]const u8,
) !void {
    const tw = live_trace orelse {
        try mcp_protocol.writeToolTextResult(writer, id, "{\"ok\":false,\"mode\":\"explore\",\"traceDir\":null,\"message\":\"start zmr mcp with --trace-dir to enable live trace exploration\"}");
        return;
    };

    try tw.flushManifest();
    var explored = try cli_explore.exploreFromTrace(allocator, .{
        .from_trace = tw.root_dir,
        .out_path = out_path,
        .goal = goal,
        .name = name,
        .app_id = app_id,
        .include_actions = include_actions,
        .validate = validate,
        .force = force,
        .json = true,
    });
    defer explored.deinit(allocator);
    try runner_events.recordTraceExplore(
        tw,
        if (explored.summary.ok) "ok" else "failed",
        explored.discovered.summary.draft.out_path,
        goal,
        include_actions,
        explored.discovered.summary.validated,
    );

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try cli_explore.writeJson(&payload.writer, explored.summary, explored.discovered.summary, explored.discovered.validation);
    try mcp_protocol.writeToolTextResult(writer, id, std.mem.trimEnd(u8, payload.writer.buffered(), " \t\r\n"));
}
