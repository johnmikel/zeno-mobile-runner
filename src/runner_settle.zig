//! Waiting for the screen to stop moving after an action.
//!
//! The obvious implementation is a fixed sleep, and it is wrong in both
//! directions at once: it pays the full cost when the UI settled in 50ms, and
//! it gives up early when the UI needed longer. Neither is visible from the
//! outside — the run is just slower than it needs to be, and flaky when it
//! isn't.
//!
//! Instead, poll the hierarchy and stop as soon as two consecutive reads are
//! identical. That is adaptive by construction: a static screen costs one extra
//! read, and a slow screen gets the time it actually needs, up to a bound.
//!
//! Two properties are load-bearing:
//!
//!   * It NEVER fails a run. A clock, a spinner, or a progress bar means
//!     "settled" is unreachable, so the wait is bounded and then simply
//!     returns. Bounding the wait matters more than perfecting the predicate.
//!     Only the lookup that follows is allowed to fail, and it produces a far
//!     better message than a settle timeout ever could.
//!   * The fingerprint ignores snapshot identity and timing. Those differ on
//!     every read from a real device, so including them would mean nothing ever
//!     looked settled.

const std = @import("std");
const stdio = @import("stdio.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

pub const Options = struct {
    settle_timeout_ms: u64 = 2000,
    settle_poll_ms: u64 = 100,
};

pub const Result = struct {
    converged: bool,
    polls: usize,
    elapsed_ms: u64,
};

/// Stable identity of what a user could see. Deliberately excludes the
/// snapshot id and timestamp, which change on every read.
pub fn fingerprint(snapshot: types.ObservationSnapshot) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, snapshot.nodes.len);
    for (snapshot.nodes) |node| {
        hasher.update(node.stable_id);
        hasher.update(node.class_name);
        if (node.text) |value| hasher.update(value);
        hasher.update("\x00");
        if (node.content_desc) |value| hasher.update(value);
        hasher.update("\x00");
        if (node.resource_id) |value| hasher.update(value);
        hasher.update("\x00");
        std.hash.autoHash(&hasher, node.bounds.x);
        std.hash.autoHash(&hasher, node.bounds.y);
        std.hash.autoHash(&hasher, node.bounds.width);
        std.hash.autoHash(&hasher, node.bounds.height);
        std.hash.autoHash(&hasher, node.enabled);
        std.hash.autoHash(&hasher, node.visible);
        std.hash.autoHash(&hasher, node.checked);
        std.hash.autoHash(&hasher, node.focused);
        std.hash.autoHash(&hasher, node.selected);
    }
    return hasher.final();
}

/// Poll until the hierarchy repeats, or the budget runs out. Never fails.
pub fn waitForQuiet(
    allocator: std.mem.Allocator,
    device: anytype,
    writer: ?*trace.TraceWriter,
    options: Options,
) Result {
    _ = allocator;
    const started_ms = stdio.nowMs();
    const deadline_ms = started_ms + @as(i64, @intCast(options.settle_timeout_ms));

    var previous: ?u64 = null;
    var polls: usize = 0;

    while (true) {
        var snap = device.snapshot(writer) catch {
            // A failed read is not a failed run. Hand control back and let the
            // next real operation report a cause worth acting on.
            return finish(writer, false, polls, started_ms);
        };
        defer snap.deinit(device.allocator);
        polls += 1;

        const current = fingerprint(snap);
        if (previous) |value| {
            if (value == current) return finish(writer, true, polls, started_ms);
        }
        previous = current;

        if (stdio.nowMs() >= deadline_ms) return finish(writer, false, polls, started_ms);
        if (options.settle_poll_ms > 0) {
            stdio.sleepNs(options.settle_poll_ms * std.time.ns_per_ms);
        }
    }
}

fn finish(writer: ?*trace.TraceWriter, converged: bool, polls: usize, started_ms: i64) Result {
    const elapsed: u64 = @intCast(@max(0, stdio.nowMs() - started_ms));
    if (writer) |tw| {
        var payload: std.Io.Writer.Allocating = .init(tw.allocator);
        defer payload.deinit();
        payload.writer.print(
            "{{\"converged\":{},\"polls\":{d},\"durationMs\":{d}}}",
            .{ converged, polls, elapsed },
        ) catch return .{ .converged = converged, .polls = polls, .elapsed_ms = elapsed };
        tw.recordEvent("runner.settle", payload.writer.buffered()) catch {};
    }
    return .{ .converged = converged, .polls = polls, .elapsed_ms = elapsed };
}
