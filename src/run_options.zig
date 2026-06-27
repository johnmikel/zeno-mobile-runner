const std = @import("std");
const android_emulator = @import("android_emulator.zig");
const config = @import("config.zig");
const trace = @import("trace.zig");

pub const Platform = enum {
    android,
    ios,
};

pub const IosDeviceType = enum {
    simulator,
    physical,
};

pub const RawRunOptions = struct {
    scenario_path: ?[]const u8 = null,
    serial: ?[]const u8 = null,
    trace_dir: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    android_shim_path: ?[]const u8 = null,
    ios_shim_path: ?[]const u8 = null,
    screen_recording: ?bool = null,
    android_avd_name: ?[]const u8 = null,
    android_restore_snapshot: ?[]const u8 = null,
    android_create_avd_if_missing: ?bool = null,
    android_avd_system_image: ?[]const u8 = null,
    android_avd_device_profile: ?[]const u8 = null,
    android_reset_before_run: ?bool = null,
    android_wait_ready: ?bool = null,
    ensure_device: ?bool = null,
    platform: Platform = .android,
    ios_device_type: IosDeviceType = .simulator,
};

pub const ResolvedRunOptions = struct {
    scenario_path: ?[]const u8,
    serial: ?[]const u8,
    trace_dir: ?[]const u8,
    app_id: []const u8,
    android_shim_path: ?[]const u8,
    ios_shim_path: ?[]const u8,
    android_avd_name: ?[]const u8,
    android_restore_snapshot: ?[]const u8,
    android_create_avd_if_missing: bool,
    android_avd_system_image: ?[]const u8,
    android_avd_device_profile: ?[]const u8,
    android_reset_before_run: bool,
    android_wait_ready: bool,
    ensure_device: bool,
    platform: Platform,
    ios_device_type: IosDeviceType,
};

pub const RawServeOptions = struct {
    serial: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    trace_dir: ?[]const u8 = null,
    android_shim_path: ?[]const u8 = null,
    ios_shim_path: ?[]const u8 = null,
    platform: Platform = .android,
    ios_device_type: IosDeviceType = .simulator,
};

pub const ResolvedServeOptions = struct {
    serial: ?[]const u8,
    app_id: []const u8,
    trace_dir: ?[]const u8,
    android_shim_path: ?[]const u8,
    ios_shim_path: ?[]const u8,
    platform: Platform,
    ios_device_type: IosDeviceType,
};

pub fn resolveRun(raw: RawRunOptions, cfg: ?config.Config) ResolvedRunOptions {
    const platform_cfg = platformConfigFor(raw.platform, cfg);
    return .{
        .scenario_path = raw.scenario_path orelse if (platform_cfg) |pc| pc.smoke_scenario else null,
        .serial = raw.serial orelse if (platform_cfg) |pc| pc.default_device else null,
        .trace_dir = raw.trace_dir orelse if (platform_cfg) |pc| pc.trace_dir else null,
        .app_id = raw.app_id orelse if (cfg) |value| value.app_id orelse "com.example.mobiletest" else "com.example.mobiletest",
        .android_shim_path = raw.android_shim_path orelse if (cfg) |value| value.tools.android_shim_path else null,
        .ios_shim_path = raw.ios_shim_path orelse if (cfg) |value| value.tools.ios_shim_path else null,
        .android_avd_name = raw.android_avd_name orelse if (platform_cfg) |pc| pc.avd_name else null,
        .android_restore_snapshot = raw.android_restore_snapshot orelse if (platform_cfg) |pc| pc.restore_snapshot else null,
        .android_create_avd_if_missing = raw.android_create_avd_if_missing orelse if (platform_cfg) |pc| pc.create_avd_if_missing else false,
        .android_avd_system_image = raw.android_avd_system_image orelse if (platform_cfg) |pc| pc.avd_system_image else null,
        .android_avd_device_profile = raw.android_avd_device_profile orelse if (platform_cfg) |pc| pc.avd_device_profile else null,
        .android_reset_before_run = raw.android_reset_before_run orelse if (platform_cfg) |pc| pc.reset_before_run else false,
        .android_wait_ready = raw.android_wait_ready orelse if (platform_cfg) |pc| pc.wait_ready else false,
        .ensure_device = raw.ensure_device orelse if (platform_cfg) |pc| pc.ensure_device else false,
        .platform = raw.platform,
        .ios_device_type = raw.ios_device_type,
    };
}

pub fn resolveServe(raw: RawServeOptions, cfg: ?config.Config) ResolvedServeOptions {
    const platform_cfg = platformConfigFor(raw.platform, cfg);
    return .{
        .serial = raw.serial orelse if (platform_cfg) |pc| pc.default_device else null,
        .app_id = raw.app_id orelse if (cfg) |value| value.app_id orelse "com.example.mobiletest" else "com.example.mobiletest",
        .trace_dir = raw.trace_dir orelse if (platform_cfg) |pc| pc.trace_dir else null,
        .android_shim_path = raw.android_shim_path orelse if (cfg) |value| value.tools.android_shim_path else null,
        .ios_shim_path = raw.ios_shim_path orelse if (cfg) |value| value.tools.ios_shim_path else null,
        .platform = raw.platform,
        .ios_device_type = raw.ios_device_type,
    };
}

pub fn androidPreflight(
    resolved: ResolvedRunOptions,
    adb_path: []const u8,
    emulator_path: []const u8,
    avdmanager_path: []const u8,
) ?android_emulator.PreflightOptions {
    const options = android_emulator.PreflightOptions{
        .adb_path = adb_path,
        .emulator_path = emulator_path,
        .avdmanager_path = avdmanager_path,
        .device_serial = resolved.serial,
        .avd_name = resolved.android_avd_name,
        .restore_snapshot = resolved.android_restore_snapshot,
        .create_avd_if_missing = resolved.android_create_avd_if_missing,
        .avd_system_image = resolved.android_avd_system_image,
        .avd_device_profile = resolved.android_avd_device_profile,
        .reset_before_run = resolved.android_reset_before_run,
        .wait_ready = resolved.android_wait_ready,
        .ensure_ready = resolved.ensure_device,
    };
    return if (android_emulator.hasWork(options)) options else null;
}

pub fn traceCapture(cfg: config.Config) trace.CaptureOptions {
    return .{
        .capture_screenshots = cfg.artifacts.screenshots,
        .capture_hierarchy = cfg.artifacts.hierarchy,
        .capture_logs = cfg.artifacts.logs,
        .capture_screen_recording = cfg.artifacts.screen_recording,
        .redaction = .{
            .denylist_text = cfg.redaction.denylist_text,
            .allowlist_text = cfg.redaction.allowlist_text,
            .denylist_resource_ids = cfg.redaction.denylist_resource_ids,
            .allowlist_resource_ids = cfg.redaction.allowlist_resource_ids,
        },
    };
}

fn platformConfigFor(platform: Platform, cfg: ?config.Config) ?config.PlatformConfig {
    if (cfg) |value| {
        return switch (platform) {
            .android => value.android,
            .ios => value.ios,
        };
    }
    return null;
}
