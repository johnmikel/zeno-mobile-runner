const std = @import("std");
const stdio = @import("stdio.zig");
const runner_actions = @import("runner_actions.zig");
const runner_config = @import("runner_config.zig");
const runner_events = @import("runner_events.zig");
const runner_waits = @import("runner_waits.zig");
const scenario = @import("scenario.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");
const fake_device = @import("fake_device.zig");

pub const RunOptions = runner_config.RunOptions;

pub fn runScenario(
    allocator: std.mem.Allocator,
    device: anytype,
    script: scenario.Scenario,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    if (writer) |tw| {
        try tw.startManifest(script.name, script.app_id);
        const payload = try runner_events.eventString(tw.allocator, script.name);
        defer tw.allocator.free(payload);
        try tw.recordEvent("scenario.start", payload);
    }
    for (script.steps, 0..) |step, index| {
        executeStep(allocator, device, step, writer, options) catch |err| {
            if (writer) |tw| {
                try runner_events.recordStepError(tw, index, err);
                try runner_events.recordScenarioEnd(tw, script.name, "failed", index, err);
                try tw.finishManifest(.{
                    .status = "failed",
                    .failed_step_index = index,
                    .error_name = @errorName(err),
                });
            }
            return err;
        };
        if (writer) |tw| {
            const payload = try std.fmt.allocPrint(tw.allocator, "{{\"index\":{d}}}", .{index});
            defer tw.allocator.free(payload);
            try tw.recordEvent("step.done", payload);
        }
    }
    if (writer) |tw| {
        try runner_events.recordScenarioEnd(tw, script.name, "passed", null, null);
        try tw.finishManifest(.{ .status = "passed" });
    }
}

