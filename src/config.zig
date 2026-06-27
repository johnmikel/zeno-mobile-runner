const std = @import("std");
const stdio = @import("stdio.zig");
const config_diagnostics = @import("config_diagnostics.zig");

pub const PlatformConfig = struct {
    enabled: bool = false,
    default_device: ?[]const u8 = null,
    smoke_scenario: ?[]const u8 = null,
    trace_dir: ?[]const u8 = null,
    avd_name: ?[]const u8 = null,
    restore_snapshot: ?[]const u8 = null,
    avd_system_image: ?[]const u8 = null,
    avd_device_profile: ?[]const u8 = null,
    reset_before_run: bool = false,
    wait_ready: bool = false,
    ensure_device: bool = false,
    create_avd_if_missing: bool = false,

    pub fn deinit(self: *PlatformConfig, allocator: std.mem.Allocator) void {
        if (self.default_device) |value| allocator.free(value);
        if (self.smoke_scenario) |value| allocator.free(value);
        if (self.trace_dir) |value| allocator.free(value);
        if (self.avd_name) |value| allocator.free(value);
        if (self.restore_snapshot) |value| allocator.free(value);
        if (self.avd_system_image) |value| allocator.free(value);
        if (self.avd_device_profile) |value| allocator.free(value);
    }
};

pub const ToolsConfig = struct {
    adb_path: ?[]const u8 = null,
    emulator_path: ?[]const u8 = null,
    avdmanager_path: ?[]const u8 = null,
    android_shim_path: ?[]const u8 = null,
    xcrun_path: ?[]const u8 = null,
    ios_shim_path: ?[]const u8 = null,
    zig_path: ?[]const u8 = null,

    pub fn deinit(self: *ToolsConfig, allocator: std.mem.Allocator) void {
        if (self.adb_path) |value| allocator.free(value);
        if (self.emulator_path) |value| allocator.free(value);
        if (self.avdmanager_path) |value| allocator.free(value);
        if (self.android_shim_path) |value| allocator.free(value);
        if (self.xcrun_path) |value| allocator.free(value);
        if (self.ios_shim_path) |value| allocator.free(value);
        if (self.zig_path) |value| allocator.free(value);
    }
};

pub const ArtifactConfig = struct {
    screenshots: bool = true,
    hierarchy: bool = true,
    logs: bool = true,
    screen_recording: bool = false,
};

pub const RedactionConfig = struct {
    denylist_text: []const []const u8 = &.{},
    allowlist_text: []const []const u8 = &.{},
    denylist_resource_ids: []const []const u8 = &.{},
    allowlist_resource_ids: []const []const u8 = &.{},

    pub fn deinit(self: *RedactionConfig, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.denylist_text);
        freeStringList(allocator, self.allowlist_text);
        freeStringList(allocator, self.denylist_resource_ids);
        freeStringList(allocator, self.allowlist_resource_ids);
    }
};

pub const ScriptCommand = struct {
    name: []const u8,
    command: []const u8,
};

pub const Config = struct {
    schema_version: u32,
    app_id: ?[]const u8 = null,
    android: PlatformConfig = .{},
    ios: PlatformConfig = .{},
    tools: ToolsConfig = .{},
    artifacts: ArtifactConfig = .{},
    redaction: RedactionConfig = .{},
    scripts: []ScriptCommand = &.{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.app_id) |value| allocator.free(value);
        self.android.deinit(allocator);
        self.ios.deinit(allocator);
        self.tools.deinit(allocator);
        self.redaction.deinit(allocator);
        freeScripts(allocator, self.scripts);
    }
};

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const content = try stdio.readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(content);
    return try parseSlice(allocator, content);
}

