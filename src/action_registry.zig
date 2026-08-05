const std = @import("std");
const trace = @import("trace.zig");

pub const Platform = enum {
    android,
    ios,
};

pub const AliasKind = enum {
    json,
    yaml,
    rpc,
    mcp,
};

pub const Mutability = enum {
    read_only,
    mutating,
    lifecycle,
    control,
};

pub const RiskClass = enum {
    low,
    medium,
    high,
};

pub const ActionSpec = struct {
    id: []const u8,
    json_aliases: []const []const u8,
    yaml_aliases: []const []const u8,
    rpc_aliases: []const []const u8,
    mcp_aliases: []const []const u8,
    parameter_schema: []const u8,
    platforms: []const Platform,
    required_capability: []const u8,
    mutability: Mutability,
    risk_class: RiskClass,
    trace_event: []const u8,
    version: []const u8,
    deprecated: bool = false,
    replacement: ?[]const u8 = null,
};

pub const UnsupportedDiagnostic = struct {
    command: []const u8,
    reason: []const u8,
    replacement: ?[]const u8 = null,
};

const both_platforms = [_]Platform{ .android, .ios };
const android_only = [_]Platform{.android};
const ios_only = [_]Platform{.ios};
const no_aliases = [_][]const u8{};

const json_launch = [_][]const u8{"launch"};
const yaml_launch = [_][]const u8{"launchApp"};
const rpc_launch = [_][]const u8{"app.launch"};
const mcp_launch = [_][]const u8{"launch_app"};

const json_stop = [_][]const u8{"stop"};
const yaml_stop = [_][]const u8{"stopApp"};
const rpc_stop = [_][]const u8{"app.stop"};
const mcp_stop = [_][]const u8{"stop_app"};

const json_kill = [_][]const u8{"killApp"};
const yaml_kill = [_][]const u8{"killApp"};
const rpc_kill = [_][]const u8{"app.kill"};
const mcp_kill = [_][]const u8{"kill_app"};

const json_clear_state = [_][]const u8{"clearState"};
const yaml_clear_state = [_][]const u8{"clearState", "clearAppState"};
const rpc_clear_state = [_][]const u8{"app.clearState"};
const mcp_clear_state = [_][]const u8{"clear_state"};

const json_clear_keychain = [_][]const u8{"clearKeychain"};
const yaml_clear_keychain = [_][]const u8{"clearKeychain"};
const rpc_clear_keychain = [_][]const u8{"app.clearKeychain"};
const mcp_clear_keychain = [_][]const u8{"clear_keychain"};

const json_open_link = [_][]const u8{"openLink"};
const yaml_open_link = [_][]const u8{"openLink"};
const rpc_open_link = [_][]const u8{"app.openLink"};
const mcp_open_link = [_][]const u8{"open_link"};

const json_permissions = [_][]const u8{"grantPermissions"};
const yaml_permissions = [_][]const u8{"grantPermissions"};
const rpc_permissions = [_][]const u8{"device.grantPermissions"};
const mcp_permissions = [_][]const u8{"grant_permissions"};

const json_orientation = [_][]const u8{"setOrientation"};
const yaml_orientation = [_][]const u8{"setOrientation"};
const rpc_orientation = [_][]const u8{"device.setOrientation"};
const mcp_orientation = [_][]const u8{"set_orientation"};

const json_clipboard = [_][]const u8{"setClipboard", "copyText"};
const yaml_clipboard = [_][]const u8{"setClipboard", "copyText"};
const rpc_clipboard = [_][]const u8{"device.setClipboard"};
const mcp_clipboard = [_][]const u8{"set_clipboard"};

const json_snapshot = [_][]const u8{"snapshot"};
const yaml_snapshot = [_][]const u8{"takeScreenshot"};
const rpc_snapshot = [_][]const u8{"observe.snapshot"};
const mcp_snapshot = [_][]const u8{"snapshot"};

const json_tap = [_][]const u8{"tap"};
const yaml_tap = [_][]const u8{"tapOn"};
const rpc_tap = [_][]const u8{"ui.tap"};
const mcp_tap = [_][]const u8{"tap"};

