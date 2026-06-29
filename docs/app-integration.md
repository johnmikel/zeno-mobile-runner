# App Integration

ZMR is intentionally a separate runner. The app does not vendor ZMR, but it
should expose a small, stable test surface so agents and CI can drive the app
deterministically.

Install the native `zmr` binary once, then create app-local `.zmr/` state from
the app repo:

```bash
curl -fsSL https://raw.githubusercontent.com/johnmikel/zeno-mobile-runner/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
zmr init --app --app-id com.example.mobiletest
```

That keeps scenarios and traces in the app repo while the runner stays outside
the app process. JavaScript teams can use
`npm install --save-dev zeno-mobile-runner` plus
`npx zmr-wizard --app-id com.example.mobiletest --package-json` when they want
generated package scripts and npm helper bins.

For Expo development builds, use
`npx zmr-wizard --expo-dev-client-scheme <scheme> --package-json` when you want
generated Android and iOS open-link smoke scenarios that load Metro before
selector assertions run.

## React Native, Expo, And Flutter

ZMR works best when the app exposes stable, user-meaningful selectors and direct
navigation paths:

- React Native apps should use `testID`, `accessibilityLabel`, stable visible
  text, and deep links for direct navigation.
- Expo development builds can use `--expo-dev-client-scheme <scheme>` so ZMR
  opens the dev client before running selector assertions.
- Flutter apps should expose important controls through `Semantics` labels,
  stable text, and deep links. ZMR drives Flutter apps at the Android/iOS app
  level; it does not inspect Flutter widget trees.

See [frameworks.md](frameworks.md) for framework-specific examples.

## What The App Provides

Think of this as the contract between the app repo and the runner.

For Android:

- A debug/test APK.
- A stable application id, for example `com.example.mobiletest`.
- Optional deep links for direct navigation into test states.
- Accessibility labels, text, or resource ids for important controls.
- A test server or local dev server when the app requires one.
- Optional Android instrumentation shim command for faster hierarchy and
  selector-grade actions.

Create the app-local Android shim command from the ZMR package or checkout when
you want faster hierarchy capture or selector-grade native actions:

```bash
npx zmr-install-android-shim \
  --app-root . \
  --test-package com.example.mobiletest.test \
  --runner androidx.test.runner.AndroidJUnitRunner \
  --android-module android/app \
  --gradle-file android/app/build.gradle
```

With `--android-module`, the installer copies the shim into the app module's
standard `src/androidTest/java/dev/zmr/shim/` tree. With `--gradle-file`, it
appends guarded Gradle blocks once for `testInstrumentationRunner` and AndroidX
Test/UI Automator dependencies. If the Gradle file already declares a custom
`testInstrumentationRunner` and `--runner` is omitted, the generated shim command
uses the existing runner. Omit those flags when you prefer to wire source and
dependencies yourself from the generated `.zmr/ZMRShimInstrumentedTest.java`.
The generated
`.zmr/android-shim` executable is the value to pass to `--android-shim` or
`tools.androidShimPath`.

For iOS/iPadOS:

- A simulator `.app` build.
- A stable bundle id, for example `com.example.mobiletest`.
- Optional deep links for direct navigation into test states.
- Accessibility labels for important controls.
- Optional simulator XCTest/XCUIAutomation shim command for hierarchy and
  selector-grade actions.

Create the app-local XCTest/XCUIAutomation shim command from the ZMR package or
checkout when selector actions, bounded hierarchy snapshots, or physical-device
screenshots are required:

```bash
npx zmr-install-ios-shim \
  --app-root . \
  --scheme SampleUITests \
  --test-target SampleUITests \
  --workspace ios/Sample.xcworkspace \
  --app-target SampleApp \
  --derived-data-path ios/build/ZMRDerivedData \
  --bundle-id com.example.mobiletest \
  --patch-xcodeproj
```

Run `.zmr/ensure-ios-shim-target.sh` to create/update the UI test target, add
the generated `.zmr/ZMRShimUITestCase.swift` and
`.zmr/shims/ios/ZMRShim.swift` files, configure
`.zmr/ZMRShimUITests-Info.plist`, and write a shared scheme. The helper uses the
Ruby `xcodeproj` gem. With `--workspace`, it resolves the referenced
`.xcodeproj` automatically when there is one project, or when exactly one
project contains `--app-target`, or when `--bundle-id` disambiguates matching
app targets. Pass `--project ios/Sample.xcodeproj` explicitly for
still-ambiguous multi-project workspaces or project-only apps.

