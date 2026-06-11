const std = @import("std");

const cli_devices = @import("cli_devices.zig");
const cli_doctor = @import("cli_doctor.zig");
const cli_import = @import("cli_import.zig");
const cli_info = @import("cli_info.zig");
const cli_init = @import("cli_init.zig");
const cli_output = @import("cli_output.zig");
const cli_run = @import("cli_run.zig");
const cli_serve = @import("cli_serve.zig");
const cli_trace = @import("cli_trace.zig");
const cli_validate = @import("cli_validate.zig");
const config_paths = @import("config_paths.zig");
const device_registry = @import("device_registry.zig");
const fake_device = @import("fake_device.zig");
const ios_devices = @import("ios_devices.zig");
const json_rpc_protocol = @import("json_rpc_protocol.zig");
const runner = @import("runner.zig");
const runner_events = @import("runner_events.zig");
const runner_native = @import("runner_native.zig");
const run_options = @import("run_options.zig");
const scenario = @import("scenario.zig");
const schema_registry = @import("schema_registry.zig");
const selector = @import("selector.zig");
const trace = @import("trace.zig");
const trace_summary = @import("trace_summary.zig");
const types = @import("types.zig");
const validation = @import("validation.zig");

test "fake device can run a probe-style scenario" {
    const allocator = std.testing.allocator;
    const node = types.UiNode{
        .stable_id = try allocator.dupe(u8, "probe-node"),
        .class_name = try allocator.dupe(u8, "android.widget.TextView"),
        .text = try allocator.dupe(u8, "E2E auth probe"),
        .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
    };
    const nodes = try allocator.alloc(types.UiNode, 1);
    nodes[0] = node;
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

    const script_json =
        \\{
        \\  "name": "fake probe",
        \\  "steps": [
        \\    {"action": "openLink", "url": "exampleapp://e2e-auth?probe=1"},
        \\    {"action": "waitVisible", "selector": {"text": "E2E auth probe"}, "timeoutMs": 10}
        \\  ]
        \\}
    ;
    const script = try scenario.parseSlice(allocator, script_json);
    defer script.deinit(allocator);

    try runner.runScenario(allocator, &fake, script, null, .{ .settle_ms = 0, .poll_ms = 1, .default_timeout_ms = 10 });
    try std.testing.expectEqualStrings("exampleapp://e2e-auth?probe=1", fake.opened_link.?);
}

test "validation output includes field and source location diagnostics" {
    const allocator = std.testing.allocator;
    const result = validation.Result{
        .ok = false,
        .error_code = try allocator.dupe(u8, "scenario.invalid"),
        .message = try allocator.dupe(u8, "scenario is invalid"),
        .path = try allocator.dupe(u8, "$.steps"),
        .line = 3,
        .column = 3,
    };
    defer result.deinit(allocator);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try cli_output.writeValidationText(text.writer(allocator), "bad.json", result);
    try std.testing.expectEqualStrings("bad.json: invalid [scenario.invalid] scenario is invalid at $.steps line 3 column 3\n", text.items);

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try cli_output.writeValidationJson(json.writer(allocator), "bad.json", result);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"fieldPath\":\"$.steps\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"line\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"column\":3") != null);
}

test "cli output module preserves validation field source diagnostics" {
    const allocator = std.testing.allocator;
    const result = validation.Result{
        .ok = false,
        .error_code = try allocator.dupe(u8, "scenario.invalid"),
        .message = try allocator.dupe(u8, "scenario is invalid"),
        .path = try allocator.dupe(u8, "$.steps"),
        .line = 3,
        .column = 3,
    };
    defer result.deinit(allocator);

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try cli_output.writeValidationJson(json.writer(allocator), "bad.json", result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json.items, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("$.steps", parsed.value.object.get("fieldPath").?.string);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("column").?.integer);
}

