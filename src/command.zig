const std = @import("std");
const stdio = @import("stdio.zig");

pub const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    timed_out: bool = false,

    pub fn deinit(self: ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn ensureSuccess(self: ExecResult) !void {
        if (self.timed_out) return error.CommandTimedOut;
        switch (self.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        return error.CommandFailed;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_output_bytes: usize,
) !ExecResult {
    const result = try std.process.run(allocator, stdio.io(), .{
        .argv = argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
        .timed_out = false,
    };
}

pub fn runWithInput(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin: []const u8,
    max_output_bytes: usize,
) !ExecResult {
    return try runWithInputTimeout(allocator, argv, stdin, max_output_bytes, 0);
}

pub fn runWithInputTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin: []const u8,
    max_output_bytes: usize,
    timeout_ms: u64,
) !ExecResult {
    var child = try std.process.spawn(stdio.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer if (child.id != null) child.kill(stdio.io());

    if (child.stdin) |stdin_file| {
        var stdin_buffer: [8192]u8 = undefined;
        var stdin_writer = stdin_file.writerStreaming(stdio.io(), &stdin_buffer);
        try stdin_writer.interface.writeAll(stdin);
        try stdin_writer.interface.flush();
        stdin_file.close(stdio.io());
        child.stdin = null;
    }

    return try collectSpawnedOutput(allocator, &child, max_output_bytes, timeoutForMs(timeout_ms));
}

pub fn runWithTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_output_bytes: usize,
    timeout_ms: u64,
) !ExecResult {
    if (timeout_ms == 0) return run(allocator, argv, max_output_bytes);

    const result = std.process.run(allocator, stdio.io(), .{
        .argv = argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .timeout = timeoutForMs(timeout_ms),
    }) catch |err| switch (err) {
        error.Timeout => return timedOutResult(allocator),
        else => |actual| return actual,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
        .timed_out = false,
    };
}

fn collectSpawnedOutput(
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    max_output_bytes: usize,
    timeout: std.Io.Timeout,
) !ExecResult {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, stdio.io(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
        if (stderr_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            child.kill(stdio.io());
            return timedOutResult(allocator);
        },
        else => |actual| return actual,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(stdio.io());

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
        .timed_out = false,
    };
}

fn timedOutResult(allocator: std.mem.Allocator) !ExecResult {
    return .{
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
        .term = .{ .unknown = 0 },
        .timed_out = true,
    };
}

fn timeoutForMs(timeout_ms: u64) std.Io.Timeout {
    if (timeout_ms == 0) return .none;
    const timeout_ns = std.math.mul(u64, timeout_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    return .{ .duration = .{
        .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
        .clock = .awake,
    } };
}

pub fn escapeAdbInputText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        switch (ch) {
            ' ' => try out.appendSlice(allocator, "%s"),
            '&', '<', '>', ';', '|', '*', '~', '"', '\'', '\\', '(', ')' => {
                try out.append(allocator, '\\');
                try out.append(allocator, ch);
            },
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn escapeAdbShellArg(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}
