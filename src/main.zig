const std = @import("std");
const stdio = @import("stdio.zig");
const cli_devices = @import("cli_devices.zig");
const cli_discover = @import("cli_discover.zig");
const cli_doctor = @import("cli_doctor.zig");
const cli_draft = @import("cli_draft.zig");
const cli_explore = @import("cli_explore.zig");
const cli_info = @import("cli_info.zig");
const cli_init = @import("cli_init.zig");
const cli_import = @import("cli_import.zig");
const cli_inspect = @import("cli_inspect.zig");
const cli_record = @import("cli_record.zig");
const cli_run = @import("cli_run.zig");
const cli_test = @import("cli_test.zig");
const cli_serve = @import("cli_serve.zig");
const cli_trace = @import("cli_trace.zig");
const cli_validate = @import("cli_validate.zig");
const errors = @import("errors.zig");

pub fn main(init: std.process.Init.Minimal) void {
    mainInner(init) catch |err| {
        // stdout's consumer went away (e.g. `zmr ... | head`); exit quietly
        // with the conventional SIGPIPE status instead of reporting an error.
        if (err == error.BrokenPipe) std.process.exit(141);
        writeTopLevelError(err);
        std.process.exit(exitCodeForError(err));
    };
}

fn mainInner(init: std.process.Init.Minimal) !void {
    const GeneralAllocator = if (@hasDecl(std.heap, "GeneralPurposeAllocator"))
        std.heap.GeneralPurposeAllocator
    else
        std.heap.DebugAllocator;
    var gpa = GeneralAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    stdio.initProcess(init, allocator);
    defer stdio.deinitProcess();

    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.next();
    const command_name = args.next() orelse {
        try usage();
        return;
    };

    if (std.mem.eql(u8, command_name, "devices")) {
        try cli_devices.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "schemas")) {
        try cli_info.runSchemas(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "doctor")) {
        try cli_doctor.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "discover")) {
        try cli_discover.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "draft")) {
        try cli_draft.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "explore")) {
        try cli_explore.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "validate")) {
        try cli_validate.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "init")) {
        try cli_init.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "import")) {
        try cli_import.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "inspect")) {
        try cli_inspect.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "run")) {
        try cli_run.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "record")) {
        try cli_record.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "test")) {
        try cli_test.run(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "report")) {
        try cli_trace.runReport(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "explain")) {
        try cli_trace.runExplain(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "export")) {
        try cli_trace.runExport(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "serve")) {
        try cli_serve.runServe(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "mcp")) {
        try cli_serve.runMcp(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "version") or std.mem.eql(u8, command_name, "--version")) {
        try cli_info.runVersion(allocator, &args);
    } else if (std.mem.eql(u8, command_name, "help") or std.mem.eql(u8, command_name, "--help")) {
        try usage();
    } else {
        std.debug.print("unknown command: {s}\n\n", .{command_name});
        try usage();
        return error.unknownCommand;
    }
}

fn writeTopLevelError(err: anyerror) void {
    const public = errors.classify(err);
    var stderr_io: stdio.Output = .{};
    stderr_io.init(.stderr());
    defer stderr_io.deinit();
    const stderr = stderr_io.writer();
    stderr.print("error[{s}]: {s}\n", .{ public.code, public.message }) catch {};
    if (err == error.CommandFailed) {
        // CommandFailed is a catch-all for a non-zero exit from simctl/adb, and the
        // underlying stderr is not plumbed this far. Do not send the user to doctor
        // here: doctor only inspects the host toolchain, so on a first run it passes
        // and then points back at the run command that just failed — a loop with no
        // exit. Name the cause that actually explains almost every first-run failure.
        stderr.writeAll("hint: on a first run this usually means the app under test is not installed on the target device.\n") catch {};
        stderr.writeAll("hint: check with `xcrun simctl listapps booted` (iOS) or `adb shell pm list packages` (Android), install the app, then re-run.\n") catch {};
    }
    if (err == error.CommandTimedOut or
        err == error.IosXCTestShimResponseTimedOut or err == error.IosXCTestShimStartTimedOut or
        err == error.IosXCTestShimBuildTimedOut or err == error.IosXCTestShimServerExited)
    {
        stderr.writeAll("hint: run `zmr doctor --json` for setup diagnostics.\n") catch {};
    }
    if (err == error.unknownFlag) {
        stderr.writeAll("hint: run `zmr help` for each command's flags and arguments.\n") catch {};
    }
    if (err == error.AppIdRequired) {
        stderr.writeAll("hint: no expo.ios.bundleIdentifier or expo.android.package was found in app.json, so the bundle id has to be given.\n") catch {};
        stderr.writeAll("hint: pass the id your app is installed under, e.g. `zmr init --app --app-id com.acme.myapp`.\n") catch {};
        stderr.writeAll("hint: list what is installed with `xcrun simctl listapps booted` (iOS) or `adb shell pm list packages` (Android).\n") catch {};
        stderr.writeAll("hint: a fresh Expo project has no bundle id until `npx expo prebuild` runs — ZMR drives an installed native build, not Expo Go.\n") catch {};
    }
}

