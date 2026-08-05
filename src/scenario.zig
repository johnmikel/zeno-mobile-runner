const std = @import("std");
const stdio = @import("stdio.zig");
const fields = @import("scenario_fields.zig");
const selector = @import("selector.zig");

pub const Swipe = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    duration_ms: u32 = 300,
};

pub const Location = struct {
    latitude: f64,
    longitude: f64,
};

pub const Orientation = enum {
    portrait,
    landscape,
};

pub const LaunchArgumentValue = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    double: f64,

    pub fn deinit(self: LaunchArgumentValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |value| allocator.free(value),
            else => {},
        }
    }
};

pub const LaunchArgument = struct {
    name: []const u8,
    value: LaunchArgumentValue,

    pub fn deinit(self: LaunchArgument, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
    }
};

pub const LaunchOptions = struct {
    app_id: ?[]const u8 = null,
    stop_app: bool = true,
    clear_state: bool = false,
    clear_keychain: bool = false,
    arguments: []LaunchArgument = &.{},

    pub fn deinit(self: LaunchOptions, allocator: std.mem.Allocator) void {
        if (self.app_id) |value| allocator.free(value);
        for (self.arguments) |argument| argument.deinit(allocator);
        if (self.arguments.len > 0) allocator.free(self.arguments);
    }
};

pub const WaitVisible = struct {
    selector: selector.Selector,
    timeout_ms: u64 = 5000,
};

pub const WaitAny = struct {
    selectors: []selector.Selector,
    timeout_ms: u64 = 5000,

    pub fn deinit(self: WaitAny, allocator: std.mem.Allocator) void {
        for (self.selectors) |wanted| wanted.deinit(allocator);
        allocator.free(self.selectors);
    }
};

pub const VisibilityAssertion = struct {
    selector: selector.Selector,
    timeout_ms: ?u64 = null,

    pub fn deinit(self: VisibilityAssertion, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
    }
};

pub const TypeText = struct {
    selector: ?selector.Selector = null,
    text: []const u8,

    pub fn deinit(self: TypeText, allocator: std.mem.Allocator) void {
        if (self.selector) |wanted| wanted.deinit(allocator);
        allocator.free(self.text);
    }
};

pub const EraseText = struct {
    selector: ?selector.Selector = null,
    max_chars: u32 = 80,

    pub fn deinit(self: EraseText, allocator: std.mem.Allocator) void {
        if (self.selector) |wanted| wanted.deinit(allocator);
    }
};

pub const LongPress = struct {
    selector: selector.Selector,
    duration_ms: u32 = 800,

    pub fn deinit(self: LongPress, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
    }
};

