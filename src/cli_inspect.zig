const std = @import("std");
const stdio = @import("stdio.zig");

const config = @import("config.zig");
const scaffold = @import("scaffold.zig");
const trace = @import("trace.zig");
const version = @import("version.zig");

pub const ParsedArgs = struct {
    json: bool = false,
    dir: []const u8 = ".",
    config_path: ?[]const u8 = null,
};

pub const PlatformInspection = struct {
    name: []const u8,
    enabled: bool,
    default_device: ?[]const u8 = null,
    smoke_scenario: ?[]const u8 = null,
    smoke_scenario_exists: bool = false,
    trace_dir: ?[]const u8 = null,
};

pub const Inspection = struct {
    ok: bool,
    status: []const u8 = "ready",
    dir: []const u8,
    config_path: []const u8,
    config_exists: bool,
    agent_instructions_path: []const u8,
    agent_instructions_exists: bool,
    platforms: []const PlatformInspection = &.{},
};

const OwnedInspection = struct {
    inspection: Inspection,
    owned_strings: std.ArrayList([]const u8),
    platforms: std.ArrayList(PlatformInspection),
    parsed_config: ?config.Config = null,

    fn deinit(self: *OwnedInspection, allocator: std.mem.Allocator) void {
        if (self.parsed_config) |*cfg| cfg.deinit(allocator);
        for (self.owned_strings.items) |value| allocator.free(value);
        self.owned_strings.deinit(allocator);
        self.platforms.deinit(allocator);
    }
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            parsed.dir = if (index < args.len) args[index] else return error.MissingParam;
        } else if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            parsed.config_path = if (index < args.len) args[index] else return error.MissingParam;
        } else {
            return error.unknownFlag;
        }
    }
    return parsed;
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseArgs(raw_args.items);
    var owned = try inspect(allocator, parsed);
    defer owned.deinit(allocator);

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    if (parsed.json) {
        try writeJson(stdout, owned.inspection);
    } else {
        try writeText(stdout, owned.inspection);
    }
    try stdout_io.flush();
}

fn inspect(allocator: std.mem.Allocator, parsed: ParsedArgs) !OwnedInspection {
    var owned = OwnedInspection{
        .inspection = .{
            .ok = false,
            .status = "needs-setup",
            .dir = undefined,
            .config_path = undefined,
            .config_exists = false,
            .agent_instructions_path = undefined,
            .agent_instructions_exists = false,
        },
        .owned_strings = .empty,
        .platforms = .empty,
    };
    errdefer owned.deinit(allocator);

    owned.inspection.dir = try ownString(allocator, &owned.owned_strings, parsed.dir);
    owned.inspection.config_path = if (parsed.config_path) |explicit|
        try ownString(allocator, &owned.owned_strings, explicit)
    else
        try ownJoinedPath(allocator, &owned.owned_strings, parsed.dir, scaffold.app_config_file);
    owned.inspection.agent_instructions_path = try ownJoinedPath(allocator, &owned.owned_strings, parsed.dir, scaffold.app_agents_file);

    owned.inspection.config_exists = pathExists(owned.inspection.config_path);
    owned.inspection.agent_instructions_exists = pathExists(owned.inspection.agent_instructions_path);
    if (!owned.inspection.config_exists) return owned;

    owned.parsed_config = try config.parseFile(allocator, owned.inspection.config_path);
    const cfg = &owned.parsed_config.?;
    try appendPlatform(allocator, &owned, "android", cfg.android);
    try appendPlatform(allocator, &owned, "ios", cfg.ios);
    owned.inspection.platforms = owned.platforms.items;
    owned.inspection.ok = true;
    owned.inspection.status = "ready";
    return owned;
}

fn appendPlatform(
    allocator: std.mem.Allocator,
    owned: *OwnedInspection,
    name: []const u8,
    platform: config.PlatformConfig,
) !void {
    const smoke_scenario = if (platform.smoke_scenario) |path|
        try ownResolvedPath(allocator, &owned.owned_strings, owned.inspection.dir, path)
    else
        null;
    try owned.platforms.append(allocator, .{
        .name = name,
        .enabled = platform.enabled,
        .default_device = platform.default_device,
        .smoke_scenario = smoke_scenario,
        .smoke_scenario_exists = if (smoke_scenario) |path| pathExists(path) else false,
        .trace_dir = platform.trace_dir,
    });
}

fn pathExists(path: []const u8) bool {
    stdio.access(path) catch return false;
    return true;
}

fn ownString(allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]const u8), value: []const u8) ![]const u8 {
    const owned = try allocator.dupe(u8, value);
    try owned_strings.append(allocator, owned);
    return owned;
}

fn ownJoinedPath(
    allocator: std.mem.Allocator,
    owned_strings: *std.ArrayList([]const u8),
    root: []const u8,
    path: []const u8,
) ![]const u8 {
    const joined = try std.fs.path.join(allocator, &.{ root, path });
    try owned_strings.append(allocator, joined);
    return joined;
}

fn ownResolvedPath(
    allocator: std.mem.Allocator,
    owned_strings: *std.ArrayList([]const u8),
    root: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return try ownString(allocator, owned_strings, path);
    return try ownJoinedPath(allocator, owned_strings, root, path);
}

