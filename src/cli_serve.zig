const std = @import("std");

const android = @import("android.zig");
const config = @import("config.zig");
const config_paths = @import("config_paths.zig");
const ios = @import("ios.zig");
const json_rpc = @import("json_rpc.zig");
const mcp = @import("mcp.zig");
const run_options = @import("run_options.zig");
const trace = @import("trace.zig");

pub const ServeArgs = struct {
    raw: run_options.RawServeOptions = .{},
    adb_path: []const u8 = "adb",
    xcrun_path: []const u8 = "xcrun",
    transport: []const u8 = "stdio",
    port: u16 = 8765,
    config_path: ?[]const u8 = null,
};

pub const McpArgs = struct {
    raw: run_options.RawServeOptions = .{},
    adb_path: []const u8 = "adb",
    xcrun_path: []const u8 = "xcrun",
    config_path: ?[]const u8 = null,
};

const ResolvedContext = struct {
    resolved: run_options.ResolvedServeOptions,
    adb_path: []const u8,
    xcrun_path: []const u8,
    trace_dir: ?[]const u8,
    android_shim_path: ?[]const u8,
    ios_shim_path: ?[]const u8,
    capture: trace.CaptureOptions,
};

pub fn parseServeArgs(args: []const []const u8) !ServeArgs {
    var parsed = ServeArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--transport")) {
            index += 1;
            parsed.transport = if (index < args.len) args[index] else return error.MissingTransport;
            if (!std.mem.eql(u8, parsed.transport, "stdio") and !std.mem.eql(u8, parsed.transport, "tcp")) {
                return error.UnsupportedTransport;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            const value = if (index < args.len) args[index] else return error.MissingPort;
            parsed.port = try std.fmt.parseInt(u16, value, 10);
        } else {
            try parseCommonArg(args, &index, &parsed.raw, &parsed.adb_path, &parsed.xcrun_path, &parsed.config_path);
        }
    }
    return parsed;
}

pub fn parseMcpArgs(args: []const []const u8) !McpArgs {
    var parsed = McpArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        try parseCommonArg(args, &index, &parsed.raw, &parsed.adb_path, &parsed.xcrun_path, &parsed.config_path);
    }
    return parsed;
}

pub fn runServe(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseServeArgs(raw_args.items);
    var owned_config_paths = std.ArrayList([]const u8).empty;
    defer {
        for (owned_config_paths.items) |path| allocator.free(path);
        owned_config_paths.deinit(allocator);
    }
    var config_root: ?[]const u8 = null;
    defer if (config_root) |root| allocator.free(root);

    var loaded_config = try config_paths.loadIfPresent(allocator, parsed.config_path);
    defer if (loaded_config) |*cfg| cfg.deinit(allocator);

    const context = try resolveContext(allocator, parsed.raw, parsed.adb_path, parsed.xcrun_path, parsed.config_path, loaded_config, &owned_config_paths, &config_root);
    switch (context.resolved.platform) {
        .android => {
            var device = try android.AndroidDevice.initWithShim(allocator, context.adb_path, context.resolved.serial, context.resolved.app_id, context.android_shim_path);
            defer device.deinit();
            try serveWithDevice(allocator, &device, parsed.transport, parsed.port, context.trace_dir, context.resolved.app_id, context.capture);
        },
        .ios => {
            var device = try ios.IosDevice.initWithKindAndShim(allocator, context.xcrun_path, context.resolved.serial, context.resolved.app_id, iosTargetKind(context.resolved.ios_device_type), context.ios_shim_path);
            defer device.deinit();
            try serveWithDevice(allocator, &device, parsed.transport, parsed.port, context.trace_dir, context.resolved.app_id, context.capture);
        },
    }
}

