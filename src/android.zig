const std = @import("std");
const stdio = @import("stdio.zig");
const command = @import("command.zig");
const android_device_info = @import("android_device_info.zig");
const android_shell = @import("android_shell.zig");
const android_screen_recording = @import("android_screen_recording.zig");
const ios_shim = @import("ios_shim.zig");
const scenario = @import("scenario.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");
const uiautomator = @import("uiautomator.zig");

const default_max_output = 32 * 1024 * 1024;
const default_adb_timeout_ms = 15_000;
const install_adb_timeout_ms = 120_000;
const shim_timeout_ms = 5_000;
const open_link_attempts = 3;
const open_link_retry_delay_ms = 500;

pub const AndroidDevice = struct {
    allocator: std.mem.Allocator,
    adb_path: []const u8 = "adb",
    serial: ?[]const u8 = null,
    app_id: []const u8,
    shim_path: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        adb_path: []const u8,
        serial: ?[]const u8,
        app_id: []const u8,
    ) !AndroidDevice {
        return try initWithShim(allocator, adb_path, serial, app_id, null);
    }

    pub fn initWithShim(
        allocator: std.mem.Allocator,
        adb_path: []const u8,
        serial: ?[]const u8,
        app_id: []const u8,
        shim_path: ?[]const u8,
    ) !AndroidDevice {
        return .{
            .allocator = allocator,
            .adb_path = try allocator.dupe(u8, adb_path),
            .serial = try types.dupeOptional(allocator, serial),
            .app_id = try allocator.dupe(u8, app_id),
            .shim_path = try types.dupeOptional(allocator, shim_path),
        };
    }

    pub fn deinit(self: *AndroidDevice) void {
        self.allocator.free(self.adb_path);
        if (self.serial) |value| self.allocator.free(value);
        self.allocator.free(self.app_id);
        if (self.shim_path) |value| self.allocator.free(value);
    }

    pub fn listDevices(self: *AndroidDevice) ![]types.DeviceInfo {
        return try android_device_info.listDevices(self.allocator, self.adb_path);
    }

    pub fn install(self: *AndroidDevice, apk_path: []const u8) !void {
        const result = try self.runAdbWithTimeout(&.{ "install", "-r", apk_path }, default_max_output, install_adb_timeout_ms);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn launch(self: *AndroidDevice) !void {
        const result = try self.runAdb(&.{ "shell", "monkey", "-p", self.app_id, "-c", "android.intent.category.LAUNCHER", "1" }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn launchWithArguments(self: *AndroidDevice, requested_app_id: ?[]const u8, arguments: []const scenario.LaunchArgument) !void {
        if (self.shim_path != null) return error.UnsupportedDeviceCapability;
        const app_id = requested_app_id orelse self.app_id;
        if (arguments.len == 0) {
            const result = try self.runAdb(&.{ "shell", "monkey", "-p", app_id, "-c", "android.intent.category.LAUNCHER", "1" }, default_max_output);
            defer result.deinit(self.allocator);
            return result.ensureSuccess();
        }

        const resolved = try self.runAdb(&.{ "shell", "cmd", "package", "resolve-activity", "--brief", app_id }, default_max_output);
        defer resolved.deinit(self.allocator);
        try resolved.ensureSuccess();
        const activity = parseResolvedActivity(resolved.stdout) orelse return error.AppLaunchActivityNotFound;
        var args = try android_shell.launchWithArguments(self.allocator, activity, arguments);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn stop(self: *AndroidDevice) !void {
        const result = try self.runAdb(&.{ "shell", "am", "force-stop", self.app_id }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn killApp(self: *AndroidDevice) !void {
        return self.stop();
    }

    pub fn clearState(self: *AndroidDevice) !void {
        const result = try self.runAdb(&.{ "shell", "pm", "clear", self.app_id }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn clearKeychain(self: *AndroidDevice) !void {
        // Android has no separate app keychain reset primitive exposed by adb;
        // clearing app data is the closest deterministic equivalent.
        return self.clearState();
    }

    pub fn openLink(self: *AndroidDevice, url: []const u8) !void {
        var args = try android_shell.openLinkIntent(self.allocator, url, self.app_id);
        defer args.deinit();
        var attempt: usize = 0;
        while (attempt < open_link_attempts) : (attempt += 1) {
            const result = try self.runAdb(args.items(), default_max_output);
            defer result.deinit(self.allocator);
            try result.ensureSuccess();

            if (self.isAppForeground() catch false) return;
            if (attempt + 1 < open_link_attempts) {
                stdio.sleepNs(open_link_retry_delay_ms * std.time.ns_per_ms);
            }
        }
        return error.AppDidNotOpen;
    }

    pub fn setLocation(self: *AndroidDevice, latitude: f64, longitude: f64) !void {
        const latitude_arg = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{latitude});
        defer self.allocator.free(latitude_arg);
        const longitude_arg = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{longitude});
        defer self.allocator.free(longitude_arg);

        try self.grantRuntimePermissionBestEffort("android.permission.ACCESS_FINE_LOCATION");
        try self.grantRuntimePermissionBestEffort("android.permission.ACCESS_COARSE_LOCATION");

        const result = try self.runAdb(&.{ "emu", "geo", "fix", longitude_arg, latitude_arg }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn grantPermissions(self: *AndroidDevice, permissions: [][]const u8) !void {
        for (permissions) |permission| {
            const result = try self.runAdb(&.{ "shell", "pm", "grant", self.app_id, permission }, default_max_output);
            defer result.deinit(self.allocator);
            try result.ensureSuccess();
        }
    }

    pub fn setClipboard(self: *AndroidDevice, text: []const u8) !void {
        if (self.shim_path != null) return error.UnsupportedDeviceCapability;
        const result = try self.runAdb(&.{ "shell", "cmd", "clipboard", "set", "text", text }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn setOrientation(self: *AndroidDevice, orientation: scenario.Orientation) !void {
        if (self.shim_path != null) return error.UnsupportedDeviceCapability;
        const rotation: []const u8 = switch (orientation) {
            .portrait => "0",
            .landscape => "1",
        };
        const disabled = self.runAdb(&.{ "shell", "settings", "put", "system", "accelerometer_rotation", "0" }, default_max_output) catch |err| return err;
        defer disabled.deinit(self.allocator);
        try disabled.ensureSuccess();
        const result = try self.runAdb(&.{ "shell", "settings", "put", "system", "user_rotation", rotation }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn tap(self: *AndroidDevice, x: i32, y: i32) !void {
        if (self.shim_path != null) return try self.runShimAction(.{ .kind = .tap, .x = x, .y = y });
        var args = try android_shell.tap(self.allocator, x, y);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn typeText(self: *AndroidDevice, text: []const u8) !void {
        if (self.shim_path != null) return try self.runShimAction(.{ .kind = .type_text, .text = text });
        var args = try android_shell.typeText(self.allocator, text);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn eraseText(self: *AndroidDevice, max_chars: u32) !void {
        if (self.shim_path != null) return try self.runShimAction(.{ .kind = .erase_text, .max_chars = max_chars });
        var args = try android_shell.eraseText(self.allocator, max_chars);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn hideKeyboard(self: *AndroidDevice) !void {
        if (self.shim_path != null) return try self.runShimAction(.{ .kind = .hide_keyboard });
        var args = try android_shell.pressBack(self.allocator);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn swipe(self: *AndroidDevice, x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
        if (self.shim_path != null) return try self.runShimAction(.{ .kind = .swipe, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .duration_ms = duration_ms });
        var args = try android_shell.swipe(self.allocator, x1, y1, x2, y2, duration_ms);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn pressBack(self: *AndroidDevice) !void {
        if (self.shim_path != null) return try self.runShimAction(.{ .kind = .press_back });
        var args = try android_shell.pressBack(self.allocator);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn pressKey(self: *AndroidDevice, key: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(key, "BACK")) return self.pressBack();
        if (self.shim_path != null) return error.UnsupportedDeviceCapability;
        var args = try android_shell.pressKey(self.allocator, key);
        defer args.deinit();
        const result = try self.runAdb(args.items(), default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
    }

    pub fn startScreenRecording(self: *AndroidDevice, remote_path: []const u8) !AndroidScreenRecording {
        return try android_screen_recording.start(self.allocator, self.adb_path, self.serial, remote_path);
    }

    pub fn settle(self: *AndroidDevice, timeout_ms: u64) !void {
        if (self.shim_path != null) {
            return try self.runShimAction(.{
                .kind = .settle,
                .duration_ms = @as(u32, @intCast(@min(timeout_ms, std.math.maxInt(u32)))),
            });
        }
        stdio.sleepNs(timeout_ms * std.time.ns_per_ms);
    }

    pub fn snapshot(self: *AndroidDevice, writer: ?*trace.TraceWriter) !types.ObservationSnapshot {
        const id = if (writer) |tw| try tw.nextSnapshotId() else try std.fmt.allocPrint(self.allocator, "snapshot-{d}", .{stdio.nowMs()});
        errdefer self.allocator.free(id);

        const xml = if (self.shim_path == null) try self.dumpHierarchy() else null;
        defer if (xml) |value| self.allocator.free(value);
        const nodes = if (self.shim_path) |_|
            try self.snapshotNodesFromShim()
        else
            try uiautomator.parseHierarchy(self.allocator, xml.?);
        errdefer {
            for (nodes) |node| node.deinit(self.allocator);
            self.allocator.free(nodes);
        }

        var screenshot_artifact: ?[]const u8 = null;
        errdefer if (screenshot_artifact) |path| self.allocator.free(path);
        var tree_artifact: ?[]const u8 = null;
        errdefer if (tree_artifact) |path| self.allocator.free(path);

        if (writer) |tw| {
            if (tw.capture.capture_screenshots) {
                const screenshot = self.captureScreenshot() catch null;
                if (screenshot) |bytes| {
                    defer self.allocator.free(bytes);
                    const file_name = try std.fmt.allocPrint(self.allocator, "{s}.png", .{id});
                    defer self.allocator.free(file_name);
                    screenshot_artifact = try tw.writeArtifact(file_name, bytes);
                }
            }
            if (tw.capture.capture_hierarchy and xml != null) {
                const tree_name = try std.fmt.allocPrint(self.allocator, "{s}.xml", .{id});
                defer self.allocator.free(tree_name);
                tree_artifact = try tw.writeArtifact(tree_name, xml.?);
            }
        }

        const active = try self.activeWindow();
        errdefer active.deinit(self.allocator);

        const screen = self.viewport() catch types.Viewport{};
        const display_density_dpi = self.displayDensityDpi() catch null;
        const capture_logs = if (writer) |tw| tw.capture.capture_logs else true;
        const logs = if (capture_logs) self.logDelta() catch null else null;
        errdefer if (logs) |value| self.allocator.free(value);

        return .{
            .id = id,
            .timestamp_ms = stdio.nowMs(),
            .viewport = screen,
            .display_density_dpi = display_density_dpi,
            .active_package = active.package,
            .active_activity = active.activity,
            .screenshot_artifact = screenshot_artifact,
            .tree_artifact = tree_artifact,
            .focused_node_id = null,
            .log_delta = logs,
            .nodes = nodes,
        };
    }

    fn dumpHierarchy(self: *AndroidDevice) ![]u8 {
        const result = try self.runAdb(&.{ "exec-out", "uiautomator", "dump", "/dev/tty" }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return try self.allocator.dupe(u8, result.stdout);
    }

    fn captureScreenshot(self: *AndroidDevice) ![]u8 {
        const result = try self.runAdb(&.{ "exec-out", "screencap", "-p" }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return try self.allocator.dupe(u8, result.stdout);
    }

    fn activeWindow(self: *AndroidDevice) !ActiveWindow {
        const result = try self.runAdb(&.{ "shell", "dumpsys", "window" }, default_max_output);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return try android_device_info.parseActiveWindow(self.allocator, result.stdout);
    }

    fn isAppForeground(self: *AndroidDevice) !bool {
        const active = try self.activeWindow();
        defer active.deinit(self.allocator);
        const package = active.package orelse return false;
        return std.mem.eql(u8, package, self.app_id);
    }

    fn viewport(self: *AndroidDevice) !types.Viewport {
        const result = try self.runAdb(&.{ "shell", "wm", "size" }, 4096);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return android_device_info.parseViewport(result.stdout) catch types.Viewport{};
    }

    fn displayDensityDpi(self: *AndroidDevice) !?u32 {
        const result = try self.runAdb(&.{ "shell", "wm", "density" }, 4096);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return android_device_info.parseDisplayDensityDpi(result.stdout);
    }

    fn logDelta(self: *AndroidDevice) !?[]const u8 {
        const result = try self.runAdb(&.{ "logcat", "-d", "-t", "80" }, 1024 * 1024);
        defer result.deinit(self.allocator);
        if (result.term != .exited or result.term.exited != 0) return null;
        return try self.allocator.dupe(u8, result.stdout);
    }

    fn snapshotNodesFromShim(self: *AndroidDevice) ![]types.UiNode {
        const response = try self.runShim(.{ .kind = .snapshot });
        defer self.allocator.free(response);
        return try ios_shim.parseSnapshotNodes(self.allocator, response);
    }

    fn grantRuntimePermissionBestEffort(self: *AndroidDevice, permission: []const u8) !void {
        const result = self.runAdb(&.{ "shell", "pm", "grant", self.app_id, permission }, 64 * 1024) catch return;
        defer result.deinit(self.allocator);
        result.ensureSuccess() catch {};
    }

    fn runShimAction(self: *AndroidDevice, shim_command: ios_shim.Command) !void {
        const response = try self.runShim(shim_command);
        defer self.allocator.free(response);
        try ios_shim.parseOkResponse(response);
    }

    fn runShim(self: *AndroidDevice, shim_command: ios_shim.Command) ![]u8 {
        const path = self.shim_path orelse return error.AndroidShimRequired;

        var input: std.Io.Writer.Allocating = .init(self.allocator);
        defer input.deinit();
        try ios_shim.writeCommandJson(&input.writer, shim_command);

        const result = try command.runWithInputTimeout(self.allocator, &.{path}, input.writer.buffered(), 4 * 1024 * 1024, shim_timeout_ms);
        defer result.deinit(self.allocator);
        try result.ensureSuccess();
        return try self.allocator.dupe(u8, result.stdout);
    }

    fn runAdb(self: *AndroidDevice, extra: []const []const u8, max_output_bytes: usize) !command.ExecResult {
        return try self.runAdbWithTimeout(extra, max_output_bytes, default_adb_timeout_ms);
    }

    fn runAdbWithTimeout(self: *AndroidDevice, extra: []const []const u8, max_output_bytes: usize, timeout_ms: u64) !command.ExecResult {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        try self.appendAdbBase(&argv);
        try argv.appendSlice(self.allocator, extra);
        return try command.runWithTimeout(self.allocator, argv.items, max_output_bytes, timeout_ms);
    }

    fn appendAdbBase(self: *AndroidDevice, argv: *std.ArrayList([]const u8)) !void {
        try argv.append(self.allocator, self.adb_path);
        if (self.serial) |serial| {
            try argv.append(self.allocator, "-s");
            try argv.append(self.allocator, serial);
        }
    }
};

fn parseResolvedActivity(output: []const u8) ?[]const u8 {
    var activity: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "No activity")) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '/') != null) activity = trimmed;
    }
    return activity;
}

pub const AndroidScreenRecording = android_screen_recording.AndroidScreenRecording;

pub fn listDevices(allocator: std.mem.Allocator, adb_path: []const u8) ![]types.DeviceInfo {
    return try android_device_info.listDevices(allocator, adb_path);
}

pub const ActiveWindow = android_device_info.ActiveWindow;

pub fn parseActiveWindow(allocator: std.mem.Allocator, dumpsys: []const u8) !ActiveWindow {
    return try android_device_info.parseActiveWindow(allocator, dumpsys);
}

pub fn parseViewport(output: []const u8) !types.Viewport {
    return try android_device_info.parseViewport(output);
}

pub fn parseDisplayDensityDpi(output: []const u8) ?u32 {
    return android_device_info.parseDisplayDensityDpi(output);
}
