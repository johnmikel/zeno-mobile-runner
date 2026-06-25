const std = @import("std");
const validation = @import("validation.zig");

const validateFile = validation.validateFile;
const validateSlice = validation.validateSlice;

test "validation accepts valid scenario and reports name and step count" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "valid",
        \\  "steps": [
        \\    {"action": "launch"},
        \\    {"action": "snapshot"}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("valid", result.name.?);
    try std.testing.expectEqual(@as(usize, 2), result.step_count);
}

test "validation returns public error for invalid scenario" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": "nope"
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps", result.path.?);
    try std.testing.expectEqual(@as(usize, 3), result.line.?);
    try std.testing.expectEqual(@as(usize, 3), result.column.?);
}

test "validation returns selector field diagnostics for missing selector" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "tap"}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("selector.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].selector", result.path.?);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.column == null);
}

test "validation rejects unknown fields before device execution" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "waitVisible", "selector": {"text": "Dashboard"}, "timeotMs": 1000}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[]", result.path.?);
}

test "validation rejects unknown selector fields before device execution" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "tap", "selector": {"accessibilityId": "login"}}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("selector.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].selector", result.path.?);
}

test "validation returns action field diagnostics for unknown action" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "tapp"}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].action", result.path.?);
    try std.testing.expectEqual(@as(usize, 4), result.line.?);
    try std.testing.expectEqual(@as(usize, 6), result.column.?);
}

test "validation returns direction field diagnostics for invalid scroll direction" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "scrollUntilVisible", "selector": {"text": "Dashboard"}, "direction": "sideways"}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].direction", result.path.?);
    try std.testing.expect(result.line != null);
    try std.testing.expect(result.column != null);
}

test "validation returns url field diagnostics for missing open link url" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "openLink"}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].url", result.path.?);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.column == null);
}

test "validation returns text field diagnostics for missing type text value" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "typeText", "selector": {"resourceId": "email-input"}}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].text", result.path.?);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.column == null);
}

test "validation returns x1 field diagnostics for missing swipe x1 value" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "swipe", "y1": 1, "x2": 2, "y2": 3}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].x1", result.path.?);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.column == null);
}

test "validation returns y1 field diagnostics for missing swipe y1 value" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "swipe", "x1": 1, "x2": 2, "y2": 3}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].y1", result.path.?);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.column == null);
}

test "validation returns x2 field diagnostics for missing swipe x2 value" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "swipe", "x1": 1, "y1": 2, "y2": 3}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].x2", result.path.?);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.column == null);
}

test "validation returns y2 field diagnostics for missing swipe y2 value" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\    {"action": "swipe", "x1": 1, "y1": 2, "x2": 3}
        \\  ]
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expectEqualStrings("$.steps[].y2", result.path.?);
    try std.testing.expect(result.line == null);
    try std.testing.expect(result.column == null);
}

test "validation returns line and column for malformed json" {
    const result = try validateSlice(std.testing.allocator,
        \\{
        \\  "name": "invalid",
        \\  "steps": [
        \\}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.invalid", result.error_code.?);
    try std.testing.expect(result.line != null);
    try std.testing.expect(result.column != null);
}

test "validation returns public error for missing scenario file" {
    const result = try validateFile(std.testing.allocator, "/tmp/definitely-missing-zmr-scenario.json");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("scenario.file_not_found", result.error_code.?);
}