pub fn executeStep(
    allocator: std.mem.Allocator,
    device: anytype,
    step: scenario.Step,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    switch (step) {
        .launch => {
            device.launch() catch |err| {
                if (writer) |tw| try runner_events.recordActionStatus(tw, "app.launch", "failed", err, null);
                return err;
            };
            if (writer) |tw| try runner_events.recordActionStatus(tw, "app.launch", "ok", null, null);
            try settleDevice(device, options);
        },
        .stop => try device.stop(),
        .clear_state => try device.clearState(),
        .snapshot => {
            var snap = try device.snapshot(writer);
            defer snap.deinit(device.allocator);
            if (writer) |tw| {
                const path = try tw.writeSnapshot(snap);
                defer tw.allocator.free(path);
                const payload = try runner_events.eventString(tw.allocator, path);
                defer tw.allocator.free(payload);
                try tw.recordEvent("observe.snapshot", payload);
            }
        },
        .open_link => |url| {
            device.openLink(url) catch |err| {
                if (writer) |tw| try runner_events.recordActionStatus(tw, "app.openLink", "failed", err, url);
                return err;
            };
            if (writer) |tw| try runner_events.recordActionStatus(tw, "app.openLink", "ok", null, url);
            try settleDevice(device, options);
        },
        .set_location => |location| {
            device.setLocation(location.latitude, location.longitude) catch |err| {
                if (writer) |tw| try runner_events.recordSetLocation(tw, "failed", err, location.latitude, location.longitude);
                return err;
            };
            if (writer) |tw| try runner_events.recordSetLocation(tw, "ok", null, location.latitude, location.longitude);
            try settleDevice(device, options);
        },
        .tap => |wanted| try tapSelector(device, wanted, writer, options),
        .type_text => |input| {
            if (input.selector) |wanted| return try typeTextSelector(device, wanted, input.text, writer, options);
            try device.typeText(input.text);
            try settleDevice(device, options);
        },
        .erase_text => |input| {
            if (input.selector) |wanted| return try eraseTextSelector(device, wanted, input.max_chars, writer, options);
            try device.eraseText(input.max_chars);
            if (writer) |tw| {
                const payload = try std.fmt.allocPrint(tw.allocator, "{{\"maxChars\":{d}}}", .{input.max_chars});
                defer tw.allocator.free(payload);
                try tw.recordEvent("ui.eraseText", payload);
            }
            try settleDevice(device, options);
        },
        .press_back => {
            try device.pressBack();
            if (writer) |tw| try tw.recordEvent("ui.pressBack", "{\"status\":\"ok\"}");
            try settleDevice(device, options);
        },
        .hide_keyboard => {
            try device.hideKeyboard();
            if (writer) |tw| try tw.recordEvent("ui.hideKeyboard", "{\"status\":\"ok\"}");
            try settleDevice(device, options);
        },
        .swipe => |swipe| {
            try device.swipe(swipe.x1, swipe.y1, swipe.x2, swipe.y2, swipe.duration_ms);
            if (writer) |tw| try runner_events.recordSwipe(tw, swipe.x1, swipe.y1, swipe.x2, swipe.y2, swipe.duration_ms);
            try settleDevice(device, options);
        },
        .wait_visible => |wait| {
            if (!try waitUntilVisible(device, wait.selector, wait.timeout_ms, writer, options)) return error.WaitTimeout;
        },
        .wait_not_visible => |wait| {
            if (!try waitUntilNotVisible(device, wait.selector, wait.timeout_ms, writer, options)) return error.WaitTimeout;
        },
        .wait_any => |wait| {
            if (try waitUntilAnyVisible(device, wait.selectors, wait.timeout_ms, writer, options) == null) return error.WaitTimeout;
        },
        .assert_visible => |assertion| {
            if (!try assertVisible(device, assertion.selector, assertion.timeout_ms orelse options.default_timeout_ms, writer, options)) return error.AssertionFailed;
        },
        .assert_not_visible => |assertion| {
            if (!try assertNotVisible(device, assertion.selector, assertion.timeout_ms orelse options.default_timeout_ms, writer, options)) return error.AssertionFailed;
        },
        .assert_none_visible => |assertion| {
            if (!try assertNoneVisible(device, assertion.selectors, assertion.timeout_ms, writer, options)) return error.AssertionFailed;
        },
        .assert_healthy_timeout_ms => |timeout_ms| {
            if (!try assertHealthy(device, timeout_ms, writer, options)) return error.AssertionFailed;
        },
        .optional => |inner| {
            executeStep(allocator, device, inner.*, writer, options) catch |err| {
                if (writer) |tw| {
                    const payload = try std.fmt.allocPrint(tw.allocator, "{{\"status\":\"skipped\",\"error\":\"{s}\"}}", .{@errorName(err)});
                    defer tw.allocator.free(payload);
                    try tw.recordEvent("step.optional", payload);
                }
            };
        },
        .when_visible => |block| {
            const visible = if (block.timeout_ms == 0)
                isVisibleNow(device, block.selector, writer) catch |err| {
                    if (writer) |tw| try runner_events.recordSelectorEventWithError(tw, "step.whenVisible.skipped", block.selector, err);
                    return;
                }
            else
                waitUntilVisible(device, block.selector, block.timeout_ms, writer, options) catch |err| {
                    if (writer) |tw| try runner_events.recordSelectorEventWithError(tw, "step.whenVisible.skipped", block.selector, err);
                    return;
                };
            if (visible) {
                for (block.steps) |inner| try executeStep(allocator, device, inner, writer, options);
            } else if (writer) |tw| {
                try runner_events.recordSelectorEvent(tw, "step.whenVisible.skipped", block.selector);
            }
        },
        .repeat => |block| {
            var iteration: u32 = 0;
            while (iteration < block.times) : (iteration += 1) {
                if (writer) |tw| {
                    const payload = try std.fmt.allocPrint(tw.allocator, "{{\"iteration\":{d},\"times\":{d}}}", .{ iteration + 1, block.times });
                    defer tw.allocator.free(payload);
                    try tw.recordEvent("step.repeat.iteration", payload);
                }
                for (block.steps) |inner| try executeStep(allocator, device, inner, writer, options);
            }
        },
        .scroll_until_visible => |scroll| {
            if (!try scrollUntilVisible(device, scroll.selector, scroll.timeout_ms, scroll.direction, writer, options)) return error.WaitTimeout;
        },
        .sleep_ms => |ms| try sleepMs(ms),
    }
}

pub fn tapSelector(
    device: anytype,
    wanted: selector.Selector,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    return try runner_actions.tapSelector(device, wanted, writer, options);
}

