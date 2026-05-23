const std = @import("std");
const cli_output = @import("cli_output.zig");
const doctor = @import("doctor.zig");
const importer = @import("importer.zig");
const validation = @import("validation.zig");

test "validation json preserves source location fields" {
    const allocator = std.testing.allocator;
    const result = validation.Result{
        .ok = false,
        .error_code = try allocator.dupe(u8, "scenario.invalid"),
        .message = try allocator.dupe(u8, "scenario is invalid"),
        .path = try allocator.dupe(u8, "$.steps"),
        .line = 3,
        .column = 3,
    };
    defer result.deinit(allocator);

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try cli_output.writeValidationJson(json.writer(allocator), "bad.json", result);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"fieldPath\":\"$.steps\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"line\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"column\":3") != null);
}

test "validation json gives agents a quoted run handoff for valid scenarios" {
    const allocator = std.testing.allocator;
    const result = validation.Result{
        .ok = true,
        .name = try allocator.dupe(u8, "login smoke"),
        .app_id = try allocator.dupe(u8, "com.example.mobiletest"),
        .step_count = 2,
    };
    defer result.deinit(allocator);

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try cli_output.writeValidationJson(json.writer(allocator), "/tmp/mobile app/login smoke.json", result);

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"path\":\"/tmp/mobile app/login smoke.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"nextCommands\":[\"zmr run '/tmp/mobile app/login smoke.json' --json --trace-dir traces/zmr-run\"]") != null);
}

test "init app json reports generated agent instructions" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try cli_output.writeInitAppJson(json.writer(allocator), ".", "com.example.mobiletest");

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"./.zmr/AGENTS.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"configPath\":\"./.zmr/config.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"androidScenarioPath\":\"./.zmr/android-smoke.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"iosScenarioPath\":\"./.zmr/ios-smoke.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"deviceMatrixPath\":\"./.zmr/device-matrix.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"agentInstructionsPath\":\"./.zmr/AGENTS.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"next\":\"zmr doctor --strict --json --config ./.zmr/config.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"nextCommands\":[\"zmr doctor --strict --json --config ./.zmr/config.json\",\"zmr schemas --json\",\"zmr validate --json ./.zmr/android-smoke.json\",\"zmr validate --json ./.zmr/ios-smoke.json\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"smokeCommands\":[\"zmr run ./.zmr/android-smoke.json --device emulator-5554 --trace-dir ./traces/zmr-android\",\"zmr run ./.zmr/ios-smoke.json --platform ios --device booted --trace-dir ./traces/zmr-ios\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"scriptCount\":16") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"scriptNames\":[\"doctor\",\"schemas\",\"validate\",\"android\",\"androidReport\",\"androidReliability\",\"ios\",\"iosReport\",\"iosReliability\",\"matrix\",\"pilotGate\",\"readiness\",\"serve\",\"mcp\",\"explain\",\"exportTrace\"]") != null);
}

test "init app json shell quotes next commands with spaces in paths" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try cli_output.writeInitAppJson(json.writer(allocator), "/tmp/mobile app", "com.example.mobiletest");

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"configPath\":\"/tmp/mobile app/.zmr/config.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"next\":\"zmr doctor --strict --json --config '/tmp/mobile app/.zmr/config.json'\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"nextCommands\":[\"zmr doctor --strict --json --config '/tmp/mobile app/.zmr/config.json'\",\"zmr schemas --json\",\"zmr validate --json '/tmp/mobile app/.zmr/android-smoke.json'\",\"zmr validate --json '/tmp/mobile app/.zmr/ios-smoke.json'\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"smokeCommands\":[\"zmr run '/tmp/mobile app/.zmr/android-smoke.json' --device emulator-5554 --trace-dir '/tmp/mobile app/traces/zmr-android'\",\"zmr run '/tmp/mobile app/.zmr/ios-smoke.json' --platform ios --device booted --trace-dir '/tmp/mobile app/traces/zmr-ios'\"]") != null);
}

test "init scenario json shell quotes next command with spaces in path" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try cli_output.writeInitScenarioJson(json.writer(allocator), "/tmp/mobile app/login smoke.json", "com.example.mobiletest");

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"created\":[\"/tmp/mobile app/login smoke.json\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"next\":\"zmr validate '/tmp/mobile app/login smoke.json'\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"nextCommands\":[\"zmr validate --json '/tmp/mobile app/login smoke.json'\",\"zmr run '/tmp/mobile app/login smoke.json' --json --trace-dir traces/zmr-run\"]") != null);
}

test "import json shell quotes next command with spaces in path" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const result = importer.ImportResult{
        .out_path = "/tmp/mobile app/imported flow.json",
        .name = "imported flow",
        .app_id = "com.example.mobiletest",
        .step_count = 2,
    };

    try cli_output.writeImportJson(json.writer(allocator), "flow-yaml", "/tmp/mobile app/source flow.yaml", result);

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"out\":\"/tmp/mobile app/imported flow.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"next\":\"zmr validate '/tmp/mobile app/imported flow.json'\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"nextCommands\":[\"zmr validate --json '/tmp/mobile app/imported flow.json'\",\"zmr run '/tmp/mobile app/imported flow.json' --json --trace-dir traces/zmr-run\"]") != null);
}

test "doctor output treats warnings and missing checks as unhealthy" {
    const checks = [_]doctor.Check{
        .{
            .name = "ios-physical-devices",
            .status = .warning,
            .detail = "listed but unavailable",
        },
    };
    try std.testing.expect(!cli_output.doctorChecksHealthy(null, &checks));
}

test "doctor json includes structured device counts for agents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var xcrun_file = try tmp.dir.createFile("fake-xcrun-counts.sh", .{ .truncate = true });
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

    const xcrun_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-xcrun-counts.sh", .{tmp.sub_path});
    defer allocator.free(xcrun_path);

    const checks = try doctor.run(allocator, .{
        .zig_path = "zig",
        .adb_path = "./tests/fake-adb.sh",
        .xcrun_path = xcrun_path,
    });
    defer {
        for (checks) |check| check.deinit(allocator);
        allocator.free(checks);
    }

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try cli_output.writeDoctorJson(json.writer(allocator), null, checks);

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"name\":\"ios-physical-devices\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"count\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"readyCount\":1") != null);
}

test "doctor json includes config script count for agents" {
    const allocator = std.testing.allocator;
    const config_check = doctor.Check{
        .name = "config",
        .status = .ok,
        .detail = ".zmr/config.json",
        .script_count = 12,
        .script_names = &.{ "doctor", "android", "mcp" },
    };

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try cli_output.writeDoctorJson(json.writer(allocator), config_check, &.{});

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"name\":\"config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"scriptCount\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"scriptNames\":[\"doctor\",\"android\",\"mcp\"]") != null);
}
