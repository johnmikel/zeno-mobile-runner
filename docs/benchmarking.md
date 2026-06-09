# Benchmarking

ZMR benchmark output is intentionally simple: each run appends one JSON object
to `results.jsonl`, and `zmr report` turns that directory into local HTML and
optional JUnit XML artifacts.

## Public Evidence

Public-safe benchmark evidence lives in [docs/benchmarks](benchmarks/README.md).
The first committed pack is
[2026-06-09 iOS simulator demo](benchmarks/2026-06-09-ios-demo.md): 20 repeated
runs of the generated iOS smoke scenario with a 100% pass rate. It is a
single-tool reliability benchmark, not a competitive speed claim.

The first baseline comparison is documented in
[docs/benchmarks](benchmarks/README.md): 20 ZMR runs and 20 baseline runner
runs against the same generated iOS demo app.

Additional public-safe packs in that directory include a second baseline
comparison and a native shim floor. The floor is not a product comparison; it
shows the warmed platform path ZMR can approach after runner and trace overhead
are reduced.

A richer iOS workflow pack is also committed there: 20 ZMR rows and 20 baseline
runner rows against the same generated app build, covering profile entry,
catalog item selection, save, review, and final-state assertion.

Benchmark Lab v1 is the next public evidence layer. It defines framework
fixtures, timing modes, runner-adapter labels, and claim rules in a manifest
that can be validated or rendered with `zmr-benchmark-lab`.

The generated Android workflow now has its first 20-run evidence pack in
[docs/benchmarks](benchmarks/README.md), using the platform UIAutomator path
without the optional Android instrumentation shim.

## Single Tool Benchmark

```bash
scripts/benchmark.sh \
  --zmr examples/android-app-login-smoke.json \
  --device emulator-5554 \
  --runs 10 \
  --trace-root traces/zmr-login \
  --results traces/bench-comparison/results.jsonl \
  --replace \
  --min-pass-rate 100 \
  --max-failures 0 \
  --max-p95-ms 30000
```

The command writes trace artifacts under `--trace-root` and appends normalized
rows to `--results`. Omit `--results` to use `<trace-root>/results.jsonl`.
Omitting `--trace-root` writes under `traces/` in the current app directory,
not inside the installed ZMR package.
Use `--replace` when starting a fresh shared comparison file.
When any gate option is present, `scripts/benchmark_gate.py` reads
`results.jsonl` and exits non-zero if pass rate, failure count, mean duration,
or p95 duration misses the configured threshold.

Generate a report:

```bash
zmr report traces/bench-<timestamp> \
  --out traces/bench-<timestamp>/report.html \
  --junit traces/bench-<timestamp>/junit.xml
```

## Pilot Wrapper

The configurable Android pilot script can run both sample scenarios repeatedly:

```bash
./scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --device emulator-5554 \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --max-p95-ms 30000
```

For lower variance, restore a clean emulator snapshot at the start of the pilot.
Use `--screen-record` when investigating visual flakes:

```bash
./scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --device emulator-5554 \
  --avd Small_Phone \
  --reset-emulator \
  --restore-snapshot zmr-clean \
  --screen-record \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0
```

For `--runs 1`, the script exports normal and redacted `.zmrtrace` bundles.
For `--runs > 1`, the pilot wrappers and generated app reliability scripts
write benchmark directories with HTML and JUnit reports.

The iOS pilot wrapper supports the same repeated-run gates:

```bash
./scripts/run-ios-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app \
  --device booted \
  --ios-shim /path/to/mobile-app/.zmr/ios-shim \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --max-p95-ms 45000
```

For a paired physical iOS device, pass the target type, a concrete device
identifier from `zmr devices`, and a signed device artifact:

```bash
./scripts/run-ios-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-path /path/to/mobile-app/build/Release-iphoneos/Sample.ipa \
  --ios-device-type physical \
  --device <physical-device-id> \
  --ios-shim /path/to/mobile-app/.zmr/ios-shim \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --max-p95-ms 45000
```

When `--ios-shim` is set, the iOS pilot prewarms the app-local XCTest shim with
an `appState` command before timing scenarios. That moves cold
`xcodebuild build-for-testing` work out of the measured run and fails early when
the UI test target is miswired. Use `--skip-shim-prewarm` only when measuring
first-command cold-start behavior.

For release validation on a machine that has both platform builds and targets
ready, `zmr-pilot-gate` runs the Android and iOS pilot wrappers with one
external gate command:

```bash
zmr-pilot-gate \
  --android --ios \
  --android-app-root /path/to/mobile-app \
  --ios-app-root /path/to/mobile-app --ios-app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app \
  --ios-device-type simulator \
  --ios-shim /path/to/mobile-app/.zmr/ios-shim \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0
```

## Reading Results

Benchmark reports include:

