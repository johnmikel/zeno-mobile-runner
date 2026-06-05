const std = @import("std");
const scaffold = @import("scaffold.zig");

test "app scaffold exposes generated file list for init output metadata" {
    try std.testing.expectEqualStrings(".zmr/config.json", scaffold.app_config_file);
    try std.testing.expectEqualStrings(".zmr/android-smoke.json", scaffold.app_android_smoke_file);
    try std.testing.expectEqualStrings(".zmr/ios-smoke.json", scaffold.app_ios_smoke_file);
    try std.testing.expectEqualStrings(".zmr/device-matrix.json", scaffold.app_device_matrix_file);
    try std.testing.expectEqualStrings(".zmr/AGENTS.md", scaffold.app_agents_file);
    try std.testing.expectEqual(@as(usize, 5), scaffold.app_created_files.len);
    try std.testing.expectEqualStrings(scaffold.app_config_file, scaffold.app_created_files[0]);
    try std.testing.expectEqualStrings(scaffold.app_android_smoke_file, scaffold.app_created_files[1]);
    try std.testing.expectEqualStrings(scaffold.app_ios_smoke_file, scaffold.app_created_files[2]);
    try std.testing.expectEqualStrings(scaffold.app_device_matrix_file, scaffold.app_created_files[3]);
    try std.testing.expectEqualStrings(scaffold.app_agents_file, scaffold.app_created_files[4]);
}

test "app scaffold exposes generated script names for init and doctor metadata" {
    try std.testing.expectEqual(@as(usize, 16), scaffold.app_script_names.len);
    try std.testing.expectEqualStrings("doctor", scaffold.app_script_names[0]);
    try std.testing.expectEqualStrings("schemas", scaffold.app_script_names[1]);
    try std.testing.expectEqualStrings("validate", scaffold.app_script_names[2]);
    try std.testing.expectEqualStrings("android", scaffold.app_script_names[3]);
    try std.testing.expectEqualStrings("androidReport", scaffold.app_script_names[4]);
    try std.testing.expectEqualStrings("androidReliability", scaffold.app_script_names[5]);
    try std.testing.expectEqualStrings("ios", scaffold.app_script_names[6]);
    try std.testing.expectEqualStrings("iosReport", scaffold.app_script_names[7]);
    try std.testing.expectEqualStrings("iosReliability", scaffold.app_script_names[8]);
    try std.testing.expectEqualStrings("matrix", scaffold.app_script_names[9]);
    try std.testing.expectEqualStrings("pilotGate", scaffold.app_script_names[10]);
    try std.testing.expectEqualStrings("readiness", scaffold.app_script_names[11]);
    try std.testing.expectEqualStrings("serve", scaffold.app_script_names[12]);
    try std.testing.expectEqualStrings("mcp", scaffold.app_script_names[13]);
    try std.testing.expectEqualStrings("explain", scaffold.app_script_names[14]);
    try std.testing.expectEqualStrings("exportTrace", scaffold.app_script_names[15]);
}

test "starter scenario scaffolder writes a valid scenario and protects existing files" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-scaffold";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);

    const path = dir ++ "/scenario.json";
    try scaffold.writeStarterScenario(allocator, path, "com.example.mobiletest", false);
    try std.testing.expectError(error.PathAlreadyExists, scaffold.writeStarterScenario(allocator, path, "com.example.mobiletest", false));
    try scaffold.writeStarterScenario(allocator, path, "com.example.app", true);

    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"appId\": \"com.example.app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"action\": \"launch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"action\": \"assertHealthy\"") != null);
}

