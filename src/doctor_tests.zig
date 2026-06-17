const std = @import("std");
const test_io = @import("test_io.zig");
const doctor = @import("doctor.zig");

const Status = doctor.Status;
const checkCommand = doctor.checkCommand;
const checkConfigError = doctor.checkConfigError;
const run = doctor.run;

test "doctor command check reports ok warning and missing" {
    const allocator = std.testing.allocator;

    const ok = try checkCommand(allocator, "ok", &.{ "/bin/sh", "-c", "printf ready" });
    defer ok.deinit(allocator);
    try std.testing.expectEqual(Status.ok, ok.status);
    try std.testing.expectEqualStrings("ready", ok.detail);

    const warning = try checkCommand(allocator, "warning", &.{ "/bin/sh", "-c", "printf bad >&2; exit 7" });
    defer warning.deinit(allocator);
    try std.testing.expectEqual(Status.warning, warning.status);
    try std.testing.expect(std.mem.indexOf(u8, warning.detail, "exit 7") != null);

    const missing = try checkCommand(allocator, "missing", &.{"/definitely/not/zmr-tool"});
    defer missing.deinit(allocator);
    try std.testing.expectEqual(Status.missing, missing.status);
    try std.testing.expectEqualStrings("setup.tool.not_found", missing.error_code.?);
}

test "doctor checks include remediation hints for actionable failures" {
    const allocator = std.testing.allocator;

    const ok = try checkCommand(allocator, "zig", &.{ "/bin/sh", "-c", "printf ready" });
    defer ok.deinit(allocator);
    try std.testing.expect(ok.hint == null);

    const warning = try checkCommand(allocator, "zig", &.{ "/bin/sh", "-c", "printf bad >&2; exit 7" });
    defer warning.deinit(allocator);
    try std.testing.expect(warning.hint != null);
    try std.testing.expectEqualStrings("setup.zig.command_failed", warning.error_code.?);
    try std.testing.expect(std.mem.indexOf(u8, warning.hint.?, "Zig") != null);

    const missing = try checkCommand(allocator, "adb", &.{"/definitely/not/zmr-tool"});
    defer missing.deinit(allocator);
    try std.testing.expect(missing.hint != null);
    try std.testing.expectEqualStrings("setup.adb.not_found", missing.error_code.?);
    try std.testing.expect(std.mem.indexOf(u8, missing.hint.?, "Android SDK Platform Tools") != null);
}

test "doctor config errors include stable codes and field paths" {
    const allocator = std.testing.allocator;

    const check = try checkConfigError(allocator, ".zmr/config.json", error.ConfigFieldMustBeNonEmptyString, "$.scripts.android");
    defer check.deinit(allocator);

    try std.testing.expectEqual(Status.warning, check.status);
    try std.testing.expectEqualStrings("config.empty_string", check.error_code.?);
    try std.testing.expectEqualStrings("$.scripts.android", check.field_path.?);
    try std.testing.expect(check.hint != null);
}

test "doctor run reports fake device counts" {
    const allocator = std.testing.allocator;
    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .xcrun_path = "./tests/fake-xcrun.sh",
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqual(@as(usize, 6), checks.len);
    try std.testing.expectEqualStrings("1 Android device(s)", checks[2].detail);
    try std.testing.expectEqualStrings("1 booted iOS simulator(s)", checks[4].detail);
    try std.testing.expectEqualStrings("ios-physical-devices", checks[5].name);
    try std.testing.expectEqualStrings("1 ready physical iOS device(s)", checks[5].detail);
}