pub const StepBlock = struct {
    steps: []Step,

    pub fn deinit(self: StepBlock, allocator: std.mem.Allocator) void {
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

pub const RetryBlock = struct {
    attempts: u32,
    steps: []Step,

    pub fn deinit(self: RetryBlock, allocator: std.mem.Allocator) void {
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

pub const ConditionalBlock = struct {
    selector: selector.Selector,
    timeout_ms: u64 = 0,
    steps: []Step,

    pub fn deinit(self: ConditionalBlock, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

pub const RepeatBlock = struct {
    times: u32,
    steps: []Step,

    pub fn deinit(self: RepeatBlock, allocator: std.mem.Allocator) void {
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

pub const ScrollDirection = enum {
    down,
    up,
};

pub const ScrollUntilVisible = struct {
    selector: selector.Selector,
    timeout_ms: u64 = 5000,
    direction: ScrollDirection = .down,

    pub fn deinit(self: ScrollUntilVisible, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
    }
};

pub const Step = union(enum) {
    launch,
    launch_app: LaunchOptions,
    stop,
    kill_app,
    clear_state,
    clear_keychain,
    snapshot,
    open_link: []const u8,
    set_location: Location,
    grant_permissions: [][]const u8,
    set_orientation: Orientation,
    set_clipboard: []const u8,
    tap: selector.Selector,
    long_press: LongPress,
    double_tap: selector.Selector,
    press_key: []const u8,
    type_text: TypeText,
    press_back,
    hide_keyboard,
    swipe: Swipe,
    erase_text: EraseText,
    wait_visible: WaitVisible,
    wait_not_visible: WaitVisible,
    wait_any: WaitAny,
    assert_visible: VisibilityAssertion,
    assert_not_visible: VisibilityAssertion,
    assert_none_visible: WaitAny,
    assert_healthy_timeout_ms: u64,
    optional: *Step,
    when_visible: ConditionalBlock,
    when_not_visible: ConditionalBlock,
    repeat: RepeatBlock,
    retry: RetryBlock,
    run_flow: StepBlock,
    scroll_until_visible: ScrollUntilVisible,
    sleep_ms: u64,

    pub fn deinit(self: Step, allocator: std.mem.Allocator) void {
        switch (self) {
            .launch_app => |value| value.deinit(allocator),
            .open_link => |value| allocator.free(value),
            .grant_permissions => |values| {
                for (values) |value| allocator.free(value);
                allocator.free(values);
            },
            .set_clipboard => |value| allocator.free(value),
            .tap => |value| value.deinit(allocator),
            .long_press => |value| value.deinit(allocator),
            .double_tap => |value| value.deinit(allocator),
            .press_key => |value| allocator.free(value),
            .type_text => |value| value.deinit(allocator),
            .erase_text => |value| value.deinit(allocator),
            .wait_visible => |value| value.selector.deinit(allocator),
            .wait_not_visible => |value| value.selector.deinit(allocator),
            .wait_any => |value| value.deinit(allocator),
            .assert_visible => |value| value.deinit(allocator),
            .assert_not_visible => |value| value.deinit(allocator),
            .assert_none_visible => |value| value.deinit(allocator),
            .optional => |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            },
            .when_visible => |value| value.deinit(allocator),
            .when_not_visible => |value| value.deinit(allocator),
            .repeat => |value| value.deinit(allocator),
            .retry => |value| value.deinit(allocator),
            .run_flow => |value| value.deinit(allocator),
            .scroll_until_visible => |value| value.deinit(allocator),
            else => {},
        }
    }
};

pub const Binding = struct {
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: Binding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,

    pub fn deinit(self: SourceLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
    }
};

pub const Scenario = struct {
    name: []const u8,
    app_id: ?[]const u8 = null,
    env: []Binding = &.{},
    constants: []Binding = &.{},
    labels: [][]const u8 = &.{},
    source: ?SourceLocation = null,
    on_start: []Step = &.{},
    on_complete: []Step = &.{},
    steps: []Step,

    pub fn deinit(self: Scenario, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.app_id) |value| allocator.free(value);
        for (self.env) |binding| binding.deinit(allocator);
        allocator.free(self.env);
        for (self.constants) |binding| binding.deinit(allocator);
        allocator.free(self.constants);
        for (self.labels) |label| allocator.free(label);
        allocator.free(self.labels);
        if (self.source) |location| location.deinit(allocator);
        for (self.on_start) |step| step.deinit(allocator);
        allocator.free(self.on_start);
        for (self.on_complete) |step| step.deinit(allocator);
        allocator.free(self.on_complete);
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Scenario {
    const content = try stdio.readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(content);
    return try parseSlice(allocator, content);
}

pub fn parseSlice(allocator: std.mem.Allocator, content: []const u8) !Scenario {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ScenarioMustBeObject;
    const root = parsed.value.object;
    try rejectUnknownRootFields(root);

    const name = try fields.requiredString(allocator, root, "name");
    errdefer allocator.free(name);
    const app_id = try fields.optionalString(allocator, root, "appId");
    errdefer if (app_id) |value| allocator.free(value);

    const env = try parseBindings(allocator, root, "env");
    errdefer deinitBindings(allocator, env);
    const constants = try parseBindings(allocator, root, "constants");
    errdefer deinitBindings(allocator, constants);
    const labels = try parseStringArray(allocator, root, "labels");
    errdefer deinitStrings(allocator, labels);
    const source = try parseSource(allocator, root);
    errdefer if (source) |location| location.deinit(allocator);
    const on_start = try parseOptionalStepsField(allocator, root, "onStart");
    errdefer deinitSteps(allocator, on_start);
    const on_complete = try parseOptionalStepsField(allocator, root, "onComplete");
    errdefer deinitSteps(allocator, on_complete);

    const steps_value = root.get("steps") orelse return error.ScenarioMissingSteps;
    if (steps_value != .array) return error.ScenarioStepsMustBeArray;
    var steps = std.ArrayList(Step).empty;
    errdefer {
        for (steps.items) |step| step.deinit(allocator);
        steps.deinit(allocator);
    }
    try appendParsedSteps(allocator, &steps, steps_value);

    return .{
        .name = name,
        .app_id = app_id,
        .env = env,
        .constants = constants,
        .labels = labels,
        .source = source,
        .on_start = on_start,
        .on_complete = on_complete,
        .steps = try steps.toOwnedSlice(allocator),
    };
}

fn parseStep(allocator: std.mem.Allocator, value: std.json.Value) anyerror!Step {
    if (value != .object) return error.StepMustBeObject;
    const object = value.object;
    try rejectUnknownStepFields(object);
    var parsed = try parseRawStep(allocator, object);
    errdefer parsed.deinit(allocator);

    if (try fields.optionalBool(object, "optional", false)) {
        const step_ptr = try allocator.create(Step);
        errdefer allocator.destroy(step_ptr);
        step_ptr.* = parsed;
        return .{ .optional = step_ptr };
    }

    return parsed;
}

fn parseRawStep(allocator: std.mem.Allocator, object: std.json.ObjectMap) anyerror!Step {
    const action_value = object.get("action") orelse return error.StepMissingAction;
    if (action_value != .string) return error.StepActionMustBeString;
    const action = action_value.string;

    if (std.mem.eql(u8, action, "launch") or std.mem.eql(u8, action, "launchApp")) {
        if (hasLaunchOptions(object)) return .{ .launch_app = try parseLaunchOptions(allocator, object) };
        return .launch;
    }
    if (std.mem.eql(u8, action, "stop") or std.mem.eql(u8, action, "stopApp")) return .stop;
    if (std.mem.eql(u8, action, "killApp") or std.mem.eql(u8, action, "forceStop")) return .kill_app;
    if (std.mem.eql(u8, action, "clearState")) return .clear_state;
    if (std.mem.eql(u8, action, "clearKeychain")) return .clear_keychain;
    if (std.mem.eql(u8, action, "snapshot") or std.mem.eql(u8, action, "takeScreenshot")) return .snapshot;
    if (std.mem.eql(u8, action, "pressBack") or std.mem.eql(u8, action, "back")) return .press_back;
    if (std.mem.eql(u8, action, "hideKeyboard")) return .hide_keyboard;
    if (std.mem.eql(u8, action, "sleep") or std.mem.eql(u8, action, "waitForAnimationToEnd")) return .{ .sleep_ms = try fields.optionalU64(object, "ms", 500) };
    if (std.mem.eql(u8, action, "openLink")) return .{ .open_link = try fields.requiredStringOrError(allocator, object, "url", error.StepMissingUrl) };
    if (std.mem.eql(u8, action, "setLocation")) return .{ .set_location = .{
        .latitude = try parseLatitude(object),
        .longitude = try parseLongitude(object),
    } };
    if (std.mem.eql(u8, action, "grantPermissions")) return .{ .grant_permissions = try parseStepStringArray(allocator, object, "permissions", error.StepMissingPermissions) };
    if (std.mem.eql(u8, action, "setOrientation")) return .{ .set_orientation = try parseOrientation(object) };
    if (std.mem.eql(u8, action, "setClipboard") or std.mem.eql(u8, action, "copyText")) return .{ .set_clipboard = try fields.requiredStringOrError(allocator, object, "text", error.StepMissingText) };
    if (std.mem.eql(u8, action, "tap") or std.mem.eql(u8, action, "tapOn")) return .{ .tap = try fields.parseSelectorField(allocator, object) };
    if (std.mem.eql(u8, action, "longPress") or std.mem.eql(u8, action, "longPressOn")) return .{ .long_press = .{
        .selector = try fields.parseSelectorField(allocator, object),
        .duration_ms = @as(u32, @intCast(try fields.optionalU64(object, "durationMs", 800))),
    } };
    if (std.mem.eql(u8, action, "doubleTap") or std.mem.eql(u8, action, "doubleTapOn")) return .{ .double_tap = try fields.parseSelectorField(allocator, object) };
    if (std.mem.eql(u8, action, "pressKey")) return .{ .press_key = try fields.requiredStringOrError(allocator, object, "key", error.StepMissingKey) };
    if (std.mem.eql(u8, action, "typeText") or std.mem.eql(u8, action, "inputText")) {
        const wanted = if (object.get("selector")) |selector_value| try selector.parseFromJson(allocator, selector_value) else null;
        errdefer if (wanted) |actual| actual.deinit(allocator);
        return .{ .type_text = .{
            .selector = wanted,
            .text = try fields.requiredStringOrError(allocator, object, "text", error.StepMissingText),
        } };
    }
    if (std.mem.eql(u8, action, "eraseText")) {
        const wanted = if (object.get("selector")) |selector_value| try selector.parseFromJson(allocator, selector_value) else null;
        errdefer if (wanted) |actual| actual.deinit(allocator);
        return .{ .erase_text = .{
            .selector = wanted,
            .max_chars = @as(u32, @intCast(try fields.optionalU64(object, "maxChars", 80))),
        } };
    }
    if (std.mem.eql(u8, action, "swipe")) return .{ .swipe = .{
        .x1 = try fields.requiredI32OrError(object, "x1", error.StepMissingX1),
        .y1 = try fields.requiredI32OrError(object, "y1", error.StepMissingY1),
        .x2 = try fields.requiredI32OrError(object, "x2", error.StepMissingX2),
        .y2 = try fields.requiredI32OrError(object, "y2", error.StepMissingY2),
        .duration_ms = @as(u32, @intCast(try fields.optionalU64(object, "durationMs", 300))),
    } };
    if (std.mem.eql(u8, action, "waitVisible") or std.mem.eql(u8, action, "waitUntilVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        return .{ .wait_visible = .{
            .selector = wanted,
            .timeout_ms = try fields.optionalU64(object, "timeoutMs", 5000),
        } };
    }
    if (std.mem.eql(u8, action, "waitNotVisible") or std.mem.eql(u8, action, "waitUntilNotVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        return .{ .wait_not_visible = .{
            .selector = wanted,
            .timeout_ms = try fields.optionalU64(object, "timeoutMs", 5000),
        } };
    }
    if (std.mem.eql(u8, action, "waitAny")) {
        const selectors = try fields.parseSelectorArrayField(allocator, object);
        errdefer {
            for (selectors) |wanted| wanted.deinit(allocator);
            allocator.free(selectors);
        }
        return .{ .wait_any = .{
            .selectors = selectors,
            .timeout_ms = try fields.optionalU64(object, "timeoutMs", 5000),
        } };
    }
    if (std.mem.eql(u8, action, "assertVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        return .{ .assert_visible = .{
            .selector = wanted,
            .timeout_ms = try optionalTimeoutMs(object),
        } };
    }
    if (std.mem.eql(u8, action, "assertNotVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        return .{ .assert_not_visible = .{
            .selector = wanted,
            .timeout_ms = try optionalTimeoutMs(object),
        } };
    }
    if (std.mem.eql(u8, action, "assertHealthy")) return .{ .assert_healthy_timeout_ms = try fields.optionalU64(object, "timeoutMs", 0) };
    if (std.mem.eql(u8, action, "assertNoneVisible")) {
        const selectors = try fields.parseSelectorArrayField(allocator, object);
        errdefer {
            for (selectors) |wanted| wanted.deinit(allocator);
            allocator.free(selectors);
        }
        return .{ .assert_none_visible = .{
            .selectors = selectors,
            .timeout_ms = try fields.optionalU64(object, "timeoutMs", 0),
        } };
    }
    if (std.mem.eql(u8, action, "optional")) {
        const nested_value = object.get("step") orelse return error.OptionalStepMissingStep;
        const nested = try allocator.create(Step);
        errdefer allocator.destroy(nested);
        nested.* = try parseStep(allocator, nested_value);
        return .{ .optional = nested };
    }
    if (std.mem.eql(u8, action, "whenVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        const timeout_ms = try fields.optionalU64(object, "timeoutMs", 0);
        const steps = try parseStepsField(allocator, object);
        errdefer {
            for (steps) |step| step.deinit(allocator);
            allocator.free(steps);
        }
        return .{ .when_visible = .{
            .selector = wanted,
            .timeout_ms = timeout_ms,
            .steps = steps,
        } };
    }
    if (std.mem.eql(u8, action, "whenNotVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        const timeout_ms = try fields.optionalU64(object, "timeoutMs", 0);
        const steps = try parseStepsField(allocator, object);
        errdefer {
            for (steps) |step| step.deinit(allocator);
            allocator.free(steps);
        }
        return .{ .when_not_visible = .{
            .selector = wanted,
            .timeout_ms = timeout_ms,
            .steps = steps,
        } };
    }
    if (std.mem.eql(u8, action, "repeat")) return .{ .repeat = .{
        .times = try boundedCount(object, "times", 1, error.RepeatOutOfRange),
        .steps = try parseStepsField(allocator, object),
    } };
    if (std.mem.eql(u8, action, "retry")) return .{ .retry = .{
        .attempts = try boundedCount(object, "attempts", 2, error.RetryOutOfRange),
        .steps = try parseStepsField(allocator, object),
    } };
    if (std.mem.eql(u8, action, "runFlow")) return .{ .run_flow = .{
        .steps = try parseStepsField(allocator, object),
    } };
    if (std.mem.eql(u8, action, "scrollUntilVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        return .{ .scroll_until_visible = .{
            .selector = wanted,
            .timeout_ms = try fields.optionalU64(object, "timeoutMs", 5000),
            .direction = try optionalDirection(object, "direction", .down),
        } };
    }

    return error.unknownScenarioAction;
}

fn rejectUnknownRootFields(object: std.json.ObjectMap) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "name") or
            std.mem.eql(u8, key, "appId") or
            std.mem.eql(u8, key, "env") or
            std.mem.eql(u8, key, "constants") or
            std.mem.eql(u8, key, "labels") or
            std.mem.eql(u8, key, "source") or
            std.mem.eql(u8, key, "onStart") or
            std.mem.eql(u8, key, "onComplete") or
            std.mem.eql(u8, key, "steps")) continue;
        return error.UnknownScenarioField;
    }
}

fn rejectUnknownStepFields(object: std.json.ObjectMap) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isKnownStepField(entry.key_ptr.*)) return error.UnknownScenarioStepField;
    }
}