pub fn typeTextSelector(
    device: anytype,
    wanted: selector.Selector,
    text: []const u8,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    return try runner_actions.typeTextSelector(device, wanted, text, writer, options);
}

pub fn eraseTextSelector(
    device: anytype,
    wanted: selector.Selector,
    max_chars: u32,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    return try runner_actions.eraseTextSelector(device, wanted, max_chars, writer, options);
}

pub fn waitUntilVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try runner_waits.waitUntilVisible(device, wanted, timeout_ms, writer, options);
}

pub fn waitUntilNotVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try runner_waits.waitUntilNotVisible(device, wanted, timeout_ms, writer, options);
}

pub fn waitUntilAnyVisible(
    device: anytype,
    selectors: []const selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !?usize {
    return try runner_waits.waitUntilAnyVisible(device, selectors, timeout_ms, writer, options);
}

pub fn assertVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try runner_waits.assertVisible(device, wanted, timeout_ms, writer, options);
}

pub fn assertNotVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try runner_waits.assertNotVisible(device, wanted, timeout_ms, writer, options);
}

pub fn assertNoneVisible(
    device: anytype,
    selectors: []const selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try runner_waits.assertNoneVisible(device, selectors, timeout_ms, writer, options);
}

pub fn assertHealthy(
    device: anytype,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try runner_waits.assertHealthy(device, timeout_ms, writer, options);
}

pub fn scrollUntilVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    direction: scenario.ScrollDirection,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try runner_waits.scrollUntilVisible(device, wanted, timeout_ms, direction, writer, options);
}

fn isVisibleNow(
    device: anytype,
    wanted: selector.Selector,
    writer: ?*trace.TraceWriter,
) !bool {
    var snap = try device.snapshot(writer);
    defer snap.deinit(device.allocator);
    return selector.find(snap.nodes, wanted) != null;
}

fn sleepMs(ms: u64) !void {
    stdio.sleepNs(ms * std.time.ns_per_ms);
}

fn settleDevice(device: anytype, options: RunOptions) !void {
    try device.settle(options.settle_ms);
}

test "setLocation dispatches through the device, records trace evidence, and settles" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-set-location";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const script_json =
        \\{
        \\  "name": "set location",
        \\  "steps": [
        \\    {"action": "setLocation", "latitude": 51.5074, "longitude": -0.1278}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    var device = fake_device.FakeDevice.init(allocator, &.{});
    defer device.deinit();
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try runScenario(allocator, &device, script, &tw, .{ .settle_ms = 25 });

    try std.testing.expectEqual(@as(usize, 1), device.location_sets);
    try std.testing.expectApproxEqAbs(@as(f64, 51.5074), device.last_location.?.latitude, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1278), device.last_location.?.longitude, 0.000001);
    try std.testing.expectEqual(@as(usize, 1), device.settles);
    try std.testing.expectEqual(@as(u64, 25), device.last_settle_timeout_ms);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"device.setLocation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"latitude\":51.5074") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"longitude\":-0.1278") != null);
}

test "whenVisible skips the conditional block when the visibility probe command fails" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-when-visible-command-failed";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const ProbeFailureDevice = struct {
        allocator: std.mem.Allocator,
        typed: usize = 0,

        pub fn launch(self: *@This()) !void {
            _ = self;
        }

        pub fn stop(self: *@This()) !void {
            _ = self;
        }

        pub fn clearState(self: *@This()) !void {
            _ = self;
        }

        pub fn openLink(self: *@This(), url: []const u8) !void {
            _ = self;
            _ = url;
        }

        pub fn setLocation(self: *@This(), latitude: f64, longitude: f64) !void {
            _ = self;
            _ = latitude;
            _ = longitude;
        }

        pub fn tap(self: *@This(), x: i32, y: i32) !void {
            _ = self;
            _ = x;
            _ = y;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = self;
            _ = writer;
            return error.CommandFailed;
        }

        pub fn typeText(self: *@This(), text: []const u8) !void {
            _ = text;
            self.typed += 1;
        }

        pub fn eraseText(self: *@This(), max_chars: u32) !void {
            _ = self;
            _ = max_chars;
        }

        pub fn pressBack(self: *@This()) !void {
            _ = self;
        }

        pub fn hideKeyboard(self: *@This()) !void {
            _ = self;
        }

        pub fn swipe(self: *@This(), x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
            _ = self;
            _ = x1;
            _ = y1;
            _ = x2;
            _ = y2;
            _ = duration_ms;
        }

        pub fn settle(self: *@This(), ms: u64) !void {
            _ = self;
            _ = ms;
        }
    };

    const script_json =
        \\{
        \\  "name": "conditional probe failure",
        \\  "steps": [
        \\    {"action": "whenVisible", "selector": {"text": "Deep link received:"}, "steps": [
        \\      {"action": "typeText", "text": "not-run"}
        \\    ]}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    var device = ProbeFailureDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try runScenario(allocator, &device, script, &tw, .{ .settle_ms = 0 });

    try std.testing.expectEqual(@as(usize, 0), device.typed);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"step.whenVisible.skipped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"CommandFailed\"") != null);
}

