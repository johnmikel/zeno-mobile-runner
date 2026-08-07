const std = @import("std");
const cli_test = @import("cli_test.zig");

test "test command parses bounded scheduler and output options" {
    const parsed = try cli_test.parseArgs(&.{
        "workspace",
        "--workers",
        "3",
        "--shard-split",
        "--retry",
        "2",
        "--output-dir",
        "results",
        "--platform",
        "ios",
        "--json",
        "--dry-run",
    });

    try std.testing.expectEqualStrings("workspace", parsed.workspace);
    try std.testing.expectEqual(@as(u32, 3), parsed.workers);
    try std.testing.expectEqual(cli_test.Platform.ios, parsed.platform);
    try std.testing.expectEqual(cli_test.ShardMode.split, parsed.shard_mode);
    try std.testing.expectEqual(@as(u32, 2), parsed.retries);
    try std.testing.expectEqualStrings("results", parsed.output_dir);
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.dry_run);
}

test "test command parses recording toggle" {
    const parsed = try cli_test.parseArgs(&.{ "workspace", "--screen-record" });
    try std.testing.expect(parsed.screen_recording);
    const disabled = try cli_test.parseArgs(&.{ "workspace", "--screen-record", "--no-screen-record" });
    try std.testing.expect(!disabled.screen_recording);
}

test "test command rejects conflicting shard modes and missing values" {
    try std.testing.expectError(error.ConflictingShardModes, cli_test.parseArgs(&.{ "workspace", "--shard-all", "--shard-split" }));
    try std.testing.expectError(error.MissingTestWorkspace, cli_test.parseArgs(&.{}));
    try std.testing.expectError(error.MissingTestWorkers, cli_test.parseArgs(&.{ "workspace", "--workers" }));
    try std.testing.expectError(error.InvalidTestPlatform, cli_test.parseArgs(&.{ "workspace", "--platform", "web" }));
    try std.testing.expectError(error.unknownFlag, cli_test.parseArgs(&.{ "workspace", "--wat" }));
}
