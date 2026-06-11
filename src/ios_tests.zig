const std = @import("std");
const ios = @import("ios.zig");
const trace = @import("trace.zig");

const IosDevice = ios.IosDevice;
const listDevices = ios.listDevices;
const listPhysicalDevices = ios.listPhysicalDevices;
const parseDevicesJson = ios.parseDevicesJson;
const parsePhysicalDevicesJson = ios.parsePhysicalDevicesJson;

test "ios shim viewport overrides retina screenshot pixels with app frame points" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-ios-shim-viewport";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var shim = try tmp.dir.createFile("fake-ios-shim-viewport.sh", .{ .truncate = true });
    try shim.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\request="$(cat)"
        \\case "$request" in
        \\  *'"cmd":"snapshot"'*)
        \\    cat <<'JSON'
        \\{"status":"ok","viewport":{"width":390,"height":844},"nodes":[{"id":"id:catalog_title","type":"staticText","label":"Catalog","value":"","identifier":"catalog_title","bounds":{"x":24,"y":64,"width":342,"height":34},"enabled":true,"visible":true,"selected":false}]}
        \\JSON
        \\    ;;
        \\  *) printf '{"status":"ok"}\n' ;;
        \\esac
        \\
    );
    try shim.chmod(0o755);
    shim.close();

    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-viewport.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);

    var device = try IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();

    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();

    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 390), snapshot.viewport.width);
    try std.testing.expectEqual(@as(u32, 844), snapshot.viewport.height);
}

test "ios simulator adapter lists devices and supports lifecycle snapshot smoke" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-ios-trace";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    const devices = try listDevices(allocator, "./tests/fake-xcrun.sh");
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }
    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("fake-ios-1", devices[0].serial);
    try std.testing.expectEqualStrings("Booted", devices[0].state);

    var device = try IosDevice.init(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest");
    defer device.deinit();

    try device.install("/tmp/Sample.app");
    try device.launch();
    try device.openLink("exampleapp:///e2e-auth?probe=1");
    try device.stop();
    try device.clearState();

    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();
    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("com.example.mobiletest", snapshot.active_package.?);
    try std.testing.expect(snapshot.screenshot_artifact != null);
    try std.testing.expectEqual(@as(u32, 2), snapshot.viewport.width);
    try std.testing.expectEqual(@as(u32, 3), snapshot.viewport.height);
    try std.testing.expect(snapshot.log_delta != null);
    try std.testing.expectEqual(@as(usize, 0), snapshot.nodes.len);
}

test "ios snapshot honors trace artifact capture controls" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-ios-trace-capture-controls";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    var device = try IosDevice.init(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest");
    defer device.deinit();

    var writer = try trace.TraceWriter.initWithOptions(allocator, dir, .{
        .capture_screenshots = false,
        .capture_hierarchy = false,
        .capture_logs = false,
    });
    defer writer.deinit();

    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("com.example.mobiletest", snapshot.active_package.?);
    try std.testing.expect(snapshot.screenshot_artifact == null);
    try std.testing.expect(snapshot.log_delta == null);
    try std.testing.expectEqual(@as(usize, 0), snapshot.nodes.len);
}

test "ios snapshot preserves screenshot when shim hierarchy extraction fails" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-ios-partial-snapshot";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var shim = try tmp.dir.createFile("fake-ios-shim-snapshot-fail.sh", .{ .truncate = true });
    try shim.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\request="$(cat)"
        \\case "$request" in
        \\  *'"cmd":"snapshot"'*)
        \\    echo "accessibility hierarchy unavailable" >&2
        \\    exit 7
        \\    ;;
        \\  *) printf '{"status":"ok"}\n' ;;
        \\esac
        \\
    );
    try shim.chmod(0o755);
    shim.close();

    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-snapshot-fail.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);

    var device = try IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();

    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();

    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);

    try std.testing.expect(snapshot.screenshot_artifact != null);
    try std.testing.expectEqual(@as(usize, 0), snapshot.nodes.len);

    const events = try std.fs.cwd().readFileAlloc(allocator, dir ++ "/events.jsonl", 4096);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.snapshot.semanticExtraction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"artifactStatus\":\"captured\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"semanticStatus\":\"failed\"") != null);
}