fn isKnownStepField(key: []const u8) bool {
    return std.mem.eql(u8, key, "action") or
        std.mem.eql(u8, key, "optional") or
        std.mem.eql(u8, key, "label") or
        std.mem.eql(u8, key, "source") or
        std.mem.eql(u8, key, "appId") or
        std.mem.eql(u8, key, "stopApp") or
        std.mem.eql(u8, key, "clearState") or
        std.mem.eql(u8, key, "clearKeychain") or
        std.mem.eql(u8, key, "arguments") or
        std.mem.eql(u8, key, "url") or
        std.mem.eql(u8, key, "latitude") or
        std.mem.eql(u8, key, "longitude") or
        std.mem.eql(u8, key, "permissions") or
        std.mem.eql(u8, key, "orientation") or
        std.mem.eql(u8, key, "selector") or
        std.mem.eql(u8, key, "selectors") or
        std.mem.eql(u8, key, "text") or
        std.mem.eql(u8, key, "key") or
        std.mem.eql(u8, key, "maxChars") or
        std.mem.eql(u8, key, "x1") or
        std.mem.eql(u8, key, "y1") or
        std.mem.eql(u8, key, "x2") or
        std.mem.eql(u8, key, "y2") or
        std.mem.eql(u8, key, "durationMs") or
        std.mem.eql(u8, key, "timeoutMs") or
        std.mem.eql(u8, key, "direction") or
        std.mem.eql(u8, key, "times") or
        std.mem.eql(u8, key, "attempts") or
        std.mem.eql(u8, key, "steps") or
        std.mem.eql(u8, key, "step") or
        std.mem.eql(u8, key, "ms");
}

