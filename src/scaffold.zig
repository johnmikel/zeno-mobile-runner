const std = @import("std");

pub const app_config_file = ".zmr/config.json";
pub const app_android_smoke_file = ".zmr/android-smoke.json";
pub const app_ios_smoke_file = ".zmr/ios-smoke.json";
pub const app_device_matrix_file = ".zmr/device-matrix.json";
pub const app_agents_file = ".zmr/AGENTS.md";

pub const app_created_files = [_][]const u8{
    app_config_file,
    app_android_smoke_file,
    app_ios_smoke_file,
    app_device_matrix_file,
    app_agents_file,
};

pub const app_script_names = [_][]const u8{
    "doctor",
    "schemas",
    "validate",
    "android",
    "androidReport",
    "androidReliability",
    "ios",
    "iosReport",
    "iosReliability",
    "matrix",
    "pilotGate",
    "readiness",
    "serve",
    "mcp",
    "explain",
    "exportTrace",
};

pub fn writeStarterScenario(
    allocator: std.mem.Allocator,
    path: []const u8,
    app_id: []const u8,
    force: bool,
) !void {
    if (!force) {
        std.fs.cwd().access(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (std.fs.cwd().access(path, .{})) |_| return error.PathAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.fs.cwd().makePath(parent);
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(
        \\{
        \\  "name": "Starter mobile smoke",
        \\  "appId": "
    );
    try writeJsonStringContent(writer, app_id);
    try writer.writeAll(
        \\",
        \\  "steps": [
        \\    { "action": "launch" },
        \\    { "action": "assertHealthy" },
        \\    { "action": "snapshot" }
        \\  ]
        \\}
        \\
    );
    try writer.flush();
    _ = allocator;
}

pub fn writeAppScaffold(
    allocator: std.mem.Allocator,
    dir: []const u8,
    app_id: []const u8,
    force: bool,
) !void {
    const zmr_dir = try std.fs.path.join(allocator, &.{ dir, ".zmr" });
    defer allocator.free(zmr_dir);
    try std.fs.cwd().makePath(zmr_dir);

    const config_path = try std.fs.path.join(allocator, &.{ zmr_dir, appFileBasename(app_config_file) });
    defer allocator.free(config_path);
    const android_path = try std.fs.path.join(allocator, &.{ zmr_dir, appFileBasename(app_android_smoke_file) });
    defer allocator.free(android_path);
    const ios_path = try std.fs.path.join(allocator, &.{ zmr_dir, appFileBasename(app_ios_smoke_file) });
    defer allocator.free(ios_path);
    const matrix_path = try std.fs.path.join(allocator, &.{ zmr_dir, appFileBasename(app_device_matrix_file) });
    defer allocator.free(matrix_path);
    const agents_path = try std.fs.path.join(allocator, &.{ zmr_dir, appFileBasename(app_agents_file) });
    defer allocator.free(agents_path);

    try writeAppConfig(config_path, app_id, true);
    try writePlatformSmoke(android_path, "Android smoke", app_id, force);
    try writePlatformSmoke(ios_path, "iOS smoke", app_id, force);
    try writeDeviceMatrix(matrix_path, app_id, true);
    try writeAgentInstructions(agents_path, app_id, true);
    try ensureTraceGitignore(allocator, dir);
}

fn appFileBasename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn writeAppConfig(path: []const u8, app_id: []const u8, force: bool) !void {
    var file = try createOutputFile(path, force);
    defer file.close();
    var buffer: [8192]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(
        \\{
        \\  "schemaVersion": 1,
        \\  "appId": "
    );
    try writeJsonStringContent(writer, app_id);
    try writer.writeAll(
        \\",
        \\  "android": {
        \\    "enabled": true,
        \\    "defaultDevice": "emulator-5554",
        \\    "smokeScenario": ".zmr/android-smoke.json",
        \\    "traceDir": "traces/zmr-android"
        \\  },
        \\  "ios": {
        \\    "enabled": true,
        \\    "defaultDevice": "booted",
        \\    "smokeScenario": ".zmr/ios-smoke.json",
        \\    "traceDir": "traces/zmr-ios"
        \\  },
        \\  "artifacts": {
        \\    "screenshots": true,
        \\    "hierarchy": true,
        \\    "logs": true,
        \\    "screenRecording": false
        \\  },
        \\  "scripts": {
        \\    "doctor": "zmr doctor --strict --json --config .zmr/config.json",
        \\    "schemas": "zmr schemas --json",
        \\    "validate": "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json",
        \\    "android": "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android",
        \\    "androidReport": "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml",
        \\    "androidReliability": "export ZMR_BIN=\"${ZMR_BIN:-zmr}\"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id
    );
    try writer.writeAll(" ");
    try writeJsonShellArg(writer, app_id);
    try writer.writeAll(
        \\ --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && \"$ZMR_BIN\" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml",
        \\    "ios": "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios",
        \\    "iosReport": "zmr report traces/zmr-ios --out traces/zmr-ios/report.html --junit traces/zmr-ios/junit.xml",
        \\    "iosReliability": "export ZMR_BIN=\"${ZMR_BIN:-zmr}\"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id
    );
    try writer.writeAll(" ");
    try writeJsonShellArg(writer, app_id);
    try writer.writeAll(
        \\ --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && \"$ZMR_BIN\" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml",
        \\    "matrix": "ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0",
        \\    "pilotGate": "zmr-pilot-gate --android --ios --android-app-root . --android-app-id
    );
    try writer.writeAll(" ");
    try writeJsonShellArg(writer, app_id);
    try writer.writeAll(
        \\ --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id
    );
    try writer.writeAll(" ");
    try writeJsonShellArg(writer, app_id);
    try writer.writeAll(
        \\ --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
        \\    "readiness": "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json",
        \\    "serve": "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent",
        \\    "mcp": "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent",
        \\    "explain": "zmr explain traces/zmr-agent --json",
        \\    "exportTrace": "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact"
        \\  }
        \\}
        \\
    );
    try writer.flush();
}

fn writeDeviceMatrix(path: []const u8, app_id: []const u8, force: bool) !void {
    var file = try createOutputFile(path, force);
    defer file.close();
    var buffer: [8192]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(
        \\{
        \\  "runs": 1,
        \\  "appId": "
    );
    try writeJsonStringContent(writer, app_id);
    try writer.writeAll(
        \\",
        \\  "devices": [
        \\    {
        \\      "name": "android-emulator",
        \\      "platform": "android",
        \\      "serial": "emulator-5554",
        \\      "scenario": ".zmr/android-smoke.json",
        \\      "adb": "adb"
        \\    },
        \\    {
        \\      "name": "ios-simulator",
        \\      "platform": "ios",
        \\      "iosDeviceType": "simulator",
        \\      "serial": "booted",
        \\      "scenario": ".zmr/ios-smoke.json",
        \\      "xcrun": "xcrun"
        \\    }
        \\  ]
        \\}
        \\
    );
    try writer.flush();
}

fn writePlatformSmoke(path: []const u8, name: []const u8, app_id: []const u8, force: bool) !void {
    if (!force and try pathExists(path)) return;
    var file = try createOutputFile(path, force);
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(
        \\{
        \\  "name": "
    );
    try writeJsonStringContent(writer, name);
    try writer.writeAll(
        \\",
        \\  "appId": "
    );
    try writeJsonStringContent(writer, app_id);
    try writer.writeAll(
        \\",
        \\  "steps": [
        \\    { "action": "launch" },
        \\    { "action": "assertHealthy" },
        \\    { "action": "snapshot" }
        \\  ]
        \\}
        \\
    );
    try writer.flush();
}

fn pathExists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn writeJsonShellArg(writer: anytype, value: []const u8) !void {
    if (isShellSafe(value)) {
        try writeJsonStringContent(writer, value);
        return;
    }
    try writer.writeAll("'");
    for (value) |ch| {
        if (ch == '\'') try writeJsonStringContent(writer, "'\\''") else try writeJsonStringContent(writer, &[_]u8{ch});
    }
    try writer.writeAll("'");
}

fn writeShellArg(writer: anytype, value: []const u8) !void {
    if (isShellSafe(value)) {
        try writer.writeAll(value);
        return;
    }
    try writer.writeAll("'");
    for (value) |ch| {
        if (ch == '\'') try writer.writeAll("'\\''") else try writer.writeAll(&[_]u8{ch});
    }
    try writer.writeAll("'");
}

fn isShellSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '/', ':', '=', '@', '%', '+', ',', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn writeAgentInstructions(path: []const u8, app_id: []const u8, force: bool) !void {
    var file = try createOutputFile(path, force);
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(
        \\# ZMR Agent Instructions
        \\
        \\App id: `
    );
    try writer.writeAll(app_id);
    try writer.writeAll(
        \\`
        \\
        \\Start from the app checkout. Keep generated scenarios and config under `.zmr/`, and write run output under `traces/`.
        \\
        \\## Setup Checks
        \\
        \\```bash
        \\zmr inspect --json --dir .
        \\zmr doctor --strict --json --config .zmr/config.json
        \\zmr schemas --json
        \\zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json
        \\```
        \\
        \\## Interactive Agent Session
        \\
        \\```bash
        \\zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
        \\zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
        \\```
        \\
        \\Use `semantic_snapshot` before choosing tap or type actions. Prefer selectors from accessibility identifiers, resource ids, labels, or exact text before coordinates. Export redacted traces before sharing artifacts.
        \\
        \\## Discover From Trace
        \\
        \\```bash
        \\zmr explore --from-trace traces/zmr-agent --out .zmr/discovered/login-smoke.json --goal "find a stable login smoke" --include-actions --validate --json
        \\zmr discover --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --validate --json
        \\zmr draft --from-trace traces/zmr-agent --out .zmr/discovered/surface-smoke.json --json
        \\zmr validate --json .zmr/discovered/surface-smoke.json
        \\zmr draft --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --json
        \\zmr validate --json .zmr/discovered/replay-smoke.json
        \\```
        \\
        \\Prefer `zmr explore` for CLI agent loops when the goal should travel with the generated candidate. Its JSON includes `autonomous:false`, `reviewRequired:true`, `guardrails`, replay coverage, validation, and deterministic next commands. Treat discover output as a lower-level reviewable starting point. It writes from trace evidence and validates the generated file when `--validate` is present, but it does not crawl, invent missing actions, discover credentials, or commit tests. Treat draft output as a reviewable starting point when using the lower-level split workflow. The default draft contains only `launch`, `snapshot`, and conservative `assertVisible` checks. Use `--include-actions` only when the trace came from a reviewed agent session; unsupported events are skipped with warnings instead of guessed. Do not commit a discovered or drafted scenario until a human has reviewed and rerun it.
        \\
        \\## Failure Triage
        \\
        \\```bash
        \\zmr explain traces/zmr-agent --json
        \\```
        \\
        \\Use the JSON explanation before editing selectors. It includes the terminal status, partial visual-capture diagnostics, and the last useful failure context.
        \\
        \\## Trace Sharing
        \\
        \\```bash
        \\zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact
        \\```
        \\
        \\Add `--omit-screenshots` when visual artifacts may contain sensitive data.
        \\
        \\## Direct Smoke Runs
        \\
        \\```bash
        \\zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android
        \\zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml
        \\export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id
    );
    try writer.writeAll(" ");
    try writeShellArg(writer, app_id);
    try writer.writeAll(
        \\ --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && "$ZMR_BIN" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml
        \\zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios
        \\zmr report traces/zmr-ios --out traces/zmr-ios/report.html --junit traces/zmr-ios/junit.xml
        \\export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id
    );
    try writer.writeAll(" ");
    try writeShellArg(writer, app_id);
    try writer.writeAll(
        \\ --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && "$ZMR_BIN" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml
        \\```
        \\
        \\## Release Claims
        \\
        \\```bash
        \\zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json
        \\```
        \\
        \\Do not claim production readiness from smoke runs alone. Use `satisfied` for proven requirements; do not infer readiness from raw `passed` evidence. Use `recommendedWording` and keep `claimLimitations` intact when summarizing readiness. When readiness is blocked, follow `nextSteps[].commands` in order.
        \\
        \\## App Commands
        \\
        \\```bash
        \\zmr inspect --json --dir .
        \\zmr doctor --strict --json --config .zmr/config.json
        \\zmr schemas --json
        \\zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json
        \\zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android
        \\zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml
        \\export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id
    );
    try writer.writeAll(" ");
    try writeShellArg(writer, app_id);
    try writer.writeAll(
        \\ --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && "$ZMR_BIN" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml
        \\zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios
        \\zmr report traces/zmr-ios --out traces/zmr-ios/report.html --junit traces/zmr-ios/junit.xml
        \\export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id
    );
    try writer.writeAll(" ");
    try writeShellArg(writer, app_id);
    try writer.writeAll(
        \\ --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && "$ZMR_BIN" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml
        \\ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0
    );
    try writer.writeAll("zmr-pilot-gate --android --ios --android-app-root . --android-app-id ");
    try writeShellArg(writer, app_id);
    try writer.writeAll(" --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id ");
    try writeShellArg(writer, app_id);
    try writer.writeAll(
        \\ --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl
        \\zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json
        \\zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
        \\zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
        \\zmr discover --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --validate --json
        \\zmr explain traces/zmr-agent --json
        \\zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact
        \\```
        \\
    );
    try writer.flush();
}

fn createOutputFile(path: []const u8, force: bool) !std.fs.File {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.fs.cwd().makePath(parent);
    }
    if (!force) return try std.fs.cwd().createFile(path, .{ .exclusive = true });
    return try std.fs.cwd().createFile(path, .{ .truncate = true });
}

fn ensureTraceGitignore(allocator: std.mem.Allocator, dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, ".gitignore" });
    defer allocator.free(path);

    const existing = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const had_existing_file = existing.ptr != "".ptr;
    defer if (had_existing_file) allocator.free(existing);

    if (std.mem.indexOf(u8, existing, "traces/") != null) return;

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    if (existing.len > 0) {
        try writer.writeAll(existing);
        if (!std.mem.endsWith(u8, existing, "\n")) try writer.writeAll("\n");
        try writer.writeAll("\n");
    }
    try writer.writeAll(
        \\# ZMR local run artifacts
        \\traces/
        \\
    );
    try writer.flush();
}

fn writeJsonStringContent(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...7, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeAll(&.{ch}),
        }
    }
}