const json_long_press = [_][]const u8{"longPress"};
const yaml_long_press = [_][]const u8{"longPressOn"};
const rpc_long_press = [_][]const u8{"ui.longPress"};
const mcp_long_press = [_][]const u8{"long_press"};

const json_double_tap = [_][]const u8{"doubleTap"};
const yaml_double_tap = [_][]const u8{"doubleTapOn"};
const rpc_double_tap = [_][]const u8{"ui.doubleTap"};
const mcp_double_tap = [_][]const u8{"double_tap"};

const json_type = [_][]const u8{"typeText"};
const yaml_type = [_][]const u8{"inputText"};
const rpc_type = [_][]const u8{"ui.type"};
const mcp_type = [_][]const u8{"type"};

const json_erase = [_][]const u8{"eraseText"};
const yaml_erase = [_][]const u8{"eraseText"};
const rpc_erase = [_][]const u8{"ui.eraseText"};
const mcp_erase = [_][]const u8{"erase_text"};

const json_back = [_][]const u8{"pressBack"};
const yaml_back = [_][]const u8{"back", "pressBack"};
const rpc_back = [_][]const u8{"ui.pressBack"};
const mcp_back = [_][]const u8{"press_back"};

const json_press_key = [_][]const u8{"pressKey"};
const yaml_press_key = [_][]const u8{"pressKey"};
const rpc_press_key = [_][]const u8{"ui.pressKey"};
const mcp_press_key = [_][]const u8{"press_key"};

const json_hide_keyboard = [_][]const u8{"hideKeyboard"};
const yaml_hide_keyboard = [_][]const u8{"hideKeyboard"};
const rpc_hide_keyboard = [_][]const u8{"ui.hideKeyboard"};
const mcp_hide_keyboard = [_][]const u8{"hide_keyboard"};

const json_swipe = [_][]const u8{"swipe"};
const yaml_swipe = [_][]const u8{"swipe"};
const rpc_swipe = [_][]const u8{"ui.swipe"};
const mcp_swipe = [_][]const u8{"swipe"};

const json_wait_visible = [_][]const u8{"waitVisible"};
const yaml_wait_visible = [_][]const u8{"waitUntilVisible"};
const rpc_wait_visible = [_][]const u8{"wait.until"};
const mcp_wait_visible = [_][]const u8{"wait_until_visible"};

const json_wait_not_visible = [_][]const u8{"waitNotVisible"};
const yaml_wait_not_visible = [_][]const u8{"waitUntilNotVisible"};
const rpc_wait_not_visible = [_][]const u8{"wait.gone"};
const mcp_wait_not_visible = [_][]const u8{"wait_until_not_visible"};

const json_wait_any = [_][]const u8{"waitAny"};
const yaml_wait_any = [_][]const u8{};
const rpc_wait_any = [_][]const u8{"wait.any"};
const mcp_wait_any = [_][]const u8{"wait_any"};

const json_assert_visible = [_][]const u8{"assertVisible"};
const yaml_assert_visible = [_][]const u8{"assertVisible"};
const rpc_assert_visible = [_][]const u8{"assert.visible"};
const mcp_assert_visible = [_][]const u8{"assert_visible"};

const json_assert_not_visible = [_][]const u8{"assertNotVisible"};
const yaml_assert_not_visible = [_][]const u8{"assertNotVisible"};
const rpc_assert_not_visible = [_][]const u8{"assert.notVisible"};
const mcp_assert_not_visible = [_][]const u8{"assert_not_visible"};

const json_assert_none_visible = [_][]const u8{"assertNoneVisible"};
const yaml_assert_none_visible = [_][]const u8{};
const rpc_assert_none_visible = [_][]const u8{"assert.noneVisible"};
const mcp_assert_none_visible = [_][]const u8{"assert_none_visible"};

const json_assert_healthy = [_][]const u8{"assertHealthy"};
const yaml_assert_healthy = [_][]const u8{};
const rpc_assert_healthy = [_][]const u8{"assert.healthy"};
const mcp_assert_healthy = [_][]const u8{"assert_healthy"};

const json_when_visible = [_][]const u8{"whenVisible"};
const yaml_when_visible = [_][]const u8{"whenVisible"};
const rpc_when_visible = [_][]const u8{"flow.whenVisible"};
const mcp_when_visible = [_][]const u8{"when_visible"};

