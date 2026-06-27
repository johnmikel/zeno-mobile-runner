# npm Package

Install the npm package inside a mobile app repo when you want the `zmr` binary,
setup wizard, app-local scripts, schemas, examples, clients, and agent skill to
version with the app:

```bash
npm install --save-dev zeno-mobile-runner
```

The package exposes these command surfaces:

- `zmr`: CLI binary wrapper.
- `zmr-init`: app-local scenario scaffolder.
- `zmr-wizard`: guided setup and dependency checker.
- `zmr-benchmark`: repeated-run wrapper with pass-rate and duration gates.
- `zmr-benchmark-command`: repeated-run wrapper for app-local baseline commands
  so existing runner flows can be compared without custom glue.
- `zmr-compare-benchmarks`: generic comparison report for ZMR and app-local
  baseline benchmark rows.
- `zmr-device-matrix`: local multi-device Android/iOS matrix runner with
  simulator and physical iOS row support plus pass-rate gates.
- `zmr-pilot-gate`: app-local pilot runner that delegates to the Android and
  iOS pilot wrappers on machines with real targets.
- `zmr-assert-ios-physical-ready`: verifies that a requested physical iOS
  device is connected, trusted, and ready before physical-device pilots; pass
  `--xcrun <path>` when using a custom Xcode toolchain.
- `zmr-release-readiness`: optional evidence checker for teams that collect
  repeated app/device pilot rows and want a machine-readable readiness summary.
- `zmr-install-android-shim`: writes the app-local Android instrumentation
  shim command and source file.
- `zmr-install-ios-shim`: writes the app-local iOS XCTest shim command and
  source files.
- `zmr-create-android-demo-app`: creates a generic native Android APK with a
  matching `.zmr/` smoke scenario for public demos and emulator pilots.
- `zmr-create-ios-demo-app`: creates a generic SwiftUI simulator app with
  `.zmr/` scenarios and the iOS shim already installed for public demos.
- `zmr-create-react-native-expo-demo-app`: creates a generic React Native and
  Expo app with stable `testID` values, accessibility labels, deep-link config,
  and Android/iOS `.zmr/` workflow scenarios.
- `zmr-demo-android`: creates, installs, and runs the generated Android demo
  through a real emulator/device.
- `zmr-demo-ios`: creates, builds, and runs the generated iOS simulator demo
  through the real iOS pilot wrapper.
- `import { runZmr, spawnZmr, resolveBinary } from "zeno-mobile-runner"` for Node scripts.
- packaged docs, schemas, examples, reference clients, and the reusable
  `skills/zmr-mobile-testing` agent skill.

Most app teams should start with `zmr-wizard`, generated smoke scenarios, and
redacted traces. Use pilot and readiness helpers when you need repeated local
evidence for your own app and devices.

## App Setup

From the app repo:

```bash
npx zmr-wizard --app-id com.example.mobiletest
```

This creates:

```text
.zmr/
  config.json
  android-smoke.json
  ios-smoke.json
  device-matrix.json
  AGENTS.md
```

`.zmr/config.json` is the app-local source of truth for default devices, trace
directories, smoke scenario paths, and suggested script commands.
`.zmr/device-matrix.json` gives CI a ready Android/iOS matrix starting point.
ZMR auto-discovers config from the app repo, and explicit CLI flags override it.
The wizard does not inspect or depend on any other mobile test runner
configuration.

`.zmr/AGENTS.md` gives AI agents an app-local operating note with:

- strict doctor and validation commands
- schema discovery
- direct `zmr run` smoke commands
- JSON-RPC and MCP startup commands
- selector guidance
- trace-to-test discovery commands
- failure-triage commands
- redacted trace export commands

`zmr-init` and wizard runs without `--package-json` write direct commands in
`.zmr/AGENTS.md` so agents can execute the generated guidance immediately.
`zmr-init` accepts the same platform, shim, and Expo dev-client scaffold flags
as the wizard, plus `--package-json` for non-interactive app templates that do
not need dependency checks.
For setup scripts and AI agents that need a machine-readable handoff, use
`npx zmr-init --json --dir . --app-id com.example.mobiletest` or
`npx zmr-wizard --json --dir . --app-id com.example.mobiletest --android --ios`.
The JSON form is covered by `schemas/init-output.schema.json` and includes the
generated config, scenario, Expo dev-client scenario, device matrix, and
`AGENTS.md` paths plus `nextCommands`, `scriptCount`, and `scriptNames`.
Wizard runs with `--package-json` write npm script commands in `.zmr/AGENTS.md`
because the wizard installs those scripts into `package.json`. Run
`npm run zmr:validate` after editing generated scenarios and before starting
longer smoke, matrix, or pilot runs.

Add app-local scripts:

