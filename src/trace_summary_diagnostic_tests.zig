const std = @import("std");
const test_io = @import("test_io.zig");
const trace_summary_diagnostic = @import("trace_summary_diagnostic.zig");

test "trace summary diagnostic parses payload and writes agent json" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"status":"timeout","snapshotId":"snapshot-1","activePackage":"com.example.mobiletest","visibleTexts":["Sign in","Dashboard"],"nearestTextMatches":[{"text":"Sign up","score":2}]}
    , .{});
    defer parsed.deinit();

    var diagnostic = try trace_summary_diagnostic.DiagnosticEvent.fromPayload(std.testing.allocator, "wait.visible", parsed.value.object);
    defer diagnostic.deinit(std.testing.allocator);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try trace_summary_diagnostic.writeJson(&out.writer, diagnostic);

    const written = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer written.deinit();
    try std.testing.expectEqualStrings("wait.visible", written.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("timeout", written.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 2), written.value.object.get("visibleTexts").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), written.value.object.get("nearestTextMatches").?.array.items.len);
}
