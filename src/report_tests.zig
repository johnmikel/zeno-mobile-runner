const std = @import("std");
const report = @import("report.zig");

const writeHtmlReport = report.writeHtmlReport;
const writeJUnitReport = report.writeJUnitReport;
const writeTraceExplanation = report.writeTraceExplanation;

test "report writes benchmark html with terminal trace fields" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-report-benchmark";
    const out_path = root ++ "/report.html";
    const trace_dir = root ++ "/zmr-2";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(trace_dir);

    {
        var results = try std.fs.cwd().createFile(root ++ "/results.jsonl", .{ .truncate = true });
        defer results.close();
        try results.writeAll(
            "{\"tool\":\"zmr\",\"run\":1,\"status\":\"ok\",\"durationMs\":1000,\"traceDir\":\"" ++ root ++ "/zmr-1\",\"traceStatus\":\"passed\"}\n" ++
                "{\"tool\":\"zmr\",\"run\":2,\"status\":\"failed\",\"durationMs\":2000,\"traceDir\":\"" ++ trace_dir ++ "\",\"traceStatus\":\"failed\",\"traceError\":\"WaitTimeout\",\"failedStepIndex\":5}\n",
        );
    }
    {
        var events = try std.fs.cwd().createFile(trace_dir ++ "/events.jsonl", .{ .truncate = true });
        defer events.close();
        try events.writeAll(
            "{\"seq\":1,\"kind\":\"step.error\",\"payload\":{\"index\":5,\"error\":\"WaitTimeout\"}}\n" ++
                "{\"seq\":2,\"kind\":\"scenario.end\",\"payload\":{\"value\":\"flow\",\"status\":\"failed\",\"failedStepIndex\":5,\"error\":\"WaitTimeout\"}}\n",
        );
    }

    try writeHtmlReport(allocator, root, out_path);

    const html = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "ZMR Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Pass Rate") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "1/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "WaitTimeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "failedStepIndex") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "events.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "file://") != null);
}

test "report writes single trace html with terminal event" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-report-trace";
    const out_path = root ++ "/report.html";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);

    {
        var events = try std.fs.cwd().createFile(root ++ "/events.jsonl", .{ .truncate = true });
        defer events.close();
        try events.writeAll(
            "{\"seq\":1,\"kind\":\"wait.visible\",\"payload\":{\"status\":\"ok\"}}\n" ++
                "{\"seq\":2,\"kind\":\"scenario.end\",\"payload\":{\"value\":\"flow\",\"status\":\"passed\"}}\n",
        );
    }
    {
        var manifest = try std.fs.cwd().createFile(root ++ "/trace.json", .{ .truncate = true });
        defer manifest.close();
        try manifest.writeAll(
            "{\"schemaVersion\":1,\"runnerVersion\":\"0.2.2\",\"protocolVersion\":\"2026-04-28\",\"scenarioName\":\"flow\",\"appId\":\"com.example.mobiletest\",\"status\":\"passed\",\"startedAtMs\":1,\"endedAtMs\":2,\"durationMs\":1,\"failedStepIndex\":null,\"error\":null,\"eventsPath\":\"events.jsonl\",\"artifactsDir\":\"artifacts\",\"eventCount\":2,\"snapshotCount\":0,\"reportPath\":null}\n",
        );
    }

    try writeHtmlReport(allocator, root, out_path);

    const html = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "ZMR Trace Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Terminal Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "scenario.end") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "file://") != null);

    const manifest = try std.fs.cwd().readFileAlloc(allocator, root ++ "/trace.json", 1024 * 1024);
    defer allocator.free(manifest);
    const parsed_manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest, .{});
    defer parsed_manifest.deinit();
    try std.testing.expectEqualStrings("report.html", parsed_manifest.value.object.get("reportPath").?.string);
}

test "report writes single trace junit xml for ci" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-report-junit";
    const out_path = root ++ "/junit.xml";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);

    {
        var manifest = try std.fs.cwd().createFile(root ++ "/trace.json", .{ .truncate = true });
        defer manifest.close();
        try manifest.writeAll(
            "{\"schemaVersion\":1,\"runnerVersion\":\"0.2.2\",\"protocolVersion\":\"2026-04-28\",\"scenarioName\":\"login & smoke\",\"appId\":\"com.example.mobiletest\",\"status\":\"failed\",\"startedAtMs\":1,\"endedAtMs\":101,\"durationMs\":100,\"failedStepIndex\":2,\"error\":\"WaitTimeout\",\"eventsPath\":\"events.jsonl\",\"artifactsDir\":\"artifacts\",\"eventCount\":4,\"snapshotCount\":1,\"reportPath\":null}\n",
        );
    }
    {
        var events = try std.fs.cwd().createFile(root ++ "/events.jsonl", .{ .truncate = true });
        defer events.close();
        try events.writeAll(
            "{\"seq\":1,\"kind\":\"scenario.start\",\"payload\":{\"value\":\"login & smoke\"}}\n" ++
                "{\"seq\":2,\"kind\":\"wait.visible\",\"payload\":{\"status\":\"timeout\",\"snapshotId\":\"snapshot-7\",\"selectors\":[{\"text\":\"Dashboard\"}],\"visibleTexts\":[\"Sign in\",\"Try again\"]}}\n" ++
                "{\"seq\":3,\"kind\":\"step.error\",\"payload\":{\"index\":2,\"error\":\"WaitTimeout\"}}\n" ++
                "{\"seq\":4,\"kind\":\"scenario.end\",\"payload\":{\"value\":\"login & smoke\",\"status\":\"failed\",\"failedStepIndex\":2,\"error\":\"WaitTimeout\"}}\n",
        );
    }

    try writeJUnitReport(allocator, root, out_path);

    const xml = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<testsuite name=\"ZMR\" tests=\"1\" failures=\"1\" errors=\"0\" skipped=\"0\" time=\"0.100\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<testcase classname=\"com.example.mobiletest\" name=\"login &amp; smoke\" time=\"0.100\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<failure message=\"WaitTimeout\" type=\"WaitTimeout\">failedStepIndex=2</failure>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<property name=\"traceDir\" value=\"zig-cache-test-report-junit\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<property name=\"eventCount\" value=\"4\"/>") != null);
}

