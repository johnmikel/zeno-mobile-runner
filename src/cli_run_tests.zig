const std = @import("std");
const cli_run = @import("cli_run.zig");
const run_outcome = @import("run_outcome.zig");

test "parse args rejects missing option values and invalid platform values" {
    try std.testing.expectError(error.MissingDeviceSerial, cli_run.parseArgs(&.{"--device"}));
    try std.testing.expectError(error.MissingTraceDir, cli_run.parseArgs(&.{"--trace-dir"}));
    try std.testing.expectError(error.MissingAppId, cli_run.parseArgs(&.{"--app-id"}));
    try std.testing.expectError(error.MissingAdbPath, cli_run.parseArgs(&.{"--adb"}));
    try std.testing.expectError(error.MissingEmulatorPath, cli_run.parseArgs(&.{"--emulator"}));
    try std.testing.expectError(error.MissingAvdmanagerPath, cli_run.parseArgs(&.{"--avdmanager"}));
    try std.testing.expectError(error.MissingAndroidShimPath, cli_run.parseArgs(&.{"--android-shim"}));
    try std.testing.expectError(error.MissingXcrunPath, cli_run.parseArgs(&.{"--xcrun"}));
    try std.testing.expectError(error.MissingIosShimPath, cli_run.parseArgs(&.{"--ios-shim"}));
    try std.testing.expectError(error.UnsupportedPlatform, cli_run.parseArgs(&.{ "--platform", "watchos" }));
    try std.testing.expectError(error.UnsupportedIosDeviceType, cli_run.parseArgs(&.{ "--ios-device-type", "watch" }));
    try std.testing.expectError(error.MissingAndroidAvdName, cli_run.parseArgs(&.{"--android-avd"}));
    try std.testing.expectError(error.MissingAndroidSnapshotName, cli_run.parseArgs(&.{"--restore-snapshot"}));
    try std.testing.expectError(error.MissingAndroidAvdSystemImage, cli_run.parseArgs(&.{"--avd-system-image"}));
    try std.testing.expectError(error.MissingAndroidAvdDeviceProfile, cli_run.parseArgs(&.{"--avd-device"}));
    try std.testing.expectError(error.MissingDiscoverOut, cli_run.parseArgs(&.{"--discover-out"}));
    try std.testing.expectError(error.MissingOutcomeFile, cli_run.parseArgs(&.{"--outcome-file"}));
    try std.testing.expectError(error.MissingIosShimMode, cli_run.parseArgs(&.{"--ios-shim-mode"}));
    try std.testing.expectError(error.UnsupportedIosShimMode, cli_run.parseArgs(&.{ "--ios-shim-mode", "automatic" }));

    const ensure = try cli_run.parseArgs(&.{"--ensure-device"});
    try std.testing.expect(ensure.raw.ensure_device.?);

    const no_ensure = try cli_run.parseArgs(&.{"--no-ensure-device"});
    try std.testing.expectEqual(false, no_ensure.raw.ensure_device.?);
}

test "run outcome and ios shim provenance flags normalize without changing json mode" {
    const disabled = try cli_run.parseArgs(&.{
        "flow.json",
        "--json",
        "--outcome-file",
        "run-outcomes/0123456789abcdef0123456789abcdef.json",
    });
    try std.testing.expect(disabled.json);
    try std.testing.expectEqualStrings(
        "run-outcomes/0123456789abcdef0123456789abcdef.json",
        disabled.outcome_file.?,
    );
    try std.testing.expectEqual(.disabled, try cli_run.resolveIosShimMode(disabled.ios_shim_mode, null));

    const compatible = try cli_run.parseArgs(&.{ "--ios-shim", "shim.xctestrun" });
    try std.testing.expectEqual(.provided, try cli_run.resolveIosShimMode(compatible.ios_shim_mode, compatible.raw.ios_shim_path));

    const generated = try cli_run.parseArgs(&.{ "--ios-shim", "generated.xctestrun", "--ios-shim-mode", "generated" });
    try std.testing.expectEqual(.generated, try cli_run.resolveIosShimMode(generated.ios_shim_mode, generated.raw.ios_shim_path));

    const missing = try cli_run.parseArgs(&.{ "--ios-shim-mode", "provided" });
    try std.testing.expectError(error.IosShimPathRequired, cli_run.resolveIosShimMode(missing.ios_shim_mode, null));

    const contradictory = try cli_run.parseArgs(&.{ "--ios-shim", "shim.xctestrun", "--ios-shim-mode", "disabled" });
    try std.testing.expectError(error.IosShimPathForbidden, cli_run.resolveIosShimMode(contradictory.ios_shim_mode, contradictory.raw.ios_shim_path));
}

test "structured run outcome owns assertion shim and unclassified failures exactly" {
    const shim = run_outcome.IosShim{
        .target_kind = .simulator,
        .mode = .generated,
        .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };

    const assertion = cli_run.outcomeForRun(
        error.AssertionFailed,
        "traces/run.zmrtrace",
        shim,
    );
    try std.testing.expectEqual(.app, assertion.failure_owner);
    try std.testing.expectEqualStrings("app.assertion_failed", assertion.error_code.?);
    try std.testing.expectEqualStrings("scenario.execute", assertion.phase);

    const unsupported = cli_run.outcomeForRun(
        error.IosXCTestShimRequired,
        null,
        shim,
    );
    try std.testing.expectEqual(.configuration, unsupported.failure_owner);
    try std.testing.expectEqualStrings("config.unsupported_capability", unsupported.error_code.?);

    const contradictory = cli_run.outcomeForRun(
        error.IosShimPathForbidden,
        null,
        shim,
    );
    try std.testing.expectEqual(.configuration, contradictory.failure_owner);
    try std.testing.expectEqualStrings("config.invalid", contradictory.error_code.?);
    try std.testing.expectEqualStrings("invocation", contradictory.phase);

    const shim_build = cli_run.outcomeForRun(
        error.IosXCTestShimBuildTimedOut,
        null,
        shim,
    );
    try std.testing.expectEqual(.runner, shim_build.failure_owner);
    try std.testing.expectEqualStrings("runner.ios_shim.build_failed", shim_build.error_code.?);
    try std.testing.expectEqualStrings("shim.build", shim_build.phase);

    const unknown = cli_run.outcomeForRun(error.CommandFailed, null, null);
    try std.testing.expectEqual(.runner, unknown.failure_owner);
    try std.testing.expectEqualStrings("runner.unclassified", unknown.error_code.?);
}