fn hasLaunchOptions(object: std.json.ObjectMap) bool {
    return object.get("appId") != null or
        object.get("stopApp") != null or
        object.get("clearState") != null or
        object.get("clearKeychain") != null or
        object.get("arguments") != null;
}

fn parseLaunchOptions(allocator: std.mem.Allocator, object: std.json.ObjectMap) !LaunchOptions {
    var options = LaunchOptions{
        .app_id = try fields.optionalString(allocator, object, "appId"),
        .stop_app = try fields.optionalBool(object, "stopApp", true),
        .clear_state = try fields.optionalBool(object, "clearState", false),
        .clear_keychain = try fields.optionalBool(object, "clearKeychain", false),
    };
    errdefer options.deinit(allocator);

    const arguments_value = object.get("arguments") orelse return options;
    if (arguments_value != .object) return error.StepLaunchArgumentsMustBeObject;
    var arguments = std.ArrayList(LaunchArgument).empty;
    errdefer {
        for (arguments.items) |argument| argument.deinit(allocator);
        arguments.deinit(allocator);
    }
    var iterator = arguments_value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.*.len == 0) return error.StepLaunchArgumentNameEmpty;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        const parsed_value = try parseLaunchArgumentValue(allocator, entry.value_ptr.*);
        arguments.append(allocator, .{
            .name = name,
            .value = parsed_value,
        }) catch |err| {
            allocator.free(name);
            parsed_value.deinit(allocator);
            return err;
        };
    }
    options.arguments = try arguments.toOwnedSlice(allocator);
    return options;
}

