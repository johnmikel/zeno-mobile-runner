# App-Local Config

Use `.zmr/config.json` to keep app-specific defaults in the app repository:
app ids, device targets, scenario paths, trace directories, artifact settings,
redaction rules, and shim command paths.

The schema is published at `schemas/zmr-config.schema.json`. Runtime parsing
follows the schema for primitive field types. For example,
boolean fields such as `artifacts.screenRecording`, `artifacts.screenshots`,
`android.resetBeforeRun`, `android.waitReady`, and `ios.ensureDevice` must be
JSON booleans, not strings. Path, id, redaction-list, and script command string
fields must be non-empty. `zmr doctor --json --config .zmr/config.json`
reports those type/value mistakes as structured `config` warnings. Unknown
fields are rejected too, so typos in app-local config do not silently fall back
to defaults.

Example:

```json
{
  "schemaVersion": 1,
  "appId": "com.example.mobiletest",
  "android": {
    "enabled": true,
    "defaultDevice": "emulator-5554",
    "smokeScenario": ".zmr/android-smoke.json",
    "traceDir": "traces/zmr-android",
    "avdName": "Small_Phone",
    "restoreSnapshot": "zmr-clean",
    "createAvdIfMissing": false,
    "avdSystemImage": "system-images;android-35;google_apis;arm64-v8a",
    "avdDeviceProfile": "pixel_6",
    "resetBeforeRun": false,
    "waitReady": true,
    "ensureDevice": true
  },
  "ios": {
    "enabled": true,
    "defaultDevice": "booted",
    "smokeScenario": ".zmr/ios-smoke.json",
    "traceDir": "traces/zmr-ios",
    "ensureDevice": true
  },
  "artifacts": {
    "screenshots": true,
    "hierarchy": true,
    "logs": true,
    "screenRecording": false
  },
  "redaction": {
    "denylistText": ["customer dob", "internal token"],
    "allowlistText": ["public token label"],
    "denylistResourceIds": ["password-field", "ssn"],
    "allowlistResourceIds": ["public-token-label"]
  },
  "tools": {
    "androidShimPath": "./.zmr/android-shim",
    "iosShimPath": "./.zmr/ios-shim"
  }
}
```

## Precedence

ZMR auto-discovers `.zmr/config.json` from the current working directory.
Pass `--config <path>` to load a different file.

Relative scenario, trace, and shim paths from config resolve against the app
root. For the standard `.zmr/config.json` location, the app root is the parent
directory of `.zmr/`, even when `--config` is an absolute path and ZMR is
invoked from another checkout. Relative optional tool commands such as
`tools.adbPath` are resolved the same way when they look like paths; bare
commands such as `adb`, `xcrun`, or `zig` stay as PATH lookups.

Explicit CLI flags always win. Use config for stable app defaults and CLI flags
for one-off local or CI overrides:

- `--app-id` overrides `appId`
- `--device` overrides platform `defaultDevice`
- `--trace-dir` overrides platform `traceDir`
- `--android-avd`, `--create-avd-if-missing`, `--avd-system-image`, `--avd-device`, `--restore-snapshot`, `--reset-emulator`, `--wait-emulator`, `--ensure-device`, and `--no-ensure-device` override device lifecycle defaults
- `--screen-record` and `--no-screen-record` override `artifacts.screenRecording`
- a positional scenario path overrides platform `smokeScenario`
- `--adb`, `--emulator`, `--avdmanager`, `--android-shim`, `--xcrun`, `--ios-shim`, and `--zig` override optional tool paths

## Android Emulator Lifecycle

The Android platform config can boot and wait for an emulator before a traced
`zmr run` starts:

- `ensureDevice`: when the requested Android device is not ready, boot the
  configured `avdName`; if no `avdName` is configured, boot the first local AVD
  from `emulator -list-avds`, then wait for `sys.boot_completed=1`.
- `avdName`: AVD name passed to the Android emulator.
- `createAvdIfMissing`: check `emulator -list-avds` and create the AVD when absent.
- `avdSystemImage`: installed Android system image package for `avdmanager create avd`.
- `avdDeviceProfile`: optional device profile for the created AVD.
- `restoreSnapshot`: optional emulator snapshot name to load at boot.
- `resetBeforeRun`: best-effort `adb emu kill` before booting the configured AVD.
- `waitReady`: wait for `adb wait-for-device` and `sys.boot_completed=1`.

