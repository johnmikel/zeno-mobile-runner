const std = @import("std");
const test_io = @import("test_io.zig");
const mcp_trace = @import("mcp_trace.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

test "mcp trace events tool emits filtered text payload" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-events";
    test_io.cwd().deleteTree(trace_dir) catch {};
    defer test_io.cwd().deleteTree(trace_dir) catch {};

    var no_trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer no_trace.deinit();
    try mcp_trace.writeEventsToolResult(allocator, &no_trace.writer, .{ .integer = 3 }, null, 2, 10);
    const no_trace_text = try toolText(allocator, no_trace.written());
    defer allocator.free(no_trace_text);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"traceDir\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"afterSeq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"nextSeq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"latestSeq\":0") != null);

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.recordEvent("first", "{\"ok\":true}");
    try tw.recordEvent("second", "{\"ok\":true}");

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try mcp_trace.writeEventsToolResult(allocator, &out.writer, .{ .integer = 4 }, &tw, 1, 10);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":4") != null);
    const text = try toolText(allocator, out.written());
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"traceDir\":\"zig-cache-test-mcp-trace-events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"afterSeq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"nextSeq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"latestSeq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"first\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"second\"") != null);
}

test "mcp trace export tool reports no-trace fallback and redacted export payload" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-export";
    const out_path = trace_dir ++ ".zmrtrace";
    test_io.cwd().deleteTree(trace_dir) catch {};
    defer test_io.cwd().deleteTree(trace_dir) catch {};
    defer test_io.cwd().deleteFile(out_path) catch {};

    var no_trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer no_trace.deinit();
    try mcp_trace.writeExportToolResult(allocator, &no_trace.writer, .{ .integer = 5 }, null, out_path, false, false);
    const no_trace_text = try toolText(allocator, no_trace.written());
    defer allocator.free(no_trace_text);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"traceDir\":null") != null);

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("mcp trace export", "com.example.mobiletest");
    try tw.recordEvent("trace.fixture", "{\"status\":\"ok\"}");

    var exported = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer exported.deinit();
    try mcp_trace.writeExportToolResult(allocator, &exported.writer, .{ .integer = 6 }, &tw, out_path, true, true);

    try test_io.cwd().access(out_path, .{});
    try std.testing.expect(std.mem.indexOf(u8, exported.written(), "\"id\":6") != null);
    const exported_text = try toolText(allocator, exported.written());
    defer allocator.free(exported_text);
    try std.testing.expect(std.mem.indexOf(u8, exported_text, "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported_text, "\"omitScreenshots\":true") != null);
}

test "mcp trace explain tool summarizes active trace" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-explain";
    test_io.cwd().deleteTree(trace_dir) catch {};
    defer test_io.cwd().deleteTree(trace_dir) catch {};

    var no_trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer no_trace.deinit();
    try mcp_trace.writeExplainToolResult(allocator, &no_trace.writer, .{ .integer = 8 }, null);
    const no_trace_text = try toolText(allocator, no_trace.written());
    defer allocator.free(no_trace_text);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"traceDir\":null") != null);

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("mcp trace explain", "com.example.mobiletest");
    try tw.recordEvent("wait.visible", "{\"status\":\"timeout\",\"snapshotId\":\"snapshot-9\",\"activePackage\":\"com.example.mobiletest\",\"visibleTexts\":[\"Login\",\"Retry\"]}");
    try tw.recordEvent("scenario.end", "{\"value\":\"mcp trace explain\",\"status\":\"failed\",\"failedStepIndex\":4,\"error\":\"WaitTimeout\"}");
    try tw.finishManifest(.{ .status = "failed", .failed_step_index = 4, .error_name = "WaitTimeout" });

    var explained = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer explained.deinit();
    try mcp_trace.writeExplainToolResult(allocator, &explained.writer, .{ .integer = 9 }, &tw);

    try std.testing.expect(std.mem.indexOf(u8, explained.written(), "\"id\":9") != null);
    const explained_text = try toolText(allocator, explained.written());
    defer allocator.free(explained_text);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"traceDir\":\"zig-cache-test-mcp-trace-explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"scenario\":\"mcp trace explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"failedStepIndex\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"error\":\"WaitTimeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"diagnostic\":{\"kind\":\"wait.visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"visibleTexts\":[\"Login\",\"Retry\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, explained_text, "\"nextCommands\"") != null);
}

