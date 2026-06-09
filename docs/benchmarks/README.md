# Benchmark Evidence

This directory contains public-safe benchmark evidence collected from
reproducible ZMR demo apps.

Evidence here is intentionally narrow:

- It records the command, platform, runner version, run count, pass rate, and
  duration summary.
- It does not claim ZMR is faster than another tool unless an equivalent
  baseline was collected on the same app build, device state, and scenario.
- Raw local traces are not committed because generated reports and JUnit files
  can include absolute local paths. Public rows are sanitized before commit.

## Evidence Packs

- [2026-06-09 iOS simulator demo](2026-06-09-ios-demo.md): 20 repeated runs of
  the public iOS smoke scenario on a booted simulator.
- [2026-06-09 iOS simulator ZMR vs Maestro comparison](2026-06-09-ios-maestro-comparison.md):
  command-level comparison against Maestro on the same generated iOS demo app.
