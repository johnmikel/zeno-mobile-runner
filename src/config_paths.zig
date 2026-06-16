const std = @import("std");
const stdio = @import("stdio.zig");
const config = @import("config.zig");

pub const default_path = ".zmr/config.json";

pub fn loadIfPresent(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !?config.Config {
    if (explicit_path) |path| return try config.parseFile(allocator, path);
    stdio.access(default_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try config.parseFile(allocator, default_path);
}

pub fn rootForPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(path) orelse ".";
    if (std.mem.eql(u8, std.fs.path.basename(parent), ".zmr")) {
        return try allocator.dupe(u8, std.fs.path.dirname(parent) orelse ".");
    }
    return try allocator.dupe(u8, ".");
}

pub fn ownFilePath(
    allocator: std.mem.Allocator,
    owned_paths: *std.ArrayList([]const u8),
    config_root: []const u8,
    path: []const u8,
) ![]const u8 {
    const resolved = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ config_root, path });
    try owned_paths.append(allocator, resolved);
    return resolved;
}

pub fn ownCommandPath(
    allocator: std.mem.Allocator,
    owned_paths: *std.ArrayList([]const u8),
    config_root: []const u8,
    path: []const u8,
) ![]const u8 {
    if (!std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, std.fs.path.sep) == null and !std.mem.startsWith(u8, path, ".")) {
        const owned = try allocator.dupe(u8, path);
        try owned_paths.append(allocator, owned);
        return owned;
    }
    return try ownFilePath(allocator, owned_paths, config_root, path);
}
