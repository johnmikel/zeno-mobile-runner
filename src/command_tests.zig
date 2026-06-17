const std = @import("std");
const test_io = @import("test_io.zig");
const command = @import("command.zig");

const ExecResult = command.ExecResult;
const escapeAdbInputText = command.escapeAdbInputText;
const escapeAdbShellArg = command.escapeAdbShellArg;
const run = command.run;
const runWithInput = command.runWithInput;
const runWithInputTimeout = command.runWithInputTimeout;
const runWithTimeout = command.runWithTimeout;

test "adb text escaping maps spaces" {
    const escaped = try escapeAdbInputText(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("hello%sworld", escaped);
}

test "adb text escaping protects shell metacharacters" {
    const escaped = try escapeAdbInputText(std.testing.allocator, "a&b <c> \"d\" 'e' \\f");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\&b%s\\<c\\>%s\\\"d\\\"%s\\'e\\'%s\\\\f", escaped);
}

test "adb shell argument escaping protects deep link query separators" {
    const escaped = try escapeAdbShellArg(std.testing.allocator, "exampleapp:///e2e-auth?email=a%40example.com&password=Test1234%21&returnTo=%2Fbank-connection");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("'exampleapp:///e2e-auth?email=a%40example.com&password=Test1234%21&returnTo=%2Fbank-connection'", escaped);
}

test "command run captures output and ensureSuccess rejects failures" {
    const allocator = std.testing.allocator;
    var result = try run(allocator, &.{ "/bin/echo", "ok" }, 1024);
    defer result.deinit(allocator);
    try result.ensureSuccess();
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ok") != null);

    const failed = ExecResult{
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "bad"),
        .term = .{ .exited = 7 },
    };
    defer failed.deinit(allocator);
    try std.testing.expectError(error.CommandFailed, failed.ensureSuccess());
}

test "command run with input sends stdin and captures stdout" {
    const allocator = std.testing.allocator;
    var result = try runWithInput(allocator, &.{ "/bin/sh", "-c", "read line; printf 'got:%s' \"$line\"" }, "hello\n", 1024);
    defer result.deinit(allocator);

    try result.ensureSuccess();
    try std.testing.expectEqualStrings("got:hello", result.stdout);
}

test "command run with input timeout terminates stuck child" {
    const allocator = std.testing.allocator;
    var result = try runWithInputTimeout(allocator, &.{ "/bin/sh", "-c", "cat >/dev/null; sleep 5" }, "hello\n", 1024, 50);
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
    try std.testing.expectError(error.CommandTimedOut, result.ensureSuccess());
}

test "command run with timeout terminates stuck child" {
    const allocator = std.testing.allocator;
    var result = try runWithTimeout(allocator, &.{ "/bin/sh", "-c", "sleep 5" }, 1024, 50);
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
    try std.testing.expectError(error.CommandTimedOut, result.ensureSuccess());
}

test "command timeout terminates shell child process group" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pid_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/child.pid", .{tmp.sub_path});
    defer allocator.free(pid_path);

    var result = try runWithTimeout(
        allocator,
        &.{ "/bin/sh", "-c", "sleep 5 & child=$!; echo \"$child\" > \"$1\"; wait \"$child\"", "sh", pid_path },
        1024,
        500,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
    try std.testing.expectError(error.CommandTimedOut, result.ensureSuccess());

    const pid_bytes = try test_io.readFileAllocIn(tmp.dir, allocator, "child.pid", 128);
    defer allocator.free(pid_bytes);
    const pid = std.mem.trim(u8, pid_bytes, " \n\r\t");

    var probe = try run(allocator, &.{ "/bin/sh", "-c", "kill -0 \"$1\" 2>/dev/null", "sh", pid }, 1024);
    defer probe.deinit(allocator);
    const alive = switch (probe.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (alive) {
        var cleanup = try run(allocator, &.{ "/bin/sh", "-c", "kill -TERM \"$1\" 2>/dev/null || true", "sh", pid }, 1024);
        defer cleanup.deinit(allocator);
    }
    try std.testing.expect(!alive);
}
