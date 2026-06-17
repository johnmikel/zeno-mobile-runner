const std = @import("std");
const test_io = @import("test_io.zig");
const runner_diagnostics = @import("runner_diagnostics.zig");
const selector = @import("selector.zig");
const types = @import("types.zig");

test "runner diagnostics write selector miss details for agents" {
    const selectors = [_]selector.Selector{.{ .text = "Sign in" }};
    var nodes = [_]types.UiNode{
        .{
            .stable_id = "text:Sign up:0",
            .class_name = "android.widget.TextView",
            .text = "Sign up",
            .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
        },
    };
    const snap = types.ObservationSnapshot{
        .id = "snapshot-1",
        .timestamp_ms = 1,
        .viewport = .{ .width = 320, .height = 640 },
        .nodes = nodes[0..],
    };

    var json = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json.deinit();
    try runner_diagnostics.writeSelectorDiagnosticJson(&json.writer, "not_found", "nativeSelector", selectors[0..], snap);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("not_found", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("nativeSelector", parsed.value.object.get("strategy").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("nearestTextMatches").?.array.items.len);
}
