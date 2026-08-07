const std = @import("std");
const android = @import("android.zig");
const cli_run = @import("cli_run.zig");
const ios = @import("ios.zig");
const scheduler = @import("scheduler.zig");
const session = @import("session.zig");
const scenario = @import("scenario.zig");
const stdio = @import("stdio.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

pub const ShardMode = scheduler.ShardMode;

pub const Platform = enum {
    android,
    ios,
};

pub const ParsedArgs = struct {
    workspace: []const u8,
    workers: u32 = 1,
    shard_mode: ShardMode = .none,
    retries: u32 = 0,
    output_dir: []const u8 = "artifacts",
    platform: Platform = .android,
    serial: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    adb_path: []const u8 = "adb",
    xcrun_path: []const u8 = "xcrun",
    android_shim_path: ?[]const u8 = null,
    ios_shim_path: ?[]const u8 = null,
    json: bool = false,
    dry_run: bool = false,
    screen_recording: bool = false,
};

pub const AttemptRecord = struct {
    attempt_id: u32,
    status: []const u8,
    failure_class: []const u8,
    error_name: ?[]const u8,
    artifact_path: []const u8,

    fn deinit(self: AttemptRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_path);
    }
};

pub const RunOutcome = struct {
    scenario_path: []const u8,
    worker_index: u32,
    shard_index: u32,
    attempt_limit: u32,
    attempts: u32 = 0,
    status: []const u8 = "planned",
    failure_class: []const u8 = "none",
    error_name: ?[]const u8 = null,
    artifact_path: ?[]const u8 = null,
    attempt_records: std.ArrayList(AttemptRecord) = .empty,

    pub fn deinit(self: *RunOutcome, allocator: std.mem.Allocator) void {
        if (self.artifact_path) |path| allocator.free(path);
        for (self.attempt_records.items) |record| record.deinit(allocator);
        self.attempt_records.deinit(allocator);
    }
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
    var workspace: ?[]const u8 = null;
    var parsed = ParsedArgs{ .workspace = "" };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--workers")) {
            index += 1;
            if (index >= args.len) return error.MissingTestWorkers;
            parsed.workers = try parseNumber(args[index], error.InvalidTestWorkers);
        } else if (std.mem.eql(u8, arg, "--shard-all")) {
            if (parsed.shard_mode == .split) return error.ConflictingShardModes;
            parsed.shard_mode = .all;
        } else if (std.mem.eql(u8, arg, "--shard-split")) {
            if (parsed.shard_mode == .all) return error.ConflictingShardModes;
            parsed.shard_mode = .split;
        } else if (std.mem.eql(u8, arg, "--retry")) {
            index += 1;
            if (index >= args.len) return error.MissingTestRetries;
            parsed.retries = try parseNumber(args[index], error.InvalidTestRetries);
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            index += 1;
            parsed.output_dir = if (index < args.len) args[index] else return error.MissingTestOutputDir;
        } else if (std.mem.eql(u8, arg, "--platform")) {
            index += 1;
            const value = if (index < args.len) args[index] else return error.MissingTestPlatform;
            parsed.platform = if (std.mem.eql(u8, value, "android"))
                .android
            else if (std.mem.eql(u8, value, "ios"))
                .ios
            else
                return error.InvalidTestPlatform;
        } else if (std.mem.eql(u8, arg, "--device")) {
            index += 1;
            parsed.serial = if (index < args.len) args[index] else return error.MissingTestDevice;
        } else if (std.mem.eql(u8, arg, "--app-id")) {
            index += 1;
            parsed.app_id = if (index < args.len) args[index] else return error.MissingTestAppId;
        } else if (std.mem.eql(u8, arg, "--adb")) {
            index += 1;
            parsed.adb_path = if (index < args.len) args[index] else return error.MissingTestAdb;
        } else if (std.mem.eql(u8, arg, "--xcrun")) {
            index += 1;
            parsed.xcrun_path = if (index < args.len) args[index] else return error.MissingTestXcrun;
        } else if (std.mem.eql(u8, arg, "--android-shim")) {
            index += 1;
            parsed.android_shim_path = if (index < args.len) args[index] else return error.MissingTestAndroidShim;
        } else if (std.mem.eql(u8, arg, "--ios-shim")) {
            index += 1;
            parsed.ios_shim_path = if (index < args.len) args[index] else return error.MissingTestIosShim;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--screen-record")) {
            parsed.screen_recording = true;
        } else if (std.mem.eql(u8, arg, "--no-screen-record")) {
            parsed.screen_recording = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.unknownFlag;
        } else if (workspace == null) {
            workspace = arg;
        } else {
            return error.unknownFlag;
        }
    }
    parsed.workspace = workspace orelse return error.MissingTestWorkspace;
    return parsed;
}