test "app scaffold writes config smoke scenarios and gitignore without overwriting" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-app-scaffold";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);

    try scaffold.writeAppScaffold(allocator, dir, "com.example.mobiletest", false);

    const config_path = dir ++ "/.zmr/config.json";
    const android_path = dir ++ "/.zmr/android-smoke.json";
    const ios_path = dir ++ "/.zmr/ios-smoke.json";
    const matrix_path = dir ++ "/.zmr/device-matrix.json";
    const agent_path = dir ++ "/.zmr/AGENTS.md";

    const config = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"schemaVersion\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"appId\": \"com.example.mobiletest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"doctor\": \"zmr doctor --strict --json --config .zmr/config.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"schemas\": \"zmr schemas --json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"validate\": \"zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"androidReport\": \"zmr report traces/zmr-android --out traces/zmr-android/report.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"androidReliability\": \"export ZMR_BIN=\\\"${ZMR_BIN:-zmr}\\\"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.mobiletest --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && \\\"$ZMR_BIN\\\" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"iosReport\": \"zmr report traces/zmr-ios --out traces/zmr-ios/report.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"iosReliability\": \"export ZMR_BIN=\\\"${ZMR_BIN:-zmr}\\\"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.mobiletest --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && \\\"$ZMR_BIN\\\" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"matrix\": \"ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"pilotGate\": \"zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.mobiletest --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.mobiletest --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"readiness\": \"zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"serve\": \"zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"mcp\": \"zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"explain\": \"zmr explain traces/zmr-agent --json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"exportTrace\": \"zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"smokeScenario\": \".zmr/android-smoke.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"smokeScenario\": \".zmr/ios-smoke.json\"") != null);

    const android = try std.fs.cwd().readFileAlloc(allocator, android_path, 1024 * 1024);
    defer allocator.free(android);
    try std.testing.expect(std.mem.indexOf(u8, android, "\"name\": \"Android smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, android, "\"action\": \"assertHealthy\"") != null);

    const ios = try std.fs.cwd().readFileAlloc(allocator, ios_path, 1024 * 1024);
    defer allocator.free(ios);
    try std.testing.expect(std.mem.indexOf(u8, ios, "\"name\": \"iOS smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ios, "\"action\": \"assertHealthy\"") != null);

    const matrix = try std.fs.cwd().readFileAlloc(allocator, matrix_path, 1024 * 1024);
    defer allocator.free(matrix);
    try std.testing.expect(std.mem.indexOf(u8, matrix, "\"appId\": \"com.example.mobiletest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, matrix, "\"name\": \"android-emulator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, matrix, "\"iosDeviceType\": \"simulator\"") != null);

    const agent = try std.fs.cwd().readFileAlloc(allocator, agent_path, 1024 * 1024);
    defer allocator.free(agent);
    try std.testing.expect(std.mem.indexOf(u8, agent, "# ZMR Agent Instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "App id: `com.example.mobiletest`") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr inspect --json --dir .") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr doctor --strict --json --config .zmr/config.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr schemas --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr report traces/zmr-android --out traces/zmr-android/report.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.mobiletest --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr report traces/zmr-ios --out traces/zmr-ios/report.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.mobiletest --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr explain traces/zmr-agent --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "Use `recommendedWording` and keep `claimLimitations` intact") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "Use `satisfied` for proven requirements; do not infer readiness from raw `passed` evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "When readiness is blocked, follow `nextSteps[].commands` in order") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "Do not claim production readiness from smoke runs alone") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "Use `semantic_snapshot` before choosing tap or type actions") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "## App Commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr report traces/zmr-android --out traces/zmr-android/report.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr report traces/zmr-ios --out traces/zmr-ios/report.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "traces/zmr-android-reliability/report.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "traces/zmr-ios-reliability/report.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.mobiletest --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.mobiletest --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "npm run zmr:") == null);

    const gitignore = try std.fs.cwd().readFileAlloc(allocator, dir ++ "/.gitignore", 1024 * 1024);
    defer allocator.free(gitignore);
    try std.testing.expect(std.mem.indexOf(u8, gitignore, "traces/") != null);

    var edited_android = try std.fs.cwd().createFile(android_path, .{ .truncate = true });
    try edited_android.writeAll(
        \\{
        \\  "name": "Custom Android smoke",
        \\  "appId": "com.example.mobiletest",
        \\  "steps": [
        \\    { "action": "launch" }
        \\  ]
        \\}
        \\
    );
    edited_android.close();

    try scaffold.writeAppScaffold(allocator, dir, "com.example.other", false);

    const overwritten = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(overwritten);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "\"appId\": \"com.example.other\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "--android-app-id com.example.other") != null);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "--android-device emulator-5554") != null);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "--ios-app-id com.example.other") != null);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "--ios-device booted") != null);

    const overwritten_agent = try std.fs.cwd().readFileAlloc(allocator, agent_path, 1024 * 1024);
    defer allocator.free(overwritten_agent);
    try std.testing.expect(std.mem.indexOf(u8, overwritten_agent, "App id: `com.example.other`") != null);

    const preserved_android = try std.fs.cwd().readFileAlloc(allocator, android_path, 1024 * 1024);
    defer allocator.free(preserved_android);
    try std.testing.expect(std.mem.indexOf(u8, preserved_android, "\"name\": \"Custom Android smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, preserved_android, "\"appId\": \"com.example.mobiletest\"") != null);

    try scaffold.writeAppScaffold(allocator, dir, "com.example.force", true);
    const forced_android = try std.fs.cwd().readFileAlloc(allocator, android_path, 1024 * 1024);
    defer allocator.free(forced_android);
    try std.testing.expect(std.mem.indexOf(u8, forced_android, "\"name\": \"Android smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, forced_android, "\"appId\": \"com.example.force\"") != null);
}

