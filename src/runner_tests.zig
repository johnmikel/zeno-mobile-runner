const std = @import("std");
const test_io = @import("test_io.zig");
const runner = @import("runner.zig");
const scenario = @import("scenario.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

const runScenario = runner.runScenario;
const tapSelector = runner.tapSelector;
const waitUntilVisible = runner.waitUntilVisible;
const waitUntilNotVisible = runner.waitUntilNotVisible;
const waitUntilAnyVisible = runner.waitUntilAnyVisible;
const scrollUntilVisible = runner.scrollUntilVisible;

test "wait any matches the first visible selector candidate" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const nodes = try allocator.alloc(types.UiNode, 1);
    nodes[0] = .{
        .stable_id = try allocator.dupe(u8, "node-home"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, "Home"),
    };
    var snaps = try allocator.alloc(types.ObservationSnapshot, 1);
    snaps[0] = .{
        .id = try allocator.dupe(u8, "snapshot-1"),
        .timestamp_ms = 1,
        .nodes = nodes,
    };
    defer {
        snaps[0].deinit(allocator);
        allocator.free(snaps);
    }

    var fake = fake_device.FakeDevice.init(allocator, snaps);
    defer fake.deinit();
    const selectors = [_]selector.Selector{ .{ .text = "Missing" }, .{ .text = "Home" } };
    const matched = try waitUntilAnyVisible(&fake, selectors[0..], 10, null, .{ .settle_ms = 0, .poll_ms = 1 });
    try std.testing.expectEqual(@as(?usize, 1), matched);
}

test "wait any retries through transient observation command timeouts" {
    const allocator = std.testing.allocator;

    const FlakySnapshotDevice = struct {
        allocator: std.mem.Allocator,
        snapshots: usize = 0,

        pub fn snapshot(self: *@This(), writer: ?*trace.TraceWriter) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            if (self.snapshots == 1) return error.CommandTimedOut;

            const nodes = try self.allocator.alloc(types.UiNode, 1);
            nodes[0] = .{
                .stable_id = try self.allocator.dupe(u8, "node-ready"),
                .class_name = try self.allocator.dupe(u8, "android.widget.TextView"),
                .text = try self.allocator.dupe(u8, "Ready"),
            };
            return .{
                .id = try self.allocator.dupe(u8, "snapshot-ready"),
                .timestamp_ms = 1,
                .nodes = nodes,
            };
        }
    };

    var fake = FlakySnapshotDevice{ .allocator = allocator };
    const selectors = [_]selector.Selector{.{ .text = "Ready" }};
    const matched = try waitUntilAnyVisible(&fake, selectors[0..], 100, null, .{ .settle_ms = 0, .poll_ms = 0 });
    try std.testing.expectEqual(@as(?usize, 0), matched);
    try std.testing.expectEqual(@as(usize, 2), fake.snapshots);
}

test "tap retries through transient empty snapshots" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "empty", null, .{});
    try appendTextSnapshot(allocator, &snapshots, "tap-target", "Tap Target", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    try tapSelector(&fake, .{ .text = "Tap Target" }, null, .{ .settle_ms = 0, .poll_ms = 0, .action_timeout_ms = 100 });

    try std.testing.expectEqual(@as(usize, 1), fake.taps);
}

