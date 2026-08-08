const std = @import("std");
const types = @import("types.zig");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Selector = struct {
    id: ?[]const u8 = null,
    stable_id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    text_contains: ?[]const u8 = null,
    text_regex: ?[]const u8 = null,
    content_desc: ?[]const u8 = null,
    content_desc_contains: ?[]const u8 = null,
    content_desc_regex: ?[]const u8 = null,
    class_name: ?[]const u8 = null,
    index: ?u32 = null,
    point: ?Point = null,
    enabled: ?bool = null,
    checked: ?bool = null,
    focused: ?bool = null,
    selected: ?bool = null,
    above: ?*Selector = null,
    below: ?*Selector = null,
    left: ?*Selector = null,
    right: ?*Selector = null,
    child: ?*Selector = null,
    descendant: ?*Selector = null,

    pub fn deinit(self: Selector, allocator: std.mem.Allocator) void {
        if (self.id) |value| allocator.free(value);
        if (self.stable_id) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.text_contains) |value| allocator.free(value);
        if (self.text_regex) |value| allocator.free(value);
        if (self.content_desc) |value| allocator.free(value);
        if (self.content_desc_contains) |value| allocator.free(value);
        if (self.content_desc_regex) |value| allocator.free(value);
        if (self.class_name) |value| allocator.free(value);
        deinitRelation(allocator, self.above);
        deinitRelation(allocator, self.below);
        deinitRelation(allocator, self.left);
        deinitRelation(allocator, self.right);
        deinitRelation(allocator, self.child);
        deinitRelation(allocator, self.descendant);
    }

    pub fn clone(self: Selector, allocator: std.mem.Allocator) !Selector {
        var copy = Selector{
            .id = try types.dupeOptional(allocator, self.id),
            .stable_id = try types.dupeOptional(allocator, self.stable_id),
            .text = try types.dupeOptional(allocator, self.text),
            .text_contains = try types.dupeOptional(allocator, self.text_contains),
            .text_regex = try types.dupeOptional(allocator, self.text_regex),
            .content_desc = try types.dupeOptional(allocator, self.content_desc),
            .content_desc_contains = try types.dupeOptional(allocator, self.content_desc_contains),
            .content_desc_regex = try types.dupeOptional(allocator, self.content_desc_regex),
            .class_name = try types.dupeOptional(allocator, self.class_name),
            .index = self.index,
            .point = self.point,
            .enabled = self.enabled,
            .checked = self.checked,
            .focused = self.focused,
            .selected = self.selected,
        };
        errdefer copy.deinit(allocator);
        copy.above = try cloneRelation(allocator, self.above);
        copy.below = try cloneRelation(allocator, self.below);
        copy.left = try cloneRelation(allocator, self.left);
        copy.right = try cloneRelation(allocator, self.right);
        copy.child = try cloneRelation(allocator, self.child);
        copy.descendant = try cloneRelation(allocator, self.descendant);
        return copy;
    }

    pub fn hasAny(self: Selector) bool {
        return self.id != null or
            self.stable_id != null or
            self.text != null or
            self.text_contains != null or
            self.text_regex != null or
            self.content_desc != null or
            self.content_desc_contains != null or
            self.content_desc_regex != null or
            self.class_name != null or
            self.index != null or
            self.point != null or
            self.enabled != null or
            self.checked != null or
            self.focused != null or
            self.selected != null or
            self.above != null or
            self.below != null or
            self.left != null or
            self.right != null or
            self.child != null or
            self.descendant != null;
    }
};

/// Matches the fields that can be evaluated against one node. Positional and
/// relational fields are evaluated by find(), which has the complete snapshot.
pub fn matches(node: types.UiNode, wanted: Selector) bool {
    if (!wanted.hasAny()) return false;
    if (!matchesBase(node, wanted)) return false;
    if (wanted.point) |point| {
        if (!containsPoint(node.bounds, point)) return false;
    }
    return node.visible;
}

/// The deepest matching node wins.
///
/// React Native and Expo render one control as a stack of nested views that
/// all carry the same accessible text — a Text inside a Pressable inside a
/// scroll container. A flattened hierarchy lists the outermost first, so
/// returning the first match hands back the container. Sometimes that works by
/// accident, because the container covers the same pixels; when the container
/// is the scroll view, a tap lands hundreds of points from the control. The
/// leaf is what the user would press, so the leaf is the answer.
///
/// Among matches at equal depth the first in document order still wins, so the
/// same hierarchy always resolves to the same node — determinism is the whole
/// product claim, and a matcher that picked differently between runs would
/// undermine it.
pub fn find(nodes: []const types.UiNode, wanted: Selector) ?types.UiNode {
    var best: ?types.UiNode = null;
    var best_depth: usize = 0;
    for (nodes, 0..) |node, node_index| {
        if (!matchesAt(nodes, node_index, wanted)) continue;
        const depth = depthOf(nodes, node_index);
        if (best == null or depth > best_depth) {
            best = node;
            best_depth = depth;
        }
    }
    return best;
}

