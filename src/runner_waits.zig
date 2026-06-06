const std = @import("std");
const health = @import("health.zig");
const runner_config = @import("runner_config.zig");
const runner_events = @import("runner_events.zig");
const runner_native = @import("runner_native.zig");
const scenario = @import("scenario.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");

const RunOptions = runner_config.RunOptions;

pub fn waitUntilVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (try nativeVisibleBySelector(device, wanted)) |visible| {
            if (visible) {
                if (writer) |tw| try runner_events.recordNativeWait(tw, "wait.visible", wanted, null);
                return true;
            }
            if (std.time.milliTimestamp() >= deadline) {
                if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, "wait.visible", &[_]selector.Selector{wanted});
                return false;
            }
            try sleepMs(options.poll_ms);
            continue;
        }
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "wait.visible", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);
        if (selector.find(snap.nodes, wanted)) |node| {
            if (writer) |tw| {
                var payload = std.ArrayList(u8).empty;
                defer payload.deinit(tw.allocator);
                try payload.writer(tw.allocator).print("{{\"status\":\"ok\",\"target\":\"{s}\",\"selector\":", .{node.stable_id});
                try trace.writeSelectorJson(payload.writer(tw.allocator), wanted);
                try payload.writer(tw.allocator).print(",\"timeoutMs\":{d}}}", .{timeout_ms});
                try tw.recordEvent("wait.visible", payload.items);
            }
            return true;
        }
        if (std.time.milliTimestamp() >= deadline) {
            if (writer) |tw| {
                const selectors = [_]selector.Selector{wanted};
                try runner_events.recordWaitTimeout(tw, "wait.visible", selectors[0..], snap);
            }
            return false;
        }
        try sleepMs(options.poll_ms);
    }
}

pub fn waitUntilNotVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (try nativeVisibleBySelector(device, wanted)) |visible| {
            if (!visible) {
                if (writer) |tw| try runner_events.recordNativeWait(tw, "wait.notVisible", wanted, null);
                return true;
            }
            if (std.time.milliTimestamp() >= deadline) {
                if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, "wait.notVisible", &[_]selector.Selector{wanted});
                return false;
            }
            try sleepMs(options.poll_ms);
            continue;
        }
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "wait.notVisible", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);
        if (selector.find(snap.nodes, wanted) == null) {
            if (writer) |tw| {
                var payload = std.ArrayList(u8).empty;
                defer payload.deinit(tw.allocator);
                try payload.writer(tw.allocator).writeAll("{\"status\":\"ok\",\"selector\":");
                try trace.writeSelectorJson(payload.writer(tw.allocator), wanted);
                try payload.writer(tw.allocator).print(",\"timeoutMs\":{d}}}", .{timeout_ms});
                try tw.recordEvent("wait.notVisible", payload.items);
            }
            return true;
        }
        if (std.time.milliTimestamp() >= deadline) {
            if (writer) |tw| {
                const selectors = [_]selector.Selector{wanted};
                try runner_events.recordWaitTimeout(tw, "wait.notVisible", selectors[0..], snap);
            }
            return false;
        }
        try sleepMs(options.poll_ms);
    }
}

pub fn waitUntilAnyVisible(
    device: anytype,
    selectors: []const selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !?usize {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        var all_native = true;
        for (selectors, 0..) |wanted, index| {
            if (try nativeVisibleBySelector(device, wanted)) |visible| {
                if (visible) {
                    if (writer) |tw| try runner_events.recordNativeWait(tw, "wait.any", wanted, index);
                    return index;
                }
            } else {
                all_native = false;
                break;
            }
        }
        if (all_native) {
            if (std.time.milliTimestamp() >= deadline) {
                if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, "wait.any", selectors);
                return null;
            }
            try sleepMs(options.poll_ms);
            continue;
        }
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "wait.any", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);
        for (selectors, 0..) |wanted, index| {
            if (selector.find(snap.nodes, wanted)) |node| {
                if (writer) |tw| {
                    var payload = std.ArrayList(u8).empty;
                    defer payload.deinit(tw.allocator);
                    try payload.writer(tw.allocator).print("{{\"status\":\"ok\",\"matchedIndex\":{d},\"target\":\"{s}\",\"selector\":", .{ index, node.stable_id });
                    try trace.writeSelectorJson(payload.writer(tw.allocator), wanted);
                    try payload.writer(tw.allocator).print(",\"timeoutMs\":{d}}}", .{timeout_ms});
                    try tw.recordEvent("wait.any", payload.items);
                }
                return index;
            }
        }
        if (std.time.milliTimestamp() >= deadline) {
            if (writer) |tw| try runner_events.recordWaitTimeout(tw, "wait.any", selectors, snap);
            return null;
        }
        try sleepMs(options.poll_ms);
    }
}

