const std = @import("std");
const errors = @import("errors.zig");

test "classifies public error codes" {
    try std.testing.expectEqualStrings("scenario.invalid", errors.classify(error.ScenarioMissingSteps).code);
    try std.testing.expectEqualStrings("runner.wait_timeout", errors.classify(error.WaitTimeout).code);
    try std.testing.expectEqualStrings("ios.xctest_shim_required", errors.classify(error.IosXCTestShimRequired).code);
    try std.testing.expectEqualStrings("ios.xctest_shim_response_timeout", errors.classify(error.IosXCTestShimResponseTimedOut).code);
    try std.testing.expectEqualStrings("cli.unknown_command", errors.classify(error.unknownCommand).code);
    try std.testing.expectEqualStrings("cli.missing_discover_out", errors.classify(error.MissingDiscoverOut).code);
    try std.testing.expectEqualStrings("cli.missing_outcome_file", errors.classify(error.MissingOutcomeFile).code);
    try std.testing.expectEqualStrings("config.invalid", errors.classify(error.MissingRunEvidenceRoot).code);
    try std.testing.expectEqualStrings("config.invalid", errors.classify(error.IosShimPathForbidden).code);
    try std.testing.expectEqualStrings("cli.missing_report_input", errors.classify(error.MissingReportInput).code);
    try std.testing.expectEqualStrings("cli.missing_report_output", errors.classify(error.MissingReportOutput).code);
    try std.testing.expectEqualStrings("cli.missing_junit_output", errors.classify(error.MissingJUnitOutput).code);
    try std.testing.expectEqualStrings("cli.missing_trace_bundle_output", errors.classify(error.MissingTraceBundleOutput).code);
    try std.testing.expectEqualStrings("internal.error", errors.classify(error.OutOfMemory).code);
}