```json
{
  "scripts": {
    "zmr:doctor": "zmr doctor --strict --json --config .zmr/config.json",
    "zmr:schemas": "zmr schemas --json",
    "zmr:validate": "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json",
    "zmr:android": "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --ensure-device",
    "zmr:android:report": "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml",
    "zmr:android:reliability": "export ZMR_BIN=\"${ZMR_BIN:-zmr}\"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.mobiletest --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && \"$ZMR_BIN\" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml",
    "zmr:matrix": "ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0",
    "zmr:ios": "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios --ensure-device",
    "zmr:ios:report": "zmr report traces/zmr-ios --out traces/zmr-ios/report.html --junit traces/zmr-ios/junit.xml",
    "zmr:ios:reliability": "export ZMR_BIN=\"${ZMR_BIN:-zmr}\"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.mobiletest --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && \"$ZMR_BIN\" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml",
    "zmr:pilot": "zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.mobiletest --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.mobiletest --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
    "zmr:readiness": "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json",
    "zmr:serve": "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent",
    "zmr:mcp": "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent",
    "zmr:explain": "zmr explain traces/zmr-agent --json",
    "zmr:export": "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact"
  }
}
```

Reliability scripts export one `ZMR_BIN` value and reuse it for both
`zmr-benchmark` and report generation, so CI can pin a custom runner binary
without mixing binaries between the run and report steps.

For non-interactive CI or template setup:

```bash
npx zmr-wizard \
  --yes \
  --app-id com.example.mobiletest \
  --android \
  --android-shim ./.zmr/android-shim \
  --ios \
  --ios-shim ./.zmr/ios-shim \
  --expo-dev-client-scheme mobiletest \
  --package-json
```

The wizard checks Node, ZMR, ADB, `xcrun`, and Zig when applicable. It
scaffolds `.zmr` scenarios, can patch `package.json` scripts, and ensures
`traces/` is ignored in the app repo.
When `--expo-dev-client-scheme` is set, it also writes
`.zmr/android-dev-client-smoke.json` and `.zmr/ios-dev-client-open-link.json`.
Package-script setup also adds `zmr:android:dev-client`,
`zmr:android:dev-client:report`, `zmr:ios:dev-client`, and
`zmr:ios:dev-client:report` for the generated dev-client traces.
The Android scenario opens Metro through `10.0.2.2:8081`; the iOS simulator
scenario opens `127.0.0.1:8081`.
Rerunning the wizard refreshes generated `.zmr/config.json`,
`.zmr/device-matrix.json`, and `.zmr/AGENTS.md` for the selected platforms,
while existing scenario files are left in place so local flow edits are not
overwritten.
`zmr-init` can be used for the same non-interactive scaffold without dependency
checks:

```bash
npx zmr-init \
  --dir . \
  --app-id com.example.mobiletest \
  --ios \
  --ios-shim ./.zmr/ios-shim \
  --expo-dev-client-scheme mobiletest \
  --package-json
```

When platform flags are omitted, `zmr-init` scaffolds both Android and iOS.
With `--package-json`, `zmr-init` patches `package.json` directly and writes
`.zmr/AGENTS.md` with `npm run zmr:*` commands. Without `--package-json`, it
prints the script map for copy-free review and keeps `.zmr/AGENTS.md` on direct
`zmr` commands.
Rerunning `zmr init --app` refreshes generated `.zmr/config.json`,
`.zmr/device-matrix.json`, and `.zmr/AGENTS.md` the same way, while preserving
existing scenario files. Pass `--force` only when you intentionally want to
replace the generated smoke scenarios too.
The reliability scripts use `zmr-benchmark` with `100%` pass-rate and
zero-failure defaults. Tune p95 thresholds only after capturing stable local
baseline runs.
The wizard only adds `zmr:readiness` for Android+iOS setups because the
production readiness target requires Android, iOS simulator, and physical iOS
evidence; single-platform setups should use `zmr:pilot` and the platform
reliability script until the full matrix is enabled.
For release validation, `zmr-pilot-gate` is safe to run from the app checkout:
relative app roots, APK paths, simulator app paths, shim paths, and trace roots
are resolved against the current app directory before the packaged runner
scripts are invoked. Pass `--zmr-bin ./node_modules/.bin/zmr` when CI needs an
explicit runner binary instead of relying on `PATH` or `ZMR_BIN`. Add
`--evidence-out traces/zmr-pilots/evidence.jsonl` so production-readiness rows
can be evaluated with `zmr-release-readiness`.

The standalone CLI has the same non-interactive app-local bootstrap for
source or release-archive installs:

```bash
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr doctor --strict --json --config .zmr/config.json
```

See [ai-agents.md](ai-agents.md) for JSON-RPC agent workflows and
[`../skills/zmr-mobile-testing/SKILL.md`](../skills/zmr-mobile-testing/SKILL.md)
for the packaged agent skill.

