const std = @import("std");
const fake_device = @import("fake_device.zig");
const json_rpc = @import("json_rpc.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

test "json rpc dispatches core action wait assertion and trace methods" {
    const allocator = std.testing.allocator;

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendRpcSnapshot(allocator, &snapshots, "rpc-observe", "Observed");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-tap", "Tap");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-type", "Field");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-erase", "Field");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-scroll", "Scroll");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-visible", "Visible");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-any", "Any");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-gone", "Other");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-assert-visible", "Assert");
    try appendRpcSnapshot(allocator, &snapshots, "rpc-assert-not-visible", "Other");

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"runner.capabilities\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"device.list\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session.create\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session.close\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"app.install\",\"params\":{\"path\":\"/tmp/app.apk\"}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"app.launch\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"app.openLink\",\"params\":{\"url\":\"exampleapp://probe\"}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"app.clearState\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"app.stop\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"observe.snapshot\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"ui.tap\",\"params\":{\"selector\":{\"text\":\"Tap\"}}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"ui.type\",\"params\":{\"selector\":{\"text\":\"Field\"},\"text\":\"typed\"}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"ui.eraseText\",\"params\":{\"selector\":{\"text\":\"Field\"},\"maxChars\":9}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"ui.hideKeyboard\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"ui.swipe\",\"params\":{\"x1\":1,\"y1\":2,\"x2\":3,\"y2\":4,\"durationMs\":5}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"ui.pressBack\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"ui.scrollUntilVisible\",\"params\":{\"selector\":{\"text\":\"Scroll\"},\"direction\":\"down\",\"timeoutMs\":10}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"wait.until\",\"params\":{\"visible\":{\"text\":\"Visible\"},\"timeoutMs\":10}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"wait.any\",\"params\":{\"selectors\":[{\"text\":\"Missing\"},{\"text\":\"Any\"}],\"timeoutMs\":10}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"wait.gone\",\"params\":{\"selector\":{\"text\":\"Gone\"},\"timeoutMs\":10}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"assert.visible\",\"params\":{\"selector\":{\"text\":\"Assert\"},\"timeoutMs\":10}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"assert.notVisible\",\"params\":{\"selector\":{\"text\":\"Gone\"},\"timeoutMs\":10}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"assert.healthy\",\"params\":{\"timeoutMs\":10}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"trace.export\",\"params\":{}}", writer);

    try std.testing.expectEqualStrings("/tmp/app.apk", fake.installed_path.?);
    try std.testing.expect(fake.launched);
    try std.testing.expect(fake.stopped);
    try std.testing.expect(fake.cleared);
    try std.testing.expectEqualStrings("exampleapp://probe", fake.opened_link.?);
    try std.testing.expectEqual(@as(usize, 3), fake.taps);
    try std.testing.expectEqual(@as(usize, 1), fake.typed_text.items.len);
    try std.testing.expectEqualStrings("typed", fake.typed_text.items[0]);
    try std.testing.expectEqual(@as(usize, 1), fake.erases);
    try std.testing.expectEqual(@as(u32, 9), fake.last_erase_chars);
    try std.testing.expectEqual(@as(usize, 1), fake.hides_keyboard);
    try std.testing.expectEqual(@as(usize, 1), fake.presses_back);
    try std.testing.expectEqual(@as(usize, 1), fake.swipes);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"methods\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"assert.healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"version\":\"0.1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"protocolVersion\":\"2026-04-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"protocol\":{\"version\":\"2026-04-28\",\"minimumCompatibleVersion\":\"2026-04-28\",\"stability\":\"dev-preview\",\"breakingChangePolicy\":\"version-and-changelog\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"platforms\":[\"android\",\"ios\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"platformSupport\":{\"android\":{\"status\":\"supported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ios\":{\"status\":\"supported\",\"deviceTypes\":[\"simulator\",\"physical\"],\"automation\":[\"simctl\",\"devicectl\",\"xctest-shim\"],\"physicalDevices\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"iosPreview\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"serial\":\"fake-device-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"sessionId\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"text\":\"Observed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"matchedIndex\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"traceDir\":null") != null);
}