test "runner events module writes selector miss diagnostics for agents" {
    const selectors = [_]selector.Selector{.{ .text = "Sign in" }};
    var nodes = [_]types.UiNode{
        .{
            .stable_id = "text:Sign up:0",
            .class_name = "android.widget.TextView",
            .text = "Sign up",
            .bounds = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
        },
    };
    const snap = types.ObservationSnapshot{
        .id = "snapshot-1",
        .timestamp_ms = 1,
        .viewport = .{ .width = 320, .height = 640 },
        .active_package = "com.example",
        .active_activity = ".MainActivity",
        .nodes = nodes[0..],
    };

    var json = std.ArrayList(u8).empty;
    defer json.deinit(std.testing.allocator);
    try runner_events.writeSelectorDiagnosticJson(json.writer(std.testing.allocator), "not_found", null, selectors[0..], snap);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("not_found", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("snapshot-1", parsed.value.object.get("snapshotId").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("nearestTextMatches").?.array.items.len);
}

test "json rpc protocol module writes stable capabilities and device readiness" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const id = std.json.Value{ .integer = 7 };

    try json_rpc_protocol.writeCapabilitiesResult(out.writer(std.testing.allocator), id);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"protocolVersion\":\"2026-04-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"observe.semanticSnapshot\"") != null);

    out.clearRetainingCapacity();
    const devices = [_]types.DeviceInfo{
        .{ .serial = "sim-1", .state = "Booted" },
        .{ .serial = "phone-1", .state = "unavailable" },
    };
    try json_rpc_protocol.writeDevicesResult(out.writer(std.testing.allocator), id, devices[0..]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"serial\":\"sim-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ready\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"serial\":\"phone-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ready\":false") != null);
}

test "trace summary module preserves partial visual capture diagnostics" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-trace-summary-partial";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);

    {
        var manifest = try std.fs.cwd().createFile(dir ++ "/trace.json", .{ .truncate = true });
        defer manifest.close();
        try manifest.writeAll(
            "{\"schemaVersion\":1,\"runnerVersion\":\"0.2.0\",\"protocolVersion\":\"2026-04-28\",\"scenarioName\":\"ios partial\",\"appId\":\"com.example.mobiletest\",\"status\":\"partial\",\"startedAtMs\":1,\"endedAtMs\":101,\"durationMs\":100,\"failedStepIndex\":null,\"error\":null,\"eventsPath\":\"events.jsonl\",\"artifactsDir\":\"artifacts\",\"eventCount\":2,\"snapshotCount\":1,\"partialFailureCount\":1,\"reportPath\":null}\n",
        );
    }
    {
        var events = try std.fs.cwd().createFile(dir ++ "/events.jsonl", .{ .truncate = true });
        defer events.close();
        try events.writeAll(
            "{\"seq\":1,\"timestampMs\":1,\"kind\":\"observe.snapshot.semanticExtraction\",\"payload\":{\"status\":\"failed\",\"artifactStatus\":\"captured\",\"semanticStatus\":\"failed\",\"error\":\"CommandFailed\",\"screenshotArtifact\":\"artifacts/snapshot-1.png\",\"source\":\"ios-xctest-shim\"}}\n" ++
                "{\"seq\":2,\"timestampMs\":2,\"kind\":\"scenario.end\",\"payload\":{\"status\":\"passed\"}}\n",
        );
    }

    var summary = try trace_summary.read(allocator, dir);
    defer summary.deinit(allocator);

    try std.testing.expectEqualStrings("ios partial", summary.scenario_name);
    try std.testing.expectEqualStrings("partial", summary.status);
    try std.testing.expectEqual(@as(i64, 1), summary.partial_failure_count.?);
    try std.testing.expect(summary.partial_failure != null);
    try std.testing.expectEqualStrings("observe.snapshot.semanticExtraction", summary.partial_failure.?.kind.?);
    try std.testing.expectEqualStrings("captured", summary.partial_failure.?.artifact_status.?);
    try std.testing.expectEqualStrings("failed", summary.partial_failure.?.semantic_status.?);
    try std.testing.expectEqualStrings("artifacts/snapshot-1.png", summary.partial_failure.?.screenshot_artifact.?);
    try std.testing.expectEqualStrings("partial", summary.status);
    try std.testing.expectEqualStrings("observe.snapshot.semanticExtraction", summary.diagnostic.kind.?);
}

