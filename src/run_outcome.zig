const std = @import("std");
const stdio = @import("stdio.zig");
const trace = @import("trace.zig");

pub const max_sidecar_bytes: usize = 64 * 1024;

pub const Status = enum { passed, failed, cancelled };
pub const FailureOwner = enum { none, runner, app, configuration, infrastructure };
pub const IosTargetKind = enum { simulator, physical };
pub const IosShimMode = enum { disabled, generated, provided };

pub const IosShim = struct {
    target_kind: IosTargetKind,
    mode: IosShimMode,
    digest: ?[]const u8 = null,
};

pub const Outcome = struct {
    status: Status,
    failure_owner: FailureOwner,
    error_code: ?[]const u8 = null,
    phase: []const u8,
    summary: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    report: ?[]const u8 = null,
    child_status: ?i32 = null,
    ios_shim: ?IosShim = null,
};

pub fn validate(outcome: Outcome) !void {
    if (!validPhase(outcome.phase)) return error.InvalidRunOutcome;
    if (outcome.child_status) |status| {
        if (status < 0 or status > 255) return error.InvalidRunOutcome;
    }
    switch (outcome.status) {
        .passed => {
            if (outcome.failure_owner != .none or
                !std.mem.eql(u8, outcome.phase, "complete") or
                outcome.error_code != null or outcome.summary != null or outcome.hint != null)
            {
                return error.InvalidRunOutcome;
            }
            if (outcome.child_status) |status| {
                if (status != 0) return error.InvalidRunOutcome;
            }
        },
        .cancelled => {
            if (outcome.failure_owner != .none or
                !optionalEqual(outcome.error_code, "run.cancelled") or
                outcome.summary == null or outcome.hint == null)
            {
                return error.InvalidRunOutcome;
            }
        },
        .failed => {
            if (outcome.failure_owner == .none or outcome.error_code == null or
                outcome.summary == null or outcome.hint == null or
                std.mem.eql(u8, outcome.phase, "complete") or
                !errorCodeMatchesOwner(outcome.failure_owner, outcome.error_code.?))
            {
                return error.InvalidRunOutcome;
            }
        },
    }

    try validateText(outcome.phase, 128);
    if (outcome.error_code) |value| try validateText(value, 256);
    if (outcome.summary) |value| try validateText(value, 512);
    if (outcome.hint) |value| try validateText(value, 512);
    for ([_]?[]const u8{ outcome.trace, outcome.report }) |value| {
        if (value) |path| try validateAttemptRelativePath(path);
    }

    if (outcome.ios_shim) |shim| {
        switch (shim.mode) {
            .disabled => if (shim.digest != null) return error.InvalidRunOutcome,
            .generated, .provided => {
                const digest = shim.digest orelse return error.InvalidRunOutcome;
                if (!validSha256(digest)) return error.InvalidRunOutcome;
            },
        }
    }
}

fn optionalEqual(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |actual| std.mem.eql(u8, actual, expected) else false;
}

fn validPhase(value: []const u8) bool {
    const phases = [_][]const u8{
        "invocation",
        "evidence.init",
        "device.acquire",
        "device.preflight",
        "device.boot",
        "app.build",
        "app.install",
        "shim.build",
        "shim.start",
        "shim.prewarm",
        "scenario.validate",
        "scenario.execute",
        "trace.finalize",
        "report.generate",
        "evidence.finalize",
        "cleanup",
        "complete",
    };
    for (phases) |phase| {
        if (std.mem.eql(u8, value, phase)) return true;
    }
    return false;
}

fn errorCodeMatchesOwner(owner: FailureOwner, code: []const u8) bool {
    const runner_codes = [_][]const u8{
        "runner.unclassified",
        "runner.child_timeout",
        "runner.command_supervisor_lost",
        "runner.capture_failed",
        "runner.cleanup_failed",
        "runner.driver_protocol",
        "runner.ios_shim.build_failed",
        "runner.ios_shim.readiness_timeout",
        "runner.trace_failed",
        "runner.report_failed",
        "runner.evidence_invalid",
    };
    const configuration_codes = [_][]const u8{
        "config.invalid",
        "config.app_artifact_missing",
        "config.device_selection",
        "config.signing",
        "config.unsupported_capability",
        "config.required_tool_missing",
    };
    const infrastructure_codes = [_][]const u8{
        "infra.hosted_runner",
        "infra.device_unavailable",
        "infra.emulator_provision",
        "infra.simulator_provision",
        "infra.disk",
        "infra.network",
    };
    const app_codes = [_][]const u8{
        "app.assertion_failed",
        "app.crashed",
        "app.launch_failed",
    };
    const candidates = switch (owner) {
        .runner => &runner_codes,
        .configuration => &configuration_codes,
        .infrastructure => &infrastructure_codes,
        .app => &app_codes,
        .none => return false,
    };
    for (candidates) |candidate| {
        if (std.mem.eql(u8, code, candidate)) return true;
    }
    return false;
}

