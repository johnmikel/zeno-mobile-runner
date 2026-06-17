const std = @import("std");
const stdio = @import("stdio.zig");

pub fn cwd() Cwd {
    return .{};
}

pub const Cwd = struct {
    pub fn makePath(_: Cwd, path: []const u8) !void {
        return std.Io.Dir.cwd().createDirPath(stdio.io(), path);
    }

    pub fn writeFile(_: Cwd, options: std.Io.Dir.WriteFileOptions) !void {
        return std.Io.Dir.cwd().writeFile(stdio.io(), options);
    }

    pub fn readFileAlloc(_: Cwd, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(stdio.io(), path, allocator, .limited(limit));
    }

    pub fn createFile(_: Cwd, path: []const u8, flags: std.Io.Dir.CreateFileOptions) !File {
        return createFileIn(std.Io.Dir.cwd(), path, flags);
    }

    pub fn deleteTree(_: Cwd, path: []const u8) !void {
        return std.Io.Dir.cwd().deleteTree(stdio.io(), path);
    }

    pub fn deleteFile(_: Cwd, path: []const u8) !void {
        return std.Io.Dir.cwd().deleteFile(stdio.io(), path);
    }

    pub fn access(_: Cwd, path: []const u8, options: std.Io.Dir.AccessOptions) !void {
        return std.Io.Dir.cwd().access(stdio.io(), path, options);
    }
};

pub const File = struct {
    inner: std.Io.File,

    pub fn writeAll(self: *File, bytes: []const u8) !void {
        return std.Io.File.writeStreamingAll(self.inner, stdio.io(), bytes);
    }

    pub fn chmod(self: *File, mode: std.posix.mode_t) !void {
        return self.inner.setPermissions(stdio.io(), .fromMode(mode));
    }

    pub fn close(self: *File) void {
        self.inner.close(stdio.io());
    }
};

pub fn createFileIn(dir: std.Io.Dir, path: []const u8, flags: std.Io.Dir.CreateFileOptions) !File {
    return .{ .inner = try dir.createFile(stdio.io(), path, flags) };
}

pub fn readFileAllocIn(dir: std.Io.Dir, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return dir.readFileAlloc(stdio.io(), path, allocator, .limited(limit));
}
