const std = @import("std");
const stdio = @import("stdio.zig");
const runner_config = @import("runner_config.zig");
const runner_events = @import("runner_events.zig");
const runner_native = @import("runner_native.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

const RunOptions = runner_config.RunOptions;

pub fn tapSelector(
    device: anytype,
    wanted: selector.Selector,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    if (try runner_native.tryTapSelector(device, wanted, writer, options.settle_ms)) return;

    const deadline = stdio.nowMs() + @as(i64, @intCast(options.action_timeout_ms));
    var attempts: u32 = 0;
    while (true) {
        attempts += 1;
        var snap = try device.snapshot(writer);
        defer snap.deinit(device.allocator);
        if (findActionable(snap, wanted)) |node| {
            try device.tap(node.bounds.centerX(), node.bounds.centerY());
            if (writer) |tw| {
                var payload: std.Io.Writer.Allocating = .init(tw.allocator);
                defer payload.deinit();
                const out = &payload.writer;
                try out.print("{{\"snapshotId\":\"{s}\",\"target\":\"{s}\",\"x\":{d},\"y\":{d},\"attempts\":{d},\"selector\":", .{
                    snap.id,
                    node.stable_id,
                    node.bounds.centerX(),
                    node.bounds.centerY(),
                    attempts,
                });
                try trace.writeSelectorJson(out, wanted);
                try out.writeAll("}");
                try tw.recordEvent("ui.tap", out.buffered());
            }
            try settleDevice(device, options);
            return;
        }
        if (stdio.nowMs() >= deadline) {
            if (writer) |tw| {
                try runner_events.recordSelectorMiss(tw, "ui.tap.notFound", wanted, snap);
            }
            return error.SelectorNotFound;
        }
        try sleepMs(options.poll_ms);
    }
}

pub fn typeTextSelector(
    device: anytype,
    wanted: selector.Selector,
    text: []const u8,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    if (try runner_native.tryTypeTextSelector(device, wanted, text, writer, options.settle_ms)) return;
    try tapSelector(device, wanted, writer, options);
    try device.typeText(text);
    if (writer) |tw| {
        var payload: std.Io.Writer.Allocating = .init(tw.allocator);
        defer payload.deinit();
        const out = &payload.writer;
        try out.writeAll("{\"status\":\"ok\",\"selector\":");
        try trace.writeSelectorJson(out, wanted);
        try out.writeAll(",\"text\":");
        try trace.writeJsonString(out, text);
        try out.writeAll("}");
        try tw.recordEvent("ui.type", out.buffered());
    }
    try settleDevice(device, options);
}

pub fn eraseTextSelector(
    device: anytype,
    wanted: selector.Selector,
    max_chars: u32,
    writer: ?*trace.TraceWriter,
    options: RunOptions,
) !void {
    if (try runner_native.tryEraseTextSelector(device, wanted, max_chars, writer, options.settle_ms)) return;
    try tapSelector(device, wanted, writer, options);
    try device.eraseText(max_chars);
    if (writer) |tw| {
        const payload = try std.fmt.allocPrint(tw.allocator, "{{\"maxChars\":{d}}}", .{max_chars});
        defer tw.allocator.free(payload);
        try tw.recordEvent("ui.eraseText", payload);
    }
    try settleDevice(device, options);
}

fn findActionable(snap: types.ObservationSnapshot, wanted: selector.Selector) ?types.UiNode {
    for (snap.nodes) |node| {
        if (!selector.matches(node, wanted)) continue;
        if (!node.enabled) continue;
        if (!isInViewport(node, snap.viewport)) continue;
        return node;
    }
    return null;
}

fn isInViewport(node: types.UiNode, viewport: types.Viewport) bool {
    if (node.bounds.width <= 0 or node.bounds.height <= 0) return false;
    if (viewport.width == 0 or viewport.height == 0) return true;
    const right = node.bounds.x + node.bounds.width;
    const bottom = node.bounds.y + node.bounds.height;
    return right > 0 and bottom > 0 and node.bounds.x < @as(i32, @intCast(viewport.width)) and node.bounds.y < @as(i32, @intCast(viewport.height));
}

fn settleDevice(device: anytype, options: RunOptions) !void {
    try device.settle(options.settle_ms);
}

fn sleepMs(ms: u64) !void {
    stdio.sleepNs(ms * std.time.ns_per_ms);
}