test "ios device discovery module filters simulators and physical devices" {
    const allocator = std.testing.allocator;

    const simulators = try ios_devices.parseSimulatorsJson(allocator,
        \\{"devices":{"iOS 18.0":[
        \\{"name":"Ready","udid":"sim-1","state":"Booted","isAvailable":true},
        \\{"name":"Shutdown","udid":"sim-2","state":"Shutdown","isAvailable":true},
        \\{"name":"Missing","udid":"sim-3","state":"Booted","isAvailable":false}
        \\]}}
    );
    defer {
        for (simulators) |device| device.deinit(allocator);
        allocator.free(simulators);
    }
    try std.testing.expectEqual(@as(usize, 1), simulators.len);
    try std.testing.expectEqualStrings("sim-1", simulators[0].serial);

    const physical = try ios_devices.parsePhysicalDevicesJson(allocator,
        \\{"result":{"devices":[
        \\{"identifier":"ios-ready","connectionProperties":{"pairingState":"connected"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"ios-ready"}},
        \\{"identifier":"watch","hardwareProperties":{"platform":"watchOS","reality":"physical","udid":"watch"}}
        \\]}}
    );
    defer {
        for (physical) |device| device.deinit(allocator);
        allocator.free(physical);
    }
    try std.testing.expectEqual(@as(usize, 1), physical.len);
    try std.testing.expectEqualStrings("ios-ready", physical[0].serial);
    try std.testing.expectEqualStrings("connected", physical[0].state);
}

test "pilot scenario examples parse" {
    const allocator = std.testing.allocator;
    const probe = try scenario.parseFile(allocator, "examples/android-app-auth-probe.json");
    defer probe.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", probe.app_id.?);
    try std.testing.expect(probe.steps.len > 0);

    const login = try scenario.parseFile(allocator, "examples/android-app-login-smoke.json");
    defer login.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", login.app_id.?);
    try std.testing.expect(login.steps.len > probe.steps.len);

    const demo = try scenario.parseFile(allocator, "examples/demo-fake.json");
    defer demo.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", demo.app_id.?);

    const android_shim_smoke = try scenario.parseFile(allocator, "examples/android-shim-smoke.json");
    defer android_shim_smoke.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", android_shim_smoke.app_id.?);

    const ios_smoke = try scenario.parseFile(allocator, "examples/ios-smoke.json");
    defer ios_smoke.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", ios_smoke.app_id.?);
    try std.testing.expectEqual(@as(usize, 3), ios_smoke.steps.len);

    const ios_shim_smoke = try scenario.parseFile(allocator, "examples/ios-shim-smoke.json");
    defer ios_shim_smoke.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", ios_shim_smoke.app_id.?);
    try std.testing.expect(ios_shim_smoke.steps.len > ios_smoke.steps.len);
    for (ios_shim_smoke.steps) |step| {
        try std.testing.expect(std.meta.activeTag(step) != .open_link);
    }
    try std.testing.expectEqual(@as(std.meta.Tag(scenario.Step), .type_text), std.meta.activeTag(ios_shim_smoke.steps[3]));
    try std.testing.expect(ios_shim_smoke.steps[3].type_text.selector != null);
    try std.testing.expectEqualStrings("demo_input", ios_shim_smoke.steps[3].type_text.selector.?.id.?);

    const ios_dev_client = try scenario.parseFile(allocator, "examples/ios-dev-client-open-link.json");
    defer ios_dev_client.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", ios_dev_client.app_id.?);
    try std.testing.expect(ios_dev_client.steps.len > ios_smoke.steps.len);
    try std.testing.expectEqual(@as(std.meta.Tag(scenario.Step), .open_link), std.meta.activeTag(ios_dev_client.steps[1]));
    // The dev-client smoke must prove the launcher is gone before declaring
    // health: tokens like "Home" or "Continue" also match dev-launcher chrome
    // and would turn the run green without the app's JS bundle ever loading.
    try std.testing.expectEqual(@as(std.meta.Tag(scenario.Step), .wait_any), std.meta.activeTag(ios_dev_client.steps[2]));
    for (ios_dev_client.steps[2].wait_any.selectors) |wanted| {
        if (wanted.text_contains) |needle| {
            try std.testing.expect(!std.mem.eql(u8, needle, "Home"));
            try std.testing.expect(!std.mem.eql(u8, needle, "Continue"));
            try std.testing.expect(!std.mem.eql(u8, needle, "Sign in"));
        }
    }
    try std.testing.expectEqual(@as(std.meta.Tag(scenario.Step), .assert_none_visible), std.meta.activeTag(ios_dev_client.steps[3]));
    try std.testing.expectEqualStrings("Development servers", ios_dev_client.steps[3].assert_none_visible.selectors[0].text_contains.?);
    try std.testing.expectEqualStrings("No development servers", ios_dev_client.steps[3].assert_none_visible.selectors[1].text_contains.?);

    const ios_dev_client_route = try scenario.parseFile(allocator, "examples/ios-dev-client-route-snapshot.json");
    defer ios_dev_client_route.deinit(allocator);
    try std.testing.expectEqualStrings("com.example.mobiletest", ios_dev_client_route.app_id.?);
    try std.testing.expectEqual(@as(std.meta.Tag(scenario.Step), .open_link), std.meta.activeTag(ios_dev_client_route.steps[1]));
    try std.testing.expectEqual(@as(std.meta.Tag(scenario.Step), .assert_none_visible), std.meta.activeTag(ios_dev_client_route.steps[3]));
    try std.testing.expectEqual(@as(std.meta.Tag(scenario.Step), .snapshot), std.meta.activeTag(ios_dev_client_route.steps[ios_dev_client_route.steps.len - 1]));
}

