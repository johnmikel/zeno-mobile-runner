const std = @import("std");
const cli_info = @import("cli_info.zig");

test "json flag parser rejects extra positional values" {
    try std.testing.expect(!(try cli_info.parseJsonFlag(&.{})));
    try std.testing.expect(try cli_info.parseJsonFlag(&.{"--json"}));
    try std.testing.expectError(error.unknownFlag, cli_info.parseJsonFlag(&.{ "--json", "extra" }));
}
