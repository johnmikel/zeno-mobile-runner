const std = @import("std");
const config = @import("config.zig");

const parseSlice = config.parseSlice;
const errorFieldPathForSlice = config.errorFieldPathForSlice;

test "config parser reads app-local defaults" {
    var cfg = try parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "appId": "com.example.mobiletest",
        \\  "android": {
        \\    "enabled": true,
        \\    "defaultDevice": "emulator-5554",
        \\    "smokeScenario": ".zmr/android-smoke.json",
        \\    "traceDir": "traces/android",
        \\    "avdName": "Small_Phone",
        \\    "restoreSnapshot": "zmr-clean",
        \\    "resetBeforeRun": true,
        \\    "waitReady": true,
        \\    "createAvdIfMissing": true,
        \\    "avdSystemImage": "system-images;android-35;google_apis;arm64-v8a",
        \\    "avdDeviceProfile": "pixel_6"
        \\  },
        \\  "tools": {
        \\    "adbPath": "./fake-adb",
        \\    "avdmanagerPath": "./fake-avdmanager",
        \\    "androidShimPath": "./fake-android-shim",
        \\    "iosShimPath": "./fake-ios-shim"
        \\  }
        \\}
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), cfg.schema_version);
    try std.testing.expectEqualStrings("com.example.mobiletest", cfg.app_id.?);
    try std.testing.expect(cfg.android.enabled);
    try std.testing.expectEqualStrings("emulator-5554", cfg.android.default_device.?);
    try std.testing.expectEqualStrings(".zmr/android-smoke.json", cfg.android.smoke_scenario.?);
    try std.testing.expectEqualStrings("traces/android", cfg.android.trace_dir.?);
    try std.testing.expectEqualStrings("Small_Phone", cfg.android.avd_name.?);
    try std.testing.expectEqualStrings("zmr-clean", cfg.android.restore_snapshot.?);
    try std.testing.expect(cfg.android.reset_before_run);
    try std.testing.expect(cfg.android.wait_ready);
    try std.testing.expect(cfg.android.create_avd_if_missing);
    try std.testing.expectEqualStrings("system-images;android-35;google_apis;arm64-v8a", cfg.android.avd_system_image.?);
    try std.testing.expectEqualStrings("pixel_6", cfg.android.avd_device_profile.?);
    try std.testing.expectEqualStrings("./fake-adb", cfg.tools.adb_path.?);
    try std.testing.expectEqualStrings("./fake-avdmanager", cfg.tools.avdmanager_path.?);
    try std.testing.expectEqualStrings("./fake-android-shim", cfg.tools.android_shim_path.?);
    try std.testing.expectEqualStrings("./fake-ios-shim", cfg.tools.ios_shim_path.?);
}

test "config parser rejects unsupported versions" {
    try std.testing.expectError(error.UnsupportedConfigVersion, parseSlice(std.testing.allocator,
        \\{"schemaVersion": 2}
    ));
}

test "config parser rejects non-boolean platform flags" {
    try std.testing.expectError(error.ConfigFieldMustBeBool, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "android": {
        \\    "enabled": "true"
        \\  }
        \\}
    ));
}

test "config parser rejects unknown fields" {
    try std.testing.expectError(error.ConfigUnknownField, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "android": {
        \\    "smokeScenaro": ".zmr/android-smoke.json"
        \\  }
        \\}
    ));
}

test "config parser rejects empty strings where schema requires values" {
    try std.testing.expectError(error.ConfigFieldMustBeNonEmptyString, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "appId": ""
        \\}
    ));

    try std.testing.expectError(error.ConfigFieldMustBeNonEmptyString, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "tools": {
        \\    "adbPath": ""
        \\  }
        \\}
    ));

    try std.testing.expectError(error.ConfigFieldMustBeNonEmptyString, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "redaction": {
        \\    "denylistText": [""]
        \\  }
        \\}
    ));
}

