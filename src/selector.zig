const std = @import("std");
const types = @import("types.zig");

pub const Selector = struct {
    id: ?[]const u8 = null,
    stable_id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    text_contains: ?[]const u8 = null,
    content_desc: ?[]const u8 = null,
    content_desc_contains: ?[]const u8 = null,
    class_name: ?[]const u8 = null,

    pub fn deinit(self: Selector, allocator: std.mem.Allocator) void {
        if (self.id) |value| allocator.free(value);
        if (self.stable_id) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.text_contains) |value| allocator.free(value);
        if (self.content_desc) |value| allocator.free(value);
        if (self.content_desc_contains) |value| allocator.free(value);
        if (self.class_name) |value| allocator.free(value);
    }

    pub fn clone(self: Selector, allocator: std.mem.Allocator) !Selector {
        return .{
            .id = try types.dupeOptional(allocator, self.id),
            .stable_id = try types.dupeOptional(allocator, self.stable_id),
            .text = try types.dupeOptional(allocator, self.text),
            .text_contains = try types.dupeOptional(allocator, self.text_contains),
            .content_desc = try types.dupeOptional(allocator, self.content_desc),
            .content_desc_contains = try types.dupeOptional(allocator, self.content_desc_contains),
            .class_name = try types.dupeOptional(allocator, self.class_name),
        };
    }

    pub fn hasAny(self: Selector) bool {
        return self.id != null or
            self.stable_id != null or
            self.text != null or
            self.text_contains != null or
            self.content_desc != null or
            self.content_desc_contains != null or
            self.class_name != null;
    }
};

pub fn matches(node: types.UiNode, wanted: Selector) bool {
    if (!wanted.hasAny()) return false;
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
    if (wanted.content_desc) |desc| {
        if (node.content_desc == null or !std.mem.eql(u8, node.content_desc.?, desc)) return false;
    }
    if (wanted.content_desc_contains) |needle| {
        if (node.content_desc == null or std.mem.indexOf(u8, node.content_desc.?, needle) == null) return false;
    }
    if (wanted.class_name) |class_name| {
        if (!std.mem.eql(u8, node.class_name, class_name)) return false;
    }
    return node.visible;
}

pub fn find(nodes: []const types.UiNode, wanted: Selector) ?types.UiNode {
    for (nodes) |node| {
        if (matches(node, wanted)) return node;
    }
    return null;
}

pub fn parseFromJson(allocator: std.mem.Allocator, value: std.json.Value) !Selector {
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
    parsed.content_desc = try stringField(allocator, object, "contentDesc");
    parsed.content_desc_contains = try stringField(allocator, object, "contentDescContains");
    parsed.class_name = try stringField(allocator, object, "className");
    if (!parsed.hasAny()) return error.SelectorMustNotBeEmpty;
    return parsed;
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
        std.mem.eql(u8, key, "contentDesc") or
        std.mem.eql(u8, key, "contentDescContains") or
        std.mem.eql(u8, key, "className");
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
