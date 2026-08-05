const std = @import("std");
const scenario = @import("scenario.zig");

pub const ImportOptions = struct {
    name: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    force: bool = false,
    strict: bool = false,
    compatibility_report_path: ?[]const u8 = null,
};

pub const CompatibilityStatus = enum {
    supported,
    rewritten,
    unsupported,
};

pub const CompatibilityItem = struct {
    command: []const u8,
    status: CompatibilityStatus,
    line: u32,
    column: u32,
    message: []const u8,
    canonical_action: ?[]const u8 = null,
    source_file: ?[]const u8 = null,

    pub fn deinit(self: CompatibilityItem, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.free(self.message);
        if (self.canonical_action) |value| allocator.free(value);
        if (self.source_file) |value| allocator.free(value);
    }
};

pub const ImportResult = struct {
    out_path: []const u8,
    name: []const u8,
    app_id: ?[]const u8,
    step_count: usize,
    supported_count: usize = 0,
    rewritten_count: usize = 0,
    unsupported_count: usize = 0,
    compatibility_report_path: ?[]const u8 = null,

    pub fn deinit(self: ImportResult, allocator: std.mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.name);
        if (self.app_id) |value| allocator.free(value);
        if (self.compatibility_report_path) |value| allocator.free(value);
    }
};

pub const ImportedScenario = struct {
    name: []const u8,
    app_id: ?[]const u8 = null,
    on_start: []ImportedStep = &.{},
    on_complete: []ImportedStep = &.{},
    steps: []ImportedStep,
    compatibility: []CompatibilityItem = &.{},

    pub fn deinit(self: ImportedScenario, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.app_id) |value| allocator.free(value);
        for (self.on_start) |step| step.deinit(allocator);
        if (self.on_start.len > 0) allocator.free(self.on_start);
        for (self.on_complete) |step| step.deinit(allocator);
        if (self.on_complete.len > 0) allocator.free(self.on_complete);
        for (self.steps) |step| step.deinit(allocator);
        if (self.steps.len > 0) allocator.free(self.steps);
        for (self.compatibility) |item| item.deinit(allocator);
        if (self.compatibility.len > 0) allocator.free(self.compatibility);
    }
};

pub const SelectorSpec = struct {
    id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    text_contains: ?[]const u8 = null,
    content_desc: ?[]const u8 = null,

    pub fn deinit(self: SelectorSpec, allocator: std.mem.Allocator) void {
        if (self.id) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.text_contains) |value| allocator.free(value);
        if (self.content_desc) |value| allocator.free(value);
    }

    pub fn hasAny(self: SelectorSpec) bool {
        return self.id != null or self.text != null or self.text_contains != null or self.content_desc != null;
    }
};

pub const WaitSelector = struct {
    selector: SelectorSpec,
    timeout_ms: u64 = 5000,

    pub fn deinit(self: WaitSelector, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
    }
};

pub const ScrollStep = struct {
    selector: SelectorSpec,
    direction: []const u8 = "down",
    timeout_ms: u64 = 5000,

    pub fn deinit(self: ScrollStep, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
    }
};

pub const GestureStep = struct {
    selector: SelectorSpec,
    duration_ms: u32 = 800,

    pub fn deinit(self: GestureStep, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
    }
};

pub const ImportedBlock = struct {
    count: u32,
    steps: []ImportedStep,

    pub fn deinit(self: ImportedBlock, allocator: std.mem.Allocator) void {
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

pub const ImportedConditional = struct {
    selector: SelectorSpec,
    steps: []ImportedStep,

    pub fn deinit(self: ImportedConditional, allocator: std.mem.Allocator) void {
        self.selector.deinit(allocator);
        for (self.steps) |step| step.deinit(allocator);
        allocator.free(self.steps);
    }
};

pub const ImportedStep = union(enum) {
    launch,
    launch_app: scenario.LaunchOptions,
    stop,
    kill_app,
    clear_state,
    clear_keychain,
    grant_permissions: [][]const u8,
    set_orientation: []const u8,
    set_clipboard: []const u8,
    repeat: ImportedBlock,
    retry: ImportedBlock,
    when_visible: ImportedConditional,
    when_not_visible: ImportedConditional,
    snapshot,
    hide_keyboard,
    press_back,
    open_link: []const u8,
    tap: SelectorSpec,
    long_press: GestureStep,
    double_tap: SelectorSpec,
    press_key: []const u8,
    type_text: []const u8,
    erase_text: u32,
    assert_visible: SelectorSpec,
    assert_not_visible: SelectorSpec,
    wait_visible: WaitSelector,
    wait_not_visible: WaitSelector,
    scroll_until_visible: ScrollStep,
    sleep_ms: u64,

    pub fn deinit(self: ImportedStep, allocator: std.mem.Allocator) void {
        switch (self) {
            .launch_app => |value| value.deinit(allocator),
            .open_link => |value| allocator.free(value),
            .grant_permissions => |values| {
                for (values) |value| allocator.free(value);
                allocator.free(values);
            },
            .set_orientation => |value| allocator.free(value),
            .set_clipboard => |value| allocator.free(value),
            .repeat => |value| value.deinit(allocator),
            .retry => |value| value.deinit(allocator),
            .when_visible => |value| value.deinit(allocator),
            .when_not_visible => |value| value.deinit(allocator),
            .tap => |value| value.deinit(allocator),
            .long_press => |value| value.deinit(allocator),
            .double_tap => |value| value.deinit(allocator),
            .press_key => |value| allocator.free(value),
            .type_text => |value| allocator.free(value),
            .assert_visible => |value| value.deinit(allocator),
            .assert_not_visible => |value| value.deinit(allocator),
            .wait_visible => |value| value.deinit(allocator),
            .wait_not_visible => |value| value.deinit(allocator),
            .scroll_until_visible => |value| value.deinit(allocator),
            else => {},
        }
    }
};
