//! Wait budgets measured from when the UI last had a *reason* to change.
//!
//! A wait normally starts its clock when the wait starts. But if a scenario
//! tapped a button, then spent four seconds taking snapshots and asserting
//! things, the screen has already had four quiet seconds to produce whatever
//! the next wait is looking for. Giving that wait a further full budget mostly
//! buys time for something that was never coming, and it lets total scenario
//! time compound in a way nobody predicted from reading the steps.
//!
//! So: every action that actually changes device state stamps the anchor, and
//! waits spend `timeout - (now - last_mutation)` instead of the full timeout.
//!
//! The obvious danger is that this *shortens* waits, and a shortened wait can
//! turn a passing scenario into a failing one. Two things bound that:
//!
//!   * A floor. A budget is never reduced below `wait_floor_ms`, so a wait
//!     always gets a real chance no matter how long ago the last interaction
//!     was. Trading a scenario's correctness for tighter timing is a bad deal.
//!   * Visibility. Whenever a budget is actually shortened, the trace records
//!     it, so a wait that failed early is diagnosable from the evidence rather
//!     than mysterious.

const std = @import("std");
const stdio = @import("stdio.zig");
const trace = @import("trace.zig");

pub const Anchor = struct {
    /// When the device was last given a reason to change what it is showing.
    last_mutation_ms: i64,

    pub fn init() Anchor {
        return .{ .last_mutation_ms = stdio.nowMs() };
    }

    pub fn at(timestamp_ms: i64) Anchor {
        return .{ .last_mutation_ms = timestamp_ms };
    }

    /// Called by actions that change device state. Non-mutating work —
    /// snapshots, assertions, waits — deliberately does not stamp it.
    pub fn touch(self: *Anchor) void {
        self.last_mutation_ms = stdio.nowMs();
    }

    pub fn quietMs(self: Anchor) u64 {
        return @intCast(@max(0, stdio.nowMs() - self.last_mutation_ms));
    }
};

pub const Budget = struct {
    timeout_ms: u64,
    /// True when the anchor actually reduced the budget, which is the only
    /// case worth reporting.
    shortened: bool,
    quiet_ms: u64,
};

/// The budget a wait should actually spend.
pub fn budgetFor(anchor: ?*const Anchor, timeout_ms: u64, floor_ms: u64) Budget {
    const value = anchor orelse return .{ .timeout_ms = timeout_ms, .shortened = false, .quiet_ms = 0 };
    const quiet = value.quietMs();
    if (quiet == 0) return .{ .timeout_ms = timeout_ms, .shortened = false, .quiet_ms = 0 };

    const remaining = if (quiet >= timeout_ms) 0 else timeout_ms - quiet;
    // Never trade the scenario's correctness for tighter timing: a wait always
    // gets at least the floor, however long the screen has been quiet.
    const floored = @max(remaining, @min(floor_ms, timeout_ms));
    return .{
        .timeout_ms = floored,
        .shortened = floored < timeout_ms,
        .quiet_ms = quiet,
    };
}

/// Record a shortened budget so an early wait failure can be explained from
/// the trace instead of looking arbitrary.
pub fn recordBudget(writer: ?*trace.TraceWriter, kind: []const u8, requested_ms: u64, budget: Budget) !void {
    if (!budget.shortened) return;
    const tw = writer orelse return;
    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
    defer payload.deinit();
    try payload.writer.print(
        "{{\"kind\":\"{s}\",\"requestedTimeoutMs\":{d},\"effectiveTimeoutMs\":{d},\"quietMs\":{d}}}",
        .{ kind, requested_ms, budget.timeout_ms, budget.quiet_ms },
    );
    try tw.recordEvent("runner.waitBudget", payload.writer.buffered());
}
