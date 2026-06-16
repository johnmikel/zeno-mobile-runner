const std = @import("std");
const stdio = @import("stdio.zig");

pub fn writeStart(writer: anytype, title: []const u8) !void {
    try writer.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>");
    try escape(writer, title);
    try writer.writeAll(
        \\</title><style>
        \\body{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:32px;color:#17202a;background:#f7f8fa}
        \\h1,h2{color:#111827}
        \\section{margin:24px 0}
        \\dl{display:grid;grid-template-columns:max-content 1fr;gap:8px 16px}
        \\dt{font-weight:700}
        \\table{border-collapse:collapse;width:100%;background:#fff}
        \\th,td{border:1px solid #d8dee6;padding:8px;text-align:left;vertical-align:top}
        \\th{background:#eef2f7}
        \\.ok{color:#116329;font-weight:700}
        \\.failed{color:#b42318;font-weight:700}
        \\.muted{color:#667085}
        \\.warning{border-left:4px solid #b54708;background:#fff7ed;padding:12px}
        \\code{white-space:pre-wrap;word-break:break-word}
        \\</style></head><body>
        \\
    );
}

pub fn writeEnd(writer: anytype) !void {
    try writer.writeAll("</body></html>\n");
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(stdio.io(), path, .{ .truncate = true });
    defer file.close(stdio.io());
    try std.Io.File.writeStreamingAll(file, stdio.io(), bytes);
}

pub fn writeArtifactLink(
    allocator: std.mem.Allocator,
    writer: anytype,
    path: []const u8,
    label: []const u8,
) !void {
    const href = std.Io.Dir.cwd().realPathFileAlloc(stdio.io(), path, allocator) catch try allocator.dupeZ(u8, path);
    defer allocator.free(href);

    try writer.writeAll("<a href=\"file://");
    try escape(writer, href);
    try writer.writeAll("\">");
    try escape(writer, label);
    try writer.writeAll("</a>");
}

pub fn escape(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(ch),
        }
    }
}