fn parseLaunchArgumentValue(allocator: std.mem.Allocator, value: std.json.Value) !LaunchArgumentValue {
    return switch (value) {
        .string => |actual| .{ .string = try allocator.dupe(u8, actual) },
        .bool => |actual| .{ .boolean = actual },
        .integer => |actual| .{ .integer = actual },
        .float => |actual| .{ .double = actual },
        else => error.StepLaunchArgumentValueUnsupported,
    };
}

fn parseLatitude(object: std.json.ObjectMap) !f64 {
    const latitude = try fields.requiredF64OrError(object, "latitude", error.StepMissingLatitude, error.StepLatitudeMustBeNumber);
    if (latitude < -90.0 or latitude > 90.0) return error.StepLatitudeOutOfRange;
    return latitude;
}

fn parseLongitude(object: std.json.ObjectMap) !f64 {
    const longitude = try fields.requiredF64OrError(object, "longitude", error.StepMissingLongitude, error.StepLongitudeMustBeNumber);
    if (longitude < -180.0 or longitude > 180.0) return error.StepLongitudeOutOfRange;
    return longitude;
}

fn parseOrientation(object: std.json.ObjectMap) !Orientation {
    const value = object.get("orientation") orelse return error.StepMissingOrientation;
    if (value != .string) return error.StepOrientationMustBeString;
    if (std.ascii.eqlIgnoreCase(value.string, "portrait")) return .portrait;
    if (std.ascii.eqlIgnoreCase(value.string, "landscape")) return .landscape;
    return error.StepOrientationInvalid;
}