test "runner uses native selector actions when a device exposes them" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-selector-actions";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const NativeSelectorDevice = struct {
        allocator: std.mem.Allocator,
        native_taps: usize = 0,
        native_types: usize = 0,
        native_erases: usize = 0,
        fallback_taps: usize = 0,
        fallback_types: usize = 0,
        fallback_erases: usize = 0,
        snapshots: usize = 0,
        settles: usize = 0,

        pub fn install(self: *@This(), path: []const u8) !void {
            _ = self;
            _ = path;
        }

        pub fn launch(self: *@This()) !void {
            _ = self;
        }

        pub fn stop(self: *@This()) !void {
            _ = self;
        }

        pub fn clearState(self: *@This()) !void {
            _ = self;
        }

        pub fn openLink(self: *@This(), url: []const u8) !void {
            _ = self;
            _ = url;
        }

        pub fn tapBySelector(self: *@This(), wanted: selector.Selector) !bool {
            try std.testing.expectEqualStrings("Continue", wanted.text.?);
            self.native_taps += 1;
            return true;
        }

        pub fn typeTextBySelector(self: *@This(), wanted: selector.Selector, text: []const u8) !bool {
            try std.testing.expectEqualStrings("Email", wanted.text.?);
            try std.testing.expectEqualStrings("agent name", text);
            self.native_types += 1;
            return true;
        }

        pub fn eraseTextBySelector(self: *@This(), wanted: selector.Selector, max_chars: u32) !bool {
            try std.testing.expectEqualStrings("Email", wanted.text.?);
            try std.testing.expectEqual(@as(u32, 5), max_chars);
            self.native_erases += 1;
            return true;
        }

        pub fn tap(self: *@This(), x: i32, y: i32) !void {
            _ = x;
            _ = y;
            self.fallback_taps += 1;
        }

        pub fn typeText(self: *@This(), text: []const u8) !void {
            _ = text;
            self.fallback_types += 1;
        }

        pub fn eraseText(self: *@This(), max_chars: u32) !void {
            _ = max_chars;
            self.fallback_erases += 1;
        }

        pub fn hideKeyboard(self: *@This()) !void {
            _ = self;
        }

        pub fn swipe(self: *@This(), x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
            _ = self;
            _ = x1;
            _ = y1;
            _ = x2;
            _ = y2;
            _ = duration_ms;
        }

        pub fn pressBack(self: *@This()) !void {
            _ = self;
        }

        pub fn settle(self: *@This(), timeout_ms: u64) !void {
            _ = timeout_ms;
            self.settles += 1;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeSelectorDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();
    const script_json =
        \\{
        \\  "name": "native selector flow",
        \\  "steps": [
        \\    {"action": "tap", "selector": {"text": "Continue"}},
        \\    {"action": "typeText", "selector": {"text": "Email"}, "text": "agent name"},
        \\    {"action": "eraseText", "selector": {"text": "Email"}, "maxChars": 5}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try runScenario(allocator, &device, script, &tw, .{ .settle_ms = 0, .poll_ms = 0 });

    try std.testing.expectEqual(@as(usize, 1), device.native_taps);
    try std.testing.expectEqual(@as(usize, 1), device.native_types);
    try std.testing.expectEqual(@as(usize, 1), device.native_erases);
    try std.testing.expectEqual(@as(usize, 0), device.fallback_taps);
    try std.testing.expectEqual(@as(usize, 0), device.fallback_types);
    try std.testing.expectEqual(@as(usize, 0), device.fallback_erases);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.tap\",\"payload\":{\"status\":\"started\",\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.type\",\"payload\":{\"status\":\"started\",\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.eraseText\",\"payload\":{\"status\":\"started\",\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"selector\":{\"text\":\"Email\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"text\":\"agent name\"") != null);
}

test "runner uses native selector queries for waits when a device exposes them" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-waits";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const NativeWaitDevice = struct {
        allocator: std.mem.Allocator,
        queries: usize = 0,
        snapshots: usize = 0,

        pub fn visibleBySelector(self: *@This(), wanted: selector.Selector) !?bool {
            self.queries += 1;
            if (wanted.text) |text| return std.mem.eql(u8, text, "Ready");
            if (wanted.id) |id| return std.mem.eql(u8, id, "visible");
            return null;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeWaitDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try waitUntilVisible(&device, .{ .text = "Ready" }, 1000, &tw, .{ .poll_ms = 0 }));
    try std.testing.expect(try waitUntilNotVisible(&device, .{ .id = "gone" }, 1000, &tw, .{ .poll_ms = 0 }));
    const selectors = [_]selector.Selector{ .{ .text = "Missing" }, .{ .text = "Ready" } };
    try std.testing.expectEqual(@as(?usize, 1), try waitUntilAnyVisible(&device, selectors[0..], 1000, &tw, .{ .poll_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);
    try std.testing.expect(device.queries >= 4);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.visible\",\"payload\":{\"status\":\"ok\",\"strategy\":\"nativeSelector\",\"selector\":{\"text\":\"Ready\"},\"timeoutMs\":1000}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.notVisible\",\"payload\":{\"status\":\"ok\",\"strategy\":\"nativeSelector\",\"selector\":{\"id\":\"gone\"},\"timeoutMs\":1000}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.any\",\"payload\":{\"status\":\"ok\",\"strategy\":\"nativeSelector\",\"matchedIndex\":1,\"selector\":{\"text\":\"Ready\"},\"timeoutMs\":1000}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"matchedIndex\":1") != null);
}

