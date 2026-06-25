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

pub const StepBlock = struct {
    steps: []Step,

    pub fn deinit(self: StepBlock, allocator: std.mem.Allocator) void {
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
    stop,
    clear_state,
    snapshot,
    open_link: []const u8,
    set_location: Location,
    tap: selector.Selector,
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
    repeat: RepeatBlock,
    scroll_until_visible: ScrollUntilVisible,
    sleep_ms: u64,

    pub fn deinit(self: Step, allocator: std.mem.Allocator) void {
        switch (self) {
            .open_link => |value| allocator.free(value),
            .tap => |value| value.deinit(allocator),
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
            .repeat => |value| value.deinit(allocator),
            .scroll_until_visible => |value| value.deinit(allocator),
            else => {},
        }
    }
};

pub const Scenario = struct {
    name: []const u8,
    app_id: ?[]const u8 = null,
    steps: []Step,

    pub fn deinit(self: Scenario, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.app_id) |value| allocator.free(value);
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

    if (std.mem.eql(u8, action, "launch")) return .launch;
    if (std.mem.eql(u8, action, "stop")) return .stop;
    if (std.mem.eql(u8, action, "clearState")) return .clear_state;
    if (std.mem.eql(u8, action, "snapshot")) return .snapshot;
    if (std.mem.eql(u8, action, "pressBack")) return .press_back;
    if (std.mem.eql(u8, action, "hideKeyboard")) return .hide_keyboard;
    if (std.mem.eql(u8, action, "sleep")) return .{ .sleep_ms = try fields.optionalU64(object, "ms", 500) };
    if (std.mem.eql(u8, action, "openLink")) return .{ .open_link = try fields.requiredStringOrError(allocator, object, "url", error.StepMissingUrl) };
    if (std.mem.eql(u8, action, "setLocation")) return .{ .set_location = .{
        .latitude = try parseLatitude(object),
        .longitude = try parseLongitude(object),
    } };
    if (std.mem.eql(u8, action, "tap")) return .{ .tap = try fields.parseSelectorField(allocator, object) };
    if (std.mem.eql(u8, action, "typeText")) {
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
    if (std.mem.eql(u8, action, "waitVisible")) {
        const wanted = try fields.parseSelectorField(allocator, object);
        errdefer wanted.deinit(allocator);
        return .{ .wait_visible = .{
            .selector = wanted,
            .timeout_ms = try fields.optionalU64(object, "timeoutMs", 5000),
        } };
    }
    if (std.mem.eql(u8, action, "waitNotVisible")) {
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
    if (std.mem.eql(u8, action, "repeat")) return .{ .repeat = .{
        .times = @as(u32, @intCast(try fields.optionalU64(object, "times", 1))),
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
        std.mem.eql(u8, key, "url") or
        std.mem.eql(u8, key, "latitude") or
        std.mem.eql(u8, key, "longitude") or
        std.mem.eql(u8, key, "selector") or
        std.mem.eql(u8, key, "selectors") or
        std.mem.eql(u8, key, "text") or
        std.mem.eql(u8, key, "maxChars") or
        std.mem.eql(u8, key, "x1") or
        std.mem.eql(u8, key, "y1") or
        std.mem.eql(u8, key, "x2") or
        std.mem.eql(u8, key, "y2") or
        std.mem.eql(u8, key, "durationMs") or
        std.mem.eql(u8, key, "timeoutMs") or
        std.mem.eql(u8, key, "direction") or
        std.mem.eql(u8, key, "times") or
        std.mem.eql(u8, key, "steps") or
        std.mem.eql(u8, key, "step") or
        std.mem.eql(u8, key, "ms");
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
