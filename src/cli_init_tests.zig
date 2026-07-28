const std = @import("std");
const cli_init = @import("cli_init.zig");
const test_io = @import("test_io.zig");

test "parse args rejects missing option values and extra paths" {
    try std.testing.expectError(error.MissingAppId, cli_init.parseArgs(&.{"--app-id"}));
    try std.testing.expectError(error.MissingDirectory, cli_init.parseArgs(&.{"--dir"}));
    try std.testing.expectError(error.unknownFlag, cli_init.parseArgs(&.{ "a.json", "b.json" }));
}

test "parse args records whether an app id was supplied" {
    const without = try cli_init.parseArgs(&.{"--app"});
    try std.testing.expect(!without.app_id_set);

    const with = try cli_init.parseArgs(&.{ "--app", "--app-id", "com.acme.app" });
    try std.testing.expect(with.app_id_set);
    try std.testing.expectEqualStrings("com.acme.app", with.app_id);
}

const derive_dir = "zig-cache/cli-init-derive-test";

fn writeAppJson(body: []const u8) !void {
    try test_io.cwd().makePath(derive_dir);
    try test_io.cwd().writeFile(.{
        .sub_path = derive_dir ++ "/app.json",
        .data = body,
    });
}

test "derives the app id from an expo ios bundle identifier" {
    defer test_io.cwd().deleteTree(derive_dir) catch {};
    try writeAppJson(
        \\{"expo":{"name":"myapp","ios":{"bundleIdentifier":"com.acme.myapp"}}}
    );

    const derived = try cli_init.deriveExpoAppId(std.testing.allocator, derive_dir);
    try std.testing.expect(derived != null);
    defer std.testing.allocator.free(derived.?);
    try std.testing.expectEqualStrings("com.acme.myapp", derived.?);
}

test "falls back to the expo android package when ios has no bundle identifier" {
    defer test_io.cwd().deleteTree(derive_dir) catch {};
    try writeAppJson(
        \\{"expo":{"ios":{"supportsTablet":true},"android":{"package":"com.acme.droid"}}}
    );

    const derived = try cli_init.deriveExpoAppId(std.testing.allocator, derive_dir);
    try std.testing.expect(derived != null);
    defer std.testing.allocator.free(derived.?);
    try std.testing.expectEqualStrings("com.acme.droid", derived.?);
}

test "returns null for a fresh expo app that has no bundle id yet" {
    defer test_io.cwd().deleteTree(derive_dir) catch {};
    // Exactly the shape `create-expo-app --template blank-typescript` writes:
    // an ios block with no bundleIdentifier and no android package.
    try writeAppJson(
        \\{"expo":{"name":"myapp","slug":"myapp","ios":{"supportsTablet":true}}}
    );

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try cli_init.deriveExpoAppId(std.testing.allocator, derive_dir),
    );
}

test "returns null when app.json is absent or unparseable" {
    defer test_io.cwd().deleteTree(derive_dir) catch {};
    try test_io.cwd().makePath(derive_dir);
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try cli_init.deriveExpoAppId(std.testing.allocator, derive_dir),
    );

    try writeAppJson("not json at all");
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try cli_init.deriveExpoAppId(std.testing.allocator, derive_dir),
    );

    try writeAppJson(
        \\{"expo":"a string, not an object"}
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try cli_init.deriveExpoAppId(std.testing.allocator, derive_dir),
    );
}
