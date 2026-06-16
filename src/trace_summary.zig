const std = @import("std");
const stdio = @import("stdio.zig");
const trace = @import("trace.zig");
const trace_summary_diagnostic = @import("trace_summary_diagnostic.zig");

pub const DiagnosticEvent = trace_summary_diagnostic.DiagnosticEvent;

pub const Summary = struct {
    scenario_name: []u8,
    status: []u8,
    app_id: ?[]u8 = null,
    events_path: []u8,
    artifacts_dir: []u8,
    duration_ms: ?i64 = null,
    event_count: ?i64 = null,
    snapshot_count: ?i64 = null,
    partial_failure_count: ?i64 = null,
    failed_step_index: ?i64 = null,
    error_name: ?[]u8 = null,
    report_path: ?[]u8 = null,
    diagnostic: DiagnosticEvent = .{},
    partial_failure: ?DiagnosticEvent = null,
    last_kind: ?[]u8 = null,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.scenario_name);
        allocator.free(self.status);
        if (self.app_id) |value| allocator.free(value);
        allocator.free(self.events_path);
        allocator.free(self.artifacts_dir);
        if (self.error_name) |value| allocator.free(value);
        if (self.report_path) |value| allocator.free(value);
        self.diagnostic.deinit(allocator);
        if (self.partial_failure) |*value| value.deinit(allocator);
        if (self.last_kind) |value| allocator.free(value);
    }
};

const TerminalEvent = struct {
    status: ?[]u8 = null,
    error_name: ?[]u8 = null,
    failed_step_index: ?i64 = null,

    fn deinit(self: *TerminalEvent, allocator: std.mem.Allocator) void {
        if (self.status) |value| allocator.free(value);
        if (self.error_name) |value| allocator.free(value);
    }

    fn setStatus(self: *TerminalEvent, allocator: std.mem.Allocator, value: ?[]const u8) !void {
        if (self.status) |old| allocator.free(old);
        self.status = if (value) |actual| try allocator.dupe(u8, actual) else null;
    }

    fn setErrorName(self: *TerminalEvent, allocator: std.mem.Allocator, value: ?[]const u8) !void {
        if (self.error_name) |old| allocator.free(old);
        self.error_name = if (value) |actual| try allocator.dupe(u8, actual) else null;
    }
};