pub fn runMcp(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(allocator);
    while (args.next()) |arg| try raw_args.append(allocator, arg);

    const parsed = try parseMcpArgs(raw_args.items);
    var owned_config_paths = std.ArrayList([]const u8).empty;
    defer {
        for (owned_config_paths.items) |path| allocator.free(path);
        owned_config_paths.deinit(allocator);
    }
    var config_root: ?[]const u8 = null;
    defer if (config_root) |root| allocator.free(root);

    var loaded_config = try config_paths.loadIfPresent(allocator, parsed.config_path);
    defer if (loaded_config) |*cfg| cfg.deinit(allocator);

    const context = try resolveContext(allocator, parsed.raw, parsed.adb_path, parsed.xcrun_path, parsed.config_path, loaded_config, &owned_config_paths, &config_root);
    switch (context.resolved.platform) {
        .android => {
            var device = try android.AndroidDevice.initWithShim(allocator, context.adb_path, context.resolved.serial, context.resolved.app_id, context.android_shim_path);
            defer device.deinit();
            try serveMcpWithDevice(allocator, &device, context.trace_dir, context.resolved.app_id, context.capture);
        },
        .ios => {
            var device = try ios.IosDevice.initWithKindAndShim(allocator, context.xcrun_path, context.resolved.serial, context.resolved.app_id, iosTargetKind(context.resolved.ios_device_type), context.ios_shim_path);
            defer device.deinit();
            try serveMcpWithDevice(allocator, &device, context.trace_dir, context.resolved.app_id, context.capture);
        },
    }
}

fn parseCommonArg(
    args: []const []const u8,
    index: *usize,
    raw: *run_options.RawServeOptions,
    adb_path: *[]const u8,
    xcrun_path: *[]const u8,
    config_path: *?[]const u8,
) !void {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--device")) {
        index.* += 1;
        raw.serial = if (index.* < args.len) args[index.*] else return error.MissingDeviceSerial;
    } else if (std.mem.eql(u8, arg, "--app-id")) {
        index.* += 1;
        raw.app_id = if (index.* < args.len) args[index.*] else return error.MissingAppId;
    } else if (std.mem.eql(u8, arg, "--trace-dir")) {
        index.* += 1;
        raw.trace_dir = if (index.* < args.len) args[index.*] else return error.MissingTraceDir;
    } else if (std.mem.eql(u8, arg, "--adb")) {
        index.* += 1;
        adb_path.* = if (index.* < args.len) args[index.*] else return error.MissingAdbPath;
    } else if (std.mem.eql(u8, arg, "--android-shim")) {
        index.* += 1;
        raw.android_shim_path = if (index.* < args.len) args[index.*] else return error.MissingAndroidShimPath;
    } else if (std.mem.eql(u8, arg, "--xcrun")) {
        index.* += 1;
        xcrun_path.* = if (index.* < args.len) args[index.*] else return error.MissingXcrunPath;
    } else if (std.mem.eql(u8, arg, "--ios-shim")) {
        index.* += 1;
        raw.ios_shim_path = if (index.* < args.len) args[index.*] else return error.MissingIosShimPath;
    } else if (std.mem.eql(u8, arg, "--platform")) {
        index.* += 1;
        raw.platform = try parsePlatform(if (index.* < args.len) args[index.*] else return error.MissingPlatform);
    } else if (std.mem.eql(u8, arg, "--ios-device-type")) {
        index.* += 1;
        raw.ios_device_type = try parseIosDeviceType(if (index.* < args.len) args[index.*] else return error.MissingIosDeviceType);
    } else if (std.mem.eql(u8, arg, "--config")) {
        index.* += 1;
        config_path.* = if (index.* < args.len) args[index.*] else return error.MissingConfigPath;
    } else {
        return error.unknownFlag;
    }
}

