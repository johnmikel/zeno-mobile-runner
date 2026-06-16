const std = @import("std");
const stdio = @import("stdio.zig");
const errors = @import("errors.zig");
const methods = @import("json_rpc_methods.zig");
const protocol = @import("json_rpc_protocol.zig");
const trace = @import("trace.zig");

const net = std.Io.net;

pub const ServeOptions = struct {
    transport: []const u8 = "stdio",
};

pub fn serveStdio(allocator: std.mem.Allocator, device: anytype) !void {
    try serveStdioWithTrace(allocator, device, null);
}

pub fn serveStdioWithTrace(allocator: std.mem.Allocator, device: anytype, live_trace: ?*trace.TraceWriter) !void {
    var stdin_io: stdio.Input = .{};
    stdin_io.init(.stdin());
    const stdin = stdin_io.reader();

    var stdout_io: stdio.Output = .{};
    stdout_io.init(.stdout());
    defer stdout_io.deinit();
    const stdout = stdout_io.writer();

    while (true) {
        const line = stdio.readLineAlloc(stdin, allocator, 16 * 1024 * 1024) catch |err| {
            try protocol.writeError(stdout, null, -32700, @errorName(err));
            try stdout_io.flush();
            continue;
        };
        const owned_line = line orelse break;
        defer allocator.free(owned_line);
        const trimmed = std.mem.trim(u8, owned_line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try dispatchLineWithTrace(allocator, device, trimmed, stdout, live_trace);
        try stdout_io.flush();
    }
}

pub fn serveTcp(allocator: std.mem.Allocator, device: anytype, port: u16) !void {
    try serveTcpWithTrace(allocator, device, port, null);
}

pub fn serveTcpWithTrace(allocator: std.mem.Allocator, device: anytype, port: u16, live_trace: ?*trace.TraceWriter) !void {
    const address = try net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(stdio.io(), .{ .reuse_address = true });
    defer server.deinit(stdio.io());

    while (true) {
        const connection = try server.accept(stdio.io());
        defer connection.close(stdio.io());
        try serveTcpConnection(allocator, device, connection, live_trace);
    }
}

fn serveTcpConnection(allocator: std.mem.Allocator, device: anytype, stream: net.Stream, live_trace: ?*trace.TraceWriter) !void {
    var write_buffer: [8192]u8 = undefined;
    var stream_writer = stream.writer(stdio.io(), &write_buffer);
    const writer = &stream_writer.interface;

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(stdio.io(), &read_buffer);
    while (true) {
        const line = stdio.readLineAlloc(&stream_reader.interface, allocator, 16 * 1024 * 1024) catch |err| {
            try protocol.writeError(writer, null, -32700, @errorName(err));
            try writer.flush();
            continue;
        };
        const owned_line = line orelse break;
        defer allocator.free(owned_line);
        const trimmed = std.mem.trim(u8, owned_line, " \t\r\n");
        if (trimmed.len != 0) {
            try dispatchLineWithTrace(allocator, device, trimmed, writer, live_trace);
            try writer.flush();
        }
    }
}

pub fn dispatchLine(allocator: std.mem.Allocator, device: anytype, line: []const u8, writer: anytype) !void {
    try dispatchLineWithTrace(allocator, device, line, writer, null);
}

pub fn dispatchLineWithTrace(
    allocator: std.mem.Allocator,
    device: anytype,
    line: []const u8,
    writer: anytype,
    live_trace: ?*trace.TraceWriter,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
        try protocol.writeError(writer, null, -32700, @errorName(err));
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try protocol.writeError(writer, null, -32600, "request must be an object");
        return;
    }
    const object = parsed.value.object;
    const id = object.get("id");
    const method_value = object.get("method") orelse {
        try protocol.writeError(writer, id, -32600, "missing method");
        return;
    };
    if (method_value != .string) {
        try protocol.writeError(writer, id, -32600, "method must be a string");
        return;
    }
    const params = object.get("params");

    if (live_trace) |tw| try recordRpcEvent(tw, "rpc.request", method_value.string, id);
    methods.dispatchMethod(allocator, device, method_value.string, params, id, writer, live_trace) catch |err| {
        if (live_trace) |tw| try recordRpcErrorEvent(tw, method_value.string, id, err);
        const classified = errors.classify(err);
        try protocol.writeErrorWithPublicCode(writer, id, -32000, @errorName(err), classified.code);
        return;
    };
    if (live_trace) |tw| try recordRpcEvent(tw, "rpc.response", method_value.string, id);
}

fn recordRpcEvent(tw: *trace.TraceWriter, kind: []const u8, method: []const u8, id: ?std.json.Value) !void {
    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
    defer payload.deinit();
    const writer = &payload.writer;
    try writer.writeAll("{\"method\":");
    try trace.writeJsonString(writer, method);
    try writer.writeAll(",\"id\":");
    try protocol.writeId(writer, id);
    try writer.writeAll("}");
    try tw.recordEvent(kind, writer.buffered());
}

fn recordRpcErrorEvent(tw: *trace.TraceWriter, method: []const u8, id: ?std.json.Value, err: anyerror) !void {
    var payload: std.Io.Writer.Allocating = .init(tw.allocator);
    defer payload.deinit();
    const writer = &payload.writer;
    try writer.writeAll("{\"method\":");
    try trace.writeJsonString(writer, method);
    try writer.writeAll(",\"id\":");
    try protocol.writeId(writer, id);
    try writer.writeAll(",\"error\":");
    try trace.writeJsonString(writer, @errorName(err));
    try writer.writeAll("}");
    try tw.recordEvent("rpc.error", writer.buffered());
}
