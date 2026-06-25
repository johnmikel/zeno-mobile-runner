# Demo

Run the local demo when you want a fast proof of the CLI, schemas, fake-device
flows, reference clients, trace output, and diagnostics without an emulator,
simulator, app build, or credentials:

```bash
./scripts/demo.sh
```

The script builds `zig-out/bin/zmr`, then runs:

- `zmr version`
- `zmr version --json`
- `zmr schemas --json`
- `zmr validate examples/demo-fake.json`
- `zmr validate examples/demo-failure.json`
- `zmr validate examples/android-app-onboarding.json`
- `zmr validate examples/android-app-referral-deep-link.json`
- `zmr validate examples/android-app-error-state.json`
- `zmr validate examples/android-shim-smoke.json`
- `zmr validate examples/android-workflow.json`
- `zmr validate examples/react-native-expo-workflow.json`
- `zmr validate examples/ios-smoke.json`
- `zmr validate examples/ios-dev-client-open-link.json`
- `zmr validate examples/ios-dev-client-route-snapshot.json`
- `zmr validate examples/ios-shim-smoke.json`
- `zmr validate examples/ios-shim-workflow.json`
- expected-failing `zmr validate --json` output that shows `fieldPath`, `line`,
  and `column` for invalid scenarios covered by `schemas/validate-output.schema.json`
- `zmr doctor --adb ./tests/fake-adb.sh --xcrun ./tests/fake-xcrun.sh --ios-shim ./tests/fake-ios-shim.sh`
- `zmr doctor --json` output for a missing Android shim that includes a
  remediation `hint`
- `zmr doctor --json` output that warns with stable setup `errorCode` values
  when no Android devices, booted iOS simulators, or paired physical iOS
  devices are ready
- expected-failing `zmr doctor --strict --json` output for the same no-device
  setup, showing how CI can fail without parsing the diagnostics itself
- `zmr doctor --json --config traces/demo-doctor-config.json` output that
  validates configured smoke scenario files, including an `ios-smoke-scenario` remediation
  for a bad `ios.smokeScenario` and a `zmr validate on the configured Android
  smoke scenario` hint for malformed scenario JSON
- `zmr doctor --json --config traces/demo-bad-config.json` output that reports
  stable `errorCode` plus `fieldPath` for an invalid app-local config value
  before device setup starts
- `zmr devices --adb ./tests/fake-adb.sh`
- `zmr devices --json --adb ./tests/fake-adb.sh`
- `zmr devices --platform ios --xcrun ./tests/fake-xcrun.sh`
- `zmr devices --json --platform ios --xcrun ./tests/fake-xcrun.sh`
- `zmr init --app --json --dir traces/demo-init-app --app-id com.example.demoapp`
  followed by validation and strict config-driven doctor checks from that
  generated app-local workspace
- `zmr import flow-yaml traces/demo-flow-yaml-flow.yaml --out traces/demo-imported-flow.json --json`
  followed by validation of the generated native ZMR scenario
- `zmr run examples/demo-fake.json --trace-dir traces/demo-fake-android --json`
- `scripts/device-matrix.sh --matrix traces/demo-device-matrix.json --trace-root traces/demo-device-matrix`
- `zmr run examples/demo-failure.json --trace-dir traces/demo-failure --json`
- `zmr explain traces/demo-failure`
- `zmr explain traces/demo-failure --json`
- `zmr serve --transport stdio --trace-dir traces/demo-rpc-session`
- `node clients/typescript/examples/fake-session.mjs`
- `python3 clients/python/examples/fake_session.py`
- `swift run ZMRFakeSession` from `clients/swift`
- `gradle -p clients/kotlin runFakeSession`
- `go run ./clients/go/examples/fake-session --zmr ./zig-out/bin/zmr --adb ./tests/fake-adb.sh --trace-dir traces/demo-go-client`
- `cargo run --manifest-path clients/rust/Cargo.toml --example fake_session -- --zmr ./zig-out/bin/zmr --adb ./tests/fake-adb.sh --trace-dir traces/demo-rust-client`
- `zmr run examples/ios-smoke.json --platform ios --trace-dir traces/demo-fake-ios`

