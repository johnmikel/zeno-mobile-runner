const std = @import("std");
const doctor = @import("doctor.zig");
const importer = @import("importer.zig");
const scaffold = @import("scaffold.zig");
const trace = @import("trace.zig");
const trace_summary = @import("trace_summary.zig");
const validation = @import("validation.zig");

pub const RunDiscovery = struct {
    json: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
};

pub fn writeImportJson(writer: anytype, format: []const u8, source_path: []const u8, result: importer.ImportResult) !void {
    try writer.writeAll("{\"ok\":true,\"format\":");
    try trace.writeJsonString(writer, format);
    try writer.writeAll(",\"source\":");
    try trace.writeJsonString(writer, source_path);
    try writer.writeAll(",\"out\":");
    try trace.writeJsonString(writer, result.out_path);
    try writer.writeAll(",\"name\":");
    try trace.writeJsonString(writer, result.name);
    try writer.writeAll(",\"appId\":");
    if (result.app_id) |app_id| {
        try trace.writeJsonString(writer, app_id);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"stepCount\":{d}", .{result.step_count});
    try writer.print(",\"supportedCount\":{d},\"rewrittenCount\":{d},\"unsupportedCount\":{d},\"compatibilityReport\":", .{ result.supported_count, result.rewritten_count, result.unsupported_count });
    if (result.compatibility_report_path) |path| {
        try trace.writeJsonString(writer, path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"next\":\"zmr validate ");
    try writeShellArgJsonContent(writer, result.out_path);
    try writer.writeAll("\"");
    try writeImportNextCommandsJson(writer, result.out_path);
    try writer.writeAll("}\n");
}

fn writeImportNextCommandsJson(writer: anytype, out_path: []const u8) !void {
    try writer.writeAll(",\"nextCommands\":[\"zmr validate --json ");
    try writeShellArgJsonContent(writer, out_path);
    try writer.writeAll("\",\"zmr run ");
    try writeShellArgJsonContent(writer, out_path);
    try writer.writeAll(" --json --trace-dir traces/zmr-run\"]");
}

pub fn writeInitAppJson(writer: anytype, dir: []const u8, app_id: []const u8) !void {
    try writer.writeAll("{\"ok\":true,\"mode\":\"app\",\"dir\":");
    try trace.writeJsonString(writer, dir);
    try writer.writeAll(",\"appId\":");
    try trace.writeJsonString(writer, app_id);
    try writer.writeAll(",\"created\":[");
    for (scaffold.app_created_files, 0..) |path, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJoinedPathJson(writer, dir, path);
    }
    try writer.writeAll("],\"configPath\":");
    try writeJoinedPathJson(writer, dir, scaffold.app_config_file);
    try writer.writeAll(",\"androidScenarioPath\":");
    try writeJoinedPathJson(writer, dir, scaffold.app_android_smoke_file);
    try writer.writeAll(",\"iosScenarioPath\":");
    try writeJoinedPathJson(writer, dir, scaffold.app_ios_smoke_file);
    try writer.writeAll(",\"deviceMatrixPath\":");
    try writeJoinedPathJson(writer, dir, scaffold.app_device_matrix_file);
    try writer.writeAll(",\"agentInstructionsPath\":");
    try writeJoinedPathJson(writer, dir, scaffold.app_agents_file);
    try writer.writeAll(",\"next\":");
    try writer.writeAll("\"zmr doctor --strict --json --config ");
    try writeJoinedPathShellArgJsonContent(writer, dir, scaffold.app_config_file);
    try writer.writeAll("\"");
    try writer.writeAll(",\"nextCommands\":[");
    try writeInitDoctorCommandJson(writer, dir);
    try writer.writeAll(",");
    try trace.writeJsonString(writer, "zmr schemas --json");
    try writer.writeAll(",");
    try writeInitValidateCommandJson(writer, dir, scaffold.app_android_smoke_file);
    try writer.writeAll(",");
    try writeInitValidateCommandJson(writer, dir, scaffold.app_ios_smoke_file);
    try writer.writeAll("]");
    try writeInitSmokeCommandsJson(writer, dir);
    try writer.print(",\"scriptCount\":{d}", .{scaffold.app_script_names.len});
    try writer.writeAll(",\"scriptNames\":[");
    for (scaffold.app_script_names, 0..) |script_name, index| {
        if (index > 0) try writer.writeAll(",");
        try trace.writeJsonString(writer, script_name);
    }
    try writer.writeAll("]}\n");
}