pub fn writeJson(writer: anytype, inspection: Inspection) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (inspection.ok) "true" else "false");
    try writer.writeAll(",\"status\":");
    try trace.writeJsonString(writer, inspection.status);
    try writer.writeAll(",\"schemaVersion\":1");
    try writer.writeAll(",\"runnerVersion\":");
    try trace.writeJsonString(writer, version.runner_version);
    try writer.writeAll(",\"protocolVersion\":");
    try trace.writeJsonString(writer, version.protocol_version);
    try writer.writeAll(",\"dir\":");
    try trace.writeJsonString(writer, inspection.dir);
    try writer.writeAll(",\"configPath\":");
    try trace.writeJsonString(writer, inspection.config_path);
    try writer.writeAll(",\"configExists\":");
    try writer.writeAll(if (inspection.config_exists) "true" else "false");
    try writer.writeAll(",\"agentInstructionsPath\":");
    try trace.writeJsonString(writer, inspection.agent_instructions_path);
    try writer.writeAll(",\"agentInstructionsExists\":");
    try writer.writeAll(if (inspection.agent_instructions_exists) "true" else "false");
    try writer.writeAll(",\"platforms\":[");
    for (inspection.platforms, 0..) |platform, index| {
        if (index > 0) try writer.writeAll(",");
        try writePlatformJson(writer, platform);
    }
    try writer.writeAll("],\"recommendedCommands\":[");
    try writeRecommendedCommandsJson(writer, inspection);
    try writer.writeAll("]");
    try writer.writeAll(",\"claimsPolicy\":[\"verify runs with trace evidence before making readiness claims\",\"do not claim Flutter widget-tree inspection\"]");
    try writer.writeAll(",\"limitations\":[\"inspect is read-only and does not launch devices\",\"autonomous crawling is not shipped; generate or edit scenarios for human review\"]");
    try writer.writeAll("}\n");
}

fn writePlatformJson(writer: anytype, platform: PlatformInspection) !void {
    try writer.writeAll("{\"name\":");
    try trace.writeJsonString(writer, platform.name);
    try writer.writeAll(",\"enabled\":");
    try writer.writeAll(if (platform.enabled) "true" else "false");
    try writer.writeAll(",\"defaultDevice\":");
    try writeOptionalJsonString(writer, platform.default_device);
    try writer.writeAll(",\"smokeScenario\":");
    try writeOptionalJsonString(writer, platform.smoke_scenario);
    try writer.writeAll(",\"smokeScenarioExists\":");
    try writer.writeAll(if (platform.smoke_scenario_exists) "true" else "false");
    try writer.writeAll(",\"traceDir\":");
    try writeOptionalJsonString(writer, platform.trace_dir);
    try writer.writeAll("}");
}

fn writeOptionalJsonString(writer: anytype, value: ?[]const u8) !void {
    if (value) |actual| {
        try trace.writeJsonString(writer, actual);
    } else {
        try writer.writeAll("null");
    }
}

fn writeRecommendedCommandsJson(writer: anytype, inspection: Inspection) !void {
    if (!inspection.config_exists) {
        try writer.writeAll("\"zmr init --app --dir ");
        try writeShellArgJsonContent(writer, inspection.dir);
        try writer.writeAll("\"");
        return;
    }

    try writer.writeAll("\"zmr doctor --strict --json --config ");
    try writeShellArgJsonContent(writer, inspection.config_path);
    try writer.writeAll("\",");
    try trace.writeJsonString(writer, "zmr schemas --json");
    for (inspection.platforms) |platform| {
        if (!platform.enabled) continue;
        if (platform.smoke_scenario) |path| {
            try writer.writeAll(",\"zmr validate --json ");
            try writeShellArgJsonContent(writer, path);
            try writer.writeAll("\"");
        }
    }
    try writer.writeAll(",\"zmr serve --transport stdio --config ");
    try writeShellArgJsonContent(writer, inspection.config_path);
    try writer.writeAll(" --trace-dir traces/zmr-agent\"");
    try writer.writeAll(",\"zmr mcp --config ");
    try writeShellArgJsonContent(writer, inspection.config_path);
    try writer.writeAll(" --trace-dir traces/zmr-agent\"");
}

fn writeShellArgJsonContent(writer: anytype, value: []const u8) !void {
    if (value.len == 0) {
        try writer.writeAll("''");
        return;
    }
    var safe = true;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '/' and byte != '.' and byte != '_' and byte != '-' and byte != ':' and byte != '=') {
            safe = false;
            break;
        }
    }
    if (safe) {
        try writeJsonStringContent(writer, value);
        return;
    }
    try writer.writeAll("'");
    for (value) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\"'\"'");
        } else {
            try writeJsonEscapedByte(writer, byte);
        }
    }
    try writer.writeAll("'");
}

fn writeJsonStringContent(writer: anytype, value: []const u8) !void {
    for (value) |byte| try writeJsonEscapedByte(writer, byte);
}

fn writeJsonEscapedByte(writer: anytype, byte: u8) !void {
    switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    }
}

fn writeText(writer: anytype, inspection: Inspection) !void {
    try writer.print("status\t{s}\n", .{inspection.status});
    try writer.print("config\t{s}\t{s}\n", .{ if (inspection.config_exists) "ok" else "missing", inspection.config_path });
    try writer.print("agentInstructions\t{s}\t{s}\n", .{ if (inspection.agent_instructions_exists) "ok" else "missing", inspection.agent_instructions_path });
    for (inspection.platforms) |platform| {
        try writer.print("{s}\t{s}", .{ platform.name, if (platform.enabled) "enabled" else "disabled" });
        if (platform.smoke_scenario) |path| try writer.print("\t{s}", .{path});
        try writer.writeAll("\n");
    }
}