test "json rpc writes parse request method and execution errors" {
    const allocator = std.testing.allocator;
    const snapshots = try allocator.alloc(types.ObservationSnapshot, 0);
    defer allocator.free(snapshots);

    var fake = fake_device.FakeDevice.init(allocator, snapshots);
    defer fake.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try json_rpc.dispatchLine(allocator, &fake, "{bad json", writer);
    try json_rpc.dispatchLine(allocator, &fake, "[]", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":3,\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"missing.method\",\"params\":{}}", writer);
    try json_rpc.dispatchLine(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ui.swipe\",\"params\":{\"x1\":1}}", writer);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"code\":-32700") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":\"abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"publicCode\":\"cli.missing_param\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "MissingParam") != null);
}

test "json rpc live trace records session events and exports a bundle" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-rpc-live-trace";
    const out_path = trace_dir ++ ".zmrtrace";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteFile(out_path) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendRpcSnapshot(allocator, &snapshots, "rpc-live-observe", "Live Trace");

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var live_trace = try trace.TraceWriter.init(allocator, trace_dir);
    defer live_trace.deinit();
    try live_trace.startManifest("json-rpc session", "com.example.mobiletest");

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try json_rpc.dispatchLineWithTrace(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{}}", writer, &live_trace);
    try json_rpc.dispatchLineWithTrace(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"app.openLink\",\"params\":{\"url\":\"exampleapp://live\"}}", writer, &live_trace);
    try json_rpc.dispatchLineWithTrace(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"observe.snapshot\",\"params\":{}}", writer, &live_trace);
    try json_rpc.dispatchLineWithTrace(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"trace.export\",\"params\":{\"out\":\"zig-cache-test-rpc-live-trace.zmrtrace\",\"redact\":true,\"omitScreenshots\":true}}", writer, &live_trace);

    const events_path = try std.fs.path.join(allocator, &.{ trace_dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try std.fs.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"rpc.request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"method\":\"app.openLink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"trace.export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"out\":\"zig-cache-test-rpc-live-trace.zmrtrace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"omitScreenshots\":true") != null);
    try std.fs.cwd().access(out_path, .{});
}

test "json rpc trace events returns live events after a cursor" {
    const allocator = std.testing.allocator;
    const trace_dir = "zig-cache-test-rpc-event-stream";
    std.fs.cwd().deleteTree(trace_dir) catch {};
    defer std.fs.cwd().deleteTree(trace_dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendRpcSnapshot(allocator, &snapshots, "rpc-stream-observe", "Stream Trace");

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var live_trace = try trace.TraceWriter.init(allocator, trace_dir);
    defer live_trace.deinit();
    try live_trace.startManifest("json-rpc event stream", "com.example.mobiletest");

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try json_rpc.dispatchLineWithTrace(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{}}", writer, &live_trace);
    try json_rpc.dispatchLineWithTrace(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"observe.snapshot\",\"params\":{}}", writer, &live_trace);
    try json_rpc.dispatchLineWithTrace(allocator, &fake, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"trace.events\",\"params\":{\"afterSeq\":2,\"limit\":10}}", writer, &live_trace);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"traceDir\":\"zig-cache-test-rpc-event-stream\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"afterSeq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"nextSeq\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"latestSeq\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"kind\":\"observe.snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"method\":\"trace.events\"") != null);
}

test "json rpc protocol fixtures match exact core session responses" {
    const allocator = std.testing.allocator;

    const snapshots = try allocator.alloc(types.ObservationSnapshot, 0);
    defer allocator.free(snapshots);
    var fake = fake_device.FakeDevice.init(allocator, snapshots);
    defer fake.deinit();

    const requests = try std.fs.cwd().readFileAlloc(allocator, "docs/protocol-fixtures/core-session.requests.jsonl", 64 * 1024);
    defer allocator.free(requests);
    const expected = try std.fs.cwd().readFileAlloc(allocator, "docs/protocol-fixtures/core-session.responses.jsonl", 64 * 1024);
    defer allocator.free(expected);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    var lines = std.mem.splitScalar(u8, requests, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try json_rpc.dispatchLine(allocator, &fake, line, writer);
    }

    try std.testing.expectEqualStrings(expected, out.items);
}

fn appendRpcSnapshot(
    allocator: std.mem.Allocator,
    snapshots: *std.ArrayList(types.ObservationSnapshot),
    id: []const u8,
    text: []const u8,
) !void {
    const nodes = try allocator.alloc(types.UiNode, 1);
    nodes[0] = .{
        .stable_id = try std.fmt.allocPrint(allocator, "node-{s}", .{id}),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, text),
        .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
    };
    try snapshots.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .timestamp_ms = @as(i64, @intCast(snapshots.items.len + 1)),
        .viewport = .{ .width = 1080, .height = 2400 },
        .nodes = nodes,
    });
}
