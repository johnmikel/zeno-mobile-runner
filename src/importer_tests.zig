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

test "flow-yaml importer emits compatibility diagnostics for unsupported commands" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-compatibility";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    const report_path = root ++ "/compatibility.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{ .sub_path = source_path, .data =
        \\name: Compatibility smoke
        \\---
        \\- launchApp
        \\- evalScript: "return true"
        \\- takeScreenshot
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{
        .compatibility_report_path = report_path,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.step_count);
    try std.testing.expectEqual(@as(usize, 1), result.unsupported_count);
    try std.testing.expectEqualStrings(report_path, result.compatibility_report_path.?);

    const report = try test_io.cwd().readFileAlloc(allocator, report_path, 1024 * 1024);
    defer allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "evalScript") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "line") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "arbitrary JavaScript") != null);
}

test "flow-yaml importer strict mode rejects unsupported commands" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-strict";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{ .sub_path = source_path, .data =
        \\---
        \\- evalScript: "return true"
    });
    try std.testing.expectError(error.UnsupportedImportCommand, importer.importFlowYamlFile(allocator, source_path, out_path, .{ .strict = true }));
}

test "flow-yaml importer resolves nested workspace flows" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-nested";
    const source_path = root ++ "/main.yaml";
    const nested_path = root ++ "/auth.yaml";
    const out_path = root ++ "/scenario.json";
    const report_path = root ++ "/compatibility.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{
        .sub_path = nested_path,
        .data =
        \\name: Auth flow
        \\---
        \\- launchApp
        \\- tapOn: "Sign in"
        \\
        ,
    });
    try test_io.cwd().writeFile(.{
        .sub_path = source_path,
        .data =
        \\name: Workspace flow
        \\---
        \\- runFlow: auth.yaml
        \\- takeScreenshot
        \\
        ,
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{ .compatibility_report_path = report_path });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), result.step_count);
    const output = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"launch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"tap\"") != null);
    const report = try test_io.cwd().readFileAlloc(allocator, report_path, 1024 * 1024);
    defer allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "auth.yaml") != null);
}

test "flow-yaml importer translates device state commands" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-device-state";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{
        .sub_path = source_path,
        .data =
        \\---
        \\- grantPermissions:
        \\    permissions:
        \\      - android.permission.CAMERA
        \\- setOrientation: LANDSCAPE
        \\- setClipboard: copied
        \\
        ,
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), result.step_count);
    const output = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "grantPermissions") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "setOrientation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "setClipboard") != null);
}

test "flow-yaml importer translates bounded repeat and retry blocks" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-flow-control";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{
        .sub_path = source_path,
        .data =
        \\---
        \\- repeat:
        \\    times: 2
        \\    commands:
        \\      - tapOn: "More"
        \\- retry:
        \\    maxRetries: 2
        \\    commands:
        \\      - waitUntilVisible: "Ready"
        \\
        ,
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.step_count);
    const output = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"repeat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"times\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"retry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"attempts\":3") != null);
}

test "flow-yaml importer translates conditional command blocks" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-conditions";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{
        .sub_path = source_path,
        .data =
        \\---
        \\- whenVisible:
        \\    visible: "Continue"
        \\    commands:
        \\      - tapOn: "Continue"
        \\
        ,
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{});
    defer result.deinit(allocator);
    const output = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"whenVisible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"text\":\"Continue\"") != null);
}

test "flow-yaml importer preserves flow hooks" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-hooks";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{
        .sub_path = source_path,
        .data =
        \\name: Hooked flow
        \\onFlowStart:
        \\  - launchApp
        \\onFlowComplete:
        \\  - takeScreenshot
        \\---
        \\- tapOn: "Continue"
        \\
        ,
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{});
    defer result.deinit(allocator);
    const output = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"onStart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"onComplete\"") != null);
}

test "flow-yaml importer translates launchApp options and clearKeychain" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-importer-launch-options";
    const source_path = root ++ "/flow.yaml";
    const out_path = root ++ "/scenario.json";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root);
    try test_io.cwd().writeFile(.{
        .sub_path = source_path,
        .data =
        \\appId: com.example.imported
        \\---
        \\- launchApp:
        \\    appId: com.example.other
        \\    stopApp: false
        \\    clearState: true
        \\    clearKeychain: true
        \\    arguments:
        \\      foo: "bar"
        \\      enabled: false
        \\      count: 3
        \\- clearKeychain
        \\
        ,
    });

    const result = try importer.importFlowYamlFile(allocator, source_path, out_path, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.step_count);
    const output = try test_io.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"launchApp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stopApp\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"clearKeychain\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"foo\":\"bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"action\":\"clearKeychain\"") != null);
}