The generated `.zmr/ios-shim` executable is written into
`tools.iosShimPath` in `.zmr/config.json`, and can still be passed explicitly
with `--ios-shim`. It caches `build-for-testing` output and uses
`test-without-building` for selector commands through `.zmr/ios-shim-state/`.
Set `ZMR_IOS_SHIM_FORCE_REBUILD=1` after app-side target changes, or
`ZMR_IOS_SHIM_ONESHOT=1` when you need to debug the slower cold-start path.
When `--derived-data-path` points at a ZMR-owned path ending in
`ZMRDerivedData`, the generated shim removes that directory before each
`build-for-testing` refresh so copied app checkouts do not reuse stale absolute
Xcode paths. It refuses to delete arbitrary shared DerivedData locations.

## Recommended App Repo Layout

The exact layout is app-specific, but this shape works well:

```text
mobile-app/
  android/app/build/outputs/apk/debug/app-debug.apk
  build/Debug-iphonesimulator/Sample.app
  .zmr/
    config.json
    android-auth-probe.json
    android-login-smoke.json
    ios-smoke.json
```

Keep app-owned scenarios and ZMR defaults in `.zmr/` when they are app-specific.
Keep generic examples in the ZMR repo. ZMR auto-discovers `.zmr/config.json`
from the app repo; explicit CLI flags still override config defaults.

## Android App Pilot Command

Use the pilot wrapper when you want app-local reliability evidence and standard
trace/report artifacts:

```bash
/path/to/zeno-mobile-runner/scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-id com.example.mobiletest \
  --device emulator-5554
```

Use a saved emulator snapshot for repeatability:

```bash
/path/to/zeno-mobile-runner/scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-id com.example.mobiletest \
  --device emulator-5554 \
  --avd Small_Phone \
  --reset-emulator \
  --restore-snapshot zmr-clean \
  --screen-record
```

`--screen-record` writes `screenrecord.mp4` under the pilot trace root. For
direct traced runs, use `zmr run --ensure-device --android-avd Small_Phone
--create-avd-if-missing --avd-system-image
'system-images;android-35;google_apis;arm64-v8a' --avd-device pixel_6
--restore-snapshot zmr-clean --wait-emulator --screen-record`, or set the
equivalent `android.avdName`, `android.createAvdIfMissing`,
`android.avdSystemImage`, `android.avdDeviceProfile`,
`android.restoreSnapshot`, `android.waitReady`, `android.ensureDevice`, and
`artifacts.screenRecording` values in `.zmr/config.json`. Treat recordings like
screenshots: keep them local or share only when the app state is safe.

The Android wrapper expects the default APK path under the app root. Override it
when needed:

```bash
/path/to/zeno-mobile-runner/scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --apk /path/to/app-debug.apk \
  --device emulator-5554
```

## Public Android Demo Command

Use the public demo before connecting ZMR to a private app. It proves local
Android install, launch, selector action, typing, snapshot, and trace capture
with generic artifacts:

```bash
npx zmr-demo-android --out /tmp/zmr-android-demo --device emulator-5554 --avd <avd-name>
```

This writes a signed debug APK plus `.zmr/android-smoke.json` without Gradle or
network access, then installs and runs it on the requested Android target. For
manual inspection or customization:

```bash
npx zmr-create-android-demo-app --out /tmp/zmr-android-demo
adb install -r /tmp/zmr-android-demo/build/app-debug.apk
/path/to/zeno-mobile-runner/zig-out/bin/zmr run /tmp/zmr-android-demo/.zmr/android-smoke.json \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --trace-dir /tmp/zmr-android-demo/traces/android-demo
```

Use this path before wiring ZMR into a private app.

## iOS Demo Command

Use the public iOS demo before connecting ZMR to a private iOS or iPadOS app:

```bash
npx zmr-demo-ios --out /tmp/zmr-ios-demo --device booted
```

That command creates the demo app, boots an available simulator when needed,
builds it, runs the iOS pilot, and writes redacted trace bundles. To inspect or
customize the generated app before running the pilot manually:

```bash
npx zmr-create-ios-demo-app --out /tmp/zmr-ios-demo
cd /tmp/zmr-ios-demo
xcodebuild -project ios/ZMRDemo.xcodeproj -scheme ZMRDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build
```

Then boot a simulator and run:

