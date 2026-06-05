# Features

Zeno Mobile Runner is a local, agent-native mobile test runner for Android,
iOS simulators, and physical iOS devices. It is designed for external agents and normal test files: ZMR
controls devices, exposes typed observations, executes actions, waits for UI
state, and writes deterministic traces. It does not embed an LLM.

## Platform Support

- Android emulators and connected devices through ADB, UI Automator, and an
  optional app-local instrumentation shim.
- Android emulator lifecycle helpers for boot, wait-ready, reset, snapshot
  restore, optional AVD creation, and optional screen recording.
- iOS simulators through `xcrun simctl` for lifecycle, install, launch, deep
  links, screenshots, logs, clear-state-by-uninstall, and device discovery.
- Physical iOS devices through `xcrun devicectl` for discovery, install,
  launch, deep-link launch, clear-state-by-uninstall, and best-effort stop.
- iOS selector actions through an app-local XCTest/XCUIAutomation shim on
  simulators and physical devices.

## App Integration

- npm-first installation with `zeno-mobile-runner` as a dev dependency.
- `npx zmr-wizard` scaffolds `.zmr/config.json`, Android and iOS smoke
  scenarios, optional app package scripts, and `traces/` gitignore rules.
- `zmr init --app` provides the same app-local bootstrap for source and archive
  installs.
- `.zmr/config.json` is schema validated, auto-discovered from app checkouts,
  and overridden by explicit CLI flags.
- Android and iOS shim installers generate app-local commands and source files
  without requiring ZMR state outside `.zmr/`.

## Agent Interface

- JSON-RPC v1 over newline-delimited stdio or localhost TCP.
- MCP stdio server with mobile-native tools for AI agents, including semantic
  snapshots, selector actions, waits, trace polling, and trace export.
- `runner.capabilities`, `device.list`, `session.create`,
  `observe.snapshot`, `observe.semanticSnapshot`, UI actions, waits,
  assertions, live trace events, and redacted trace export.
- TypeScript, Python, Go, Rust, Swift, and Kotlin reference clients.
- Machine-readable CLI output for `zmr version --json`, `zmr schemas --json`,
  `zmr inspect --json`, `zmr doctor --json`, `zmr devices --json`,
  `zmr validate --json`, `zmr run --json`, and `zmr explain --json`.
- Public JSON Schemas for scenarios, snapshots, semantic snapshots, action
  results, trace events, protocol messages, setup diagnostics, and release
  manifests.

## Scenario Execution

- JSON scenarios with launch, stop, clear state, open link, tap, type, erase
  text, hide keyboard, swipe, back/home-equivalent navigation, waits,
  assertions, snapshots, optional steps, conditionals, repeats, sleeps, and
  scroll-until-visible.
- Selector matching for text, text contains, content description, resource id,
  class name, role/class, enabled/visible/selected state, and bounds-aware
  target validation.
- Wait and retry behavior around transient observation failures.
- Import helper for a documented subset of common mobile-flow YAML commands
  into native `.zmr/*.json` scenarios.

## Traces And Diagnostics

- Deterministic trace directories with `trace.json`, `events.jsonl`,
  snapshots, screenshots, UI hierarchy artifacts, logs, timings, action inputs,
  assertion results, and optional Android screen recordings.
- Static trace viewer with timeline, screenshot and UI tree inspection,
  selected node details, payloads, artifact links, and snapshot replay
  controls.
- `zmr explain` summarizes failed traces for humans and agents.
- Redacted `.zmrtrace` export can replace or omit screenshots, omit screen
  recordings, and redact common secrets plus app-configured denylist fields.

## Reliability And Benchmarks

- `zmr-benchmark` repeats ZMR scenarios with pass-rate, failure-count, and p95
  duration gates.
- `zmr-benchmark-command` records normalized rows for app-local baseline
  commands without hardcoding another tool.
- `zmr-compare-benchmarks` compares candidate and baseline rows into generic
  reports.
- `zmr-device-matrix` runs local Android/iOS smoke gates across configured
  devices.
- `zmr-pilot-gate` coordinates Android and iOS app-local pre-release pilot
  checks.

## Shipping Surface

- Release archive builder with checksums, SPDX SBOM, third-party notices,
  generated Homebrew formula, and `RELEASE_MANIFEST.json`.
- npm package tarball generation with bundled prebuilt binaries.
- `zmr-release-readiness` checks repeated app/device evidence for teams that
  want a machine-readable readiness summary.
- Tagged release workflow with artifact attestation and optional npm
  provenance publishing.
- Security, contribution, trace privacy, troubleshooting, protocol versioning,
  app integration, benchmarking, and npm packaging docs.
- Reusable agent skill under `skills/zmr-mobile-testing/`.

## Current Limitations

- Current release status is `0.1.5`, a public developer preview rather than
  a production-stable `1.0.0`.
- Physical iOS log capture is still simulator-first. Physical iOS screenshots
  are available when the XCTest/XCUIAutomation shim is configured.
- Broad cloud device farm certification is out of scope for this preview.
- Public benchmark fixtures are generic. Performance claims for a real app
  should come from equivalent app-local candidate and baseline runs.
- Screenshot and video redaction is conservative: redacted exports can replace
  screenshots with placeholders or omit visual artifacts, but they do not mask
  pixels inside original raw captures.
