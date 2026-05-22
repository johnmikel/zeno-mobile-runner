# ZMR Product Roadmap

**Goal:** Make Zig Mobile Runner a shippable open-source mobile test runner for AI agents, with Android production support first and iOS production support next.

**Product Thesis:** ZMR should feel like Playwright for mobile agents: fast typed control, rich observations, deterministic traces, and reliable isolation. It should beat shell-driven mobile automation by moving orchestration, waits, retries, traces, and protocol handling into a small Zig core while delegating platform-specific state and interaction to focused native adapters.

**Current State:** `0.1.0` local dev preview. Android pilot flows exist. iOS simulator lifecycle, snapshot, and selector actions are supported through `simctl` plus the XCTest shim. Coverage gate is above 90%. Demo traces can be generated without an emulator.

---

## Definition Of Shippable

ZMR is shippable when a new developer can install it, run the no-device demo, connect an Android emulator, run the Android pilot wrapper, connect a booted iOS simulator, run the iOS smoke wrapper, inspect actionable traces, and integrate an external AI agent through JSON-RPC without manual code changes or hidden setup.

The first public product should be a **developer preview**, not a broad device-farm platform. It should be honest about limitations and strong on repeatability.

## Product Principles

- **Typed agent protocol first:** agents should consume structured snapshots and action results, not parse terminal output.
- **Deterministic traces:** every run should leave enough evidence to debug failure without rerunning immediately.
- **Fast local loop:** fake-device tests, fake demos, and simulator/emulator flows must run locally.
- **Adapter boundaries:** Android, iOS, and future platforms should share runner semantics without sharing platform hacks.
- **No embedded LLM:** ZMR is the control plane; external agents decide.
- **Security by default:** persisted JSON traces redact common secrets; publishing real visual artifacts requires explicit sanitizer work.

## Release Tracks

### Track A: `0.1.x` Dev Preview Hardening

Purpose: make the current repo credible for early users.

Ship criteria:
- `README.md` has install, demo, Android pilot, iOS smoke, app integration, and troubleshooting instructions.
- `docs/protocol.md` documents every JSON-RPC method, params, response shape, and error shape.
- `docs/shipping.md` has one copy-paste release gate.
- `scripts/demo.sh` passes on a clean macOS machine with Zig and no emulator.
- `scripts/coverage.sh` stays at or above 90%.
- Release archives include binary, README, license, protocol docs, demo scenarios, checksum file, and verifier.

Work:
- [x] Add `zmr doctor` to detect Zig, ADB, `xcrun`, emulator/simulator state, Android SDK paths, and missing permissions.
- [x] Add `zmr init` to scaffold a starter scenario.
- [x] Add stable JSON schemas for scenario files, snapshots, action results, and JSON-RPC payloads.
- [x] Add app-local `.zmr/config.json` schema and CLI default loading.
- [x] Add public error code taxonomy instead of exposing raw Zig error names.
- [x] Add install instructions for manual tarball/source install.
- [x] Add release notes template and changelog.

Verification:
- `zig fmt --check build.zig src`
- `bash -n scripts/*.sh tests/*.sh`
- `zig test src/main.zig -target aarch64-macos.15.0`
- `./scripts/demo.sh`
- `./scripts/coverage.sh`
- `./scripts/build-release.sh`

### Track B: Android Production Adapter

Purpose: move Android from useful pilot to product-grade reliability.

Ship criteria:
- Android sample app auth probe and login smoke flows pass repeatedly on a clean emulator.
- Failure traces identify selector misses, active package/activity, visible text, screenshots, logs, and timing.
- A native Android shim can provide hierarchy and interaction when ADB shell/UI Automator is too slow or flaky.
- Runner can install, launch, stop, clear state, deep link, tap, type, swipe, press back, wait, assert, and snapshot reliably.

Work:
- [x] Add Android shim project under `shims/android/`.
- [x] Implement faster hierarchy retrieval through Android accessibility/UI Automator APIs.
- [x] Implement reliable tap/type/swipe through the shim with ADB shell fallback.
- [x] Add app idle/settle detection instead of fixed sleeps where possible.
- [x] Add local emulator helper script for boot, wait-ready, snapshot save/load, and kill.
- [x] Add in-run emulator lifecycle orchestration: create, boot, wait-ready, reset, snapshot restore.
  - [x] Pilot wrapper can reset the target emulator and boot an AVD from a named snapshot.
  - [x] `zmr run` can boot an AVD, restore a snapshot, reset, and wait-ready before scenario execution.
  - [x] `zmr run` can create a missing AVD from an installed Android system image.
- [x] Add Android artifact capture: screenshot, hierarchy, logcat window, package/activity, display metrics, optional screen recording.
  - [x] Pilot wrapper can capture an optional MP4 screen recording for visual flake triage.
  - [x] Snapshots include Android display density when available.
  - [x] Traced Android runs can capture opt-in MP4 screen recordings.
- [x] Add Android flake harness that repeats pilot scenarios and emits pass rate/duration summaries.

