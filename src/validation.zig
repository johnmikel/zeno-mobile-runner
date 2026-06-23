const std = @import("std");
const stdio = @import("stdio.zig");
const errors = @import("errors.zig");
const scenario = @import("scenario.zig");

pub const Result = struct {
    ok: bool,
    name: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    step_count: usize = 0,
    error_code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    path: ?[]const u8 = null,
    line: ?usize = null,
    column: ?usize = null,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.app_id) |value| allocator.free(value);
        if (self.error_code) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
    }
};

pub fn validateFile(allocator: std.mem.Allocator, path: []const u8) !Result {
    const content = stdio.readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| return failure(allocator, null, err);
    defer allocator.free(content);
    const script = scenario.parseSlice(allocator, content) catch |err| return failure(allocator, content, err);
    defer script.deinit(allocator);
    return success(allocator, script);
}

pub fn validateSlice(allocator: std.mem.Allocator, content: []const u8) !Result {
    const script = scenario.parseSlice(allocator, content) catch |err| return failure(allocator, content, err);
    defer script.deinit(allocator);
    return success(allocator, script);
}

fn success(allocator: std.mem.Allocator, script: scenario.Scenario) !Result {
    return .{
        .ok = true,
        .name = try allocator.dupe(u8, script.name),
        .app_id = try dupeOptionalString(allocator, script.app_id),
        .step_count = script.steps.len,
    };
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |actual| return try allocator.dupe(u8, actual);
    return null;
}

fn failure(allocator: std.mem.Allocator, content: ?[]const u8, err: anyerror) !Result {
    const classified = errors.classify(err);
    const diagnostic = if (content) |actual| try diagnoseFailure(allocator, actual, err) else Diagnostic{};
    errdefer diagnostic.deinit(allocator);
    const code = if (diagnostic.line != null and diagnostic.path == null and std.mem.eql(u8, classified.code, "internal.error"))
        "scenario.invalid"
    else
        classified.code;
    const message = if (diagnostic.line != null and diagnostic.path == null and std.mem.eql(u8, classified.code, "internal.error"))
        "malformed scenario json"
    else
        classified.message;
    return .{
        .ok = false,
        .error_code = try allocator.dupe(u8, code),
        .message = try allocator.dupe(u8, message),
        .path = diagnostic.path,
        .line = diagnostic.line,
        .column = diagnostic.column,
    };
}

const Diagnostic = struct {
    path: ?[]const u8 = null,
    line: ?usize = null,
    column: ?usize = null,

    fn deinit(self: Diagnostic, allocator: std.mem.Allocator) void {
        if (self.path) |value| allocator.free(value);
    }
};

fn diagnoseFailure(allocator: std.mem.Allocator, content: []const u8, err: anyerror) !Diagnostic {
    if (syntaxLocation(allocator, content)) |location| return location;
    return switch (err) {
        error.ScenarioMustBeObject => try pathDiagnostic(allocator, content, "$", null),
        error.ScenarioMissingSteps,
        error.ScenarioStepsMustBeArray,
        => try pathDiagnostic(allocator, content, "$.steps", "steps"),
        error.StepMissingAction,
        error.StepActionMustBeString,
        error.unknownAction,
        error.unknownScenarioAction,
        => try pathDiagnostic(allocator, content, "$.steps[].action", "action"),
        error.unknownScrollDirection,
        => try pathDiagnostic(allocator, content, "$.steps[].direction", "direction"),
        error.StepMissingUrl,
        => try pathDiagnostic(allocator, content, "$.steps[].url", "url"),
        error.StepMissingText,
        => try pathDiagnostic(allocator, content, "$.steps[].text", "text"),
        error.StepMissingX1,
        => try pathDiagnostic(allocator, content, "$.steps[].x1", "x1"),
        error.StepMissingY1,
        => try pathDiagnostic(allocator, content, "$.steps[].y1", "y1"),
        error.StepMissingX2,
        => try pathDiagnostic(allocator, content, "$.steps[].x2", "x2"),
        error.StepMissingY2,
        => try pathDiagnostic(allocator, content, "$.steps[].y2", "y2"),
        error.StepMissingLatitude,
        error.StepLatitudeMustBeNumber,
        error.StepLatitudeOutOfRange,
        => try pathDiagnostic(allocator, content, "$.steps[].latitude", "latitude"),
        error.StepMissingLongitude,
        error.StepLongitudeMustBeNumber,
        error.StepLongitudeOutOfRange,
        => try pathDiagnostic(allocator, content, "$.steps[].longitude", "longitude"),
        error.MissingSelector,
        error.StepMissingSelector,
        error.SelectorMustNotBeEmpty,
        => try pathDiagnostic(allocator, content, "$.steps[].selector", "selector"),
        error.MissingSelectors,
        error.StepMissingSelectors,
        error.SelectorsMustBeArray,
        error.SelectorsMustNotBeEmpty,
        => try pathDiagnostic(allocator, content, "$.steps[].selectors", "selectors"),
        else => .{},
    };
}

fn syntaxLocation(allocator: std.mem.Allocator, content: []const u8) ?Diagnostic {
    var scanner = std.json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);
    const parsed = std.json.parseFromTokenSource(std.json.Value, allocator, &scanner, .{}) catch {
        return .{
            .line = @as(usize, @intCast(diagnostics.getLine())),
            .column = @as(usize, @intCast(diagnostics.getColumn())),
        };
    };
    parsed.deinit();
    return null;
}

fn pathDiagnostic(allocator: std.mem.Allocator, content: []const u8, path: []const u8, key: ?[]const u8) !Diagnostic {
    var diagnostic = Diagnostic{ .path = try allocator.dupe(u8, path) };
    if (key) |actual| {
        if (findJsonKeyOffset(allocator, content, actual)) |offset| {
            const location = lineColumnForOffset(content, offset);
            diagnostic.line = location.line;
            diagnostic.column = location.column;
        }
    } else {
        const offset = firstNonWhitespaceOffset(content) orelse 0;
        const location = lineColumnForOffset(content, offset);
        diagnostic.line = location.line;
        diagnostic.column = location.column;
    }
    return diagnostic;
}

fn findJsonKeyOffset(allocator: std.mem.Allocator, content: []const u8, key: []const u8) ?usize {
    const needle = std.fmt.allocPrint(allocator, "\"{s}\"", .{key}) catch return null;
    defer allocator.free(needle);
    return std.mem.indexOf(u8, content, needle);
}

fn firstNonWhitespaceOffset(content: []const u8) ?usize {
    for (content, 0..) |byte, index| switch (byte) {
        ' ', '\t', '\r', '\n' => {},
        else => return index,
    };
    return null;
}

const SourceLocation = struct {
    line: usize,
    column: usize,
};

fn lineColumnForOffset(content: []const u8, offset: usize) SourceLocation {
    var line: usize = 1;
    var column: usize = 1;
    for (content[0..@min(offset, content.len)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}
