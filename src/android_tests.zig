const std = @import("std");
const test_io = @import("test_io.zig");
const android = @import("android.zig");
const trace = @import("trace.zig");

const AndroidDevice = android.AndroidDevice;
const parseActiveWindow = android.parseActiveWindow;
const parseDisplayDensityDpi = android.parseDisplayDensityDpi;
const parseViewport = android.parseViewport;
const listDevices = android.listDevices;

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

test "parse active window package and activity" {
    const active = try parseActiveWindow(std.testing.allocator, "mCurrentFocus=Window{123 u0 com.example.mobiletest/.MainActivity}\n");
    defer active.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", active.package.?);
    try std.testing.expectEqualStrings(".MainActivity", active.activity.?);
}

test "parse viewport" {
    const viewport = try parseViewport("Physical size: 1080x2400\nOverride size: 1080x2200\n");
    try std.testing.expectEqual(@as(u32, 1080), viewport.width);
    try std.testing.expectEqual(@as(u32, 2400), viewport.height);
}

test "parse display density dpi" {
    try std.testing.expectEqual(@as(?u32, 420), parseDisplayDensityDpi("Physical density: 420\nOverride density: 440\n"));
    try std.testing.expectEqual(@as(?u32, null), parseDisplayDensityDpi("Override density: 440\n"));
}

test "android device actions and snapshot work through fake adb" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-android-trace";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var device = try AndroidDevice.init(allocator, "./tests/fake-adb.sh", "fake-android-1", "com.example.mobiletest");
    defer device.deinit();

    try device.install("/tmp/app.apk");
    try device.launch();
    try device.stop();
    try device.clearState();
    try device.openLink("exampleapp://probe");
    try device.tap(10, 20);
    try device.typeText("hello world");
    try device.eraseText(3);
    try device.hideKeyboard();
    try device.swipe(1, 2, 3, 4, 5);
    try device.pressBack();

    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();
    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", snapshot.active_package.?);
    try std.testing.expectEqualStrings(".MainActivity", snapshot.active_activity.?);
    try std.testing.expectEqual(@as(u32, 720), snapshot.viewport.width);
    try std.testing.expectEqual(@as(u32, 1280), snapshot.viewport.height);
    try std.testing.expectEqual(@as(?u32, 420), snapshot.display_density_dpi);
    try std.testing.expect(snapshot.screenshot_artifact != null);
    try std.testing.expect(snapshot.tree_artifact != null);
    try std.testing.expect(snapshot.log_delta != null);
    try std.testing.expect(snapshot.nodes.len > 0);

    const devices = try listDevices(allocator, "./tests/fake-adb.sh");
    defer {
        for (devices) |info| info.deinit(allocator);
        allocator.free(devices);
    }
    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("fake-android-1", devices[0].serial);
    try std.testing.expectEqualStrings("device", devices[0].state);
}

test "android openLink starts intent without waiting for activity launch completion" {
    const allocator = std.testing.allocator;
    const log_path = "zig-cache/test-android-open-link-adb.log";
    const adb_path = "zig-cache/test-android-open-link-adb.sh";
    try test_io.cwd().makePath("zig-cache");
    test_io.cwd().deleteFile(log_path) catch {};
    test_io.cwd().deleteFile(adb_path) catch {};
    defer test_io.cwd().deleteFile(log_path) catch {};
    defer test_io.cwd().deleteFile(adb_path) catch {};

    var adb_file = try test_io.cwd().createFile(adb_path, .{ .truncate = true });
    try adb_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\printf '%s\n' "$*" >> zig-cache/test-android-open-link-adb.log
        \\exec ./tests/fake-adb.sh "$@"
        \\
    );
    try adb_file.chmod(0o755);
    adb_file.close();

    var device = try AndroidDevice.init(allocator, adb_path, "fake-android-1", "com.example.mobiletest");
    defer device.deinit();

    try device.openLink("exampleapp://probe");

    const contents = try test_io.cwd().readFileAlloc(allocator, log_path, 4096);
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "shell am start ") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, " -W ") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "android.intent.action.VIEW") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "exampleapp://probe") != null);
}

test "android openLink escapes multi parameter deep links for adb shell" {
    const allocator = std.testing.allocator;
    const log_path = "zig-cache/test-android-open-link-escaped-adb.log";
    const adb_path = "zig-cache/test-android-open-link-escaped-adb.sh";
    try test_io.cwd().makePath("zig-cache");
    test_io.cwd().deleteFile(log_path) catch {};
    test_io.cwd().deleteFile(adb_path) catch {};
    defer test_io.cwd().deleteFile(log_path) catch {};
    defer test_io.cwd().deleteFile(adb_path) catch {};

    var adb_file = try test_io.cwd().createFile(adb_path, .{ .truncate = true });
    try adb_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\printf '%s\n' "$*" >> zig-cache/test-android-open-link-escaped-adb.log
        \\exec ./tests/fake-adb.sh "$@"
        \\
    );
    try adb_file.chmod(0o755);
    adb_file.close();

    var device = try AndroidDevice.init(allocator, adb_path, "fake-android-1", "com.example.mobiletest");
    defer device.deinit();

    try device.openLink("exampleapp:///e2e-auth?email=a%40example.com&password=Test1234%21&returnTo=%2Fbank-connection");

    const contents = try test_io.cwd().readFileAlloc(allocator, log_path, 4096);
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "'exampleapp:///e2e-auth?email=a%40example.com&password=Test1234%21&returnTo=%2Fbank-connection'") != null);
}