const json_repeat = [_][]const u8{"repeat"};
const yaml_repeat = [_][]const u8{"repeat"};
const rpc_repeat = [_][]const u8{"flow.repeat"};
const mcp_repeat = [_][]const u8{"repeat"};

const json_retry = [_][]const u8{"retry"};
const yaml_retry = [_][]const u8{"retry"};
const rpc_retry = [_][]const u8{"flow.retry"};
const mcp_retry = [_][]const u8{"retry"};

const json_run_flow = [_][]const u8{"runFlow"};
const yaml_run_flow = [_][]const u8{"runFlow"};
const rpc_run_flow = [_][]const u8{"flow.runFlow"};
const mcp_run_flow = [_][]const u8{"run_flow"};

const json_scroll = [_][]const u8{"scrollUntilVisible"};
const yaml_scroll = [_][]const u8{"scrollUntilVisible"};
const rpc_scroll = [_][]const u8{"ui.scrollUntilVisible"};
const mcp_scroll = [_][]const u8{"scroll_until_visible"};

const json_sleep = [_][]const u8{"sleep"};
const yaml_sleep = [_][]const u8{"waitForAnimationToEnd"};
const rpc_sleep = [_][]const u8{"wait.sleep"};
const mcp_sleep = [_][]const u8{"sleep"};

const json_location = [_][]const u8{"setLocation"};
const yaml_location = [_][]const u8{"setLocation"};
const rpc_location = [_][]const u8{"device.setLocation"};
const mcp_location = [_][]const u8{"set_location"};