Omit `--android-shim` or `--ios-shim` for shell/screenshot-only smoke runs.
Include them when the app repo provides native shim commands for faster
hierarchy and selector actions.

## Android Demo App

For a clean public Android demo APK that does not depend on a private app:

```bash
npx zmr-demo-android --out /tmp/zmr-android-demo --device emulator-5554 --avd <avd-name>
```

That command uses Android SDK command-line tools directly, so it does not need
Gradle or network access. It creates the demo APK, boots the named AVD when
the requested device is not already ready, installs the app, runs the smoke
scenario, and writes traces under `<out>/traces/pilot`.

To inspect or customize the generated app before running manually:

```bash
npx zmr-create-android-demo-app --out /tmp/zmr-android-demo
adb install -r /tmp/zmr-android-demo/build/app-debug.apk
zmr run /tmp/zmr-android-demo/.zmr/android-smoke.json \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --trace-dir /tmp/zmr-android-demo/traces/android-demo
```

## React Native And Expo Demo Fixture

Generate a public React Native and Expo app when you need a framework-level
benchmark fixture before collecting timing rows:

```bash
npx zmr-create-react-native-expo-demo-app --out /tmp/zmr-rn-expo-demo
cd /tmp/zmr-rn-expo-demo
bun install
bunx expo start
```

The generated app includes `expo-dev-client`, stable `testID` values,
accessibility labels, an Expo deep-link scheme, and platform-specific ZMR
workflow scenarios under `.zmr/`. After installing a development build on the
target device, run the generated Android or iOS workflow scenario from the app
directory.

## iOS Demo App

For a clean public iOS demo that does not depend on a private app:

```bash
npx zmr-demo-ios --out /tmp/zmr-ios-demo --device booted --cleanup-build-products
```

That command creates the demo app, boots an available simulator when needed,
builds it with Xcode, runs the iOS pilot, and writes trace reports plus
redacted bundles. `--cleanup-build-products` removes generated Xcode
`DerivedData` after the trace reports are written, which keeps repeated demo
runs from filling local disk. To inspect or customize the app before running
the pilot manually:

```bash
npx zmr-create-ios-demo-app --out /tmp/zmr-ios-demo
cd /tmp/zmr-ios-demo
xcodebuild -project ios/ZMRDemo.xcodeproj -scheme ZMRDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build
```

Then boot a simulator and run the pilot wrapper:

```bash
zmr-pilot-gate \
  --ios \
  --ios-app-root /tmp/zmr-ios-demo \
  --ios-app-path /tmp/zmr-ios-demo/DerivedData/Build/Products/Debug-iphonesimulator/ZMRDemo.app \
  --ios-app-id com.example.mobiletest \
  --ios-device booted \
  --ios-shim /tmp/zmr-ios-demo/.zmr/ios-shim \
  --zmr-bin ./node_modules/.bin/zmr
```

When `--ios-shim` is set, the pilot prewarms the XCTest shim before scenario
timing with an `appState` command. Pass `--skip-shim-prewarm` only when
intentionally measuring cold shim startup.

To scaffold the Android shim command into an app repo:

```bash
npx zmr-install-android-shim \
  --app-root . \
  --test-package com.example.mobiletest.test \
  --runner androidx.test.runner.AndroidJUnitRunner \
  --android-module android/app \
  --gradle-file android/app/build.gradle
```

`--android-module` copies the shim into
`android/app/src/androidTest/java/dev/zmr/shim/ZMRShimInstrumentedTest.java`.
`--gradle-file` appends guarded Gradle blocks for `testInstrumentationRunner`,
AndroidX Test runner, JUnit extension, and UI Automator. If the Gradle file
already has a custom `testInstrumentationRunner` and `--runner` is omitted, the
generated `.zmr/android-shim` command uses that runner. Run ZMR with
`--android-shim ./.zmr/android-shim`.

To scaffold the iOS shim command into an app repo:

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

The installer writes:

- `.zmr/ios-shim`
- `.zmr/ensure-ios-shim-target.sh`
- `.zmr/ensure-ios-shim-target.rb`
- `.zmr/ZMRShimUITestCase.swift`
- `.zmr/shims/ios/ZMRShim.swift`
- `.zmr/ZMRShimUITests-Info.plist`
- `.zmr/config.json` `tools.iosShimPath`, creating the config file when needed

Run `.zmr/ensure-ios-shim-target.sh` to create/update the UI test target, add
the Swift files, configure the generated Info.plist, and write a shared scheme.
The helper uses the Ruby `xcodeproj` gem. With `--workspace`, it resolves the
referenced `.xcodeproj` automatically when there is one project, or when exactly
one project contains `--app-target`, or when `--bundle-id` disambiguates
matching app targets. Pass `--project ios/Sample.xcodeproj` explicitly for
still-ambiguous multi-project workspaces or project-only apps.