test "android openLink retries when deep link leaves launcher foregrounded" {
    const allocator = std.testing.allocator;
    const log_path = "zig-cache/test-android-open-link-retry-adb.log";
    const state_path = "zig-cache/test-android-open-link-retry-state";
    const adb_path = "zig-cache/test-android-open-link-retry-adb.sh";
    try test_io.cwd().makePath("zig-cache");
    test_io.cwd().deleteFile(log_path) catch {};
    test_io.cwd().deleteFile(state_path) catch {};
    test_io.cwd().deleteFile(adb_path) catch {};
    defer test_io.cwd().deleteFile(log_path) catch {};
    defer test_io.cwd().deleteFile(state_path) catch {};
    defer test_io.cwd().deleteFile(adb_path) catch {};

    var adb_file = try test_io.cwd().createFile(adb_path, .{ .truncate = true });
    try adb_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\printf '%s\n' "$*" >> zig-cache/test-android-open-link-retry-adb.log
        \\if [[ "${1:-}" == "-s" ]]; then shift 2; fi
        \\if [[ "${1:-}" == "shell" && "${2:-}" == "dumpsys" ]]; then
        \\  count="$(cat zig-cache/test-android-open-link-retry-state 2>/dev/null || printf '0')"
        \\  count=$((count + 1))
        \\  printf '%s' "$count" > zig-cache/test-android-open-link-retry-state
        \\  if [[ "$count" -eq 1 ]]; then
        \\    printf 'mCurrentFocus=Window{123 u0 com.google.android.apps.nexuslauncher/.NexusLauncherActivity}\n'
        \\  else
        \\    printf 'mCurrentFocus=Window{123 u0 com.example.mobiletest/.MainActivity}\n'
        \\  fi
        \\  exit 0
        \\fi
        \\exec ./tests/fake-adb.sh "$@"
        \\
    );
    try adb_file.chmod(0o755);
    adb_file.close();

    var device = try AndroidDevice.init(allocator, adb_path, "fake-android-1", "com.example.mobiletest");
    defer device.deinit();

    try device.openLink("exampleapp://probe");

    const contents = try test_io.cwd().readFileAlloc(allocator, log_path, 8192);
    defer allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(contents, "shell am start"));
}

test "android snapshot honors trace artifact capture controls" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-android-trace-capture-controls";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var device = try AndroidDevice.init(allocator, "./tests/fake-adb.sh", "fake-android-1", "com.example.mobiletest");
    defer device.deinit();

    var writer = try trace.TraceWriter.initWithOptions(allocator, dir, .{
        .capture_screenshots = false,
        .capture_hierarchy = false,
        .capture_logs = false,
    });
    defer writer.deinit();

    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);

    try std.testing.expect(snapshot.screenshot_artifact == null);
    try std.testing.expect(snapshot.tree_artifact == null);
    try std.testing.expect(snapshot.log_delta == null);
    try std.testing.expect(snapshot.nodes.len > 0);
}

test "android screen recording pulls mp4 into trace artifacts" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-android-screen-recording";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var device = try AndroidDevice.init(allocator, "./tests/fake-adb.sh", "fake-android-1", "com.example.mobiletest");
    defer device.deinit();

    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();

    var recording = try device.startScreenRecording("/sdcard/zmr-trace-screenrecord.mp4");
    defer recording.deinit();

    const artifact_path = try recording.stopAndPull(&writer, "screenrecord.mp4");
    defer allocator.free(artifact_path);

    const bytes = try test_io.cwd().readFileAlloc(allocator, artifact_path, 1024);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("FAKE_MP4\n", bytes);
}

test "android native shim supplies hierarchy and handles actions" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-android-native-shim";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var device = try AndroidDevice.initWithShim(allocator, "./tests/fake-adb.sh", "fake-android-1", "com.example.mobiletest", "./tests/fake-android-shim.sh");
    defer device.deinit();

    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();

    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.nodes.len);
    try std.testing.expectEqualStrings("Continue", snapshot.nodes[0].text.?);
    try std.testing.expectEqualStrings("continue_button", snapshot.nodes[0].resource_id.?);

    try device.tap(60, 42);
    try device.typeText("hello");
    try device.eraseText(5);
    try device.hideKeyboard();
    try device.swipe(1, 2, 3, 4, 5);
    try device.pressBack();
}