fn writeInitDoctorCommandJson(writer: anytype, dir: []const u8) !void {
    try writer.writeAll("\"zmr doctor --strict --json --config ");
    try writeJoinedPathShellArgJsonContent(writer, dir, scaffold.app_config_file);
    try writer.writeAll("\"");
}

fn writeInitValidateCommandJson(writer: anytype, dir: []const u8, scenario_path: []const u8) !void {
    try writer.writeAll("\"zmr validate --json ");
    try writeJoinedPathShellArgJsonContent(writer, dir, scenario_path);
    try writer.writeAll("\"");
}

fn writeInitSmokeCommandsJson(writer: anytype, dir: []const u8) !void {
    try writer.writeAll(",\"smokeCommands\":[\"zmr run ");
    try writeJoinedPathShellArgJsonContent(writer, dir, scaffold.app_android_smoke_file);
    try writer.writeAll(" --device emulator-5554 --trace-dir ");
    try writeJoinedPathShellArgJsonContent(writer, dir, "traces/zmr-android");
    try writer.writeAll(" --ensure-device");
    try writer.writeAll("\",\"zmr run ");
    try writeJoinedPathShellArgJsonContent(writer, dir, scaffold.app_ios_smoke_file);
    try writer.writeAll(" --platform ios --device booted --trace-dir ");
    try writeJoinedPathShellArgJsonContent(writer, dir, "traces/zmr-ios");
    try writer.writeAll(" --ensure-device");
    try writer.writeAll("\"]");
}

pub fn writeInitScenarioJson(writer: anytype, path: []const u8, app_id: []const u8) !void {
    try writer.writeAll("{\"ok\":true,\"mode\":\"scenario\",\"appId\":");
    try trace.writeJsonString(writer, app_id);
    try writer.writeAll(",\"created\":[");
    try trace.writeJsonString(writer, path);
    try writer.writeAll("],\"next\":\"zmr validate ");
    try writeShellArgJsonContent(writer, path);
    try writer.writeAll("\"");
    try writeScenarioNextCommandsJson(writer, path);
    try writer.writeAll("}\n");
}

fn writeScenarioNextCommandsJson(writer: anytype, path: []const u8) !void {
    try writer.writeAll(",\"nextCommands\":[\"zmr validate --json ");
    try writeShellArgJsonContent(writer, path);
    try writer.writeAll("\",\"zmr run ");
    try writeShellArgJsonContent(writer, path);
    try writer.writeAll(" --json --trace-dir traces/zmr-run\"]");
}

pub fn writeRunSummaryJson(
    allocator: std.mem.Allocator,
    writer: anytype,
    trace_dir: ?[]const u8,
    fallback_scenario: []const u8,
    fallback_app_id: []const u8,
    run_error: ?anyerror,
    discovery: RunDiscovery,
) !void {
    if (trace_dir) |dir| {
        if (trace_summary.read(allocator, dir)) |summary_value| {
            var summary = summary_value;
            defer summary.deinit(allocator);
            return try writeRunSummaryFromTraceSummary(writer, dir, summary, run_error, discovery);
        } else |_| {}
    }

    const ok = run_error == null;
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (ok) "true" else "false");
    try writer.writeAll(",\"status\":");
    try trace.writeJsonString(writer, if (ok) "passed" else "failed");
    try writer.writeAll(",\"scenario\":");
    try trace.writeJsonString(writer, fallback_scenario);
    try writer.writeAll(",\"appId\":");
    try trace.writeJsonString(writer, fallback_app_id);
    if (run_error) |err| {
        try writer.writeAll(",\"error\":");
        try trace.writeJsonString(writer, @errorName(err));
    }
    try writeRunDiscoveryJson(writer, discovery);
    try writer.writeAll("}\n");
}