```bash
/path/to/zeno-mobile-runner/scripts/run-ios-pilot.sh \
  --app-root /tmp/zmr-ios-demo \
  --app-path /tmp/zmr-ios-demo/DerivedData/Build/Products/Debug-iphonesimulator/ZMRDemo.app \
  --app-id com.example.mobiletest \
  --device booted \
  --ios-shim /tmp/zmr-ios-demo/.zmr/ios-shim
```

For a private app, build the app for an iOS simulator, boot a simulator, then
run:

```bash
/path/to/zeno-mobile-runner/scripts/run-ios-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app \
  --app-id com.example.mobiletest \
  --device booted \
  --ios-shim /path/to/mobile-app/.zmr/ios-shim
```

Without `--ios-shim`, the iOS path is a smoke demo: install, launch/open-link,
screenshot, logs, trace, report, and redacted export. With `--ios-shim`, ZMR
also runs `examples/ios-shim-smoke.json`, producing a second report and
redacted bundle for selector-grade native waits, tap, type, and bounded
snapshot actions. If a selector wait times out, ZMR records a final XCTest
snapshot when possible so reports and agents can see the active app context,
visible labels, hidden/disabled/offscreen candidates, and nearest text matches.
When the app is already running, ZMR uses the shim `appState` response as an
idempotent launch confirmation if `simctl launch` itself returns an error.

On iOS and iPadOS simulators, `clearState` means best-effort app uninstall by
bundle id. Use the same `--platform ios --ios-device-type simulator` path for
iPhone and iPad simulators, but collect separate iPad evidence when tablet
layouts, split views, or size classes can change the UI tree.

For physical iPhone and iPad devices, lifecycle commands go through `devicectl`
and selector commands go through the same app-local XCTest shim, subject to
signing, provisioning, Developer Mode, and local Xcode availability. Screenshot
artifacts use the XCTest shim; log artifact capture is simulator-first in this
release.
Use a simulator-built `iphonesimulator` `.app` for simulator runs. A signed
device `.ipa` must be run with `--ios-device-type physical`; the pilot wrapper
rejects device IPAs on simulator runs before installing anything.
Use `--ios-device-type physical` with a concrete device identifier from
`zmr devices` for physical iPhone or iPad pilot runs:

```bash
/path/to/zeno-mobile-runner/scripts/run-ios-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-path /path/to/mobile-app/build/Release-iphoneos/Sample.ipa \
  --ios-device-type physical \
  --device <physical-device-id> \
  --ios-shim /path/to/mobile-app/.zmr/ios-shim \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0
```

If the app is already missing, ZMR treats the simulator as clean and continues.
Install the simulator `.app` again before launch/open-link steps that need it.

## Direct CLI Use

Use direct CLI commands when debugging a scenario or wiring custom CI steps.

Android:

```bash
zmr run .zmr/android-auth-probe.json \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --android-shim ./.zmr/android-shim \
  --trace-dir traces/android-auth
```

Or use app-local defaults:

```bash
zmr run --config .zmr/config.json
```

iOS:

```bash
xcrun simctl install booted /path/to/Sample.app
zmr run .zmr/ios-shim-smoke.json \
  --platform ios \
  --device booted \
  --ensure-device \
  --app-id com.example.mobiletest \
  --ios-shim ./.zmr/ios-shim \
  --trace-dir traces/ios-smoke
```

## Agent JSON-RPC Use

Start a local server next to the device. App repos scaffolded by
`zmr-wizard --package-json` can use the generated scripts:

```bash
npm run zmr:serve
npm run zmr:mcp
```

External agents can call:

- `runner.capabilities`
- `session.create`
- `app.launch`
- `app.openLink`
- `observe.snapshot`
- `observe.semanticSnapshot`
- `ui.tap`
- `wait.until`
- `assert.visible`
- `trace.export`

Use `observe.semanticSnapshot` before choosing actions, and use
`observe.snapshot` when raw adapter details are needed. Every action should
settle and observe again. Scenario runs call the adapter-level settle hook after
mutating actions; native shims can wait for platform idle while shell-only paths
keep a bounded sleep fallback. Start `serve` with `--trace-dir` so
`trace.export` can produce a redacted `.zmrtrace` bundle for the whole agent
session.

## Public Artifact Rules

- Share `*-redacted.zmrtrace` bundles.
- Do not publish raw Metro logs, simulator logs, or unredacted screenshot
  bundles from private apps.
- Run `bash tests/public-safety-test.sh` before publishing this repo.