- pass rate
- failure count
- mean duration
- p95 duration
- per-run status
- terminal trace status
- failed step index and error when available
- links to each run's `events.jsonl`
- optional JUnit XML with one testcase per benchmark row for CI test reports

Before making public performance claims, run the same scenario repeatedly on a clean emulator image and include the raw `results.jsonl` plus the redacted trace bundle for any failure.

## Compare Against A Baseline

Use `zmr-compare-benchmarks` when a private app repo has benchmark rows from
ZMR and another local runner. The public ZMR repo keeps this generic: rows are
grouped by the `tool` field and no external runner is hardcoded.

Collect ZMR rows into the shared comparison file first:

```bash
zmr-benchmark \
  --zmr .zmr/android-smoke.json \
  --platform android \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --app-build <build-id-or-artifact> \
  --runs 20 \
  --trace-root traces/zmr-login \
  --results traces/bench-comparison/results.jsonl \
  --replace \
  --min-pass-rate 100 \
  --max-failures 0
```

Then collect rows from an existing command-line runner by wrapping it with
`zmr-benchmark-command`. This keeps benchmark collection tool-agnostic while
still capturing per-run stdout/stderr logs and appending to the same results
file:

```bash
zmr-benchmark-command \
  --tool baseline \
  --platform android \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --scenario .zmr/android-smoke.json \
  --app-build <build-id-or-artifact> \
  --runs 20 \
  --trace-root traces/baseline-login \
  --results traces/bench-comparison/results.jsonl \
  -- baseline-runner test .baseline/login.yaml
```

For another runner or command, only change `--tool` and the command after
`--`:

```bash
zmr-benchmark-command \
  --tool runner-b \
  --platform ios \
  --device booted \
  --app-id com.example.mobiletest \
  --scenario .zmr/ios-smoke.json \
  --app-build <build-id-or-artifact> \
  --runs 20 \
  --trace-root traces/runner-b-login \
  --results traces/bench-comparison/results.jsonl \
  -- npm run e2e:ios
```

```bash
zmr-compare-benchmarks \
  --results traces/bench-comparison/results.jsonl \
  --candidate zmr \
  --baseline baseline \
  --min-candidate-pass-rate 100 \
  --max-candidate-failures 0 \
  --min-mean-speedup 1.25 \
  --min-p95-speedup 1.25 \
  --format markdown \
  --out traces/bench-comparison/comparison.md \
  --evidence-out traces/bench-comparison/evidence.jsonl
```

The report includes pass rate, failure count, mean duration, p95 duration, mean
speedup, p95 speedup, candidate/baseline run counts, and whether the rows have
the same benchmark context. The optional gates make CI fail when ZMR is not
reliable enough or not faster than the baseline by the required margin. Only
compare runs collected on the same host, device state, app build, and scenario.
`--evidence-out` requires `--min-candidate-pass-rate`,
`--max-candidate-failures`, `--min-mean-speedup`, and `--min-p95-speedup`, so
the evidence records explicit reliability and speedup thresholds. When
`--evidence-out` is set, a successful comparison also requires at least 20
candidate rows, at least 20 baseline rows, and matching `platform`, `device`,
`appId`, `scenario`, and `appBuild` metadata across candidate and baseline rows.

## Device Matrix

Use `zmr-device-matrix` when CI needs to run one or more scenarios across
multiple local emulators, simulators, or attached devices:

```bash
zmr-device-matrix \
  --matrix .zmr/device-matrix.json \
  --trace-root traces/zmr-matrix \
  --min-pass-rate 100 \
  --max-failures 0
```

Example matrix:

```json
{
  "runs": 2,
  "appId": "com.example.mobiletest",
  "devices": [
    {
      "name": "android-api-35",
      "platform": "android",
      "serial": "emulator-5554",
      "scenario": ".zmr/android-smoke.json",
      "adb": "adb",
      "androidShim": ".zmr/android-shim"
    },
    {
      "name": "ios-18",
      "platform": "ios",
      "iosDeviceType": "simulator",
      "serial": "booted",
      "scenario": ".zmr/ios-smoke.json",
      "xcrun": "xcrun",
      "iosShim": ".zmr/ios-shim"
    },
    {
      "name": "ios-physical",
      "platform": "ios",
      "iosDeviceType": "physical",
      "serial": "<physical-device-id>",
      "scenario": ".zmr/ios-smoke.json",
      "xcrun": "xcrun",
      "iosShim": ".zmr/ios-shim"
    }
  ]
}
```

The command writes `matrix.jsonl` and `summary.json` under the trace root.
Each device/run pair has a normal trace directory, so failures can be inspected
with `zmr explain`, `zmr report`, or the trace viewer.
For iOS rows, omit `iosDeviceType` for the default simulator path or set it to
`physical` to pass `--ios-device-type physical` through to `zmr run`.
