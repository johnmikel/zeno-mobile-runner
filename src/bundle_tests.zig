const std = @import("std");
const test_io = @import("test_io.zig");
const bundle = @import("bundle.zig");

const exportTraceBundle = bundle.exportTraceBundle;
const exportTraceBundleWithOptions = bundle.exportTraceBundleWithOptions;

test "trace bundle export writes deterministic archive with manifest events report and artifacts" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-trace-bundle";
    const out_path = root ++ ".zmrtrace";
    defer test_io.cwd().deleteTree(root) catch {};
    defer test_io.cwd().deleteFile(out_path) catch {};
    try test_io.cwd().makePath(root ++ "/artifacts");
    try writeFixture(root ++ "/trace.json", "{\"schemaVersion\":1,\"status\":\"passed\"}\n");
    try writeFixture(root ++ "/events.jsonl", "{\"seq\":1,\"kind\":\"scenario.end\",\"payload\":{\"status\":\"passed\"}}\n");
    try writeFixture(root ++ "/report.html", "<!doctype html><h1>ZMR</h1>\n");
    try writeFixture(root ++ "/artifacts/snapshot-1.json", "{\"id\":\"snapshot-1\"}\n");
    try writeFixture(root ++ "/artifacts/snapshot-1.xml", "<hierarchy />\n");

    try exportTraceBundle(allocator, root, out_path);

    const archive = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(archive);
    const names = try tarNames(allocator, archive);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 5), names.len);
    try std.testing.expectEqualStrings("trace.json", names[0]);
    try std.testing.expectEqualStrings("events.jsonl", names[1]);
    try std.testing.expectEqualStrings("report.html", names[2]);
    try std.testing.expectEqualStrings("artifacts/snapshot-1.json", names[3]);
    try std.testing.expectEqualStrings("artifacts/snapshot-1.xml", names[4]);
    try std.testing.expect(std.mem.indexOf(u8, archive, "snapshot-1") != null);
}

test "trace bundle export rejects directories without a manifest" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-trace-bundle-missing";
    const out_path = root ++ ".zmrtrace";
    defer test_io.cwd().deleteTree(root) catch {};
    defer test_io.cwd().deleteFile(out_path) catch {};
    try test_io.cwd().makePath(root);
    try writeFixture(root ++ "/events.jsonl", "{}\n");

    try std.testing.expectError(error.MissingTraceManifest, exportTraceBundle(allocator, root, out_path));
}

test "redacted trace bundle replaces screenshots scrubs text artifacts and annotates manifest" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-trace-bundle-redacted";
    const out_path = root ++ ".zmrtrace";
    defer test_io.cwd().deleteTree(root) catch {};
    defer test_io.cwd().deleteFile(out_path) catch {};
    try test_io.cwd().makePath(root ++ "/artifacts");
    try writeFixture(root ++ "/trace.json", "{\"schemaVersion\":1,\"status\":\"failed\",\"eventsPath\":\"events.jsonl\",\"artifactsDir\":\"artifacts\"}\n");
    try writeFixture(root ++ "/events.jsonl", "{\"seq\":1,\"kind\":\"log\",\"payload\":{\"message\":\"agent@example.com bearer abc.def.ghi\"}}\n");
    try writeFixture(
        root ++ "/artifacts/snapshot-1.xml",
        "<node resource-id=\"password-field\" text=\"hunter2\" content-desc=\"agent@example.com\" /><node text=\"Bearer abc.def.ghi\" />\n",
    );
    try writeFixture(
        root ++ "/artifacts/snapshot-1.json",
        "{\"id\":\"snapshot-1\",\"text\":\"agent@example.com\",\"authToken\":\"abc.def.ghi\"}\n",
    );
    try writeFixture(root ++ "/artifacts/snapshot-1.png", "agent@example.com image bytes");
    try writeFixture(root ++ "/artifacts/screenrecord.mp4", "agent@example.com video bytes");

    try exportTraceBundleWithOptions(allocator, root, out_path, .{ .redact = true });

    const archive = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(archive);
    const names = try tarNames(allocator, archive);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 5), names.len);
    try std.testing.expectEqualStrings("trace.json", names[0]);
    try std.testing.expectEqualStrings("events.jsonl", names[1]);
    try std.testing.expectEqualStrings("artifacts/snapshot-1.json", names[2]);
    try std.testing.expectEqualStrings("artifacts/snapshot-1.png", names[3]);
    try std.testing.expectEqualStrings("artifacts/snapshot-1.xml", names[4]);
    try std.testing.expect(std.mem.indexOf(u8, archive, "redaction") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "screenshotsOmitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "screenshotsRedacted") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "screenRecordingsOmitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\x89PNG\r\n\x1a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "image bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "video bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "agent@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "Bearer abc.def.ghi") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "authToken") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "[REDACTED") != null);
}

test "redacted trace bundle can omit screenshots entirely" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-trace-bundle-redacted-omit-screenshots";
    const out_path = root ++ ".zmrtrace";
    defer test_io.cwd().deleteTree(root) catch {};
    defer test_io.cwd().deleteFile(out_path) catch {};
    try test_io.cwd().makePath(root ++ "/artifacts");
    try writeFixture(root ++ "/trace.json", "{\"schemaVersion\":1,\"status\":\"passed\",\"eventsPath\":\"events.jsonl\",\"artifactsDir\":\"artifacts\"}\n");
    try writeFixture(root ++ "/events.jsonl", "{\"seq\":1,\"kind\":\"scenario.end\",\"payload\":{\"status\":\"passed\"}}\n");
    try writeFixture(root ++ "/artifacts/snapshot-1.json", "{\"id\":\"snapshot-1\",\"text\":\"agent@example.com\"}\n");
    try writeFixture(root ++ "/artifacts/snapshot-1.png", "private screenshot bytes");

    try exportTraceBundleWithOptions(allocator, root, out_path, .{ .redact = true, .omit_screenshots = true });

    const archive = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(archive);
    const names = try tarNames(allocator, archive);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("trace.json", names[0]);
    try std.testing.expectEqualStrings("events.jsonl", names[1]);
    try std.testing.expectEqualStrings("artifacts/snapshot-1.json", names[2]);
    try std.testing.expect(std.mem.indexOf(u8, archive, "private screenshot bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\x89PNG\r\n\x1a\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"screenshots\":\"omitted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"screenshotsOmitted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"screenshotsRedacted\":false") != null);
}

fn writeFixture(path: []const u8, bytes: []const u8) !void {
    var file = try test_io.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn tarNames(allocator: std.mem.Allocator, archive: []const u8) ![][]const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset + 512 <= archive.len) {
        const header = archive[offset .. offset + 512];
        if (allZero(header)) break;
        const raw_name = std.mem.sliceTo(header[0..100], 0);
        const size_field = std.mem.trim(u8, header[124..136], " \x00");
        const size = try std.fmt.parseInt(usize, size_field, 8);
        try names.append(allocator, try allocator.dupe(u8, raw_name));
        offset += 512 + std.mem.alignForward(usize, size, 512);
    }

    return try names.toOwnedSlice(allocator);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