/// How many ancestors a node has. Bounded by node count so a malformed
/// snapshot carrying a parent-id cycle cannot spin here.
pub fn depthOf(nodes: []const types.UiNode, node_index: usize) usize {
    var depth: usize = 0;
    var parent_id = nodes[node_index].parent_stable_id orelse return 0;
    var hops: usize = 0;
    while (hops < nodes.len) : (hops += 1) {
        var found = false;
        for (nodes) |other| {
            if (!std.mem.eql(u8, other.stable_id, parent_id)) continue;
            depth += 1;
            parent_id = other.parent_stable_id orelse return depth;
            found = true;
            break;
        }
        if (!found) return depth;
    }
    return depth;
}

/// Full-context matcher for callers that need to retain their own filtering
/// policy (for example, actionable nodes additionally require enabled and
/// viewport checks). This keeps index and relational selectors consistent
/// across snapshots, waits, and interactions.
pub fn matchesAt(nodes: []const types.UiNode, node_index: usize, wanted: Selector) bool {
    if (node_index >= nodes.len or !wanted.hasAny()) return false;
    const node = nodes[node_index];
    if (!matchesBase(node, wanted) or !node.visible) return false;
    if (wanted.index) |wanted_index| {
        var current_index: u32 = 0;
        for (nodes[0..node_index]) |previous| {
            if (matchesBase(previous, wanted) and previous.visible) current_index +|= 1;
        }
        if (current_index != wanted_index) return false;
    }
    if (wanted.point) |point| {
        if (!containsPoint(node.bounds, point)) return false;
    }
    return matchesRelations(nodes, node_index, wanted, 0);
}

pub fn parseFromJson(allocator: std.mem.Allocator, value: std.json.Value) anyerror!Selector {
    if (value != .object) return error.SelectorMustBeObject;
    const object = value.object;
    try rejectUnknownFields(object);
    var parsed: Selector = .{};
    errdefer parsed.deinit(allocator);
    parsed.id = try stringField(allocator, object, "id");
    const resource_id = try stringField(allocator, object, "resourceId");
    if (parsed.id == null) {
        parsed.id = resource_id;
    } else if (resource_id) |resource_id_value| {
        allocator.free(resource_id_value);
    }
    parsed.stable_id = try stringField(allocator, object, "stableId");
    parsed.text = try stringField(allocator, object, "text");
    parsed.text_contains = try stringField(allocator, object, "textContains");
    parsed.text_regex = try stringField(allocator, object, "textRegex");
    parsed.content_desc = try stringField(allocator, object, "contentDesc");
    parsed.content_desc_contains = try stringField(allocator, object, "contentDescContains");
    parsed.content_desc_regex = try stringField(allocator, object, "contentDescRegex");
    parsed.class_name = try stringField(allocator, object, "className");
    parsed.index = try optionalU32(object, "index");
    parsed.point = try optionalPoint(object, "point");
    parsed.enabled = try optionalBool(object, "enabled");
    parsed.checked = try optionalBool(object, "checked");
    parsed.focused = try optionalBool(object, "focused");
    parsed.selected = try optionalBool(object, "selected");
    parsed.above = try optionalRelation(allocator, object, "above");
    parsed.below = try optionalRelation(allocator, object, "below");
    parsed.left = try optionalRelation(allocator, object, "leftOf");
    if (parsed.left == null) parsed.left = try optionalRelation(allocator, object, "left");
    parsed.right = try optionalRelation(allocator, object, "rightOf");
    if (parsed.right == null) parsed.right = try optionalRelation(allocator, object, "right");
    parsed.child = try optionalRelation(allocator, object, "child");
    parsed.descendant = try optionalRelation(allocator, object, "descendant");
    if (!parsed.hasAny()) return error.SelectorMustNotBeEmpty;
    return parsed;
}