The fake Android flow exercises selector matching and wait/assert trace output.
The fake device-matrix flow exercises Android, iOS simulator, and physical iOS
matrix rows without requiring local hardware, producing `matrix.jsonl` and
`summary.json`.
The fake failure flow exercises failed trace diagnostics and the terminal
`zmr explain` summary.
The fake JSON-RPC flow exercises the agent protocol over stdio, live RPC trace
recording, `observe.snapshot`, and redacted `trace.export`.
Doctor output is intentionally structured for setup automation; `--json`
includes remediation `hint` values for missing or warning checks, and
`--config` validates app-local smoke scenario files. Add `--strict` when a
non-`ok` diagnostic should also make the command fail.
The TypeScript reference client flow exercises the same protocol through the
client API external agents would use.
The Python reference client flow verifies the same agent integration path with
only the Python standard library.
The Swift and Kotlin reference client flows verify host-side native-language
agent/test-harness integration for iOS and Android teams.
The fake Android shim flow exercises shim-backed hierarchy, wait, tap, type,
hide-keyboard, and snapshot handling.
The React Native/Expo workflow example validates the framework fixture scenario
that uses deep links, accessibility labels, and stable `testID` values.
The fake iOS flow exercises simulator lifecycle, deep-link opening, screenshot
artifact capture, log capture, and snapshot trace writing. The fake iOS shim
flow exercises shim-backed hierarchy, wait, tap, type, hide-keyboard, and
snapshot handling.

Load any generated `.zmrtrace` in `viewer/index.html` to inspect the replay
timeline, payloads, screenshot, UI tree, selected node details, and raw
artifacts side-by-side. When the viewer and the bundle are served over HTTP,
link straight to a loaded trace with `viewer/index.html?bundle=<url>`, which is
useful for CI artifact links and shared triage.

![ZMR trace viewer with a loaded Android demo trace showing the timeline, device screenshot, and UI tree](assets/viewer-android.png)

## Real Android Pilot Demo

Run the Android pilot against a sample app test build when you want real
emulator/device evidence:

```bash
./scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --device emulator-5554
```

To force a known emulator state, direct `zmr run` supports `--android-avd`,
`--create-avd-if-missing`, `--avd-system-image`, `--avd-device`,
`--restore-snapshot`, `--reset-emulator`, and `--wait-emulator`. The pilot
wrapper accepts the same state controls while also building/installing the app.
Add `--screen-record` to keep a pilot-level MP4 under the trace root:

```bash
./scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --device emulator-5554 \
  --avd Small_Phone \
  --reset-emulator \
  --restore-snapshot zmr-clean \
  --screen-record
```

The script builds `zmr` when needed, validates both sample scenarios, installs the debug test APK, starts the app's test Metro server, and runs:

- `examples/android-app-auth-probe.json`
- `examples/android-app-login-smoke.json`

For each single run it writes:

- `auth/report.html`
- `auth/junit.xml`
- `login-smoke/report.html`
- `login-smoke/junit.xml`
- `auth.zmrtrace`
- `auth-redacted.zmrtrace`
- `login-smoke.zmrtrace`
- `login-smoke-redacted.zmrtrace`
- `screenrecord.mp4` when pilot `--screen-record`, `zmr run --screen-record`, or `.zmr/config.json` `artifacts.screenRecording` is enabled

Use the redacted bundles for demos outside a trusted local machine:

```bash
open viewer/index.html
```

Then load `auth-redacted.zmrtrace` or `login-smoke-redacted.zmrtrace`.

Inspect the command plan without touching the emulator:

```bash
./scripts/run-android-pilot.sh --dry-run --skip-emulator --skip-metro --app-root <android-app-root>
```

Run repeated benchmark passes:

```bash
./scripts/run-android-pilot.sh \
  --app-root <android-app-root> \
  --device emulator-5554 \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0
```

`<trace-root>/metro.log` may contain sensitive app output from the sample app test environment. Do not publish raw Metro logs.

## Real Android Demo APK

To generate a small public native Android app and matching smoke scenario:

```bash
npx zmr-demo-android --out /tmp/zmr-android-demo --device emulator-5554 --avd <avd-name>
```

The wrapper builds a signed debug APK with Android SDK command-line tools
only, boots the named AVD when the requested device is not ready, installs the
app, and runs the generated smoke scenario. To inspect or customize the
generated app before running manually:

