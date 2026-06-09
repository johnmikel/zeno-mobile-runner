const std = @import("std");
const command = @import("command.zig");
const ios_devices = @import("ios_devices.zig");
const ios_lifecycle = @import("ios_lifecycle.zig");
const ios_snapshot = @import("ios_snapshot.zig");
const ios_shim = @import("ios_shim.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

const default_max_output = 32 * 1024 * 1024;
// Clean iOS prebuilds can force the XCTest shim script through a full native
// dependency build before it can answer the first selector query.
const shim_timeout_ms = 5_400_000;
const shim_best_effort_timeout_ms = 10_000;
const shim_command_attempts = 2;
const shim_bootstrap_retry_delay_ms = 500;

pub const TargetKind = enum {
    simulator,
    physical,
};

pub const IosDevice = struct {
    allocator: std.mem.Allocator,
    xcrun_path: []const u8 = "xcrun",
    udid: ?[]const u8 = null,
    app_id: []const u8,
    shim_path: ?[]const u8 = null,
    target_kind: TargetKind = .simulator,

    pub fn init(
        allocator: std.mem.Allocator,
        xcrun_path: []const u8,
        udid: ?[]const u8,
        app_id: []const u8,
    ) !IosDevice {
        return try initWithShim(allocator, xcrun_path, udid, app_id, null);
    }

    pub fn initWithShim(
        allocator: std.mem.Allocator,
        xcrun_path: []const u8,
        udid: ?[]const u8,
        app_id: []const u8,
        shim_path: ?[]const u8,
    ) !IosDevice {
        return try initWithKindAndShim(allocator, xcrun_path, udid, app_id, .simulator, shim_path);
    }

    pub fn initWithKindAndShim(
        allocator: std.mem.Allocator,
        xcrun_path: []const u8,
        udid: ?[]const u8,
        app_id: []const u8,
        target_kind: TargetKind,
        shim_path: ?[]const u8,
    ) !IosDevice {
        const owned_xcrun = try allocator.dupe(u8, xcrun_path);
        errdefer allocator.free(owned_xcrun);
        const owned_udid = try types.dupeOptional(allocator, udid);
        errdefer if (owned_udid) |value| allocator.free(value);
        const owned_app_id = try allocator.dupe(u8, app_id);
        errdefer allocator.free(owned_app_id);
        const owned_shim_path = try types.dupeOptional(allocator, shim_path);

        return .{
            .allocator = allocator,
            .xcrun_path = owned_xcrun,
            .udid = owned_udid,
            .app_id = owned_app_id,
            .shim_path = owned_shim_path,
            .target_kind = target_kind,
        };
    }

    pub fn deinit(self: *IosDevice) void {
        self.allocator.free(self.xcrun_path);
        if (self.udid) |value| self.allocator.free(value);
        self.allocator.free(self.app_id);
        if (self.shim_path) |value| self.allocator.free(value);
    }

    pub fn listDevices(self: *IosDevice) ![]types.DeviceInfo {
        return switch (self.target_kind) {
            .simulator => try ios_devices.listSimulators(self.allocator, self.xcrun_path),
            .physical => try ios_devices.listPhysical(self.allocator, self.xcrun_path),
        };
    }

    pub fn install(self: *IosDevice, app_path: []const u8) !void {
        if (self.target_kind == .physical) return try self.installPhysical(app_path);
        const result = try self.runSimctl(&.{ "install", self.target(), app_path }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn launch(self: *IosDevice) !void {
        if (self.target_kind == .physical) return try self.launchPhysical(null);
        const result = try self.runSimctl(&.{ "launch", self.target(), self.app_id }, default_max_output);
        defer result.deinit(self.allocator);
        result.ensureSuccess() catch |err| {
            if (self.appIsRunningFromShimBestEffort()) return;
            return err;
        };
    }

    pub fn stop(self: *IosDevice) !void {
        if (self.target_kind == .physical) return try self.stopPhysicalBestEffort();
        const result = try self.runSimctl(&.{ "terminate", self.target(), self.app_id }, default_max_output);
        defer result.deinit(self.allocator);
        if (ios_lifecycle.isAppNotRunning(result)) return;
        try result.ensureSuccess();
    }

    pub fn clearState(self: *IosDevice) !void {
        if (self.target_kind == .physical) return try self.uninstallPhysicalBestEffort();
        const result = try self.runSimctl(&.{ "uninstall", self.target(), self.app_id }, default_max_output);
        defer result.deinit(self.allocator);
        if (ios_lifecycle.isMissingInstalledApp(result)) return;
        try result.ensureSuccess();
    }

    pub fn openLink(self: *IosDevice, url: []const u8) !void {
        if (self.target_kind == .physical) return try self.launchPhysical(url);
        const result = try self.runSimctl(&.{ "openurl", self.target(), url }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        if (urlMayNeedOpenConfirmation(url)) {
            self.acceptOpenURLConfirmationBestEffort();
        }
    }

    pub fn tap(self: *IosDevice, x: i32, y: i32) !void {
        try self.runShimAction(.{ .kind = .tap, .x = x, .y = y });
    }

    pub fn tapBySelector(self: *IosDevice, wanted: selector.Selector) !bool {
        return try self.runShimSelectorAction(.{ .kind = .tap }, wanted);
    }

    pub fn visibleBySelector(self: *IosDevice, wanted: selector.Selector) !?bool {
        if (self.shim_path == null) return null;
        const shim_selector = try ios_shim.selectorString(self.allocator, wanted) orelse return null;
        defer self.allocator.free(shim_selector);

        const response = try self.runShim(.{ .kind = .query, .selector = shim_selector });
        defer self.allocator.free(response);
        return try ios_shim.parseQueryResponse(response);
    }

    pub fn typeText(self: *IosDevice, text: []const u8) !void {
        try self.runShimAction(.{ .kind = .type_text, .text = text });
    }

    pub fn typeTextBySelector(self: *IosDevice, wanted: selector.Selector, text: []const u8) !bool {
        return try self.runShimSelectorAction(.{ .kind = .type_text, .text = text }, wanted);
    }

    pub fn eraseText(self: *IosDevice, max_chars: u32) !void {
        try self.runShimAction(.{ .kind = .erase_text, .max_chars = max_chars });
    }

    pub fn eraseTextBySelector(self: *IosDevice, wanted: selector.Selector, max_chars: u32) !bool {
        return try self.runShimSelectorAction(.{ .kind = .erase_text, .max_chars = max_chars }, wanted);
    }

    pub fn hideKeyboard(self: *IosDevice) !void {
        try self.runShimAction(.{ .kind = .hide_keyboard });
    }

    pub fn swipe(self: *IosDevice, x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
        try self.runShimAction(.{ .kind = .swipe, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .duration_ms = duration_ms });
    }

    pub fn pressBack(self: *IosDevice) !void {
        try self.runShimAction(.{ .kind = .press_back });
    }

    pub fn settle(self: *IosDevice, timeout_ms: u64) !void {
        if (self.shim_path != null) {
            return try self.runShimAction(.{
                .kind = .settle,
                .duration_ms = @as(u32, @intCast(@min(timeout_ms, std.math.maxInt(u32)))),
            });
        }
        std.Thread.sleep(timeout_ms * std.time.ns_per_ms);
    }

    pub fn snapshot(self: *IosDevice, writer: ?*trace.TraceWriter) !types.ObservationSnapshot {
        const id = if (writer) |tw| try tw.nextSnapshotId() else try std.fmt.allocPrint(self.allocator, "snapshot-{d}", .{std.time.milliTimestamp()});
        errdefer self.allocator.free(id);

        var screenshot_artifact: ?[]const u8 = null;
        errdefer if (screenshot_artifact) |path| self.allocator.free(path);
        var viewport: types.Viewport = .{};

        if (writer) |tw| {
            if (tw.capture.capture_screenshots) {
                const screenshot = self.captureScreenshot() catch null;
                if (screenshot) |bytes| {
                    defer self.allocator.free(bytes);
                    viewport = ios_snapshot.parsePngViewport(bytes) orelse .{};
                    const file_name = try std.fmt.allocPrint(self.allocator, "{s}.png", .{id});
                    defer self.allocator.free(file_name);
                    screenshot_artifact = try tw.writeArtifact(file_name, bytes);
                }
            }
        }

        const capture_logs = if (writer) |tw| tw.capture.capture_logs else true;
        const logs = if (capture_logs) self.logDelta() catch null else null;
        errdefer if (logs) |value| self.allocator.free(value);

        const active_package = try self.allocator.dupe(u8, self.app_id);
        errdefer self.allocator.free(active_package);
        const nodes = if (self.shim_path != null)
            self.snapshotNodesFromShim() catch |err| blk: {
                if (screenshot_artifact == null) return err;
                if (writer) |tw| try self.recordSnapshotSemanticFailure(tw, screenshot_artifact.?, err);
                break :blk try self.allocator.alloc(types.UiNode, 0);
            }
        else
            try self.allocator.alloc(types.UiNode, 0);
        errdefer self.allocator.free(nodes);

        return .{
            .id = id,
            .timestamp_ms = std.time.milliTimestamp(),
            .viewport = viewport,
            .active_package = active_package,
            .active_activity = null,
            .screenshot_artifact = screenshot_artifact,
            .tree_artifact = null,
            .focused_node_id = null,
            .log_delta = logs,
            .nodes = nodes,
        };
    }

    fn captureScreenshot(self: *IosDevice) ![]u8 {
        if (self.target_kind == .physical) {
            const response = try self.runShim(.{ .kind = .screenshot });
            defer self.allocator.free(response);
            return try ios_shim.parseScreenshotPng(self.allocator, response);
        }
        const path = try std.fmt.allocPrint(self.allocator, "/tmp/zmr-ios-screenshot-{d}.png", .{std.time.nanoTimestamp()});
        defer self.allocator.free(path);
        defer std.fs.cwd().deleteFile(path) catch {};

        const result = try self.runSimctl(&.{ "io", self.target(), "screenshot", path }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return try std.fs.cwd().readFileAlloc(self.allocator, path, default_max_output);
    }

    fn logDelta(self: *IosDevice) !?[]const u8 {
        if (self.target_kind == .physical) return null;
        const result = try self.runSimctl(&.{ "spawn", self.target(), "log", "show", "--style", "compact", "--last", "30s" }, 1024 * 1024);
        defer result.deinit(self.allocator);
        if (result.term != .Exited or result.term.Exited != 0) return null;
        return try self.allocator.dupe(u8, result.stdout);
    }

    fn snapshotNodesFromShim(self: *IosDevice) ![]types.UiNode {
        const response = try self.runShim(.{ .kind = .snapshot });
        defer self.allocator.free(response);
        return try ios_shim.parseSnapshotNodes(self.allocator, response);
    }

    fn recordSnapshotSemanticFailure(self: *IosDevice, writer: *trace.TraceWriter, screenshot_artifact: []const u8, err: anyerror) !void {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(writer.allocator);
        const out = payload.writer(writer.allocator);
        try out.writeAll("{\"status\":\"failed\",\"artifactStatus\":\"captured\",\"semanticStatus\":\"failed\",\"error\":");
        try trace.writeJsonString(out, @errorName(err));
        try out.writeAll(",\"screenshotArtifact\":");
        try trace.writeJsonString(out, screenshot_artifact);
        try out.writeAll(",\"source\":\"ios-xctest-shim\"}");
        try writer.recordEvent("observe.snapshot.semanticExtraction", payload.items);
        _ = self;
    }

    fn runShimAction(self: *IosDevice, shim_command: ios_shim.Command) !void {
        const response = try self.runShim(shim_command);
        defer self.allocator.free(response);
        try ios_shim.parseOkResponse(response);
    }

    fn runShimActionWithTimeout(self: *IosDevice, shim_command: ios_shim.Command, timeout_ms: u64) !void {
        const response = try self.runShimWithTimeout(shim_command, timeout_ms);
        defer self.allocator.free(response);
        try ios_shim.parseOkResponse(response);
    }

    fn acceptOpenURLConfirmationBestEffort(self: *IosDevice) void {
        if (self.shim_path == null) return;
        self.runShimActionWithTimeout(.{ .kind = .accept_system_alert, .text = "Open" }, shim_best_effort_timeout_ms) catch {};
    }

    fn appIsRunningFromShimBestEffort(self: *IosDevice) bool {
        if (self.shim_path == null) return false;
        const response = self.runShimWithTimeout(.{ .kind = .app_state }, shim_best_effort_timeout_ms) catch return false;
        defer self.allocator.free(response);
        return ios_shim.parseAppStateRunning(response) catch false;
    }

    fn runShimSelectorAction(self: *IosDevice, shim_command: ios_shim.Command, wanted: selector.Selector) !bool {
        if (self.shim_path == null) return false;
        const shim_selector = try ios_shim.selectorString(self.allocator, wanted) orelse return false;
        defer self.allocator.free(shim_selector);

        var command_with_selector = shim_command;
        command_with_selector.selector = shim_selector;
        const response = try self.runShim(command_with_selector);
        defer self.allocator.free(response);
        return switch (try ios_shim.parseSelectorActionResponse(response)) {
            .ok => true,
            .selector_unavailable => false,
        };
    }

    fn runShim(self: *IosDevice, shim_command: ios_shim.Command) ![]u8 {
        return self.runShimWithTimeout(shim_command, shim_timeout_ms);
    }

    fn runShimWithTimeout(self: *IosDevice, shim_command: ios_shim.Command, timeout_ms: u64) ![]u8 {
        const path = self.shim_path orelse return error.IosXCTestShimRequired;

        var input = std.ArrayList(u8).empty;
        defer input.deinit(self.allocator);
        try ios_shim.writeCommandJson(input.writer(self.allocator), shim_command);

        var attempt: usize = 0;
        while (attempt < shim_command_attempts) {
            attempt += 1;
            const result = try command.runWithInputTimeout(self.allocator, &.{path}, input.items, 4 * 1024 * 1024, timeout_ms);
            defer result.deinit(self.allocator);

            result.ensureSuccess() catch |err| {
                if (attempt < shim_command_attempts and err == error.CommandFailed and isTransientShimBootstrapFailure(result)) {
                    std.Thread.sleep(shim_bootstrap_retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            return try self.allocator.dupe(u8, result.stdout);
        }

        return error.CommandFailed;
    }

    fn target(self: *IosDevice) []const u8 {
        return self.udid orelse "booted";
    }

    fn runSimctl(self: *IosDevice, extra: []const []const u8, max_output_bytes: usize) !command.ExecResult {
        return try ios_devices.runSimctlCommand(self.allocator, self.xcrun_path, extra, max_output_bytes);
    }

    fn installPhysical(self: *IosDevice, app_path: []const u8) !void {
        try ios_lifecycle.installPhysical(self.allocator, self.xcrun_path, self.target(), app_path);
    }

    fn launchPhysical(self: *IosDevice, url: ?[]const u8) !void {
        try ios_lifecycle.launchPhysical(self.allocator, self.xcrun_path, self.target(), self.app_id, url);
    }

    fn stopPhysicalBestEffort(self: *IosDevice) !void {
        try ios_lifecycle.stopPhysicalBestEffort(self.allocator, self.xcrun_path, self.target(), self.app_id);
    }

    fn uninstallPhysicalBestEffort(self: *IosDevice) !void {
        try ios_lifecycle.uninstallPhysicalBestEffort(self.allocator, self.xcrun_path, self.target(), self.app_id);
    }
};

fn isTransientShimBootstrapFailure(result: command.ExecResult) bool {
    if (result.timed_out) return false;
    switch (result.term) {
        .Exited => |code| if (code == 0) return false,
        else => return false,
    }
    return std.mem.indexOf(u8, result.stderr, "iOS shim server exited before it became ready") != null or
        std.mem.indexOf(u8, result.stderr, "Early unexpected exit") != null or
        std.mem.indexOf(u8, result.stderr, "operation never finished bootstrapping") != null;
}

fn urlMayNeedOpenConfirmation(url: []const u8) bool {
    return startsWithIgnoreCase(url, "http://") or startsWithIgnoreCase(url, "https://");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

pub fn listDevices(allocator: std.mem.Allocator, xcrun_path: []const u8) ![]types.DeviceInfo {
    return try ios_devices.listSimulators(allocator, xcrun_path);
}

pub fn listPhysicalDevices(allocator: std.mem.Allocator, xcrun_path: []const u8) ![]types.DeviceInfo {
    return try ios_devices.listPhysical(allocator, xcrun_path);
}

pub fn parseDevicesJson(allocator: std.mem.Allocator, content: []const u8) ![]types.DeviceInfo {
    return try ios_devices.parseSimulatorsJson(allocator, content);
}

pub fn parsePhysicalDevicesJson(allocator: std.mem.Allocator, content: []const u8) ![]types.DeviceInfo {
    return try ios_devices.parsePhysicalDevicesJson(allocator, content);
}

test "ios xctest shim timeout allows cold xcodebuild startup" {
    try std.testing.expect(shim_timeout_ms >= 5_400_000);
    try std.testing.expect(shim_best_effort_timeout_ms <= 15_000);
}
