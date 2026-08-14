const std = @import("std");
const test_io = @import("test_io.zig");
const ios_shim = @import("ios_shim.zig");
const selector = @import("selector.zig");

test "ios shim command json is stable" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ios_shim.writeCommandJson(&out.writer, .{
        .kind = .tap,
        .selector = "text=Continue",
        .x = 20,
        .y = 40,
    });
    try std.testing.expectEqualStrings("{\"cmd\":\"tap\",\"selector\":\"text=Continue\",\"x\":20,\"y\":40}\n", out.written());
}

test "ios shim device state commands serialize stable names" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ios_shim.writeCommandJson(&out.writer, .{ .kind = .set_orientation, .text = "landscape" });
    try std.testing.expectEqualStrings("{\"cmd\":\"setOrientation\",\"text\":\"landscape\"}\n", out.written());
}

test "ios shim accept system alert command json is stable" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ios_shim.writeCommandJson(&out.writer, .{
        .kind = .accept_system_alert,
        .text = "Open",
        .url = "exampleapp:///probe",
        .expo_dev_client_fallback = true,
    });
    try std.testing.expectEqualStrings("{\"cmd\":\"acceptSystemAlert\",\"text\":\"Open\",\"url\":\"exampleapp:///probe\",\"expoDevClientFallback\":true}\n", out.written());
}

test "ios shim screenshot command and response are stable" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ios_shim.writeCommandJson(&out.writer, .{ .kind = .screenshot });
    try std.testing.expectEqualStrings("{\"cmd\":\"screenshot\"}\n", out.written());

    const png = try ios_shim.parseScreenshotPng(allocator,
        \\{"status":"ok","format":"png","base64":"iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"}
    );
    defer allocator.free(png);
    try std.testing.expectEqual(@as(usize, 24), png.len);
    try std.testing.expect(std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n"));
}

test "ios shim viewport command and response are stable" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ios_shim.writeCommandJson(&out.writer, .{ .kind = .viewport });
    try std.testing.expectEqualStrings("{\"cmd\":\"viewport\"}\n", out.written());

    const viewport = try ios_shim.parseViewportResponse(
        \\{"status":"ok","viewport":{"width":390,"height":844}}
    );
    try std.testing.expectEqual(@as(u32, 390), viewport.width);
    try std.testing.expectEqual(@as(u32, 844), viewport.height);
    try std.testing.expectError(error.IosShimMissingViewport, ios_shim.parseViewportResponse("{\"status\":\"ok\"}"));
    try std.testing.expectError(error.IosShimInvalidViewport, ios_shim.parseViewportResponse(
        \\{"status":"ok","viewport":{"width":0,"height":844}}
    ));
}

test "ios shim selector strings map public selectors to XCTest fields" {
    const allocator = std.testing.allocator;

    const text_selector = try ios_shim.selectorString(allocator, .{ .text = "Continue" });
    defer if (text_selector) |value| allocator.free(value);
    try std.testing.expectEqualStrings("text=Continue", text_selector.?);

    const resource_selector = try ios_shim.selectorString(allocator, .{ .id = "email" });
    defer if (resource_selector) |value| allocator.free(value);
    try std.testing.expectEqualStrings("resourceId=email", resource_selector.?);

    const stable_selector = try ios_shim.selectorString(allocator, .{ .stable_id = "node-42" });
    try std.testing.expect(stable_selector == null);

    const desc_selector = try ios_shim.selectorString(allocator, .{ .content_desc_contains = "Log" });
    defer if (desc_selector) |value| allocator.free(value);
    try std.testing.expectEqualStrings("identifierContains=Log", desc_selector.?);

    const class_selector = try ios_shim.selectorString(allocator, .{ .class_name = "XCUIElementTypeButton" });
    defer if (class_selector) |value| allocator.free(value);
    try std.testing.expectEqualStrings("type=XCUIElementTypeButton", class_selector.?);

    const compound_selector = try ios_shim.selectorString(allocator, selector.Selector{ .text = "Continue", .id = "continue_button" });
    try std.testing.expect(compound_selector == null);
}

// The shim query string can express exactly one identity attribute. Everything
// else a selector can carry — an index, a state requirement, a bounded regex, a
// relational anchor — has no place in that string, and the shim has no way to
// report that it ignored one. A selector narrowed by any of them must therefore
// be declined here so the caller falls back to the snapshot path, which
// evaluates the whole selector. Answering with a partial match instead makes the
// runner act on the wrong element and report success.
test "ios shim declines selectors it can only partially express" {
    const allocator = std.testing.allocator;

    var anchor = selector.Selector{ .text = "Basket" };

    const narrowed = [_]selector.Selector{
        .{ .text = "Save", .index = 3 },
        .{ .id = "submit", .enabled = true },
        .{ .id = "submit", .checked = true },
        .{ .id = "submit", .focused = true },
        .{ .id = "submit", .selected = true },
        .{ .text = "Save", .stable_id = "node-42" },
        .{ .class_name = "XCUIElementTypeButton", .text_regex = "^Save$" },
        .{ .class_name = "XCUIElementTypeButton", .content_desc_regex = "^Save$" },
        .{ .text = "Save", .point = .{ .x = 10, .y = 20 } },
        .{ .text = "Save", .above = &anchor },
        .{ .text = "Save", .below = &anchor },
        .{ .text = "Save", .left = &anchor },
        .{ .text = "Save", .right = &anchor },
        .{ .text = "Save", .child = &anchor },
        .{ .text = "Save", .descendant = &anchor },
    };

    for (narrowed, 0..) |wanted, index| {
        const produced = try ios_shim.selectorString(allocator, wanted);
        if (produced) |value| {
            defer allocator.free(value);
            std.debug.print(
                "selector {d} was narrowed but the shim answered '{s}', dropping the constraint\n",
                .{ index, value },
            );
            return error.PartiallyExpressedSelectorAccepted;
        }
    }

    // A lone identity attribute is still expressible, so the fast path survives.
    const plain = try ios_shim.selectorString(allocator, .{ .text = "Save" });
    defer if (plain) |value| allocator.free(value);
    try std.testing.expectEqualStrings("text=Save", plain.?);
}

