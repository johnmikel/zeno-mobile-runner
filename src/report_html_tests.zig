const std = @import("std");
const test_io = @import("test_io.zig");
const report_html = @import("report_html.zig");

test "report html helpers escape text and frame a valid document" {
    var body = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer body.deinit();
    try report_html.writeStart(&body.writer, "A <B> \"C\"");
    try report_html.escape(&body.writer, "Tom & <button> \"Run\"");
    try report_html.writeEnd(&body.writer);

    try std.testing.expect(std.mem.indexOf(u8, body.written(), "<!doctype html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body.written(), "A &lt;B&gt; &quot;C&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, body.written(), "Tom &amp; &lt;button&gt; &quot;Run&quot;") != null);
    try std.testing.expect(std.mem.endsWith(u8, body.written(), "</body></html>\n"));
}