test "assertHealthy retries through a transient observation command failure" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-healthy-command-failed";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const FlakyHealthDevice = struct {
        allocator: std.mem.Allocator,
        snapshots: usize = 0,

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            if (self.snapshots == 1) return error.CommandFailed;

            const nodes = try self.allocator.alloc(types.UiNode, 1);
            nodes[0] = .{
                .stable_id = try self.allocator.dupe(u8, "node-ready"),
                .class_name = try self.allocator.dupe(u8, "android.widget.TextView"),
                .text = try self.allocator.dupe(u8, "Probe mode"),
            };
            return .{
                .id = try self.allocator.dupe(u8, "snapshot-ready"),
                .timestamp_ms = 1,
                .nodes = nodes,
            };
        }
    };

    var device = FlakyHealthDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try assertHealthy(&device, 100, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 2), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.retry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"CommandFailed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"ok\"") != null);
}

test "assertHealthy retries native probes after a transient native health probe failure" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-healthy-native-probe-command-failed";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const NativeFlakyProbeHealthDevice = struct {
        allocator: std.mem.Allocator,
        native_queries: usize = 0,
        snapshots: usize = 0,

        pub fn visibleBySelectorWithTimeout(self: *@This(), wanted: selector.Selector, timeout_ms: u64) !?bool {
            _ = wanted;
            _ = timeout_ms;
            self.native_queries += 1;
            if (self.native_queries == 1) return error.CommandTimedOut;
            return false;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeFlakyProbeHealthDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try assertHealthy(&device, 100, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expect(device.native_queries > 1);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.retry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"CommandTimedOut\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
}

test "assertHealthy gives native health probes a practical XCTest query budget" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-healthy-native-probe-xctest-budget";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const NativeXCTestBudgetHealthDevice = struct {
        allocator: std.mem.Allocator,
        native_queries: usize = 0,
        largest_query_timeout_ms: u64 = 0,
        snapshots: usize = 0,

        pub fn visibleBySelectorWithTimeout(self: *@This(), wanted: selector.Selector, timeout_ms: u64) !?bool {
            _ = wanted;
            self.native_queries += 1;
            self.largest_query_timeout_ms = @max(self.largest_query_timeout_ms, timeout_ms);
            if (timeout_ms < 1000) return error.CommandTimedOut;
            return false;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeXCTestBudgetHealthDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try assertHealthy(&device, 5000, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expect(device.native_queries > 0);
    try std.testing.expect(device.largest_query_timeout_ms >= 1000);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);
}

test "native selector waits pass bounded query timeouts instead of legacy blocking queries" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-wait-bounded-query-timeout";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const NativeBoundedWaitDevice = struct {
        allocator: std.mem.Allocator,
        legacy_queries: usize = 0,
        bounded_queries: usize = 0,
        largest_query_timeout_ms: u64 = 0,
        snapshots: usize = 0,

        pub fn visibleBySelector(self: *@This(), wanted: selector.Selector) !?bool {
            _ = wanted;
            self.legacy_queries += 1;
            return false;
        }

        pub fn visibleBySelectorWithTimeout(self: *@This(), wanted: selector.Selector, timeout_ms: u64) !?bool {
            _ = wanted;
            self.bounded_queries += 1;
            self.largest_query_timeout_ms = @max(self.largest_query_timeout_ms, timeout_ms);
            return false;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            const nodes = try self.allocator.alloc(types.UiNode, 0);
            return .{
                .id = try self.allocator.dupe(u8, "native-bounded-timeout-final"),
                .timestamp_ms = 1,
                .nodes = nodes,
            };
        }
    };

    var device = NativeBoundedWaitDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(!try waitUntilVisible(&device, .{ .id = "never-visible" }, 25, &tw, .{ .poll_ms = 0 }));
    try std.testing.expect(device.bounded_queries > 0);
    try std.testing.expectEqual(@as(usize, 0), device.legacy_queries);
    try std.testing.expect(device.largest_query_timeout_ms > 0);
    try std.testing.expect(device.largest_query_timeout_ms <= 25);
    try std.testing.expectEqual(@as(usize, 1), device.snapshots);
}

