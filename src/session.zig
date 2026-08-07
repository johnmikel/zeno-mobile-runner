const std = @import("std");

pub const SessionState = enum {
    created,
    preflight,
    ready,
    running,
    cancelling,
    closed,
};

pub const AttemptStatus = enum {
    planned,
    running,
    passed,
    failed,
    cancelled,
    skipped,
};

pub const FailureClass = enum {
    none,
    infrastructure,
    assertion,
    application,
    timeout,
    cancellation,
    configuration,
    unknown,
};

pub const RunAttempt = struct {
    run_id: []const u8,
    attempt_id: u32,
    scenario_digest: []const u8,
    device: []const u8,
    status: AttemptStatus,
    failure_class: FailureClass,
    retry_reason: ?[]const u8,
    trace_path: []const u8,
    artifact_path: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        run_id: []const u8,
        attempt_id: u32,
        scenario_digest: []const u8,
        device: []const u8,
        trace_path: []const u8,
        artifact_path: []const u8,
    ) !RunAttempt {
        const owned_run_id = try allocator.dupe(u8, run_id);
        errdefer allocator.free(owned_run_id);
        const owned_digest = try allocator.dupe(u8, scenario_digest);
        errdefer allocator.free(owned_digest);
        const owned_device = try allocator.dupe(u8, device);
        errdefer allocator.free(owned_device);
        const owned_trace = try allocator.dupe(u8, trace_path);
        errdefer allocator.free(owned_trace);
        const owned_artifact = try allocator.dupe(u8, artifact_path);
        errdefer allocator.free(owned_artifact);

        return .{
            .run_id = owned_run_id,
            .attempt_id = attempt_id,
            .scenario_digest = owned_digest,
            .device = owned_device,
            .status = .running,
            .failure_class = .none,
            .retry_reason = null,
            .trace_path = owned_trace,
            .artifact_path = owned_artifact,
        };
    }

    pub fn deinit(self: RunAttempt, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.scenario_digest);
        allocator.free(self.device);
        if (self.retry_reason) |reason| allocator.free(reason);
        allocator.free(self.trace_path);
        allocator.free(self.artifact_path);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    run_id: []const u8,
    device: []const u8,
    output_dir: []const u8,
    state: SessionState = .created,
    attempts: std.ArrayList(RunAttempt) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        run_id: []const u8,
        device: []const u8,
        output_dir: []const u8,
    ) !Session {
        const owned_run_id = try allocator.dupe(u8, run_id);
        errdefer allocator.free(owned_run_id);
        const owned_device = try allocator.dupe(u8, device);
        errdefer allocator.free(owned_device);
        const owned_output = try allocator.dupe(u8, output_dir);
        errdefer allocator.free(owned_output);
        return .{
            .allocator = allocator,
            .run_id = owned_run_id,
            .device = owned_device,
            .output_dir = owned_output,
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.attempts.items) |attempt| attempt.deinit(self.allocator);
        self.attempts.deinit(self.allocator);
        self.allocator.free(self.run_id);
        self.allocator.free(self.device);
        self.allocator.free(self.output_dir);
    }

    pub fn transition(self: *Session, next: SessionState) !void {
        if (!validTransition(self.state, next)) return error.InvalidSessionTransition;
        self.state = next;
    }

    pub fn cancel(self: *Session) !void {
        try self.transition(.cancelling);
    }

    pub fn close(self: *Session) !void {
        try self.transition(.closed);
    }

    pub fn artifactPath(self: *const Session, allocator: std.mem.Allocator, scenario_name: []const u8, attempt_id: u32) ![]const u8 {
        const run_component = try safeComponent(allocator, self.run_id);
        defer allocator.free(run_component);
        const scenario_component = try safeComponent(allocator, scenario_name);
        defer allocator.free(scenario_component);
        const attempt_component = try std.fmt.allocPrint(allocator, "attempt-{d}", .{attempt_id});
        defer allocator.free(attempt_component);
        return try std.fs.path.join(allocator, &.{
            self.output_dir,
            "runs",
            run_component,
            attempt_component,
            scenario_component,
        });
    }

    pub fn startAttempt(
        self: *Session,
        scenario_digest: []const u8,
        attempt_id: u32,
        trace_path: []const u8,
        artifact_path: []const u8,
    ) !usize {
        if (self.state != .running) return error.SessionNotRunning;
        var attempt = try RunAttempt.init(
            self.allocator,
            self.run_id,
            attempt_id,
            scenario_digest,
            self.device,
            trace_path,
            artifact_path,
        );
        errdefer attempt.deinit(self.allocator);
        try self.attempts.append(self.allocator, attempt);
        return self.attempts.items.len - 1;
    }

    pub fn finishAttempt(
        self: *Session,
        attempt_index: usize,
        status: AttemptStatus,
        failure_class: FailureClass,
        retry_reason: ?[]const u8,
    ) !void {
        if (attempt_index >= self.attempts.items.len) return error.UnknownRunAttempt;
        if (status == .running or status == .planned) return error.AttemptMustBeTerminal;
        const copied_reason = if (retry_reason) |reason| try self.allocator.dupe(u8, reason) else null;
        const attempt = &self.attempts.items[attempt_index];
        if (attempt.retry_reason) |old_reason| self.allocator.free(old_reason);
        attempt.retry_reason = copied_reason;
        attempt.status = status;
        attempt.failure_class = failure_class;
    }
};

pub fn shouldRetry(failure_class: FailureClass, retry_index: u32, max_retries: u32) bool {
    return failure_class == .infrastructure and retry_index < max_retries;
}

fn validTransition(current: SessionState, next: SessionState) bool {
    return switch (current) {
        .created => next == .preflight or next == .cancelling or next == .closed,
        .preflight => next == .ready or next == .cancelling or next == .closed,
        .ready => next == .running or next == .cancelling or next == .closed,
        .running => next == .cancelling or next == .closed,
        .cancelling => next == .closed,
        .closed => false,
    };
}

fn safeComponent(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (value) |character| {
        const safe = (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9') or
            character == '_' or character == '-' or character == '.';
        try result.append(allocator, if (safe) character else '_');
    }
    if (result.items.len == 0) try result.append(allocator, '_');
    if (result.items[0] == '.') try result.insert(allocator, 0, '_');
    return try result.toOwnedSlice(allocator);
}