test "platform parser accepts supported values" {
    try std.testing.expectEqual(@as(run_options.Platform, .android), try cli_run.parsePlatform("android"));
    try std.testing.expectEqual(@as(run_options.Platform, .ios), try cli_run.parsePlatform("ios"));
    try std.testing.expectError(error.UnsupportedPlatform, cli_run.parsePlatform("windows"));
}

test "config paths module resolves app-local files and bare commands" {
    const allocator = std.testing.allocator;

    const root = try config_paths.rootForPath(allocator, "apps/sample/.zmr/config.json");
    defer allocator.free(root);
    try std.testing.expectEqualStrings("apps/sample", root);

    var owned = std.ArrayList([]const u8).empty;
    defer {
        for (owned.items) |path| allocator.free(path);
        owned.deinit(allocator);
    }

    const scenario_path = try config_paths.ownFilePath(allocator, &owned, root, ".zmr/android-smoke.json");
    try std.testing.expectEqualStrings("apps/sample/.zmr/android-smoke.json", scenario_path);

    const adb_path = try config_paths.ownCommandPath(allocator, &owned, root, "adb");
    try std.testing.expectEqualStrings("adb", adb_path);

    const shim_path = try config_paths.ownCommandPath(allocator, &owned, root, "./tools/ios-shim");
    try std.testing.expectEqualStrings("apps/sample/./tools/ios-shim", shim_path);
}

test "runner native module handles selector tap without snapshot fallback" {
    const allocator = std.testing.allocator;
    const dir = "zig-cache-test-runner-native-module";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    const NativeDevice = struct {
        allocator: std.mem.Allocator,
        taps: usize = 0,
        snapshots: usize = 0,
        settles: usize = 0,

        pub fn tapBySelector(self: *@This(), wanted: selector.Selector) !bool {
            try std.testing.expectEqualStrings("Continue", wanted.text.?);
            self.taps += 1;
            return true;
        }

        pub fn settle(self: *@This(), timeout_ms: u64) !void {
            try std.testing.expectEqual(@as(u64, 25), timeout_ms);
            self.settles += 1;
        }

        pub fn snapshot(self: *@This(), writer: anytype) !types.ObservationSnapshot {
            _ = writer;
            self.snapshots += 1;
            return error.UnexpectedSnapshotFallback;
        }
    };

    var device = NativeDevice{ .allocator = allocator };
    var tw = try trace.TraceWriter.init(allocator, dir);
    defer tw.deinit();

    try std.testing.expect(try runner_native.tryTapSelector(&device, .{ .text = "Continue" }, &tw, 25));
    try std.testing.expectEqual(@as(usize, 1), device.taps);
    try std.testing.expectEqual(@as(usize, 1), device.settles);
    try std.testing.expectEqual(@as(usize, 0), device.snapshots);

    const events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    defer allocator.free(events_path);
    const events = try std.fs.cwd().readFileAlloc(allocator, events_path, 1024 * 1024);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"kind\":\"ui.tap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"strategy\":\"nativeSelector\"") != null);
}

