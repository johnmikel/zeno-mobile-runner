# Benchmark Evidence

This directory contains public-safe benchmark evidence collected from
reproducible ZMR demo apps. Treat each file as fixture-specific evidence, not a
global performance claim.

Evidence here is intentionally narrow:

- It records the command, platform, runner version, run count, pass rate, and
  duration summary.
- It does not claim ZMR is faster than another tool unless an equivalent
  baseline was collected on the same app build, device state, and scenario.
- Raw local traces are not committed because generated reports and JUnit files
  can include absolute local paths. Public rows are sanitized before commit.
- Product claims should point to the matching evidence pack and its scope.

## Evidence Packs

- [Benchmark Lab v1](benchmark-lab-v1.md): public fixture, timing-mode,
  runner-adapter, and claim-rule plan for framework-level evidence.
- [2026-07-27 iOS determinism](2026-07-27-ios-determinism.md): 20 repeated runs of
  the 17-step React Native/Expo iOS workflow, measuring whether the runner walks
  an identical path rather than how fast it is. All 20 runs emitted the same
  event count.
- [2026-06-09 iOS simulator demo](2026-06-09-ios-demo.md): 20 repeated runs of
  the public iOS smoke scenario on a booted simulator.
- [2026-06-09 iOS simulator ZMR vs Maestro comparison](2026-06-09-ios-maestro-comparison.md):
  command-level comparison against Maestro on the same generated iOS demo app.
- [2026-06-09 iOS simulator ZMR vs Appium comparison](2026-06-09-ios-appium-comparison.md):
  command-level comparison against Appium on the same generated iOS demo app.
- [2026-06-09 iOS simulator workflow comparison](2026-06-09-ios-workflow-comparison.md):
  longer profile, catalog, save, and review workflow on the generated iOS demo
  app.
- [2026-06-09 Android emulator workflow](2026-06-09-android-workflow.md):
  20 repeated ZMR runs of the generated Android workflow demo app.
- React Native/Expo fixture: generated app and ZMR workflow scenarios are
  available through `zmr-create-react-native-expo-demo-app`. Determinism rows
  landed 27 July 2026 (above); comparative timing rows against another runner on
  this fixture are still pending.
- [2026-06-09 iOS simulator XCTest shim floor](2026-06-09-ios-xctest-floor.md):
  native-path floor for the optimized iOS shim-backed smoke flow.
- [2026-06-09 framework baseline status](2026-06-09-framework-baseline-status.md):
  status for Detox, Flutter, Espresso, and other framework-specific baselines.
