const std = @import("std");
const selector = @import("selector.zig");
const trace = @import("trace.zig");

pub fn tryTapSelector(
    device: anytype,
    wanted: selector.Selector,
    writer: ?*trace.TraceWriter,
    settle_ms: u64,
) !bool {
    if (!@hasDecl(@TypeOf(device.*), "tapBySelector")) return false;
    const tapped = device.tapBySelector(wanted) catch |err| {
        if (writer) |tw| try recordSelectorActionFailure(tw, "ui.tap", wanted, err);
        return err;
    };
    if (!tapped) return false;
    if (writer) |tw| try recordSelectorAction(tw, "ui.tap", wanted, null);
    try device.settle(settle_ms);
    return true;
}

pub fn tryTypeTextSelector(
    device: anytype,
    wanted: selector.Selector,
    text: []const u8,
    writer: ?*trace.TraceWriter,
    settle_ms: u64,
) !bool {
    if (!@hasDecl(@TypeOf(device.*), "typeTextBySelector")) return false;
    const typed = device.typeTextBySelector(wanted, text) catch |err| {
        if (writer) |tw| try recordSelectorActionFailure(tw, "ui.type", wanted, err);
        return err;
    };
    if (!typed) return false;
    if (writer) |tw| try recordSelectorTextAction(tw, "ui.type", wanted, text);
    try device.settle(settle_ms);
    return true;
}

pub fn tryEraseTextSelector(
    device: anytype,
    wanted: selector.Selector,
    max_chars: u32,
    writer: ?*trace.TraceWriter,
    settle_ms: u64,
) !bool {
    if (!@hasDecl(@TypeOf(device.*), "eraseTextBySelector")) return false;
    const erased = device.eraseTextBySelector(wanted, max_chars) catch |err| {
        if (writer) |tw| try recordSelectorActionFailure(tw, "ui.eraseText", wanted, err);
        return err;
    };
    if (!erased) return false;
    if (writer) |tw| try recordSelectorAction(tw, "ui.eraseText", wanted, max_chars);
    try device.settle(settle_ms);
    return true;
}

fn recordSelectorAction(
    tw: *trace.TraceWriter,
    kind: []const u8,
    wanted: selector.Selector,
    max_chars: ?u32,
) !void {
    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
    defer payload.deinit();
    const writer = &payload.writer;
    try writer.writeAll("{\"status\":\"ok\",\"strategy\":\"nativeSelector\",\"selector\":");
    try trace.writeSelectorJson(writer, wanted);
    if (max_chars) |value| try writer.print(",\"maxChars\":{d}", .{value});
    try writer.writeAll("}");
    try tw.recordEvent(kind, writer.buffered());
}

fn recordSelectorTextAction(
    tw: *trace.TraceWriter,
    kind: []const u8,
    wanted: selector.Selector,
    text: []const u8,
) !void {
    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
    defer payload.deinit();
    const writer = &payload.writer;
    try writer.writeAll("{\"status\":\"ok\",\"strategy\":\"nativeSelector\",\"selector\":");
    try trace.writeSelectorJson(writer, wanted);
    try writer.writeAll(",\"text\":");
    try trace.writeJsonString(writer, text);
    try writer.writeAll("}");
    try tw.recordEvent(kind, writer.buffered());
}

fn recordSelectorActionFailure(
    tw: *trace.TraceWriter,
    kind: []const u8,
    wanted: selector.Selector,
    err: anyerror,
) !void {
    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
    defer payload.deinit();
    const out = &payload.writer;
    try out.writeAll("{\"status\":\"failed\",\"strategy\":\"nativeSelector\",\"error\":");
    try trace.writeJsonString(out, @errorName(err));
    try out.writeAll(",\"selector\":");
    try trace.writeSelectorJson(out, wanted);
    try out.writeAll("}");
    try tw.recordEvent(kind, out.buffered());
}