test "ios clear state treats an already uninstalled app as clean" {
    const allocator = std.testing.allocator;
    var device = try IosDevice.init(allocator, "./tests/fake-xcrun-missing-ios-app.sh", "fake-ios-1", "com.example.mobiletest");
    defer device.deinit();

    try device.clearState();
}

test "ios simctl parser filters unavailable and shutdown devices" {
    const allocator = std.testing.allocator;
    const devices = try parseDevicesJson(allocator,
        \\{
        \\  "devices": {
        \\    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
        \\      {"name":"iPhone 16","udid":"booted-1","state":"Booted","isAvailable":true},
        \\      {"name":"iPhone 15","udid":"shutdown-1","state":"Shutdown","isAvailable":true},
        \\      {"name":"iPhone 14","udid":"gone-1","state":"Booted","isAvailable":false}
        \\    ]
        \\  }
        \\}
    );
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }

    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("booted-1", devices[0].serial);
    try std.testing.expectEqualStrings("Booted", devices[0].state);
}

test "ios device listing retries transient CoreSimulator failures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var script = try tmp.dir.createFile("fake-xcrun-flaky.sh", .{ .truncate = true });
    try script.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\
        \\state="$(dirname "$0")/state"
        \\if [[ "${1:-}" == "--version" ]]; then
        \\  printf 'xcrun version 70\n'
        \\  exit 0
        \\fi
        \\if [[ "${1:-}" != "simctl" ]]; then
        \\  echo "expected simctl command: $*" >&2
        \\  exit 2
        \\fi
        \\shift
        \\if [[ ! -e "$state" ]]; then
        \\  touch "$state"
        \\  echo "CoreSimulatorService connection became invalid" >&2
        \\  echo "Failed to initialize simulator device set" >&2
        \\  exit 61
        \\fi
        \\if [[ "${1:-}" == "list" && "${2:-}" == "devices" && "${3:-}" == "--json" ]]; then
        \\  cat <<'JSON'
        \\{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[{"name":"iPhone","udid":"retry-ios-1","state":"Booted","isAvailable":true}]}}
        \\JSON
        \\  exit 0
        \\fi
        \\echo "unsupported simctl command: $*" >&2
        \\exit 2
        \\
    );
    try script.chmod(0o755);
    script.close();

    const script_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-xcrun-flaky.sh", .{tmp.sub_path});
    defer allocator.free(script_path);

    const devices = try listDevices(allocator, script_path);
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }

    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("retry-ios-1", devices[0].serial);
}

test "ios simulator launch treats already running app state as usable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var xcrun = try tmp.dir.createFile("fake-xcrun-launch-fail.sh", .{ .truncate = true });
    try xcrun.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\if [[ "${1:-}" == "simctl" && "${2:-}" == "launch" ]]; then
        \\  echo "launch failed even though the app is already foregrounded" >&2
        \\  exit 2
        \\fi
        \\echo "unexpected xcrun command: $*" >&2
        \\exit 2
        \\
    );
    try xcrun.chmod(0o755);
    xcrun.close();

    var shim = try tmp.dir.createFile("fake-ios-shim-appstate.sh", .{ .truncate = true });
    try shim.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\request="$(cat)"
        \\case "$request" in
        \\  *'"cmd":"appState"'*) printf '{"status":"ok","state":4}\n' ;;
        \\  *) printf '{"status":"error","message":"unsupported command"}\n'; exit 3 ;;
        \\esac
        \\
    );
    try shim.chmod(0o755);
    shim.close();

    const xcrun_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-xcrun-launch-fail.sh", .{tmp.sub_path});
    defer allocator.free(xcrun_path);
    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-appstate.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);

    var device = try IosDevice.initWithShim(allocator, xcrun_path, "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();

    try device.launch();
}