Acceptance:
- `examples/android-app-auth-probe.json` passes 20/20 local runs.
- `examples/android-app-login-smoke.json` passes 20/20 local runs.
- Repeated-run reports show stable pass rate, useful failure diagnostics, and acceptable runtime on a clean emulator.
- All Android adapter unit/fake tests pass without an emulator.

### Track C: iOS Production Adapter

Purpose: keep the iOS simulator adapter at agent-grade quality and expand the supported surface deliberately.

Ship criteria:
- iOS supports structured hierarchy, selector matching, tap, type, swipe, press home/back-equivalent navigation, launch, stop, clear state, deep link, screenshot, logs, and snapshots.
- iOS implementation uses XCTest/XCUIAutomation boundaries instead of fragile coordinate-only shelling.
- iOS simulator smoke flow runs with the same scenario semantics as Android where platform concepts overlap.

Work:
- [x] Create app-local XCTest shim source and installer under `shims/ios/`.
- [x] Define a small local shim protocol for hierarchy, element query, tap, type, swipe, keyboard, and app state.
- [x] Add Zig-side iOS shim command and snapshot mapping tests.
- [x] Add Zig-side iOS shim process control for one-command local shim execution.
- [x] Map XCUIElement snapshots into `UiNode` with stable ids, labels, identifiers, values, enabled/visible flags, and bounds.
- [x] Add iOS selector tests using fake shim responses.
- [x] Add real simulator E2E smoke scenario with install/launch/openLink/snapshot/tap/type using the generated XCTest shim.
- [x] Add `examples/ios-dev-client-open-link.json` for Expo dev-client
  simulator flows that need to open a local Metro bundle before selector waits.
- [x] Decide and document iOS clear-state semantics: best-effort app uninstall by bundle id; a missing app is already clean.

Acceptance:
- `examples/ios-smoke.json` passes on a real booted simulator with a test app.
- At least one selector-driven iOS flow passes repeatedly without manual interaction.
- iOS unsupported-action errors disappear for normal UI actions.
- iOS traces include screenshot, hierarchy, logs, active app id, timings, and assertions.

### Track D: Protocol And SDKs

Purpose: make ZMR easy for external AI agents and test harnesses to consume.

Ship criteria:
- JSON-RPC is stable and versioned.
- Clients can generate valid scenarios and validate snapshots using schemas.
- At least one reference client exists.

Work:
- [x] Add `schemas/` with JSON Schema files for scenario, snapshot, action result, trace event, and JSON-RPC messages.
- [x] Add protocol compatibility tests that load fixtures and assert exact response shapes.
- [x] Add a TypeScript reference client package in `clients/typescript/`.
- [x] Add a Python reference client package in `clients/python/`.
- [x] Add a Go reference client package in `clients/go/`.
- [x] Add a Rust reference client package in `clients/rust/`.
- [x] Add streaming observation/event mode for long-running agent sessions.
- [x] Add `trace.export` support for live RPC sessions, not only scenario runs.
- [x] Add semantic protocol version policy.

Acceptance:
- Reference clients can run demo scenarios through stdio.
- Protocol fixtures are committed and checked in CI.
- Breaking changes require protocol version changes and changelog entries.

### Track E: Trace Viewer And Diagnostics

Purpose: make failures easy to understand, not just logged.

Ship criteria:
- A failed run produces a portable trace bundle that a human can inspect quickly.
- Trace viewer shows timeline, screenshots, hierarchy, selected nodes, action inputs, logs, and assertion failures.

Work:
- [x] Define `trace.json` manifest for each run.
- [x] Add trace bundle export as `.zmrtrace` tar/zip.
- [x] Build a local static trace viewer under `viewer/`.
- [x] Add screenshot + UI tree side-by-side inspection.
- [x] Add replay controls for snapshot-linked trace frames.
- [x] Add selector miss diagnostics: nearest text matches, hidden/disabled candidates, offscreen hints.
- [x] Add artifact redaction options for screenshots/XML before sharing.
- [x] Add benchmark report viewer for duration and flake trends. V1: `zmr report`.
- [x] Add local device-matrix runner for multi-device smoke gates before cloud
  device farm certification.

Acceptance:
- `scripts/demo.sh` produces a trace that opens in the viewer.
- Selector timeout traces show enough context to fix the selector without rerunning.
- Public demo traces contain no real app secrets.

### Track F: Scenario Authoring

Purpose: make scenario files easy to create, review, and maintain inside `.zmr/`.

Ship criteria:
- Users can author scenarios by hand, generate them from examples, and keep app-local runner state under `.zmr/`.
- Scenario errors are precise and actionable.

Work:
- [x] Add `zmr validate <scenario.json>` with semantic checks.
- [x] Add line/field-aware parse errors.
- [x] Add `zmr explain <trace-dir>` for a concise failure summary.
- [x] Add examples for auth, onboarding, referral, deep link, and error-state flows.
- [x] Add scenario style guide for resilient selectors and waits.
- [x] Add `zmr import flow-yaml` as a one-time migration helper into native
  `.zmr/*.json` scenarios.

Acceptance:
- [x] Invalid scenarios fail before touching a device.
- Docs explain how to write robust agent-generated scenarios.