test "native selector wait retries bounded query command timeouts before falling back" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-wait-retries-bounded-query-timeout";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const NativeFlakyBoundedWaitDevice = struct {
        allocator: std.mem.Allocator,
        legacy_queries: usize = 0,
        bounded_queries: usize = 0,
        snapshots: usize = 0,

        pub fn visibleBySelector(self: *@This(), wanted: selector.Selector) !?bool {
            _ = wanted;
            self.legacy_queries += 1;
            return error.LegacyNativeQueryUsed;
        }

        pub fn visibleBySelectorWithTimeout(self: *@This(), wanted: selector.Selector, timeout_ms: u64) !?bool {
            _ = wanted;
            try std.testing.expect(timeout_ms > 0);
            self.bounded_queries += 1;
            if (self.bounded_queries == 1) return error.CommandTimedOut;
            return true;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeFlakyBoundedWaitDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try waitUntilVisible(&device, .{ .text = "Ready" }, 100, &tw, .{ .poll_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 0), device.legacy_queries);
    try std.testing.expectEqual(@as(usize, 2), device.bounded_queries);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.retry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"CommandTimedOut\"") != null);
}

test "assertHealthy uses native selector probes before broad snapshots" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-healthy-native-selector";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const NativeHealthDevice = struct {
        allocator: std.mem.Allocator,
        queries: usize = 0,
        snapshots: usize = 0,

        pub fn visibleBySelector(self: *@This(), wanted: selector.Selector) !?bool {
            _ = wanted;
            self.queries += 1;
            return false;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeHealthDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try assertHealthy(&device, 100, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expect(device.queries > 0);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
}

test "assertHealthy bounds each native selector probe independently" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-healthy-native-probe-budget";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const NativeSlowAbsentHealthDevice = struct {
        allocator: std.mem.Allocator,
        bounded_queries: usize = 0,
        largest_query_timeout_ms: u64 = 0,
        snapshots: usize = 0,

        pub fn visibleBySelectorWithTimeout(self: *@This(), wanted: selector.Selector, timeout_ms: u64) !?bool {
            _ = wanted;
            self.bounded_queries += 1;
            self.largest_query_timeout_ms = @max(self.largest_query_timeout_ms, timeout_ms);
            if (timeout_ms > 0) stdio.sleepNs(timeout_ms * std.time.ns_per_ms);
            return false;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeSlowAbsentHealthDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try assertHealthy(&device, 250, &tw, .{ .settle_ms = 0, .poll_ms = 0, .action_timeout_ms = 1 }));
    try std.testing.expect(device.bounded_queries > 1);
    try std.testing.expect(device.largest_query_timeout_ms <= 1);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
}

test "assertHealthy reports unhealthy native selector matches" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-healthy-native-unhealthy";
    std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(stdio.io(), dir) catch {};

    const NativeUnhealthyDevice = struct {
        allocator: std.mem.Allocator,
        queries: usize = 0,
        snapshots: usize = 0,

        pub fn visibleBySelector(self: *@This(), wanted: selector.Selector) !?bool {
            self.queries += 1;
            if (wanted.text_contains) |text| return std.mem.eql(u8, text, "ReferenceError");
            return false;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeUnhealthyDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(!try assertHealthy(&device, 100, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expect(device.queries > 0);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try stdio.readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"unhealthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"matchedIndex\"") != null);
}