pub fn writeDoctorText(writer: anytype, config_check: ?doctor.Check, checks: []const doctor.Check) !void {
    const healthy = doctorChecksHealthy(config_check, checks);
    if (config_check) |check| {
        try writer.print("{s}\t{s}\t{s}\n", .{ check.name, @tagName(check.status), check.detail });
        if (check.hint) |hint| {
            try writer.print("{s}-hint\t{s}\n", .{ check.name, hint });
        }
    }
    for (checks) |check| {
        try writer.print("{s}\t{s}\t{s}\n", .{ check.name, @tagName(check.status), check.detail });
        if (check.hint) |hint| {
            try writer.print("{s}-hint\t{s}\n", .{ check.name, hint });
        }
    }
    try writer.print("status\t{s}\n", .{if (healthy) "ok" else "needs-attention"});

    // install.sh points at `zmr init`, and `zmr init` points at `zmr doctor`.
    // Without a next command here the onboarding chain dead-ends on a status line,
    // before the user has run a single scenario. Name the platform that actually
    // has a device ready rather than making them work it out from the table.
    const ios_ready = doctorCheckStatus(checks, "ios-simulators") == .ok;
    const android_ready = doctorCheckStatus(checks, "android-devices") == .ok;
    if (ios_ready) {
        try writer.writeAll("next\tzmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios --ensure-device\n");
    } else if (android_ready) {
        try writer.writeAll("next\tzmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --ensure-device\n");
    } else {
        try writer.writeAll("next\tStart an iOS simulator or an Android emulator, then run zmr doctor again.\n");
    }
}

fn doctorCheckStatus(checks: []const doctor.Check, name: []const u8) ?doctor.Status {
    for (checks) |check| {
        if (std.mem.eql(u8, check.name, name)) return check.status;
    }
    return null;
}

pub fn writeDoctorJson(writer: anytype, config_check: ?doctor.Check, checks: []const doctor.Check) !void {
    const healthy = doctorChecksHealthy(config_check, checks);
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (healthy) "true" else "false");
    try writer.writeAll(",\"checks\":[");
    var index: usize = 0;
    if (config_check) |check| {
        try writeDoctorCheckJson(writer, check);
        index += 1;
    }
    for (checks) |check| {
        if (index > 0) try writer.writeAll(",");
        try writeDoctorCheckJson(writer, check);
        index += 1;
    }
    try writer.writeAll("]}\n");
}

pub fn doctorChecksHealthy(config_check: ?doctor.Check, checks: []const doctor.Check) bool {
    var healthy = true;
    if (config_check) |check| {
        if (check.status != .ok) healthy = false;
    }
    for (checks) |check| {
        if (check.status != .ok) healthy = false;
    }
    return healthy;
}

pub fn writeValidationText(writer: anytype, path: []const u8, result: validation.Result) !void {
    if (result.ok) {
        try writer.print("{s}: ok ({s}, {d} steps)\n", .{ path, result.name.?, result.step_count });
    } else {
        try writer.print("{s}: invalid [{s}] {s}", .{ path, result.error_code.?, result.message.? });
        if (result.path) |field_path| {
            try writer.print(" at {s}", .{field_path});
        }
        if (result.line) |line| {
            try writer.print(" line {d}", .{line});
            if (result.column) |column| try writer.print(" column {d}", .{column});
        }
        try writer.writeAll("\n");
    }
}

pub fn writeValidationJson(writer: anytype, path: []const u8, result: validation.Result) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (result.ok) "true" else "false");
    try writer.writeAll(",\"path\":");
    try trace.writeJsonString(writer, path);
    if (result.ok) {
        try writer.writeAll(",\"name\":");
        try trace.writeJsonString(writer, result.name.?);
        if (result.app_id) |app_id| {
            try writer.writeAll(",\"appId\":");
            try trace.writeJsonString(writer, app_id);
        }
        try writer.print(",\"stepCount\":{d}", .{result.step_count});
        try writeValidationNextCommandsJson(writer, path);
    } else {
        try writer.writeAll(",\"errorCode\":");
        try trace.writeJsonString(writer, result.error_code.?);
        try writer.writeAll(",\"message\":");
        try trace.writeJsonString(writer, result.message.?);
        if (result.path) |field_path| {
            try writer.writeAll(",\"fieldPath\":");
            try trace.writeJsonString(writer, field_path);
        }
        if (result.line) |line| try writer.print(",\"line\":{d}", .{line});
        if (result.column) |column| try writer.print(",\"column\":{d}", .{column});
    }
    try writer.writeAll("}\n");
}

fn writeValidationNextCommandsJson(writer: anytype, path: []const u8) !void {
    try writer.writeAll(",\"nextCommands\":[\"zmr run ");
    try writeShellArgJsonContent(writer, path);
    try writer.writeAll(" --json --trace-dir traces/zmr-run\"]");
}

