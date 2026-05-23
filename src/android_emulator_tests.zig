const std = @import("std");
const android_emulator = @import("android_emulator.zig");

test "android emulator preflight resets boots from snapshot and waits ready" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath("zig-cache");
    const log_path = "zig-cache/test-android-emulator-preflight.log";
    std.fs.cwd().deleteFile(log_path) catch {};
    defer std.fs.cwd().deleteFile(log_path) catch {};

    try android_emulator.runPreflight(allocator, .{
        .adb_path = "./tests/fake-adb.sh",
        .emulator_path = "./tests/fake-emulator.sh",
        .device_serial = "fake-android-1",
        .avd_name = "Small_Phone",
        .restore_snapshot = "zmr-clean",
        .reset_before_run = true,
        .wait_ready = true,
        .event_log_path = log_path,
    });

    const log = try std.fs.cwd().readFileAlloc(allocator, log_path, 1024 * 1024);
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "./tests/fake-adb.sh -s fake-android-1 emu kill\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "./tests/fake-emulator.sh -avd Small_Phone -snapshot zmr-clean -netdelay none -netspeed full\n") != null);
}

test "android emulator preflight creates missing avd before boot" {
    const allocator = std.testing.allocator;
    try std.fs.cwd().makePath("zig-cache");
    const log_path = "zig-cache/test-android-emulator-create.log";
    std.fs.cwd().deleteFile(log_path) catch {};
    defer std.fs.cwd().deleteFile(log_path) catch {};

    try android_emulator.runPreflight(allocator, .{
        .adb_path = "./tests/fake-adb.sh",
        .emulator_path = "./tests/fake-emulator.sh",
        .avdmanager_path = "./tests/fake-avdmanager.sh",
        .device_serial = "fake-android-1",
        .avd_name = "Small_Phone",
        .create_avd_if_missing = true,
        .avd_system_image = "system-images;android-35;google_apis;arm64-v8a",
        .avd_device_profile = "pixel_6",
        .event_log_path = log_path,
    });

    const log = try std.fs.cwd().readFileAlloc(allocator, log_path, 1024 * 1024);
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "./tests/fake-emulator.sh -list-avds\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "./tests/fake-avdmanager.sh create avd --name Small_Phone --package system-images;android-35;google_apis;arm64-v8a --device pixel_6 --force\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "./tests/fake-emulator.sh -avd Small_Phone -no-snapshot-load -netdelay none -netspeed full\n") != null);
}
