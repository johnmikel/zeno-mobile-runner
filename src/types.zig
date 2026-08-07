const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Bounds = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn centerX(self: Bounds) i32 {
        return self.x + @divTrunc(self.width, 2);
    }

    pub fn centerY(self: Bounds) i32 {
        return self.y + @divTrunc(self.height, 2);
    }
};

pub const Viewport = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const UiNode = struct {
    stable_id: []const u8,
    class_name: []const u8,
    resource_id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    content_desc: ?[]const u8 = null,
    bounds: Bounds = .{},
    enabled: bool = true,
    visible: bool = true,
    checked: bool = false,
    focused: bool = false,
    selected: bool = false,
    parent_stable_id: ?[]const u8 = null,

    pub fn deinit(self: UiNode, allocator: Allocator) void {
        allocator.free(self.stable_id);
        allocator.free(self.class_name);
        if (self.resource_id) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.content_desc) |value| allocator.free(value);
        if (self.parent_stable_id) |value| allocator.free(value);
    }
};

pub const ObservationSnapshot = struct {
    id: []const u8,
    timestamp_ms: i64,
    viewport: Viewport = .{},
    display_density_dpi: ?u32 = null,
    active_package: ?[]const u8 = null,
    active_activity: ?[]const u8 = null,
    screenshot_artifact: ?[]const u8 = null,
    tree_artifact: ?[]const u8 = null,
    focused_node_id: ?[]const u8 = null,
    log_delta: ?[]const u8 = null,
    nodes: []UiNode = &.{},

    pub fn deinit(self: ObservationSnapshot, allocator: Allocator) void {
        allocator.free(self.id);
        if (self.active_package) |value| allocator.free(value);
        if (self.active_activity) |value| allocator.free(value);
        if (self.screenshot_artifact) |value| allocator.free(value);
        if (self.tree_artifact) |value| allocator.free(value);
        if (self.focused_node_id) |value| allocator.free(value);
        if (self.log_delta) |value| allocator.free(value);
        for (self.nodes) |node| node.deinit(allocator);
        allocator.free(self.nodes);
    }
};

pub const StructuredError = struct {
    code: []const u8,
    message: []const u8,

    pub fn deinit(self: StructuredError, allocator: Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

pub const ActionStatus = enum {
    ok,
    not_found,
    timeout,
    device_error,
    protocol_error,
};

pub const ActionResult = struct {
    status: ActionStatus,
    elapsed_ms: u64,
    action: []const u8,
    target: ?[]const u8 = null,
    before_snapshot_id: ?[]const u8 = null,
    after_snapshot_id: ?[]const u8 = null,
    err: ?StructuredError = null,

    pub fn deinit(self: ActionResult, allocator: Allocator) void {
        allocator.free(self.action);
        if (self.target) |value| allocator.free(value);
        if (self.before_snapshot_id) |value| allocator.free(value);
        if (self.after_snapshot_id) |value| allocator.free(value);
        if (self.err) |value| value.deinit(allocator);
    }
};

pub const DeviceInfo = struct {
    serial: []const u8,
    state: []const u8,

    pub fn deinit(self: DeviceInfo, allocator: Allocator) void {
        allocator.free(self.serial);
        allocator.free(self.state);
    }
};

pub fn dupeOptional(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |actual| return try allocator.dupe(u8, actual);
    return null;
}
