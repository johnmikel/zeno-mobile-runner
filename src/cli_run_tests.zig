const std = @import("std");
const cli_run = @import("cli_run.zig");

test "parse args rejects missing option values and invalid platform values" {
    try std.testing.expectError(error.MissingDeviceSerial, cli_run.parseArgs(&.{"--device"}));
    try std.testing.expectError(error.MissingTraceDir, cli_run.parseArgs(&.{"--trace-dir"}));
    try std.testing.expectError(error.MissingAppId, cli_run.parseArgs(&.{"--app-id"}));
    try std.testing.expectError(error.MissingAdbPath, cli_run.parseArgs(&.{"--adb"}));
    try std.testing.expectError(error.MissingEmulatorPath, cli_run.parseArgs(&.{"--emulator"}));
    try std.testing.expectError(error.MissingAvdmanagerPath, cli_run.parseArgs(&.{"--avdmanager"}));
    try std.testing.expectError(error.MissingAndroidShimPath, cli_run.parseArgs(&.{"--android-shim"}));
    try std.testing.expectError(error.MissingXcrunPath, cli_run.parseArgs(&.{"--xcrun"}));
    try std.testing.expectError(error.MissingIosShimPath, cli_run.parseArgs(&.{"--ios-shim"}));
    try std.testing.expectError(error.UnsupportedPlatform, cli_run.parseArgs(&.{ "--platform", "watchos" }));
    try std.testing.expectError(error.UnsupportedIosDeviceType, cli_run.parseArgs(&.{ "--ios-device-type", "watch" }));
    try std.testing.expectError(error.MissingAndroidAvdName, cli_run.parseArgs(&.{"--android-avd"}));
    try std.testing.expectError(error.MissingAndroidSnapshotName, cli_run.parseArgs(&.{"--restore-snapshot"}));
    try std.testing.expectError(error.MissingAndroidAvdSystemImage, cli_run.parseArgs(&.{"--avd-system-image"}));
    try std.testing.expectError(error.MissingAndroidAvdDeviceProfile, cli_run.parseArgs(&.{"--avd-device"}));
    try std.testing.expectError(error.MissingDiscoverOut, cli_run.parseArgs(&.{"--discover-out"}));
}