pub fn run(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);
    const parsed = try parseArgs(raw_args.items);

    const paths = try scheduler.discoverScenarioPaths(allocator, parsed.workspace);
    defer scheduler.freeScenarioPaths(allocator, paths);
    if (paths.len == 0) return error.NoTestScenarios;

    const inputs = try allocator.alloc(scheduler.ScenarioInput, paths.len);
    defer allocator.free(inputs);
    for (paths, 0..) |path, index| {
        const content = try stdio.readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(content);
        var parsed_scenario = try scenario.parseSlice(allocator, content);
        parsed_scenario.deinit(allocator);
        inputs[index] = .{
            .path = path,
            .digest = try std.fmt.allocPrint(allocator, "{x}", .{std.hash.Wyhash.hash(0, content)}),
        };
    }
    defer for (inputs) |input| allocator.free(input.digest);

    const run_id = try std.fmt.allocPrint(allocator, "test-{d}", .{stdio.nowMs()});
    defer allocator.free(run_id);

    var lease_pool: ?scheduler.LeasePool = null;
    defer if (lease_pool) |*pool| pool.deinit();
    var device_infos: []types.DeviceInfo = &.{};
    defer {
        for (device_infos) |info| info.deinit(allocator);
        allocator.free(device_infos);
    }
    var serials = std.ArrayList([]const u8).empty;
    defer serials.deinit(allocator);

    if (!parsed.dry_run) {
        device_infos = switch (parsed.platform) {
            .android => try android.listDevices(allocator, parsed.adb_path),
            .ios => try ios.listDevices(allocator, parsed.xcrun_path),
        };
        for (device_infos) |info| {
            if (!isReadyDevice(parsed.platform, info.state)) continue;
            if (parsed.serial) |wanted| if (!std.mem.eql(u8, wanted, info.serial)) continue;
            try serials.append(allocator, info.serial);
        }
        if (serials.items.len == 0) return error.NoReadyTestDevice;
        lease_pool = try scheduler.LeasePool.init(allocator, serials.items);
    }

    const effective_workers = if (parsed.dry_run)
        parsed.workers
    else
        @min(parsed.workers, @as(u32, @intCast(serials.items.len)));
    var execution = parsed;
    execution.workers = effective_workers;
    const plan = try scheduler.buildPlan(allocator, inputs, .{
        .workers = effective_workers,
        .shard_mode = parsed.shard_mode,
        .retries = parsed.retries,
        .output_dir = parsed.output_dir,
    });
    defer plan.deinit(allocator);

    const outcomes = try allocator.alloc(RunOutcome, plan.items.len);
    defer {
        for (outcomes) |*outcome| outcome.deinit(allocator);
        allocator.free(outcomes);
    }
    for (plan.items, 0..) |item, index| {
        outcomes[index] = .{
            .scenario_path = item.scenario.path,
            .worker_index = item.worker_index,
            .shard_index = item.shard_index,
            .attempt_limit = item.attempt_limit,
        };
    }

    if (!execution.dry_run) {
        const worker_leases = try allocator.alloc(scheduler.Lease, effective_workers);
        defer {
            if (lease_pool) |*pool| {
                for (worker_leases) |lease| pool.release(lease);
            }
            allocator.free(worker_leases);
        }
        for (worker_leases, 0..) |*lease, worker_index| {
            lease.* = lease_pool.?.acquire() orelse return error.NoReadyTestDevice;
            _ = worker_index;
        }

        var threads = std.ArrayList(std.Thread).empty;
        defer threads.deinit(allocator);
        for (worker_leases, 0..) |lease, worker_index| {
            const context = WorkerContext{
                .allocator = allocator,
                .parsed = execution,
                .run_id = run_id,
                .items = plan.items,
                .outcomes = outcomes,
                .worker_index = @intCast(worker_index),
                .serial = lease.serial,
            };
            const thread = std.Thread.spawn(.{}, workerMain, .{context}) catch |err| {
                for (threads.items) |running| running.join();
                return err;
            };
            try threads.append(allocator, thread);
        }
        for (threads.items) |thread| thread.join();
    }

    const report_path = try std.fs.path.join(allocator, &.{ parsed.output_dir, "test-report.json" });
    defer allocator.free(report_path);
    try std.Io.Dir.cwd().createDirPath(stdio.io(), parsed.output_dir);
    try writeReportFile(allocator, report_path, execution, run_id, outcomes);
    if (execution.json) {
        var stdout_io: stdio.Output = .{};
        stdout_io.init(.stdout());
        defer stdout_io.deinit();
        try writeReportJson(stdout_io.writer(), execution, run_id, report_path, outcomes);
        try stdout_io.flush();
    } else {
        std.debug.print("zmr test: {d} scenario(s), report at {s}\n", .{ outcomes.len, report_path });
    }
    for (outcomes) |outcome| {
        if (std.mem.eql(u8, outcome.status, "failed")) return error.TestRunFailed;
    }
}

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    run_id: []const u8,
    items: []const scheduler.PlanItem,
    outcomes: []RunOutcome,
    worker_index: u32,
    serial: []const u8,
};

