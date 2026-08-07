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

// A snapshot is the single largest payload an agent reads, and it reads one per
// step. Every byte of it competes with the agent's actual reasoning for context,
// so attributes at their default value are noise: emitting "enabled":true on a
// node that is enabled says nothing the legend does not already say.
fn compactFixtureNodes() []types.UiNode {
    const nodes = struct {
        const list = [_]types.UiNode{
            .{ .stable_id = "n1", .class_name = "android.widget.TextView", .text = "Welcome back", .bounds = .{ .x = 0, .y = 0, .width = 300, .height = 40 } },
            .{ .stable_id = "n2", .class_name = "android.widget.EditText", .resource_id = "com.app:id/email", .bounds = .{ .x = 0, .y = 50, .width = 300, .height = 44 } },
            .{ .stable_id = "n3", .class_name = "android.widget.Button", .text = "Sign in", .bounds = .{ .x = 0, .y = 110, .width = 300, .height = 48 } },
            .{ .stable_id = "n4", .class_name = "android.widget.Button", .text = "Disabled", .enabled = false, .bounds = .{ .x = 0, .y = 170, .width = 300, .height = 48 } },
            // Zero-area layout artifact carrying no name: nothing an agent can act on.
            .{ .stable_id = "n5", .class_name = "android.view.ViewGroup", .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
        };
    };
    return @constCast(&nodes.list);
}

test "compact snapshot omits defaults and drops unactionable nodes" {
    const allocator = std.testing.allocator;
    const snapshot = types.ObservationSnapshot{
        .id = "snap-1",
        .timestamp_ms = 1,
        .viewport = .{ .width = 300, .height = 600 },
        .nodes = compactFixtureNodes(),
    };

    var full = std.Io.Writer.Allocating.init(allocator);
    defer full.deinit();
    try semantic.writeSemanticSnapshotJson(&full.writer, snapshot);

    var compact = std.Io.Writer.Allocating.init(allocator);
    defer compact.deinit();
    try semantic.writeCompactSnapshotJson(&compact.writer, snapshot);

    // The legend is emitted once and explains the abbreviations for the whole
    // payload, so it must be there before any abbreviation is used.
    try std.testing.expect(std.mem.indexOf(u8, compact.written(), "\"uiSchema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact.written(), "\"defaults\"") != null);

    // Defaults are omitted from the nodes; the legend still declares them, so
    // scope the check to the node array rather than the whole payload.
    const nodes_at = std.mem.indexOf(u8, compact.written(), "\"nodes\":[").?;
    const node_section = compact.written()[nodes_at..];
    try std.testing.expect(std.mem.indexOf(u8, node_section, "\"e\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, node_section, "\"e\":false") != null);

    // The zero-area unnamed container is not worth an agent's attention.
    try std.testing.expect(std.mem.indexOf(u8, compact.written(), "n5") == null);
    try std.testing.expect(std.mem.indexOf(u8, compact.written(), "n3") != null);

    const saved = full.written().len - compact.written().len;
    const percent = (saved * 100) / full.written().len;
    std.debug.print(
        "\n  semantic snapshot: {d} -> {d} bytes ({d}% smaller)\n",
        .{ full.written().len, compact.written().len, percent },
    );
    // Claim only what is measured; this floor is what the encoding must keep earning.
    try std.testing.expect(percent >= 30);
}

test "compact snapshot preserves every actionable node and its selector" {
    const allocator = std.testing.allocator;
    const snapshot = types.ObservationSnapshot{
        .id = "snap-1",
        .timestamp_ms = 1,
        .viewport = .{ .width = 300, .height = 600 },
        .nodes = compactFixtureNodes(),
    };

    var compact = std.Io.Writer.Allocating.init(allocator);
    defer compact.deinit();
    try semantic.writeCompactSnapshotJson(&compact.writer, snapshot);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, compact.written(), .{});
    defer parsed.deinit();

    const list = parsed.value.object.get("nodes").?.array;
    try std.testing.expectEqual(@as(usize, 4), list.items.len);

    // Losing a selector would make the compact form useless: the agent could see
    // an element and have no way to address it.
    for (list.items) |item| {
        try std.testing.expect(item.object.get("i") != null);
        try std.testing.expect(item.object.get("s") != null);
    }
}
