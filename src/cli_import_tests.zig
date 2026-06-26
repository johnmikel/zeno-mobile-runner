const std = @import("std");
const cli_import = @import("cli_import.zig");

test "parse args rejects missing option values and unknown flags" {
    try std.testing.expectError(error.MissingImportOut, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--out" }));
    try std.testing.expectError(error.MissingImportName, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--name" }));
    try std.testing.expectError(error.MissingAppId, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--app-id" }));
    try std.testing.expectError(error.unknownFlag, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--wat" }));
}

test "parse args accepts flags before the positionals" {
    const parsed = try cli_import.parseArgs(&.{ "--out", "out.json", "flow-yaml", "flow.yaml" });
    try std.testing.expectEqualStrings("flow-yaml", parsed.format);
    try std.testing.expectEqualStrings("flow.yaml", parsed.source_path);
    try std.testing.expectEqualStrings("out.json", parsed.out_path.?);
}

test "parse args accepts maestro migration alias" {
    const parsed = try cli_import.parseArgs(&.{ "maestro", "flows/login.yaml", "--out", ".zmr/login.json", "--json" });
    try std.testing.expectEqualStrings("maestro", parsed.format);
    try std.testing.expectEqualStrings("flows/login.yaml", parsed.source_path);
    try std.testing.expectEqualStrings(".zmr/login.json", parsed.out_path.?);
    try std.testing.expect(parsed.json);
}