test "native selector wait falls back to snapshot after query command timeout" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-wait-timeout-snapshot-fallback";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const NativeTimeoutThenSnapshotDevice = struct {
        allocator: std.mem.Allocator,
        native_queries: usize = 0,
        largest_query_timeout_ms: u64 = 0,
        snapshots: usize = 0,

        pub fn visibleBySelectorWithTimeout(self: *@This(), wanted: selector.Selector, timeout_ms: u64) !?bool {
            try std.testing.expectEqualStrings("Personal details", wanted.text.?);
            self.native_queries += 1;
            self.largest_query_timeout_ms = @max(self.largest_query_timeout_ms, timeout_ms);
            return error.CommandTimedOut;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            const nodes = try self.allocator.alloc(types.UiNode, 1);
            nodes[0] = .{
                .stable_id = try self.allocator.dupe(u8, "node-native-timeout-fallback"),
                .class_name = try self.allocator.dupe(u8, "XCUIElementTypeStaticText"),
                .text = try self.allocator.dupe(u8, "Personal details"),
                .bounds = .{ .x = 20, .y = 280, .width = 300, .height = 44 },
            };
            return .{
                .id = try self.allocator.dupe(u8, "native-timeout-fallback"),
                .timestamp_ms = 1,
                .nodes = nodes,
            };
        }
    };

    var device = NativeTimeoutThenSnapshotDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try waitUntilVisible(
        &device,
        .{ .text = "Personal details" },
        100,
        &tw,
        .{ .settle_ms = 0, .poll_ms = 0, .action_timeout_ms = 5 },
    ));
    try std.testing.expectEqual(@as(usize, 2), device.native_queries);
    try std.testing.expect(device.largest_query_timeout_ms <= 5);
    try std.testing.expectEqual(@as(usize, 1), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.retry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"CommandTimedOut\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"target\":\"node-native-timeout-fallback\"") != null);
}

test "scroll until visible uses native selector queries before snapshot fallback" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-scroll";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const NativeScrollDevice = struct {
        allocator: std.mem.Allocator,
        queries: usize = 0,
        snapshots: usize = 0,
        swipes: usize = 0,
        settles: usize = 0,
        last_swipe: ?struct { x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32 } = null,

        pub fn visibleBySelectorWithTimeout(self: *@This(), wanted: selector.Selector, timeout_ms: u64) !?bool {
            try std.testing.expect(timeout_ms > 0);
            self.queries += 1;
            if (wanted.id) |id| {
                try std.testing.expectEqualStrings("legal-documents-card", id);
                return self.queries >= 3;
            }
            return null;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }

        pub fn scrollViewport(self: *@This()) !types.Viewport {
            _ = self;
            return .{ .width = 390, .height = 844 };
        }

        pub fn swipe(self: *@This(), x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
            self.swipes += 1;
            self.last_swipe = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .duration_ms = duration_ms };
        }

        pub fn settle(self: *@This(), timeout_ms: u64) !void {
            _ = timeout_ms;
            self.settles += 1;
        }
    };

    var device = NativeScrollDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try scrollUntilVisible(&device, .{ .id = "legal-documents-card" }, 1000, .down, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 3), device.queries);
    try std.testing.expectEqual(@as(usize, 2), device.swipes);
    try std.testing.expectEqual(@as(usize, 2), device.settles);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);
    try std.testing.expectEqual(@as(i32, 195), device.last_swipe.?.x1);
    try std.testing.expectEqual(@as(i32, 675), device.last_swipe.?.y1);
    try std.testing.expectEqual(@as(i32, 253), device.last_swipe.?.y2);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.scrollUntilVisible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"selector\":{\"id\":\"legal-documents-card\"}") != null);
}

test "native selector wait timeouts include final snapshot diagnostics" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-wait-diagnostics";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const NativeTimeoutDevice = struct {
        allocator: std.mem.Allocator,
        queries: usize = 0,
        snapshots: usize = 0,

        pub fn visibleBySelector(self: *@This(), wanted: selector.Selector) !?bool {
            _ = wanted;
            self.queries += 1;
            return false;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            const nodes = try self.allocator.alloc(types.UiNode, 1);
            nodes[0] = .{
                .stable_id = try self.allocator.dupe(u8, "visible-title"),
                .class_name = try self.allocator.dupe(u8, "XCUIElementTypeStaticText"),
                .text = try self.allocator.dupe(u8, "Expo Dev Menu"),
                .bounds = .{ .x = 0, .y = 0, .width = 300, .height = 50 },
                .enabled = true,
                .visible = true,
            };
            return .{
                .id = try self.allocator.dupe(u8, "native-timeout-final"),
                .timestamp_ms = 1,
                .viewport = .{ .width = 390, .height = 844 },
                .active_package = try self.allocator.dupe(u8, "com.example.mobiletest"),
                .active_activity = try self.allocator.dupe(u8, "ExampleActivity"),
                .nodes = nodes,
            };
        }
    };

    var device = NativeTimeoutDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(!try waitUntilVisible(&device, .{ .text = "Dashboard" }, 0, &tw, .{ .poll_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 1), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"snapshotId\":\"native-timeout-final\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"timeoutMs\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"visibleTexts\":[\"Expo Dev Menu\"]") != null);
}

