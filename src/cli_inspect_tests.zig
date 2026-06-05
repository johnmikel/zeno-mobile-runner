const std = @import("std");
const cli_inspect = @import("cli_inspect.zig");

test "inspect parses json config and dir flags" {
    const parsed = try cli_inspect.parseArgs(&.{ "--json", "--dir", "app root", "--config", "app root/.zmr/config.json" });

    try std.testing.expect(parsed.json);
    try std.testing.expectEqualStrings("app root", parsed.dir);
    try std.testing.expectEqualStrings("app root/.zmr/config.json", parsed.config_path.?);
}

test "inspect rejects unknown flags" {
    try std.testing.expectError(error.UnknownFlag, cli_inspect.parseArgs(&.{"--crawl"}));
}

test "inspect json reports app handoff without launching devices" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const platforms = [_]cli_inspect.PlatformInspection{
        .{
            .name = "android",
            .enabled = true,
            .default_device = "emulator-5554",
            .smoke_scenario = ".zmr/android-smoke.json",
            .smoke_scenario_exists = true,
            .trace_dir = "traces/zmr-android",
        },
        .{
            .name = "ios",
            .enabled = true,
            .default_device = "booted",
            .smoke_scenario = ".zmr/ios-smoke.json",
            .smoke_scenario_exists = false,
            .trace_dir = "traces/zmr-ios",
        },
    };
    const inspection = cli_inspect.Inspection{
        .ok = true,
        .dir = ".",
        .config_path = ".zmr/config.json",
        .config_exists = true,
        .agent_instructions_path = ".zmr/AGENTS.md",
        .agent_instructions_exists = true,
        .platforms = platforms[0..],
    };

    try cli_inspect.writeJson(out.writer(allocator), inspection);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"schemaVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"runnerVersion\":\"0.1.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"protocolVersion\":\"2026-04-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"configExists\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"agentInstructionsExists\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"android\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"smokeScenarioExists\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"recommendedCommands\":[\"zmr doctor --strict --json --config .zmr/config.json\",\"zmr schemas --json\",\"zmr validate --json .zmr/android-smoke.json\",\"zmr validate --json .zmr/ios-smoke.json\",\"zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent\",\"zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"limitations\":[\"inspect is read-only and does not launch devices\",\"autonomous crawling is not shipped; generate or edit scenarios for human review\"]") != null);
}