test "public schema files parse as json" {
    const allocator = std.testing.allocator;
    for (schema_registry.all()) |schema_info| {
        const content = try std.fs.cwd().readFileAlloc(allocator, schema_info.path, 1024 * 1024);
        defer allocator.free(content);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
}

test "device registry readiness keeps disconnected physical devices unavailable to agents" {
    try std.testing.expect(device_registry.isReady(.android, "device"));
    try std.testing.expect(device_registry.isReady(.ios, "Booted"));
    try std.testing.expect(device_registry.isReady(.ios, "connected"));
    try std.testing.expect(!device_registry.isReady(.ios, "disconnected"));
    try std.testing.expect(!device_registry.isReady(.ios, "unavailable"));
}

test "cli devices module parses ios scope and registry platform" {
    try std.testing.expectEqual(cli_devices.IosDevicesScope.all, try cli_devices.parseIosDevicesScope("all"));
    try std.testing.expectEqual(cli_devices.IosDevicesScope.simulator, try cli_devices.parseIosDevicesScope("simulator"));
    try std.testing.expectError(error.UnsupportedIosDeviceType, cli_devices.parseIosDevicesScope("watch"));
    try std.testing.expectEqual(device_registry.Platform.ios, cli_devices.registryPlatform(.ios));
    try std.testing.expectEqual(device_registry.Platform.android, cli_devices.registryPlatform(.android));
}

test "cli doctor module parses flags for app-local setup diagnostics" {
    const parsed = try cli_doctor.parseArgs(&.{
        "--json",
        "--strict",
        "--config",
        ".zmr/config.json",
        "--adb",
        "./tools/adb",
        "--ios-shim",
        "./.zmr/ios-shim",
    });

    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.strict);
    try std.testing.expect(parsed.explicit_config);
    try std.testing.expectEqualStrings(".zmr/config.json", parsed.config_path.?);
    try std.testing.expectEqualStrings("./tools/adb", parsed.options.adb_path);
    try std.testing.expectEqualStrings("./.zmr/ios-shim", parsed.options.ios_shim_path.?);
}

test "cli validate module parses scenario path and json flag" {
    const parsed = try cli_validate.parseArgs(&.{ "examples/demo-fake.json", "--json" });
    try std.testing.expectEqualStrings("examples/demo-fake.json", parsed.path);
    try std.testing.expect(parsed.json);
    try std.testing.expectError(error.MissingScenarioPath, cli_validate.parseArgs(&.{}));
    try std.testing.expectError(error.UnknownFlag, cli_validate.parseArgs(&.{ "examples/demo-fake.json", "--wat" }));
}

test "cli info module parses shared json flag for metadata commands" {
    try std.testing.expect(!(try cli_info.parseJsonFlag(&.{})));
    try std.testing.expect(try cli_info.parseJsonFlag(&.{"--json"}));
    try std.testing.expectError(error.UnknownFlag, cli_info.parseJsonFlag(&.{"--wat"}));
}

test "cli init module parses app scaffold and scenario modes" {
    const app = try cli_init.parseArgs(&.{ "--app", "--dir", "apps/mobile", "--app-id", "com.example.app", "--json" });
    try std.testing.expect(app.app_scaffold);
    try std.testing.expect(app.json);
    try std.testing.expectEqualStrings("apps/mobile", app.dir);
    try std.testing.expectEqualStrings("com.example.app", app.app_id);

    const scenario_init = try cli_init.parseArgs(&.{ "smoke.json", "--force" });
    try std.testing.expect(!scenario_init.app_scaffold);
    try std.testing.expect(scenario_init.force);
    try std.testing.expectEqualStrings("smoke.json", scenario_init.path);

    try std.testing.expectError(error.UnknownFlag, cli_init.parseArgs(&.{ "--app", "smoke.json" }));
}