```bash
npx zmr-create-android-demo-app --out /tmp/zmr-android-demo
adb install -r /tmp/zmr-android-demo/build/app-debug.apk
zmr run /tmp/zmr-android-demo/.zmr/android-smoke.json \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --trace-dir /tmp/zmr-android-demo/traces/android-demo
```

The scenario launches the app, waits for visible text, taps a button, types
text into a field, and captures a trace-backed snapshot.

## React Native And Expo Fixture

To generate a public React Native and Expo app with stable test IDs,
accessibility labels, deep-link routing, and matching Android/iOS ZMR workflow
scenarios:

```bash
npx zmr-create-react-native-expo-demo-app --out /tmp/zmr-rn-expo-demo
cd /tmp/zmr-rn-expo-demo
bun install
bunx expo start
```

After installing a development build on the target device, run the generated
scenario for the platform you are measuring:

```bash
zmr run .zmr/react-native-expo-android-workflow.json \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --trace-dir traces/zmr-rn-expo-android
```

The fixture includes `expo-dev-client` and is available for benchmark
collection, but it does not have public timing rows yet.

## Real iOS Simulator Demo

To generate a small public demo app with the ZMR XCTest shim already installed:

```bash
npx zmr-demo-ios --out /tmp/zmr-ios-demo --device booted --cleanup-build-products
```

That command creates the demo app, builds it, installs it on the requested
simulator, runs the plain iOS smoke and selector-grade shim smoke, then writes
reports and redacted `.zmrtrace` bundles. `--cleanup-build-products` removes
generated Xcode `DerivedData` after the pilot so repeated demo runs keep their
footprint small. When `--device booted` is used and no
simulator is running, the command boots an available iOS simulator first. If
the first available simulator fails to boot because CoreSimulator cannot start
`launchd_sim`, the script tries the next available iOS simulator before failing.

To inspect or customize the generated app before running the pilot manually:

```bash
npx zmr-create-ios-demo-app --out /tmp/zmr-ios-demo
cd /tmp/zmr-ios-demo
xcodebuild -project ios/ZMRDemo.xcodeproj -scheme ZMRDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build
```

Then boot a simulator and run from the ZMR repo:

```bash
scripts/run-ios-pilot.sh \
  --app-root /tmp/zmr-ios-demo \
  --app-path /tmp/zmr-ios-demo/DerivedData/Build/Products/Debug-iphonesimulator/ZMRDemo.app \
  --app-id com.example.mobiletest \
  --device booted \
  --ios-shim /tmp/zmr-ios-demo/.zmr/ios-shim
```

Build the app for an iOS simulator, boot a simulator, then run:

```bash
./scripts/run-ios-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app \
  --app-id com.example.mobiletest \
  --device booted \
  --ios-shim /path/to/mobile-app/.zmr/ios-shim
```

For each run it writes:

- `ios-smoke/report.html`
- `ios-smoke/junit.xml`
- `ios-smoke.zmrtrace`
- `ios-smoke-redacted.zmrtrace`
- `ios-shim-smoke/report.html` when `--ios-shim` is set
- `ios-shim-smoke/junit.xml` when `--ios-shim` is set
- `ios-shim-smoke.zmrtrace` when `--ios-shim` is set
- `ios-shim-smoke-redacted.zmrtrace` when `--ios-shim` is set

The iOS demo covers simulator install, launch/open-link, screenshot capture,
log capture, trace export, and viewer inspection. With `--ios-shim`, it also
runs `examples/ios-shim-smoke.json`, which exercises launch, waitVisible, tap,
selector-scoped typeText, hideKeyboard, and snapshot through the generated
XCTest/XCUIAutomation shim command.

When an iOS shim is configured, the pilot wrapper prewarms it before scenario
timing by sending `{"cmd":"appState"}`. That catches Xcode target wiring issues
early and keeps cold `build-for-testing` cost out of benchmark durations.
The same app-state check is used as an idempotent launch confirmation when the
app is already running but `simctl launch` reports a non-zero exit.

Simulator demos require a simulator-built `iphonesimulator` `.app`. A signed
device `.ipa` is for `--ios-device-type physical` only and is rejected early for
simulator pilots.

`clearState` on iOS is best-effort app uninstall by bundle id. Repeating it is
safe: a simulator where the app is already absent is treated as clean.