test "app scaffold shell quotes app ids in generated commands" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-app-scaffold-quoted";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);

    try scaffold.writeAppScaffold(allocator, dir, "com.example mobile's", false);

    const config = try std.fs.cwd().readFileAlloc(allocator, dir ++ "/.zmr/config.json", 1024 * 1024);
    defer allocator.free(config);
    const agent = try std.fs.cwd().readFileAlloc(allocator, dir ++ "/.zmr/AGENTS.md", 1024 * 1024);
    defer allocator.free(agent);

    const shell_quoted_app_id = "'com.example mobile'\\''s'";
    const json_quoted_app_id = "'com.example mobile'\\\\''s'";
    const config_app_id_arg = try std.fmt.allocPrint(allocator, "--app-id {s} --runs", .{json_quoted_app_id});
    defer allocator.free(config_app_id_arg);
    const config_android_app_id_arg = try std.fmt.allocPrint(allocator, "--android-app-id {s} --android-device", .{json_quoted_app_id});
    defer allocator.free(config_android_app_id_arg);
    const config_ios_app_id_arg = try std.fmt.allocPrint(allocator, "--ios-app-id {s} --ios-device", .{json_quoted_app_id});
    defer allocator.free(config_ios_app_id_arg);
    const agent_app_id_arg = try std.fmt.allocPrint(allocator, "--app-id {s} --runs", .{shell_quoted_app_id});
    defer allocator.free(agent_app_id_arg);
    const agent_android_app_id_arg = try std.fmt.allocPrint(allocator, "--android-app-id {s} --android-device", .{shell_quoted_app_id});
    defer allocator.free(agent_android_app_id_arg);
    const agent_ios_app_id_arg = try std.fmt.allocPrint(allocator, "--ios-app-id {s} --ios-device", .{shell_quoted_app_id});
    defer allocator.free(agent_ios_app_id_arg);

    try std.testing.expect(std.mem.indexOf(u8, config, "\"appId\": \"com.example mobile's\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, config_app_id_arg) != null);
    try std.testing.expect(std.mem.indexOf(u8, config, config_android_app_id_arg) != null);
    try std.testing.expect(std.mem.indexOf(u8, config, config_ios_app_id_arg) != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, agent_app_id_arg) != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, agent_android_app_id_arg) != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, agent_ios_app_id_arg) != null);
}
