const std = @import("std");
const runner_actions = @import("runner_actions.zig");
const runner_config = @import("runner_config.zig");
const runner_events = @import("runner_events.zig");
const runner_waits = @import("runner_waits.zig");
const scenario = @import("scenario.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");

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
        .assert_visible => |wanted| {
            if (!try waitUntilVisible(device, wanted, options.default_timeout_ms, writer, options)) return error.AssertionFailed;
        },
        .assert_not_visible => |wanted| {
            if (!try waitUntilNotVisible(device, wanted, options.default_timeout_ms, writer, options)) return error.AssertionFailed;
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
                try isVisibleNow(device, block.selector, writer)
            else
                try waitUntilVisible(device, block.selector, block.timeout_ms, writer, options);
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
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

fn settleDevice(device: anytype, options: RunOptions) !void {
    try device.settle(options.settle_ms);
}
