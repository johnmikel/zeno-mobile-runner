const std = @import("std");
const session = @import("session.zig");

test "session transitions are explicit and attempts retain every run" {
    const allocator = std.testing.allocator;
    var value = try session.Session.init(allocator, "run-1", "device-1", "/tmp/zmr-results");
    defer value.deinit();

    try std.testing.expectEqual(session.SessionState.created, value.state);
    try value.transition(.preflight);
    try value.transition(.ready);
    try value.transition(.running);

    const artifact_path = try value.artifactPath(allocator, "login/basic", 1);
    defer allocator.free(artifact_path);
    try std.testing.expectEqualStrings("/tmp/zmr-results/runs/run-1/attempt-1/login_basic", artifact_path);

    const attempt_index = try value.startAttempt("digest-1", 1, "trace.json", artifact_path);
    try value.finishAttempt(attempt_index, .failed, .infrastructure, "shim timed out");
    try std.testing.expectEqual(@as(usize, 1), value.attempts.items.len);
    try std.testing.expectEqual(session.AttemptStatus.failed, value.attempts.items[0].status);
    try std.testing.expectEqual(session.FailureClass.infrastructure, value.attempts.items[0].failure_class);
    try std.testing.expectEqualStrings("shim timed out", value.attempts.items[0].retry_reason.?);

    try value.transition(.cancelling);
    try value.transition(.closed);
    try std.testing.expectError(error.InvalidSessionTransition, value.transition(.running));
}

test "session only retries infrastructure failures by default" {
    try std.testing.expect(session.shouldRetry(.infrastructure, 0, 2));
    try std.testing.expect(session.shouldRetry(.infrastructure, 1, 2));
    try std.testing.expect(!session.shouldRetry(.infrastructure, 2, 2));
    try std.testing.expect(!session.shouldRetry(.assertion, 0, 2));
    try std.testing.expect(!session.shouldRetry(.application, 0, 2));
}

test "artifact components cannot escape the output directory" {
    const allocator = std.testing.allocator;
    var value = try session.Session.init(allocator, "run/../unsafe", "device", "results");
    defer value.deinit();

    const path = try value.artifactPath(allocator, "../secret", 0);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("results/runs/run_.._unsafe/attempt-0/_.._secret", path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/../") == null);
}
