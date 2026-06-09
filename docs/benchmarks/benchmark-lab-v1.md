# Benchmark Lab v1

Benchmark Lab v1 is the public evidence plan for ZMR. It keeps framework
fixtures, runner adapters, timing modes, and claim boundaries explicit so speed
or reliability statements are reproducible instead of anecdotal.
It is the framework-level evidence map for React Native, Expo, Flutter, native
Android, and native iOS fixtures.

The machine-readable source is
[benchmark-lab-v1.json](benchmark-lab-v1.json). Render or validate it with:

```bash
zmr-benchmark-lab --manifest docs/benchmarks/benchmark-lab-v1.json --format markdown
zmr-benchmark-lab --manifest docs/benchmarks/benchmark-lab-v1.json --format json
```

## Direction

ZMR should compete first where mobile teams already make framework choices:
React Native, Expo, Flutter, native Android, and native iOS. The lab is not a
generic benchmark scoreboard. Each fixture must represent an app workflow a
developer can inspect, build, run, and adapt.

The near-term wedge is agent-native mobile testing: structured observation,
selector-grade actions, trace-first debugging, and reviewable scenario
generation. Benchmarks should prove the local runner path is fast and reliable
without overstating what one fixture demonstrates.

## Fixtures

| Fixture | Framework | Platforms | Status | Scenario |
| --- | --- | --- | --- | --- |
| Generated native iOS workflow | native-ios | iOS | evidence committed | `examples/ios-shim-workflow.json` |
| Generated native Android workflow | native-android | Android | evidence committed | `examples/android-workflow.json` |
| React Native and Expo workflow | react-native-expo | Android, iOS | fixture available | `examples/react-native-expo-workflow.json` |
| Flutter semantics workflow | flutter | Android, iOS | planned | pending |

The first richer iOS evidence pack is
[2026-06-09 iOS simulator workflow comparison](2026-06-09-ios-workflow-comparison.md).
It covers launch, profile entry, catalog scroll, item detail, save, review, and
final-state assertion on the generated native iOS demo app.

The first Android workflow evidence pack is
[2026-06-09 Android emulator workflow](2026-06-09-android-workflow.md). It
records 20 repeated ZMR runs through the platform UIAutomator path.

The React Native/Expo fixture is available through
`scripts/create-react-native-expo-demo-app.sh`. It generates an Expo app with
stable `testID` values, accessibility labels, a deep-link scheme, and matching
Android/iOS ZMR workflow scenarios. Public timing rows are still pending.

## Runner Adapters

| Adapter | Status | Collector | Notes |
| --- | --- | --- | --- |
| ZMR | available | `scripts/benchmark.sh` | Candidate runner for all fixtures. |
| Maestro | evidence committed | `scripts/benchmark-command.sh` | Use YAML flows that match the same visible app state. |
| Appium | partial | `scripts/benchmark-command.sh` | The current public iOS workflow attempt failed while starting WebDriverAgent, so setup needs hardening before timing rows. |
| Detox | planned | `scripts/benchmark-command.sh` | Requires a React Native fixture with native build targets and a project-local test harness. |

Other local runner rows can be collected with the same generic command wrapper,
but public docs should only name tools when a fixture-specific evidence pack is
available or when a status row explains why evidence is missing.

## Modes

| Mode | Meaning |
| --- | --- |
| Cold command | Measures the shell command a user runs, including runner startup. |
| Warm suite | Prepares the app, device, and runner bridge before timed rows, isolating repeated scenario execution. |
| Native floor | Measures a direct platform shim path as diagnostic lower-bound evidence, not a product comparison. |

Cold-command rows are the best default for user-facing claims. Warm-suite rows
are the best way to prove the core execution path can become faster without
hiding setup work. Native-floor rows show where remaining overhead lives.

## Claim Rules

- Use at least 20 candidate rows and 20 baseline rows for public comparison
  evidence.
- Require 100% candidate pass rate and zero candidate failures for any public
  speed claim.
- Compare only rows with the same host class, OS/toolchain, device state, app
  id, app build, scenario, and timing mode.
- Commit sanitized result rows and commands. Do not commit raw trace logs when
  they contain local absolute paths or app data.
- Phrase every result as fixture-specific evidence. Do not describe one lab run
  as a universal product claim.

## Next Slices

1. Add a Flutter semantics fixture that proves app-level Android/iOS support
   without claiming widget-tree automation.
2. Add warm-suite collection so bridge prewarm and repeated execution can be
   measured separately from command startup.
