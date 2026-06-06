const std = @import("std");
const trace = @import("trace.zig");

pub const PublicSchema = struct {
    name: []const u8,
    path: []const u8,
    id: []const u8,
    description: []const u8,
};

const public_schemas = [_]PublicSchema{
    .{ .name = "json-rpc", .path = "schemas/json-rpc.schema.json", .id = "https://zmr.dev/schemas/json-rpc.schema.json", .description = "JSON-RPC requests and responses used by zmr serve" },
    .{ .name = "scenario", .path = "schemas/scenario.schema.json", .id = "https://zmr.dev/schemas/scenario.schema.json", .description = "Scenario files consumed by zmr run and zmr validate" },
    .{ .name = "snapshot", .path = "schemas/snapshot.schema.json", .id = "https://zmr.dev/schemas/snapshot.schema.json", .description = "ObservationSnapshot JSON emitted by live RPC and persisted trace snapshots" },
    .{ .name = "semantic-snapshot", .path = "schemas/semantic-snapshot.schema.json", .id = "https://zmr.dev/schemas/semantic-snapshot.schema.json", .description = "Agent-optimized semantic snapshot emitted by observe.semanticSnapshot and zmr mcp" },
    .{ .name = "action-result", .path = "schemas/action-result.schema.json", .id = "https://zmr.dev/schemas/action-result.schema.json", .description = "Typed action result shape reserved for richer protocol responses" },
    .{ .name = "trace-event", .path = "schemas/trace-event.schema.json", .id = "https://zmr.dev/schemas/trace-event.schema.json", .description = "One JSONL event row from events.jsonl" },
    .{ .name = "trace-manifest", .path = "schemas/trace-manifest.schema.json", .id = "https://zmr.dev/schemas/trace-manifest.schema.json", .description = "trace.json summary for one traced run" },
    .{ .name = "zmr-config", .path = "schemas/zmr-config.schema.json", .id = "https://zmr.dev/schemas/zmr-config.schema.json", .description = "App-local .zmr/config.json defaults used by the CLI and npm wizard" },
    .{ .name = "doctor-output", .path = "schemas/doctor-output.schema.json", .id = "https://zmr.dev/schemas/doctor-output.schema.json", .description = "Machine-readable zmr doctor --json setup diagnostics" },
    .{ .name = "init-output", .path = "schemas/init-output.schema.json", .id = "https://zmr.dev/schemas/init-output.schema.json", .description = "Machine-readable zmr init --json bootstrap output" },
    .{ .name = "import-output", .path = "schemas/import-output.schema.json", .id = "https://zmr.dev/schemas/import-output.schema.json", .description = "Machine-readable zmr import --json migration output" },
    .{ .name = "devices-output", .path = "schemas/devices-output.schema.json", .id = "https://zmr.dev/schemas/devices-output.schema.json", .description = "Machine-readable zmr devices --json discovery output" },
    .{ .name = "validate-output", .path = "schemas/validate-output.schema.json", .id = "https://zmr.dev/schemas/validate-output.schema.json", .description = "Machine-readable zmr validate --json scenario preflight output" },
    .{ .name = "version-output", .path = "schemas/version-output.schema.json", .id = "https://zmr.dev/schemas/version-output.schema.json", .description = "Machine-readable zmr version --json compatibility output" },
    .{ .name = "capabilities-output", .path = "schemas/capabilities-output.schema.json", .id = "https://zmr.dev/schemas/capabilities-output.schema.json", .description = "Machine-readable runner.capabilities JSON-RPC result" },
    .{ .name = "explain-output", .path = "schemas/explain-output.schema.json", .id = "https://zmr.dev/schemas/explain-output.schema.json", .description = "Machine-readable zmr explain --json failure triage output" },
    .{ .name = "run-output", .path = "schemas/run-output.schema.json", .id = "https://zmr.dev/schemas/run-output.schema.json", .description = "Machine-readable zmr run --json terminal summary output" },
    .{ .name = "inspect-output", .path = "schemas/inspect-output.schema.json", .id = "https://zmr.dev/schemas/inspect-output.schema.json", .description = "Machine-readable zmr inspect --json app and agent handoff output" },
    .{ .name = "discover-output", .path = "schemas/discover-output.schema.json", .id = "https://zmr.dev/schemas/discover-output.schema.json", .description = "Machine-readable zmr discover --json trace-backed scenario discovery output" },
    .{ .name = "explore-output", .path = "schemas/explore-output.schema.json", .id = "https://zmr.dev/schemas/explore-output.schema.json", .description = "Machine-readable zmr explore --json review-first trace exploration output" },
    .{ .name = "draft-output", .path = "schemas/draft-output.schema.json", .id = "https://zmr.dev/schemas/draft-output.schema.json", .description = "Machine-readable zmr draft --json scenario draft output" },
    .{ .name = "release-manifest", .path = "schemas/release-manifest.schema.json", .id = "https://zmr.dev/schemas/release-manifest.schema.json", .description = "Machine-readable RELEASE_MANIFEST.json emitted with release archives" },
    .{ .name = "release-readiness-output", .path = "schemas/release-readiness-output.schema.json", .id = "https://zmr.dev/schemas/release-readiness-output.schema.json", .description = "Machine-readable zmr-release-readiness --json release evidence gate output" },
    .{ .name = "schemas-output", .path = "schemas/schemas-output.schema.json", .id = "https://zmr.dev/schemas/schemas-output.schema.json", .description = "Machine-readable zmr schemas --json public schema index" },
};

pub fn all() []const PublicSchema {
    return public_schemas[0..];
}

pub fn writeJson(writer: anytype) !void {
    try writer.print("{{\"ok\":true,\"count\":{d},\"schemas\":[", .{public_schemas.len});
    for (public_schemas, 0..) |schema_info, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try trace.writeJsonString(writer, schema_info.name);
        try writer.writeAll(",\"path\":");
        try trace.writeJsonString(writer, schema_info.path);
        try writer.writeAll(",\"id\":");
        try trace.writeJsonString(writer, schema_info.id);
        try writer.writeAll(",\"description\":");
        try trace.writeJsonString(writer, schema_info.description);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}\n");
}
