const std = @import("std");
const test_io = @import("test_io.zig");
const schema_registry = @import("schema_registry.zig");

test "registry exposes stable public schema metadata" {
    const schemas = schema_registry.all();
    try std.testing.expect(schemas.len >= 10);
    try std.testing.expectEqualStrings("json-rpc", schemas[0].name);
    try std.testing.expectEqualStrings("schemas/json-rpc.schema.json", schemas[0].path);
    var saw_release_readiness = false;
    var saw_run_summary = false;
    var saw_bootstrap_event = false;
    var run_summary_index: ?usize = null;
    var bootstrap_event_index: ?usize = null;
    var release_readiness_index: ?usize = null;
    for (schemas, 0..) |schema, index| {
        if (std.mem.eql(u8, schema.name, "run-summary")) {
            saw_run_summary = true;
            run_summary_index = index;
            try std.testing.expectEqualStrings("schemas/run-summary.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/run-summary.schema.json", schema.id);
        }
        if (std.mem.eql(u8, schema.name, "bootstrap-event")) {
            saw_bootstrap_event = true;
            bootstrap_event_index = index;
            try std.testing.expectEqualStrings("schemas/bootstrap-event.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/bootstrap-event.schema.json", schema.id);
        }
        if (std.mem.eql(u8, schema.name, "release-readiness-output")) {
            saw_release_readiness = true;
            release_readiness_index = index;
            try std.testing.expectEqualStrings("schemas/release-readiness-output.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/release-readiness-output.schema.json", schema.id);
        }
    }
    try std.testing.expect(saw_run_summary);
    try std.testing.expect(saw_bootstrap_event);
    try std.testing.expect(saw_release_readiness);
    try std.testing.expectEqual(run_summary_index.? + 1, bootstrap_event_index.?);
    try std.testing.expectEqual(bootstrap_event_index.? + 1, release_readiness_index.?);
    for (schemas, 0..) |schema, index| {
        for (schemas[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, schema.name, other.name));
            try std.testing.expect(!std.mem.eql(u8, schema.id, other.id));
        }
    }
    var found_inspect_output = false;
    var found_discover_output = false;
    var found_draft_output = false;
    var found_explore_output = false;
    for (schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "inspect-output")) {
            found_inspect_output = true;
            try std.testing.expectEqualStrings("schemas/inspect-output.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/inspect-output.schema.json", schema.id);
        }
        if (std.mem.eql(u8, schema.name, "draft-output")) {
            found_draft_output = true;
            try std.testing.expectEqualStrings("schemas/draft-output.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/draft-output.schema.json", schema.id);
        }
        if (std.mem.eql(u8, schema.name, "discover-output")) {
            found_discover_output = true;
            try std.testing.expectEqualStrings("schemas/discover-output.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/discover-output.schema.json", schema.id);
        }
        if (std.mem.eql(u8, schema.name, "explore-output")) {
            found_explore_output = true;
            try std.testing.expectEqualStrings("schemas/explore-output.schema.json", schema.path);
            try std.testing.expectEqualStrings("https://zmr.dev/schemas/explore-output.schema.json", schema.id);
        }
    }
    try std.testing.expect(found_inspect_output);
    try std.testing.expect(found_discover_output);
    try std.testing.expect(found_draft_output);
    try std.testing.expect(found_explore_output);
    try std.testing.expectEqualStrings("schemas-output", schemas[schemas.len - 1].name);
}

test "registry json output is parseable and count matches entries" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try schema_registry.writeJson(&out.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, @intCast(schema_registry.all().len)), object.get("count").?.integer);
    try std.testing.expectEqual(schema_registry.all().len, object.get("schemas").?.array.items.len);
}