test "runner assertion traces preserve replay metadata" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assertion-replay-metadata";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "assert-visible", "Assert Me", .{});
    try appendTextSnapshot(allocator, &snapshots, "assert-not-visible", "Home", .{});
    try appendTextSnapshot(allocator, &snapshots, "assert-none-visible", "Home", .{});
    try appendTextSnapshot(allocator, &snapshots, "assert-healthy", "Still healthy", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const script_json =
        \\{
        \\  "name": "assertion replay metadata",
        \\  "steps": [
        \\    {"action": "assertVisible", "selector": {"text": "Assert Me"}, "timeoutMs": 3456},
        \\    {"action": "assertNotVisible", "selector": {"text": "Missing Toast"}, "timeoutMs": 4567},
        \\    {"action": "assertNoneVisible", "selectors": [{"textContains": "Crash"}, {"textContains": "Fatal"}], "timeoutMs": 1234},
        \\    {"action": "assertHealthy", "timeoutMs": 2345}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try runScenario(allocator, &fake, script, &tw, .{ .settle_ms = 0, .poll_ms = 0 });

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.visible\",\"payload\":{\"status\":\"ok\",\"target\":\"node-assert-visible\",\"selector\":{\"text\":\"Assert Me\"},\"timeoutMs\":3456}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.notVisible\",\"payload\":{\"status\":\"ok\",\"selector\":{\"text\":\"Missing Toast\"},\"timeoutMs\":4567}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.noneVisible\",\"payload\":{\"status\":\"ok\",\"selectors\":[{\"textContains\":\"Crash\"},{\"textContains\":\"Fatal\"}],\"timeoutMs\":1234}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.healthy\",\"payload\":{\"status\":\"ok\",\"timeoutMs\":2345}") != null);
}