fn writeRunSummaryFromTraceSummary(
    writer: anytype,
    trace_dir: []const u8,
    summary: trace_summary.Summary,
    run_error: ?anyerror,
    discovery: RunDiscovery,
) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (std.mem.eql(u8, summary.status, "passed")) "true" else "false");
    try writer.writeAll(",\"status\":");
    try trace.writeJsonString(writer, summary.status);
    try writer.writeAll(",\"scenario\":");
    try trace.writeJsonString(writer, summary.scenario_name);
    if (summary.app_id) |value| {
        try writer.writeAll(",\"appId\":");
        try trace.writeJsonString(writer, value);
    }
    try writer.writeAll(",\"traceDir\":");
    try trace.writeJsonString(writer, trace_dir);
    try writer.writeAll(",\"eventsPath\":");
    try trace.writeJsonString(writer, summary.events_path);
    try writer.writeAll(",\"artifactsDir\":");
    try trace.writeJsonString(writer, summary.artifacts_dir);
    if (summary.duration_ms) |value| try writer.print(",\"durationMs\":{d}", .{value});
    if (summary.event_count) |value| try writer.print(",\"eventCount\":{d}", .{value});
    if (summary.snapshot_count) |value| try writer.print(",\"snapshotCount\":{d}", .{value});
    if (summary.partial_failure_count) |value| try writer.print(",\"partialFailureCount\":{d}", .{value});
    if (summary.failed_step_index) |value| try writer.print(",\"failedStepIndex\":{d}", .{value});
    if (summary.error_name) |value| {
        try writer.writeAll(",\"error\":");
        try trace.writeJsonString(writer, value);
    } else if (run_error) |err| {
        try writer.writeAll(",\"error\":");
        try trace.writeJsonString(writer, @errorName(err));
    }
    if (summary.partial_failure) |partial| {
        try writer.writeAll(",\"partialFailure\":");
        try trace_summary.writePartialFailureJson(writer, partial);
    }
    if (summary.report_path) |value| {
        try writer.writeAll(",\"reportPath\":");
        try trace.writeJsonString(writer, value);
    }
    try writeRunDiscoveryJson(writer, discovery);
    try writeRunNextCommandsJson(writer, trace_dir);
    try writer.writeAll("}\n");
}

fn writeRunDiscoveryJson(writer: anytype, discovery: RunDiscovery) !void {
    if (discovery.json) |json| {
        try writer.writeAll(",\"discovery\":");
        try writer.writeAll(json);
    }
    if (discovery.error_name) |error_name| {
        try writer.writeAll(",\"discoveryError\":");
        try trace.writeJsonString(writer, error_name);
    }
}

fn writeRunNextCommandsJson(writer: anytype, trace_dir: []const u8) !void {
    try writer.writeAll(",\"nextCommands\":[\"zmr report ");
    try writeShellArgJsonContent(writer, trace_dir);
    try writer.writeAll(" --out ");
    try writeJoinedPathShellArgJsonContent(writer, trace_dir, "report.html");
    try writer.writeAll(" --junit ");
    try writeJoinedPathShellArgJsonContent(writer, trace_dir, "junit.xml");
    try writer.writeAll("\",\"zmr explain ");
    try writeShellArgJsonContent(writer, trace_dir);
    try writer.writeAll(" --json\",\"zmr discover --from-trace ");
    try writeShellArgJsonContent(writer, trace_dir);
    try writer.writeAll(" --out .zmr/discovered/replay-smoke.json --include-actions --validate --force --json\",\"zmr export ");
    try writeShellArgJsonContent(writer, trace_dir);
    try writer.writeAll(" --out ");
    try writePathWithSuffixShellArgJsonContent(writer, trace_dir, ".zmrtrace");
    try writer.writeAll(" --redact\"]");
}

