const runner_anchor = @import("runner_anchor.zig");

pub const RunOptions = struct {
    /// Upper bound on a native/device-side settle, and the fixed wait used when
    /// `adaptive_settle` is off.
    settle_ms: u64 = 500,
    poll_ms: u64 = 500,
    default_timeout_ms: u64 = 5000,
    action_timeout_ms: u64 = 5000,

    /// Wait for the hierarchy to stop changing after an action instead of
    /// sleeping a fixed amount. A fixed sleep is wrong in both directions: it
    /// pays in full when the screen settled immediately, and gives up early
    /// when the screen needed longer. See src/runner_settle.zig.
    ///
    /// Off by default, deliberately. Settling this way costs at least one extra
    /// hierarchy read per action, and on a real device a read is a full
    /// `uiautomator dump` or XCTest snapshot — not free. Whether it is a net
    /// win depends on how that read compares to `settle_ms` on real hardware,
    /// and that has not been measured yet. Turning it on before measuring would
    /// risk the published determinism figures on a guess. The mechanism, its
    /// tests, and the config knob ship now; the default flips when a pilot run
    /// on a real device says it should.
    adaptive_settle: bool = false,
    /// Bound on adaptive settling. Reaching it is not a failure — the run
    /// continues and the next lookup reports anything genuinely wrong.
    settle_timeout_ms: u64 = 2000,
    settle_poll_ms: u64 = 100,

    /// Measures wait budgets from when the device last had a reason to change
    /// rather than from when the wait started. See src/runner_anchor.zig.
    /// Null means the previous behavior: every wait gets its full timeout.
    anchor: ?*runner_anchor.Anchor = null,
    /// A wait budget is never reduced below this, however long the screen has
    /// been quiet. Correctness beats tighter timing.
    wait_floor_ms: u64 = 1000,
};
