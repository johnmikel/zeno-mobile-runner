const std = @import("std");
const android_shell = @import("android_shell.zig");
const scenario = @import("scenario.zig");

test "android shell helpers build escaped open link intent args" {
    var args = try android_shell.openLinkIntent(
        std.testing.allocator,
        "exampleapp:///e2e-auth?email=a%40example.com&password=Test1234%21&returnTo=%2Fbank-connection",
        "com.example.mobiletest",
    );
    defer args.deinit();

    try std.testing.expectEqual(@as(usize, 8), args.items().len);
    try std.testing.expectEqualStrings("shell", args.items()[0]);
    try std.testing.expectEqualStrings("am", args.items()[1]);
    try std.testing.expectEqualStrings("start", args.items()[2]);
    try std.testing.expectEqualStrings("-a", args.items()[3]);
    try std.testing.expectEqualStrings("android.intent.action.VIEW", args.items()[4]);
    try std.testing.expectEqualStrings("-d", args.items()[5]);
    try std.testing.expectEqualStrings("'exampleapp:///e2e-auth?email=a%40example.com&password=Test1234%21&returnTo=%2Fbank-connection'", args.items()[6]);
    try std.testing.expectEqualStrings("com.example.mobiletest", args.items()[7]);
}

test "android shell helpers build fallback input action args" {
    var tap = try android_shell.tap(std.testing.allocator, 10, 20);
    defer tap.deinit();
    try std.testing.expectEqualStrings("input", tap.items()[1]);
    try std.testing.expectEqualStrings("tap", tap.items()[2]);
    try std.testing.expectEqualStrings("10", tap.items()[3]);
    try std.testing.expectEqualStrings("20", tap.items()[4]);

    var typed = try android_shell.typeText(std.testing.allocator, "hello world");
    defer typed.deinit();
    try std.testing.expectEqualStrings("text", typed.items()[2]);
    try std.testing.expectEqualStrings("hello%sworld", typed.items()[3]);

    var swipe = try android_shell.swipe(std.testing.allocator, 1, 2, 3, 4, 5);
    defer swipe.deinit();
    try std.testing.expectEqualStrings("swipe", swipe.items()[2]);
    try std.testing.expectEqualStrings("1", swipe.items()[3]);
    try std.testing.expectEqualStrings("2", swipe.items()[4]);
    try std.testing.expectEqualStrings("3", swipe.items()[5]);
    try std.testing.expectEqualStrings("4", swipe.items()[6]);
    try std.testing.expectEqualStrings("5", swipe.items()[7]);
}

test "android shell helpers build erase and back key args" {
    var erase = try android_shell.eraseText(std.testing.allocator, 3);
    defer erase.deinit();
    try std.testing.expectEqualStrings("sh", erase.items()[1]);
    try std.testing.expectEqualStrings("-c", erase.items()[2]);
    try std.testing.expect(std.mem.indexOf(u8, erase.items()[3], "while [ $i -lt 3 ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, erase.items()[3], "KEYCODE_DEL") != null);

    var back = try android_shell.pressBack(std.testing.allocator);
    defer back.deinit();
    try std.testing.expectEqualStrings("input", back.items()[1]);
    try std.testing.expectEqualStrings("keyevent", back.items()[2]);
    try std.testing.expectEqualStrings("BACK", back.items()[3]);
}

test "android shell press key keeps the key as an argument" {
    var args = try android_shell.pressKey(std.testing.allocator, "ENTER");
    defer args.deinit();
    try std.testing.expectEqualStrings("keyevent", args.items()[2]);
    try std.testing.expectEqualStrings("ENTER", args.items()[3]);
}

test "android shell builds typed launch extras" {
    const arguments = [_]scenario.LaunchArgument{
        .{ .name = "foo", .value = .{ .string = "hello world" } },
        .{ .name = "enabled", .value = .{ .boolean = true } },
        .{ .name = "count", .value = .{ .integer = 3 } },
        .{ .name = "ratio", .value = .{ .double = 3.25 } },
    };
    var args = try android_shell.launchWithArguments(std.testing.allocator, "com.example/.MainActivity", arguments[0..]);
    defer args.deinit();

    try std.testing.expectEqualStrings("shell", args.items()[0]);
    try std.testing.expectEqualStrings("-W", args.items()[3]);
    try std.testing.expectEqualStrings("-n", args.items()[4]);
    try std.testing.expectEqualStrings("com.example/.MainActivity", args.items()[5]);
    try std.testing.expectEqualStrings("--es", args.items()[6]);
    try std.testing.expectEqualStrings("'foo'", args.items()[7]);
    try std.testing.expectEqualStrings("'hello world'", args.items()[8]);
    try std.testing.expectEqualStrings("--ez", args.items()[9]);
    try std.testing.expectEqualStrings("'enabled'", args.items()[10]);
    try std.testing.expectEqualStrings("true", args.items()[11]);
}
