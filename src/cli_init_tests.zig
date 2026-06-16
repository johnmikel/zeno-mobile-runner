const std = @import("std");
const cli_init = @import("cli_init.zig");

test "parse args rejects missing option values and extra paths" {
    try std.testing.expectError(error.MissingAppId, cli_init.parseArgs(&.{"--app-id"}));
    try std.testing.expectError(error.MissingDirectory, cli_init.parseArgs(&.{"--dir"}));
    try std.testing.expectError(error.unknownFlag, cli_init.parseArgs(&.{ "a.json", "b.json" }));
}
