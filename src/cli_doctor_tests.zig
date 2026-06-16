const std = @import("std");
const cli_doctor = @import("cli_doctor.zig");

test "parse args rejects missing tool values" {
    try std.testing.expectError(error.MissingAdbPath, cli_doctor.parseArgs(&.{"--adb"}));
    try std.testing.expectError(error.MissingConfigPath, cli_doctor.parseArgs(&.{"--config"}));
    try std.testing.expectError(error.unknownFlag, cli_doctor.parseArgs(&.{"--wat"}));
}
