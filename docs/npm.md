# npm Package

> **Most people do not need this page.** The supported install path is the curl
> installer — see [install.md](install.md). It is framework-neutral and installs
> the same native binary this package wraps.
>
> Read this page if you are **a JavaScript team** pinning ZMR in `package.json`
> so it versions with the app, and wanting the helper bins in
> `node_modules/.bin`.
>
> Publishing a release is a maintainer task — see [releasing.md](releasing.md).
> Demo apps are documented in [demo.md](demo.md).

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

JavaScript app teams should start with `zmr-wizard`, generated smoke scenarios,
and redacted traces. Use pilot and readiness helpers when you need repeated
local evidence for your own app and devices.

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

The standalone CLI has the same non-interactive app-local bootstrap for source
or native-binary installs:

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

## Demo apps

Demo app generation is documented in [demo.md](demo.md), which is the canonical
reference. The npm package exposes the generators as bins:

```bash
npx zmr-demo-android --out /tmp/zmr-android-demo --device emulator-5554 --avd <avd-name>
npx zmr-demo-ios --out /tmp/zmr-ios-demo --device booted --cleanup-build-products
npx zmr-create-react-native-expo-demo-app --out /tmp/zmr-rn-expo-demo
```

See [demo.md](demo.md) for what each generates, the Expo dev-client scenario it
writes, and how to run them end to end.

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

Publishing a release is a maintainer task and lives in
[releasing.md](releasing.md): the pre-tag gate, trusted publishing configuration,
manual publish with passkey or 2FA, and post-publish verification.

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
