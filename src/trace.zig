const std = @import("std");
const stdio = @import("stdio.zig");
const selector = @import("selector.zig");
const trace_json = @import("trace_json.zig");
const types = @import("types.zig");
const version = @import("version.zig");

pub const RedactionRules = trace_json.RedactionRules;

pub const CaptureOptions = struct {
    capture_screenshots: bool = true,
    capture_hierarchy: bool = true,
    capture_logs: bool = true,
    capture_screen_recording: bool = false,
    redaction: RedactionRules = .{},
};

pub const TraceWriter = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    event_count: usize = 0,
    snapshot_count: usize = 0,
    partial_failure_count: usize = 0,
    manifest: ?Manifest = null,
    capture: CaptureOptions = .{},

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) !TraceWriter {
        return try initWithOptions(allocator, root_dir, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, root_dir: []const u8, capture: CaptureOptions) !TraceWriter {
        try std.Io.Dir.cwd().createDirPath(stdio.io(), root_dir);
        try resetTraceDirectory(allocator, root_dir);
        const artifacts_path = try std.fs.path.join(allocator, &.{ root_dir, "artifacts" });
        defer allocator.free(artifacts_path);
        try std.Io.Dir.cwd().createDirPath(stdio.io(), artifacts_path);
        return .{
            .allocator = allocator,
            .root_dir = try allocator.dupe(u8, root_dir),
            .capture = capture,
        };
    }

    pub fn deinit(self: *TraceWriter) void {
        if (self.manifest) |*manifest| manifest.deinit(self.allocator);
        self.allocator.free(self.root_dir);
    }

    pub fn startManifest(self: *TraceWriter, scenario_name: []const u8, app_id: ?[]const u8) !void {
        if (self.manifest) |*existing| existing.deinit(self.allocator);
        self.manifest = .{
            .scenario_name = try self.allocator.dupe(u8, scenario_name),
            .app_id = try dupeOptional(self.allocator, app_id),
            .status = try self.allocator.dupe(u8, "running"),
            .started_at_ms = stdio.nowMs(),
        };
        try self.writeManifest();
    }

    pub const FinishManifestOptions = struct {
        status: []const u8,
        failed_step_index: ?usize = null,
        error_name: ?[]const u8 = null,
        report_path: ?[]const u8 = null,
    };

    pub fn finishManifest(self: *TraceWriter, options: FinishManifestOptions) !void {
        if (self.manifest == null) return;
        var manifest = &self.manifest.?;
        self.allocator.free(manifest.status);
        manifest.status = try self.allocator.dupe(u8, options.status);
        manifest.ended_at_ms = stdio.nowMs();
        manifest.failed_step_index = options.failed_step_index;
        if (manifest.error_name) |value| self.allocator.free(value);
        manifest.error_name = try dupeOptional(self.allocator, options.error_name);
        if (options.report_path) |value| {
            if (manifest.report_path) |old| self.allocator.free(old);
            manifest.report_path = try self.allocator.dupe(u8, value);
        }
        try self.writeManifest();
    }

    pub fn attachReport(self: *TraceWriter, report_path: []const u8) !void {
        if (self.manifest == null) return;
        var manifest = &self.manifest.?;
        if (manifest.report_path) |old| self.allocator.free(old);
        manifest.report_path = try self.allocator.dupe(u8, report_path);
        try self.writeManifest();
    }

    pub fn nextSnapshotId(self: *TraceWriter) ![]const u8 {
        self.snapshot_count += 1;
        return try std.fmt.allocPrint(self.allocator, "snapshot-{d}", .{self.snapshot_count});
    }

    pub fn artifactPath(self: *TraceWriter, name: []const u8) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.root_dir, "artifacts", name });
    }

    pub fn writeArtifact(self: *TraceWriter, name: []const u8, bytes: []const u8) ![]const u8 {
        const path = try self.artifactPath(name);
        errdefer self.allocator.free(path);
        var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
        defer file.close(stdio.io());
        try std.Io.File.writeStreamingAll(file, stdio.io(), bytes);
        return path;
    }

    pub fn recordEvent(self: *TraceWriter, kind: []const u8, payload: []const u8) !void {
        self.event_count += 1;
        if (isPartialFailureEvent(kind, payload)) self.partial_failure_count += 1;
        const path = try std.fs.path.join(self.allocator, &.{ self.root_dir, "events.jsonl" });
        defer self.allocator.free(path);
        const existing = stdio.readFileAlloc(self.allocator, path, 64 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        const had_existing_file = existing.ptr != "".ptr;
        defer if (had_existing_file) self.allocator.free(existing);

        var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
        defer file.close(stdio.io());
        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writerStreaming(stdio.io(), &write_buffer);
        const writer = &file_writer.interface;
        if (existing.len > 0) try writer.writeAll(existing);
        try writer.print(
            "{{\"seq\":{d},\"timestampMs\":{d},\"kind\":\"{s}\",\"payload\":",
            .{ self.event_count, stdio.nowMs(), kind },
        );
        try trace_json.writeRedactedJsonPayload(self.allocator, writer, payload, self.capture.redaction);
        try writer.writeAll("}\n");
        try writer.flush();
        try self.writeManifest();
    }

    pub fn writeSnapshot(self: *TraceWriter, snapshot: types.ObservationSnapshot) ![]const u8 {
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.json", .{snapshot.id});
        defer self.allocator.free(file_name);
        const path = try self.artifactPath(file_name);
        errdefer self.allocator.free(path);
        var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
        defer file.close(stdio.io());
        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writerStreaming(stdio.io(), &write_buffer);
        try trace_json.writeSnapshotJsonRedacted(&file_writer.interface, snapshot, self.capture.redaction);
        try file_writer.interface.flush();
        return path;
    }

    pub fn flushManifest(self: *TraceWriter) !void {
        try self.writeManifest();
    }

    fn writeManifest(self: *TraceWriter) !void {
        if (self.manifest == null) return;
        const manifest = self.manifest.?;
        const path = try std.fs.path.join(self.allocator, &.{ self.root_dir, "trace.json" });
        defer self.allocator.free(path);
        var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
        defer file.close(stdio.io());
        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writerStreaming(stdio.io(), &write_buffer);
        const writer = &file_writer.interface;

        try writer.writeAll("{");
        try writer.writeAll("\"schemaVersion\":1");
        try writer.writeAll(",\"runnerVersion\":");
        try writeJsonString(writer, version.runner_version);
        try writer.writeAll(",\"protocolVersion\":");
        try writeJsonString(writer, version.protocol_version);
        try writer.writeAll(",\"scenarioName\":");
        try writeJsonString(writer, manifest.scenario_name);
        try writer.writeAll(",\"appId\":");
        if (manifest.app_id) |app_id| {
            try writeJsonString(writer, app_id);
        } else {
            try writer.writeAll("null");
        }
        const effective_status = if (std.mem.eql(u8, manifest.status, "passed") and self.partial_failure_count > 0) "partial" else manifest.status;
        try writer.writeAll(",\"status\":");
        try writeJsonString(writer, effective_status);
        try writer.print(",\"startedAtMs\":{d}", .{manifest.started_at_ms});
        try writer.writeAll(",\"endedAtMs\":");
        if (manifest.ended_at_ms) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"durationMs\":");
        if (manifest.ended_at_ms) |ended| {
            try writer.print("{d}", .{ended - manifest.started_at_ms});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"failedStepIndex\":");
        if (manifest.failed_step_index) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"error\":");
        if (manifest.error_name) |value| {
            try writeJsonString(writer, value);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"eventsPath\":\"events.jsonl\"");
        try writer.writeAll(",\"artifactsDir\":\"artifacts\"");
        try writer.print(",\"eventCount\":{d}", .{self.event_count});
        try writer.print(",\"snapshotCount\":{d}", .{self.snapshot_count});
        try writer.print(",\"partialFailureCount\":{d}", .{self.partial_failure_count});
        try writer.writeAll(",\"reportPath\":");
        if (manifest.report_path) |value| {
            try writeJsonString(writer, value);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}\n");
        try writer.flush();
    }
};

