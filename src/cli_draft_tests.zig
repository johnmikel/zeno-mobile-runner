const std = @import("std");
const cli_draft = @import("cli_draft.zig");

test "parse args requires trace source and output path" {
    const parsed = try cli_draft.parseArgs(&.{
        "--from-trace",
        "traces/login",
        "--out",
        ".zmr/discovered/home-smoke.json",
        "--name",
        "home smoke",
        "--app-id",
        "com.example.mobiletest",
        "--force",
        "--json",
    });

    try std.testing.expectEqualStrings("traces/login", parsed.from_trace.?);
    try std.testing.expectEqualStrings(".zmr/discovered/home-smoke.json", parsed.out_path.?);
    try std.testing.expectEqualStrings("home smoke", parsed.name.?);
    try std.testing.expectEqualStrings("com.example.mobiletest", parsed.app_id.?);
    try std.testing.expect(parsed.force);
    try std.testing.expect(parsed.json);

    try std.testing.expectError(error.MissingTraceDir, cli_draft.parseArgs(&.{ "--out", "draft.json" }));
    try std.testing.expectError(error.MissingDraftOut, cli_draft.parseArgs(&.{ "--from-trace", "traces/login" }));
    try std.testing.expectError(error.UnknownFlag, cli_draft.parseArgs(&.{ "--from-snapshot", "snapshot.json" }));
}

test "draft from trace writes conservative surface smoke scenario" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-cli-draft";
    const trace_dir = root ++ "/trace";
    const out_path = root ++ "/draft.json";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(trace_dir ++ "/artifacts");
    try std.fs.cwd().writeFile(.{
        .sub_path = trace_dir ++ "/trace.json",
        .data =
        \\{"schemaVersion":1,"runnerVersion":"0.1.7","protocolVersion":"2026-04-28","scenarioName":"login smoke","appId":"com.example.mobiletest","status":"passed","startedAtMs":1,"endedAtMs":2,"durationMs":1,"failedStepIndex":null,"error":null,"eventsPath":"events.jsonl","artifactsDir":"artifacts","eventCount":3,"snapshotCount":2,"partialFailureCount":0,"reportPath":null}
        \\
        ,
    });
    try std.fs.cwd().writeFile(.{
        .sub_path = trace_dir ++ "/artifacts/snapshot-2.json",
        .data =
        \\{
        \\  "id": "snapshot-2",
        \\  "timestampMs": 2,
        \\  "viewport": {"width": 390, "height": 844},
        \\  "activePackage": "com.example.mobiletest",
        \\  "activeActivity": ".MainActivity",
        \\  "focusedNodeId": null,
        \\  "nodes": [
        \\    {
        \\      "id": "primary",
        \\      "role": "button",
        \\      "name": "Continue",
        \\      "selector": {"resourceId": "com.example.mobiletest:id/continue_button", "text": "Continue"},
        \\      "source": {"className": "android.widget.Button", "resourceId": "com.example.mobiletest:id/continue_button", "text": "Continue", "contentDesc": null},
        \\      "bounds": {"x": 16, "y": 720, "width": 358, "height": 48, "centerX": 195, "centerY": 744},
        \\      "enabled": true,
        \\      "visible": true,
        \\      "selected": false,
        \\      "interactive": true,
        \\      "recommendedAction": "tap"
        \\    },
        \\    {
        \\      "id": "title",
        \\      "role": "text",
        \\      "name": "Welcome",
        \\      "selector": {"text": "Welcome"},
        \\      "source": {"className": "android.widget.TextView", "resourceId": null, "text": "Welcome", "contentDesc": null},
        \\      "bounds": {"x": 20, "y": 80, "width": 200, "height": 40, "centerX": 120, "centerY": 100},
        \\      "enabled": true,
        \\      "visible": true,
        \\      "selected": false,
        \\      "interactive": false,
        \\      "recommendedAction": null
        \\    },
        \\    {
        \\      "id": "weak",
        \\      "role": "node",
        \\      "name": "",
        \\      "selector": {"stableId": "node-3"},
        \\      "source": {"className": "android.view.View", "resourceId": null, "text": null, "contentDesc": null},
        \\      "bounds": {"x": 0, "y": 0, "width": 1, "height": 1, "centerX": 0, "centerY": 0},
        \\      "enabled": true,
        \\      "visible": true,
        \\      "selected": false,
        \\      "interactive": false,
        \\      "recommendedAction": null
        \\    }
        \\  ],
        \\  "summary": {"nodeCount": 3, "interactiveCount": 1, "visibleText": ["Continue", "Welcome"]}
        \\}
        \\
        ,
    });

    var result = try cli_draft.draftFromTrace(allocator, .{
        .from_trace = trace_dir,
        .out_path = out_path,
        .force = true,
        .json = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(out_path, result.summary.out_path);
    try std.testing.expectEqualStrings(trace_dir ++ "/artifacts/snapshot-2.json", result.summary.source_snapshot);
    try std.testing.expectEqual(@as(usize, 2), result.summary.selector_count);
    try std.testing.expectEqual(@as(usize, 4), result.summary.step_count);

    const scenario = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(scenario);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"name\":\"draft from login smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"appId\":\"com.example.mobiletest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"launch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"selector\":{\"resourceId\":\"com.example.mobiletest:id/continue_button\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"selector\":{\"text\":\"Welcome\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"tap\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"className\"") == null);
}

test "draft json response points agents to validation before running" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try cli_draft.writeJson(out.writer(allocator), .{
        .ok = true,
        .out_path = ".zmr/discovered/draft.json",
        .trace_dir = "traces/zmr-agent",
        .source_snapshot = "traces/zmr-agent/artifacts/snapshot-2.json",
        .name = "draft from login smoke",
        .app_id = "com.example.mobiletest",
        .selector_count = 2,
        .step_count = 4,
        .warnings = &.{"draft requires human review before commit"},
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"mode\":\"draft\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"zmr validate --json .zmr/discovered/draft.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"zmr run .zmr/discovered/draft.json --json --trace-dir traces/zmr-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "human review") != null);
}
