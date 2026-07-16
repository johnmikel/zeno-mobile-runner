const std = @import("std");
const run_outcome = @import("run_outcome.zig");
const stdio = @import("stdio.zig");

test "run outcome contract is closed and serializes stable ownership" {
    const outcome = run_outcome.Outcome{
        .status = .failed,
        .failure_owner = .app,
        .error_code = "app.assertion_failed",
        .phase = "scenario.execute",
        .summary = "Scenario assertion failed while the driver remained healthy",
        .hint = "Inspect the trace failure and app state",
        .trace = "traces/ios-run-1",
        .report = null,
        .child_status = 1,
        .ios_shim = .{
            .target_kind = .simulator,
            .mode = .generated,
            .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
    };

    try run_outcome.validate(outcome);
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try run_outcome.writeJson(&encoded.writer, outcome);

    try std.testing.expectEqualStrings(
        "{\"schemaVersion\":1,\"status\":\"failed\",\"failureOwner\":\"app\",\"errorCode\":\"app.assertion_failed\",\"phase\":\"scenario.execute\",\"summary\":\"Scenario assertion failed while the driver remained healthy\",\"hint\":\"Inspect the trace failure and app state\",\"trace\":\"traces/ios-run-1\",\"report\":null,\"childStatus\":1,\"iosShim\":{\"targetKind\":\"simulator\",\"mode\":\"generated\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}\n",
        encoded.written(),
    );
}

test "run outcome invariants reject contradictory terminal states and shim provenance" {
    const passed = run_outcome.Outcome{
        .status = .passed,
        .failure_owner = .none,
        .phase = "complete",
        .child_status = 0,
    };
    try run_outcome.validate(passed);

    var contradictory = passed;
    contradictory.error_code = "runner.unclassified";
    try std.testing.expectError(error.InvalidRunOutcome, run_outcome.validate(contradictory));

    const missing_shim_digest = run_outcome.Outcome{
        .status = .failed,
        .failure_owner = .runner,
        .error_code = "runner.driver_protocol",
        .phase = "scenario.execute",
        .summary = "Driver protocol failed",
        .hint = "Inspect the runner diagnostics",
        .child_status = 1,
        .ios_shim = .{ .target_kind = .physical, .mode = .provided },
    };
    try std.testing.expectError(error.InvalidRunOutcome, run_outcome.validate(missing_shim_digest));

    var disabled = missing_shim_digest;
    disabled.ios_shim.?.mode = .disabled;
    try run_outcome.validate(disabled);

    var owner_mismatch = disabled;
    owner_mismatch.error_code = "app.assertion_failed";
    try std.testing.expectError(error.InvalidRunOutcome, run_outcome.validate(owner_mismatch));

    var invalid_phase = disabled;
    invalid_phase.phase = "made.up.phase";
    try std.testing.expectError(error.InvalidRunOutcome, run_outcome.validate(invalid_phase));

    var invalid_status = disabled;
    invalid_status.child_status = 256;
    try std.testing.expectError(error.InvalidRunOutcome, run_outcome.validate(invalid_status));

    var long_summary: [513]u8 = undefined;
    @memset(&long_summary, 'a');
    var oversized = disabled;
    oversized.summary = &long_summary;
    try std.testing.expectError(error.InvalidRunOutcome, run_outcome.validate(oversized));

    var non_normalized_path = disabled;
    non_normalized_path.trace = "traces\\run";
    try std.testing.expectError(error.InvalidRunOutcome, run_outcome.validate(non_normalized_path));
}

test "run outcome atomic write stays under run-outcomes and preserves prior content on failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(stdio.io(), "attempt/run-outcomes");
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/attempt", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const relative = "run-outcomes/0123456789abcdef0123456789abcdef.json";
    const passed = run_outcome.Outcome{
        .status = .passed,
        .failure_owner = .none,
        .phase = "complete",
        .child_status = 0,
    };
    try run_outcome.writeAtomic(std.testing.allocator, root, relative, passed);

    const original = try tmp.dir.readFileAlloc(
        stdio.io(),
        "attempt/run-outcomes/0123456789abcdef0123456789abcdef.json",
        std.testing.allocator,
        .limited(run_outcome.max_sidecar_bytes),
    );
    defer std.testing.allocator.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, "\"status\":\"passed\"") != null);

    var invalid = passed;
    invalid.summary = "must not appear on passed outcome";
    try std.testing.expectError(
        error.InvalidRunOutcome,
        run_outcome.writeAtomic(std.testing.allocator, root, relative, invalid),
    );
    try std.testing.expectError(
        error.InvalidOutcomePath,
        run_outcome.writeAtomic(std.testing.allocator, root, "../escaped.json", passed),
    );

    const retained = try tmp.dir.readFileAlloc(
        stdio.io(),
        "attempt/run-outcomes/0123456789abcdef0123456789abcdef.json",
        std.testing.allocator,
        .limited(run_outcome.max_sidecar_bytes),
    );
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings(original, retained);
}
