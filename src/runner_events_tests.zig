const std = @import("std");
const test_io = @import("test_io.zig");
const runner_events = @import("runner_events.zig");
const selector = @import("selector.zig");
const types = @import("types.zig");

test "selector diagnostics include nearest visible text matches" {
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
    try runner_events.writeSelectorDiagnosticJson(&json.writer, "not_found", null, selectors[0..], snap);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("nearestTextMatches").?.array.items.len);
}