test "report writes benchmark junit xml for ci" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-report-benchmark-junit";
    const out_path = root ++ "/junit.xml";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);

    {
        var results = try std.fs.cwd().createFile(root ++ "/results.jsonl", .{ .truncate = true });
        defer results.close();
        try results.writeAll(
            "{\"tool\":\"zmr\",\"run\":1,\"status\":\"ok\",\"durationMs\":1000,\"traceDir\":\"" ++ root ++ "/zmr-1\",\"traceStatus\":\"passed\"}\n" ++
                "{\"tool\":\"zmr\",\"run\":2,\"status\":\"failed\",\"durationMs\":2000,\"traceDir\":\"" ++ root ++ "/zmr-2\",\"traceStatus\":\"failed\",\"traceError\":\"WaitTimeout\",\"failedStepIndex\":5}\n",
        );
    }

    try writeJUnitReport(allocator, root, out_path);

    const xml = try std.fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<testsuite name=\"ZMR Benchmark\" tests=\"2\" failures=\"1\" errors=\"0\" skipped=\"0\" time=\"3.000\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<testcase classname=\"zmr\" name=\"run 1\" time=\"1.000\"></testcase>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<testcase classname=\"zmr\" name=\"run 2\" time=\"2.000\"><failure message=\"WaitTimeout\" type=\"ZMRFailure\">failedStepIndex=5 traceDir=zig-cache-test-report-benchmark-junit/zmr-2</failure></testcase>") != null);
}

test "trace explanation summarizes terminal failure diagnostics" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-explain-trace";
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);

    {
        var manifest = try std.fs.cwd().createFile(root ++ "/trace.json", .{ .truncate = true });
        defer manifest.close();
        try manifest.writeAll(
            "{\"schemaVersion\":1,\"runnerVersion\":\"0.2.2\",\"protocolVersion\":\"2026-04-28\",\"scenarioName\":\"login smoke\",\"appId\":\"com.example.mobiletest\",\"status\":\"failed\",\"startedAtMs\":1,\"endedAtMs\":101,\"durationMs\":100,\"failedStepIndex\":2,\"error\":\"WaitTimeout\",\"eventsPath\":\"events.jsonl\",\"artifactsDir\":\"artifacts\",\"eventCount\":4,\"snapshotCount\":1,\"reportPath\":null}\n",
        );
    }
    {
        var events = try std.fs.cwd().createFile(root ++ "/events.jsonl", .{ .truncate = true });
        defer events.close();
        try events.writeAll(
            "{\"seq\":1,\"kind\":\"scenario.start\",\"payload\":{\"value\":\"login smoke\"}}\n" ++
                "{\"seq\":2,\"kind\":\"wait.visible\",\"payload\":{\"status\":\"timeout\",\"snapshotId\":\"snapshot-7\",\"selectors\":[{\"text\":\"Dashboard\"}],\"activePackage\":\"com.example.mobiletest\",\"activeActivity\":\".MainActivity\",\"visibleTexts\":[\"Sign in\",\"Try again\"],\"nearestTextMatches\":[{\"stableId\":\"title\",\"text\":\"Dashboards\",\"score\":1,\"enabled\":true,\"visible\":true}]}}\n" ++
                "{\"seq\":3,\"kind\":\"step.error\",\"payload\":{\"index\":2,\"error\":\"WaitTimeout\"}}\n" ++
                "{\"seq\":4,\"kind\":\"scenario.end\",\"payload\":{\"value\":\"login smoke\",\"status\":\"failed\",\"failedStepIndex\":2,\"error\":\"WaitTimeout\"}}\n",
        );
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try writeTraceExplanation(allocator, root, out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "scenario: login smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "status: failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "failedStepIndex: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "error: WaitTimeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "diagnostic: wait.visible timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "snapshot: snapshot-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "visibleTexts: Sign in | Try again") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "nearestTextMatches: Dashboards") != null);
}