test "mcp trace discover tool writes validated scenario text payload" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-discover";
    const out_path = trace_dir ++ "/discovered.json";
    test_io.cwd().deleteTree(trace_dir) catch {};
    defer test_io.cwd().deleteTree(trace_dir) catch {};

    var no_trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer no_trace.deinit();
    try mcp_trace.writeDiscoverToolResult(allocator, &no_trace.writer, .{ .integer = 6 }, null, out_path, true, true, true, null, null);
    const no_trace_text = try toolText(allocator, no_trace.written());
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

    var discovered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer discovered.deinit();
    try mcp_trace.writeDiscoverToolResult(allocator, &discovered.writer, .{ .integer = 7 }, &tw, out_path, true, true, true, "MCP discovered", null);

    try std.testing.expect(std.mem.indexOf(u8, discovered.written(), "\"id\":7") != null);
    const discovered_text = try toolText(allocator, discovered.written());
    defer allocator.free(discovered_text);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "\"mode\":\"discover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "\"validated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "\"validation\":{\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovered_text, "unsupported trace action was skipped: rpc.request") == null);

    const scenario = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(scenario);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"openLink\",\"url\":\"exampleapp://discover-mcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"assertVisible\",\"selector\":{\"text\":\"Discover MCP\"}") != null);

    const events = try test_io.cwd().readFileAlloc(allocator, trace_dir ++ "/events.jsonl", 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"trace.discover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"out\":\"zig-cache-test-mcp-trace-discover/discovered.json\"") != null);
}

test "mcp trace explore tool writes guarded scenario text payload" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-mcp-trace-explore";
    const out_path = trace_dir ++ "/explored.json";
    const goal = "find a stable MCP smoke";
    test_io.cwd().deleteTree(trace_dir) catch {};
    defer test_io.cwd().deleteTree(trace_dir) catch {};

    var no_trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer no_trace.deinit();
    try mcp_trace.writeExploreToolResult(allocator, &no_trace.writer, .{ .integer = 6 }, null, out_path, goal, true, true, true, null, null);
    const no_trace_text = try toolText(allocator, no_trace.written());
    defer allocator.free(no_trace_text);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"mode\":\"explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_trace_text, "\"traceDir\":null") != null);

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("mcp explore", "com.example.mobiletest");
    try tw.recordEvent("app.launch", "{\"status\":\"ok\"}");
    try tw.recordEvent("app.openLink", "{\"status\":\"ok\",\"url\":\"exampleapp://explore-mcp\"}");
    var snapshot = try makeTraceSnapshot(allocator, "snapshot-1", "Explore MCP");
    defer snapshot.deinit(allocator);
    const snapshot_path = try tw.writeSnapshot(snapshot);
    defer allocator.free(snapshot_path);
    tw.snapshot_count = 1;
    try tw.recordEvent("observe.semanticSnapshot", "{\"status\":\"ok\"}");

    var explored = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer explored.deinit();
    try mcp_trace.writeExploreToolResult(allocator, &explored.writer, .{ .integer = 7 }, &tw, out_path, goal, true, true, true, "MCP explored", null);

    try std.testing.expect(std.mem.indexOf(u8, explored.written(), "\"id\":7") != null);
    const explored_text = try toolText(allocator, explored.written());
    defer allocator.free(explored_text);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "\"mode\":\"explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "\"goal\":\"find a stable MCP smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "\"autonomous\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "\"reviewRequired\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "\"guardrails\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "\"validated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "\"validation\":{\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, explored_text, "unsupported trace action was skipped: rpc.request") == null);

    const scenario = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(scenario);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"openLink\",\"url\":\"exampleapp://explore-mcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"assertVisible\",\"selector\":{\"text\":\"Explore MCP\"}") != null);

    const events = try test_io.cwd().readFileAlloc(allocator, trace_dir ++ "/events.jsonl", 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"trace.explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"out\":\"zig-cache-test-mcp-trace-explore/explored.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"goal\":\"find a stable MCP smoke\"") != null);
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