test "doctor warns when no mobile devices are ready" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var adb_file = try test_io.createFileIn(tmp.dir, "fake-adb-empty.sh", .{ .truncate = true });
    try adb_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\case "${1:-}" in
        \\  version) printf 'Android Debug Bridge version 1.0.41\n' ;;
        \\  devices) printf 'List of devices attached\n' ;;
        \\  *) exit 2 ;;
        \\esac
        \\
    );
    try adb_file.chmod(0o755);
    adb_file.close();

    var xcrun_file = try test_io.createFileIn(tmp.dir, "fake-xcrun-empty.sh", .{ .truncate = true });
    try xcrun_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\if [[ "${1:-}" == "--version" ]]; then
        \\  printf 'xcrun version 70\n'
        \\  exit 0
        \\fi
        \\if [[ "${1:-}" == "simctl" && "${2:-}" == "list" && "${3:-}" == "devices" && "${4:-}" == "--json" ]]; then
        \\  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[]}}\n'
        \\  exit 0
        \\fi
        \\if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
        \\  while [[ $# -gt 0 ]]; do
        \\    if [[ "${1:-}" == "--json-output" ]]; then
        \\      printf '{"result":{"devices":[]}}\n' > "${2:-}"
        \\      exit 0
        \\    fi
        \\    shift
        \\  done
        \\fi
        \\exit 2
        \\
    );
    try xcrun_file.chmod(0o755);
    xcrun_file.close();

    const adb_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-adb-empty.sh", .{tmp.sub_path});
    defer allocator.free(adb_path);
    const xcrun_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-xcrun-empty.sh", .{tmp.sub_path});
    defer allocator.free(xcrun_path);

    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = adb_path,
        .xcrun_path = xcrun_path,
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqual(Status.warning, checks[2].status);
    try std.testing.expectEqualStrings("setup.android.no_devices", checks[2].error_code.?);
    try std.testing.expectEqualStrings("0 Android device(s)", checks[2].detail);
    try std.testing.expect(checks[2].hint != null);

    try std.testing.expectEqual(Status.warning, checks[4].status);
    try std.testing.expectEqualStrings("setup.ios.no_booted_simulators", checks[4].error_code.?);
    try std.testing.expectEqualStrings("0 booted iOS simulator(s)", checks[4].detail);
    try std.testing.expect(checks[4].hint != null);

    try std.testing.expectEqual(Status.warning, checks[5].status);
    try std.testing.expectEqualStrings("setup.ios.no_physical_devices", checks[5].error_code.?);
    try std.testing.expectEqualStrings("0 physical iOS device(s)", checks[5].detail);
    try std.testing.expect(checks[5].hint != null);
}

