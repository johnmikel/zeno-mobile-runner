const std = @import("std");
const test_io = @import("test_io.zig");
const trace = @import("trace.zig");
const selector = @import("selector.zig");
const types = @import("types.zig");

const TraceWriter = trace.TraceWriter;
const writeJsonString = trace.writeJsonString;
const writeSelectorJson = trace.writeSelectorJson;
const writeSnapshotJson = trace.writeSnapshotJson;

test "snapshot json contains nodes" {
    const allocator = std.testing.allocator;
    var node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-1"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, "Probe"),
    };
    defer node.deinit(allocator);
    const nodes = try allocator.alloc(types.UiNode, 1);
    defer allocator.free(nodes);
    nodes[0] = node;

    const snapshot = types.ObservationSnapshot{
        .id = try allocator.dupe(u8, "snapshot-1"),
        .timestamp_ms = 42,
        .nodes = nodes,
    };
    defer allocator.free(snapshot.id);

    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();
    try writeSnapshotJson(&buffer.writer, snapshot);
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "\"nodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "\"displayDensityDpi\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "Probe") != null);
}

test "trace writer appends events" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-events";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    try writer.recordEvent("first", "{\"ok\":true}");
    try writer.recordEvent("second", "{\"ok\":true}");

    const path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(path);
    const bytes = try test_io.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"second\"") != null);
    try std.testing.expect(std.mem.count(u8, bytes, "\n") == 2);
}

test "trace writer init resets stale events and artifacts" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-reset";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    try test_io.cwd().makePath(dir ++ "/artifacts");
    {
        var events = try test_io.cwd().createFile(dir ++ "/events.jsonl", .{ .truncate = true });
        defer events.close();
        try events.writeAll("{\"seq\":99,\"kind\":\"stale\",\"payload\":{}}\n");
    }
    {
        var artifact = try test_io.cwd().createFile(dir ++ "/artifacts/stale.png", .{ .truncate = true });
        defer artifact.close();
        try artifact.writeAll("stale");
    }

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    try writer.recordEvent("fresh", "{\"ok\":true}");

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const bytes = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"stale\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"fresh\"") != null);
    try std.testing.expectError(error.FileNotFound, test_io.cwd().access(dir ++ "/artifacts/stale.png", .{}));
}

test "trace writer writes and finalizes manifest" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-manifest";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    try writer.startManifest("manifest flow", "com.example.mobiletest");
    try writer.recordEvent("scenario.start", "{\"value\":\"manifest flow\"}");
    try writer.finishManifest(.{
        .status = "passed",
        .report_path = "report.html",
    });

    const path = try std.fs.path.join(allocator, &.{ dir, "trace.json" });
    defer allocator.free(path);
    const bytes = try test_io.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"scenarioName\":\"manifest flow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"appId\":\"com.example.mobiletest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"status\":\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"eventsPath\":\"events.jsonl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"artifactsDir\":\"artifacts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"eventCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"reportPath\":\"report.html\"") != null);
}

test "trace writer marks passed run partial when snapshot semantics fail" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-partial";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    try writer.startManifest("partial snapshot", "com.example.mobiletest");
    try writer.recordEvent("observe.snapshot.semanticExtraction", "{\"status\":\"failed\",\"artifactStatus\":\"captured\",\"semanticStatus\":\"failed\",\"error\":\"CommandFailed\"}");
    try writer.finishManifest(.{ .status = "passed" });

    const path = try std.fs.path.join(allocator, &.{ dir, "trace.json" });
    defer allocator.free(path);
    const bytes = try test_io.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"status\":\"partial\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"partialFailureCount\":1") != null);
}

test "json string escapes quotes slashes and control characters" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    try writeJsonString(&buffer.writer, "a\"b\\c\n\r\t\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\r\\t\\u0001\"", buffer.written());
}

test "raw snapshot json preserves text for live observations" {
    const allocator = std.testing.allocator;
    var node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-email"),
        .class_name = try allocator.dupe(u8, "android.widget.EditText"),
        .text = try allocator.dupe(u8, "agent@example.com"),
    };
    defer node.deinit(allocator);
    const nodes = try allocator.alloc(types.UiNode, 1);
    defer allocator.free(nodes);
    nodes[0] = node;

    const snapshot = types.ObservationSnapshot{
        .id = try allocator.dupe(u8, "snapshot-live"),
        .timestamp_ms = 1,
        .nodes = nodes,
    };
    defer allocator.free(snapshot.id);

    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();
    try writeSnapshotJson(&buffer.writer, snapshot);

    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "agent@example.com") != null);
}

