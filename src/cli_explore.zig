const std = @import("std");
const stdio = @import("stdio.zig");

const cli_discover = @import("cli_discover.zig");
const cli_output = @import("cli_output.zig");
const validation = @import("validation.zig");

const explore_guardrails = [_][]const u8{
    "writes from existing trace evidence only",
    "does not crawl the app",
    "does not discover credentials or secrets",
    "requires human review before commit",
};

pub const ParsedArgs = struct {
    from_trace: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    name: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    include_actions: bool = false,
    validate: bool = false,
    force: bool = false,
    json: bool = false,
};

pub const ExploreSummary = struct {
    ok: bool,
    goal: ?[]const u8,
};

pub const OwnedExplore = struct {
    discovered: cli_discover.OwnedDiscover,
    summary: ExploreSummary,

    pub fn deinit(self: *OwnedExplore, allocator: std.mem.Allocator) void {
        self.discovered.deinit(allocator);
    }
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--from-trace")) {
            index += 1;
            parsed.from_trace = if (index < args.len) args[index] else return error.MissingTraceDir;
        } else if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            parsed.out_path = if (index < args.len) args[index] else return error.MissingDraftOut;
        } else if (std.mem.eql(u8, arg, "--goal")) {
            index += 1;
            parsed.goal = if (index < args.len) args[index] else return error.MissingParam;
        } else if (std.mem.eql(u8, arg, "--name")) {
            index += 1;
            parsed.name = if (index < args.len) args[index] else return error.MissingParam;
        } else if (std.mem.eql(u8, arg, "--app-id")) {
            index += 1;
            parsed.app_id = if (index < args.len) args[index] else return error.MissingAppId;
        } else if (std.mem.eql(u8, arg, "--include-actions")) {
            parsed.include_actions = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            parsed.validate = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            parsed.force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else {
            return error.unknownFlag;
        }
    }

    if (parsed.from_trace == null) return error.MissingTraceDir;
    if (parsed.out_path == null) return error.MissingDraftOut;
    return parsed;
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseArgs(raw_args.items);
    var explored = try exploreFromTrace(allocator, parsed);
    defer explored.deinit(allocator);

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    if (parsed.json) {
        try writeJson(stdout, explored.summary, explored.discovered.summary, explored.discovered.validation);
    } else {
        try stdout.print("wrote {s}\n", .{explored.discovered.summary.draft.out_path});
        if (explored.summary.goal) |goal| try stdout.print("goal: {s}\n", .{goal});
        try stdout.writeAll("review required: true\n");
        try stdout.writeAll("next: zmr validate --json ");
        try cli_output.writeShellArg(stdout, explored.discovered.summary.draft.out_path);
        try stdout.writeAll("\n");
    }
    try stdout_io.flush();
    if (!explored.summary.ok) std.process.exit(1);
}

pub fn exploreFromTrace(allocator: std.mem.Allocator, parsed: ParsedArgs) !OwnedExplore {
    var discovered = try cli_discover.discoverFromTrace(allocator, .{
        .from_trace = parsed.from_trace,
        .out_path = parsed.out_path,
        .name = parsed.name,
        .app_id = parsed.app_id,
        .include_actions = parsed.include_actions,
        .validate = parsed.validate,
        .force = parsed.force,
        .json = parsed.json,
    });
    errdefer discovered.deinit(allocator);

    return .{
        .discovered = discovered,
        .summary = .{
            .ok = discovered.summary.ok,
            .goal = parsed.goal,
        },
    };
}

pub fn writeJson(
    writer: anytype,
    summary: ExploreSummary,
    discover_summary: cli_discover.DiscoverSummary,
    validation_result: ?validation.Result,
) !void {
    try cli_discover.writeJsonWithOptions(writer, discover_summary, validation_result, .{
        .mode = "explore",
        .goal = summary.goal,
        .autonomous = false,
        .review_required = true,
        .guardrails = explore_guardrails[0..],
    });
}
