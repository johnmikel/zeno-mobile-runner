const std = @import("std");
const stdio = @import("stdio.zig");
const health = @import("health.zig");
const runner_config = @import("runner_config.zig");
const runner_events = @import("runner_events.zig");
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
    return try untilVisibleKind(device, wanted, timeout_ms, writer, options, "wait.visible");
}

pub fn assertVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try untilVisibleKind(device, wanted, timeout_ms, writer, options, "assert.visible");
}

fn untilVisibleKind(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
    kind: []const u8,
) !bool {
    const deadline = stdio.nowMs() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (nativeSelectorQueryTimeoutMs(deadline)) |query_timeout_ms| {
            const native_result = nativeVisibleBySelector(device, wanted, query_timeout_ms) catch |err| {
                if (try retryTransientObservation(err, kind, writer, deadline, options)) continue;
                return err;
            };
            if (native_result) |visible| {
                if (visible) {
                    if (writer) |tw| try runner_events.recordNativeWait(tw, kind, wanted, null, timeout_ms);
                    return true;
                }
                if (stdio.nowMs() >= deadline) {
                    if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, kind, &[_]selector.Selector{wanted}, timeout_ms);
                    return false;
                }
                try sleepMs(options.poll_ms);
                continue;
            }
        } else if (hasNativeSelectorQuery(device)) {
            if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, kind, &[_]selector.Selector{wanted}, timeout_ms);
            return false;
        }

        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, kind, writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);
        if (selector.find(snap.nodes, wanted)) |node| {
            if (writer) |tw| {
                var payload: std.Io.Writer.Allocating = .init(tw.allocator);
                defer payload.deinit();
                const out = &payload.writer;
                try out.print("{{\"status\":\"ok\",\"target\":\"{s}\",\"selector\":", .{node.stable_id});
                try trace.writeSelectorJson(out, wanted);
                try out.print(",\"timeoutMs\":{d}}}", .{timeout_ms});
                try tw.recordEvent(kind, out.buffered());
            }
            return true;
        }
        if (stdio.nowMs() >= deadline) {
            if (writer) |tw| {
                const selectors = [_]selector.Selector{wanted};
                try runner_events.recordDiagnosticWithStrategyAndTimeout(tw, kind, "timeout", null, selectors[0..], snap, timeout_ms);
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
    return try untilNotVisibleKind(device, wanted, timeout_ms, writer, options, "wait.notVisible");
}

pub fn assertNotVisible(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !bool {
    return try untilNotVisibleKind(device, wanted, timeout_ms, writer, options, "assert.notVisible");
}

fn untilNotVisibleKind(
    device: anytype,
    wanted: selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
    kind: []const u8,
) !bool {
    const deadline = stdio.nowMs() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (nativeSelectorQueryTimeoutMs(deadline)) |query_timeout_ms| {
            const native_result = nativeVisibleBySelector(device, wanted, query_timeout_ms) catch |err| {
                if (try retryTransientObservation(err, kind, writer, deadline, options)) continue;
                return err;
            };
            if (native_result) |visible| {
                if (!visible) {
                    if (writer) |tw| try runner_events.recordNativeWait(tw, kind, wanted, null, timeout_ms);
                    return true;
                }
                if (stdio.nowMs() >= deadline) {
                    if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, kind, &[_]selector.Selector{wanted}, timeout_ms);
                    return false;
                }
                try sleepMs(options.poll_ms);
                continue;
            }
        } else if (hasNativeSelectorQuery(device)) {
            if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, kind, &[_]selector.Selector{wanted}, timeout_ms);
            return false;
        }

        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, kind, writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);
        if (selector.find(snap.nodes, wanted) == null) {
            if (writer) |tw| {
                var payload: std.Io.Writer.Allocating = .init(tw.allocator);
                defer payload.deinit();
                const out = &payload.writer;
                try out.writeAll("{\"status\":\"ok\",\"selector\":");
                try trace.writeSelectorJson(out, wanted);
                try out.print(",\"timeoutMs\":{d}}}", .{timeout_ms});
                try tw.recordEvent(kind, out.buffered());
            }
            return true;
        }
        if (stdio.nowMs() >= deadline) {
            if (writer) |tw| {
                const selectors = [_]selector.Selector{wanted};
                try runner_events.recordDiagnosticWithStrategyAndTimeout(tw, kind, "timeout", null, selectors[0..], snap, timeout_ms);
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
    const deadline = stdio.nowMs() + @as(i64, @intCast(timeout_ms));
    while (true) {
        var all_native = true;
        for (selectors, 0..) |wanted, index| {
            const query_timeout_ms = nativeSelectorQueryTimeoutMs(deadline) orelse {
                if (hasNativeSelectorQuery(device)) {
                    if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, "wait.any", selectors, timeout_ms);
                    return null;
                }
                all_native = false;
                break;
            };
            const native_result = nativeVisibleBySelector(device, wanted, query_timeout_ms) catch |err| {
                if (try retryTransientObservation(err, "wait.any", writer, deadline, options)) continue;
                return err;
            };
            if (native_result) |visible| {
                if (visible) {
                    if (writer) |tw| try runner_events.recordNativeWait(tw, "wait.any", wanted, index, timeout_ms);
                    return index;
                }
            } else {
                all_native = false;
                break;
            }
        }

        if (all_native) {
            if (stdio.nowMs() >= deadline) {
                if (writer) |tw| try runner_events.recordNativeWaitTimeoutWithDiagnostics(device, tw, "wait.any", selectors, timeout_ms);
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
                    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
                    defer payload.deinit();
                    const out = &payload.writer;
                    try out.print("{{\"status\":\"ok\",\"matchedIndex\":{d},\"target\":\"{s}\",\"selector\":", .{ index, node.stable_id });
                    try trace.writeSelectorJson(out, wanted);
                    try out.print(",\"timeoutMs\":{d}}}", .{timeout_ms});
                    try tw.recordEvent("wait.any", out.buffered());
                }
                return index;
            }
        }
        if (stdio.nowMs() >= deadline) {
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
    const deadline = stdio.nowMs() + @as(i64, @intCast(timeout_ms));
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
            if (writer) |tw| try runner_events.recordSelectorArrayStatus(tw, "assert.noneVisible", "ok", selectors, timeout_ms);
            return true;
        }

        if (stdio.nowMs() >= deadline) {
            if (writer) |tw| try runner_events.recordDiagnosticWithStrategyAndTimeout(tw, "assert.noneVisible", "visible", null, selectors, snap, timeout_ms);
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
    const deadline = stdio.nowMs() + @as(i64, @intCast(timeout_ms));
    if (try nativeAssertHealthy(device, health_selectors, timeout_ms, writer, deadline, options)) |healthy| return healthy;
    while (true) {
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "assert.healthy", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);

        if (!health.hasUnhealthyOverlay(snap.nodes)) {
            if (writer) |tw| {
                const payload = try std.fmt.allocPrint(tw.allocator, "{{\"status\":\"ok\",\"timeoutMs\":{d}}}", .{timeout_ms});
                defer tw.allocator.free(payload);
                try tw.recordEvent("assert.healthy", payload);
            }
            return true;
        }

        if (stdio.nowMs() >= deadline) {
            if (writer) |tw| try runner_events.recordDiagnosticWithStrategyAndTimeout(tw, "assert.healthy", "unhealthy", null, health_selectors, snap, timeout_ms);
            return false;
        }

        try sleepMs(options.poll_ms);
    }
}