test "config error diagnostics identify actionable field paths" {
    const allocator = std.testing.allocator;

    const root = try errorFieldPathForSlice(allocator,
        \\[]
    , error.ConfigMustBeObject);
    defer allocator.free(root.?);
    try std.testing.expectEqualStrings("$", root.?);

    const schema_version = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": "1"
        \\}
    , error.ConfigSchemaVersionMustBeInteger);
    defer allocator.free(schema_version.?);
    try std.testing.expectEqualStrings("$.schemaVersion", schema_version.?);

    const scripts_object = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": []
        \\}
    , error.ConfigScriptsMustBeObject);
    defer allocator.free(scripts_object.?);
    try std.testing.expectEqualStrings("$.scripts", scripts_object.?);

    const platform_object = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "android": false
        \\}
    , error.ConfigPlatformMustBeObject);
    defer allocator.free(platform_object.?);
    try std.testing.expectEqualStrings("$.android", platform_object.?);

    const tools_object = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "tools": false
        \\}
    , error.ConfigToolsMustBeObject);
    defer allocator.free(tools_object.?);
    try std.testing.expectEqualStrings("$.tools", tools_object.?);

    const artifacts_object = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "artifacts": false
        \\}
    , error.ConfigArtifactsMustBeObject);
    defer allocator.free(artifacts_object.?);
    try std.testing.expectEqualStrings("$.artifacts", artifacts_object.?);

    const redaction_object = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "redaction": false
        \\}
    , error.ConfigRedactionMustBeObject);
    defer allocator.free(redaction_object.?);
    try std.testing.expectEqualStrings("$.redaction", redaction_object.?);

    const unknown = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "android": {
        \\    "smokeScenaro": ".zmr/android-smoke.json"
        \\  }
        \\}
    , error.ConfigUnknownField);
    defer allocator.free(unknown.?);
    try std.testing.expectEqualStrings("$.android.smokeScenaro", unknown.?);

    const ios_unknown = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "ios": {
        \\    "smokeScenaro": ".zmr/ios-smoke.json"
        \\  }
        \\}
    , error.ConfigUnknownField);
    defer allocator.free(ios_unknown.?);
    try std.testing.expectEqualStrings("$.ios.smokeScenaro", ios_unknown.?);

    const tools_unknown = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "tools": {
        \\    "adb": "./adb"
        \\  }
        \\}
    , error.ConfigUnknownField);
    defer allocator.free(tools_unknown.?);
    try std.testing.expectEqualStrings("$.tools.adb", tools_unknown.?);

    const artifacts_unknown = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "artifacts": {
        \\    "video": true
        \\  }
        \\}
    , error.ConfigUnknownField);
    defer allocator.free(artifacts_unknown.?);
    try std.testing.expectEqualStrings("$.artifacts.video", artifacts_unknown.?);

    const redaction_unknown = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "redaction": {
        \\    "denyText": ["secret"]
        \\  }
        \\}
    , error.ConfigUnknownField);
    defer allocator.free(redaction_unknown.?);
    try std.testing.expectEqualStrings("$.redaction.denyText", redaction_unknown.?);

    const no_unknown = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1
        \\}
    , error.ConfigUnknownField);
    try std.testing.expect(no_unknown == null);

    const bool_path = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "artifacts": {
        \\    "screenshots": "false"
        \\  }
        \\}
    , error.ConfigFieldMustBeBool);
    defer allocator.free(bool_path.?);
    try std.testing.expectEqualStrings("$.artifacts.screenshots", bool_path.?);

    const script_type = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": {
        \\    "android": false
        \\  }
        \\}
    , error.ConfigFieldMustBeString);
    defer allocator.free(script_type.?);
    try std.testing.expectEqualStrings("$.scripts.android", script_type.?);

    const app_id_type = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "appId": false
        \\}
    , error.ConfigFieldMustBeString);
    defer allocator.free(app_id_type.?);
    try std.testing.expectEqualStrings("$.appId", app_id_type.?);

    const android_string_type = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "android": {
        \\    "defaultDevice": false
        \\  }
        \\}
    , error.ConfigFieldMustBeString);
    defer allocator.free(android_string_type.?);
    try std.testing.expectEqualStrings("$.android.defaultDevice", android_string_type.?);

    const ios_string_type = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "ios": {
        \\    "smokeScenario": false
        \\  }
        \\}
    , error.ConfigFieldMustBeString);
    defer allocator.free(ios_string_type.?);
    try std.testing.expectEqualStrings("$.ios.smokeScenario", ios_string_type.?);

    const tools_string_type = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "tools": {
        \\    "adbPath": false
        \\  }
        \\}
    , error.ConfigFieldMustBeString);
    defer allocator.free(tools_string_type.?);
    try std.testing.expectEqualStrings("$.tools.adbPath", tools_string_type.?);

    const no_string_type = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": {
        \\    "android": "zmr run .zmr/android-smoke.json"
        \\  }
        \\}
    , error.ConfigFieldMustBeString);
    try std.testing.expect(no_string_type == null);

    const empty_app_id = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "appId": ""
        \\}
    , error.ConfigFieldMustBeNonEmptyString);
    defer allocator.free(empty_app_id.?);
    try std.testing.expectEqualStrings("$.appId", empty_app_id.?);

    const empty_tool = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "tools": {
        \\    "adbPath": ""
        \\  }
        \\}
    , error.ConfigFieldMustBeNonEmptyString);
    defer allocator.free(empty_tool.?);
    try std.testing.expectEqualStrings("$.tools.adbPath", empty_tool.?);

    const empty_script = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": {
        \\    "android": ""
        \\  }
        \\}
    , error.ConfigFieldMustBeNonEmptyString);
    defer allocator.free(empty_script.?);
    try std.testing.expectEqualStrings("$.scripts.android", empty_script.?);

    const empty_redaction = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "redaction": {
        \\    "denylistText": [""]
        \\  }
        \\}
    , error.ConfigFieldMustBeNonEmptyString);
    defer allocator.free(empty_redaction.?);
    try std.testing.expectEqualStrings("$.redaction.denylistText[0]", empty_redaction.?);

    const redaction_not_array = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "redaction": {
        \\    "denylistText": false
        \\  }
        \\}
    , error.ConfigFieldMustBeStringArray);
    defer allocator.free(redaction_not_array.?);
    try std.testing.expectEqualStrings("$.redaction.denylistText", redaction_not_array.?);

    const bad_redaction = try errorFieldPathForSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "redaction": {
        \\    "denylistText": ["ok", false]
        \\  }
        \\}
    , error.ConfigFieldMustBeStringArray);
    defer allocator.free(bad_redaction.?);
    try std.testing.expectEqualStrings("$.redaction.denylistText[1]", bad_redaction.?);
}

