const std = @import("std");
const cli_discover = @import("cli_discover.zig");

test "discover parse args supports trace draft and validation flags" {
    const parsed = try cli_discover.parseArgs(&.{
        "--from-trace",
        "traces/login",
        "--out",
        ".zmr/discovered/login-replay.json",
        "--name",
        "login replay",
        "--app-id",
        "com.example.mobiletest",
        "--include-actions",
        "--validate",
        "--force",
        "--json",
    });

    try std.testing.expectEqualStrings("traces/login", parsed.from_trace.?);
    try std.testing.expectEqualStrings(".zmr/discovered/login-replay.json", parsed.out_path.?);
    try std.testing.expectEqualStrings("login replay", parsed.name.?);
    try std.testing.expectEqualStrings("com.example.mobiletest", parsed.app_id.?);
    try std.testing.expect(parsed.include_actions);
    try std.testing.expect(parsed.validate);
    try std.testing.expect(parsed.force);
    try std.testing.expect(parsed.json);

    try std.testing.expectError(error.MissingTraceDir, cli_discover.parseArgs(&.{ "--out", "discover.json" }));
    try std.testing.expectError(error.MissingDraftOut, cli_discover.parseArgs(&.{ "--from-trace", "traces/login" }));
    try std.testing.expectError(error.UnknownFlag, cli_discover.parseArgs(&.{ "--crawl", "true" }));
}

test "discover from trace writes reviewable scenario and validates it" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-cli-discover";
    const trace_dir = root ++ "/trace";
    const out_path = root ++ "/discovered.json";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(trace_dir ++ "/artifacts");
    try std.fs.cwd().writeFile(.{
        .sub_path = trace_dir ++ "/trace.json",
        .data =
        \\{"schemaVersion":1,"runnerVersion":"0.1.7","protocolVersion":"2026-04-28","scenarioName":"agent session","appId":"com.example.mobiletest","status":"passed","startedAtMs":1,"endedAtMs":2,"durationMs":1,"failedStepIndex":null,"error":null,"eventsPath":"events.jsonl","artifactsDir":"artifacts","eventCount":3,"snapshotCount":1,"partialFailureCount":0,"reportPath":null}
        \\
        ,
    });
    try std.fs.cwd().writeFile(.{
        .sub_path = trace_dir ++ "/events.jsonl",
        .data =
        \\{"seq":1,"timestampMs":1,"kind":"app.launch","payload":{"status":"ok"}}
        \\{"seq":2,"timestampMs":2,"kind":"app.openLink","payload":{"status":"ok","url":"exampleapp://discover"}}
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
        \\      "stableId": "rid:welcome-title:0",
        \\      "className": "android.widget.TextView",
        \\      "resourceId": "welcome-title",
        \\      "text": "Welcome",
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

    var result = try cli_discover.discoverFromTrace(allocator, .{
        .from_trace = trace_dir,
        .out_path = out_path,
        .force = true,
        .json = true,
        .include_actions = true,
        .validate = true,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.summary.ok);
    try std.testing.expect(result.validation != null);
    try std.testing.expect(result.validation.?.ok);
    try std.testing.expectEqualStrings(out_path, result.summary.draft.out_path);
    try std.testing.expectEqual(@as(usize, 1), result.summary.draft.selector_count);

    const scenario = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(scenario);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"openLink\",\"url\":\"exampleapp://discover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scenario, "\"action\":\"assertVisible\",\"selector\":{\"resourceId\":\"welcome-title\"}") != null);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try cli_discover.writeJson(out.writer(allocator), result.summary, result.validation);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"mode\":\"discover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"validated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"validation\":{\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"zmr validate --json ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"zmr run ") != null);
}
