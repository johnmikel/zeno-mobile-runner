const std = @import("std");
const json_rpc_trace = @import("json_rpc_trace.zig");
const trace = @import("trace.zig");

test "json rpc trace events result streams events after cursor with limit" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-json-rpc-trace-events";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("trace events helper", "com.example.mobiletest");
    try tw.recordEvent("first", "{\"ok\":true}");
    try tw.recordEvent("second", "{\"ok\":true}");

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try json_rpc_trace.writeEventsResult(allocator, out.writer(allocator), null, &tw, 1, 1);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"traceDir\":\"zig-cache-test-json-rpc-trace-events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"afterSeq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"nextSeq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"latestSeq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"kind\":\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"kind\":\"first\"") == null);
}

test "json rpc trace explain result summarizes active trace" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-json-rpc-trace-explain";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("trace explain helper", "com.example.mobiletest");
    try tw.recordEvent("wait.visible", "{\"status\":\"timeout\",\"snapshotId\":\"snapshot-7\",\"activePackage\":\"com.example.mobiletest\",\"visibleTexts\":[\"Sign in\",\"Try again\"]}");
    try tw.recordEvent("scenario.end", "{\"value\":\"trace explain helper\",\"status\":\"failed\",\"failedStepIndex\":2,\"error\":\"WaitTimeout\"}");
    try tw.finishManifest(.{ .status = "failed", .failed_step_index = 2, .error_name = "WaitTimeout" });

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try json_rpc_trace.writeExplainResult(allocator, out.writer(allocator), .{ .integer = 7 }, &tw);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"traceDir\":\"zig-cache-test-json-rpc-trace-explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"scenario\":\"trace explain helper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"failedStepIndex\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"error\":\"WaitTimeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"diagnostic\":{\"kind\":\"wait.visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"visibleTexts\":[\"Sign in\",\"Try again\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"nextCommands\"") != null);
}

test "json rpc trace explain result reports disabled tracing" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try json_rpc_trace.writeExplainResult(allocator, out.writer(allocator), .{ .integer = 8 }, null);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"traceDir\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "enable live RPC trace explanation") != null);
}

test "json rpc trace helper records simple string payloads" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-json-rpc-simple-payload";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};

    var tw = try trace.TraceWriter.init(allocator, trace_dir);
    defer tw.deinit();
    try tw.startManifest("simple payload helper", "com.example.mobiletest");
    try json_rpc_trace.recordSimplePayload(&tw, "ui.type", "text", "hello");

    const events_path = try std.fs.path.join(allocator, &.{ trace_dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try std.fs.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"text\":\"hello\"") != null);
}