fn workerMain(context: WorkerContext) void {
    for (context.items, 0..) |item, index| {
        if (item.worker_index != context.worker_index) continue;
        executeItem(context.allocator, context.parsed, context.run_id, item, context.serial, &context.outcomes[index]) catch |err| {
            context.outcomes[index].status = "failed";
            context.outcomes[index].failure_class = @tagName(classifyFailure(err));
            context.outcomes[index].error_name = @errorName(err);
        };
    }
}

fn executeItem(
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    run_id: []const u8,
    item: scheduler.PlanItem,
    serial: []const u8,
    outcome: *RunOutcome,
) !void {
    var value = try session.Session.init(allocator, run_id, serial, parsed.output_dir);
    defer {
        if (value.state != .closed) {
            if (value.state == .running) value.cancel() catch {};
            value.close() catch {};
        }
        value.deinit();
    }
    try value.transition(.preflight);
    try value.transition(.ready);
    try value.transition(.running);

    var attempt_id: u32 = 0;
    while (attempt_id < item.attempt_limit) : (attempt_id += 1) {
        var script = try scenario.parseFile(allocator, item.scenario.path);
        defer script.deinit(allocator);
        const app_id = parsed.app_id orelse script.app_id orelse return error.MissingTestAppId;
        const artifact_path = try value.artifactPath(allocator, script.name, attempt_id);
        defer allocator.free(artifact_path);
        const attempt_index = try value.startAttempt(item.scenario.digest, attempt_id, artifact_path, artifact_path);
        outcome.attempts = attempt_id + 1;
        const run_error: ?anyerror = switch (parsed.platform) {
            .android => blk: {
                var device = try android.AndroidDevice.initWithShim(allocator, parsed.adb_path, serial, app_id, parsed.android_shim_path);
                defer device.deinit();
                var capture = trace.CaptureOptions{};
                capture.capture_screen_recording = parsed.screen_recording;
                cli_run.runAndroidWithTrace(allocator, &device, script, artifact_path, capture) catch |err| break :blk err;
                break :blk null;
            },
            .ios => blk: {
                var device = try ios.IosDevice.initWithKindAndShim(allocator, parsed.xcrun_path, serial, app_id, .simulator, parsed.ios_shim_path);
                defer device.deinit();
                cli_run.runWithTrace(allocator, &device, script, artifact_path, .{}) catch |err| break :blk err;
                break :blk null;
            },
        };
        if (run_error == null) {
            try value.finishAttempt(attempt_index, .passed, .none, null);
            try appendAttemptRecord(allocator, outcome, attempt_id, "passed", "none", null, artifact_path);
            outcome.status = "passed";
            outcome.failure_class = "none";
            if (outcome.artifact_path) |old| allocator.free(old);
            outcome.artifact_path = try allocator.dupe(u8, artifact_path);
            return;
        }

        const err = run_error.?;
        const failure_class = classifyFailure(err);
        try value.finishAttempt(attempt_index, .failed, failure_class, @errorName(err));
        try appendAttemptRecord(allocator, outcome, attempt_id, "failed", @tagName(failure_class), @errorName(err), artifact_path);
        outcome.status = "failed";
        outcome.failure_class = @tagName(failure_class);
        outcome.error_name = @errorName(err);
        if (outcome.artifact_path) |old| allocator.free(old);
        outcome.artifact_path = try allocator.dupe(u8, artifact_path);
        if (!scheduler.shouldRetry(failure_class, attempt_id, parsed.retries)) return;
    }
}

fn appendAttemptRecord(
    allocator: std.mem.Allocator,
    outcome: *RunOutcome,
    attempt_id: u32,
    status: []const u8,
    failure_class: []const u8,
    error_name: ?[]const u8,
    artifact_path: []const u8,
) !void {
    const owned_path = try allocator.dupe(u8, artifact_path);
    errdefer allocator.free(owned_path);
    try outcome.attempt_records.append(allocator, .{
        .attempt_id = attempt_id,
        .status = status,
        .failure_class = failure_class,
        .error_name = error_name,
        .artifact_path = owned_path,
    });
}