const specs = [_]ActionSpec{
    .{ .id = "app.launch", .json_aliases = json_launch[0..], .yaml_aliases = yaml_launch[0..], .rpc_aliases = rpc_launch[0..], .mcp_aliases = mcp_launch[0..], .parameter_schema = "#/definitions/launchApp", .platforms = both_platforms[0..], .required_capability = "app.lifecycle", .mutability = .lifecycle, .risk_class = .medium, .trace_event = "app.launch", .version = "0.2.0" },
    .{ .id = "app.stop", .json_aliases = json_stop[0..], .yaml_aliases = yaml_stop[0..], .rpc_aliases = rpc_stop[0..], .mcp_aliases = mcp_stop[0..], .parameter_schema = "#/definitions/stopApp", .platforms = both_platforms[0..], .required_capability = "app.lifecycle", .mutability = .lifecycle, .risk_class = .medium, .trace_event = "app.stop", .version = "0.2.0" },
    .{ .id = "app.kill", .json_aliases = json_kill[0..], .yaml_aliases = yaml_kill[0..], .rpc_aliases = rpc_kill[0..], .mcp_aliases = mcp_kill[0..], .parameter_schema = "#/definitions/killApp", .platforms = both_platforms[0..], .required_capability = "app.lifecycle", .mutability = .lifecycle, .risk_class = .high, .trace_event = "app.kill", .version = "1.0.0" },
    .{ .id = "app.clearState", .json_aliases = json_clear_state[0..], .yaml_aliases = yaml_clear_state[0..], .rpc_aliases = rpc_clear_state[0..], .mcp_aliases = mcp_clear_state[0..], .parameter_schema = "#/definitions/clearState", .platforms = both_platforms[0..], .required_capability = "app.state", .mutability = .lifecycle, .risk_class = .high, .trace_event = "app.clearState", .version = "0.2.0" },
    .{ .id = "app.clearKeychain", .json_aliases = json_clear_keychain[0..], .yaml_aliases = yaml_clear_keychain[0..], .rpc_aliases = rpc_clear_keychain[0..], .mcp_aliases = mcp_clear_keychain[0..], .parameter_schema = "#/definitions/clearKeychain", .platforms = both_platforms[0..], .required_capability = "app.keychain", .mutability = .lifecycle, .risk_class = .high, .trace_event = "app.clearKeychain", .version = "1.0.0" },
    .{ .id = "app.openLink", .json_aliases = json_open_link[0..], .yaml_aliases = yaml_open_link[0..], .rpc_aliases = rpc_open_link[0..], .mcp_aliases = mcp_open_link[0..], .parameter_schema = "#/definitions/openLink", .platforms = both_platforms[0..], .required_capability = "app.deepLink", .mutability = .mutating, .risk_class = .medium, .trace_event = "app.openLink", .version = "0.2.0" },
    .{ .id = "device.grantPermissions", .json_aliases = json_permissions[0..], .yaml_aliases = yaml_permissions[0..], .rpc_aliases = rpc_permissions[0..], .mcp_aliases = mcp_permissions[0..], .parameter_schema = "#/definitions/grantPermissions", .platforms = both_platforms[0..], .required_capability = "device.permissions", .mutability = .mutating, .risk_class = .high, .trace_event = "device.grantPermissions", .version = "1.0.0" },
    .{ .id = "device.setOrientation", .json_aliases = json_orientation[0..], .yaml_aliases = yaml_orientation[0..], .rpc_aliases = rpc_orientation[0..], .mcp_aliases = mcp_orientation[0..], .parameter_schema = "#/definitions/orientation", .platforms = both_platforms[0..], .required_capability = "device.orientation", .mutability = .mutating, .risk_class = .medium, .trace_event = "device.setOrientation", .version = "1.0.0" },
    .{ .id = "device.setClipboard", .json_aliases = json_clipboard[0..], .yaml_aliases = yaml_clipboard[0..], .rpc_aliases = rpc_clipboard[0..], .mcp_aliases = mcp_clipboard[0..], .parameter_schema = "#/definitions/clipboard", .platforms = both_platforms[0..], .required_capability = "device.clipboard", .mutability = .mutating, .risk_class = .medium, .trace_event = "device.setClipboard", .version = "1.0.0" },
    .{ .id = "observe.snapshot", .json_aliases = json_snapshot[0..], .yaml_aliases = yaml_snapshot[0..], .rpc_aliases = rpc_snapshot[0..], .mcp_aliases = mcp_snapshot[0..], .parameter_schema = "#/definitions/takeScreenshot", .platforms = both_platforms[0..], .required_capability = "observe.snapshot", .mutability = .read_only, .risk_class = .low, .trace_event = "observe.snapshot", .version = "0.2.0" },
    .{ .id = "ui.tap", .json_aliases = json_tap[0..], .yaml_aliases = yaml_tap[0..], .rpc_aliases = rpc_tap[0..], .mcp_aliases = mcp_tap[0..], .parameter_schema = "#/definitions/selectorAction", .platforms = both_platforms[0..], .required_capability = "ui.accessibility", .mutability = .mutating, .risk_class = .medium, .trace_event = "ui.tap", .version = "0.2.0" },
    .{ .id = "ui.longPress", .json_aliases = json_long_press[0..], .yaml_aliases = yaml_long_press[0..], .rpc_aliases = rpc_long_press[0..], .mcp_aliases = mcp_long_press[0..], .parameter_schema = "#/definitions/longPress", .platforms = both_platforms[0..], .required_capability = "ui.gestures", .mutability = .mutating, .risk_class = .medium, .trace_event = "ui.longPress", .version = "1.0.0" },
    .{ .id = "ui.doubleTap", .json_aliases = json_double_tap[0..], .yaml_aliases = yaml_double_tap[0..], .rpc_aliases = rpc_double_tap[0..], .mcp_aliases = mcp_double_tap[0..], .parameter_schema = "#/definitions/selectorAction", .platforms = both_platforms[0..], .required_capability = "ui.gestures", .mutability = .mutating, .risk_class = .medium, .trace_event = "ui.doubleTap", .version = "1.0.0" },
    .{ .id = "ui.type", .json_aliases = json_type[0..], .yaml_aliases = yaml_type[0..], .rpc_aliases = rpc_type[0..], .mcp_aliases = mcp_type[0..], .parameter_schema = "#/definitions/typeText", .platforms = both_platforms[0..], .required_capability = "ui.input", .mutability = .mutating, .risk_class = .high, .trace_event = "ui.type", .version = "0.2.0" },
    .{ .id = "ui.eraseText", .json_aliases = json_erase[0..], .yaml_aliases = yaml_erase[0..], .rpc_aliases = rpc_erase[0..], .mcp_aliases = mcp_erase[0..], .parameter_schema = "#/definitions/eraseText", .platforms = both_platforms[0..], .required_capability = "ui.input", .mutability = .mutating, .risk_class = .high, .trace_event = "ui.eraseText", .version = "0.2.0" },
    .{ .id = "ui.pressBack", .json_aliases = json_back[0..], .yaml_aliases = yaml_back[0..], .rpc_aliases = rpc_back[0..], .mcp_aliases = mcp_back[0..], .parameter_schema = "#/definitions/pressKey", .platforms = both_platforms[0..], .required_capability = "ui.navigation", .mutability = .mutating, .risk_class = .medium, .trace_event = "ui.pressBack", .version = "0.2.0" },
    .{ .id = "ui.pressKey", .json_aliases = json_press_key[0..], .yaml_aliases = yaml_press_key[0..], .rpc_aliases = rpc_press_key[0..], .mcp_aliases = mcp_press_key[0..], .parameter_schema = "#/definitions/pressKey", .platforms = both_platforms[0..], .required_capability = "ui.navigation", .mutability = .mutating, .risk_class = .medium, .trace_event = "ui.pressKey", .version = "1.0.0" },
    .{ .id = "ui.hideKeyboard", .json_aliases = json_hide_keyboard[0..], .yaml_aliases = yaml_hide_keyboard[0..], .rpc_aliases = rpc_hide_keyboard[0..], .mcp_aliases = mcp_hide_keyboard[0..], .parameter_schema = "#/definitions/hideKeyboard", .platforms = both_platforms[0..], .required_capability = "ui.input", .mutability = .mutating, .risk_class = .low, .trace_event = "ui.hideKeyboard", .version = "0.2.0" },
    .{ .id = "ui.swipe", .json_aliases = json_swipe[0..], .yaml_aliases = yaml_swipe[0..], .rpc_aliases = rpc_swipe[0..], .mcp_aliases = mcp_swipe[0..], .parameter_schema = "#/definitions/swipe", .platforms = both_platforms[0..], .required_capability = "ui.gestures", .mutability = .mutating, .risk_class = .medium, .trace_event = "ui.swipe", .version = "0.2.0" },
    .{ .id = "wait.visible", .json_aliases = json_wait_visible[0..], .yaml_aliases = yaml_wait_visible[0..], .rpc_aliases = rpc_wait_visible[0..], .mcp_aliases = mcp_wait_visible[0..], .parameter_schema = "#/definitions/selectorWait", .platforms = both_platforms[0..], .required_capability = "observe.accessibility", .mutability = .read_only, .risk_class = .low, .trace_event = "wait.visible", .version = "0.2.0" },
    .{ .id = "wait.notVisible", .json_aliases = json_wait_not_visible[0..], .yaml_aliases = yaml_wait_not_visible[0..], .rpc_aliases = rpc_wait_not_visible[0..], .mcp_aliases = mcp_wait_not_visible[0..], .parameter_schema = "#/definitions/selectorWait", .platforms = both_platforms[0..], .required_capability = "observe.accessibility", .mutability = .read_only, .risk_class = .low, .trace_event = "wait.notVisible", .version = "0.2.0" },
    .{ .id = "wait.any", .json_aliases = json_wait_any[0..], .yaml_aliases = yaml_wait_any[0..], .rpc_aliases = rpc_wait_any[0..], .mcp_aliases = mcp_wait_any[0..], .parameter_schema = "#/definitions/selectorArrayWait", .platforms = both_platforms[0..], .required_capability = "observe.accessibility", .mutability = .read_only, .risk_class = .low, .trace_event = "wait.any", .version = "0.2.0" },
    .{ .id = "assert.visible", .json_aliases = json_assert_visible[0..], .yaml_aliases = yaml_assert_visible[0..], .rpc_aliases = rpc_assert_visible[0..], .mcp_aliases = mcp_assert_visible[0..], .parameter_schema = "#/definitions/selectorAssertion", .platforms = both_platforms[0..], .required_capability = "observe.accessibility", .mutability = .read_only, .risk_class = .low, .trace_event = "assert.visible", .version = "0.2.0" },
    .{ .id = "assert.notVisible", .json_aliases = json_assert_not_visible[0..], .yaml_aliases = yaml_assert_not_visible[0..], .rpc_aliases = rpc_assert_not_visible[0..], .mcp_aliases = mcp_assert_not_visible[0..], .parameter_schema = "#/definitions/selectorAssertion", .platforms = both_platforms[0..], .required_capability = "observe.accessibility", .mutability = .read_only, .risk_class = .low, .trace_event = "assert.notVisible", .version = "0.2.0" },
    .{ .id = "assert.noneVisible", .json_aliases = json_assert_none_visible[0..], .yaml_aliases = yaml_assert_none_visible[0..], .rpc_aliases = rpc_assert_none_visible[0..], .mcp_aliases = mcp_assert_none_visible[0..], .parameter_schema = "#/definitions/selectorArrayAssertion", .platforms = both_platforms[0..], .required_capability = "observe.accessibility", .mutability = .read_only, .risk_class = .low, .trace_event = "assert.noneVisible", .version = "0.2.0" },
    .{ .id = "assert.healthy", .json_aliases = json_assert_healthy[0..], .yaml_aliases = yaml_assert_healthy[0..], .rpc_aliases = rpc_assert_healthy[0..], .mcp_aliases = mcp_assert_healthy[0..], .parameter_schema = "#/definitions/healthAssertion", .platforms = both_platforms[0..], .required_capability = "observe.health", .mutability = .read_only, .risk_class = .low, .trace_event = "assert.healthy", .version = "0.2.0" },
    .{ .id = "flow.whenVisible", .json_aliases = json_when_visible[0..], .yaml_aliases = yaml_when_visible[0..], .rpc_aliases = rpc_when_visible[0..], .mcp_aliases = mcp_when_visible[0..], .parameter_schema = "#/definitions/conditionalBlock", .platforms = both_platforms[0..], .required_capability = "flow.control", .mutability = .control, .risk_class = .low, .trace_event = "flow.whenVisible", .version = "0.2.0" },
    .{ .id = "flow.repeat", .json_aliases = json_repeat[0..], .yaml_aliases = yaml_repeat[0..], .rpc_aliases = rpc_repeat[0..], .mcp_aliases = mcp_repeat[0..], .parameter_schema = "#/definitions/repeatBlock", .platforms = both_platforms[0..], .required_capability = "flow.control", .mutability = .control, .risk_class = .low, .trace_event = "flow.repeat", .version = "0.2.0" },
    .{ .id = "flow.retry", .json_aliases = json_retry[0..], .yaml_aliases = yaml_retry[0..], .rpc_aliases = rpc_retry[0..], .mcp_aliases = mcp_retry[0..], .parameter_schema = "#/definitions/retryBlock", .platforms = both_platforms[0..], .required_capability = "flow.control", .mutability = .control, .risk_class = .medium, .trace_event = "flow.retry", .version = "1.0.0" },
    .{ .id = "flow.runFlow", .json_aliases = json_run_flow[0..], .yaml_aliases = yaml_run_flow[0..], .rpc_aliases = rpc_run_flow[0..], .mcp_aliases = mcp_run_flow[0..], .parameter_schema = "#/definitions/runFlow", .platforms = both_platforms[0..], .required_capability = "flow.control", .mutability = .control, .risk_class = .low, .trace_event = "flow.runFlow", .version = "1.0.0" },
    .{ .id = "ui.scrollUntilVisible", .json_aliases = json_scroll[0..], .yaml_aliases = yaml_scroll[0..], .rpc_aliases = rpc_scroll[0..], .mcp_aliases = mcp_scroll[0..], .parameter_schema = "#/definitions/scrollUntilVisible", .platforms = both_platforms[0..], .required_capability = "ui.gestures", .mutability = .mutating, .risk_class = .medium, .trace_event = "ui.scrollUntilVisible", .version = "0.2.0" },
    .{ .id = "flow.sleep", .json_aliases = json_sleep[0..], .yaml_aliases = yaml_sleep[0..], .rpc_aliases = rpc_sleep[0..], .mcp_aliases = mcp_sleep[0..], .parameter_schema = "#/definitions/sleep", .platforms = both_platforms[0..], .required_capability = "flow.control", .mutability = .control, .risk_class = .low, .trace_event = "flow.sleep", .version = "0.2.0" },
    .{ .id = "device.setLocation", .json_aliases = json_location[0..], .yaml_aliases = yaml_location[0..], .rpc_aliases = rpc_location[0..], .mcp_aliases = mcp_location[0..], .parameter_schema = "#/definitions/location", .platforms = both_platforms[0..], .required_capability = "device.location", .mutability = .mutating, .risk_class = .high, .trace_event = "device.setLocation", .version = "0.2.0" },
};