test "runner executes agent flow primitives and records trace events" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-flow";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "snap-start", "Start", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-tap", "Tap Target", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-type", "Email Field", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-erase", "Email Field", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-wait-visible", "Visible", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-wait-gone", "Different", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-wait-any", "Any Match", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-assert-visible", "Assert Me", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-assert-not-visible", "No Gone Here", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-optional-miss", "Alternative", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-conditional", "Conditional", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-skip-conditional", "Other Branch", .{});
    try appendTextSnapshot(allocator, &snapshots, "snap-scroll-before", "Before Scroll", .{ .width = 100, .height = 200 });
    try appendTextSnapshot(allocator, &snapshots, "snap-scroll-after", "Scroll Target", .{ .width = 100, .height = 200 });

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const script_json =
        \\{
        \\  "name": "full flow",
        \\  "steps": [
        \\    {"action": "launch"},
        \\    {"action": "snapshot"},
        \\    {"action": "tap", "selector": {"text": "Tap Target"}},
        \\    {"action": "typeText", "selector": {"text": "Email Field"}, "text": "agent name"},
        \\    {"action": "eraseText", "selector": {"text": "Email Field"}, "maxChars": 4},
        \\    {"action": "hideKeyboard"},
        \\    {"action": "swipe", "x1": 10, "y1": 20, "x2": 30, "y2": 40, "durationMs": 50},
        \\    {"action": "pressBack"},
        \\    {"action": "waitVisible", "selector": {"text": "Visible"}, "timeoutMs": 10},
        \\    {"action": "waitNotVisible", "selector": {"text": "Gone"}, "timeoutMs": 10},
        \\    {"action": "waitAny", "selectors": [{"text": "Missing"}, {"text": "Any Match"}], "timeoutMs": 10},
        \\    {"action": "assertVisible", "selector": {"text": "Assert Me"}},
        \\    {"action": "assertNotVisible", "selector": {"text": "Gone"}},
        \\    {"action": "optional", "step": {"action": "tap", "selector": {"text": "Missing Optional"}}},
        \\    {"action": "whenVisible", "selector": {"text": "Conditional"}, "steps": [
        \\      {"action": "typeText", "text": "conditional"}
        \\    ]},
        \\    {"action": "whenVisible", "selector": {"text": "Missing Branch"}, "steps": [
        \\      {"action": "typeText", "text": "not-run"}
        \\    ]},
        \\    {"action": "repeat", "times": 2, "steps": [
        \\      {"action": "eraseText", "maxChars": 1}
        \\    ]},
        \\    {"action": "scrollUntilVisible", "selector": {"text": "Scroll Target"}, "direction": "up", "timeoutMs": 1000},
        \\    {"action": "sleep", "ms": 0},
        \\    {"action": "stop"},
        \\    {"action": "clearState"}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try runScenario(allocator, &fake, script, &tw, .{ .settle_ms = 0, .poll_ms = 0, .default_timeout_ms = 10, .action_timeout_ms = 0 });

    try std.testing.expect(fake.launched);
    try std.testing.expect(fake.stopped);
    try std.testing.expect(fake.cleared);
    try std.testing.expectEqual(@as(usize, 3), fake.taps);
    try std.testing.expectEqual(@as(usize, 2), fake.typed_text.items.len);
    try std.testing.expectEqualStrings("agent name", fake.typed_text.items[0]);
    try std.testing.expectEqualStrings("conditional", fake.typed_text.items[1]);
    try std.testing.expectEqual(@as(usize, 3), fake.erases);
    try std.testing.expectEqual(@as(u32, 1), fake.last_erase_chars);
    try std.testing.expectEqual(@as(usize, 1), fake.hides_keyboard);
    try std.testing.expectEqual(@as(usize, 2), fake.swipes);
    try std.testing.expectEqual(@as(i32, 50), fake.last_swipe.?.x1);
    try std.testing.expectEqual(@as(i32, 60), fake.last_swipe.?.y1);
    try std.testing.expectEqual(@as(i32, 160), fake.last_swipe.?.y2);
    try std.testing.expectEqual(@as(usize, 1), fake.presses_back);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"scenario.start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"observe.snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.tap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"selector\":{\"text\":\"Email Field\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"text\":\"agent name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.swipe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"x1\":10,\"y1\":20,\"x2\":30,\"y2\":40,\"durationMs\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.pressBack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.visible\",\"payload\":{\"status\":\"ok\",\"target\":\"node-snap-wait-visible\",\"selector\":{\"text\":\"Visible\"},\"timeoutMs\":10}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.notVisible\",\"payload\":{\"status\":\"ok\",\"selector\":{\"text\":\"Gone\"},\"timeoutMs\":10}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.any\",\"payload\":{\"status\":\"ok\",\"matchedIndex\":1,\"target\":\"node-snap-wait-any\",\"selector\":{\"text\":\"Any Match\"},\"timeoutMs\":10}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"step.optional\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"step.whenVisible.skipped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.scrollUntilVisible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.scrollUntilVisible\",\"payload\":{\"status\":\"ok\",\"target\":\"node-snap-scroll-after\",\"selector\":{\"text\":\"Scroll Target\"},\"direction\":\"up\",\"timeoutMs\":1000}") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"scenario.end\"") != null);
}

test "runner settles through the device hook after mutating actions" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "button"),
        .class_name = try allocator.dupe(u8, "android.widget.Button"),
        .text = try allocator.dupe(u8, "Tap Target"),
        .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
    };
    const nodes = try allocator.alloc(types.UiNode, 1);
    nodes[0] = node;
    var snapshots = try allocator.alloc(types.ObservationSnapshot, 1);
    snapshots[0] = .{
        .id = try allocator.dupe(u8, "snapshot-settle"),
        .timestamp_ms = 1,
        .nodes = nodes,
    };
    defer {
        snapshots[0].deinit(allocator);
        allocator.free(snapshots);
    }

    var fake = fake_device.FakeDevice.init(allocator, snapshots);
    defer fake.deinit();
    const script = try scenario.parseSlice(allocator,
        \\{
        \\  "name": "settle hook",
        \\  "steps": [
        \\    {"action": "launch"},
        \\    {"action": "openLink", "url": "exampleapp://settle"},
        \\    {"action": "tap", "selector": {"text": "Tap Target"}},
        \\    {"action": "typeText", "text": "hello"},
        \\    {"action": "pressBack"}
        \\  ]
        \\}
    );
    defer script.deinit(allocator);

    try runScenario(allocator, &fake, script, null, .{ .settle_ms = 123, .poll_ms = 0, .action_timeout_ms = 0 });

    try std.testing.expectEqual(@as(usize, 5), fake.settles);
    try std.testing.expectEqual(@as(u64, 123), fake.last_settle_timeout_ms);
}

