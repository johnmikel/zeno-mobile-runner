const std = @import("std");
const config = @import("config.zig");
const run_options = @import("run_options.zig");

test "run options apply app-local config defaults and let cli flags override" {
    const allocator = std.testing.allocator;
    const cfg_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "appId": "com.example.config",
        \\  "android": {
        \\    "enabled": true,
        \\    "defaultDevice": "emulator-6000",
        \\    "smokeScenario": ".zmr/android-smoke.json",
        \\    "traceDir": "traces/from-config",
        \\    "avdName": "Small_Phone",
        \\    "restoreSnapshot": "zmr-clean",
        \\    "resetBeforeRun": true,
        \\    "waitReady": true,
        \\    "ensureDevice": true,
        \\    "createAvdIfMissing": true,
        \\    "avdSystemImage": "system-images;android-35;google_apis;arm64-v8a",
        \\    "avdDeviceProfile": "pixel_6"
        \\  },
        \\  "ios": {
        \\    "enabled": true,
        \\    "defaultDevice": "booted",
        \\    "smokeScenario": ".zmr/ios-smoke.json",
        \\    "traceDir": "traces/ios"
        \\  },
        \\  "artifacts": {
        \\    "screenshots": false,
        \\    "hierarchy": false,
        \\    "logs": false,
        \\    "screenRecording": true
        \\  },
        \\  "tools": {
        \\    "androidShimPath": "./tests/fake-android-shim.sh",
        \\    "iosShimPath": "./tests/fake-ios-shim.sh"
        \\  }
        \\}
    ;
    var cfg = try config.parseSlice(allocator, cfg_json);
    defer cfg.deinit(allocator);

    const resolved = run_options.resolveRun(.{
        .scenario_path = null,
        .serial = null,
        .trace_dir = null,
        .app_id = null,
        .platform = .android,
    }, cfg);

    try std.testing.expectEqualStrings(".zmr/android-smoke.json", resolved.scenario_path.?);
    try std.testing.expectEqualStrings("emulator-6000", resolved.serial.?);
    try std.testing.expectEqualStrings("traces/from-config", resolved.trace_dir.?);
    try std.testing.expectEqualStrings("com.example.config", resolved.app_id);
    try std.testing.expectEqualStrings("./tests/fake-android-shim.sh", resolved.android_shim_path.?);
    try std.testing.expectEqualStrings("./tests/fake-ios-shim.sh", resolved.ios_shim_path.?);
    try std.testing.expectEqualStrings("Small_Phone", resolved.android_avd_name.?);
    try std.testing.expectEqualStrings("zmr-clean", resolved.android_restore_snapshot.?);
    try std.testing.expect(resolved.android_create_avd_if_missing);
    try std.testing.expectEqualStrings("system-images;android-35;google_apis;arm64-v8a", resolved.android_avd_system_image.?);
    try std.testing.expectEqualStrings("pixel_6", resolved.android_avd_device_profile.?);
    try std.testing.expect(resolved.android_reset_before_run);
    try std.testing.expect(resolved.android_wait_ready);
    try std.testing.expect(resolved.ensure_device);

    const preflight = run_options.androidPreflight(resolved, "adb", "emulator", "avdmanager").?;
    try std.testing.expectEqualStrings("Small_Phone", preflight.avd_name.?);
    try std.testing.expect(preflight.ensure_ready);

    const capture = run_options.traceCapture(cfg);
    try std.testing.expect(!capture.capture_screenshots);
    try std.testing.expect(!capture.capture_hierarchy);
    try std.testing.expect(!capture.capture_logs);
    try std.testing.expect(capture.capture_screen_recording);

    const overridden = run_options.resolveRun(.{
        .scenario_path = "custom.json",
        .serial = "device-1",
        .trace_dir = "traces/custom",
        .app_id = "com.example.cli",
        .android_shim_path = "./custom-android-shim",
        .ios_shim_path = "./custom-ios-shim",
        .ensure_device = false,
        .platform = .android,
    }, cfg);

    try std.testing.expectEqualStrings("custom.json", overridden.scenario_path.?);
    try std.testing.expectEqualStrings("device-1", overridden.serial.?);
    try std.testing.expectEqualStrings("traces/custom", overridden.trace_dir.?);
    try std.testing.expectEqualStrings("com.example.cli", overridden.app_id);
    try std.testing.expectEqualStrings("./custom-android-shim", overridden.android_shim_path.?);
    try std.testing.expectEqualStrings("./custom-ios-shim", overridden.ios_shim_path.?);
    try std.testing.expect(!overridden.ensure_device);

    const serve_resolved = run_options.resolveServe(.{
        .serial = null,
        .app_id = null,
        .trace_dir = null,
        .platform = .android,
    }, cfg);
    try std.testing.expectEqualStrings("emulator-6000", serve_resolved.serial.?);
    try std.testing.expectEqualStrings("traces/from-config", serve_resolved.trace_dir.?);
    try std.testing.expectEqualStrings("com.example.config", serve_resolved.app_id);

    const serve_overridden = run_options.resolveServe(.{
        .serial = "device-2",
        .app_id = "com.example.serve",
        .trace_dir = "traces/serve",
        .platform = .android,
    }, cfg);
    try std.testing.expectEqualStrings("device-2", serve_overridden.serial.?);
    try std.testing.expectEqualStrings("traces/serve", serve_overridden.trace_dir.?);
    try std.testing.expectEqualStrings("com.example.serve", serve_overridden.app_id);
}