test "ios physical device adapter lists devices and supports devicectl lifecycle" {
    const allocator = std.testing.allocator;

    const devices = try listPhysicalDevices(allocator, "./tests/fake-xcrun.sh");
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }
    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("fake-physical-ios-1", devices[0].serial);
    try std.testing.expectEqualStrings("connected", devices[0].state);

    const dir = "zig-cache/test-ios-physical-trace";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    var device = try IosDevice.initWithKindAndShim(allocator, "./tests/fake-xcrun.sh", "fake-physical-ios-1", "com.example.mobiletest", .physical, "./tests/fake-ios-shim.sh");
    defer device.deinit();

    try device.install("/tmp/Sample.app");
    try device.launch();
    try device.openLink("exampleapp:///e2e-auth?probe=1");
    try device.stop();
    try device.clearState();

    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();
    var snapshot = try device.snapshot(&writer);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", snapshot.active_package.?);
    try std.testing.expect(snapshot.screenshot_artifact != null);
    try std.testing.expectEqual(@as(u32, 2), snapshot.viewport.width);
    try std.testing.expectEqual(@as(u32, 3), snapshot.viewport.height);
    try std.testing.expect(snapshot.log_delta == null);
}

test "ios physical devicectl parser filters iOS physical devices" {
    const allocator = std.testing.allocator;
    const devices = try parsePhysicalDevicesJson(allocator,
        \\{
        \\  "result": {
        \\    "devices": [
        \\      {
        \\        "identifier": "coredevice-1",
        \\        "connectionProperties": {"pairingState": "paired", "tunnelState": "connected"},
        \\        "hardwareProperties": {"platform": "iOS", "reality": "physical", "udid": "physical-1"}
        \\      },
        \\      {
        \\        "identifier": "sim-1",
        \\        "connectionProperties": {"pairingState": "paired"},
        \\        "hardwareProperties": {"platform": "iOS", "reality": "virtual", "udid": "sim-1"}
        \\      },
        \\      {
        \\        "identifier": "watch-1",
        \\        "connectionProperties": {"pairingState": "paired"},
        \\        "hardwareProperties": {"platform": "watchOS", "udid": "watch-1"}
        \\      }
        \\    ]
        \\  }
        \\}
    );
    defer {
        for (devices) |device| device.deinit(allocator);
        allocator.free(devices);
    }

    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("coredevice-1", devices[0].serial);
    try std.testing.expectEqualStrings("connected", devices[0].state);
}

test "ios selector-grade interactions require XCTest shim" {
    const allocator = std.testing.allocator;
    var device = try IosDevice.init(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest");
    defer device.deinit();

    try std.testing.expectError(error.IosXCTestShimRequired, device.tap(1, 2));
    try std.testing.expectError(error.IosXCTestShimRequired, device.typeText("hello"));
    try std.testing.expectError(error.IosXCTestShimRequired, device.eraseText(3));
    try std.testing.expectError(error.IosXCTestShimRequired, device.hideKeyboard());
    try std.testing.expectError(error.IosXCTestShimRequired, device.swipe(1, 2, 3, 4, 5));
    try std.testing.expectError(error.IosXCTestShimRequired, device.pressBack());
}

test "ios xctest shim retries transient bootstrap command failure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var shim = try tmp.dir.createFile("fake-ios-shim-flaky.sh", .{ .truncate = true });
    try shim.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\request="$(cat)"
    );
    const shim_tail = try std.fmt.allocPrint(allocator,
        \\
        \\state_file=".zig-cache/tmp/{s}/attempts"
        \\attempt=0
        \\if [[ -f "$state_file" ]]; then
        \\  attempt="$(cat "$state_file")"
        \\fi
        \\attempt=$((attempt + 1))
        \\printf '%s' "$attempt" > "$state_file"
        \\if [[ "$attempt" -eq 1 ]]; then
        \\  echo "iOS shim server exited before it became ready" >&2
        \\  echo "Early unexpected exit, operation never finished bootstrapping" >&2
        \\  exit 1
        \\fi
        \\case "$request" in
        \\  *'"cmd":"snapshot"'*) printf '{{"status":"ok","nodes":[]}}\n' ;;
        \\  *) printf '{{"status":"ok"}}\n' ;;
        \\esac
        \\
    , .{tmp.sub_path});
    defer allocator.free(shim_tail);
    try shim.writeAll(shim_tail);
    try shim.chmod(0o755);
    shim.close();

    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-flaky.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);
    const attempts_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/attempts", .{tmp.sub_path});
    defer allocator.free(attempts_path);

    var device = try IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();

    var snapshot = try device.snapshot(null);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.nodes.len);

    const attempts = try std.fs.cwd().readFileAlloc(allocator, attempts_path, 1024);
    defer allocator.free(attempts);
    try std.testing.expectEqualStrings("2", attempts);
}

