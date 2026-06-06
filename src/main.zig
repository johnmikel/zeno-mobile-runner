const std = @import("std");
const cli_devices = @import("cli_devices.zig");
const cli_doctor = @import("cli_doctor.zig");
const cli_draft = @import("cli_draft.zig");
const cli_info = @import("cli_info.zig");
const cli_init = @import("cli_init.zig");
const cli_import = @import("cli_import.zig");
const cli_inspect = @import("cli_inspect.zig");
const cli_run = @import("cli_run.zig");
const cli_serve = @import("cli_serve.zig");
const cli_trace = @import("cli_trace.zig");
const cli_validate = @import("cli_validate.zig");
const errors = @import("errors.zig");

pub fn main() void {
    mainInner() catch |err| {
        writeTopLevelError(err);
        std.process.exit(exitCodeForError(err));
    };
}

fn mainInner() !void {
    const GeneralAllocator = if (@hasDecl(std.heap, "GeneralPurposeAllocator"))
        std.heap.GeneralPurposeAllocator
    else
        std.heap.DebugAllocator;
    var gpa = GeneralAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
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
    } else if (std.mem.eql(u8, command_name, "draft")) {
        try cli_draft.run(allocator, &args);
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
        return error.UnknownCommand;
    }
}

fn writeTopLevelError(err: anyerror) void {
    const public = errors.classify(err);
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("error[{s}]: {s}\n", .{ public.code, public.message }) catch {};
    if (err == error.CommandFailed) {
        stderr.writeAll("hint: run `zmr doctor --json` for setup diagnostics.\n") catch {};
    }
}

fn exitCodeForError(err: anyerror) u8 {
    return switch (err) {
        error.UnknownCommand,
        error.UnknownFlag,
        error.MissingScenarioPath,
        error.MissingDeviceSerial,
        error.MissingTraceDir,
        error.MissingDraftOut,
        error.MissingAppId,
        error.MissingAdbPath,
        error.MissingXcrunPath,
        error.MissingZigPath,
        error.MissingPlatform,
        error.MissingIosDeviceType,
        error.MissingParam,
        error.UnsupportedPlatform,
        error.UnsupportedIosDeviceType,
        error.UnsupportedTransport,
        => 2,
        else => 1,
    };
}

fn usage() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(
        \\zmr - Zeno Mobile Runner
        \\
        \\Commands:
        \\  zmr version [--json]
        \\  zmr schemas [--json]
        \\  zmr devices [--json] [--platform android|ios] [--ios-device-type simulator|physical|all] [--adb <path>] [--xcrun <path>]
        \\  zmr doctor [--json] [--strict] [--config <path>] [--zig <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr draft --from-trace <trace-dir> --out <scenario.json> [--include-actions] [--name <name>] [--app-id <id>] [--force] [--json]
        \\  zmr validate <scenario.json> [--json]
        \\  zmr init [scenario.json] [--app-id <id>] [--force] [--json]
        \\  zmr init --app [--dir <app-root>] [--app-id <id>] [--force] [--json]
        \\  zmr import flow-yaml <flow.yaml> --out <scenario.json> [--name <name>] [--app-id <id>] [--force] [--json]
        \\  zmr inspect [--json] [--dir <app-root>] [--config <path>]
        \\  zmr run [scenario.json] [--json] [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--android-avd <name>] [--create-avd-if-missing] [--avd-system-image <pkg>] [--avd-device <profile>] [--restore-snapshot <name>] [--reset-emulator] [--wait-emulator] [--screen-record] [--no-screen-record] [--adb <path>] [--emulator <path>] [--avdmanager <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr report <trace-or-benchmark-dir> --out <report.html>
        \\  zmr explain <trace-dir> [--json]
        \\  zmr export <trace-dir> --out <bundle.zmrtrace> [--redact] [--omit-screenshots]
        \\  zmr serve --transport stdio [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr serve --transport tcp [--port <port>] [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\  zmr mcp [--config <path>] [--platform android|ios] [--ios-device-type simulator|physical] [--device <serial>] [--app-id <id>] [--trace-dir <path>] [--adb <path>] [--android-shim <path>] [--xcrun <path>] [--ios-shim <path>]
        \\
        \\Scenario actions: launch, stop, clearState, openLink, tap, typeText,
        \\eraseText, hideKeyboard, swipe, pressBack, waitVisible, waitNotVisible,
        \\waitAny, whenVisible, repeat, scrollUntilVisible, assertVisible,
        \\assertNotVisible, assertNoneVisible, assertHealthy, snapshot, sleep. Any step may use "optional": true.
        \\
    );
}