fn validateText(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidRunOutcome;
    }
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidRunOutcome;
    }
}

fn validateAttemptRelativePath(value: []const u8) !void {
    if (value.len == 0 or value.len > 4096 or value[0] == '/' or
        value[value.len - 1] == '/' or std.mem.indexOfScalar(u8, value, '\\') != null)
    {
        return error.InvalidRunOutcome;
    }
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.InvalidRunOutcome;
        }
        try validateText(part, 255);
    }
}

fn validSha256(value: []const u8) bool {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return false;
    for (value[7..]) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

pub fn writeJson(writer: anytype, outcome: Outcome) !void {
    try validate(outcome);
    try writer.writeAll("{\"schemaVersion\":1,\"status\":");
    try trace.writeJsonString(writer, @tagName(outcome.status));
    try writer.writeAll(",\"failureOwner\":");
    try trace.writeJsonString(writer, @tagName(outcome.failure_owner));
    try writeOptionalString(writer, ",\"errorCode\":", outcome.error_code);
    try writer.writeAll(",\"phase\":");
    try trace.writeJsonString(writer, outcome.phase);
    try writeOptionalString(writer, ",\"summary\":", outcome.summary);
    try writeOptionalString(writer, ",\"hint\":", outcome.hint);
    try writeOptionalString(writer, ",\"trace\":", outcome.trace);
    try writeOptionalString(writer, ",\"report\":", outcome.report);
    try writer.writeAll(",\"childStatus\":");
    if (outcome.child_status) |status| {
        try writer.print("{d}", .{status});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"iosShim\":");
    if (outcome.ios_shim) |shim| {
        try writer.writeAll("{\"targetKind\":");
        try trace.writeJsonString(writer, @tagName(shim.target_kind));
        try writer.writeAll(",\"mode\":");
        try trace.writeJsonString(writer, @tagName(shim.mode));
        try writeOptionalString(writer, ",\"digest\":", shim.digest);
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
}

fn writeOptionalString(writer: anytype, prefix: []const u8, value: ?[]const u8) !void {
    try writer.writeAll(prefix);
    if (value) |text_value| {
        try trace.writeJsonString(writer, text_value);
    } else {
        try writer.writeAll("null");
    }
}

pub fn writeAtomic(
    allocator: std.mem.Allocator,
    evidence_root: []const u8,
    relative_path: []const u8,
    outcome: Outcome,
) !void {
    const basename = try outcomeBasename(relative_path);
    try validate(outcome);

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try writeJson(&encoded.writer, outcome);
    if (encoded.written().len > max_sidecar_bytes) return error.RunOutcomeTooLarge;

    const io = stdio.io();
    var root_dir = try std.Io.Dir.cwd().openDir(io, evidence_root, .{
        .follow_symlinks = false,
    });
    defer root_dir.close(io);
    var outcome_dir = try root_dir.openDir(io, "run-outcomes", .{
        .follow_symlinks = false,
    });
    defer outcome_dir.close(io);

    var temp_buffer: [160]u8 = undefined;
    var random_integer: u64 = undefined;
    io.random(std.mem.asBytes(&random_integer));
    const temporary = try std.fmt.bufPrint(
        &temp_buffer,
        ".{s}.{x}.tmp",
        .{ basename, random_integer },
    );
    var temporary_exists = false;
    defer if (temporary_exists) outcome_dir.deleteFile(io, temporary) catch {};

    {
        var file = try outcome_dir.createFile(io, temporary, .{
            .truncate = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
            .resolve_beneath = true,
        });
        defer file.close(io);
        temporary_exists = true;
        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writerStreaming(io, &write_buffer);
        try file_writer.interface.writeAll(encoded.written());
        try file_writer.interface.flush();
        try file.sync(io);
    }

    try outcome_dir.rename(temporary, outcome_dir, basename, io);
    temporary_exists = false;
    const outcome_dir_file = std.Io.File{
        .handle = outcome_dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try outcome_dir_file.sync(io);
}

fn outcomeBasename(relative_path: []const u8) ![]const u8 {
    const prefix = "run-outcomes/";
    if (!std.mem.startsWith(u8, relative_path, prefix)) return error.InvalidOutcomePath;
    const basename = relative_path[prefix.len..];
    if (basename.len != 37 or !std.mem.endsWith(u8, basename, ".json")) {
        return error.InvalidOutcomePath;
    }
    for (basename[0..32]) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidOutcomePath;
    }
    return basename;
}

pub fn validateOutcomePath(relative_path: []const u8) !void {
    _ = try outcomeBasename(relative_path);
}

pub fn sha256File(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const content = try stdio.readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(content);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const result = try allocator.alloc(u8, 71);
    @memcpy(result[0..7], "sha256:");
    _ = std.fmt.bufPrint(result[7..], "{x}", .{digest}) catch unreachable;
    return result;
}
