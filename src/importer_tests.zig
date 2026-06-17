const std = @import("std");
const test_io = @import("test_io.zig");
const importer = @import("importer.zig");

test "flow-yaml importer translates common commands to zmr scenario json" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-flow-yaml";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{
        .sub_path = source_path,
        .data =
        \\appId: com.example.imported
        \\name: Imported smoke
        \\---
        \\- launchApp
        \\- tapOn: "Sign in"
        \\- inputText: "agent@example.com"
        \\- assertVisible:
        \\    id: dashboard-title
        \\- scrollUntilVisible:
        \\    element:
        \\      text: "Invite a teammate"
        \\    direction: DOWN
        \\    timeout: 7000
        \\
        ,
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings(out_path, result.out_path);
    try std.testing.expectEqualStrings("Imported smoke", result.name);
    try std.testing.expectEqualStrings("com.example.imported", result.app_id.?);
    try std.testing.expectEqual(@as(usize, 5), result.step_count);

    const output = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"scrollUntilVisible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"direction\":\"down\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"timeoutMs\":7000") != null);
}
