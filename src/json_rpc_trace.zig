const std = @import("std");
const cli_discover = @import("cli_discover.zig");
const protocol = @import("json_rpc_protocol.zig");
const runner_events = @import("runner_events.zig");
const trace = @import("trace.zig");

pub fn writeEventsResult(
    allocator: std.mem.Allocator,
    writer: anytype,
    id: ?std.json.Value,
    live_trace: ?*trace.TraceWriter,
    after_seq: u64,
    limit: u64,
) !void {
    const tw = live_trace orelse {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try protocol.writeId(writer, id);
        try writer.print(",\"result\":{{\"traceDir\":null,\"afterSeq\":{d},\"nextSeq\":{d},\"latestSeq\":0,\"events\":[]}}}}\n", .{ after_seq, after_seq });
        return;
    };

    const events_path = try std.fs.path.join(allocator, &.{ tw.root_dir, "events.jsonl" });
    defer allocator.free(events_path);
    const content = std.fs.cwd().readFileAlloc(allocator, events_path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try protocol.writeId(writer, id);
    try writer.writeAll(",\"result\":{\"traceDir\":");
    try trace.writeJsonString(writer, tw.root_dir);
    try writer.print(",\"afterSeq\":{d},\"nextSeq\":", .{after_seq});

    var events_json = std.ArrayList(u8).empty;
    defer events_json.deinit(allocator);
    var events_writer = events_json.writer(allocator);
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

    try writer.print("{d},\"latestSeq\":{d},\"events\":[", .{ next_seq, tw.event_count });
    try writer.writeAll(events_json.items);
    try writer.writeAll("]}}\n");
}

pub fn recordSimplePayload(tw: *trace.TraceWriter, kind: []const u8, key: []const u8, value: []const u8) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(tw.allocator);
    const writer = payload.writer(tw.allocator);
    try writer.writeAll("{");
    try trace.writeJsonString(writer, key);
    try writer.writeAll(":");
    try trace.writeJsonString(writer, value);
    try writer.writeAll("}");
    try tw.recordEvent(kind, payload.items);
}

pub fn writeDiscoverResult(
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
        try protocol.writeResultRaw(writer, id, "{\"ok\":false,\"mode\":\"discover\",\"traceDir\":null,\"message\":\"start zmr serve with --trace-dir to enable live trace discovery\"}");
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
    try protocol.writeResultRaw(writer, id, std.mem.trimRight(u8, payload.items, " \t\r\n"));
}
