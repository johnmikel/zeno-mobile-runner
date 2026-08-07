const std = @import("std");
const session = @import("session.zig");
const stdio = @import("stdio.zig");

pub const max_workers: u32 = 64;
pub const max_retries: u32 = 100;

pub const ShardMode = enum {
    none,
    all,
    split,
};

pub const SchedulerOptions = struct {
    workers: u32 = 1,
    shard_mode: ShardMode = .none,
    retries: u32 = 0,
    output_dir: []const u8 = "artifacts",
};

pub const ScenarioInput = struct {
    path: []const u8,
    digest: []const u8,
};

pub const PlanItem = struct {
    scenario: ScenarioInput,
    worker_index: u32,
    shard_index: u32,
    attempt_limit: u32,
};

pub const Plan = struct {
    items: []PlanItem,
    workers: u32,
    shard_mode: ShardMode,
    retries: u32,
    output_dir: []const u8,

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    scenarios: []const ScenarioInput,
    options: SchedulerOptions,
) !Plan {
    if (options.workers == 0 or options.workers > max_workers) return error.WorkerCountOutOfRange;
    if (options.retries > max_retries) return error.RetryCountOutOfRange;

    var items = std.ArrayList(PlanItem).empty;
    errdefer items.deinit(allocator);
    const copies_per_scenario: u32 = if (options.shard_mode == .all) options.workers else 1;
    for (scenarios, 0..) |scenario, scenario_index| {
        var copy_index: u32 = 0;
        while (copy_index < copies_per_scenario) : (copy_index += 1) {
            const worker_index = switch (options.shard_mode) {
                .none => 0,
                .split => @as(u32, @intCast(scenario_index % options.workers)),
                .all => copy_index,
            };
            try items.append(allocator, .{
                .scenario = scenario,
                .worker_index = worker_index,
                .shard_index = worker_index,
                .attempt_limit = options.retries + 1,
            });
        }
    }

    return .{
        .items = try items.toOwnedSlice(allocator),
        .workers = options.workers,
        .shard_mode = options.shard_mode,
        .retries = options.retries,
        .output_dir = options.output_dir,
    };
}

pub const Lease = struct {
    pool: *LeasePool,
    index: usize,
    serial: []const u8,
};

const LeaseSlot = struct {
    serial: []const u8,
    leased: bool = false,
};

pub const LeasePool = struct {
    allocator: std.mem.Allocator,
    slots: []LeaseSlot,

    pub fn init(allocator: std.mem.Allocator, devices: []const []const u8) !LeasePool {
        const slots = try allocator.alloc(LeaseSlot, devices.len);
        errdefer allocator.free(slots);
        var written: usize = 0;
        errdefer {
            for (slots[0..written]) |slot| allocator.free(slot.serial);
        }
        for (devices) |serial| {
            slots[written] = .{ .serial = try allocator.dupe(u8, serial) };
            written += 1;
        }
        return .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *LeasePool) void {
        for (self.slots) |slot| self.allocator.free(slot.serial);
        self.allocator.free(self.slots);
    }

    pub fn acquire(self: *LeasePool) ?Lease {
        for (self.slots, 0..) |*slot, index| {
            if (slot.leased) continue;
            slot.leased = true;
            return .{ .pool = self, .index = index, .serial = slot.serial };
        }
        return null;
    }

    pub fn release(self: *LeasePool, lease: Lease) void {
        if (lease.pool != self or lease.index >= self.slots.len) return;
        self.slots[lease.index].leased = false;
    }
};

pub fn shouldRetry(failure_class: session.FailureClass, retry_index: u32, retries: u32) bool {
    return session.shouldRetry(failure_class, retry_index, retries);
}

pub fn discoverScenarioPaths(allocator: std.mem.Allocator, workspace: []const u8) ![][]const u8 {
    var root = try std.Io.Dir.cwd().openDir(stdio.io(), workspace, .{ .iterate = true });
    defer root.close(stdio.io());

    var paths = std.ArrayList([]const u8).empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try collectScenarioPaths(allocator, workspace, &root, "", &paths);
    std.sort.heap([]const u8, paths.items, {}, lessPath);
    return try paths.toOwnedSlice(allocator);
}

pub fn freeScenarioPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn collectScenarioPaths(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    dir: *std.Io.Dir,
    relative: []const u8,
    paths: *std.ArrayList([]const u8),
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(stdio.io())) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (entry.kind == .directory and isIgnoredDirectory(entry.name)) continue;

        const child_relative = if (relative.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative, entry.name });
        defer allocator.free(child_relative);

        switch (entry.kind) {
            .file => {
                if (isScenarioPath(child_relative)) {
                    const full_path = try std.fs.path.join(allocator, &.{ workspace, child_relative });
                    paths.append(allocator, full_path) catch |err| {
                        allocator.free(full_path);
                        return err;
                    };
                }
            },
            .directory => {
                var child = try dir.openDir(stdio.io(), entry.name, .{ .iterate = true });
                defer child.close(stdio.io());
                try collectScenarioPaths(allocator, workspace, &child, child_relative, paths);
            },
            else => {},
        }
    }
}

fn isIgnoredDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "build") or
        std.mem.eql(u8, name, "dist");
}

fn isScenarioPath(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, basename, ".json")) return false;
    if (std.mem.eql(u8, basename, "package.json") or
        std.mem.eql(u8, basename, "app.json") or
        std.mem.eql(u8, basename, "tsconfig.json") or
        std.mem.eql(u8, basename, "config.json")) return false;
    if (std.mem.eql(u8, basename, "scenario.json") or std.mem.endsWith(u8, basename, ".scenario.json")) return true;
    return isUnderDirectory(path, "examples") or
        isUnderDirectory(path, "scenarios") or
        isUnderDirectory(path, "flows");
}

fn isUnderDirectory(path: []const u8, directory: []const u8) bool {
    if (path.len > directory.len and std.mem.startsWith(u8, path, directory) and path[directory.len] == '/') return true;
    var index = std.mem.indexOfScalar(u8, path, '/');
    while (index) |slash| {
        const start = slash + 1;
        if (start + directory.len < path.len and
            std.mem.startsWith(u8, path[start..], directory) and
            path[start + directory.len] == '/') return true;
        index = if (start < path.len) std.mem.indexOfScalarPos(u8, path, start, '/') else null;
    }
    return false;
}

fn lessPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