test "doctor warns when physical ios devices are listed but unavailable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var xcrun_file = try test_io.createFileIn(tmp.dir, "fake-xcrun-unavailable-physical.sh", .{ .truncate = true });
    try xcrun_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\if [[ "${1:-}" == "--version" ]]; then
        \\  printf 'xcrun version 70\n'
        \\  exit 0
        \\fi
        \\if [[ "${1:-}" == "simctl" && "${2:-}" == "list" && "${3:-}" == "devices" && "${4:-}" == "--json" ]]; then
        \\  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[{"name":"iPhone","udid":"sim-1","state":"Booted","isAvailable":true}]}}\n'
        \\  exit 0
        \\fi
        \\if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
        \\  while [[ $# -gt 0 ]]; do
        \\    if [[ "${1:-}" == "--json-output" ]]; then
        \\      cat > "${2:-}" <<'JSON'
        \\{"result":{"devices":[
        \\  {"identifier":"unavailable-1","connectionProperties":{"pairingState":"unavailable","tunnelState":"unavailable"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"unavailable-1"}},
        \\  {"identifier":"disconnected-1","connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"disconnected-1"}}
        \\]}}
        \\JSON
        \\      exit 0
        \\    fi
        \\    shift
        \\  done
        \\fi
        \\exit 2
        \\
    );
    try xcrun_file.chmod(0o755);
    xcrun_file.close();

    const xcrun_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-xcrun-unavailable-physical.sh", .{tmp.sub_path});
    defer allocator.free(xcrun_path);

    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .xcrun_path = xcrun_path,
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqual(Status.warning, checks[5].status);
    try std.testing.expectEqualStrings("setup.ios.no_ready_physical_devices", checks[5].error_code.?);
    try std.testing.expectEqualStrings("0 ready physical iOS device(s); 2 listed (disconnected=1, unavailable=1)", checks[5].detail);
    try std.testing.expect(checks[5].hint != null);
}

test "doctor reports listed physical ios device breakdown when some are ready" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var xcrun_file = try test_io.createFileIn(tmp.dir, "fake-xcrun-mixed-physical.sh", .{ .truncate = true });
    try xcrun_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\if [[ "${1:-}" == "--version" ]]; then
        \\  printf 'xcrun version 70\n'
        \\  exit 0
        \\fi
        \\if [[ "${1:-}" == "simctl" && "${2:-}" == "list" && "${3:-}" == "devices" && "${4:-}" == "--json" ]]; then
        \\  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[{"name":"iPhone","udid":"sim-1","state":"Booted","isAvailable":true}]}}\n'
        \\  exit 0
        \\fi
        \\if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
        \\  while [[ $# -gt 0 ]]; do
        \\    if [[ "${1:-}" == "--json-output" ]]; then
        \\      cat > "${2:-}" <<'JSON'
        \\{"result":{"devices":[
        \\  {"identifier":"ready-1","connectionProperties":{"pairingState":"paired","tunnelState":"connected"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"ready-1"}},
        \\  {"identifier":"unavailable-1","connectionProperties":{"pairingState":"unavailable","tunnelState":"unavailable"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"unavailable-1"}},
        \\  {"identifier":"disconnected-1","connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"disconnected-1"}}
        \\]}}
        \\JSON
        \\      exit 0
        \\    fi
        \\    shift
        \\  done
        \\fi
        \\exit 2
        \\
    );
    try xcrun_file.chmod(0o755);
    xcrun_file.close();

    const xcrun_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-xcrun-mixed-physical.sh", .{tmp.sub_path});
    defer allocator.free(xcrun_path);

    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .xcrun_path = xcrun_path,
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqual(Status.ok, checks[5].status);
    try std.testing.expectEqualStrings("1 ready physical iOS device(s); 3 listed (disconnected=1, unavailable=1)", checks[5].detail);
}

test "doctor reports configured ios shim path" {
    const allocator = std.testing.allocator;
    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .xcrun_path = "./tests/fake-xcrun.sh",
        .ios_shim_path = "./tests/fake-ios-shim.sh",
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqual(@as(usize, 7), checks.len);
    try std.testing.expectEqualStrings("ios-shim", checks[6].name);
    try std.testing.expectEqual(Status.ok, checks[6].status);
}

test "doctor reports configured android shim path" {
    const allocator = std.testing.allocator;
    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .android_shim_path = "./tests/fake-android-shim.sh",
        .xcrun_path = "./tests/fake-xcrun.sh",
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqual(@as(usize, 7), checks.len);
    try std.testing.expectEqualStrings("android-shim", checks[3].name);
    try std.testing.expectEqual(Status.ok, checks[3].status);
}

test "doctor reports configured smoke scenario paths" {
    const allocator = std.testing.allocator;
    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .android_smoke_scenario = "examples/demo-fake.json",
        .xcrun_path = "./tests/fake-xcrun.sh",
        .ios_smoke_scenario = "./definitely-missing-ios-smoke.json",
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqual(@as(usize, 8), checks.len);
    try std.testing.expectEqualStrings("android-smoke-scenario", checks[3].name);
    try std.testing.expectEqual(Status.ok, checks[3].status);
    try std.testing.expectEqualStrings("ios-smoke-scenario", checks[7].name);
    try std.testing.expectEqual(Status.missing, checks[7].status);
    try std.testing.expect(checks[7].hint != null);
    try std.testing.expect(std.mem.indexOf(u8, checks[7].hint.?, "smokeScenario") != null);
}

test "doctor warns when configured smoke scenario is invalid" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/test-doctor-invalid-smoke.json";
    try test_io.cwd().makePath("zig-cache");
    try test_io.cwd().writeFile(.{ .sub_path = path, .data = "{\n  \"name\": \"bad\",\n  \"steps\": \"nope\"\n}\n" });
    defer test_io.cwd().deleteFile(path) catch {};

    const checks = try run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .android_smoke_scenario = path,
        .xcrun_path = "./tests/fake-xcrun.sh",
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    try std.testing.expectEqualStrings("android-smoke-scenario", checks[3].name);
    try std.testing.expectEqual(Status.warning, checks[3].status);
    try std.testing.expect(std.mem.indexOf(u8, checks[3].detail, "scenario.invalid") != null);
    try std.testing.expect(checks[3].hint != null);
    try std.testing.expect(std.mem.indexOf(u8, checks[3].hint.?, "zmr validate") != null);
}
