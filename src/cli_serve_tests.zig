const std = @import("std");
const cli_serve = @import("cli_serve.zig");

test "parse args rejects missing values and invalid platform values" {
    try std.testing.expectError(error.MissingTransport, cli_serve.parseServeArgs(&.{"--transport"}));
    try std.testing.expectError(error.MissingPort, cli_serve.parseServeArgs(&.{"--port"}));
    try std.testing.expectError(error.MissingDeviceSerial, cli_serve.parseServeArgs(&.{"--device"}));
    try std.testing.expectError(error.MissingAppId, cli_serve.parseServeArgs(&.{"--app-id"}));
    try std.testing.expectError(error.MissingTraceDir, cli_serve.parseServeArgs(&.{"--trace-dir"}));
    try std.testing.expectError(error.MissingAdbPath, cli_serve.parseServeArgs(&.{"--adb"}));
    try std.testing.expectError(error.MissingXcrunPath, cli_serve.parseServeArgs(&.{"--xcrun"}));
    try std.testing.expectError(error.UnsupportedPlatform, cli_serve.parseServeArgs(&.{ "--platform", "watchos" }));
    try std.testing.expectError(error.UnsupportedIosDeviceType, cli_serve.parseServeArgs(&.{ "--ios-device-type", "watch" }));
    try std.testing.expectError(error.unknownFlag, cli_serve.parseMcpArgs(&.{"scenario.json"}));
}
