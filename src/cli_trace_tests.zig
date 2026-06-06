const std = @import("std");
const cli_trace = @import("cli_trace.zig");

test "parse args rejects missing values and unknown flags" {
    try std.testing.expectError(error.MissingReportOutput, cli_trace.parseReportArgs(&.{"traces/run"}));
    try std.testing.expectError(error.MissingReportOutput, cli_trace.parseReportArgs(&.{ "traces/run", "--out" }));
    try std.testing.expectError(error.MissingJUnitOutput, cli_trace.parseReportArgs(&.{ "traces/run", "--out", "report.html", "--junit" }));
    try std.testing.expectError(error.UnknownFlag, cli_trace.parseReportArgs(&.{ "traces/run", "--wat" }));

    try std.testing.expectError(error.UnknownFlag, cli_trace.parseExplainArgs(&.{ "traces/run", "extra" }));

    try std.testing.expectError(error.MissingTraceDir, cli_trace.parseExportArgs(&.{}));
    try std.testing.expectError(error.MissingTraceBundleOutput, cli_trace.parseExportArgs(&.{ "traces/run", "--out" }));
    try std.testing.expectError(error.UnknownFlag, cli_trace.parseExportArgs(&.{ "traces/run", "--wat" }));
}

test "parse report args accepts junit output" {
    const parsed = try cli_trace.parseReportArgs(&.{ "traces/run", "--out", "traces/run/report.html", "--junit", "traces/run/junit.xml" });

    try std.testing.expectEqualStrings("traces/run", parsed.input_path);
    try std.testing.expectEqualStrings("traces/run/report.html", parsed.out_path.?);
    try std.testing.expectEqualStrings("traces/run/junit.xml", parsed.junit_path.?);
}