test "cli import module parses flow yaml migration options" {
    const parsed = try cli_import.parseArgs(&.{
        "flow-yaml",
        "flows/login.yaml",
        "--out",
        ".zmr/login.json",
        "--name",
        "Login smoke",
        "--app-id",
        "com.example.app",
        "--force",
        "--json",
    });

    try std.testing.expectEqualStrings("flow-yaml", parsed.format);
    try std.testing.expectEqualStrings("flows/login.yaml", parsed.source_path);
    try std.testing.expectEqualStrings(".zmr/login.json", parsed.out_path.?);
    try std.testing.expectEqualStrings("Login smoke", parsed.name.?);
    try std.testing.expectEqualStrings("com.example.app", parsed.app_id.?);
    try std.testing.expect(parsed.force);
    try std.testing.expect(parsed.json);
    try std.testing.expectError(error.MissingImportFormat, cli_import.parseArgs(&.{}));
    try std.testing.expectError(error.MissingImportOut, cli_import.parseArgs(&.{ "flow-yaml", "flows/login.yaml" }));
}

test "cli trace module parses report explain and export commands" {
    const report_args = try cli_trace.parseReportArgs(&.{ "traces/run", "--out", "report.html" });
    try std.testing.expectEqualStrings("traces/run", report_args.input_path);
    try std.testing.expectEqualStrings("report.html", report_args.out_path.?);

    const explain_args = try cli_trace.parseExplainArgs(&.{ "--json", "traces/run" });
    try std.testing.expect(explain_args.json);
    try std.testing.expectEqualStrings("traces/run", explain_args.trace_dir.?);

    const export_args = try cli_trace.parseExportArgs(&.{ "traces/run", "--out", "trace.zmrtrace", "--omit-screenshots" });
    try std.testing.expectEqualStrings("traces/run", export_args.trace_dir);
    try std.testing.expectEqualStrings("trace.zmrtrace", export_args.out_path.?);
    try std.testing.expect(export_args.redact);
    try std.testing.expect(export_args.omit_screenshots);
    try std.testing.expectError(error.MissingReportInput, cli_trace.parseReportArgs(&.{}));
    try std.testing.expectError(error.MissingTraceDir, cli_trace.parseExplainArgs(&.{}));
    try std.testing.expectError(error.MissingTraceBundleOutput, cli_trace.parseExportArgs(&.{"traces/run"}));
}

test "cli serve module parses json rpc and mcp options" {
    const serve_args = try cli_serve.parseServeArgs(&.{
        "--transport",
        "tcp",
        "--port",
        "9001",
        "--platform",
        "ios",
        "--ios-device-type",
        "physical",
        "--device",
        "phone-1",
        "--app-id",
        "com.example.app",
        "--trace-dir",
        "traces/rpc",
        "--xcrun",
        "./tools/xcrun",
        "--ios-shim",
        "./.zmr/ios-shim",
    });
    try std.testing.expectEqualStrings("tcp", serve_args.transport);
    try std.testing.expectEqual(@as(u16, 9001), serve_args.port);
    try std.testing.expectEqual(run_options.Platform.ios, serve_args.raw.platform);
    try std.testing.expectEqual(run_options.IosDeviceType.physical, serve_args.raw.ios_device_type);
    try std.testing.expectEqualStrings("phone-1", serve_args.raw.serial.?);
    try std.testing.expectEqualStrings("com.example.app", serve_args.raw.app_id.?);
    try std.testing.expectEqualStrings("traces/rpc", serve_args.raw.trace_dir.?);
    try std.testing.expectEqualStrings("./tools/xcrun", serve_args.xcrun_path);
    try std.testing.expectEqualStrings("./.zmr/ios-shim", serve_args.raw.ios_shim_path.?);

    const mcp_args = try cli_serve.parseMcpArgs(&.{ "--platform", "android", "--adb", "./tools/adb", "--android-shim", "./.zmr/android-shim" });
    try std.testing.expectEqual(run_options.Platform.android, mcp_args.raw.platform);
    try std.testing.expectEqualStrings("./tools/adb", mcp_args.adb_path);
    try std.testing.expectEqualStrings("./.zmr/android-shim", mcp_args.raw.android_shim_path.?);

    try std.testing.expectError(error.UnsupportedTransport, cli_serve.parseServeArgs(&.{ "--transport", "websocket" }));
    try std.testing.expectError(error.UnknownFlag, cli_serve.parseMcpArgs(&.{ "--transport", "tcp" }));
}

