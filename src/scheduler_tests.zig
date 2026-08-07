const std = @import("std");
const scheduler = @import("scheduler.zig");
const session = @import("session.zig");
const test_io = @import("test_io.zig");

test "split plans assign each scenario to one bounded worker" {
    const allocator = std.testing.allocator;
    const scenarios = [_]scheduler.ScenarioInput{
        .{ .path = "a.json", .digest = "a" },
        .{ .path = "b.json", .digest = "b" },
        .{ .path = "c.json", .digest = "c" },
    };
    const plan = try scheduler.buildPlan(allocator, &scenarios, .{
        .workers = 2,
        .shard_mode = .split,
        .retries = 2,
        .output_dir = "results",
    });
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), plan.items.len);
    try std.testing.expectEqual(@as(u32, 0), plan.items[0].worker_index);
    try std.testing.expectEqual(@as(u32, 1), plan.items[1].worker_index);
    try std.testing.expectEqual(@as(u32, 0), plan.items[2].worker_index);
    try std.testing.expectEqual(@as(u32, 3), plan.items[0].attempt_limit);
}

test "shard all creates a deterministic device matrix" {
    const allocator = std.testing.allocator;
    const scenarios = [_]scheduler.ScenarioInput{
        .{ .path = "a.json", .digest = "a" },
        .{ .path = "b.json", .digest = "b" },
    };
    const plan = try scheduler.buildPlan(allocator, &scenarios, .{
        .workers = 2,
        .shard_mode = .all,
        .output_dir = "results",
    });
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), plan.items.len);
    try std.testing.expectEqualStrings("a.json", plan.items[0].scenario.path);
    try std.testing.expectEqual(@as(u32, 0), plan.items[0].worker_index);
    try std.testing.expectEqualStrings("a.json", plan.items[1].scenario.path);
    try std.testing.expectEqual(@as(u32, 1), plan.items[1].worker_index);
    try std.testing.expectEqualStrings("b.json", plan.items[2].scenario.path);
    try std.testing.expectEqual(@as(u32, 0), plan.items[2].worker_index);
}

test "device leases are exclusive and reusable after release" {
    const allocator = std.testing.allocator;
    var pool = try scheduler.LeasePool.init(allocator, &.{ "android-1", "ios-1" });
    defer pool.deinit();

    const first = pool.acquire().?;
    const second = pool.acquire().?;
    try std.testing.expectEqualStrings("android-1", first.serial);
    try std.testing.expectEqualStrings("ios-1", second.serial);
    try std.testing.expect(pool.acquire() == null);
    pool.release(first);
    const reused = pool.acquire().?;
    try std.testing.expectEqualStrings("android-1", reused.serial);
    pool.release(second);
    pool.release(reused);
}

test "scheduler rejects unbounded workers and retry policy is conservative" {
    const allocator = std.testing.allocator;
    const scenarios = [_]scheduler.ScenarioInput{.{ .path = "a.json", .digest = "a" }};
    try std.testing.expectError(error.WorkerCountOutOfRange, scheduler.buildPlan(allocator, &scenarios, .{ .workers = 0 }));
    try std.testing.expectError(error.WorkerCountOutOfRange, scheduler.buildPlan(allocator, &scenarios, .{ .workers = 65 }));
    try std.testing.expectError(error.RetryCountOutOfRange, scheduler.buildPlan(allocator, &scenarios, .{ .retries = 101 }));

    try std.testing.expect(scheduler.shouldRetry(.infrastructure, 0, 1));
    try std.testing.expect(!scheduler.shouldRetry(.timeout, 0, 1));
    try std.testing.expect(!scheduler.shouldRetry(.assertion, 0, 1));
    _ = session.FailureClass.none;
}

test "workspace discovery is recursive, sorted, and ignores package json" {
    const allocator = std.testing.allocator;
    const root = "zig-cache-test-scheduler-workspace";
    defer test_io.cwd().deleteTree(root) catch {};
    try test_io.cwd().makePath(root ++ "/scenarios/nested");
    try test_io.cwd().makePath(root ++ "/node_modules/ignored");
    try test_io.cwd().writeFile(.{ .sub_path = root ++ "/package.json", .data = "{}" });
    try test_io.cwd().writeFile(.{ .sub_path = root ++ "/scenarios/nested/b.scenario.json", .data = "{}" });
    try test_io.cwd().writeFile(.{ .sub_path = root ++ "/scenarios/a.scenario.json", .data = "{}" });
    try test_io.cwd().writeFile(.{ .sub_path = root ++ "/node_modules/ignored/c.scenario.json", .data = "{}" });

    const paths = try scheduler.discoverScenarioPaths(allocator, root);
    defer scheduler.freeScenarioPaths(allocator, paths);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings(root ++ "/scenarios/a.scenario.json", paths[0]);
    try std.testing.expectEqualStrings(root ++ "/scenarios/nested/b.scenario.json", paths[1]);
}
