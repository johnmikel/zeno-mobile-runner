const std = @import("std");
const cli_validate = @import("cli_validate.zig");

test "parse args supports plain and json validation" {
    const plain = try cli_validate.parseArgs(&.{"scenario.json"});
    try std.testing.expectEqualStrings("scenario.json", plain.path);
    try std.testing.expect(!plain.json);

    const json = try cli_validate.parseArgs(&.{ "scenario.json", "--json" });
    try std.testing.expectEqualStrings("scenario.json", json.path);
    try std.testing.expect(json.json);
}

test "parse args accepts flags before the scenario path" {
    const parsed = try cli_validate.parseArgs(&.{ "--json", "scenario.json" });
    try std.testing.expectEqualStrings("scenario.json", parsed.path);
    try std.testing.expect(parsed.json);
}

test "parse args rejects unknown flags and extra paths" {
    try std.testing.expectError(error.UnknownFlag, cli_validate.parseArgs(&.{ "scenario.json", "--wat" }));
    try std.testing.expectError(error.UnknownFlag, cli_validate.parseArgs(&.{ "scenario.json", "extra.json" }));
    try std.testing.expectError(error.MissingScenarioPath, cli_validate.parseArgs(&.{"--json"}));
}