test "runner timeout diagnostics include selectors active window and visible text" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-diagnostics";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendDiagnosticSnapshot(allocator, &snapshots, "diag-any");
    try appendTextSnapshot(allocator, &snapshots, "diag-not-visible", "Still Visible", .{});
    try appendTextSnapshot(allocator, &snapshots, "diag-scroll", "Before Scroll", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const selectors = [_]selector.Selector{ .{ .text = "Missing" }, .{ .content_desc_contains = "Other" } };
    try std.testing.expectEqual(@as(?usize, null), try waitUntilAnyVisible(&fake, selectors[0..], 0, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expect(!try waitUntilNotVisible(&fake, .{ .text = "Still Visible" }, 0, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expect(!try scrollUntilVisible(&fake, .{ .text = "Never" }, 0, .down, &tw, .{ .settle_ms = 0, .poll_ms = 0 }));

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.any\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"timeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"activePackage\":\"com.example.mobiletest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"activeActivity\":\".MainActivity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"visibleTexts\":[\"Home\",\"Settings\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"wait.notVisible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.scrollUntilVisible\"") != null);
}

test "tap diagnostics report hidden disabled offscreen and nearest text candidates" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-actionable-diagnostics";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const nodes = try allocator.alloc(types.UiNode, 4);
    nodes[0] = .{
        .stable_id = try allocator.dupe(u8, "node-disabled"),
        .class_name = try allocator.dupe(u8, "android.widget.Button"),
        .text = try allocator.dupe(u8, "Sign in"),
        .bounds = .{ .x = 40, .y = 80, .width = 160, .height = 60 },
        .enabled = false,
    };
    nodes[1] = .{
        .stable_id = try allocator.dupe(u8, "node-hidden"),
        .class_name = try allocator.dupe(u8, "android.widget.Button"),
        .text = try allocator.dupe(u8, "Sign in"),
        .bounds = .{ .x = 40, .y = 160, .width = 160, .height = 60 },
        .visible = false,
    };
    nodes[2] = .{
        .stable_id = try allocator.dupe(u8, "node-offscreen"),
        .class_name = try allocator.dupe(u8, "android.widget.Button"),
        .text = try allocator.dupe(u8, "Sign in"),
        .bounds = .{ .x = 40, .y = 1400, .width = 160, .height = 60 },
    };
    nodes[3] = .{
        .stable_id = try allocator.dupe(u8, "node-near"),
        .class_name = try allocator.dupe(u8, "android.widget.Button"),
        .text = try allocator.dupe(u8, "Sign up"),
        .bounds = .{ .x = 40, .y = 260, .width = 160, .height = 60 },
    };

    var snaps = try allocator.alloc(types.ObservationSnapshot, 1);
    snaps[0] = .{
        .id = try allocator.dupe(u8, "diag-actionable"),
        .timestamp_ms = 1,
        .viewport = .{ .width = 720, .height = 1280 },
        .nodes = nodes,
    };
    defer {
        snaps[0].deinit(allocator);
        allocator.free(snaps);
    }

    var fake = fake_device.FakeDevice.init(allocator, snaps);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expectError(
        error.SelectorNotFound,
        tapSelector(&fake, .{ .text = "Sign in" }, &tw, .{ .settle_ms = 0, .poll_ms = 0, .action_timeout_ms = 0 }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.taps);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.tap.notFound\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"disabledCandidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"stableId\":\"node-disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"hiddenCandidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"stableId\":\"node-hidden\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"offscreenCandidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"stableId\":\"node-offscreen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"nearestTextMatches\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"text\":\"Sign up\"") != null);
}

test "runner records terminal failure events before returning an error" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-failure-events";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "failure-start", "Only visible text", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const script_json =
        \\{
        \\  "name": "failing flow",
        \\  "steps": [
        \\    {"action": "waitVisible", "selector": {"text": "Never appears"}, "timeoutMs": 0}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try std.testing.expectError(
        error.WaitTimeout,
        runScenario(allocator, &fake, script, &tw, .{ .settle_ms = 0, .poll_ms = 0 }),
    );

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"step.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"index\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"WaitTimeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"scenario.end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"failed\"") != null);
}

