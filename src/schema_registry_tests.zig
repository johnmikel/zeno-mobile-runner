const std = @import("std");
const schema_registry = @import("schema_registry.zig");

test "registry exposes stable public schema metadata" {
    const schemas = schema_registry.all();
    try std.testing.expect(schemas.len >= 10);
    try std.testing.expectEqualStrings("json-rpc", schemas[0].name);
    try std.testing.expectEqualStrings("schemas/json-rpc.schema.json", schemas[0].path);
    var saw_release_readiness = false;
    for (schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "release-readiness-output")) {
            saw_release_readiness = true;
            try std.testing.expectEqualStrings("schemas/release-readiness-output.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/release-readiness-output.schema.json", schema.id);
        }
    }
    try std.testing.expect(saw_release_readiness);
    var found_inspect_output = false;
    for (schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "inspect-output")) {
            found_inspect_output = true;
            try std.testing.expectEqualStrings("schemas/inspect-output.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/inspect-output.schema.json", schema.id);
        }
    }
    try std.testing.expect(found_inspect_output);
    try std.testing.expectEqualStrings("schemas-output", schemas[schemas.len - 1].name);
}

test "registry json output is parseable and count matches entries" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try schema_registry.writeJson(out.writer(allocator));

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, @intCast(schema_registry.all().len)), object.get("count").?.integer);
    try std.testing.expectEqual(schema_registry.all().len, object.get("schemas").?.array.items.len);
}
