//! The single description of what a `.zmr/config.json` may contain.
//!
//! `config.zig` rejects unknown fields from these tables and
//! `config_diagnostics.zig` points at offending fields from the same tables, so
//! the parser and its diagnostics cannot drift apart. They did drift once:
//! `ensureDevice` parsed fine while the diagnostics reported it as unknown.

const std = @import("std");

pub const FieldKind = enum { boolean, string };

pub const Field = struct {
    name: []const u8,
    kind: FieldKind,
};

pub const platform_fields = [_]Field{
    .{ .name = "enabled", .kind = .boolean },
    .{ .name = "defaultDevice", .kind = .string },
    .{ .name = "smokeScenario", .kind = .string },
    .{ .name = "traceDir", .kind = .string },
    .{ .name = "avdName", .kind = .string },
    .{ .name = "restoreSnapshot", .kind = .string },
    .{ .name = "createAvdIfMissing", .kind = .boolean },
    .{ .name = "avdSystemImage", .kind = .string },
    .{ .name = "avdDeviceProfile", .kind = .string },
    .{ .name = "resetBeforeRun", .kind = .boolean },
    .{ .name = "waitReady", .kind = .boolean },
    .{ .name = "ensureDevice", .kind = .boolean },
};

pub const tools_fields = [_]Field{
    .{ .name = "adbPath", .kind = .string },
    .{ .name = "emulatorPath", .kind = .string },
    .{ .name = "avdmanagerPath", .kind = .string },
    .{ .name = "androidShimPath", .kind = .string },
    .{ .name = "xcrunPath", .kind = .string },
    .{ .name = "iosShimPath", .kind = .string },
    .{ .name = "zigPath", .kind = .string },
};

pub const artifact_fields = [_]Field{
    .{ .name = "screenshots", .kind = .boolean },
    .{ .name = "hierarchy", .kind = .boolean },
    .{ .name = "logs", .kind = .boolean },
    .{ .name = "screenRecording", .kind = .boolean },
};

pub const root_fields = [_][]const u8{ "schemaVersion", "appId", "android", "ios", "artifacts", "redaction", "tools", "scripts" };

pub const redaction_fields = [_][]const u8{ "denylistText", "allowlistText", "denylistResourceIds", "allowlistResourceIds" };

/// Every field name in `fields`.
pub fn allNames(comptime fields: []const Field) []const []const u8 {
    return comptime blk: {
        var names: []const []const u8 = &.{};
        for (fields) |field| names = names ++ [_][]const u8{field.name};
        break :blk names;
    };
}

/// Field names in `fields` whose kind is `kind`.
pub fn namesOfKind(comptime fields: []const Field, comptime kind: FieldKind) []const []const u8 {
    return comptime blk: {
        var names: []const []const u8 = &.{};
        for (fields) |field| {
            if (field.kind == kind) names = names ++ [_][]const u8{field.name};
        }
        break :blk names;
    };
}
