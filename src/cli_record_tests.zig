const std = @import("std");
const cli_record = @import("cli_record.zig");

test "record command parses trace, transport, and port options" {
    const parsed = try cli_record.parseArgs(&.{
        "--trace-dir",
        "traces/agent",
        "--transport",
        "tcp",
        "--port",
        "7788",
        "--json",
    });
    try std.testing.expectEqualStrings("traces/agent", parsed.trace_dir);
    try std.testing.expectEqual(cli_record.Transport.tcp, parsed.transport);
    try std.testing.expectEqual(@as(u16, 7788), parsed.port);
    try std.testing.expect(parsed.json);
}

test "record command rejects missing and invalid options" {
    try std.testing.expectError(error.MissingRecordTraceDir, cli_record.parseArgs(&.{}));
    try std.testing.expectError(error.MissingRecordTraceDir, cli_record.parseArgs(&.{ "--trace-dir" }));
    try std.testing.expectError(error.InvalidRecordTransport, cli_record.parseArgs(&.{ "--trace-dir", "trace", "--transport", "udp" }));
    try std.testing.expectError(error.InvalidRecordPort, cli_record.parseArgs(&.{ "--trace-dir", "trace", "--port", "bad" }));
    try std.testing.expectError(error.unknownFlag, cli_record.parseArgs(&.{ "--trace-dir", "trace", "--wat" }));
}
