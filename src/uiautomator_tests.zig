const std = @import("std");
const uiautomator = @import("uiautomator.zig");

test "parse uiautomator bounds" {
    const bounds = try uiautomator.parseBounds("[12,34][56,78]");
    try std.testing.expectEqual(@as(i32, 12), bounds.x);
    try std.testing.expectEqual(@as(i32, 34), bounds.y);
    try std.testing.expectEqual(@as(i32, 44), bounds.width);
    try std.testing.expectEqual(@as(i32, 44), bounds.height);
}

test "parse hierarchy nodes and unescape attrs" {
    const xml =
        \\<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        \\<hierarchy rotation="0">
        \\  <node index="0" text="E2E &amp; auth" resource-id="probe" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[10,20][110,60]" />
        \\</hierarchy>
    ;
    const nodes = try uiautomator.parseHierarchy(std.testing.allocator, xml);
    defer {
        for (nodes) |node| node.deinit(std.testing.allocator);
        std.testing.allocator.free(nodes);
    }
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqualStrings("probe", nodes[0].resource_id.?);
    try std.testing.expectEqualStrings("E2E & auth", nodes[0].text.?);
    try std.testing.expectEqual(@as(i32, 100), nodes[0].bounds.width);
}

test "parse hierarchy handles desc ids selection invisibility and fallback ids" {
    const xml =
        \\<hierarchy>
        \\  <node index="0" text="" resource-id="" class="android.widget.ImageButton" content-desc="A &lt;quoted&gt; &quot;menu&quot; &apos;button&apos;" enabled="false" selected="true" bounds="[0,0][48,48]" />
        \\  <node index="1" text="Hidden" class="android.widget.TextView" enabled="true" selected="false" bounds="[4,4][4,20]" />
        \\  <node index="2" class="android.view.View" bounds="[5,6][7,8]" />
        \\</hierarchy>
    ;
    const nodes = try uiautomator.parseHierarchy(std.testing.allocator, xml);
    defer {
        for (nodes) |node| node.deinit(std.testing.allocator);
        std.testing.allocator.free(nodes);
    }

    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expect(nodes[0].text == null);
    try std.testing.expectEqualStrings("A <quoted> \"menu\" 'button'", nodes[0].content_desc.?);
    try std.testing.expectEqualStrings("desc:A <quoted> \"menu\" 'button':0", nodes[0].stable_id);
    try std.testing.expect(!nodes[0].enabled);
    try std.testing.expect(nodes[0].selected);
    try std.testing.expect(!nodes[1].visible);
    try std.testing.expect(std.mem.startsWith(u8, nodes[2].stable_id, "node:android.view.View:5:6:2:2:2"));
}

test "parse hierarchy preserves checked and focused state" {
    const xml =
        \\<hierarchy>
        \\  <node index="0" text="Ready" class="android.widget.CheckBox" enabled="true" checked="true" focused="true" selected="false" bounds="[0,0][80,40]" />
        \\</hierarchy>
    ;
    const nodes = try uiautomator.parseHierarchy(std.testing.allocator, xml);
    defer {
        for (nodes) |node| node.deinit(std.testing.allocator);
        std.testing.allocator.free(nodes);
    }
    try std.testing.expect(nodes[0].checked);
    try std.testing.expect(nodes[0].focused);
}

test "parse bounds rejects malformed input and clamps negative size" {
    try std.testing.expectError(error.MalformedBounds, uiautomator.parseBounds("bad"));
    const bounds = try uiautomator.parseBounds("[10,20][5,15]");
    try std.testing.expectEqual(@as(i32, 0), bounds.width);
    try std.testing.expectEqual(@as(i32, 0), bounds.height);
}

test "hierarchy parsing records parent links so depth is real" {
    // Without parent links every node is depth 0, which silently disables
    // deepest-match targeting and makes child/descendant selectors match
    // nothing — on real devices, while the fake device looked correct.
    const allocator = std.testing.allocator;
    const xml =
        \\<?xml version='1.0' encoding='UTF-8'?>
        \\<hierarchy rotation="0">
        \\<node class="android.widget.ScrollView" text="Sign in" bounds="[0,0][400,800]">
        \\<node class="android.view.ViewGroup" text="Sign in" bounds="[0,300][400,360]">
        \\<node class="android.widget.TextView" text="Sign in" bounds="[150,315][250,345]"/>
        \\</node>
        \\<node class="android.widget.TextView" text="Sibling" bounds="[0,400][400,430]"/>
        \\</node>
        \\</hierarchy>
    ;
    const nodes = try uiautomator.parseHierarchy(allocator, xml);
    defer {
        for (nodes) |node| node.deinit(allocator);
        allocator.free(nodes);
    }

    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expect(nodes[0].parent_stable_id == null);
    try std.testing.expectEqualStrings(nodes[0].stable_id, nodes[1].parent_stable_id.?);
    try std.testing.expectEqualStrings(nodes[1].stable_id, nodes[2].parent_stable_id.?);
    // The sibling closes back out to the ScrollView, not the ViewGroup.
    try std.testing.expectEqualStrings(nodes[0].stable_id, nodes[3].parent_stable_id.?);

    const selector = @import("selector.zig");
    try std.testing.expectEqual(@as(usize, 0), selector.depthOf(nodes, 0));
    try std.testing.expectEqual(@as(usize, 1), selector.depthOf(nodes, 1));
    try std.testing.expectEqual(@as(usize, 2), selector.depthOf(nodes, 2));

    // The whole point: a tap on "Sign in" reaches the label, not the scroll
    // container whose centre is 70 points away.
    const found = selector.find(nodes, .{ .text = "Sign in" }) orelse return error.ExpectedMatch;
    try std.testing.expectEqual(@as(i32, 330), found.bounds.centerY());
}
