const std = @import("std");
const stdio = @import("stdio.zig");
const command = @import("command.zig");
const ios_devices = @import("ios_devices.zig");
const ios_lifecycle = @import("ios_lifecycle.zig");
const ios_snapshot = @import("ios_snapshot.zig");
const ios_shim = @import("ios_shim.zig");
const scenario = @import("scenario.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

const default_max_output = 32 * 1024 * 1024;
// Clean iOS prebuilds can force the XCTest shim script through a full native
// dependency build before it can answer the first selector query. Slower CI
// hardware can override the default with ZMR_IOS_SHIM_TIMEOUT_MS.
const default_shim_timeout_ms = 5_400_000;
const shim_timeout_env = "ZMR_IOS_SHIM_TIMEOUT_MS";
const shim_best_effort_timeout_ms = 10_000;
const open_link_interruption_attempts = 8;
const open_link_interruption_retry_delay_ms = 1_000;
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
    expo_dev_client_open_link_mode: bool = false,

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

    pub fn launchWithArguments(self: *IosDevice, requested_app_id: ?[]const u8, arguments: []const scenario.LaunchArgument) !void {
        if (self.target_kind == .physical) return error.UnsupportedDeviceCapability;
        const app_id = requested_app_id orelse self.app_id;
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        var owned = std.ArrayList([]const u8).empty;
        defer {
            for (owned.items) |value| self.allocator.free(value);
            owned.deinit(self.allocator);
        }
        try argv.appendSlice(self.allocator, &.{ "launch", self.target(), app_id });
        for (arguments) |argument| {
            const name = try std.fmt.allocPrint(self.allocator, "--{s}", .{argument.name});
            try owned.append(self.allocator, name);
            try argv.append(self.allocator, name);
            const value = switch (argument.value) {
                .string => |actual| try self.allocator.dupe(u8, actual),
                .boolean => |actual| try self.allocator.dupe(u8, if (actual) "true" else "false"),
                .integer => |actual| try std.fmt.allocPrint(self.allocator, "{d}", .{actual}),
                .double => |actual| try std.fmt.allocPrint(self.allocator, "{d}", .{actual}),
            };
            try owned.append(self.allocator, value);
            try argv.append(self.allocator, value);
        }
        const result = try self.runSimctl(argv.items, default_max_output);
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

    pub fn killApp(self: *IosDevice) !void {
        return self.stop();
    }

    pub fn clearState(self: *IosDevice) !void {
        if (self.target_kind == .physical) return try self.uninstallPhysicalBestEffort();
        const result = try self.runSimctl(&.{ "uninstall", self.target(), self.app_id }, default_max_output);
        defer result.deinit(self.allocator);
        if (ios_lifecycle.isMissingInstalledApp(result)) return;
        try result.ensureSuccess();
    }

    pub fn clearKeychain(self: *IosDevice) !void {
        if (self.target_kind == .physical) return error.UnsupportedDeviceCapability;
        const result = try self.runSimctl(&.{ "keychain", self.target(), "reset" }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn openLink(self: *IosDevice, url: []const u8) !void {
        if (self.target_kind == .physical) return try self.launchPhysical(url);
        const result = try self.runSimctl(&.{ "openurl", self.target(), url }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        if (isExpoDevClientOpenLink(url)) {
            self.expo_dev_client_open_link_mode = true;
        }
        // Opening a URL on the simulator can raise a SpringBoard "Open in <App>?"
        // confirmation for universal links (http/https) and, just as often, for
        // custom schemes — the common Expo dev-client case
        // (exp+scheme://expo-development-client/...). Attempt a best-effort accept
        // whenever a shim is configured; the shim probes briefly and returns fast
        // when no dialog is present, so this stays cheap on the no-prompt path.
        self.acceptOpenURLConfirmationBestEffort(url);
    }

    pub fn setLocation(self: *IosDevice, latitude: f64, longitude: f64) !void {
        if (self.target_kind == .physical) return error.UnsupportedDeviceCapability;

        const coordinate = try std.fmt.allocPrint(self.allocator, "{d:.6},{d:.6}", .{ latitude, longitude });
        defer self.allocator.free(coordinate);

        const grant = try self.runSimctl(&.{ "privacy", self.target(), "grant", "location", self.app_id }, default_max_output);
        defer grant.deinit(self.allocator);
        try grant.ensureSuccess();

        const result = try self.runSimctl(&.{ "location", self.target(), "set", coordinate }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn grantPermissions(self: *IosDevice, permissions: [][]const u8) !void {
        if (self.target_kind == .physical) return error.UnsupportedDeviceCapability;
        for (permissions) |permission| {
            const result = try self.runSimctl(&.{ "privacy", self.target(), "grant", permission, self.app_id }, default_max_output);
            defer result.deinit(self.allocator);
            try result.ensureSuccess();
        }
    }

    pub fn setClipboard(self: *IosDevice, text: []const u8) !void {
        try self.runShimAction(.{ .kind = .set_clipboard, .text = text });
    }

    pub fn setOrientation(self: *IosDevice, orientation: scenario.Orientation) !void {
        try self.runShimAction(.{ .kind = .set_orientation, .text = @tagName(orientation) });
    }

    pub fn tap(self: *IosDevice, x: i32, y: i32) !void {
        try self.runShimAction(.{ .kind = .tap, .x = x, .y = y });
    }

    pub fn tapBySelector(self: *IosDevice, wanted: selector.Selector) !bool {
        return try self.runShimSelectorAction(.{ .kind = .tap }, wanted);
    }

    pub fn visibleBySelector(self: *IosDevice, wanted: selector.Selector) !?bool {
        return try self.visibleBySelectorWithTimeout(wanted, shimTimeoutMs());
    }

    pub fn visibleBySelectorWithTimeout(self: *IosDevice, wanted: selector.Selector, timeout_ms: u64) !?bool {
        if (self.shim_path == null) return null;
        const shim_selector = try ios_shim.selectorString(self.allocator, wanted) orelse return null;
        defer self.allocator.free(shim_selector);

        const response = try self.runShimWithTimeout(.{
            .kind = .query,
            .selector = shim_selector,
        }, @max(timeout_ms, 1));
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

    pub fn scrollViewport(self: *IosDevice) !types.Viewport {
        const response = try self.runShim(.{ .kind = .viewport });
        defer self.allocator.free(response);
        return try ios_shim.parseViewportResponse(response);
    }

    pub fn pressBack(self: *IosDevice) !void {
        try self.runShimAction(.{ .kind = .press_back });
    }

    pub fn pressKey(self: *IosDevice, key: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(key, "BACK")) return self.pressBack();
        if (std.ascii.eqlIgnoreCase(key, "ENTER") or std.ascii.eqlIgnoreCase(key, "RETURN")) {
            return self.typeText("\n");
        }
        return error.UnsupportedDeviceCapability;
    }

    pub fn settle(self: *IosDevice, timeout_ms: u64) !void {
        if (self.shim_path != null) {
            return try self.runShimAction(.{
                .kind = .settle,
                .duration_ms = @as(u32, @intCast(@min(timeout_ms, std.math.maxInt(u32)))),
            });
        }
        stdio.sleepNs(timeout_ms * std.time.ns_per_ms);
    }

    pub fn snapshot(self: *IosDevice, writer: ?*trace.TraceWriter) !types.ObservationSnapshot {
        const id = if (writer) |tw| try tw.nextSnapshotId() else try std.fmt.allocPrint(self.allocator, "snapshot-{d}", .{stdio.nowMs()});
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
        var shim_viewport: ?types.Viewport = null;
        const nodes = if (self.shim_path != null) blk: {
            if (writer) |tw| try self.recordSnapshotSemanticStarted(tw);
            const shim_snapshot = self.snapshotFromShim() catch |err| {
                if (screenshot_artifact == null) return err;
                if (writer) |tw| try self.recordSnapshotSemanticFailure(tw, screenshot_artifact.?, err);
                break :blk try self.allocator.alloc(types.UiNode, 0);
            };
            shim_viewport = shim_snapshot.viewport;
            break :blk shim_snapshot.nodes;
        } else try self.allocator.alloc(types.UiNode, 0);
        errdefer self.allocator.free(nodes);
        if (shim_viewport) |value| {
            if (value.width > 0 and value.height > 0) {
                viewport = value;
            }
        }

        return .{
            .id = id,
            .timestamp_ms = stdio.nowMs(),
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
        const path = try std.fmt.allocPrint(self.allocator, "/tmp/zmr-ios-screenshot-{d}.png", .{stdio.nowNs()});
        defer self.allocator.free(path);
        defer std.Io.Dir.cwd().deleteFile(stdio.io(), path) catch {};

        const result = try self.runSimctl(&.{ "io", self.target(), "screenshot", path }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return try stdio.readFileAlloc(self.allocator, path, default_max_output);
    }

    fn logDelta(self: *IosDevice) !?[]const u8 {
        if (self.target_kind == .physical) return null;
        const result = try self.runSimctl(&.{ "spawn", self.target(), "log", "show", "--style", "compact", "--last", "30s" }, 1024 * 1024);
        defer result.deinit(self.allocator);
        if (result.term != .exited or result.term.exited != 0) return null;
        return try self.allocator.dupe(u8, result.stdout);
    }

    fn snapshotFromShim(self: *IosDevice) !ios_shim.SnapshotResponse {
        const response = try self.runShim(.{ .kind = .snapshot });
        defer self.allocator.free(response);
        return try ios_shim.parseSnapshotResponse(self.allocator, response);
    }

    fn recordSnapshotSemanticStarted(self: *IosDevice, writer: *trace.TraceWriter) !void {
        try writer.recordEvent("observe.snapshot.semanticExtraction", "{\"status\":\"started\",\"source\":\"ios-xctest-shim\"}");
        _ = self;
    }

    fn recordSnapshotSemanticFailure(self: *IosDevice, writer: *trace.TraceWriter, screenshot_artifact: []const u8, err: anyerror) !void {
        var payload: std.Io.Writer.Allocating = .init(writer.allocator);
        defer payload.deinit();
        const out = &payload.writer;
        try out.writeAll("{\"status\":\"failed\",\"artifactStatus\":\"captured\",\"semanticStatus\":\"failed\",\"error\":");
        try trace.writeJsonString(out, @errorName(err));
        try out.writeAll(",\"screenshotArtifact\":");
        try trace.writeJsonString(out, screenshot_artifact);
        try out.writeAll(",\"source\":\"ios-xctest-shim\"}");
        try writer.recordEvent("observe.snapshot.semanticExtraction", out.buffered());
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

    fn acceptOpenURLConfirmationBestEffort(self: *IosDevice, url: []const u8) void {
        if (self.shim_path == null) return;
        var attempt: usize = 0;
        while (attempt < open_link_interruption_attempts) {
            attempt += 1;
            if (self.acceptOpenURLConfirmationOnce(url) catch return) return;
            if (attempt < open_link_interruption_attempts) {
                stdio.sleepNs(open_link_interruption_retry_delay_ms * std.time.ns_per_ms);
            }
        }
    }

    fn acceptOpenURLConfirmationOnce(self: *IosDevice, url: []const u8) !bool {
        const response = try self.runShimWithTimeout(.{
            .kind = .accept_system_alert,
            .text = "Open",
            .url = url,
            .expo_dev_client_fallback = self.expo_dev_client_open_link_mode,
        }, shim_best_effort_timeout_ms);
        defer self.allocator.free(response);
        return try ios_shim.parseAcceptSystemAlertResponse(response);
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
        return self.runShimWithTimeout(shim_command, shimTimeoutMs());
    }

    fn runShimWithTimeout(self: *IosDevice, shim_command: ios_shim.Command, timeout_ms: u64) ![]u8 {
        const path = self.shim_path orelse return error.IosXCTestShimRequired;

        var input: std.Io.Writer.Allocating = .init(self.allocator);
        defer input.deinit();
        try ios_shim.writeCommandJson(&input.writer, shim_command);

        var attempt: usize = 0;
        while (attempt < shim_command_attempts) {
            attempt += 1;
            const result = try command.runWithInputTimeout(self.allocator, &.{path}, input.writer.buffered(), 4 * 1024 * 1024, timeout_ms);
            defer result.deinit(self.allocator);

            result.ensureSuccess() catch |err| {
                if (attempt < shim_command_attempts and err == error.CommandFailed and isTransientShimBootstrapFailure(result)) {
                    stdio.sleepNs(shim_bootstrap_retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }
                return classifyShimCommandFailure(result);
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
        .exited => |code| if (code == 0) return false,
        else => return false,
    }
    return std.mem.indexOf(u8, result.stderr, "iOS shim server exited before it became ready") != null or
        std.mem.indexOf(u8, result.stderr, "Early unexpected exit") != null or
        std.mem.indexOf(u8, result.stderr, "operation never finished bootstrapping") != null;
}

fn classifyShimCommandFailure(result: command.ExecResult) anyerror {
    if (result.timed_out) return error.CommandTimedOut;
    if (std.mem.indexOf(u8, result.stderr, "timed out waiting for iOS shim response") != null) {
        return error.IosXCTestShimResponseTimedOut;
    }
    if (std.mem.indexOf(u8, result.stderr, "timed out waiting for iOS shim server readiness") != null) {
        return error.IosXCTestShimStartTimedOut;
    }
    if (std.mem.indexOf(u8, result.stderr, "timed out waiting for iOS shim build-for-testing") != null) {
        return error.IosXCTestShimBuildTimedOut;
    }
    if (std.mem.indexOf(u8, result.stderr, "iOS shim server exited before it became ready") != null or
        std.mem.indexOf(u8, result.stderr, "iOS shim server exited while waiting for response") != null or
        std.mem.indexOf(u8, result.stderr, "Early unexpected exit") != null or
        std.mem.indexOf(u8, result.stderr, "operation never finished bootstrapping") != null)
    {
        return error.IosXCTestShimServerExited;
    }
    return error.CommandFailed;
}

fn shimTimeoutMs() u64 {
    return parseShimTimeoutMs(stdio.getenv(shim_timeout_env));
}

fn parseShimTimeoutMs(raw: ?[]const u8) u64 {
    const value = raw orelse return default_shim_timeout_ms;
    const parsed = std.fmt.parseInt(u64, value, 10) catch return default_shim_timeout_ms;
    if (parsed == 0) return default_shim_timeout_ms;
    return parsed;
}

fn isExpoDevClientOpenLink(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "exp+") and
        std.mem.indexOf(u8, url, "://expo-development-client/") != null;
}

test "ios simulator openLink keeps sweeping delayed XCTest interruptions until accepted" {
    const allocator = std.heap.page_allocator;
    const argv = [_][*:0]const u8{"zmr-ios-test"};
    stdio.initProcess(.{
        .args = .{ .vector = argv[0..] },
        .environ = .empty,
    }, allocator);
    defer stdio.deinitProcess();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var shim = try tmp.dir.createFile(stdio.io(), "fake-ios-shim-delayed.sh", .{ .truncate = true });
    {
        var buffer: [4096]u8 = undefined;
        var writer = shim.writerStreaming(stdio.io(), &buffer);
        try writer.interface.writeAll(
            \\#!/usr/bin/env bash
            \\set -euo pipefail
            \\request="$(cat)"
        );
        const shim_tail = try std.fmt.allocPrint(allocator,
            \\
            \\printf '%s\n' "$request" >> ".zig-cache/tmp/{s}/shim.log"
            \\count_file=".zig-cache/tmp/{s}/count.txt"
            \\count=0
            \\if [[ -f "$count_file" ]]; then
            \\  count="$(cat "$count_file")"
            \\fi
            \\count=$((count + 1))
            \\printf '%s' "$count" > "$count_file"
            \\if [[ "$count" -lt 6 ]]; then
            \\  printf '{{"status":"ok","accepted":false,"count":0}}\n'
            \\else
            \\  printf '{{"status":"ok","accepted":true,"label":"Demo App","count":1}}\n'
            \\fi
            \\
        , .{ tmp.sub_path, tmp.sub_path });
        defer allocator.free(shim_tail);
        try writer.interface.writeAll(shim_tail);
        try writer.interface.flush();
    }
    shim.close(stdio.io());

    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-delayed.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);
    const shim_path_z = try allocator.dupeZ(u8, shim_path);
    defer allocator.free(shim_path_z);
    if (std.c.chmod(shim_path_z, 0o755) != 0) return error.ChmodFailed;

    var device = try IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();

    try device.openLink("exampleapp:///e2e-auth?probe=1");

    const count_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/count.txt", .{tmp.sub_path});
    defer allocator.free(count_path);
    const count_raw = try stdio.readFileAlloc(allocator, count_path, 1024);
    defer allocator.free(count_raw);
    const count = try std.fmt.parseInt(u8, count_raw, 10);
    try std.testing.expectEqual(@as(u8, 6), count);
}

test "ios simulator setLocation grants app location permission and sets coordinates" {
    const allocator = std.heap.page_allocator;
    const argv = [_][*:0]const u8{"zmr-ios-test"};
    stdio.initProcess(.{
        .args = .{ .vector = argv[0..] },
        .environ = .empty,
    }, allocator);
    defer stdio.deinitProcess();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var xcrun = try tmp.dir.createFile(stdio.io(), "fake-xcrun-location.sh", .{ .truncate = true });
    {
        var buffer: [4096]u8 = undefined;
        var writer = xcrun.writerStreaming(stdio.io(), &buffer);
        const script = try std.fmt.allocPrint(allocator,
            \\#!/usr/bin/env bash
            \\set -euo pipefail
            \\printf '%s\n' "$*" >> ".zig-cache/tmp/{s}/xcrun.log"
            \\if [[ "${{1:-}}" != "simctl" ]]; then
            \\  echo "expected simctl" >&2
            \\  exit 2
            \\fi
            \\shift
            \\case "${{1:-}}" in
            \\  privacy)
            \\    [[ "${{2:-}}" == "fake-ios-1" && "${{3:-}}" == "grant" && "${{4:-}}" == "location" && "${{5:-}}" == "com.example.mobiletest" ]] || exit 2
            \\    ;;
            \\  location)
            \\    [[ "${{2:-}}" == "fake-ios-1" && "${{3:-}}" == "set" && "${{4:-}}" == "51.507400,-0.127800" ]] || exit 2
            \\    ;;
            \\  *)
            \\    echo "unsupported simctl command: $*" >&2
            \\    exit 2
            \\    ;;
            \\esac
            \\
        , .{tmp.sub_path});
        defer allocator.free(script);
        try writer.interface.writeAll(script);
        try writer.interface.flush();
    }
    xcrun.close(stdio.io());

    const xcrun_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-xcrun-location.sh", .{tmp.sub_path});
    defer allocator.free(xcrun_path);
    const xcrun_path_z = try allocator.dupeZ(u8, xcrun_path);
    defer allocator.free(xcrun_path_z);
    if (std.c.chmod(xcrun_path_z, 0o755) != 0) return error.ChmodFailed;

    var device = try IosDevice.initWithShim(allocator, xcrun_path, "fake-ios-1", "com.example.mobiletest", null);
    defer device.deinit();

    try device.setLocation(51.5074, -0.1278);

    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/xcrun.log", .{tmp.sub_path});
    defer allocator.free(log_path);
    const log = try stdio.readFileAlloc(allocator, log_path, 1024);
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "simctl privacy fake-ios-1 grant location com.example.mobiletest") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "simctl location fake-ios-1 set 51.507400,-0.127800") != null);
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
    try std.testing.expect(default_shim_timeout_ms >= 5_400_000);
    try std.testing.expect(shim_best_effort_timeout_ms <= 15_000);
}

test "ios xctest shim timeout env override" {
    try std.testing.expectEqual(@as(u64, default_shim_timeout_ms), parseShimTimeoutMs(null));
    try std.testing.expectEqual(@as(u64, 600_000), parseShimTimeoutMs("600000"));
    try std.testing.expectEqual(@as(u64, default_shim_timeout_ms), parseShimTimeoutMs("not-a-number"));
    try std.testing.expectEqual(@as(u64, default_shim_timeout_ms), parseShimTimeoutMs("0"));
}

test "ios xctest shim command failures classify generated shim timeout causes" {
    try expectClassifiedShimFailure(error.IosXCTestShimResponseTimedOut, "timed out waiting for iOS shim response 12345\n");
    try expectClassifiedShimFailure(error.IosXCTestShimStartTimedOut, "timed out waiting for iOS shim server readiness\n");
    try expectClassifiedShimFailure(error.IosXCTestShimBuildTimedOut, "timed out waiting for iOS shim build-for-testing after 5400s\n");
    try expectClassifiedShimFailure(error.IosXCTestShimServerExited, "iOS shim server exited while waiting for response 12345\n");
    try expectClassifiedShimFailure(error.CommandFailed, "xcodebuild failed for another reason\n");
}

fn expectClassifiedShimFailure(expected: anyerror, stderr: []const u8) !void {
    const allocator = std.testing.allocator;
    const stdout_owned = try allocator.dupe(u8, "");
    defer allocator.free(stdout_owned);
    const stderr_owned = try allocator.dupe(u8, stderr);
    defer allocator.free(stderr_owned);
    const result = command.ExecResult{
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .term = .{ .exited = 1 },
    };
    try std.testing.expectEqual(expected, classifyShimCommandFailure(result));
}
