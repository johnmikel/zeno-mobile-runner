const std = @import("std");
const bundle_redaction = @import("bundle_redaction.zig");
const bundle_tar = @import("bundle_tar.zig");
const stdio = @import("stdio.zig");

pub const ExportOptions = bundle_redaction.Options;

pub fn exportTraceBundle(allocator: std.mem.Allocator, trace_dir: []const u8, out_path: []const u8) !void {
    return exportTraceBundleWithOptions(allocator, trace_dir, out_path, .{});
}

pub fn exportTraceBundleWithOptions(
    allocator: std.mem.Allocator,
    trace_dir: []const u8,
    out_path: []const u8,
    options: ExportOptions,
) !void {
    try requireTraceFile(allocator, trace_dir, "trace.json", error.MissingTraceManifest);
    try requireTraceFile(allocator, trace_dir, "events.jsonl", error.MissingTraceEvents);

    var entries = std.ArrayList([]const u8).empty;
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    try entries.append(allocator, try allocator.dupe(u8, "trace.json"));
    try entries.append(allocator, try allocator.dupe(u8, "events.jsonl"));
    if (traceFileExists(allocator, trace_dir, "report.html") catch |err| return err) {
        try entries.append(allocator, try allocator.dupe(u8, "report.html"));
    }

    var artifact_entries = std.ArrayList([]const u8).empty;
    defer {
        for (artifact_entries.items) |entry| allocator.free(entry);
        artifact_entries.deinit(allocator);
    }
    try collectArtifactEntries(allocator, trace_dir, "artifacts", &artifact_entries);
    std.mem.sort([]const u8, artifact_entries.items, {}, stringLessThan);
    for (artifact_entries.items) |entry| {
        try entries.append(allocator, try allocator.dupe(u8, entry));
    }

    var out_file = try std.Io.Dir.cwd().createFile(stdio.io(), out_path, .{ .truncate = true });
    defer out_file.close(stdio.io());

    for (entries.items) |archive_path| {
        if (options.redact) {
            if (options.omit_screenshots and bundle_redaction.isVisualArtifactPath(archive_path)) continue;
            if (bundle_redaction.isPlaceholderScreenshotPath(archive_path)) {
                try bundle_tar.writeBytes(archive_path, bundle_redaction.redacted_screenshot_png[0..], &out_file);
                continue;
            }
            if (bundle_redaction.isVisualArtifactPath(archive_path)) continue;
            const bytes = try readTraceFile(allocator, trace_dir, archive_path);
            defer allocator.free(bytes);
            const redacted = try bundle_redaction.redactEntry(allocator, archive_path, bytes, options);
            defer allocator.free(redacted);
            try bundle_tar.writeBytes(archive_path, redacted, &out_file);
        } else {
            try bundle_tar.writeFile(allocator, trace_dir, archive_path, &out_file);
        }
    }
    try std.Io.File.writeStreamingAll(out_file, stdio.io(), &([_]u8{0} ** 1024));
}

fn requireTraceFile(
    allocator: std.mem.Allocator,
    trace_dir: []const u8,
    archive_path: []const u8,
    missing_error: anyerror,
) !void {
    if (!try traceFileExists(allocator, trace_dir, archive_path)) return missing_error;
}

fn traceFileExists(allocator: std.mem.Allocator, trace_dir: []const u8, archive_path: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ trace_dir, archive_path });
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(stdio.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(stdio.io());
    return true;
}

fn readTraceFile(allocator: std.mem.Allocator, trace_dir: []const u8, archive_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ trace_dir, archive_path });
    defer allocator.free(path);
    return try stdio.readFileAlloc(allocator, path, 64 * 1024 * 1024);
}

fn collectArtifactEntries(
    allocator: std.mem.Allocator,
    trace_dir: []const u8,
    archive_dir: []const u8,
    entries: *std.ArrayList([]const u8),
) !void {
    const fs_dir = try std.fs.path.join(allocator, &.{ trace_dir, archive_dir });
    defer allocator.free(fs_dir);

    var dir = std.Io.Dir.cwd().openDir(stdio.io(), fs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(stdio.io());

    var iterator = dir.iterate();
    while (try iterator.next(stdio.io())) |entry| {
        const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ archive_dir, entry.name });
        errdefer allocator.free(archive_path);
        switch (entry.kind) {
            .file => try entries.append(allocator, archive_path),
            .directory => {
                try collectArtifactEntries(allocator, trace_dir, archive_path, entries);
                allocator.free(archive_path);
            },
            else => allocator.free(archive_path),
        }
    }
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