fn exitCodeForError(err: anyerror) u8 {
    return switch (err) {
        error.unknownCommand,
        error.unknownFlag,
        error.MissingScenarioPath,
        error.MissingDeviceSerial,
        error.MissingTraceDir,
        error.MissingReportInput,
        error.MissingReportOutput,
        error.MissingDraftOut,
        error.MissingDiscoverOut,
        error.MissingJUnitOutput,
        error.MissingTraceBundleOutput,
        error.MissingTestWorkspace,
        error.MissingTestWorkers,
        error.MissingTestRetries,
        error.MissingTestOutputDir,
        error.MissingTestPlatform,
        error.MissingTestDevice,
        error.MissingTestAppId,
        error.MissingTestAdb,
        error.MissingTestXcrun,
        error.MissingTestAndroidShim,
        error.MissingTestIosShim,
        error.MissingRecordTraceDir,
        error.MissingRecordTransport,
        error.MissingRecordPort,
        error.MissingAppId,
        error.AppIdRequired,
        error.MissingAdbPath,
        error.MissingXcrunPath,
        error.MissingZigPath,
        error.MissingPlatform,
        error.MissingIosDeviceType,
        error.MissingParam,
        error.UnsupportedPlatform,
        error.UnsupportedIosDeviceType,
        error.UnsupportedTransport,
        error.InvalidTestWorkers,
        error.InvalidTestRetries,
        error.InvalidTestPlatform,
        error.ConflictingShardModes,
        error.InvalidRecordTransport,
        error.InvalidRecordPort,
        => 2,
        else => 1,
    };
}

fn usage() !void {
    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();
    try stdout.writeAll(
        \\zmr - Zeno Mobile Runner
        \\
        \\Commands:
        \\  zmr version [--json]
        \\  zmr schemas [--json]
        \\  zmr devices [--json] [--platform android|ios] [--ios-device-type simulator|physical|all] [--adb <path>] [--xcrun <path>]
        \\  zmr doctor [--json] [--strict] [--config <path>] [--zig <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr discover --from-trace <trace-dir> --out <scenario.json> [--include-actions] [--validate] [--name <name>] [--app-id <id>] [--force] [--json]
        \\  zmr draft --from-trace <trace-dir> --out <scenario.json> [--include-actions] [--name <name>] [--app-id <id>] [--force] [--json]
        \\  zmr explore --from-trace <trace-dir> --out <scenario.json> [--goal <goal>] [--include-actions] [--validate] [--name <name>] [--app-id <id>] [--force] [--json]
        \\  zmr validate <scenario.json> [--json]
        \\  zmr init [scenario.json] [--app-id <id>] [--force] [--json]
        \\  zmr init --app [--dir <app-root>] [--app-id <id>] [--force] [--json]
        \\  zmr import flow-yaml <flow.yaml> --out <scenario.json> [--name <name>] [--app-id <id>] [--force] [--json]
        \\  zmr inspect [--json] [--dir <app-root>] [--config <path>]
        \\  zmr record --trace-dir <path> [--transport stdio|tcp] [--port <n>] [--json]
        \\  zmr run [scenario.json] [--json] [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--discover-out <scenario.json>] [--android-avd <name>] [--create-avd-if-missing] [--avd-system-image <pkg>] [--avd-device <profile>] [--restore-snapshot <name>] [--reset-emulator] [--wait-emulator] [--ensure-device] [--no-ensure-device] [--screen-record] [--no-screen-record] [--adb <path>] [--emulator <path>] [--avdmanager <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr test <workspace> [--workers <n>] [--shard-all|--shard-split] [--retry <n>] [--output-dir <path>] [--platform android|ios] [--device <serial>] [--app-id <id>] [--dry-run] [--screen-record] [--json]
        \\  zmr report <trace-or-benchmark-dir> --out <report.html> [--junit <report.xml>]
        \\  zmr explain <trace-dir> [--json]
        \\  zmr export <trace-dir> --out <bundle.zmrtrace> [--redact] [--omit-screenshots]
        \\  zmr serve --transport stdio [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr serve --transport tcp [--port <port>] [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr mcp [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\
        \\Scenario actions: launch, stop, killApp, clearState, openLink, tap, longPressOn,
        \\doubleTapOn, pressKey, typeText, grantPermissions, setOrientation,
        \\setClipboard,
        \\eraseText, hideKeyboard, swipe, pressBack, waitVisible, waitNotVisible,
        \\waitAny, whenVisible, repeat, scrollUntilVisible, assertVisible,
        \\assertNotVisible, assertNoneVisible, assertHealthy, snapshot, sleep. Any step may use "optional": true.
        \\
    );
    try stdout_io.flush();
}
