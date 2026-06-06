pub const runner_version = "0.1.7";
pub const protocol_version = "2026-04-28";
pub const protocol_min_compatible_version = "2026-04-28";
pub const protocol_stability = "dev-preview";
pub const protocol_breaking_change_policy = "version-and-changelog";

pub fn writePlain(writer: anytype) !void {
    try writer.print("zmr {s} protocol {s}\n", .{ runner_version, protocol_version });
}

pub fn writeJson(writer: anytype) !void {
    try writer.print(
        "{{\"name\":\"zmr\",\"version\":\"{s}\",\"protocolVersion\":\"{s}\",\"minimumCompatibleProtocolVersion\":\"{s}\",\"stability\":\"{s}\",\"breakingChangePolicy\":\"{s}\"}}\n",
        .{
            runner_version,
            protocol_version,
            protocol_min_compatible_version,
            protocol_stability,
            protocol_breaking_change_policy,
        },
    );
}