pub fn read(allocator: std.mem.Allocator, trace_dir: []const u8) !Summary {
    const manifest_path = try std.fs.path.join(allocator, &.{ trace_dir, "trace.json" });
    defer allocator.free(manifest_path);
    const manifest_content = try stdio.readFileAlloc(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(manifest_content);

    const manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_content, .{});
    defer manifest.deinit();
    if (manifest.value != .object) return error.InvalidTraceManifest;
    const manifest_object = manifest.value.object;

    const scenario_name = stringField(manifest_object, "scenarioName") orelse "";
    const manifest_status = stringField(manifest_object, "status") orelse "";
    const app_id = stringField(manifest_object, "appId");
    const error_name = stringField(manifest_object, "error");
    const events_path_value = stringField(manifest_object, "eventsPath") orelse "events.jsonl";
    const artifacts_dir_value = stringField(manifest_object, "artifactsDir") orelse "artifacts";
    const report_path = stringField(manifest_object, "reportPath");
    const failed_step_index = intField(manifest_object, "failedStepIndex");
    const duration_ms = intField(manifest_object, "durationMs");
    const event_count = intField(manifest_object, "eventCount");
    const snapshot_count = intField(manifest_object, "snapshotCount");
    const partial_failure_count = intField(manifest_object, "partialFailureCount");

    var terminal = TerminalEvent{};
    defer terminal.deinit(allocator);
    var diagnostic = DiagnosticEvent{};
    defer diagnostic.deinit(allocator);
    var partial_failure: ?DiagnosticEvent = null;
    defer if (partial_failure) |*value| value.deinit(allocator);
    var last_kind: ?[]u8 = null;
    defer if (last_kind) |value| allocator.free(value);

    const events_path = try std.fs.path.join(allocator, &.{ trace_dir, events_path_value });
    defer allocator.free(events_path);
    if (stdio.readFileAlloc(allocator, events_path, 64 * 1024 * 1024)) |events_content| {
        defer allocator.free(events_content);
        try scanEvents(allocator, events_content, &terminal, &diagnostic, &partial_failure, &last_kind);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const terminal_status = terminal.status orelse manifest_status;
    const effective_status = if (std.mem.eql(u8, manifest_status, "partial") and std.mem.eql(u8, terminal_status, "passed"))
        manifest_status
    else
        terminal_status;

    return .{
        .scenario_name = try allocator.dupe(u8, scenario_name),
        .status = try allocator.dupe(u8, effective_status),
        .app_id = try dupeOptionalString(allocator, app_id),
        .events_path = try allocator.dupe(u8, events_path_value),
        .artifacts_dir = try allocator.dupe(u8, artifacts_dir_value),
        .duration_ms = duration_ms,
        .event_count = event_count,
        .snapshot_count = snapshot_count,
        .partial_failure_count = partial_failure_count,
        .failed_step_index = terminal.failed_step_index orelse failed_step_index,
        .error_name = try dupeOptionalString(allocator, terminal.error_name orelse error_name),
        .report_path = try dupeOptionalString(allocator, report_path),
        .diagnostic = blk: {
            const value = diagnostic;
            diagnostic = .{};
            break :blk value;
        },
        .partial_failure = blk: {
            const value = partial_failure;
            partial_failure = null;
            break :blk value;
        },
        .last_kind = blk: {
            const value = last_kind;
            last_kind = null;
            break :blk value;
        },
    };
}

fn scanEvents(
    allocator: std.mem.Allocator,
    events_content: []const u8,
    terminal: *TerminalEvent,
    diagnostic: *DiagnosticEvent,
    partial_failure: *?DiagnosticEvent,
    last_kind: *?[]u8,
) !void {
    var lines = std.mem.splitScalar(u8, events_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const kind = stringField(object, "kind") orelse continue;
        if (last_kind.*) |old| allocator.free(old);
        last_kind.* = try allocator.dupe(u8, kind);

        const payload_value = object.get("payload") orelse continue;
        if (payload_value != .object) continue;
        const payload = payload_value.object;

        if (std.mem.eql(u8, kind, "scenario.end")) {
            try terminal.setStatus(allocator, stringField(payload, "status"));
            try terminal.setErrorName(allocator, stringField(payload, "error"));
            terminal.failed_step_index = intField(payload, "failedStepIndex");
        } else if (isDiagnosticKind(kind, payload)) {
            diagnostic.deinit(allocator);
            diagnostic.* = try DiagnosticEvent.fromPayload(allocator, kind, payload);
            if (isPartialFailureEvent(kind, payload)) {
                if (partial_failure.*) |*old| old.deinit(allocator);
                partial_failure.* = try DiagnosticEvent.fromPayload(allocator, kind, payload);
            }
        }
    }
}

pub fn writeDiagnosticJson(writer: anytype, diagnostic: DiagnosticEvent) !void {
    try trace_summary_diagnostic.writeJson(writer, diagnostic);
}

pub fn writePartialFailureJson(writer: anytype, partial: DiagnosticEvent) !void {
    try trace_summary_diagnostic.writePartialJson(writer, partial);
}

fn isDiagnosticKind(kind: []const u8, payload: std.json.ObjectMap) bool {
    if (isPartialFailureEvent(kind, payload)) return true;
    if (payload.get("snapshotId") == null) return false;
    return std.mem.indexOf(u8, kind, "wait.") != null or
        std.mem.indexOf(u8, kind, "notFound") != null or
        std.mem.indexOf(u8, kind, "scrollUntilVisible") != null;
}

fn isPartialFailureEvent(kind: []const u8, payload: std.json.ObjectMap) bool {
    if (!std.mem.eql(u8, kind, "observe.snapshot.semanticExtraction")) return false;
    return std.mem.eql(u8, stringField(payload, "artifactStatus") orelse "", "captured") and
        std.mem.eql(u8, stringField(payload, "semanticStatus") orelse "", "failed");
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |actual| return try allocator.dupe(u8, actual);
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn intField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |actual| actual,
        else => null,
    };
}
