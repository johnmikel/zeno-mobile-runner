const std = @import("std");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

pub fn record(
    tw: *trace.TraceWriter,
    kind: []const u8,
    status: []const u8,
    strategy: ?[]const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
) !void {
    try recordWithOptions(tw, kind, status, strategy, selectors, snap, .{});
}

pub const DiagnosticOptions = struct {
    timeout_ms: ?u64 = null,
};

pub fn recordWithOptions(
    tw: *trace.TraceWriter,
    kind: []const u8,
    status: []const u8,
    strategy: ?[]const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
    options: DiagnosticOptions,
) !void {
    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
    defer payload.deinit();
    try writeSelectorDiagnosticJsonWithOptions(&payload.writer, status, strategy, selectors, snap, options);
    try tw.recordEvent(kind, payload.writer.buffered());
}

pub fn writeSelectorDiagnosticJson(
    writer: anytype,
    status: []const u8,
    strategy: ?[]const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
) !void {
    try writeSelectorDiagnosticJsonWithOptions(writer, status, strategy, selectors, snap, .{});
}

pub fn writeSelectorDiagnosticJsonWithOptions(
    writer: anytype,
    status: []const u8,
    strategy: ?[]const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
    options: DiagnosticOptions,
) !void {
    try writer.print("{{\"status\":\"{s}\"", .{status});
    if (strategy) |value| {
        try writer.writeAll(",\"strategy\":");
        try trace.writeJsonString(writer, value);
    }
    if (options.timeout_ms) |timeout_ms| {
        try writer.print(",\"timeoutMs\":{d}", .{timeout_ms});
    }
    try writer.print(",\"snapshotId\":\"{s}\",\"selectors\":[", .{snap.id});
    for (selectors, 0..) |wanted, index| {
        if (index > 0) try writer.writeAll(",");
        try trace.writeSelectorJson(writer, wanted);
    }
    try writer.writeAll("],\"activePackage\":");
    if (snap.active_package) |value| {
        try trace.writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"activeActivity\":");
    if (snap.active_activity) |value| {
        try trace.writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"visibleTexts\":[");
    var count: usize = 0;
    for (snap.nodes) |node| {
        const text = node.text orelse node.content_desc orelse continue;
        if (!node.visible or text.len == 0) continue;
        if (count > 0) try writer.writeAll(",");
        try trace.writeJsonString(writer, text);
        count += 1;
        if (count >= 20) break;
    }
    try writer.writeAll("]");
    try writeCandidateList(writer, "hiddenCandidates", selectors, snap, .hidden);
    try writeCandidateList(writer, "disabledCandidates", selectors, snap, .disabled);
    try writeCandidateList(writer, "offscreenCandidates", selectors, snap, .offscreen);
    try writeNearestTextMatches(writer, selectors, snap);
    try writer.writeAll("}");
}

const CandidateKind = enum {
    hidden,
    disabled,
    offscreen,
};

