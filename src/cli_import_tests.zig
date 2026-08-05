const std = @import("std");
const cli_import = @import("cli_import.zig");

test "parse args rejects missing option values and unknown flags" {
    try std.testing.expectError(error.MissingImportOut, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--out" }));
    try std.testing.expectError(error.MissingImportName, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--name" }));
    try std.testing.expectError(error.MissingAppId, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--app-id" }));
    try std.testing.expectError(error.MissingImportReport, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--report" }));
    try std.testing.expectError(error.unknownFlag, cli_import.parseArgs(&.{ "flow-yaml", "flow.yaml", "--wat" }));
}

test "parse args accepts strict compatibility reporting" {
    const parsed = try cli_import.parseArgs(&.{ "--strict", "--report", "compat.json", "--out", "out.json", "flow-yaml", "flow.yaml" });
    try std.testing.expect(parsed.strict);
    try std.testing.expectEqualStrings("compat.json", parsed.compatibility_report_path.?);
}

test "parse args accepts flags before the positionals" {
    const parsed = try cli_import.parseArgs(&.{ "--out", "out.json", "flow-yaml", "flow.yaml" });
    try std.testing.expectEqualStrings("flow-yaml", parsed.format);
    try std.testing.expectEqualStrings("flow.yaml", parsed.source_path);
    try std.testing.expectEqualStrings("out.json", parsed.out_path.?);
}