test "runner records launch command failure diagnostics" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-launch-diagnostics";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    const adb_path = "zig-cache/test-runner-launch-fail-adb.sh";
    test_io.cwd().deleteFile(adb_path) catch {};
    defer test_io.cwd().deleteFile(adb_path) catch {};
    try test_io.cwd().makePath("zig-cache");
    var adb_file = try test_io.cwd().createFile(adb_path, .{ .truncate = true });
    try adb_file.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\if [[ "${1:-}" == "-s" ]]; then shift 2; fi
        \\if [[ "${1:-}" == "shell" && "${2:-}" == "monkey" ]]; then
        \\  echo "launch failed" >&2
        \\  exit 7
        \\fi
        \\exec ./tests/fake-adb.sh "$@"
        \\
    );
    try adb_file.chmod(0o755);
    adb_file.close();

    var device = try @import("android.zig").AndroidDevice.init(allocator, adb_path, "fake-android-1", "com.example.mobiletest");
    defer device.deinit();
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const script = try scenario.parseSlice(allocator,
        \\{"name":"launch diagnostics","steps":[{"action":"launch"}]}
    );
    defer script.deinit(allocator);

    try std.testing.expectError(error.CommandFailed, runScenario(allocator, &device, script, &tw, .{ .settle_ms = 0 }));

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"app.launch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"CommandFailed\"") != null);
}

test "runner records native selector tap command failure diagnostics" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-tap-diagnostics";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shim = try test_io.createFileIn(tmp.dir, "fake-ios-shim-tap-fail.sh", .{ .truncate = true });
    try shim.writeAll(
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\request="$(cat)"
    );
    const shim_tail = try std.fmt.allocPrint(allocator,
        \\
        \\printf '%s\n' "$request" >> ".zig-cache/tmp/{s}/shim.log"
        \\case "$request" in
        \\  *'"cmd":"tap"'*) printf '{{"status":"error","message":"not found"}}\n' ;;
        \\  *) printf '{{"status":"ok","nodes":[]}}\n' ;;
        \\esac
        \\
    , .{tmp.sub_path});
    defer allocator.free(shim_tail);
    try shim.writeAll(shim_tail);
    try shim.chmod(0o755);
    shim.close();

    const shim_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-ios-shim-tap-fail.sh", .{tmp.sub_path});
    defer allocator.free(shim_path);

    var device = try @import("ios.zig").IosDevice.initWithShim(allocator, "./tests/fake-xcrun.sh", "fake-ios-1", "com.example.mobiletest", shim_path);
    defer device.deinit();
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expectError(
        error.IosShimResponseNotOk,
        tapSelector(&device, .{ .text = "Manage" }, &tw, .{ .settle_ms = 0 }),
    );

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.tap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"error\":\"IosShimResponseNotOk\"") != null);
}

test "assert none visible fails when a crash overlay is present" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-none-visible";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "redbox", "Uncaught Error", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const script_json =
        \\{
        \\  "name": "guard app errors",
        \\  "steps": [
        \\    {"action": "assertNoneVisible", "selectors": [
        \\      {"textContains": "Uncaught Error"},
        \\      {"textContains": "Application has crashed"}
        \\    ], "timeoutMs": 0}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try std.testing.expectError(
        error.AssertionFailed,
        runScenario(allocator, &fake, script, &tw, .{ .settle_ms = 0, .poll_ms = 0 }),
    );

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.noneVisible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"Uncaught Error\"") != null);
}

