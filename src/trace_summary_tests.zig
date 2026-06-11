const std = @import("std");
const trace_summary = @import("trace_summary.zig");

test "trace summary reads partial visual capture diagnostics" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-summary-module";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);

    {
        var manifest = try std.fs.cwd().createFile(dir ++ "/trace.json", .{ .truncate = true });
        defer manifest.close();
        try manifest.writeAll(
            "{\"schemaVersion\":1,\"runnerVersion\":\"0.2.1\",\"protocolVersion\":\"2026-04-28\",\"scenarioName\":\"ios partial\",\"appId\":\"com.example.mobiletest\",\"status\":\"partial\",\"startedAtMs\":1,\"endedAtMs\":101,\"durationMs\":100,\"failedStepIndex\":null,\"error\":null,\"eventsPath\":\"events.jsonl\",\"artifactsDir\":\"artifacts\",\"eventCount\":2,\"snapshotCount\":1,\"partialFailureCount\":1,\"reportPath\":null}\n",
        );
    }
    {
        var events = try std.fs.cwd().createFile(dir ++ "/events.jsonl", .{ .truncate = true });
        defer events.close();
        try events.writeAll(
            "{\"seq\":1,\"timestampMs\":1,\"kind\":\"observe.snapshot.semanticExtraction\",\"payload\":{\"status\":\"failed\",\"artifactStatus\":\"captured\",\"semanticStatus\":\"failed\",\"error\":\"CommandFailed\",\"screenshotArtifact\":\"artifacts/snapshot-1.png\",\"source\":\"ios-xctest-shim\"}}\n" ++
                "{\"seq\":2,\"timestampMs\":2,\"kind\":\"scenario.end\",\"payload\":{\"status\":\"passed\"}}\n",
        );
    }

    var summary = try trace_summary.read(allocator, dir);
    defer summary.deinit(allocator);

    try std.testing.expectEqualStrings("partial", summary.status);
    try std.testing.expect(summary.partial_failure != null);
    try std.testing.expectEqualStrings("captured", summary.partial_failure.?.artifact_status.?);
    try std.testing.expectEqualStrings("failed", summary.partial_failure.?.semantic_status.?);
    try std.testing.expectEqualStrings("observe.snapshot.semanticExtraction", summary.diagnostic.kind.?);
}
