const std = @import("std");

pub const Status = enum {
    ok,
    warning,
    missing,
};

pub fn setupErrorCode(name: []const u8, status: Status) []const u8 {
    if (std.mem.eql(u8, name, "zig")) return if (status == .missing) "setup.zig.not_found" else "setup.zig.command_failed";
    if (std.mem.eql(u8, name, "adb")) return if (status == .missing) "setup.adb.not_found" else "setup.adb.command_failed";
    if (std.mem.eql(u8, name, "xcrun")) return if (status == .missing) "setup.xcrun.not_found" else "setup.xcrun.command_failed";
    if (std.mem.eql(u8, name, "android-shim")) return if (status == .missing) "setup.android_shim.not_found" else "setup.android_shim.command_failed";
    if (std.mem.eql(u8, name, "ios-shim")) return if (status == .missing) "setup.ios_shim.not_found" else "setup.ios_shim.command_failed";
    return if (status == .missing) "setup.tool.not_found" else "setup.tool.command_failed";
}

pub fn hintForCheck(allocator: std.mem.Allocator, name: []const u8, status: Status) !?[]const u8 {
    if (status == .ok) return null;
    const hint =
        if (std.mem.eql(u8, name, "zig"))
            "Install Zig 0.16.0 or newer, ensure it is on PATH, then run zmr doctor again."
        else if (std.mem.eql(u8, name, "adb"))
            "Install Android SDK Platform Tools, ensure adb is on PATH, then run adb devices."
        else if (std.mem.eql(u8, name, "android-devices"))
            "Start an emulator or connect a device, confirm adb devices shows it, then pass --device when running scenarios."
        else if (std.mem.eql(u8, name, "config"))
            "Fix the config file or regenerate it with npx zmr-wizard, then run zmr doctor --strict --json --config .zmr/config.json."
        else if (std.mem.eql(u8, name, "android-shim"))
            "Run npx zmr-install-android-shim in the app repo or update tools.androidShimPath in .zmr/config.json."
        else if (std.mem.eql(u8, name, "android-smoke-scenario"))
            if (status == .warning)
                "Run zmr validate on the configured Android smoke scenario, fix the reported issue, or update android.smokeScenario in .zmr/config.json."
            else
                "Run npx zmr-wizard, create the Android smoke scenario, or update android.smokeScenario in .zmr/config.json."
        else if (std.mem.eql(u8, name, "xcrun"))
            "Install Xcode command line tools, run xcode-select --install if needed, then run xcrun --version."
        else if (std.mem.eql(u8, name, "ios-simulators"))
            "Boot an iOS simulator with Xcode or xcrun simctl boot, then run xcrun simctl list devices booted."
        else if (std.mem.eql(u8, name, "ios-physical-devices"))
            "Connect and trust an iPhone, enable Developer Mode, confirm zmr devices --json --platform ios --ios-device-type physical reports ready:true, then pass --ios-device-type physical --device <physical-device-id>."
        else if (std.mem.eql(u8, name, "ios-shim"))
            "Run npx zmr-install-ios-shim in the app repo or update tools.iosShimPath in .zmr/config.json."
        else if (std.mem.eql(u8, name, "ios-smoke-scenario"))
            if (status == .warning)
                "Run zmr validate on the configured iOS smoke scenario, fix the reported issue, or update ios.smokeScenario in .zmr/config.json."
            else
                "Run npx zmr-wizard, create the iOS smoke scenario, or update ios.smokeScenario in .zmr/config.json."
        else
            "Run the command manually, fix the reported setup issue, then run zmr doctor again.";
    return try allocator.dupe(u8, hint);
}