fn isPartialFailureEvent(kind: []const u8, payload: []const u8) bool {
    return std.mem.eql(u8, kind, "observe.snapshot.semanticExtraction") and
        std.mem.indexOf(u8, payload, "\"status\":\"failed\"") != null;
}

fn resetTraceDirectory(allocator: std.mem.Allocator, root_dir: []const u8) !void {
    const stale_files = [_][]const u8{ "events.jsonl", "trace.json", "report.html" };
    for (stale_files) |name| {
        const path = try std.fs.path.join(allocator, &.{ root_dir, name });
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(stdio.io(), path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    const artifacts_path = try std.fs.path.join(allocator, &.{ root_dir, "artifacts" });
    defer allocator.free(artifacts_path);
    var artifacts_exists = true;
    stdio.access(artifacts_path) catch |err| switch (err) {
        error.FileNotFound => artifacts_exists = false,
        else => return err,
    };
    if (artifacts_exists) try std.Io.Dir.cwd().deleteTree(stdio.io(), artifacts_path);
}

const Manifest = struct {
    scenario_name: []const u8,
    app_id: ?[]const u8 = null,
    status: []const u8,
    started_at_ms: i64,
    ended_at_ms: ?i64 = null,
    failed_step_index: ?usize = null,
    error_name: ?[]const u8 = null,
    report_path: ?[]const u8 = null,

    fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.scenario_name);
        if (self.app_id) |value| allocator.free(value);
        allocator.free(self.status);
        if (self.error_name) |value| allocator.free(value);
        if (self.report_path) |value| allocator.free(value);
    }
};

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |actual| return try allocator.dupe(u8, actual);
    return null;
}

pub fn writeSnapshotJson(writer: anytype, snapshot: types.ObservationSnapshot) !void {
    try trace_json.writeSnapshotJson(writer, snapshot);
}

pub fn attachReportPath(allocator: std.mem.Allocator, root_dir: []const u8, report_path: []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "trace.json" });
    defer allocator.free(manifest_path);

    const content = stdio.readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTraceManifest;

    const arena_allocator = parsed.arena.allocator();
    const owned_report_path = try arena_allocator.dupe(u8, report_path);
    try parsed.value.object.put(arena_allocator, "reportPath", .{ .string = owned_report_path });

    var file = try std.Io.Dir.cwd().createFile(stdio.io(), manifest_path, .{ .truncate = true });
    defer file.close(stdio.io());
    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(stdio.io(), &write_buffer);
    try std.json.Stringify.value(parsed.value, .{}, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

pub fn writeNodeJson(writer: anytype, node: types.UiNode) !void {
    try trace_json.writeNodeJson(writer, node);
}

pub fn writeSelectorJson(writer: anytype, wanted: selector.Selector) !void {
    try trace_json.writeSelectorJson(writer, wanted);
}

pub fn writeRedactedJsonString(writer: anytype, value: []const u8) !void {
    try trace_json.writeRedactedJsonString(writer, value);
}

pub fn writeRedactedJsonStringForKey(writer: anytype, key: []const u8, value: []const u8, force_secret: bool) !void {
    try trace_json.writeRedactedJsonStringForKey(writer, key, value, force_secret);
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try trace_json.writeJsonString(writer, value);
}