test "config parser validates optional scripts block" {
    var cfg = try parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": {
        \\    "android": "zmr run .zmr/android-smoke.json"
        \\  }
        \\}
    );
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cfg.scripts.len);
    try std.testing.expectEqualStrings("android", cfg.scripts[0].name);
    try std.testing.expectEqualStrings("zmr run .zmr/android-smoke.json", cfg.scripts[0].command);

    var generated = try parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": {
        \\    "doctor": "zmr doctor --strict --json --config .zmr/config.json",
        \\    "validate": "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json",
        \\    "androidReport": "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml",
        \\    "androidReliability": "export ZMR_BIN=\"${ZMR_BIN:-zmr}\"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.mobiletest --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && \"$ZMR_BIN\" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml",
        \\    "exportTrace": "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact"
        \\  }
        \\}
    );
    defer generated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), generated.scripts.len);
    try std.testing.expectEqualStrings("doctor", generated.scripts[0].name);
    try std.testing.expectEqualStrings("zmr doctor --strict --json --config .zmr/config.json", generated.scripts[0].command);
    try std.testing.expectEqualStrings("androidReliability", generated.scripts[3].name);
    try std.testing.expect(std.mem.indexOf(u8, generated.scripts[3].command, "\"$ZMR_BIN\" report traces/zmr-android-reliability") != null);
    try std.testing.expectEqualStrings("exportTrace", generated.scripts[4].name);

    try std.testing.expectError(error.ConfigFieldMustBeString, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": {
        \\    "android": false
        \\  }
        \\}
    ));

    try std.testing.expectError(error.ConfigFieldMustBeNonEmptyString, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "scripts": {
        \\    "android": ""
        \\  }
        \\}
    ));
}

test "config parser reads artifact capture controls" {
    const allocator = std.testing.allocator;
    var cfg = try parseSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "artifacts": {
        \\    "screenshots": false,
        \\    "hierarchy": false,
        \\    "logs": false,
        \\    "screenRecording": true
        \\  }
        \\}
    );
    defer cfg.deinit(allocator);

    try std.testing.expect(!cfg.artifacts.screenshots);
    try std.testing.expect(!cfg.artifacts.hierarchy);
    try std.testing.expect(!cfg.artifacts.logs);
    try std.testing.expect(cfg.artifacts.screen_recording);
}

test "config parser rejects non-boolean artifact controls" {
    try std.testing.expectError(error.ConfigFieldMustBeBool, parseSlice(std.testing.allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "artifacts": {
        \\    "screenshots": "false"
        \\  }
        \\}
    ));
}

test "config parser reads trace redaction controls" {
    const allocator = std.testing.allocator;
    var cfg = try parseSlice(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "redaction": {
        \\    "denylistText": ["customer dob", "internal token"],
        \\    "allowlistText": ["public token label"],
        \\    "denylistResourceIds": ["password-field", "ssn"],
        \\    "allowlistResourceIds": ["public-token-label"]
        \\  }
        \\}
    );
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cfg.redaction.denylist_text.len);
    try std.testing.expectEqualStrings("customer dob", cfg.redaction.denylist_text[0]);
    try std.testing.expectEqualStrings("internal token", cfg.redaction.denylist_text[1]);
    try std.testing.expectEqual(@as(usize, 1), cfg.redaction.allowlist_text.len);
    try std.testing.expectEqualStrings("public token label", cfg.redaction.allowlist_text[0]);
    try std.testing.expectEqual(@as(usize, 2), cfg.redaction.denylist_resource_ids.len);
    try std.testing.expectEqualStrings("password-field", cfg.redaction.denylist_resource_ids[0]);
    try std.testing.expectEqualStrings("ssn", cfg.redaction.denylist_resource_ids[1]);
    try std.testing.expectEqual(@as(usize, 1), cfg.redaction.allowlist_resource_ids.len);
    try std.testing.expectEqualStrings("public-token-label", cfg.redaction.allowlist_resource_ids[0]);
}