test "ios xctest shim supplies hierarchy and handles selector actions" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-ios-xctest-shim";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    var device = try IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", "./tests/fake-ios-shim.sh");
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
    try std.testing.expect(try device.tapBySelector(.{ .text = "Continue" }));
    try std.testing.expect((try device.visibleBySelector(.{ .text = "Continue" })).?);
    try std.testing.expect(try device.typeTextBySelector(.{ .id = "continue_button" }, "hello"));
    try std.testing.expect(try device.eraseTextBySelector(.{ .content_desc_contains = "continue" }, 5));
    try std.testing.expect(!try device.tapBySelector(.{ .text = "Continue", .id = "continue_button" }));
    try std.testing.expect(try device.visibleBySelector(.{ .text = "Continue", .id = "continue_button" }) == null);
    try device.hideKeyboard();
    try device.swipe(1, 2, 3, 4, 5);
    try device.pressBack();
}

test "ios simulator openLink asks XCTest shim to accept universal link confirmation when available" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var shim = try tmp.dir.createFile("fake-ios-shim-log.sh", .{ .truncate = true });
    try shim.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\request="$(cat)"
    );
    const shim_tail = try std.fmt.allocPrint(allocator,
        \\
        \\printf '%s\n' "$request" >> ".zig-cache/tmp/{s}/shim.log"
        \\printf '{{"status":"ok"}}\n'
        \\
    , .{tmp.sub_path});
    defer allocator.free(shim_tail);
    try shim.writeAll(shim_tail);
    try shim.chmod(0o755);
    shim.close();

    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-log.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);
    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/shim.log", .{tmp.sub_path});
    defer allocator.free(log_path);

    var device = try IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();

    try device.openLink("https://example.com/e2e-auth?probe=1");

    const log = try std.fs.cwd().readFileAlloc(allocator, log_path, 4096);
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"cmd\":\"acceptSystemAlert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"text\":\"Open\"") != null);
}

test "ios simulator openLink asks XCTest shim to accept custom scheme open confirmation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var shim = try tmp.dir.createFile("fake-ios-shim-log.sh", .{ .truncate = true });
    try shim.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\request="$(cat)"
    );
    const shim_tail = try std.fmt.allocPrint(allocator,
        \\
        \\printf '%s\n' "$request" >> ".zig-cache/tmp/{s}/shim.log"
        \\printf '{{"status":"ok"}}\n'
        \\
    , .{tmp.sub_path});
    defer allocator.free(shim_tail);
    try shim.writeAll(shim_tail);
    try shim.chmod(0o755);
    shim.close();

    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-log.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);
    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/shim.log", .{tmp.sub_path});
    defer allocator.free(log_path);

    var device = try IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();

    // SpringBoard raises an "Open in <App>?" confirmation for custom schemes
    // too (the Expo dev-client deep-link case), so the best-effort accept must
    // not be limited to http/https universal links.
    try device.openLink("exp+exampleapp://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081");

    const log = try std.fs.cwd().readFileAlloc(allocator, log_path, 4096);
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"cmd\":\"acceptSystemAlert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"text\":\"Open\"") != null);
}

test "ios simulator openLink skips confirmation acceptance without a shim" {
    const allocator = std.testing.allocator;
    var device = try IosDevice.init(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest");
    defer device.deinit();

    try device.openLink("exampleapp:///e2e-auth?probe=1");
    try device.openLink("https://example.com/e2e-auth?probe=1");
}
