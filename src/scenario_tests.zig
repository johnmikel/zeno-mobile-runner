const std = @import("std");
const scenario = @import("scenario.zig");

const parseSlice = scenario.parseSlice;
const ScrollDirection = scenario.ScrollDirection;
const Orientation = scenario.Orientation;
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

test "parse launchApp options and clearKeychain" {
    const json =
        \\{
        \\  "name": "launch options",
        \\  "steps": [
        \\    {"action":"launchApp","appId":"com.example.other","stopApp":false,"clearState":true,"clearKeychain":true,"arguments":{"foo":"bar","enabled":true,"count":3,"ratio":3.25}},
        \\    {"action":"clearKeychain"}
        \\  ]
        \\}
    ;
    const parsed = try parseSlice(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.meta.Tag(Step).launch_app, std.meta.activeTag(parsed.steps[0]));
    const launch = parsed.steps[0].launch_app;
    try std.testing.expectEqualStrings("com.example.other", launch.app_id.?);
    try std.testing.expect(!launch.stop_app);
    try std.testing.expect(launch.clear_state);
    try std.testing.expect(launch.clear_keychain);
    try std.testing.expectEqual(@as(usize, 4), launch.arguments.len);
    try std.testing.expectEqual(std.meta.Tag(Step).clear_keychain, std.meta.activeTag(parsed.steps[1]));
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

test "parse imported-flow gesture and lifecycle aliases" {
    const json =
        \\{
        \\  "name": "imported-flow aliases",
        \\  "steps": [
        \\    {"action":"killApp"},
        \\    {"action":"longPressOn","selector":{"text":"More"},"durationMs":1200},
        \\    {"action":"doubleTapOn","selector":{"id":"card"}},
        \\    {"action":"pressKey","key":"ENTER"}
        \\  ]
        \\}
    ;
    const parsed = try parseSlice(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.meta.Tag(Step).kill_app, std.meta.activeTag(parsed.steps[0]));
    try std.testing.expectEqual(std.meta.Tag(Step).long_press, std.meta.activeTag(parsed.steps[1]));
    try std.testing.expectEqual(@as(u32, 1200), parsed.steps[1].long_press.duration_ms);
    try std.testing.expectEqual(std.meta.Tag(Step).double_tap, std.meta.activeTag(parsed.steps[2]));
    try std.testing.expectEqual(std.meta.Tag(Step).press_key, std.meta.activeTag(parsed.steps[3]));
    try std.testing.expectEqualStrings("ENTER", parsed.steps[3].press_key);
}

test "parse device state primitives" {
    const json =
        \\{
        \\  "name": "device state",
        \\  "steps": [
        \\    {"action":"grantPermissions","permissions":["android.permission.CAMERA"]},
        \\    {"action":"setOrientation","orientation":"LANDSCAPE"},
        \\    {"action":"setClipboard","text":"token"}
        \\  ]
        \\}
    ;
    const parsed = try parseSlice(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.steps[0].grant_permissions.len);
    try std.testing.expectEqual(Orientation.landscape, parsed.steps[1].set_orientation);
    try std.testing.expectEqualStrings("token", parsed.steps[2].set_clipboard);
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

test "parse migration flow control, aliases, and hooks" {
    const json =
        \\{
        \\  "name": "migration flow",
        \\  "onStart": [{"action":"launchApp"}],
        \\  "onComplete": [{"action":"takeScreenshot"}],
        \\  "steps": [
        \\    {"action":"whenNotVisible","selector":{"textRegex":"^Ready$"},"steps":[{"action":"tapOn","selector":{"text":"Open"}}]},
        \\    {"action":"retry","attempts":2,"steps":[{"action":"inputText","text":"hello"}]},
        \\    {"action":"runFlow","steps":[{"action":"back"}]}
        \\  ]
        \\}
    ;
    const parsed = try parseSlice(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.on_start.len);
    try std.testing.expectEqual(std.meta.Tag(Step).launch, std.meta.activeTag(parsed.on_start[0]));
    try std.testing.expectEqual(@as(usize, 1), parsed.on_complete.len);
    try std.testing.expectEqual(std.meta.Tag(Step).snapshot, std.meta.activeTag(parsed.on_complete[0]));
    try std.testing.expectEqual(std.meta.Tag(Step).when_not_visible, std.meta.activeTag(parsed.steps[0]));
    try std.testing.expectEqual(std.meta.Tag(Step).retry, std.meta.activeTag(parsed.steps[1]));
    try std.testing.expectEqual(@as(u32, 2), parsed.steps[1].retry.attempts);
    try std.testing.expectEqual(std.meta.Tag(Step).run_flow, std.meta.activeTag(parsed.steps[2]));
    try std.testing.expectEqual(std.meta.Tag(Step).press_back, std.meta.activeTag(parsed.steps[2].run_flow.steps[0]));
}