fn parseStepStringArray(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    missing_error: anyerror,
) anyerror![][]const u8 {
    const value = object.get(key) orelse return missing_error;
    if (value != .array or value.array.items.len == 0) return error.StepPermissionsMustBeArray;
    var values = std.ArrayList([]const u8).empty;
    errdefer {
        for (values.items) |item| allocator.free(item);
        values.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.StepPermissionMustBeString;
        try values.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try values.toOwnedSlice(allocator);
}

fn appendParsedSteps(allocator: std.mem.Allocator, steps: *std.ArrayList(Step), value: std.json.Value) anyerror!void {
    if (value != .array) return error.ScenarioStepsMustBeArray;
    for (value.array.items) |step_value| {
        try steps.append(allocator, try parseStep(allocator, step_value));
    }
}

fn parseStepsField(allocator: std.mem.Allocator, object: std.json.ObjectMap) anyerror![]Step {
    const steps_value = object.get("steps") orelse return error.StepBlockMissingSteps;
    if (steps_value != .array) return error.StepBlockStepsMustBeArray;
    var steps = std.ArrayList(Step).empty;
    errdefer {
        for (steps.items) |step| step.deinit(allocator);
        steps.deinit(allocator);
    }
    try appendParsedSteps(allocator, &steps, steps_value);
    return try steps.toOwnedSlice(allocator);
}

fn parseOptionalStepsField(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) anyerror![]Step {
    const value = object.get(key) orelse return try allocator.alloc(Step, 0);
    if (value != .array) return error.StepBlockStepsMustBeArray;
    var steps = std.ArrayList(Step).empty;
    errdefer {
        for (steps.items) |step| step.deinit(allocator);
        steps.deinit(allocator);
    }
    try appendParsedSteps(allocator, &steps, value);
    return try steps.toOwnedSlice(allocator);
}

fn boundedCount(object: std.json.ObjectMap, key: []const u8, default_value: u64, out_of_range: anyerror) anyerror!u32 {
    const value = try fields.optionalU64(object, key, default_value);
    if (value == 0 or value > 100) return out_of_range;
    return @intCast(value);
}

fn parseBindings(allocator: std.mem.Allocator, root: std.json.ObjectMap, key: []const u8) anyerror![]Binding {
    const value = root.get(key) orelse return try allocator.alloc(Binding, 0);
    if (value != .object) return error.ScenarioBindingsMustBeObject;
    var bindings = std.ArrayList(Binding).empty;
    errdefer {
        deinitBindings(allocator, bindings.items);
        bindings.deinit(allocator);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.ScenarioBindingValueMustBeString;
        try bindings.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.*.string),
        });
    }
    return try bindings.toOwnedSlice(allocator);
}

