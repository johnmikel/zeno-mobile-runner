const std = @import("std");
const runner_settle = @import("runner_settle.zig");
const types = @import("types.zig");

/// A device that hands back a fixed sequence of hierarchies and then repeats
/// the last one forever — a UI that moves for a while and then stops.
const SequenceDevice = struct {
    allocator: std.mem.Allocator,
    texts: []const []const u8,
    index: usize = 0,
    snapshots_taken: usize = 0,

    pub fn snapshot(self: *SequenceDevice, writer: anytype) !types.ObservationSnapshot {
        _ = writer;
        self.snapshots_taken += 1;
        const at = @min(self.index, self.texts.len - 1);
        if (self.index + 1 < self.texts.len) self.index += 1;

        const nodes = try self.allocator.alloc(types.UiNode, 1);
        nodes[0] = .{
            .stable_id = try self.allocator.dupe(u8, "node-1"),
            .class_name = try self.allocator.dupe(u8, "android.widget.TextView"),
            .text = try self.allocator.dupe(u8, self.texts[at]),
        };
        return .{
            .id = try self.allocator.dupe(u8, "snap"),
            .timestamp_ms = 1,
            .nodes = nodes,
        };
    }
};

/// A device whose hierarchy never stops changing — a spinner, a clock, a
/// progress bar. Settling must give up gracefully rather than hang or fail.
const RestlessDevice = struct {
    allocator: std.mem.Allocator,
    counter: usize = 0,
    snapshots_taken: usize = 0,

    pub fn snapshot(self: *RestlessDevice, writer: anytype) !types.ObservationSnapshot {
        _ = writer;
        self.counter += 1;
        self.snapshots_taken += 1;
        const label = try std.fmt.allocPrint(self.allocator, "tick {d}", .{self.counter});
        const nodes = try self.allocator.alloc(types.UiNode, 1);
        nodes[0] = .{
            .stable_id = try self.allocator.dupe(u8, "node-1"),
            .class_name = try self.allocator.dupe(u8, "android.widget.TextView"),
            .text = label,
        };
        return .{
            .id = try self.allocator.dupe(u8, "snap"),
            .timestamp_ms = 1,
            .nodes = nodes,
        };
    }
};

const FailingDevice = struct {
    allocator: std.mem.Allocator,

    pub fn snapshot(self: *FailingDevice, writer: anytype) !types.ObservationSnapshot {
        _ = self;
        _ = writer;
        return error.CommandFailed;
    }
};

test "settling stops as soon as the hierarchy stops changing" {
    const allocator = std.testing.allocator;
    var device = SequenceDevice{
        .allocator = allocator,
        .texts = &.{ "Loading", "Almost", "Ready", "Ready" },
    };

    const result = runner_settle.waitForQuiet(allocator, &device, null, .{
        .settle_timeout_ms = 5000,
        .settle_poll_ms = 0,
    });

    try std.testing.expect(result.converged);
    // Two consecutive identical hierarchies is the signal, so it must stop at
    // the first repeat rather than polling until the timeout.
    try std.testing.expectEqual(@as(usize, 4), device.snapshots_taken);
}

test "settling gives up softly when the screen never stops moving" {
    const allocator = std.testing.allocator;
    var device = RestlessDevice{ .allocator = allocator };

    // A clock or a spinner means "settled" is never reachable. Bounding the
    // wait matters more than perfecting the predicate: the run continues.
    const result = runner_settle.waitForQuiet(allocator, &device, null, .{
        .settle_timeout_ms = 40,
        .settle_poll_ms = 0,
    });

    try std.testing.expect(!result.converged);
    try std.testing.expect(device.snapshots_taken >= 2);
}

test "settling never fails a run when the device errors" {
    const allocator = std.testing.allocator;
    var device = FailingDevice{ .allocator = allocator };

    // Settling is best-effort. Only the lookup that follows is allowed to
    // fail, and it produces a far better message than a snapshot error would.
    const result = runner_settle.waitForQuiet(allocator, &device, null, .{
        .settle_timeout_ms = 40,
        .settle_poll_ms = 0,
    });

    try std.testing.expect(!result.converged);
}

test "hierarchy fingerprint reacts to the changes a user would see" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var base = [_]types.UiNode{.{
        .stable_id = "n1",
        .class_name = "android.widget.Button",
        .text = "Save",
        .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
    }};
    const first = runner_settle.fingerprint(.{ .id = "s", .timestamp_ms = 1, .nodes = &base });

    // Same tree, taken again: the id and timestamp differ on a real device, so
    // they must not participate or nothing would ever look settled.
    const again = runner_settle.fingerprint(.{ .id = "different", .timestamp_ms = 999, .nodes = &base });
    try std.testing.expectEqual(first, again);

    var moved = [_]types.UiNode{.{
        .stable_id = "n1",
        .class_name = "android.widget.Button",
        .text = "Save",
        .bounds = .{ .x = 0, .y = 12, .width = 100, .height = 40 },
    }};
    try std.testing.expect(runner_settle.fingerprint(.{ .id = "s", .timestamp_ms = 1, .nodes = &moved }) != first);

    var relabelled = [_]types.UiNode{.{
        .stable_id = "n1",
        .class_name = "android.widget.Button",
        .text = "Saving...",
        .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
    }};
    try std.testing.expect(runner_settle.fingerprint(.{ .id = "s", .timestamp_ms = 1, .nodes = &relabelled }) != first);

    var disabled = [_]types.UiNode{.{
        .stable_id = "n1",
        .class_name = "android.widget.Button",
        .text = "Save",
        .enabled = false,
        .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
    }};
    try std.testing.expect(runner_settle.fingerprint(.{ .id = "s", .timestamp_ms = 1, .nodes = &disabled }) != first);
}

test "the adaptive settle option is wired through the runner" {
    // A capability that ships switched off rots unless something exercises the
    // switch. This pins both directions: off uses the device's own settle, on
    // uses hierarchy polling and does not sleep at all.
    const fake_device = @import("fake_device.zig");
    const runner = @import("runner.zig");
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

    var fixed = fake_device.FakeDevice.init(allocator, snaps);
    defer fixed.deinit();
    try runner.executeStep(allocator, &fixed, .launch, null, .{ .adaptive_settle = false, .settle_ms = 1 });
    try std.testing.expect(fixed.settles > 0);

    var adaptive = fake_device.FakeDevice.init(allocator, snaps);
    defer adaptive.deinit();
    try runner.executeStep(allocator, &adaptive, .launch, null, .{
        .adaptive_settle = true,
        .settle_timeout_ms = 50,
        .settle_poll_ms = 0,
    });
    try std.testing.expectEqual(@as(usize, 0), adaptive.settles);
}
