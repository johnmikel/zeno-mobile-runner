const std = @import("std");
const version = @import("version.zig");

test "plain version output includes runner and protocol versions" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    try version.writePlain(buffer.writer(std.testing.allocator));

    try std.testing.expectEqualStrings("zmr 0.1.8 protocol 2026-04-28\n", buffer.items);
}

test "json version output includes protocol compatibility metadata" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    try version.writeJson(buffer.writer(std.testing.allocator));

    try std.testing.expectEqualStrings(
        "{\"name\":\"zmr\",\"version\":\"0.1.8\",\"protocolVersion\":\"2026-04-28\",\"minimumCompatibleProtocolVersion\":\"2026-04-28\",\"stability\":\"dev-preview\",\"breakingChangePolicy\":\"version-and-changelog\"}\n",
        buffer.items,
    );
}

test "protocol compatibility policy is explicit for clients" {
    try std.testing.expectEqualStrings("2026-04-28", version.protocol_min_compatible_version);
    try std.testing.expectEqualStrings("dev-preview", version.protocol_stability);
    try std.testing.expectEqualStrings("version-and-changelog", version.protocol_breaking_change_policy);
}