The equivalent CLI flags are `--ensure-device`, `--no-ensure-device`,
`--android-avd <name>`,
`--create-avd-if-missing`, `--avd-system-image <package>`,
`--avd-device <profile>`, `--restore-snapshot <name>`, `--reset-emulator`,
and `--wait-emulator`. AVD creation, snapshot restore, and reset require an AVD
name. AVD creation also requires an installed system image package.

For iOS simulator runs, `ensureDevice` or `--ensure-device` reuses an already
booted simulator when one exists. If the target is `booted` and none are
running, ZMR boots the first available shutdown simulator and waits for
`simctl bootstatus -b`. Physical iOS devices are never auto-booted.

## Android Shim

Set `tools.androidShimPath` when an app repo has built or installed an Android
instrumentation shim command. ZMR sends one JSON command to the shim over stdin
and reads one JSON response from stdout. Existing ADB/UI Automator behavior
remains the fallback when no shim is configured.

CLI `--android-shim <path>` takes precedence over the config value for
`zmr run`, `zmr serve`, and `zmr doctor`.

## iOS Shim

Set `tools.iosShimPath` when an app repo has built or installed an
XCTest/XCUIAutomation shim command. ZMR sends one JSON command to the shim over
stdin and reads one JSON response from stdout. The public scenario and JSON-RPC
interfaces stay unchanged. The generated shim command may cache the XCTest
`build-for-testing` output and use `test-without-building` internally; ZMR still
treats it as a simple command transport.

With the shim configured, iOS waits and assertions use native XCTest selector
queries for single-field selectors before falling back to portable snapshot
matching. `observe.snapshot` uses a bounded XCTest snapshot so large native or
React Native trees remain fast enough for interactive agent loops.

CLI `--ios-shim <path>` takes precedence over the config value for `zmr run`,
`zmr serve`, and `zmr doctor`.

## Artifact Capture

The `artifacts` object controls what raw trace artifacts are persisted during
`zmr run`. Turn off raw artifacts when traces might leave a trusted machine.

- `screenshots`: write PNG screenshot artifacts.
- `hierarchy`: write raw Android UI hierarchy XML artifacts.
- `logs`: include recent device log windows in snapshots.
- `screenRecording`: capture an Android MP4 for the whole traced `zmr run`.

Screenshots, hierarchy, and logs default to `true`; screen recording defaults to
`false` because it can be large and privacy-sensitive. Set raw artifacts to
`false` in app repos when traces may contain private visual state,
accessibility text, or log output. Selector matching can still use the live
hierarchy even when raw hierarchy persistence is disabled.

## Trace Redaction

The `redaction` object adds app-specific rules on top of ZMR's built-in email,
token, and sensitive-key scrubbing for persisted trace JSON.

- `denylistText`: redact trace strings containing any listed text.
- `allowlistText`: skip app-specific text denylist matches for strings
  containing any listed text. Built-in email/token scrubbing still applies.
- `denylistResourceIds`: redact matching node `resourceId` values and force the
  node's `text` and `contentDesc` fields to secret placeholders.
- `allowlistResourceIds`: skip resource-id based redaction for matching nodes.
  Built-in value-level email/token scrubbing still applies.

All matches are case-insensitive substrings. These rules apply to local
persisted snapshot JSON and trace events for both `zmr run` and
`zmr serve --trace-dir`. They do not edit raw screenshot pixels or raw hierarchy
XML; disable those artifacts or share `zmr export --redact` bundles when traces
leave a trusted machine.

## Commands

```bash
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr run --config .zmr/config.json
zmr run .zmr/android-smoke.json --device emulator-5554
zmr serve --transport stdio --config .zmr/config.json
zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
zmr doctor --strict --json --config .zmr/config.json
```

For `zmr serve`, the platform `traceDir` from `.zmr/config.json` is used as the
live JSON-RPC trace directory unless `--trace-dir` overrides it. Keep generated
trace output under `traces/` and ignore that directory in app repositories.
