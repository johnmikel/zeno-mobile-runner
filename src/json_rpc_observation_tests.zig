const std = @import("std");
const test_io = @import("test_io.zig");
const observation = @import("json_rpc_observation.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

test "json rpc observation writer emits raw and semantic snapshots" {
    const allocator = std.testing.allocator;
    var snapshot = try makeSnapshot(allocator, "snapshot-rpc-observe", "Continue");
    defer snapshot.deinit(allocator);

    var raw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer raw.deinit();
    try observation.writeResult(&raw.writer, .{ .integer = 7 }, snapshot, .raw);

    try std.testing.expect(std.mem.indexOf(u8, raw.written(), "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw.written(), "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw.written(), "\"className\":\"android.widget.Button\"") != null);

    var semantic = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer semantic.deinit();
    try observation.writeResult(&semantic.writer, .{ .integer = 8 }, snapshot, .semantic);

    try std.testing.expect(std.mem.indexOf(u8, semantic.written(), "\"id\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, semantic.written(), "\"role\":\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, semantic.written(), "\"recommendedAction\":\"tap\"") != null);
}

test "json rpc observation artifact recorder writes snapshot artifact event" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-json-rpc-observation-artifact";
    test_io.cwd().deleteTree(trace_dir) catch {};
    defer test_io.cwd().deleteTree(trace_dir) catch {};

    var snapshot = try makeSnapshot(allocator, "snapshot-artifact", "Trace");
    defer snapshot.deinit(allocator);

    var writer = try trace.TraceWriter.init(allocator, trace_dir);
    defer writer.deinit();

    try observation.recordArtifact(&writer, "observe.snapshot", snapshot);

    try test_io.cwd().access(trace_dir ++ "/artifacts/snapshot-artifact.json", .{});
    const events = try test_io.cwd().readFileAlloc(allocator, trace_dir ++ "/events.jsonl", 64 * 1024);
    defer allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"path\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "snapshot-artifact.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"snapshotId\":\"snapshot-artifact\"") != null);
}

fn makeSnapshot(allocator: std.mem.Allocator, id: []const u8, label: []const u8) !types.ObservationSnapshot {
    const nodes = try allocator.alloc(types.UiNode, 1);
    nodes[0] = .{
        .stable_id = try allocator.dupe(u8, "button-continue"),
        .class_name = try allocator.dupe(u8, "android.widget.Button"),
        .text = try allocator.dupe(u8, label),
        .bounds = .{ .x = 4, .y = 8, .width = 100, .height = 40 },
    };
    return .{
        .id = try allocator.dupe(u8, id),
        .timestamp_ms = 123,
        .viewport = .{ .width = 390, .height = 844 },
        .nodes = nodes,
    };
}
