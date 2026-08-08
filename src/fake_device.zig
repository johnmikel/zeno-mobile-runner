const std = @import("std");
const scenario = @import("scenario.zig");
const types = @import("types.zig");

pub const FakeDevice = struct {
    allocator: std.mem.Allocator,
    snapshots: []types.ObservationSnapshot,
    snapshot_index: usize = 0,
    taps: usize = 0,
    /// Where the last tap landed. Without this, nothing can assert that a tap
    /// hit the control rather than a wrapper that happens to share its text.
    last_tap_x: i32 = -1,
    last_tap_y: i32 = -1,
    swipes: usize = 0,
    erases: usize = 0,
    hides_keyboard: usize = 0,
    presses_back: usize = 0,
    pressed_keys: std.ArrayList([]const u8),
    stopped: bool = false,
    cleared: bool = false,
    last_swipe: ?SwipeRecord = null,
    last_erase_chars: u32 = 0,
    typed_text: std.ArrayList([]const u8),
    launched: bool = false,
    launch_argument_count: usize = 0,
    launch_app_id: ?[]const u8 = null,
    cleared_keychain: bool = false,
    installed_path: ?[]const u8 = null,
    opened_link: ?[]const u8 = null,
    settles: usize = 0,
    last_settle_timeout_ms: u64 = 0,
    location_sets: usize = 0,
    last_location: ?LocationRecord = null,
    granted_permissions: std.ArrayList([]const u8),
    current_orientation: scenario.Orientation = .portrait,
    clipboard: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, snapshots: []types.ObservationSnapshot) FakeDevice {
        return .{
            .allocator = allocator,
            .snapshots = snapshots,
            .typed_text = std.ArrayList([]const u8).empty,
            .pressed_keys = std.ArrayList([]const u8).empty,
            .granted_permissions = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *FakeDevice) void {
        for (self.typed_text.items) |text| self.allocator.free(text);
        self.typed_text.deinit(self.allocator);
        for (self.pressed_keys.items) |key| self.allocator.free(key);
        self.pressed_keys.deinit(self.allocator);
        for (self.granted_permissions.items) |permission| self.allocator.free(permission);
        self.granted_permissions.deinit(self.allocator);
        if (self.clipboard) |value| self.allocator.free(value);
        if (self.installed_path) |value| self.allocator.free(value);
        if (self.opened_link) |value| self.allocator.free(value);
        if (self.launch_app_id) |value| self.allocator.free(value);
    }

    pub fn install(self: *FakeDevice, apk_path: []const u8) !void {
        if (self.installed_path) |value| self.allocator.free(value);
        self.installed_path = try self.allocator.dupe(u8, apk_path);
    }

    pub fn launch(self: *FakeDevice) !void {
        self.launched = true;
    }

    pub fn launchWithArguments(self: *FakeDevice, app_id: ?[]const u8, arguments: []const scenario.LaunchArgument) !void {
        self.launched = true;
        self.launch_argument_count = arguments.len;
        if (self.launch_app_id) |value| self.allocator.free(value);
        self.launch_app_id = if (app_id) |value| try self.allocator.dupe(u8, value) else null;
    }

    pub fn stop(self: *FakeDevice) !void {
        self.stopped = true;
    }

    pub fn killApp(self: *FakeDevice) !void {
        self.stopped = true;
    }

    pub fn clearState(self: *FakeDevice) !void {
        self.cleared = true;
    }

    pub fn clearKeychain(self: *FakeDevice) !void {
        self.cleared_keychain = true;
    }

    pub fn listDevices(self: *FakeDevice) ![]types.DeviceInfo {
        const devices = try self.allocator.alloc(types.DeviceInfo, 1);
        errdefer self.allocator.free(devices);
        const serial = try self.allocator.dupe(u8, "fake-device-1");
        errdefer self.allocator.free(serial);
        const state = try self.allocator.dupe(u8, "device");
        devices[0] = .{
            .serial = serial,
            .state = state,
        };
        return devices;
    }

    pub fn openLink(self: *FakeDevice, url: []const u8) !void {
        if (self.opened_link) |value| self.allocator.free(value);
        self.opened_link = try self.allocator.dupe(u8, url);
    }

    pub fn setLocation(self: *FakeDevice, latitude: f64, longitude: f64) !void {
        self.location_sets += 1;
        self.last_location = .{
            .latitude = latitude,
            .longitude = longitude,
        };
    }

    pub fn grantPermissions(self: *FakeDevice, permissions: [][]const u8) !void {
        for (permissions) |permission| try self.granted_permissions.append(self.allocator, try self.allocator.dupe(u8, permission));
    }

    pub fn setOrientation(self: *FakeDevice, orientation: scenario.Orientation) !void {
        self.current_orientation = orientation;
    }

    pub fn setClipboard(self: *FakeDevice, text: []const u8) !void {
        if (self.clipboard) |value| self.allocator.free(value);
        self.clipboard = try self.allocator.dupe(u8, text);
    }

    pub fn tap(self: *FakeDevice, x: i32, y: i32) !void {
        self.taps += 1;
        self.last_tap_x = x;
        self.last_tap_y = y;
    }

    pub fn typeText(self: *FakeDevice, text: []const u8) !void {
        try self.typed_text.append(self.allocator, try self.allocator.dupe(u8, text));
    }

    pub fn eraseText(self: *FakeDevice, max_chars: u32) !void {
        self.last_erase_chars = max_chars;
        self.erases += 1;
    }

    pub fn hideKeyboard(self: *FakeDevice) !void {
        self.hides_keyboard += 1;
    }

    pub fn swipe(self: *FakeDevice, x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
        self.swipes += 1;
        self.last_swipe = .{
            .x1 = x1,
            .y1 = y1,
            .x2 = x2,
            .y2 = y2,
            .duration_ms = duration_ms,
        };
    }

    pub fn pressBack(self: *FakeDevice) !void {
        self.presses_back += 1;
    }

    pub fn pressKey(self: *FakeDevice, key: []const u8) !void {
        try self.pressed_keys.append(self.allocator, try self.allocator.dupe(u8, key));
    }

    pub fn settle(self: *FakeDevice, timeout_ms: u64) !void {
        self.settles += 1;
        self.last_settle_timeout_ms = timeout_ms;
    }

    pub fn snapshot(self: *FakeDevice, writer: anytype) !types.ObservationSnapshot {
        _ = writer;
        if (self.snapshots.len == 0) return error.NoFakeSnapshots;
        const index = @min(self.snapshot_index, self.snapshots.len - 1);
        if (self.snapshot_index + 1 < self.snapshots.len) self.snapshot_index += 1;
        return try cloneSnapshot(self.allocator, self.snapshots[index]);
    }
};

