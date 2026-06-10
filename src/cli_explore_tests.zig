const std = @import("std");
const cli_explore = @import("cli_explore.zig");

test "explore parse args supports trace-backed goal and validation flags" {
    const parsed = try cli_explore.parseArgs(&.{
        "--from-trace",
        "traces/login",
        "--out",
        ".zmr/discovered/login-explore.json",
        "--goal",
        "find a stable login smoke",
        "--name",
        "login explore",
        "--app-id",
        "com.example.mobiletest",
        "--include-actions",
        "--validate",
        "--force",
        "--json",
    });

    try std.testing.expectEqualStrings("traces/login", parsed.from_trace.?);
    try std.testing.expectEqualStrings(".zmr/discovered/login-explore.json", parsed.out_path.?);
    try std.testing.expectEqualStrings("find a stable login smoke", parsed.goal.?);
    try std.testing.expectEqualStrings("login explore", parsed.name.?);
    try std.testing.expectEqualStrings("com.example.mobiletest", parsed.app_id.?);
    try std.testing.expect(parsed.include_actions);
    try std.testing.expect(parsed.validate);
    try std.testing.expect(parsed.force);
    try std.testing.expect(parsed.json);

    try std.testing.expectError(error.MissingTraceDir, cli_explore.parseArgs(&.{ "--out", "explore.json" }));
    try std.testing.expectError(error.MissingDraftOut, cli_explore.parseArgs(&.{ "--from-trace", "traces/login" }));
    try std.testing.expectError(error.MissingParam, cli_explore.parseArgs(&.{ "--from-trace", "traces/login", "--out", "explore.json", "--goal" }));
    try std.testing.expectError(error.UnknownFlag, cli_explore.parseArgs(&.{ "--crawl", "true" }));
}

test "explore from trace writes reviewable validated candidate with guardrails" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-cli-explore";
    const trace_dir = root ++ "/trace";
    const out_path = root ++ "/explored.json";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(trace_dir ++ "/artifacts");
    try std.fs.cwd().writeFile(.{
        .sub_path = trace_dir ++ "/trace.json",
        .data =
        \\{"schemaVersion":1,"runnerVersion":"0.2.0","protocolVersion":"2026-04-28","scenarioName":"agent session","appId":"com.example.mobiletest","status":"passed","startedAtMs":1,"endedAtMs":2,"durationMs":1,"failedStepIndex":null,"error":null,"eventsPath":"events.jsonl","artifactsDir":"artifacts","eventCount":2,"snapshotCount":1,"partialFailureCount":0,"reportPath":null}
        \\
        ,
    });
    try std.fs.cwd().writeFile(.{
        .sub_path = trace_dir ++ "/events.jsonl",
        .data =
        \\{"seq":1,"timestampMs":1,"kind":"app.launch","payload":{"status":"ok"}}
        \\{"seq":2,"timestampMs":2,"kind":"app.openLink","payload":{"status":"ok","url":"exampleapp://login"}}
        \\
        ,
    });
    try std.fs.cwd().writeFile(.{
        .sub_path = trace_dir ++ "/artifacts/snapshot-1.json",
        .data =
        \\{
        \\  "id": "snapshot-1",
        \\  "timestampMs": 2,
        \\  "viewport": {"width": 390, "height": 844},
        \\  "activePackage": "com.example.mobiletest",
        \\  "activeActivity": ".MainActivity",
        \\  "focusedNodeId": null,
        \\  "nodes": [
        \\    {
        \\      "stableId": "rid:login-title:0",
        \\      "className": "android.widget.TextView",
        \\      "resourceId": "login-title",
        \\      "text": "Login",
        \\      "contentDesc": null,
        \\      "bounds": {"x": 20, "y": 80, "width": 200, "height": 40},
        \\      "enabled": true,
        \\      "visible": true,
        \\      "selected": false
        \\    }
        \\  ]
        \\}
        \\
        ,
    });

    var result = try cli_explore.exploreFromTrace(allocator, .{
        .from_trace = trace_dir,
        .out_path = out_path,
        .goal = "find a stable login smoke",
        .force = true,
        .json = true,
        .include_actions = true,
        .validate = true,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.summary.ok);
    try std.testing.expect(result.discovered.validation != null);
    try std.testing.expect(result.discovered.validation.?.ok);
    try std.testing.expectEqualStrings("find a stable login smoke", result.summary.goal.?);
    try std.testing.expectEqualStrings(out_path, result.discovered.summary.draft.out_path);

    const scenario = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(scenario);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"openLink\",\"url\":\"exampleapp://login\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"assertVisible\",\"selector\":{\"resourceId\":\"login-title\"}") != null);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try cli_explore.writeJson(out.writer(allocator), result.summary, result.discovered.summary, result.discovered.validation);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"mode\":\"explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"goal\":\"find a stable login smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"autonomous\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reviewRequired\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"guardrails\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "does not crawl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"validated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"validation\":{\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"zmr validate --json ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"zmr run ") != null);
}
