const std = @import("std");
const test_io = @import("test_io.zig");
const version = @import("version.zig");

test "plain version output includes runner and protocol versions" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    try version.writePlain(&buffer.writer);

    try std.testing.expectEqualStrings("zmr 0.2.13 protocol 2026-04-28\n", buffer.written());
}

test "json version output includes protocol compatibility metadata" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    try version.writeJson(&buffer.writer);

    try std.testing.expectEqualStrings(
        "{\"name\":\"zmr\",\"version\":\"0.2.13\",\"protocolVersion\":\"2026-04-28\",\"minimumCompatibleProtocolVersion\":\"2026-04-28\",\"stability\":\"dev-preview\",\"breakingChangePolicy\":\"version-and-changelog\"}\n",
        buffer.written(),
    );
}

test "protocol compatibility policy is explicit for clients" {
    try std.testing.expectEqualStrings("2026-04-28", version.protocol_min_compatible_version);
    try std.testing.expectEqualStrings("dev-preview", version.protocol_stability);
    try std.testing.expectEqualStrings("version-and-changelog", version.protocol_breaking_change_policy);
}
