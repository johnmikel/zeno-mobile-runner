const std = @import("std");
const scenario = @import("scenario.zig");

const parseSlice = scenario.parseSlice;
const ScrollDirection = scenario.ScrollDirection;
const Step = scenario.Step;

test "parse scenario with open link and wait" {
    const json =
        \\{
        \\  "name": "probe",
        \\  "appId": "com.example.mobiletest",
        \\  "steps": [
        \\    {"action": "openLink", "url": "exampleapp://e2e-auth?probe=1"},
        \\    {"action": "waitVisible", "selector": {"text": "E2E auth probe"}, "timeoutMs": 30000}
        \\  ]
        \\}
    ;
    const parsed = try parseSlice(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("probe", parsed.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.steps.len);
    try std.testing.expectEqualStrings("com.example.mobiletest", parsed.app_id.?);
}

test "parse agent-grade flow primitives" {
    const json =
        \\{
        \\  "name": "flow",
        \\  "steps": [
        \\    {"action": "waitAny", "selectors": [{"text": "A"}, {"textContains": "B"}], "timeoutMs": 10},
        \\    {"action": "assertHealthy", "timeoutMs": 0},
        \\    {"action": "assertNoneVisible", "selectors": [{"textContains": "Uncaught Error"}, {"textContains": "Application has crashed"}], "timeoutMs": 0},
        \\    {"action": "whenVisible", "selector": {"text": "A"}, "steps": [
        \\      {"action": "tap", "selector": {"text": "A"}, "optional": true}
        \\    ]},
        \\    {"action": "repeat", "times": 2, "steps": [
        \\      {"action": "eraseText", "maxChars": 5},
        \\      {"action": "hideKeyboard"}
        \\    ]},
        \\    {"action": "scrollUntilVisible", "selector": {"id": "target"}, "direction": "down"}
        \\  ]
        \\}
    ;
    const parsed = try parseSlice(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), parsed.steps.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.steps[0].wait_any.selectors.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.steps[1].assert_healthy_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), parsed.steps[2].assert_none_visible.selectors.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.steps[2].assert_none_visible.timeout_ms);
    try std.testing.expectEqual(@as(u32, 2), parsed.steps[4].repeat.times);
}

test "parse all simple action variants" {
    const json =
        \\{
        \\  "name": "all actions",
        \\  "steps": [
        \\    {"action": "launch"},
        \\    {"action": "stop"},
        \\    {"action": "clearState"},
        \\    {"action": "snapshot"},
        \\    {"action": "pressBack"},
        \\    {"action": "sleep", "ms": 7},
        \\    {"action": "tap", "selector": {"id": "tap-id"}},
        \\    {"action": "typeText", "text": "hello"},
        \\    {"action": "swipe", "x1": 1, "y1": 2, "x2": 3, "y2": 4},
        \\    {"action": "waitNotVisible", "selector": {"text": "Gone"}},
        \\    {"action": "assertVisible", "selector": {"contentDesc": "Visible"}, "timeoutMs": 1234},
        \\    {"action": "assertNotVisible", "selector": {"className": "android.widget.Toast"}, "timeoutMs": 2345},
        \\    {"action": "scrollUntilVisible", "selector": {"text": "Target"}, "direction": "up"}
        \\  ]
        \\}
    ;
    const parsed = try parseSlice(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(std.meta.Tag(Step), .launch), std.meta.activeTag(parsed.steps[0]));
    try std.testing.expectEqual(@as(std.meta.Tag(Step), .stop), std.meta.activeTag(parsed.steps[1]));
    try std.testing.expectEqual(@as(std.meta.Tag(Step), .clear_state), std.meta.activeTag(parsed.steps[2]));
    try std.testing.expectEqual(@as(std.meta.Tag(Step), .snapshot), std.meta.activeTag(parsed.steps[3]));
    try std.testing.expectEqual(@as(std.meta.Tag(Step), .press_back), std.meta.activeTag(parsed.steps[4]));
    try std.testing.expectEqual(@as(u64, 7), parsed.steps[5].sleep_ms);
    try std.testing.expectEqualStrings("tap-id", parsed.steps[6].tap.id.?);
    try std.testing.expectEqualStrings("hello", parsed.steps[7].type_text.text);
    try std.testing.expectEqual(@as(u32, 300), parsed.steps[8].swipe.duration_ms);
    try std.testing.expectEqualStrings("Gone", parsed.steps[9].wait_not_visible.selector.text.?);
    try std.testing.expectEqualStrings("Visible", parsed.steps[10].assert_visible.selector.content_desc.?);
    try std.testing.expectEqual(@as(?u64, 1234), parsed.steps[10].assert_visible.timeout_ms);
    try std.testing.expectEqualStrings("android.widget.Toast", parsed.steps[11].assert_not_visible.selector.class_name.?);
    try std.testing.expectEqual(@as(?u64, 2345), parsed.steps[11].assert_not_visible.timeout_ms);
    try std.testing.expectEqual(ScrollDirection.up, parsed.steps[12].scroll_until_visible.direction);
}

test "scenario parser rejects malformed input precisely" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ScenarioMustBeObject, parseSlice(allocator, "[]"));
    try std.testing.expectError(error.UnknownScenarioField, parseSlice(allocator,
        \\{"name":"extra root","steps":[{"action":"launch"}],"extra":true}
    ));
    try std.testing.expectError(error.ScenarioMissingSteps, parseSlice(allocator,
        \\{"name":"missing steps"}
    ));
    try std.testing.expectError(error.ScenarioStepsMustBeArray, parseSlice(allocator,
        \\{"name":"bad steps","steps":{}}
    ));
    try std.testing.expectError(error.StepMissingAction, parseSlice(allocator,
        \\{"name":"bad step","steps":[{}]}
    ));
    try std.testing.expectError(error.UnknownScenarioStepField, parseSlice(allocator,
        \\{"name":"bad step field","steps":[{"action":"waitVisible","selector":{"text":"A"},"timeotMs":1000}]}
    ));
    try std.testing.expectError(error.UnknownSelectorField, parseSlice(allocator,
        \\{"name":"bad selector","steps":[{"action":"tap","selector":{"accessibilityId":"login"}}]}
    ));
    try std.testing.expectError(error.SelectorMustNotBeEmpty, parseSlice(allocator,
        \\{"name":"empty selector","steps":[{"action":"tap","selector":{}}]}
    ));
    try std.testing.expectError(error.StepActionMustBeString, parseSlice(allocator,
        \\{"name":"bad action","steps":[{"action":1}]}
    ));
    try std.testing.expectError(error.SelectorsMustNotBeEmpty, parseSlice(allocator,
        \\{"name":"empty selectors","steps":[{"action":"waitAny","selectors":[]}]}
    ));
    try std.testing.expectError(error.OptionalFieldMustBeBool, parseSlice(allocator,
        \\{"name":"bad optional","steps":[{"action":"tap","selector":{"text":"A"},"optional":"yes"}]}
    ));
    try std.testing.expectError(error.unknownScrollDirection, parseSlice(allocator,
        \\{"name":"bad direction","steps":[{"action":"scrollUntilVisible","selector":{"text":"A"},"direction":"sideways"}]}
    ));
    try std.testing.expectError(error.unknownScenarioAction, parseSlice(allocator,
        \\{"name":"unknown","steps":[{"action":"pinch"}]}
    ));
}