fn writeDoctorCheckJson(writer: anytype, check: doctor.Check) !void {
    try writer.writeAll("{\"name\":");
    try trace.writeJsonString(writer, check.name);
    try writer.writeAll(",\"status\":");
    try trace.writeJsonString(writer, @tagName(check.status));
    if (check.error_code) |error_code| {
        try writer.writeAll(",\"errorCode\":");
        try trace.writeJsonString(writer, error_code);
    }
    try writer.writeAll(",\"detail\":");
    try trace.writeJsonString(writer, check.detail);
    if (check.count) |count| try writer.print(",\"count\":{d}", .{count});
    if (check.ready_count) |ready_count| try writer.print(",\"readyCount\":{d}", .{ready_count});
    if (check.script_count) |script_count| try writer.print(",\"scriptCount\":{d}", .{script_count});
    if (check.script_names) |script_names| {
        try writer.writeAll(",\"scriptNames\":[");
        for (script_names, 0..) |script_name, index| {
            if (index > 0) try writer.writeAll(",");
            try trace.writeJsonString(writer, script_name);
        }
        try writer.writeAll("]");
    }
    if (check.hint) |hint| {
        try writer.writeAll(",\"hint\":");
        try trace.writeJsonString(writer, hint);
    }
    if (check.field_path) |field_path| {
        try writer.writeAll(",\"fieldPath\":");
        try trace.writeJsonString(writer, field_path);
    }
    try writer.writeAll("}");
}

fn writeJoinedPathJson(writer: anytype, root: []const u8, child: []const u8) !void {
    try writer.writeAll("\"");
    try writeJoinedPathJsonContent(writer, root, child);
    try writer.writeAll("\"");
}

fn writeJoinedPathJsonContent(writer: anytype, root: []const u8, child: []const u8) !void {
    try writeJsonStringContent(writer, root);
    if (root.len > 0 and !std.mem.endsWith(u8, root, "/")) try writer.writeAll("/");
    try writeJsonStringContent(writer, child);
}

pub fn writeJoinedPathShellArgJsonContent(writer: anytype, root: []const u8, child: []const u8) !void {
    if (isShellSafe(root) and isShellSafe(child)) {
        try writeJoinedPathJsonContent(writer, root, child);
        return;
    }

    try writer.writeAll("'");
    try writeShellQuotedJsonContent(writer, root);
    if (root.len > 0 and !std.mem.endsWith(u8, root, "/")) try writer.writeAll("/");
    try writeShellQuotedJsonContent(writer, child);
    try writer.writeAll("'");
}

pub fn writeShellArgJsonContent(writer: anytype, value: []const u8) !void {
    if (isShellSafe(value)) {
        try writeJsonStringContent(writer, value);
        return;
    }

    try writer.writeAll("'");
    try writeShellQuotedJsonContent(writer, value);
    try writer.writeAll("'");
}

pub fn writePathWithSuffixShellArgJsonContent(writer: anytype, value: []const u8, suffix: []const u8) !void {
    if (isShellSafe(value) and isShellSafe(suffix)) {
        try writeJsonStringContent(writer, value);
        try writeJsonStringContent(writer, suffix);
        return;
    }

    try writer.writeAll("'");
    try writeShellQuotedJsonContent(writer, value);
    try writeShellQuotedJsonContent(writer, suffix);
    try writer.writeAll("'");
}

pub fn writeJoinedPathShellArg(writer: anytype, root: []const u8, child: []const u8) !void {
    if (isShellSafe(root) and isShellSafe(child)) {
        try writer.writeAll(root);
        if (root.len > 0 and !std.mem.endsWith(u8, root, "/")) try writer.writeAll("/");
        try writer.writeAll(child);
        return;
    }

    try writer.writeAll("'");
    try writeShellQuotedText(writer, root);
    if (root.len > 0 and !std.mem.endsWith(u8, root, "/")) try writer.writeAll("/");
    try writeShellQuotedText(writer, child);
    try writer.writeAll("'");
}

pub fn writeShellArg(writer: anytype, value: []const u8) !void {
    if (isShellSafe(value)) {
        try writer.writeAll(value);
        return;
    }

    try writer.writeAll("'");
    try writeShellQuotedText(writer, value);
    try writer.writeAll("'");
}

fn writeShellQuotedJsonContent(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        if (ch == '\'') {
            try writeJsonStringContent(writer, "'\\''");
        } else {
            try writeJsonStringContent(writer, &.{ch});
        }
    }
}

fn writeShellQuotedText(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        if (ch == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeAll(&.{ch});
        }
    }
}

fn isShellSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '/', ':', '=', '@', '%', '+', ',', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn writeJsonStringContent(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...7, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeAll(&.{ch}),
        }
    }
}
