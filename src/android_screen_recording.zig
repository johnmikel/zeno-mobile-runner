const std = @import("std");
const stdio = @import("stdio.zig");
const command = @import("command.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

const default_max_output = 32 * 1024 * 1024;
const default_adb_timeout_ms = 15_000;

pub fn start(
    allocator: std.mem.Allocator,
    adb_path: []const u8,
    serial: ?[]const u8,
    remote_path: []const u8,
) !AndroidScreenRecording {
    const cleanup = runAdbCommand(allocator, adb_path, serial, &.{ "shell", "rm", "-f", remote_path }, 4096) catch null;
    if (cleanup) |result| result.deinit(allocator);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try appendAdbBase(allocator, &argv, adb_path, serial);
    try argv.appendSlice(allocator, &.{ "shell", "screenrecord", remote_path });

    const owned_adb_path = try allocator.dupe(u8, adb_path);
    errdefer allocator.free(owned_adb_path);
    const owned_serial = try types.dupeOptional(allocator, serial);
    errdefer if (owned_serial) |value| allocator.free(value);
    const owned_remote_path = try allocator.dupe(u8, remote_path);
    errdefer allocator.free(owned_remote_path);

    const child = try std.process.spawn(stdio.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    return .{
        .allocator = allocator,
        .adb_path = owned_adb_path,
        .serial = owned_serial,
        .remote_path = owned_remote_path,
        .child = child,
    };
}

pub const AndroidScreenRecording = struct {
    allocator: std.mem.Allocator,
    adb_path: []const u8,
    serial: ?[]const u8,
    remote_path: []const u8,
    child: std.process.Child,
    stopped: bool = false,

    pub fn deinit(self: *AndroidScreenRecording) void {
        self.stopProcess() catch {};
        self.allocator.free(self.adb_path);
        if (self.serial) |value| self.allocator.free(value);
        self.allocator.free(self.remote_path);
    }

    pub fn stopAndPull(self: *AndroidScreenRecording, writer: *trace.TraceWriter, artifact_name: []const u8) ![]const u8 {
        try self.stopProcess();
        const artifact_path = try writer.artifactPath(artifact_name);
        errdefer self.allocator.free(artifact_path);

        const pull = try self.runAdb(&.{ "pull", self.remote_path, artifact_path }, default_max_output);
        defer pull.deinit(self.allocator);
        try pull.ensureSuccess();

        const cleanup = self.runAdb(&.{ "shell", "rm", "-f", self.remote_path }, 4096) catch null;
        if (cleanup) |result| result.deinit(self.allocator);

        return artifact_path;
    }

    fn stopProcess(self: *AndroidScreenRecording) !void {
        if (self.stopped) return;
        if (self.child.id) |child_id| {
            std.posix.kill(child_id, std.posix.SIG.INT) catch {};
            _ = try self.child.wait(stdio.io());
        }
        self.stopped = true;
    }

    fn runAdb(self: *AndroidScreenRecording, extra: []const []const u8, max_output_bytes: usize) !command.ExecResult {
        return try runAdbCommand(self.allocator, self.adb_path, self.serial, extra, max_output_bytes);
    }
};

fn runAdbCommand(
    allocator: std.mem.Allocator,
    adb_path: []const u8,
    serial: ?[]const u8,
    extra: []const []const u8,
    max_output_bytes: usize,
) !command.ExecResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try appendAdbBase(allocator, &argv, adb_path, serial);
    try argv.appendSlice(allocator, extra);
    return try command.runWithTimeout(allocator, argv.items, max_output_bytes, default_adb_timeout_ms);
}

fn appendAdbBase(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    adb_path: []const u8,
    serial: ?[]const u8,
) !void {
    try argv.append(allocator, adb_path);
    if (serial) |value| {
        try argv.append(allocator, "-s");
        try argv.append(allocator, value);
    }
}
