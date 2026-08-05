const std = @import("std");
const action_registry = @import("action_registry.zig");

test "action registry exposes cross-protocol aliases for mobile primitives" {
    const tap = action_registry.find(.yaml, "tapOn") orelse return error.ExpectedTapAction;
    try std.testing.expectEqualStrings("ui.tap", tap.id);
    try std.testing.expectEqualStrings("tap", tap.json_aliases[0]);
    try std.testing.expectEqualStrings("ui.tap", tap.rpc_aliases[0]);
    try std.testing.expectEqualStrings("tap", tap.mcp_aliases[0]);
    try std.testing.expectEqual(action_registry.Mutability.mutating, tap.mutability);
    try std.testing.expectEqual(action_registry.RiskClass.medium, tap.risk_class);
    try std.testing.expect(!tap.deprecated);
}

test "action registry aliases are unique within each protocol" {
    const specs = action_registry.all();
    for (specs, 0..) |spec, index| {
        for (specs[index + 1 ..]) |other| {
            try expectDisjoint(spec.json_aliases, other.json_aliases);
            try expectDisjoint(spec.yaml_aliases, other.yaml_aliases);
            try expectDisjoint(spec.rpc_aliases, other.rpc_aliases);
            try expectDisjoint(spec.mcp_aliases, other.mcp_aliases);
        }
    }
}

test "unsupported migration commands carry precise diagnostics" {
    const diagnostic = action_registry.unsupported("evalScript") orelse
        return error.ExpectedUnsupportedDiagnostic;
    try std.testing.expectEqualStrings("evalScript", diagnostic.command);
    try std.testing.expectEqualStrings("arbitrary JavaScript is intentionally outside the deterministic ZMR contract", diagnostic.reason);
    try std.testing.expect(diagnostic.replacement == null);
}

test "registry JSON is parseable and preserves contract fields" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try action_registry.writeJson(&out.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(action_registry.all().len, parsed.value.array.items.len);
    const tap = parsed.value.array.items[0];
    try std.testing.expect(tap.object.get("id") != null);
    try std.testing.expect(tap.object.get("jsonAliases") != null);
    try std.testing.expect(tap.object.get("parameterSchema") != null);
    try std.testing.expect(tap.object.get("traceEvent") != null);
    try std.testing.expect(tap.object.get("version") != null);
}

fn expectDisjoint(left: []const []const u8, right: []const []const u8) !void {
    for (left) |value| {
        for (right) |other| {
            try std.testing.expect(!std.mem.eql(u8, value, other));
        }
    }
}