fn nativeAssertHealthy(
    device: anytype,
    health_selectors: []const selector.Selector,
    timeout_ms: u64,
    writer: ?*trace.TraceWriter,
    deadline: i64,
    options: RunOptions,
) !?bool {
    if (!hasNativeSelectorQuery(device)) return null;

    probe: while (true) {
        for (health_selectors, 0..) |wanted, index| {
            const query_timeout_ms = nativeSelectorQueryTimeoutMs(deadline) orelse return false;
            const result = nativeVisibleBySelector(device, wanted, query_timeout_ms) catch |err| {
                if (try retryTransientObservation(err, "assert.healthy", writer, deadline, options)) continue :probe;
                return err;
            };
            const visible = result orelse return null;
            if (visible) {
                if (writer) |tw| try runner_events.recordNativeSelectorArrayStatus(tw, "assert.healthy", "unhealthy", health_selectors, index, timeout_ms);
                return false;
            }
        }

        if (writer) |tw| try runner_events.recordNativeSelectorArrayStatus(tw, "assert.healthy", "ok", health_selectors, null, timeout_ms);
        return true;
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
    const deadline = stdio.nowMs() + @as(i64, @intCast(timeout_ms));
    while (true) {
        var snap = device.snapshot(writer) catch |err| {
            if (try retryTransientObservation(err, "ui.scrollUntilVisible", writer, deadline, options)) continue;
            return err;
        };
        defer snap.deinit(device.allocator);
        if (selector.find(snap.nodes, wanted)) |node| {
            if (writer) |tw| {
                var payload: std.Io.Writer.Allocating = .init(tw.allocator);
                defer payload.deinit();
                const out = &payload.writer;
                try out.print("{{\"status\":\"ok\",\"target\":\"{s}\",\"selector\":", .{node.stable_id});
                try trace.writeSelectorJson(out, wanted);
                try out.print(",\"direction\":\"{s}\",\"timeoutMs\":{d}}}", .{
                    if (direction == .down) "down" else "up",
                    timeout_ms,
                });
                try tw.recordEvent("ui.scrollUntilVisible", out.buffered());
            }
            return true;
        }
        if (stdio.nowMs() >= deadline) {
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

fn hasNativeSelectorQuery(device: anytype) bool {
    return @hasDecl(@TypeOf(device.*), "visibleBySelectorWithTimeout") or @hasDecl(@TypeOf(device.*), "visibleBySelector");
}

fn nativeVisibleBySelector(device: anytype, wanted: selector.Selector, timeout_ms: u64) !?bool {
    if (@hasDecl(@TypeOf(device.*), "visibleBySelectorWithTimeout")) return try device.visibleBySelectorWithTimeout(wanted, timeout_ms);
    if (!@hasDecl(@TypeOf(device.*), "visibleBySelector")) return null;
    return try device.visibleBySelector(wanted);
}

fn nativeSelectorQueryTimeoutMs(deadline: i64) ?u64 {
    const now = stdio.nowMs();
    if (now >= deadline) return null;
    return @as(u64, @intCast(deadline - now));
}

fn retryTransientObservation(
    err: anyerror,
    kind: []const u8,
    writer: ?*trace.TraceWriter,
    deadline: i64,
    options: RunOptions,
) !bool {
    if (err != error.CommandTimedOut and err != error.CommandFailed) return false;
    if (stdio.nowMs() >= deadline) return false;
    if (writer) |tw| try runner_events.recordObservationRetry(tw, kind, err);
    try sleepMs(options.poll_ms);
    return true;
}

fn settleDevice(device: anytype, options: RunOptions) !void {
    try device.settle(options.settle_ms);
}

fn sleepMs(ms: u64) !void {
    stdio.sleepNs(ms * std.time.ns_per_ms);
}
