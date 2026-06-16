const std = @import("std");

const default_buffer_size = 8192;
var process_environ: ?std.process.Environ = null;
var process_threaded: ?std.Io.Threaded = null;

fn processIo() std.Io {
    if (process_threaded) |*threaded| return threaded.io();
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn initProcess(init: std.process.Init.Minimal, allocator: std.mem.Allocator) void {
    process_environ = init.environ;
    process_threaded = .init(allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
}

pub fn deinitProcess() void {
    if (process_threaded) |*threaded| {
        threaded.deinit();
        process_threaded = null;
    }
    process_environ = null;
}

pub fn io() std.Io {
    return processIo();
}

pub fn sleepNs(nanoseconds: u64) void {
    std.Io.sleep(
        processIo(),
        std.Io.Duration.fromNanoseconds(@intCast(nanoseconds)),
        .awake,
    ) catch {};
}

pub fn nowNs() i96 {
    return std.Io.Clock.real.now(processIo()).nanoseconds;
}

pub fn nowMs() i64 {
    return @intCast(@divTrunc(nowNs(), std.time.ns_per_ms));
}

pub fn getenv(name: []const u8) ?[]const u8 {
    const environ = process_environ orelse return null;
    const block = environ.block;
    const Block = @TypeOf(block);
    if (Block != std.process.Environ.PosixBlock) return null;

    for (block.view().slice) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

pub fn access(path: []const u8) !void {
    return accessWithOptions(path, .{});
}

pub fn accessWithOptions(path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.cwd().access(processIo(), path, options);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(processIo(), path, allocator, .limited(limit));
}

pub const Output = struct {
    buffer: [default_buffer_size]u8 = undefined,
    file_writer: std.Io.File.Writer = undefined,
    initialized: bool = false,

    pub fn init(self: *Output, file: std.Io.File) void {
        self.file_writer = file.writerStreaming(processIo(), &self.buffer);
        self.initialized = true;
    }

    pub fn writer(self: *Output) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    pub fn flush(self: *Output) !void {
        if (self.initialized) try self.file_writer.interface.flush();
    }

    pub fn deinit(self: *Output) void {
        self.flush() catch {};
        self.initialized = false;
    }
};

pub const Input = struct {
    buffer: [default_buffer_size]u8 = undefined,
    file_reader: std.Io.File.Reader = undefined,

    pub fn init(self: *Input, file: std.Io.File) void {
        self.file_reader = file.readerStreaming(processIo(), &self.buffer);
    }

    pub fn reader(self: *Input) *std.Io.Reader {
        return &self.file_reader.interface;
    }
};

pub fn readLineAlloc(reader: *std.Io.Reader, allocator: std.mem.Allocator, max_bytes: usize) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    _ = try reader.streamDelimiterLimit(&out.writer, '\n', .limited(max_bytes));

    const next = reader.peek(1) catch |err| switch (err) {
        error.EndOfStream => {
            if (out.writer.end == 0) {
                out.deinit();
                return null;
            }
            return try out.toOwnedSlice();
        },
        else => |actual| return actual,
    };
    if (next.len > 0 and next[0] == '\n') reader.toss(1);
    return try out.toOwnedSlice();
}