test "selector json emits every selector field in stable order" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    try writeSelectorJson(&buffer.writer, .{
        .id = "login",
        .text = "Sign in",
        .text_contains = "Sign",
        .content_desc = "Primary action",
        .content_desc_contains = "Primary",
        .class_name = "android.widget.Button",
    });
    try std.testing.expectEqualStrings(
        "{\"id\":\"login\",\"text\":\"Sign in\",\"textContains\":\"Sign\",\"contentDesc\":\"Primary action\",\"contentDescContains\":\"Primary\",\"className\":\"android.widget.Button\"}",
        buffer.written(),
    );
}

test "trace writer writes artifacts and full snapshot json" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-snapshot";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    const next_id = try writer.nextSnapshotId();
    defer allocator.free(next_id);
    try std.testing.expectEqualStrings("snapshot-1", next_id);

    const artifact = try writer.writeArtifact("raw.txt", "payload");
    defer allocator.free(artifact);
    const artifact_bytes = try test_io.cwd().readFileAlloc(allocator, artifact, 1024);
    defer allocator.free(artifact_bytes);
    try std.testing.expectEqualStrings("payload", artifact_bytes);

    var node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-1"),
        .class_name = try allocator.dupe(u8, "android.widget.EditText"),
        .resource_id = try allocator.dupe(u8, "email"),
        .text = try allocator.dupe(u8, "agent@example.com"),
        .content_desc = try allocator.dupe(u8, "Email"),
        .bounds = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .enabled = false,
        .visible = true,
        .selected = true,
    };
    defer node.deinit(allocator);
    const nodes = try allocator.alloc(types.UiNode, 1);
    defer allocator.free(nodes);
    nodes[0] = node;

    const snapshot = types.ObservationSnapshot{
        .id = try allocator.dupe(u8, "snapshot-file"),
        .timestamp_ms = 99,
        .viewport = .{ .width = 320, .height = 640 },
        .display_density_dpi = 420,
        .active_package = "com.example.mobiletest",
        .active_activity = ".MainActivity",
        .screenshot_artifact = "screen.png",
        .tree_artifact = "tree.xml",
        .focused_node_id = "node-1",
        .nodes = nodes,
    };
    defer allocator.free(snapshot.id);

    const path = try writer.writeSnapshot(snapshot);
    defer allocator.free(path);
    const bytes = try test_io.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"activePackage\":\"com.example.mobiletest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"displayDensityDpi\":420") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"resourceId\":\"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"selected\":true") != null);
}

test "persisted snapshot json redacts sensitive text content and logs" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-snapshot-redaction";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    const jwt =
        "eyJhbGciOiJSUzI1NiIsImtpZCI6IjFiMjMifQ.eyJlbWFpbCI6ImFnZW50QGV4YW1wbGUuY29tIn0.signature";
    var node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-secret"),
        .class_name = try allocator.dupe(u8, "android.widget.EditText"),
        .resource_id = try allocator.dupe(u8, "email-login-email-input"),
        .text = try allocator.dupe(u8, "agent@example.com"),
        .content_desc = try allocator.dupe(u8, "Bearer " ++ jwt),
    };
    defer node.deinit(allocator);
    const nodes = try allocator.alloc(types.UiNode, 1);
    defer allocator.free(nodes);
    nodes[0] = node;

    const snapshot = types.ObservationSnapshot{
        .id = try allocator.dupe(u8, "snapshot-secret"),
        .timestamp_ms = 1,
        .log_delta = try allocator.dupe(u8, "Authorization: Bearer " ++ jwt ++ "\nemail=agent@example.com"),
        .nodes = nodes,
    };
    defer {
        allocator.free(snapshot.id);
        allocator.free(snapshot.log_delta.?);
    }

    const path = try writer.writeSnapshot(snapshot);
    defer allocator.free(path);
    const bytes = try test_io.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "agent@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, jwt) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[REDACTED:email]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[REDACTED:token]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"logDelta\"") != null);
}

test "trace events redact nested secret payloads before writing" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-redaction";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    try writer.recordEvent(
        "leaky",
        "{\"email\":\"agent@example.com\",\"auth\":{\"idToken\":\"secret-token-value\"},\"visibleTexts\":[\"hello\",\"agent@example.com\"]}",
    );

    const path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(path);
    const bytes = try test_io.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "agent@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "secret-token-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[REDACTED:email]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[REDACTED:secret]") != null);
}