fn matchesBase(node: types.UiNode, wanted: Selector) bool {
    if (wanted.id) |id| {
        if (node.resource_id == null or !std.mem.eql(u8, node.resource_id.?, id)) return false;
    }
    if (wanted.stable_id) |stable_id| {
        if (!std.mem.eql(u8, node.stable_id, stable_id)) return false;
    }
    if (wanted.text) |text| {
        if (node.text == null or !std.mem.eql(u8, node.text.?, text)) return false;
    }
    if (wanted.text_contains) |needle| {
        if (node.text == null or std.mem.indexOf(u8, node.text.?, needle) == null) return false;
    }
    if (wanted.text_regex) |pattern| {
        if (node.text == null or !regexMatches(node.text.?, pattern)) return false;
    }
    if (wanted.content_desc) |desc| {
        if (node.content_desc == null or !std.mem.eql(u8, node.content_desc.?, desc)) return false;
    }
    if (wanted.content_desc_contains) |needle| {
        if (node.content_desc == null or std.mem.indexOf(u8, node.content_desc.?, needle) == null) return false;
    }
    if (wanted.content_desc_regex) |pattern| {
        if (node.content_desc == null or !regexMatches(node.content_desc.?, pattern)) return false;
    }
    if (wanted.class_name) |class_name| {
        if (!std.mem.eql(u8, node.class_name, class_name)) return false;
    }
    if (wanted.enabled) |expected| if (node.enabled != expected) return false;
    if (wanted.checked) |expected| if (node.checked != expected) return false;
    if (wanted.focused) |expected| if (node.focused != expected) return false;
    if (wanted.selected) |expected| if (node.selected != expected) return false;
    return true;
}

fn matchesRelations(
    nodes: []const types.UiNode,
    candidate_index: usize,
    wanted: Selector,
    depth: u8,
) bool {
    if (depth > 32) return false;
    const candidate = nodes[candidate_index];
    if (wanted.above) |anchor| {
        if (!hasSpatialRelation(nodes, candidate, anchor, .above, depth)) return false;
    }
    if (wanted.below) |anchor| {
        if (!hasSpatialRelation(nodes, candidate, anchor, .below, depth)) return false;
    }
    if (wanted.left) |anchor| {
        if (!hasSpatialRelation(nodes, candidate, anchor, .left, depth)) return false;
    }
    if (wanted.right) |anchor| {
        if (!hasSpatialRelation(nodes, candidate, anchor, .right, depth)) return false;
    }
    if (wanted.child) |anchor| {
        if (!hasHierarchyRelation(nodes, candidate, anchor, false, depth)) return false;
    }
    if (wanted.descendant) |anchor| {
        if (!hasHierarchyRelation(nodes, candidate, anchor, true, depth)) return false;
    }
    return true;
}

const SpatialDirection = enum { above, below, left, right };

fn hasSpatialRelation(
    nodes: []const types.UiNode,
    candidate: types.UiNode,
    anchor: *const Selector,
    direction: SpatialDirection,
    depth: u8,
) bool {
    for (nodes, 0..) |other, other_index| {
        if (!matches(other, anchor.*)) continue;
        if (!matchesRelations(nodes, other_index, anchor.*, depth + 1)) continue;
        const candidate_right = candidate.bounds.x + candidate.bounds.width;
        const candidate_bottom = candidate.bounds.y + candidate.bounds.height;
        const other_right = other.bounds.x + other.bounds.width;
        const other_bottom = other.bounds.y + other.bounds.height;
        switch (direction) {
            .above => if (candidate_bottom <= other.bounds.y) return true,
            .below => if (candidate.bounds.y >= other_bottom) return true,
            .left => if (candidate_right <= other.bounds.x) return true,
            .right => if (candidate.bounds.x >= other_right) return true,
        }
    }
    return false;
}

fn hasHierarchyRelation(
    nodes: []const types.UiNode,
    candidate: types.UiNode,
    anchor: *const Selector,
    descendant: bool,
    depth: u8,
) bool {
    var parent_id = candidate.parent_stable_id orelse return false;
    // A valid ancestor chain visits each node at most once; a malformed
    // snapshot can carry a parent-id cycle, so bound the walk by node count.
    var hops: usize = 0;
    while (hops < nodes.len) : (hops += 1) {
        for (nodes, 0..) |other, other_index| {
            if (!std.mem.eql(u8, other.stable_id, parent_id)) continue;
            if (matches(other, anchor.*) and matchesRelations(nodes, other_index, anchor.*, depth + 1)) return true;
            if (!descendant) return false;
            parent_id = other.parent_stable_id orelse return false;
            break;
        } else return false;
    }
    return false;
}

fn containsPoint(bounds: types.Bounds, point: Point) bool {
    return point.x >= bounds.x and point.y >= bounds.y and
        point.x < bounds.x + bounds.width and point.y < bounds.y + bounds.height;
}

/// A bounded deterministic regex subset used by canonical selectors. It
/// supports literals, '.', '*', '^', '$', and backslash escaping. The parser
/// accepts the field explicitly so migrations never silently turn regex into
/// substring matching; unsupported regex features simply produce no match.
pub fn regexMatches(text: []const u8, pattern: []const u8) bool {
    var start_anchored = false;
    var end_anchored = false;
    var core = pattern;
    if (core.len > 0 and core[0] == '^') {
        start_anchored = true;
        core = core[1..];
    }
    if (core.len > 0 and core[core.len - 1] == '$' and (core.len < 2 or core[core.len - 2] != '\\')) {
        end_anchored = true;
        core = core[0 .. core.len - 1];
    }
    if (start_anchored) return regexHere(text, core, end_anchored);
    var offset: usize = 0;
    while (offset <= text.len) : (offset += 1) {
        if (regexHere(text[offset..], core, end_anchored)) return true;
    }
    return false;
}

