const std = @import("std");
const test_io = @import("test_io.zig");
const semantic = @import("semantic.zig");
const types = @import("types.zig");

test "semantic roles and actions are derived from mobile UI classes" {
    const button = types.UiNode{
        .stable_id = "node-1",
        .class_name = "android.widget.Button",
        .text = "Continue",
        .bounds = .{ .x = 10, .y = 20, .width = 120, .height = 48 },
    };
    const input = types.UiNode{
        .stable_id = "node-2",
        .class_name = "android.widget.EditText",
        .resource_id = "email",
        .bounds = .{ .x = 10, .y = 90, .width = 240, .height = 48 },
    };

    try std.testing.expectEqualStrings("button", semantic.roleForNode(button));
    try std.testing.expectEqualStrings("tap", semantic.recommendedAction(button).?);
    try std.testing.expectEqualStrings("textbox", semantic.roleForNode(input));
    try std.testing.expectEqualStrings("type", semantic.recommendedAction(input).?);
    try std.testing.expectEqualStrings("Continue", semantic.accessibleName(button));
    try std.testing.expectEqualStrings("email", semantic.accessibleName(input));
}

test "semantic snapshot json exposes agent-optimized nodes and summary" {
    var nodes = [_]types.UiNode{
        .{
            .stable_id = "node-text",
            .class_name = "android.widget.TextView",
            .text = "Sample landing.",
            .bounds = .{ .x = 80, .y = 100, .width = 560, .height = 60 },
        },
        .{
            .stable_id = "node-button",
            .class_name = "android.widget.Button",
            .resource_id = "email-login-submit-button",
            .text = "Sign in",
            .bounds = .{ .x = 80, .y = 470, .width = 560, .height = 70 },
        },
    };
    const snapshot = types.ObservationSnapshot{
        .id = "snapshot-1",
        .timestamp_ms = 1234,
        .viewport = .{ .width = 720, .height = 1280 },
        .active_package = "com.example.mobiletest",
        .active_activity = ".MainActivity",
        .nodes = nodes[0..],
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try semantic.writeSemanticSnapshotJson(&output.writer, snapshot);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"id\":\"snapshot-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"role\":\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"recommendedAction\":\"tap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"interactiveCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"visibleText\":[\"Sample landing.\",\"Sign in\"]") != null);
}