fn resolveContext(
    allocator: std.mem.Allocator,
    raw: run_options.RawServeOptions,
    explicit_adb_path: []const u8,
    explicit_xcrun_path: []const u8,
    config_path: ?[]const u8,
    loaded_config: ?config.Config,
    owned_config_paths: *std.ArrayList([]const u8),
    config_root: *?[]const u8,
) !ResolvedContext {
    var adb_path = explicit_adb_path;
    var xcrun_path = explicit_xcrun_path;
    const actual_config_path = config_path orelse config_paths.default_path;

    if (loaded_config) |cfg| {
        config_root.* = try config_paths.rootForPath(allocator, actual_config_path);
        if (std.mem.eql(u8, adb_path, "adb")) {
            if (cfg.tools.adb_path) |path| adb_path = try config_paths.ownCommandPath(allocator, owned_config_paths, config_root.*.?, path);
        }
        if (std.mem.eql(u8, xcrun_path, "xcrun")) {
            if (cfg.tools.xcrun_path) |path| xcrun_path = try config_paths.ownCommandPath(allocator, owned_config_paths, config_root.*.?, path);
        }
    }

    const resolved = if (loaded_config) |cfg| run_options.resolveServe(raw, cfg) else run_options.resolveServe(raw, null);
    const capture = if (loaded_config) |cfg| run_options.traceCapture(cfg) else trace.CaptureOptions{};
    const trace_dir = if (raw.trace_dir == null and config_root.* != null and resolved.trace_dir != null)
        try config_paths.ownFilePath(allocator, owned_config_paths, config_root.*.?, resolved.trace_dir.?)
    else
        resolved.trace_dir;
    const android_shim_path = if (raw.android_shim_path == null and config_root.* != null and resolved.android_shim_path != null)
        try config_paths.ownFilePath(allocator, owned_config_paths, config_root.*.?, resolved.android_shim_path.?)
    else
        resolved.android_shim_path;
    const ios_shim_path = if (raw.ios_shim_path == null and config_root.* != null and resolved.ios_shim_path != null)
        try config_paths.ownFilePath(allocator, owned_config_paths, config_root.*.?, resolved.ios_shim_path.?)
    else
        resolved.ios_shim_path;

    return .{
        .resolved = resolved,
        .adb_path = adb_path,
        .xcrun_path = xcrun_path,
        .trace_dir = trace_dir,
        .android_shim_path = android_shim_path,
        .ios_shim_path = ios_shim_path,
        .capture = capture,
    };
}

fn serveMcpWithDevice(
    allocator: std.mem.Allocator,
    device: anytype,
    trace_dir: ?[]const u8,
    app_id: []const u8,
    capture: trace.CaptureOptions,
) !void {
    var trace_writer: ?trace.TraceWriter = null;
    if (trace_dir) |dir| {
        trace_writer = try trace.TraceWriter.initWithOptions(allocator, dir, capture);
        try trace_writer.?.startManifest("mcp session", app_id);
    }
    defer if (trace_writer) |*tw| tw.deinit();
    const live_trace = if (trace_writer) |*tw| tw else null;
    try mcp.serveStdioWithTrace(allocator, device, live_trace);
}

fn serveWithDevice(
    allocator: std.mem.Allocator,
    device: anytype,
    transport: []const u8,
    port: u16,
    trace_dir: ?[]const u8,
    app_id: []const u8,
    capture: trace.CaptureOptions,
) !void {
    var trace_writer: ?trace.TraceWriter = null;
    if (trace_dir) |dir| {
        trace_writer = try trace.TraceWriter.initWithOptions(allocator, dir, capture);
        try trace_writer.?.startManifest("json-rpc session", app_id);
    }
    defer if (trace_writer) |*tw| tw.deinit();
    const live_trace = if (trace_writer) |*tw| tw else null;

    if (std.mem.eql(u8, transport, "stdio")) {
        try json_rpc.serveStdioWithTrace(allocator, device, live_trace);
    } else if (std.mem.eql(u8, transport, "tcp")) {
        try json_rpc.serveTcpWithTrace(allocator, device, port, live_trace);
    } else {
        return error.UnsupportedTransport;
    }
}

fn parsePlatform(value: []const u8) !run_options.Platform {
    if (std.mem.eql(u8, value, "android")) return .android;
    if (std.mem.eql(u8, value, "ios")) return .ios;
    return error.UnsupportedPlatform;
}

fn parseIosDeviceType(value: []const u8) !run_options.IosDeviceType {
    if (std.mem.eql(u8, value, "simulator")) return .simulator;
    if (std.mem.eql(u8, value, "physical")) return .physical;
    return error.UnsupportedIosDeviceType;
}

fn iosTargetKind(value: run_options.IosDeviceType) ios.TargetKind {
    return switch (value) {
        .simulator => .simulator,
        .physical => .physical,
    };
}