pub const SwipeRecord = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    duration_ms: u32,
};

pub const LocationRecord = struct {
    latitude: f64,
    longitude: f64,
};

pub fn cloneSnapshot(allocator: std.mem.Allocator, source: types.ObservationSnapshot) !types.ObservationSnapshot {
    var nodes = try allocator.alloc(types.UiNode, source.nodes.len);
    errdefer allocator.free(nodes);
    var initialized: usize = 0;
    errdefer {
        for (nodes[0..initialized]) |node| node.deinit(allocator);
    }
    for (source.nodes, 0..) |node, index| {
        nodes[index] = .{
            .stable_id = try allocator.dupe(u8, node.stable_id),
            .class_name = try allocator.dupe(u8, node.class_name),
            .resource_id = try types.dupeOptional(allocator, node.resource_id),
            .text = try types.dupeOptional(allocator, node.text),
            .content_desc = try types.dupeOptional(allocator, node.content_desc),
            .bounds = node.bounds,
            .enabled = node.enabled,
            .visible = node.visible,
            .checked = node.checked,
            .focused = node.focused,
            .selected = node.selected,
            // Dropping this flattened every hierarchy the fake handed back, so
            // parent/child and depth behavior was untestable here.
            .parent_stable_id = try types.dupeOptional(allocator, node.parent_stable_id),
        };
        initialized += 1;
    }
    return .{
        .id = try allocator.dupe(u8, source.id),
        .timestamp_ms = source.timestamp_ms,
        .viewport = source.viewport,
        .active_package = try types.dupeOptional(allocator, source.active_package),
        .active_activity = try types.dupeOptional(allocator, source.active_activity),
        .screenshot_artifact = try types.dupeOptional(allocator, source.screenshot_artifact),
        .tree_artifact = try types.dupeOptional(allocator, source.tree_artifact),
        .focused_node_id = try types.dupeOptional(allocator, source.focused_node_id),
        .log_delta = try types.dupeOptional(allocator, source.log_delta),
        .nodes = nodes,
    };
}
