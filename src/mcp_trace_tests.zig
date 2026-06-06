const std = @import("std");
const mcp_trace = @import("mcp_trace.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

test "mcp trace events tool emits filtered text payload" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-events";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.recordEvent("first", "{\"ok\":true}");
    try tw.recordEvent("second", "{\"ok\":true}");

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try mcp_trace.writeEventsToolResult(allocator, out.writer(allocator), .{ .integer = 4 }, &tw, 1, 10);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":4") != null);
    const text = try toolText(allocator, out.items);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"traceDir\":\"zig-cache-test-mcp-trace-events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"afterSeq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"first\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"second\"") != null);
}

test "mcp trace export tool reports no-trace fallback and redacted export payload" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-export";
    const out_path = trace_dir ++ ".zmrtrace";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteFile(out_path) catch {};

    var no_trace = std.ArrayList(u8).empty;
    defer no_trace.deinit(allocator);
    try mcp_trace.writeExportToolResult(allocator, no_trace.writer(allocator), .{ .integer = 5 }, null, out_path, false, false);
    const no_trace_text = try toolText(allocator, no_trace.items);
    defer allocator.free(no_trace_text);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"traceDir\":null") != null);

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("mcp trace export", "com.example.mobiletest");
    try tw.recordEvent("trace.fixture", "{\"status\":\"ok\"}");

    var exported = std.ArrayList(u8).empty;
    defer exported.deinit(allocator);
    try mcp_trace.writeExportToolResult(allocator, exported.writer(allocator), .{ .integer = 6 }, &tw, out_path, true, true);

    try std.fs.cwd().access(out_path, .{});
    try std.testing.expect(std.mem.indexOf(u8, exported.items, "\"id\":6") != null);
    const exported_text = try toolText(allocator, exported.items);
    defer allocator.free(exported_text);
    try std.testing.expect(std.mem.indexOf(u8, exported_text, "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported_text, "\"omitScreenshots\":true") != null);
}

test "mcp trace discover tool writes validated scenario text payload" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-discover";
    const out_path = trace_dir ++ "/discovered.json";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};

    var no_trace = std.ArrayList(u8).empty;
    defer no_trace.deinit(allocator);
    try mcp_trace.writeDiscoverToolResult(allocator, no_trace.writer(allocator), .{ .integer = 6 }, null, out_path, true, true, true, null, null);
    const no_trace_text = try toolText(allocator, no_trace.items);
    defer allocator.free(no_trace_text);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"traceDir\":null") != null);

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("mcp discover", "com.example.mobiletest");
    try tw.recordEvent("app.launch", "{\"status\":\"ok\"}");
    try tw.recordEvent("app.openLink", "{\"status\":\"ok\",\"url\":\"exampleapp://discover-mcp\"}");
    var snapshot = try makeTraceSnapshot(allocator, "snapshot-1", "Discover MCP");
    defer snapshot.deinit(allocator);
    const snapshot_path = try tw.writeSnapshot(snapshot);
    defer allocator.free(snapshot_path);
    tw.snapshot_count = 1;
    try tw.recordEvent("observe.semanticSnapshot", "{\"status\":\"ok\"}");

    var discovered = std.ArrayList(u8).empty;
    defer discovered.deinit(allocator);
    try mcp_trace.writeDiscoverToolResult(allocator, discovered.writer(allocator), .{ .integer = 7 }, &tw, out_path, true, true, true, "MCP discovered", null);

    try std.testing.expect(std.mem.indexOf(u8, discovered.items, "\"id\":7") != null);
    const discovered_text = try toolText(allocator, discovered.items);
    defer allocator.free(discovered_text);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "\"mode\":\"discover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "\"validated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "\"validation\":{\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "unsupported trace action was skipped: rpc.request") == null);

    const scenario = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(scenario);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"openLink\",\"url\":\"exampleapp://discover-mcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"assertVisible\",\"selector\":{\"text\":\"Discover MCP\"}") != null);
}

fn toolText(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    const content = result.object.get("content").?;
    const first = content.array.items[0];
    const text = first.object.get("text").?;
    return try allocator.dupe(u8, text.string);
}

fn makeTraceSnapshot(allocator: std.mem.Allocator, id: []const u8, text: []const u8) !types.ObservationSnapshot {
    const nodes = try allocator.alloc(types.UiNode, 1);
    nodes[0] = .{
        .stable_id = try std.fmt.allocPrint(allocator, "node-{s}", .{id}),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, text),
        .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
    };
    return .{
        .id = try allocator.dupe(u8, id),
        .timestamp_ms = 1,
        .viewport = .{ .width = 1080, .height = 2400 },
        .nodes = nodes,
    };
}