test "trace writer applies app-specific redaction rules to snapshots and events" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-custom-redaction";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.initWithOptions(allocator, dir, .{
        .redaction = .{
            .denylist_text = &.{ "customer dob", "internal token" },
            .allowlist_text = &.{"public token label"},
            .denylist_resource_ids = &.{"password-field"},
            .allowlist_resource_ids = &.{"public-token-label"},
        },
    });
    defer writer.deinit();

    var sensitive_node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-sensitive"),
        .class_name = try allocator.dupe(u8, "android.widget.EditText"),
        .resource_id = try allocator.dupe(u8, "login-password-field"),
        .text = try allocator.dupe(u8, "Customer DOB 1990-01-01"),
        .content_desc = try allocator.dupe(u8, "Internal token field"),
    };
    defer sensitive_node.deinit(allocator);
    var public_node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-public"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .resource_id = try allocator.dupe(u8, "public-token-label"),
        .text = try allocator.dupe(u8, "Public token label"),
    };
    defer public_node.deinit(allocator);
    const nodes = try allocator.alloc(types.UiNode, 2);
    defer allocator.free(nodes);
    nodes[0] = sensitive_node;
    nodes[1] = public_node;

    const snapshot = types.ObservationSnapshot{
        .id = try allocator.dupe(u8, "snapshot-custom-redaction"),
        .timestamp_ms = 1,
        .log_delta = try allocator.dupe(u8, "debug Customer DOB 1990-01-01"),
        .nodes = nodes,
    };
    defer {
        allocator.free(snapshot.id);
        allocator.free(snapshot.log_delta.?);
    }

    const snapshot_path = try writer.writeSnapshot(snapshot);
    defer allocator.free(snapshot_path);
    try writer.recordEvent("custom", "{\"note\":\"internal token abc\",\"label\":\"Public token label\"}");

    const snapshot_bytes = try test_io.cwd().readFileAlloc(allocator, snapshot_path, 1024 * 1024);
    defer allocator.free(snapshot_bytes);
    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const event_bytes = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(event_bytes);

    try std.testing.expect(std.mem.indexOf(u8, snapshot_bytes, "Customer DOB 1990-01-01") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_bytes, "Internal token field") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_bytes, "login-password-field") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_bytes, "\"resourceId\":\"[REDACTED:resourceId]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_bytes, "\"resourceId\":\"public-token-label\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_bytes, "Public token label") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_bytes, "[REDACTED:custom]") != null);

    try std.testing.expect(std.mem.indexOf(u8, event_bytes, "internal token abc") == null);
    try std.testing.expect(std.mem.indexOf(u8, event_bytes, "Public token label") != null);
    try std.testing.expect(std.mem.indexOf(u8, event_bytes, "[REDACTED:custom]") != null);
}

test "snapshot ids keep advancing so artifacts never overwrite each other" {
    // Only one call to nextSnapshotId was ever tested, so an id generator that
    // returned snapshot-1 forever passed. Every artifact in a run is named
    // from this id -- <id>.png, <id>.xml, <id>.json -- so a stuck counter
    // silently collapses a whole run onto one screenshot and one UI tree, and
    // the trace still looks complete.
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-snapshot-id-sequence";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var writer = try TraceWriter.init(allocator, dir);
    defer writer.deinit();

    var seen: [4][]const u8 = undefined;
    var count: usize = 0;
    defer for (seen[0..count]) |id| allocator.free(id);

    while (count < seen.len) : (count += 1) {
        seen[count] = try writer.nextSnapshotId();
    }

    try std.testing.expectEqualStrings("snapshot-1", seen[0]);
    try std.testing.expectEqualStrings("snapshot-4", seen[3]);
    for (seen[0..], 0..) |id, i| {
        for (seen[i + 1 ..]) |other| {
            if (std.mem.eql(u8, id, other)) {
                std.debug.print("\nduplicate snapshot id: {s}\n", .{id});
                return error.DuplicateSnapshotId;
            }
        }
    }

    // The count published in the manifest has to agree with what was handed
    // out, since tooling locates the newest artifact by that number.
    try std.testing.expectEqual(@as(usize, 4), writer.snapshot_count);
}