test "cli run module parses scenario device platform and emulator options" {
    const parsed = try cli_run.parseArgs(&.{
        "flows/smoke.json",
        "--json",
        "--config",
        ".zmr/config.json",
        "--platform",
        "android",
        "--device",
        "emulator-5554",
        "--app-id",
        "com.example.app",
        "--trace-dir",
        "traces/run",
        "--discover-out",
        ".zmr/discovered/run-smoke.json",
        "--adb",
        "./tools/adb",
        "--emulator",
        "./tools/emulator",
        "--avdmanager",
        "./tools/avdmanager",
        "--android-shim",
        "./.zmr/android-shim",
        "--android-avd",
        "Pixel_8",
        "--create-avd-if-missing",
        "--avd-system-image",
        "system-images;android-35;google_apis;arm64-v8a",
        "--avd-device",
        "pixel_8",
        "--restore-snapshot",
        "clean",
        "--reset-emulator",
        "--wait-emulator",
        "--screen-record",
    });

    try std.testing.expectEqualStrings("flows/smoke.json", parsed.raw.scenario_path.?);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqualStrings(".zmr/config.json", parsed.config_path.?);
    try std.testing.expectEqualStrings("emulator-5554", parsed.raw.serial.?);
    try std.testing.expectEqualStrings("com.example.app", parsed.raw.app_id.?);
    try std.testing.expectEqualStrings("traces/run", parsed.raw.trace_dir.?);
    try std.testing.expectEqualStrings(".zmr/discovered/run-smoke.json", parsed.discover_out.?);
    try std.testing.expectEqualStrings("./tools/adb", parsed.adb_path);
    try std.testing.expect(parsed.adb_path_set);
    try std.testing.expectEqualStrings("./tools/emulator", parsed.emulator_path);
    try std.testing.expect(parsed.emulator_path_set);
    try std.testing.expectEqualStrings("./tools/avdmanager", parsed.avdmanager_path);
    try std.testing.expect(parsed.avdmanager_path_set);
    try std.testing.expectEqualStrings("./.zmr/android-shim", parsed.raw.android_shim_path.?);
    try std.testing.expectEqualStrings("Pixel_8", parsed.raw.android_avd_name.?);
    try std.testing.expect(parsed.raw.android_create_avd_if_missing.?);
    try std.testing.expectEqualStrings("system-images;android-35;google_apis;arm64-v8a", parsed.raw.android_avd_system_image.?);
    try std.testing.expectEqualStrings("pixel_8", parsed.raw.android_avd_device_profile.?);
    try std.testing.expectEqualStrings("clean", parsed.raw.android_restore_snapshot.?);
    try std.testing.expect(parsed.raw.android_reset_before_run.?);
    try std.testing.expect(parsed.raw.android_wait_ready.?);
    try std.testing.expect(parsed.raw.screen_recording.?);

    const ios_args = try cli_run.parseArgs(&.{ "--platform", "ios", "--ios-device-type", "physical", "--xcrun", "./tools/xcrun", "--ios-shim", "./.zmr/ios-shim" });
    try std.testing.expectEqual(run_options.Platform.ios, ios_args.raw.platform);
    try std.testing.expectEqual(run_options.IosDeviceType.physical, ios_args.raw.ios_device_type);
    try std.testing.expectEqualStrings("./tools/xcrun", ios_args.xcrun_path);
    try std.testing.expect(ios_args.xcrun_path_set);
    try std.testing.expectEqualStrings("./.zmr/ios-shim", ios_args.raw.ios_shim_path.?);

    const config_only = try cli_run.parseArgs(&.{});
    try std.testing.expect(config_only.raw.scenario_path == null);
    try std.testing.expectError(error.UnknownFlag, cli_run.parseArgs(&.{ "a.json", "b.json" }));
}