test "assert healthy fails on common mobile error overlays" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-assert-healthy";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "dev-error", "Failed to connect to /10.0.2.2:8081", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const script_json =
        \\{
        \\  "name": "guard app health",
        \\  "steps": [
        \\    {"action": "assertHealthy", "timeoutMs": 0}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try std.testing.expectError(
        error.AssertionFailed,
        runScenario(allocator, &fake, script, &tw, .{ .settle_ms = 0, .poll_ms = 0 }),
    );

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try test_io.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"assert.healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"status\":\"unhealthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "Failed to connect") != null);
}

test "runner writes trace manifest for failed scenarios" {
    const allocator = std.testing.allocator;
    const fake_device = @import("fake_device.zig");
    const dir = "zig-cache-test-runner-failure-manifest";
    test_io.cwd().deleteTree(dir) catch {};
    defer test_io.cwd().deleteTree(dir) catch {};

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "failure-start", "Only visible text", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    const script_json =
        \\{
        \\  "name": "manifest failure",
        \\  "appId": "com.example.mobiletest",
        \\  "steps": [
        \\    {"action": "waitVisible", "selector": {"text": "Never appears"}, "timeoutMs": 0}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try std.testing.expectError(
        error.WaitTimeout,
        runScenario(allocator, &fake, script, &tw, .{ .settle_ms = 0, .poll_ms = 0 }),
    );

    const manifest_path = try std.fs.path.join(allocator, &.{ dir, "trace.json" });
    defer allocator.free(manifest_path);
    const manifest = try test_io.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"scenarioName\":\"manifest failure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"appId\":\"com.example.mobiletest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"failedStepIndex\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"error\":\"WaitTimeout\"") != null);
}

test "scroll until visible uses default viewport for downward scroll" {
    const fake_device = @import("fake_device.zig");
    const allocator = std.testing.allocator;

    var snapshots = std.ArrayList(types.ObservationSnapshot).empty;
    defer {
        for (snapshots.items) |snap| snap.deinit(allocator);
        snapshots.deinit(allocator);
    }
    try appendTextSnapshot(allocator, &snapshots, "scroll-default-before", "Before", .{});
    try appendTextSnapshot(allocator, &snapshots, "scroll-default-after", "Target", .{});

    var fake = fake_device.FakeDevice.init(allocator, snapshots.items);
    defer fake.deinit();

    try std.testing.expect(try scrollUntilVisible(&fake, .{ .text = "Target" }, 1000, .down, null, .{ .settle_ms = 0, .poll_ms = 0 }));
    try std.testing.expectEqual(@as(usize, 1), fake.swipes);
    try std.testing.expectEqual(@as(i32, 360), fake.last_swipe.?.x1);
    try std.testing.expectEqual(@as(i32, 1024), fake.last_swipe.?.y1);
    try std.testing.expectEqual(@as(i32, 384), fake.last_swipe.?.y2);
}

fn appendTextSnapshot(
    allocator: std.mem.Allocator,
    snapshots: *std.ArrayList(types.ObservationSnapshot),
    id: []const u8,
    text: ?[]const u8,
    viewport: types.Viewport,
) !void {
    const node_count: usize = if (text == null) 0 else 1;
    const nodes = try allocator.alloc(types.UiNode, node_count);
    errdefer allocator.free(nodes);
    if (text) |value| {
        nodes[0] = .{
            .stable_id = try std.fmt.allocPrint(allocator, "node-{s}", .{id}),
            .class_name = try allocator.dupe(u8, "android.widget.TextView"),
            .text = try allocator.dupe(u8, value),
            .bounds = .{ .x = 10, .y = 20, .width = 80, .height = 40 },
        };
    }
    try snapshots.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .timestamp_ms = @as(i64, @intCast(snapshots.items.len + 1)),
        .viewport = viewport,
        .nodes = nodes,
    });
}

fn appendDiagnosticSnapshot(
    allocator: std.mem.Allocator,
    snapshots: *std.ArrayList(types.ObservationSnapshot),
    id: []const u8,
) !void {
    const nodes = try allocator.alloc(types.UiNode, 3);
    nodes[0] = .{
        .stable_id = try allocator.dupe(u8, "node-home"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, "Home"),
        .bounds = .{ .x = 1, .y = 1, .width = 10, .height = 10 },
    };
    nodes[1] = .{
        .stable_id = try allocator.dupe(u8, "node-settings"),
        .class_name = try allocator.dupe(u8, "android.widget.ImageButton"),
        .content_desc = try allocator.dupe(u8, "Settings"),
        .bounds = .{ .x = 2, .y = 2, .width = 10, .height = 10 },
    };
    nodes[2] = .{
        .stable_id = try allocator.dupe(u8, "node-hidden"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, "Hidden"),
        .visible = false,
    };
    try snapshots.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .timestamp_ms = @as(i64, @intCast(snapshots.items.len + 1)),
        .viewport = .{ .width = 1080, .height = 2400 },
        .active_package = try allocator.dupe(u8, "com.example.mobiletest"),
        .active_activity = try allocator.dupe(u8, ".MainActivity"),
        .nodes = nodes,
    });
}