fn classifyFailure(err: anyerror) session.FailureClass {
    return switch (err) {
        error.AssertionFailed, error.WaitTimeout, error.SelectorNotFound => .assertion,
        error.CommandFailed,
        error.CommandTimedOut,
        error.IosXCTestShimResponseTimedOut,
        error.IosXCTestShimStartTimedOut,
        error.IosXCTestShimBuildTimedOut,
        error.IosXCTestShimServerExited,
        => .infrastructure,
        error.AppCrashed, error.AppDidNotOpen => .application,
        error.InvalidSessionTransition, error.NoReadyTestDevice => .configuration,
        else => .unknown,
    };
}

fn isReadyDevice(platform: Platform, state: []const u8) bool {
    return switch (platform) {
        .android => std.mem.eql(u8, state, "device"),
        .ios => std.mem.eql(u8, state, "Booted"),
    };
}

fn parseNumber(value: []const u8, comptime err: anyerror) !u32 {
    return std.fmt.parseUnsigned(u32, value, 10) catch return err;
}

fn writeReportFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    parsed: ParsedArgs,
    run_id: []const u8,
    outcomes: []const RunOutcome,
) !void {
    var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
    defer file.close(stdio.io());
    var buffer: [8192]u8 = undefined;
    var writer = file.writerStreaming(stdio.io(), &buffer);
    try writeReportJson(&writer.interface, parsed, run_id, path, outcomes);
    try writer.interface.flush();
    _ = allocator;
}

fn writeReportJson(
    writer: anytype,
    parsed: ParsedArgs,
    run_id: []const u8,
    report_path: []const u8,
    outcomes: []const RunOutcome,
) !void {
    try writer.writeAll("{\"schemaVersion\":1,\"runId\":");
    try trace.writeJsonString(writer, run_id);
    try writer.writeAll(",\"workspace\":");
    try trace.writeJsonString(writer, parsed.workspace);
    try writer.writeAll(",\"platform\":");
    try trace.writeJsonString(writer, @tagName(parsed.platform));
    try writer.writeAll(",\"workers\":");
    try writer.print("{d}", .{parsed.workers});
    try writer.writeAll(",\"shardMode\":");
    try trace.writeJsonString(writer, @tagName(parsed.shard_mode));
    try writer.writeAll(",\"retry\":");
    try writer.print("{d}", .{parsed.retries});
    try writer.writeAll(",\"dryRun\":");
    try writer.writeAll(if (parsed.dry_run) "true" else "false");
    try writer.writeAll(",\"reportPath\":");
    try trace.writeJsonString(writer, report_path);
    try writer.writeAll(",\"items\":[");
    for (outcomes, 0..) |outcome, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"scenario\":");
        try trace.writeJsonString(writer, outcome.scenario_path);
        try writer.writeAll(",\"worker\":");
        try writer.print("{d}", .{outcome.worker_index});
        try writer.writeAll(",\"shard\":");
        try writer.print("{d}", .{outcome.shard_index});
        try writer.writeAll(",\"attemptLimit\":");
        try writer.print("{d}", .{outcome.attempt_limit});
        try writer.writeAll(",\"attempts\":");
        try writer.print("{d}", .{outcome.attempts});
        try writer.writeAll(",\"status\":");
        try trace.writeJsonString(writer, outcome.status);
        try writer.writeAll(",\"failureClass\":");
        try trace.writeJsonString(writer, outcome.failure_class);
        try writer.writeAll(",\"error\":");
        if (outcome.error_name) |name| try trace.writeJsonString(writer, name) else try writer.writeAll("null");
        try writer.writeAll(",\"artifactPath\":");
        if (outcome.artifact_path) |artifact| try trace.writeJsonString(writer, artifact) else try writer.writeAll("null");
        try writer.writeAll(",\"attemptRecords\":[");
        for (outcome.attempt_records.items, 0..) |record, record_index| {
            if (record_index > 0) try writer.writeAll(",");
            try writer.writeAll("{\"attemptId\":");
            try writer.print("{d}", .{record.attempt_id});
            try writer.writeAll(",\"status\":");
            try trace.writeJsonString(writer, record.status);
            try writer.writeAll(",\"failureClass\":");
            try trace.writeJsonString(writer, record.failure_class);
            try writer.writeAll(",\"error\":");
            if (record.error_name) |name| try trace.writeJsonString(writer, name) else try writer.writeAll("null");
            try writer.writeAll(",\"artifactPath\":");
            try trace.writeJsonString(writer, record.artifact_path);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
        try writer.writeAll("}");
    }
    try writer.writeAll("]}\n");
}