Run ZMR with `--ios-shim ./.zmr/ios-shim`, or rely on the generated
`tools.iosShimPath` in `.zmr/config.json`.
The generated command caches `build-for-testing` output under
`.zmr/ios-shim-state/`, uses `test-without-building` for selector commands, and
prints the last Xcode log lines when XCTest fails. Set
`ZMR_IOS_SHIM_FORCE_REBUILD=1` after app-side target changes, or
`ZMR_IOS_SHIM_ONESHOT=1` for a cold-start fallback while debugging app-side Xcode
wiring. When `--derived-data-path` points at a ZMR-owned path ending in
`ZMRDerivedData`, the generated command removes that directory before each
`build-for-testing` refresh so copied app checkouts do not reuse stale absolute
Xcode paths. It refuses to delete arbitrary shared DerivedData locations.

## Native Binary Resolution

The npm wrapper resolves `zmr` in this order:

1. `ZMR_BIN=/path/to/zmr`
2. bundled `prebuilds/<platform>-<arch>/zmr`
3. local source build at `zig-out/bin/zmr`

Shipped shell helpers such as `zmr-pilot-gate`, `zmr-demo-ios`, and the pilot
wrappers resolve the runner in this order: `ZMR_BIN`, `PATH` `zmr`, then the
source-checkout `zig-out/bin/zmr` fallback. That keeps app installs on the npm
wrapper path while preserving source-checkout development.
Relative app paths passed to pilot wrappers are resolved from the app directory
where the command was started, not from the installed package directory.

If no binary is found, install Zig and run:

```bash
npm run build:zmr
```

For release publishing, build npm tarballs with:

```bash
npm run pack:npm
```

That command builds release binaries, copies them into `prebuilds/`, and runs `npm pack`.

Tagged GitHub releases publish through npm trusted publishing, not a long-lived
`NPM_TOKEN` secret. Configure the npm package trusted publisher before relying
on the tag workflow:

- Package: `zeno-mobile-runner`
- Provider: GitHub Actions
- Organization or user: `johnmikel`
- Repository: `zeno-mobile-runner`
- Workflow filename: `release.yml`
- Environment name: leave blank unless the release job also declares a GitHub
  deployment environment.
- Allowed actions: `npm publish`

The release workflow already requests `id-token: write`, builds the npm tarball
from the tag, attests the generated release artifacts, uploads the GitHub
release assets, verifies exactly one local npm tarball exists under `./dist/`,
and then publishes that tarball with public access.

Trusted publishing requires a current npm runtime. The tag workflow uses Node
24 so the npm CLI can exchange the GitHub Actions OIDC identity for publish
authorization.

With `npm@11.10.0` or newer, maintainers can also configure the same trust
relationship from an authenticated local shell:

```bash
npm trust list zeno-mobile-runner
npm trust github zeno-mobile-runner \
  --repo johnmikel/zeno-mobile-runner \
  --file release.yml \
  --allow-publish
```

If `npm trust` is not available, update npm or use the package settings page on
npmjs.com. A failed publish with `E404` for an existing package usually means
the trusted-publisher configuration is missing, points at a different GitHub
owner/repository/workflow filename, names an environment that the workflow does
not use, or does not allow `npm publish`.

### Manual publish with passkey or 2FA

Use trusted publishing for normal tagged releases. If you need to publish a
verified local tarball manually, authenticate first:

```bash
npm login --auth-type=web
npm whoami
```

The browser/passkey step must finish before publishing. If `npm whoami` returns
`E401 Unauthorized`, the local machine is not authenticated and `npm publish`
will fail.

Build and verify the package before publishing:

```bash
./scripts/ci-gate.sh
npm pack --dry-run --json
npm run pack:npm
```

Publish the generated tarball from `dist/`:

```bash
npm publish ./dist/zeno-mobile-runner-<version>.tgz --access public
```

If npm returns `EOTP`, the account or organization requires a TOTP-style
one-time password for this publish command. The browser/passkey login flow can
authenticate the local CLI session, but `npm publish` itself only accepts the
publish-time second factor through `--otp`. Prefer the tagged trusted-publishing
workflow for normal releases; otherwise enter the TOTP locally or use a granular
automation token configured to bypass 2FA. Do not send OTPs or tokens through
issue comments, chat, or commit history.

If npm returns `E403` with a two-factor authentication message, the account or
organization requires either a current interactive 2FA challenge or a granular
automation token configured to bypass 2FA. For local passkey accounts, rerun
`npm login --auth-type=web`, complete the passkey challenge in the browser, and
confirm `npm whoami` before retrying the same `npm publish` command.

## Node API

```js
import { runZmr } from "zeno-mobile-runner";

await runZmr([
  "run",
  "--config",
  ".zmr/config.json",
]);
```

Use the CLI for normal app scripts and the JS API for custom toolchains or agent orchestration.
