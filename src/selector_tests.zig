const std = @import("std");
const selector = @import("selector.zig");
const types = @import("types.zig");

test "selector matches resource id and text" {
    const allocator = std.testing.allocator;
    const node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-1"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .resource_id = try allocator.dupe(u8, "login-button"),
        .text = try allocator.dupe(u8, "Sign in"),
    };
    defer node.deinit(allocator);

    try std.testing.expect(selector.matches(node, .{ .id = "login-button", .text = "Sign in" }));
    try std.testing.expect(!selector.matches(node, .{ .id = "other" }));
}

test "selector supports contains matching" {
    const allocator = std.testing.allocator;
    const node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "node-2"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, "E2E auth probe"),
    };
    defer node.deinit(allocator);

    try std.testing.expect(selector.matches(node, .{ .text_contains = "auth" }));
    try std.testing.expect(!selector.matches(node, .{ .text_contains = "missing" }));
}

test "selector parser accepts resourceId as an id alias" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"resourceId":"continue_button","text":"Continue"}
    , .{});
    defer parsed.deinit();

    const wanted = try selector.parseFromJson(allocator, parsed.value);
    defer wanted.deinit(allocator);

    try std.testing.expectEqualStrings("continue_button", wanted.id.?);
    try std.testing.expectEqualStrings("Continue", wanted.text.?);
}

test "selector parser accepts stableId and matches that exact node" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"stableId":"node-2"}
    , .{});
    defer parsed.deinit();

    const wanted = try selector.parseFromJson(allocator, parsed.value);
    defer wanted.deinit(allocator);

    var nodes = [_]types.UiNode{
        .{
            .stable_id = "node-1",
            .class_name = "android.widget.TextView",
            .text = "First",
        },
        .{
            .stable_id = "node-2",
            .class_name = "android.widget.TextView",
            .text = "Second",
        },
    };

    const found = selector.find(nodes[0..], wanted) orelse return error.ExpectedSelectorMatch;
    try std.testing.expectEqualStrings("node-2", found.stable_id);
}

test "selector parser rejects empty and unknown selectors" {
    const allocator = std.testing.allocator;
    var empty = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{}
    , .{});
    defer empty.deinit();
    try std.testing.expectError(error.SelectorMustNotBeEmpty, selector.parseFromJson(allocator, empty.value));

    var unknown = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"accessibilityId":"login-button"}
    , .{});
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownSelectorField, selector.parseFromJson(allocator, unknown.value));
}