const unsupported_commands = [_]UnsupportedDiagnostic{
    .{ .command = "evalScript", .reason = "arbitrary JavaScript is intentionally outside the deterministic ZMR contract" },
    .{ .command = "runScript", .reason = "arbitrary host scripting is intentionally outside the deterministic ZMR contract" },
    .{ .command = "assertWithAI", .reason = "AI assertions are deferred until their evidence and determinism contract is defined" },
    .{ .command = "setAirplaneMode", .reason = "airplane-mode control is deferred because it is host and device-policy dependent" },
    .{ .command = "addMedia", .reason = "media injection is deferred from the Tier 1 local runner" },
    .{ .command = "openBrowser", .reason = "web and browser automation are outside the Tier 1 mobile contract" },
};

pub fn all() []const ActionSpec {
    return specs[0..];
}

pub fn find(kind: AliasKind, alias: []const u8) ?ActionSpec {
    for (specs) |spec| {
        const aliases = switch (kind) {
            .json => spec.json_aliases,
            .yaml => spec.yaml_aliases,
            .rpc => spec.rpc_aliases,
            .mcp => spec.mcp_aliases,
        };
        for (aliases) |candidate| {
            if (std.mem.eql(u8, candidate, alias)) return spec;
        }
    }
    return null;
}

pub fn unsupported(command: []const u8) ?UnsupportedDiagnostic {
    for (unsupported_commands) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.command, command)) return diagnostic;
    }
    return null;
}