fn parseStringArray(allocator: std.mem.Allocator, root: std.json.ObjectMap, key: []const u8) anyerror![][]const u8 {
    const value = root.get(key) orelse return try allocator.alloc([]const u8, 0);
    if (value != .array) return error.ScenarioLabelsMustBeArray;
    var labels = std.ArrayList([]const u8).empty;
    errdefer {
        deinitStrings(allocator, labels.items);
        labels.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.ScenarioLabelMustBeString;
        try labels.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try labels.toOwnedSlice(allocator);
}

fn parseSource(allocator: std.mem.Allocator, root: std.json.ObjectMap) anyerror!?SourceLocation {
    const value = root.get("source") orelse return null;
    if (value != .object) return error.ScenarioSourceMustBeObject;
    const file_value = value.object.get("file") orelse return error.ScenarioSourceMissingFile;
    if (file_value != .string or file_value.string.len == 0) return error.ScenarioSourceFileMustBeString;
    const line_value = value.object.get("line") orelse return error.ScenarioSourceMissingLine;
    const column_value = value.object.get("column") orelse return error.ScenarioSourceMissingColumn;
    if (line_value != .integer or line_value.integer < 1 or line_value.integer > std.math.maxInt(u32)) return error.ScenarioSourceLineInvalid;
    if (column_value != .integer or column_value.integer < 1 or column_value.integer > std.math.maxInt(u32)) return error.ScenarioSourceColumnInvalid;
    return .{
        .file = try allocator.dupe(u8, file_value.string),
        .line = @intCast(line_value.integer),
        .column = @intCast(column_value.integer),
    };
}

fn deinitSteps(allocator: std.mem.Allocator, steps: []Step) void {
    for (steps) |step| step.deinit(allocator);
    allocator.free(steps);
}

fn deinitBindings(allocator: std.mem.Allocator, bindings: []Binding) void {
    for (bindings) |binding| binding.deinit(allocator);
    allocator.free(bindings);
}

fn deinitStrings(allocator: std.mem.Allocator, strings: [][]const u8) void {
    for (strings) |value| allocator.free(value);
    allocator.free(strings);
}

fn optionalDirection(object: std.json.ObjectMap, key: []const u8, default_value: ScrollDirection) !ScrollDirection {
    const value = object.get(key) orelse return default_value;
    if (value != .string) return error.OptionalFieldMustBeString;
    if (std.mem.eql(u8, value.string, "down")) return .down;
    if (std.mem.eql(u8, value.string, "up")) return .up;
    return error.unknownScrollDirection;
}

fn optionalTimeoutMs(object: std.json.ObjectMap) !?u64 {
    if (object.get("timeoutMs") == null) return null;
    return try fields.optionalU64(object, "timeoutMs", 0);
}

test "parses setLocation with latitude and longitude" {
    const allocator = std.testing.allocator;
    const script_json =
        \\{
        \\  "name": "set location smoke",
        \\  "steps": [
        \\    {"action": "setLocation", "latitude": 51.5074, "longitude": -0.1278}
        \\  ]
        \\}
    ;

    const script = try parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), script.steps.len);
    switch (script.steps[0]) {
        .set_location => |location| {
            try std.testing.expectApproxEqAbs(@as(f64, 51.5074), location.latitude, 0.000001);
            try std.testing.expectApproxEqAbs(@as(f64, -0.1278), location.longitude, 0.000001);
        },
        else => return error.ExpectedSetLocationStep,
    }
}