pub fn assertNoneVisible(
    device: anytype,
    selectors: []const selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "assert.noneVisible", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);

        var matched = false;
        for (selectors) |wanted| {
            if (selector.find(snap.nodes, wanted) != null) {
                matched = true;
                break;
            }
        }

        if (!matched) {
            if (writer) |tw| try tw.recordEvent("assert.noneVisible", "{\"status\":\"ok\"}");
            return true;
        }

        if (std.time.milliTimestamp() >= deadline) {
            if (writer) |tw| try runner_events.recordDiagnostic(tw, "assert.noneVisible", "visible", selectors, snap);
            return false;
        }

        try sleepMs(options.poll_ms);
    }
}

pub fn assertHealthy(
    device: anytype,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    const health_selectors = health.defaultSelectors();
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "assert.healthy", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);

        if (!health.hasUnhealthyOverlay(snap.nodes)) {
            if (writer) |tw| try tw.recordEvent("assert.healthy", "{\"status\":\"ok\"}");
            return true;
        }

        if (std.time.milliTimestamp() >= deadline) {
            if (writer) |tw| try runner_events.recordDiagnostic(tw, "assert.healthy", "unhealthy", health_selectors, snap);
            return false;
        }

        try sleepMs(options.poll_ms);
    }
}

pub fn scrollUntilVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    direction: scenario.ScrollDirection,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "ui.scrollUntilVisible", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);
        if (selector.find(snap.nodes, wanted)) |node| {
            if (writer) |tw| {
                var payload = std.ArrayList(u8).empty;
                defer payload.deinit(tw.allocator);
                try payload.writer(tw.allocator).print("{{\"status\":\"ok\",\"target\":\"{s}\",\"selector\":", .{node.stable_id});
                try trace.writeSelectorJson(payload.writer(tw.allocator), wanted);
                try payload.writer(tw.allocator).print(",\"direction\":\"{s}\",\"timeoutMs\":{d}}}", .{
                    if (direction == .down) "down" else "up",
                    timeout_ms,
                });
                try tw.recordEvent("ui.scrollUntilVisible", payload.items);
            }
            return true;
        }
        if (std.time.milliTimestamp() >= deadline) {
            if (writer) |tw| {
                const selectors = [_]selector.Selector{wanted};
                try runner_events.recordWaitTimeout(tw, "ui.scrollUntilVisible", selectors[0..], snap);
            }
            return false;
        }

        const width = if (snap.viewport.width == 0) @as(i32, 720) else @as(i32, @intCast(snap.viewport.width));
        const height = if (snap.viewport.height == 0) @as(i32, 1280) else @as(i32, @intCast(snap.viewport.height));
        const x = @divTrunc(width, 2);
        const start_y = switch (direction) {
            .down => @divTrunc(height * 4, 5),
            .up => @divTrunc(height * 3, 10),
        };
        const end_y = switch (direction) {
            .down => @divTrunc(height * 3, 10),
            .up => @divTrunc(height * 4, 5),
        };
        try device.swipe(x, start_y, x, end_y, 350);
        if (writer) |tw| {
            const payload = try std.fmt.allocPrint(tw.allocator, "{{\"direction\":\"{s}\",\"x\":{d},\"y1\":{d},\"y2\":{d}}}", .{
                if (direction == .down) "down" else "up",
                x,
                start_y,
                end_y,
            });
            defer tw.allocator.free(payload);
            try tw.recordEvent("ui.scroll", payload);
        }
        try settleDevice(device, options);
    }
}

fn nativeVisibleBySelector(device: anytype, wanted: selector.Selector) !?bool {
    if (!@hasDecl(@TypeOf(device.*), "visibleBySelector")) return null;
    return try device.visibleBySelector(wanted);
}

fn retryTransientObservation(
    err: anyerror,
    kind: []const u8,
    writer: ?*trace.TraceWriter,
    deadline: i64,
    options: RunOptions,
) !bool {
    if (err != error.CommandTimedOut) return false;
    if (std.time.milliTimestamp() >= deadline) return false;
    if (writer) |tw| try runner_events.recordObservationRetry(tw, kind, err);
    try sleepMs(options.poll_ms);
    return true;
}

fn settleDevice(device: anytype, options: RunOptions) !void {
    try device.settle(options.settle_ms);
}

fn sleepMs(ms: u64) !void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}
