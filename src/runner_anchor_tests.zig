const std = @import("std");
const runner_anchor = @import("runner_anchor.zig");
const stdio = @import("stdio.zig");

test "without an anchor a wait keeps its full budget" {
    // Existing behavior must be untouched when nothing is anchoring, so this
    // cannot change what already-passing scenarios do.
    const budget = runner_anchor.budgetFor(null, 5000, 1000);
    try std.testing.expectEqual(@as(u64, 5000), budget.timeout_ms);
    try std.testing.expect(!budget.shortened);
}

test "a wait right after an interaction keeps its full budget" {
    var anchor = runner_anchor.Anchor.init();
    const budget = runner_anchor.budgetFor(&anchor, 5000, 1000);
    try std.testing.expectEqual(@as(u64, 5000), budget.timeout_ms);
    try std.testing.expect(!budget.shortened);
}

test "quiet time since the last interaction comes out of the budget" {
    // The screen has had 3 seconds to produce whatever the wait is looking
    // for, so the wait spends the remaining 2 rather than a fresh 5.
    var anchor = runner_anchor.Anchor.at(stdio.nowMs() - 3000);
    const budget = runner_anchor.budgetFor(&anchor, 5000, 1000);
    try std.testing.expect(budget.timeout_ms <= 2000);
    try std.testing.expect(budget.timeout_ms >= 1900);
    try std.testing.expect(budget.shortened);
    try std.testing.expect(budget.quiet_ms >= 3000);
}

test "the floor keeps a long-quiet wait from being starved" {
    // This is the property that keeps the optimization from causing flakes:
    // however long the screen has been quiet, a wait still gets a real chance.
    var anchor = runner_anchor.Anchor.at(stdio.nowMs() - 600_000);
    const budget = runner_anchor.budgetFor(&anchor, 5000, 1000);
    try std.testing.expectEqual(@as(u64, 1000), budget.timeout_ms);
    try std.testing.expect(budget.shortened);
}

test "a timeout below the floor is never inflated by it" {
    // A caller asking for a deliberately short wait must still get a short
    // wait; the floor protects against starvation, it does not override intent.
    var anchor = runner_anchor.Anchor.at(stdio.nowMs() - 600_000);
    const budget = runner_anchor.budgetFor(&anchor, 200, 1000);
    try std.testing.expectEqual(@as(u64, 200), budget.timeout_ms);
    try std.testing.expect(!budget.shortened);
}

test "touching the anchor restores the full budget" {
    var anchor = runner_anchor.Anchor.at(stdio.nowMs() - 4000);
    try std.testing.expect(runner_anchor.budgetFor(&anchor, 5000, 1000).shortened);

    anchor.touch();
    const after = runner_anchor.budgetFor(&anchor, 5000, 1000);
    try std.testing.expectEqual(@as(u64, 5000), after.timeout_ms);
    try std.testing.expect(!after.shortened);
}

test "a shortened budget is recorded so an early failure is explainable" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-anchor-trace";
    const test_io = @import("test_io.zig");
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const trace = @import("trace.zig");
    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();

    var anchor = runner_anchor.Anchor.at(stdio.nowMs() - 4000);
    const budget = runner_anchor.budgetFor(&anchor, 5000, 1000);
    try runner_anchor.recordBudget(&writer, "wait.visible", 5000, budget);

    const events = try test_io.cwd().readFileAlloc(allocator, dir ++ "/events.jsonl", 8192);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "runner.waitBudget") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"requestedTimeoutMs\":5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"quietMs\":") != null);
}

test "an unshortened budget is not recorded" {
    // Noise in the trace costs a reader attention; only the surprising case
    // is worth an event.
    const allocator = std.testing.allocator;
    const dir = "zig-cache/test-anchor-trace-quiet";
    const test_io = @import("test_io.zig");
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const trace = @import("trace.zig");
    var writer = try trace.TraceWriter.init(allocator, dir);
    defer writer.deinit();

    var anchor = runner_anchor.Anchor.init();
    const budget = runner_anchor.budgetFor(&anchor, 5000, 1000);
    try runner_anchor.recordBudget(&writer, "wait.visible", 5000, budget);

    const events = test_io.cwd().readFileAlloc(allocator, dir ++ "/events.jsonl", 8192) catch "";
    defer if (events.len > 0) allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "runner.waitBudget") == null);
}

test "a scenario anchors its own waits without the caller arranging it" {
    // The value only lands if real runs get an anchor by default, so pin that
    // runScenario installs one and that a mutating step stamps it.
    const runner = @import("runner.zig");
    const fake_device = @import("fake_device.zig");
    const types = @import("types.zig");
    const scenario = @import("scenario.zig");
    const allocator = std.testing.allocator;

    const nodes = try allocator.alloc(types.UiNode, 1);
    nodes[0] = .{
        .stable_id = try allocator.dupe(u8, "n1"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, "Ready"),
    };
    var snaps = try allocator.alloc(types.ObservationSnapshot, 1);
    snaps[0] = .{ .id = try allocator.dupe(u8, "s1"), .timestamp_ms = 1, .nodes = nodes };
    defer {
        for (snaps) |snap| snap.deinit(allocator);
        allocator.free(snaps);
    }

    var device = fake_device.FakeDevice.init(allocator, snaps);
    defer device.deinit();

    var steps = [_]scenario.Step{
        .launch,
        .{ .assert_visible = .{ .selector = .{ .text = "Ready" }, .timeout_ms = 1000 } },
    };
    const script = scenario.Scenario{
        .name = "anchored",
        .app_id = "com.example.mobiletest",
        .steps = steps[0..],
    };

    // Passes because the assertion still has a real budget: the scenario just
    // interacted, so nothing is shortened, and the floor protects it anyway.
    try runner.runScenario(allocator, &device, script, null, .{ .settle_ms = 1 });
}