fn writeCandidateList(
    writer: anytype,
    field_name: []const u8,
    selectors: []const selector.Selector,
    snap: types.ObservationSnapshot,
    candidate_kind: CandidateKind,
) !void {
    try writer.print(",\"{s}\":[", .{field_name});
    var count: usize = 0;
    for (snap.nodes) |node| {
        var matched = false;
        for (selectors) |wanted| {
            if (nodeMatchesSelectorFields(node, wanted)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        const include = switch (candidate_kind) {
            .hidden => !node.visible,
            .disabled => node.visible and !node.enabled,
            .offscreen => node.visible and node.enabled and !isInViewport(node, snap.viewport),
        };
        if (!include) continue;
        if (count > 0) try writer.writeAll(",");
        try writeNodeDiagnostic(writer, node);
        count += 1;
        if (count >= 10) break;
    }
    try writer.writeAll("]");
}

fn writeNearestTextMatches(writer: anytype, selectors: []const selector.Selector, snap: types.ObservationSnapshot) !void {
    try writer.writeAll(",\"nearestTextMatches\":[");
    var written: usize = 0;
    for (selectors) |wanted| {
        const target = selectorTextTarget(wanted) orelse continue;
        var best: [5]NearestCandidate = undefined;
        var best_len: usize = 0;
        for (snap.nodes) |node| {
            const label = nodeLabel(node) orelse continue;
            if (label.len == 0 or nodeMatchesSelectorFields(node, wanted)) continue;
            const score = textDistance(target, label);
            if (score > @max(target.len, label.len)) continue;
            insertNearest(&best, &best_len, .{ .node = node, .text = label, .score = score });
        }
        for (best[0..best_len]) |candidate| {
            if (written > 0) try writer.writeAll(",");
            try writer.writeAll("{\"stableId\":");
            try trace.writeJsonString(writer, candidate.node.stable_id);
            try writer.writeAll(",\"text\":");
            try trace.writeJsonString(writer, candidate.text);
            try writer.print(",\"score\":{d}", .{candidate.score});
            try writer.writeAll(",\"enabled\":");
            try writer.writeAll(if (candidate.node.enabled) "true" else "false");
            try writer.writeAll(",\"visible\":");
            try writer.writeAll(if (candidate.node.visible) "true" else "false");
            try writer.writeAll("}");
            written += 1;
            if (written >= 10) break;
        }
        if (written >= 10) break;
    }
    try writer.writeAll("]");
}

const NearestCandidate = struct {
    node: types.UiNode,
    text: []const u8,
    score: usize,
};

fn insertNearest(candidates: *[5]NearestCandidate, len: *usize, candidate: NearestCandidate) void {
    const insert_limit = candidates.len;
    if (len.* == insert_limit and candidate.score >= candidates[len.* - 1].score) return;
    var index: usize = 0;
    while (index < len.* and candidates[index].score <= candidate.score) : (index += 1) {}
    if (len.* < insert_limit) len.* += 1;
    var move_index = len.* - 1;
    while (move_index > index) : (move_index -= 1) {
        candidates[move_index] = candidates[move_index - 1];
    }
    candidates[index] = candidate;
}

fn writeNodeDiagnostic(writer: anytype, node: types.UiNode) !void {
    try writer.writeAll("{\"stableId\":");
    try trace.writeJsonString(writer, node.stable_id);
    try writer.writeAll(",\"className\":");
    try trace.writeJsonString(writer, node.class_name);
    try writer.writeAll(",\"text\":");
    if (node.text) |value| {
        try trace.writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"contentDesc\":");
    if (node.content_desc) |value| {
        try trace.writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"resourceId\":");
    if (node.resource_id) |value| {
        try trace.writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"bounds\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
        .{ node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height },
    );
    try writer.writeAll(",\"enabled\":");
    try writer.writeAll(if (node.enabled) "true" else "false");
    try writer.writeAll(",\"visible\":");
    try writer.writeAll(if (node.visible) "true" else "false");
    try writer.writeAll("}");
}

fn nodeMatchesSelectorFields(node: types.UiNode, wanted: selector.Selector) bool {
    if (wanted.id) |id| {
        if (node.resource_id == null or !std.mem.eql(u8, node.resource_id.?, id)) return false;
    }
    if (wanted.text) |text| {
        if (node.text == null or !std.mem.eql(u8, node.text.?, text)) return false;
    }
    if (wanted.text_contains) |needle| {
        if (node.text == null or std.mem.indexOf(u8, node.text.?, needle) == null) return false;
    }
    if (wanted.content_desc) |desc| {
        if (node.content_desc == null or !std.mem.eql(u8, node.content_desc.?, desc)) return false;
    }
    if (wanted.content_desc_contains) |needle| {
        if (node.content_desc == null or std.mem.indexOf(u8, node.content_desc.?, needle) == null) return false;
    }
    if (wanted.class_name) |class_name| {
        if (!std.mem.eql(u8, node.class_name, class_name)) return false;
    }
    return true;
}

fn selectorTextTarget(wanted: selector.Selector) ?[]const u8 {
    if (wanted.text) |value| return value;
    if (wanted.text_contains) |value| return value;
    if (wanted.content_desc) |value| return value;
    if (wanted.content_desc_contains) |value| return value;
    return null;
}

fn nodeLabel(node: types.UiNode) ?[]const u8 {
    if (node.text) |value| return value;
    if (node.content_desc) |value| return value;
    return null;
}

fn isInViewport(node: types.UiNode, viewport: types.Viewport) bool {
    if (node.bounds.width <= 0 or node.bounds.height <= 0) return false;
    if (viewport.width == 0 or viewport.height == 0) return true;
    const right = node.bounds.x + node.bounds.width;
    const bottom = node.bounds.y + node.bounds.height;
    return right > 0 and bottom > 0 and node.bounds.x < @as(i32, @intCast(viewport.width)) and node.bounds.y < @as(i32, @intCast(viewport.height));
}

fn textDistance(left: []const u8, right: []const u8) usize {
    if (containsIgnoreCase(left, right) or containsIgnoreCase(right, left)) {
        return if (left.len > right.len) left.len - right.len else right.len - left.len;
    }
    const prefix = commonPrefixIgnoreCase(left, right);
    return @max(left.len, right.len) - prefix;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, offset| {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn commonPrefixIgnoreCase(left: []const u8, right: []const u8) usize {
    const limit = @min(left.len, right.len);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (std.ascii.toLower(left[index]) != std.ascii.toLower(right[index])) break;
    }
    return index;
}
