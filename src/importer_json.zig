const trace = @import("trace.zig");
const model = @import("importer_model.zig");

pub fn writeScenarioJson(writer: anytype, imported: model.ImportedScenario) !void {
    try writer.writeAll("{\n  \"name\": ");
    try trace.writeJsonString(writer, imported.name);
    if (imported.app_id) |app_id| {
        try writer.writeAll(",\n  \"appId\": ");
        try trace.writeJsonString(writer, app_id);
    }
    if (imported.on_start.len > 0) {
        try writer.writeAll(",\n  \"onStart\": [");
        try writeBlockSteps(writer, imported.on_start);
        try writer.writeAll("]");
    }
    if (imported.on_complete.len > 0) {
        try writer.writeAll(",\n  \"onComplete\": [");
        try writeBlockSteps(writer, imported.on_complete);
        try writer.writeAll("]");
    }
    try writer.writeAll(",\n  \"steps\": [\n");
    for (imported.steps, 0..) |step, index| {
        if (index > 0) try writer.writeAll(",\n");
        try writer.writeAll("    ");
        try writeStepJson(writer, step);
    }
    try writer.writeAll("\n  ]\n}\n");
}

fn writeStepJson(writer: anytype, step: model.ImportedStep) anyerror!void {
    switch (step) {
        .launch => try writer.writeAll("{\"action\":\"launch\"}"),
        .launch_app => |options| try writeLaunchOptionsJson(writer, options),
        .stop => try writer.writeAll("{\"action\":\"stop\"}"),
        .kill_app => try writer.writeAll("{\"action\":\"killApp\"}"),
        .clear_state => try writer.writeAll("{\"action\":\"clearState\"}"),
        .clear_keychain => try writer.writeAll("{\"action\":\"clearKeychain\"}"),
        .grant_permissions => |values| {
            try writer.writeAll("{\"action\":\"grantPermissions\",\"permissions\":[");
            for (values, 0..) |value, index| {
                if (index > 0) try writer.writeAll(",");
                try trace.writeJsonString(writer, value);
            }
            try writer.writeAll("]}");
        },
        .set_orientation => |value| {
            try writer.writeAll("{\"action\":\"setOrientation\",\"orientation\":");
            try trace.writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .set_clipboard => |value| {
            try writer.writeAll("{\"action\":\"setClipboard\",\"text\":");
            try trace.writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .repeat => |block| {
            try writer.print("{{\"action\":\"repeat\",\"times\":{d},\"steps\":[", .{block.count});
            try writeBlockSteps(writer, block.steps);
            try writer.writeAll("]}");
        },
        .retry => |block| {
            try writer.print("{{\"action\":\"retry\",\"attempts\":{d},\"steps\":[", .{block.count});
            try writeBlockSteps(writer, block.steps);
            try writer.writeAll("]}");
        },
        .when_visible => |block| {
            try writer.writeAll("{\"action\":\"whenVisible\",\"selector\":");
            try writeSelectorJson(writer, block.selector);
            try writer.writeAll(",\"steps\":[");
            try writeBlockSteps(writer, block.steps);
            try writer.writeAll("]}");
        },
        .when_not_visible => |block| {
            try writer.writeAll("{\"action\":\"whenNotVisible\",\"selector\":");
            try writeSelectorJson(writer, block.selector);
            try writer.writeAll(",\"steps\":[");
            try writeBlockSteps(writer, block.steps);
            try writer.writeAll("]}");
        },
        .snapshot => try writer.writeAll("{\"action\":\"snapshot\"}"),
        .hide_keyboard => try writer.writeAll("{\"action\":\"hideKeyboard\"}"),
        .press_back => try writer.writeAll("{\"action\":\"pressBack\"}"),
        .open_link => |value| {
            try writer.writeAll("{\"action\":\"openLink\",\"url\":");
            try trace.writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .tap => |wanted| {
            try writer.writeAll("{\"action\":\"tap\",\"selector\":");
            try writeSelectorJson(writer, wanted);
            try writer.writeAll("}");
        },
        .long_press => |gesture| {
            try writer.writeAll("{\"action\":\"longPress\",\"selector\":");
            try writeSelectorJson(writer, gesture.selector);
            try writer.print(",\"durationMs\":{d}}}", .{gesture.duration_ms});
        },
        .double_tap => |wanted| {
            try writer.writeAll("{\"action\":\"doubleTap\",\"selector\":");
            try writeSelectorJson(writer, wanted);
            try writer.writeAll("}");
        },
        .press_key => |value| {
            try writer.writeAll("{\"action\":\"pressKey\",\"key\":");
            try trace.writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .type_text => |value| {
            try writer.writeAll("{\"action\":\"typeText\",\"text\":");
            try trace.writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .erase_text => |value| try writer.print("{{\"action\":\"eraseText\",\"maxChars\":{d}}}", .{value}),
        .assert_visible => |wanted| {
            try writer.writeAll("{\"action\":\"assertVisible\",\"selector\":");
            try writeSelectorJson(writer, wanted);
            try writer.writeAll("}");
        },
        .assert_not_visible => |wanted| {
            try writer.writeAll("{\"action\":\"assertNotVisible\",\"selector\":");
            try writeSelectorJson(writer, wanted);
            try writer.writeAll("}");
        },
        .wait_visible => |wait| {
            try writer.writeAll("{\"action\":\"waitVisible\",\"selector\":");
            try writeSelectorJson(writer, wait.selector);
            try writer.print(",\"timeoutMs\":{d}}}", .{wait.timeout_ms});
        },
        .wait_not_visible => |wait| {
            try writer.writeAll("{\"action\":\"waitNotVisible\",\"selector\":");
            try writeSelectorJson(writer, wait.selector);
            try writer.print(",\"timeoutMs\":{d}}}", .{wait.timeout_ms});
        },
        .scroll_until_visible => |scroll| {
            try writer.writeAll("{\"action\":\"scrollUntilVisible\",\"selector\":");
            try writeSelectorJson(writer, scroll.selector);
            try writer.writeAll(",\"direction\":");
            try trace.writeJsonString(writer, scroll.direction);
            try writer.print(",\"timeoutMs\":{d}}}", .{scroll.timeout_ms});
        },
        .sleep_ms => |value| try writer.print("{{\"action\":\"sleep\",\"ms\":{d}}}", .{value}),
    }
}

fn writeLaunchOptionsJson(writer: anytype, options: @import("scenario.zig").LaunchOptions) !void {
    try writer.writeAll("{\"action\":\"launchApp\"");
    if (options.app_id) |app_id| {
        try writer.writeAll(",\"appId\":");
        try trace.writeJsonString(writer, app_id);
    }
    if (!options.stop_app) try writer.writeAll(",\"stopApp\":false");
    if (options.clear_state) try writer.writeAll(",\"clearState\":true");
    if (options.clear_keychain) try writer.writeAll(",\"clearKeychain\":true");
    if (options.arguments.len > 0) {
        try writer.writeAll(",\"arguments\":{");
        for (options.arguments, 0..) |argument, index| {
            if (index > 0) try writer.writeAll(",");
            try trace.writeJsonString(writer, argument.name);
            try writer.writeAll(":");
            try writeLaunchArgumentValue(writer, argument.value);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn writeLaunchArgumentValue(writer: anytype, value: @import("scenario.zig").LaunchArgumentValue) !void {
    switch (value) {
        .string => |actual| try trace.writeJsonString(writer, actual),
        .boolean => |actual| try writer.writeAll(if (actual) "true" else "false"),
        .integer => |actual| try writer.print("{d}", .{actual}),
        .double => |actual| try writer.print("{d}", .{actual}),
    }
}

fn writeBlockSteps(writer: anytype, steps: []const model.ImportedStep) anyerror!void {
    for (steps, 0..) |step, index| {
        if (index > 0) try writer.writeAll(",");
        try writeStepJson(writer, step);
    }
}

fn writeSelectorJson(writer: anytype, wanted: model.SelectorSpec) !void {
    try writer.writeAll("{");
    var first = true;
    if (wanted.id) |value| {
        try writeSelectorField(writer, "id", value, &first);
    }
    if (wanted.text) |value| {
        try writeSelectorField(writer, "text", value, &first);
    }
    if (wanted.text_contains) |value| {
        try writeSelectorField(writer, "textContains", value, &first);
    }
    if (wanted.content_desc) |value| {
        try writeSelectorField(writer, "contentDesc", value, &first);
    }
    try writer.writeAll("}");
}

fn writeSelectorField(writer: anytype, key: []const u8, value: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("\"");
    try writer.writeAll(key);
    try writer.writeAll("\":");
    try trace.writeJsonString(writer, value);
}