pub fn writeJson(writer: anytype) !void {
    try writer.writeAll("[");
    for (specs, 0..) |spec, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":");
        try trace.writeJsonString(writer, spec.id);
        try writer.writeAll(",\"jsonAliases\":");
        try writeAliases(writer, spec.json_aliases);
        try writer.writeAll(",\"yamlAliases\":");
        try writeAliases(writer, spec.yaml_aliases);
        try writer.writeAll(",\"rpcAliases\":");
        try writeAliases(writer, spec.rpc_aliases);
        try writer.writeAll(",\"mcpAliases\":");
        try writeAliases(writer, spec.mcp_aliases);
        try writer.writeAll(",\"parameterSchema\":");
        try trace.writeJsonString(writer, spec.parameter_schema);
        try writer.writeAll(",\"platforms\":");
        try writePlatforms(writer, spec.platforms);
        try writer.writeAll(",\"requiredCapability\":");
        try trace.writeJsonString(writer, spec.required_capability);
        try writer.writeAll(",\"mutability\":");
        try trace.writeJsonString(writer, @tagName(spec.mutability));
        try writer.writeAll(",\"riskClass\":");
        try trace.writeJsonString(writer, @tagName(spec.risk_class));
        try writer.writeAll(",\"traceEvent\":");
        try trace.writeJsonString(writer, spec.trace_event);
        try writer.writeAll(",\"version\":");
        try trace.writeJsonString(writer, spec.version);
        try writer.writeAll(",\"deprecated\":");
        try writer.writeAll(if (spec.deprecated) "true" else "false");
        try writer.writeAll(",\"replacement\":");
        if (spec.replacement) |replacement| {
            try trace.writeJsonString(writer, replacement);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeAliases(writer: anytype, aliases: []const []const u8) !void {
    try writer.writeAll("[");
    for (aliases, 0..) |alias, index| {
        if (index > 0) try writer.writeAll(",");
        try trace.writeJsonString(writer, alias);
    }
    try writer.writeAll("]");
}

fn writePlatforms(writer: anytype, platforms: []const Platform) !void {
    try writer.writeAll("[");
    for (platforms, 0..) |platform, index| {
        if (index > 0) try writer.writeAll(",");
        try trace.writeJsonString(writer, @tagName(platform));
    }
    try writer.writeAll("]");
}