pub fn errorFieldPathForFile(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !?[]const u8 {
    return try config_diagnostics.errorFieldPathForFile(allocator, path, err);
}

pub fn parseSlice(allocator: std.mem.Allocator, content: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ConfigMustBeObject;
    const object = parsed.value.object;
    try rejectUnknownFields(object, &.{ "schemaVersion", "appId", "android", "ios", "artifacts", "redaction", "tools", "scripts" });
    const schema_version = try requiredU32(object, "schemaVersion");

    var cfg = Config{
        .schema_version = schema_version,
        .app_id = try optionalString(allocator, object, "appId"),
        .android = try platformConfig(allocator, object.get("android")),
        .ios = try platformConfig(allocator, object.get("ios")),
        .tools = try toolsConfig(allocator, object.get("tools")),
        .artifacts = try artifactConfig(object.get("artifacts")),
        .redaction = try redactionConfig(allocator, object.get("redaction")),
        .scripts = try scriptsConfig(allocator, object.get("scripts")),
    };
    errdefer cfg.deinit(allocator);

    if (cfg.schema_version != 1) return error.UnsupportedConfigVersion;
    return cfg;
}

fn platformConfig(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) !PlatformConfig {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.ConfigPlatformMustBeObject;
    const object = value.object;
    try rejectUnknownFields(object, &.{
        "enabled",
        "defaultDevice",
        "smokeScenario",
        "traceDir",
        "avdName",
        "restoreSnapshot",
        "createAvdIfMissing",
        "avdSystemImage",
        "avdDeviceProfile",
        "resetBeforeRun",
        "waitReady",
        "ensureDevice",
    });
    return .{
        .enabled = try optionalBool(object, "enabled") orelse false,
        .default_device = try optionalString(allocator, object, "defaultDevice"),
        .smoke_scenario = try optionalString(allocator, object, "smokeScenario"),
        .trace_dir = try optionalString(allocator, object, "traceDir"),
        .avd_name = try optionalString(allocator, object, "avdName"),
        .restore_snapshot = try optionalString(allocator, object, "restoreSnapshot"),
        .avd_system_image = try optionalString(allocator, object, "avdSystemImage"),
        .avd_device_profile = try optionalString(allocator, object, "avdDeviceProfile"),
        .reset_before_run = try optionalBool(object, "resetBeforeRun") orelse false,
        .wait_ready = try optionalBool(object, "waitReady") orelse false,
        .ensure_device = try optionalBool(object, "ensureDevice") orelse false,
        .create_avd_if_missing = try optionalBool(object, "createAvdIfMissing") orelse false,
    };
}

pub fn errorFieldPathForSlice(allocator: std.mem.Allocator, content: []const u8, err: anyerror) !?[]const u8 {
    return try config_diagnostics.errorFieldPathForSlice(allocator, content, err);
}

fn toolsConfig(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) !ToolsConfig {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.ConfigToolsMustBeObject;
    const object = value.object;
    try rejectUnknownFields(object, &.{ "adbPath", "emulatorPath", "avdmanagerPath", "androidShimPath", "xcrunPath", "iosShimPath", "zigPath" });
    return .{
        .adb_path = try optionalString(allocator, object, "adbPath"),
        .emulator_path = try optionalString(allocator, object, "emulatorPath"),
        .avdmanager_path = try optionalString(allocator, object, "avdmanagerPath"),
        .android_shim_path = try optionalString(allocator, object, "androidShimPath"),
        .xcrun_path = try optionalString(allocator, object, "xcrunPath"),
        .ios_shim_path = try optionalString(allocator, object, "iosShimPath"),
        .zig_path = try optionalString(allocator, object, "zigPath"),
    };
}

fn artifactConfig(maybe_value: ?std.json.Value) !ArtifactConfig {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.ConfigArtifactsMustBeObject;
    const object = value.object;
    try rejectUnknownFields(object, &.{ "screenshots", "hierarchy", "logs", "screenRecording" });
    return .{
        .screenshots = try optionalBool(object, "screenshots") orelse true,
        .hierarchy = try optionalBool(object, "hierarchy") orelse true,
        .logs = try optionalBool(object, "logs") orelse true,
        .screen_recording = try optionalBool(object, "screenRecording") orelse false,
    };
}

fn redactionConfig(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) !RedactionConfig {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.ConfigRedactionMustBeObject;
    const object = value.object;
    try rejectUnknownFields(object, &.{ "denylistText", "allowlistText", "denylistResourceIds", "allowlistResourceIds" });
    var parsed = RedactionConfig{};
    errdefer parsed.deinit(allocator);
    parsed.denylist_text = try optionalStringList(allocator, object, "denylistText");
    parsed.allowlist_text = try optionalStringList(allocator, object, "allowlistText");
    parsed.denylist_resource_ids = try optionalStringList(allocator, object, "denylistResourceIds");
    parsed.allowlist_resource_ids = try optionalStringList(allocator, object, "allowlistResourceIds");
    return parsed;
}

fn rejectUnknownFields(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                found = true;
                break;
            }
        }
        if (!found) return error.ConfigUnknownField;
    }
}

fn scriptsConfig(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]ScriptCommand {
    const value = maybe_value orelse return &.{};
    if (value != .object) return error.ConfigScriptsMustBeObject;
    if (value.object.count() == 0) return &.{};

    var scripts = try allocator.alloc(ScriptCommand, value.object.count());
    errdefer allocator.free(scripts);

    var written: usize = 0;
    errdefer {
        for (scripts[0..written]) |script| {
            allocator.free(script.name);
            allocator.free(script.command);
        }
    }

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.ConfigFieldMustBeString;
        if (entry.value_ptr.string.len == 0) return error.ConfigFieldMustBeNonEmptyString;
        scripts[written] = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .command = try allocator.dupe(u8, entry.value_ptr.string),
        };
        written += 1;
    }
    return scripts;
}

fn requiredU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return error.MissingConfigSchemaVersion;
    if (value != .integer) return error.ConfigSchemaVersionMustBeInteger;
    if (value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.ConfigSchemaVersionMustBeInteger;
    return @intCast(value.integer);
}

fn optionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.ConfigFieldMustBeString;
    if (value.string.len == 0) return error.ConfigFieldMustBeNonEmptyString;
    return try allocator.dupe(u8, value.string);
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    if (value != .bool) return error.ConfigFieldMustBeBool;
    return value.bool;
}

fn optionalStringList(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return &.{};
    if (value != .array) return error.ConfigFieldMustBeStringArray;
    if (value.array.items.len == 0) return &.{};

    var output = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(output);
    var written: usize = 0;
    errdefer {
        for (output[0..written]) |item| allocator.free(item);
    }

    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.ConfigFieldMustBeStringArray;
        if (item.string.len == 0) return error.ConfigFieldMustBeNonEmptyString;
        output[index] = try allocator.dupe(u8, item.string);
        written += 1;
    }
    return output;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn freeScripts(allocator: std.mem.Allocator, scripts: []ScriptCommand) void {
    if (scripts.len == 0) return;
    for (scripts) |script| {
        allocator.free(script.name);
        allocator.free(script.command);
    }
    allocator.free(scripts);
}