### Track G: Packaging, CI, And Distribution

Purpose: make releases boring and reproducible.

Ship criteria:
- CI builds, tests, packages, and publishes checksummed artifacts.
- Users can install on macOS and Linux without building from source.

Work:
- [x] Add GitHub release workflow smoke test against packaged binary.
- [x] Add Homebrew formula.
- [x] Add macOS archive signing helper for credentialed release maintainers.
- [x] Add macOS archive notarization helper for credentialed release maintainers.
- [x] Add Linux x86_64/aarch64 archives with checksum verification docs.
- [x] Add SBOM generation.
- [x] Add dependency/license report.
- [x] Add machine-readable release manifest with artifact digests and sizes.
- [x] Add tagged-release npm tarball generation and provenance publish path.
- [x] Add release checklist that includes demo, coverage, pilot E2E, benchmark, and docs review.
  - [x] Add `scripts/release-gate.sh` so the local release gate is one command.

Acceptance:
- Fresh machine install path is documented and verified.
- `zmr version`, `zmr devices`, and `scripts/demo.sh` work from release artifact.
- Release notes explain platform support and known limitations.

### Track H: Security, Privacy, And Governance

Purpose: make the open-source product safe to use with real apps.

Ship criteria:
- Secret handling is explicit.
- Trace sharing rules are documented.
- Contribution rules are clear.

Work:
- [x] Add `SECURITY.md` with vulnerability reporting process.
- [x] Add `CONTRIBUTING.md` with test, formatting, and coverage expectations.
- [x] Add trace privacy guide.
- [x] Add screenshot/XML redaction strategy.
- [x] Add config controls for log capture and artifact capture.
- [x] Add denylist/allowlist for sensitive node ids and text.
- [x] Add governance note for protocol evolution.

Acceptance:
- No docs suggest sharing real traces without sanitization.
- Security-sensitive defaults are conservative.
- Contributors can run the full local gate.

## Suggested Release Milestones

### `v0.1.0`: Public Dev Preview

Scope:
- Current Android runner.
- iOS lifecycle/snapshot/selector support with `scripts/run-ios-pilot.sh`,
  simulator-first capture, and physical-device lifecycle through `devicectl`.
- Fake demo.
- Public Android and iOS pilot wrappers.
- Release archives and docs.

Exit gate:
- Full acceptance gate passes.
- README and shipping docs match reality.
- Known limitations are explicit.

### `v0.2.0-alpha`: Android Reliability Alpha

Scope:
- `zmr doctor`, `zmr validate`, public schemas.
- Improved Android wait/diagnostics.
- Repeated Android pilot benchmark report.
- Public error taxonomy.

Exit gate:
- Android pilot flows pass repeated local runs.
- Trace failures are actionable.
- Coverage remains above 90%.

### `v0.3.0-alpha`: Native Android Shim

Scope:
- Android shim for hierarchy and interaction.
- ADB fallback retained.
- Repeated benchmark reports with trace diagnostics.

Exit gate:
- Shim path is faster or materially more reliable than shell-only path.
- Android shim has fake and emulator tests.
- Failure modes are cleanly surfaced through JSON-RPC.

### `v0.4.0-alpha`: iOS UI Alpha

Scope:
- XCTest/XCUIAutomation shim.
- Selector-grade iOS tap/type/swipe.
- Real iOS simulator smoke flow.

Exit gate:
- iOS selector flow passes repeated runs.
- Shared scenario semantics work across Android/iOS where possible.
- Unsupported platform differences are documented.

### `v0.5.0-beta`: Agent Integration Beta

Scope:
- TypeScript and Python reference clients.
- Live trace export.
- Streaming observation mode.
- Stable protocol fixtures.

Exit gate:
- External client can run a full scenario over stdio.
- Protocol compatibility tests gate CI.
- Trace bundles are inspectable without local code knowledge.

### `v1.0.0`: Stable Local Runner

Scope:
- Android production support.
- iOS simulator support with documented limitations.
- Trace viewer.
- Release packaging.
- Security/contribution docs.

Exit gate:
- Clean install experience.
- Stable protocol policy.
- Full release checklist passes.
- At least two real app pilot flows are documented with repeated-run results.

## Immediate Next Sprint

The next sprint should focus on making the current preview easier to trust and easier to install.

1. [x] Add `zmr doctor`.
2. [x] Add `zmr validate`.
3. [x] Add JSON schemas for scenarios and snapshots.
4. [x] Expand `docs/protocol.md` with exact request/response examples and error codes.
5. [x] Add release notes/changelog.
6. [x] Run the Android pilot flows repeatedly and record results in `docs/benchmarking.md`. Android V1 acceptance is 20/20 auth probe and 20/20 login smoke on 2026-04-29.

## Open Decisions

- Should the Android native shim be an APK, instrumentation test APK, or long-running local service?
- Should the trace viewer be bundled as static files or shipped as a separate package?
- Should public SDKs live in this repo or separate repos once protocol stabilizes?
- What exact compatibility promise should `protocolVersion` make before `v1.0.0`?