fn regexHere(text: []const u8, pattern: []const u8, require_end: bool) bool {
    if (pattern.len == 0) return !require_end or text.len == 0;
    const width = tokenWidth(pattern);
    if (width < pattern.len and pattern[width] == '*') {
        if (regexHere(text, pattern[width + 1 ..], require_end)) return true;
        if (text.len > 0 and tokenMatches(pattern, text[0])) return regexHere(text[1..], pattern, require_end);
        return false;
    }
    if (text.len == 0 or !tokenMatches(pattern, text[0])) return false;
    return regexHere(text[1..], pattern[width..], require_end);
}

fn tokenWidth(pattern: []const u8) usize {
    return if (pattern.len >= 2 and pattern[0] == '\\') 2 else 1;
}

fn tokenMatches(pattern: []const u8, value: u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '.') return true;
    if (pattern[0] == '\\' and pattern.len >= 2) return pattern[1] == value;
    return pattern[0] == value;
}

fn rejectUnknownFields(object: std.json.ObjectMap) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isKnownField(entry.key_ptr.*)) return error.UnknownSelectorField;
    }
}

fn isKnownField(key: []const u8) bool {
    return std.mem.eql(u8, key, "id") or
        std.mem.eql(u8, key, "resourceId") or
        std.mem.eql(u8, key, "stableId") or
        std.mem.eql(u8, key, "text") or
        std.mem.eql(u8, key, "textContains") or
        std.mem.eql(u8, key, "textRegex") or
        std.mem.eql(u8, key, "contentDesc") or
        std.mem.eql(u8, key, "contentDescContains") or
        std.mem.eql(u8, key, "contentDescRegex") or
        std.mem.eql(u8, key, "className") or
        std.mem.eql(u8, key, "index") or
        std.mem.eql(u8, key, "point") or
        std.mem.eql(u8, key, "enabled") or
        std.mem.eql(u8, key, "checked") or
        std.mem.eql(u8, key, "focused") or
        std.mem.eql(u8, key, "selected") or
        std.mem.eql(u8, key, "above") or
        std.mem.eql(u8, key, "below") or
        std.mem.eql(u8, key, "leftOf") or
        std.mem.eql(u8, key, "left") or
        std.mem.eql(u8, key, "rightOf") or
        std.mem.eql(u8, key, "right") or
        std.mem.eql(u8, key, "child") or
        std.mem.eql(u8, key, "descendant");
}

fn stringField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.SelectorFieldMustBeString;
    return try allocator.dupe(u8, value.string);
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    if (value != .bool) return error.SelectorFieldMustBeBool;
    return value.bool;
}

fn optionalU32(object: std.json.ObjectMap, key: []const u8) !?u32 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.SelectorIndexOutOfRange;
    return @intCast(value.integer);
}

fn optionalPoint(object: std.json.ObjectMap, key: []const u8) !?Point {
    const value = object.get(key) orelse return null;
    if (value != .object) return error.SelectorPointMustBeObject;
    try rejectPointFields(value.object);
    return .{
        .x = try requiredI32(value.object, "x"),
        .y = try requiredI32(value.object, "y"),
    };
}

fn rejectPointFields(object: std.json.ObjectMap) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "x") and !std.mem.eql(u8, entry.key_ptr.*, "y")) return error.UnknownSelectorPointField;
    }
}

fn requiredI32(object: std.json.ObjectMap, key: []const u8) !i32 {
    const value = object.get(key) orelse return error.SelectorPointMissingCoordinate;
    if (value != .integer or value.integer < std.math.minInt(i32) or value.integer > std.math.maxInt(i32)) return error.SelectorPointCoordinateMustBeInteger;
    return @intCast(value.integer);
}

fn optionalRelation(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) anyerror!?*Selector {
    const value = object.get(key) orelse return null;
    const relation = try allocator.create(Selector);
    errdefer allocator.destroy(relation);
    relation.* = try parseFromJson(allocator, value);
    return relation;
}

fn cloneRelation(allocator: std.mem.Allocator, relation: ?*Selector) !?*Selector {
    const value = relation orelse return null;
    const copy = try allocator.create(Selector);
    errdefer allocator.destroy(copy);
    copy.* = try value.*.clone(allocator);
    return copy;
}

fn deinitRelation(allocator: std.mem.Allocator, relation: ?*Selector) void {
    if (relation) |value| {
        value.deinit(allocator);
        allocator.destroy(value);
    }
}
