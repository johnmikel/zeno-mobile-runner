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

test "selector supports explicit regex and state predicates" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"textRegex":"^Sign.*in$","enabled":true,"checked":true,"focused":true,"selected":true}
    , .{});
    defer parsed.deinit();

    const wanted = try selector.parseFromJson(allocator, parsed.value);
    defer wanted.deinit(allocator);
    const node = types.UiNode{
        .stable_id = "stateful",
        .class_name = "android.widget.Button",
        .text = "Sign in",
        .enabled = true,
        .checked = true,
        .focused = true,
        .selected = true,
    };
    try std.testing.expect(selector.matches(node, wanted));
}

test "selector supports index and point targeting" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"text":"Item","index":1,"point":{"x":150,"y":25}}
    , .{});
    defer parsed.deinit();

    const wanted = try selector.parseFromJson(allocator, parsed.value);
    defer wanted.deinit(allocator);
    const nodes = [_]types.UiNode{
        .{ .stable_id = "first", .class_name = "Text", .text = "Item", .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 40 } },
        .{ .stable_id = "second", .class_name = "Text", .text = "Item", .bounds = .{ .x = 100, .y = 0, .width = 100, .height = 40 } },
    };
    const found = selector.find(nodes[0..], wanted) orelse return error.ExpectedSelectorMatch;
    try std.testing.expectEqualStrings("second", found.stable_id);
}

test "selector supports spatial and hierarchy relationships" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"text":"Child","child":{"stableId":"parent"}}
    , .{});
    defer parsed.deinit();
    const wanted = try selector.parseFromJson(allocator, parsed.value);
    defer wanted.deinit(allocator);

    const nodes = [_]types.UiNode{
        .{ .stable_id = "parent", .class_name = "Container", .bounds = .{ .x = 0, .y = 0, .width = 200, .height = 200 } },
        .{ .stable_id = "child", .class_name = "Text", .text = "Child", .parent_stable_id = "parent", .bounds = .{ .x = 20, .y = 20, .width = 100, .height = 30 } },
    };
    const found = selector.find(nodes[0..], wanted) orelse return error.ExpectedSelectorMatch;
    try std.testing.expectEqualStrings("child", found.stable_id);

    var spatial_json = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"text":"Above","above":{"stableId":"below"}}
    , .{});
    defer spatial_json.deinit();
    const spatial = try selector.parseFromJson(allocator, spatial_json.value);
    defer spatial.deinit(allocator);
    const spatial_nodes = [_]types.UiNode{
        .{ .stable_id = "above", .class_name = "Text", .text = "Above", .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 20 } },
        .{ .stable_id = "below", .class_name = "Text", .bounds = .{ .x = 0, .y = 50, .width = 100, .height = 20 } },
    };
    try std.testing.expectEqualStrings("above", (selector.find(spatial_nodes[0..], spatial) orelse return error.ExpectedSelectorMatch).stable_id);
}

test "selector descendant walk terminates on cyclic parent chains" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"text":"Trapped","descendant":{"stableId":"missing"}}
    , .{});
    defer parsed.deinit();
    const wanted = try selector.parseFromJson(allocator, parsed.value);
    defer wanted.deinit(allocator);

    // A malformed snapshot can carry a parent-id cycle; the ancestor walk must
    // fail the match instead of spinning forever.
    const nodes = [_]types.UiNode{
        .{ .stable_id = "a", .class_name = "Text", .text = "Trapped", .parent_stable_id = "b", .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        .{ .stable_id = "b", .class_name = "Container", .parent_stable_id = "a", .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    try std.testing.expect(selector.find(nodes[0..], wanted) == null);
}