test "ios shim snapshot response maps xctest elements into ui nodes" {
    const content =
        \\{
        \\  "status": "ok",
        \\  "nodes": [
        \\    {
        \\      "id": "button-continue",
        \\      "type": "XCUIElementTypeButton",
        \\      "label": "Continue",
        \\      "value": "",
        \\      "identifier": "continue_button",
        \\      "bounds": { "x": 10, "y": 20, "width": 100, "height": 44 },
        \\      "enabled": true,
        \\      "visible": true,
        \\      "selected": false
        \\    },
        \\    {
        \\      "id": "field-email",
        \\      "type": "XCUIElementTypeTextField",
        \\      "label": "",
        \\      "value": "agent@example.com",
        \\      "identifier": "email_field",
        \\      "bounds": { "x": 10, "y": 80, "width": 100, "height": 44 },
        \\      "enabled": true,
        \\      "visible": true,
        \\      "selected": false
        \\    }
        \\  ]
        \\}
    ;

    const nodes = try ios_shim.parseSnapshotNodes(std.testing.allocator, content);
    defer {
        for (nodes) |*node| node.deinit(std.testing.allocator);
        std.testing.allocator.free(nodes);
    }

    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("button-continue", nodes[0].stable_id);
    try std.testing.expectEqualStrings("XCUIElementTypeButton", nodes[0].class_name);
    try std.testing.expectEqualStrings("Continue", nodes[0].text.?);
    try std.testing.expectEqualStrings("continue_button", nodes[0].content_desc.?);
    try std.testing.expectEqual(@as(i32, 10), nodes[0].bounds.x);
    try std.testing.expect(nodes[0].enabled);
    try std.testing.expect(nodes[0].visible);
    try std.testing.expectEqualStrings("agent@example.com", nodes[1].text.?);
    try std.testing.expectEqualStrings("email_field", nodes[1].resource_id.?);
}

test "ios shim preserves checked and focused state" {
    const content =
        \\{"status":"ok","nodes":[{"id":"toggle","type":"XCUIElementTypeSwitch","bounds":{"x":0,"y":0,"width":50,"height":30},"checked":true,"focused":true}]}
    ;
    const nodes = try ios_shim.parseSnapshotNodes(std.testing.allocator, content);
    defer {
        for (nodes) |*node| node.deinit(std.testing.allocator);
        std.testing.allocator.free(nodes);
    }
    try std.testing.expect(nodes[0].checked);
    try std.testing.expect(nodes[0].focused);
}

test "ios shim rejects malformed snapshot responses" {
    try std.testing.expectError(error.IosShimMissingStatus, ios_shim.parseSnapshotNodes(std.testing.allocator, "{}"));
    try std.testing.expectError(error.IosShimResponseNotOk, ios_shim.parseSnapshotNodes(std.testing.allocator,
        \\{"status":"error","message":"no app"}
    ));
}

test "ios shim parses action ok and error responses" {
    try ios_shim.parseOkResponse("{\"status\":\"ok\"}\n");
    try std.testing.expectError(error.IosShimResponseNotOk, ios_shim.parseOkResponse("{\"status\":\"error\",\"message\":\"miss\"}\n"));
    try std.testing.expectError(error.IosShimMissingStatus, ios_shim.parseOkResponse("{}"));
}

test "ios shim parses query responses" {
    try std.testing.expect(try ios_shim.parseQueryResponse("{\"status\":\"ok\",\"exists\":true}\n"));
    try std.testing.expect(!try ios_shim.parseQueryResponse("{\"status\":\"ok\",\"exists\":false}\n"));
    try std.testing.expectError(error.IosShimMissingExists, ios_shim.parseQueryResponse("{\"status\":\"ok\"}\n"));
    try std.testing.expectError(error.IosShimExistsMustBeBool, ios_shim.parseQueryResponse("{\"status\":\"ok\",\"exists\":\"yes\"}\n"));
}

test "ios shim parses app state responses into running status" {
    try std.testing.expect(try ios_shim.parseAppStateRunning("{\"status\":\"ok\",\"state\":4}\n"));
    try std.testing.expect(try ios_shim.parseAppStateRunning("{\"status\":\"ok\",\"state\":\"runningForeground\"}\n"));
    try std.testing.expect(try ios_shim.parseAppStateRunning("{\"status\":\"ok\",\"state\":\"runningBackground\"}\n"));
    try std.testing.expect(!try ios_shim.parseAppStateRunning("{\"status\":\"ok\",\"state\":1}\n"));
    try std.testing.expect(!try ios_shim.parseAppStateRunning("{\"status\":\"ok\",\"state\":\"notRunning\"}\n"));
    try std.testing.expectError(error.IosShimMissingState, ios_shim.parseAppStateRunning("{\"status\":\"ok\"}\n"));
    try std.testing.expectError(error.IosShimStateMustBeIntegerOrString, ios_shim.parseAppStateRunning("{\"status\":\"ok\",\"state\":true}\n"));
}
