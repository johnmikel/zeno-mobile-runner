const std = @import("std");
const cli_trace = @import("cli_trace.zig");

test "parse args rejects missing values and unknown flags" {
    try std.testing.expectError(error.MissingReportOutput, cli_trace.parseReportArgs(&.{"traces/run"}));
    try std.testing.expectError(error.MissingReportOutput, cli_trace.parseReportArgs(&.{ "traces/run", "--out" }));
    try std.testing.expectError(error.MissingJUnitOutput, cli_trace.parseReportArgs(&.{ "traces/run", "--out", "report.html", "--junit" }));
    try std.testing.expectError(error.unknownFlag, cli_trace.parseReportArgs(&.{ "traces/run", "--wat" }));

    try std.testing.expectError(error.unknownFlag, cli_trace.parseExplainArgs(&.{ "traces/run", "extra" }));

    try std.testing.expectError(error.MissingTraceDir, cli_trace.parseExportArgs(&.{}));
    try std.testing.expectError(error.MissingTraceBundleOutput, cli_trace.parseExportArgs(&.{ "traces/run", "--out" }));
    try std.testing.expectError(error.unknownFlag, cli_trace.parseExportArgs(&.{ "traces/run", "--wat" }));
}

test "parse report args accepts junit output" {
    const parsed = try cli_trace.parseReportArgs(&.{ "traces/run", "--out", "traces/run/report.html", "--junit", "traces/run/junit.xml" });

    try std.testing.expectEqualStrings("traces/run", parsed.input_path);
    try std.testing.expectEqualStrings("traces/run/report.html", parsed.out_path.?);
    try std.testing.expectEqualStrings("traces/run/junit.xml", parsed.junit_path.?);
}

test "parse report and export args accept flags before the positional" {
    const report = try cli_trace.parseReportArgs(&.{ "--out", "report.html", "traces/run" });
    try std.testing.expectEqualStrings("traces/run", report.input_path);
    try std.testing.expectEqualStrings("report.html", report.out_path.?);

    const exported = try cli_trace.parseExportArgs(&.{ "--out", "run.zmrtrace", "--redact", "traces/run" });
    try std.testing.expectEqualStrings("traces/run", exported.trace_dir);
    try std.testing.expectEqualStrings("run.zmrtrace", exported.out_path.?);
    try std.testing.expect(exported.redact);
}
