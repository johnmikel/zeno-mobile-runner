# Changelog

All notable changes to Zeno Mobile Runner are tracked here.

## Unreleased

### Added

- `zmr test <workspace>` runs every canonical scenario in a directory as one CI
  step: parallel workers, per-attempt retries, and CI sharding
  (`--shard-split` / `--shard-all`), aggregated into a single report published
  as `schemas/test-report.schema.json`. `--dry-run` lists the plan without
  touching a device.
- `zmr record --trace-dir <path>` prepares a trace workspace for a live agent
  session and prints the follow-up commands that turn its evidence into a
  committed scenario.

### Fixed

- `zmr record`'s usage text listed `--trace-dir` as optional while the parser
  required it, so following the help produced `cli.missing_record_trace_dir`.
  The usage now marks it required, matching what the command enforces.
- Canonical scenario actions covering the common mobile-flow vocabulary: `killApp` (alias
  `forceStop`), `clearKeychain`, `grantPermissions`, `setOrientation`,
  `setClipboard` (alias `copyText`), `longPress`/`longPressOn`,
  `doubleTap`/`doubleTapOn`, `pressKey`, `whenNotVisible`, `retry`, `runFlow`,
  and `sleep`'s `waitForAnimationToEnd` alias — implemented across the Android
  shell/uiautomator and iOS XCTest shim backends with typed trace events.
- `launchApp` accepts typed launch `arguments` (string/number/boolean) on both
  platforms; Android resolves the launch activity explicitly and reports
  `app.launch_activity_not_found` when it cannot.
- Selectors accept state fields (`enabled`, `checked`, `focused`, `selected`),
  `index`, bounded-regex fields (`textRegex`, `contentDescRegex`), and
  relational anchors (`above`, `below`, `leftOf`, `rightOf`, `child`,
  `descendant`).
- `app.clearKeychain` on the JSON-RPC surface and `clear_keychain` as an MCP
  tool (27 tools total).
- Scenario metadata fields `env`, `constants`, `labels`, and `source` are
  parsed and schema-validated as **reserved metadata** — the runner does not
  interpolate or act on them yet.
- A canonical action registry: `runner.capabilities` now appends an additive
  `actions` array describing every runner action — stable id, per-surface
  aliases, parameter schema, platforms, mutability, risk class, and trace
  event — published as `schemas/action-registry.schema.json`. Aliases are
  listed only for endpoints each surface actually dispatches; a conformance
  test enforces the parity, and two MCP alias names that pointed at
  nonexistent tools (`wait_until_visible`, `wait_until_not_visible`) were
  corrected to the real `wait_visible`/`wait_not_visible`.

- `zmr import` now reports per-command compatibility: every import returns
  `supportedCount`/`rewrittenCount`/`unsupportedCount`, `--report <path>`
  writes a per-command diagnostics file with source line/column for each
  command (published as `schemas/import-compatibility-report.schema.json`),
  and `--strict` exits non-zero when any command is unsupported. The importer
  vocabulary grows to cover the new canonical actions, `runFlow` nesting with
  a bounded depth, launch arguments, and flow lifecycle hooks.

### Changed

- The 90% coverage floor is now enforced. `scripts/coverage.sh` skips kcov on
  hosted macOS and that was the only job calling it, so the gate never
  actually ran in CI. It now runs as its own job with the skip disabled, and
  a 0-line kcov report is rejected as a measurement failure rather than
  reported as 0% coverage — a blind tool must not be able to masquerade as a
  coverage result in either direction. The coverage build also links libc so
  the suite builds on Linux.
- `scripts/check-test-harness.sh` fails CI when a `src/*_tests.zig` file is
  missing from `src/test_harness.zig`. `zig build test` roots at that
  hand-maintained registry, so a forgotten entry means those tests silently
  never run — the same false-green shape as the build wiring bug.
- MCP `launch_app` now routes through the runner engine's `executeStep`, so a
  launch performs the same settle wait a scenario `launch` step does. Launches
  over MCP take slightly longer and behave identically to scenario runs.

### Fixed

- The generated iOS shim no longer aborts a healthy run with `iOS shim server
  exited before it became ready`. Readiness polling asked `ps` whether the
  process it had just started already showed an `xcodebuild` command line
  naming the test target, but `start_server` records the pid the instant
  `nohup` forks — before the child has exec'd its real argv. On a loaded
  machine the first poll landed in that window and a live server was reported
  as dead. Liveness (`kill -0`) is now separate from identity (the `ps`
  match); the wait loops use liveness, and the identity check stays where it
  belongs, deciding whether a pid file left by an earlier run still names our
  server. This is what made the shim install test flaky in CI.
- `.zmr/config.json` diagnostics no longer disagree with the parser. Both read
  one field table (`src/config_schema.zig`), so a valid `ensureDevice` is no
  longer reported as the unknown field, and a wrong-typed one gets a field
  path. The two hand-copied allow-lists had already drifted.
- The selector `descendant`/`child` ancestor walk is bounded by node count, so
  a malformed snapshot carrying a parent-id cycle fails the match instead of
  hanging the runner.

- `zmr init --app` no longer falls back to the example bundle id
  `com.example.mobiletest` when `--app-id` is omitted. It now reads
  `expo.ios.bundleIdentifier` (then `expo.android.package`) from `app.json`, and
  fails with `init.app_id_required` when neither is present, naming the flag to
  pass and the commands that list what is installed. The old fallback wrote the
  example id into `config.json` and both generated smoke scenarios, so a new
  project that omitted the flag would drive the example app instead of its own —
  and report `status: passed` with a trace full of evidence from that app
  whenever it happened to be installed, which is the case for anyone who tried
  the generated demo first. Found by walking a first run against a fresh
  `create-expo-app` project.
- `zmr-evidence from-zmr` now names source-path failures instead of collapsing
  them to `Evidence command failed` with an empty `issues` array. A trace or
  scenario under `/tmp` on macOS reports `symlink_source_rejected` and says to
  pass the resolved path, and an iOS `.app` bundle passed to `--app-artifact`
  reports `source_not_regular_file` and says to zip it or pass the `.ipa`.
  Non-regular, oversized, and mid-read-modified sources report their own codes
  the same way. The messages stay fixed strings that name only the flag, so the
  CLI still never echoes a caller-supplied path, and unrecognized codes still
  collapse to the generic error.

## 0.2.18 (2026-07-25)

### Added

- Published the Evidence Contract v1 schema, with conformance fixtures covering
  passed, failed, partial, and redacted sources plus the invalid cases that must
  be rejected.
- Added the `zmr-evidence` CLI for validating and packaging release evidence
  bundles. This ships the evidence workflow the docs already described but the
  published 0.2.17 package did not contain.
- Added a Playwright evidence reporter so Playwright runs emit Evidence Contract
  v1 bundles through the same pipeline as ZMR traces.
- Added an adapter that turns hardened ZMR traces into evidence bundles, and
  deterministic evidence fingerprints so the same run always produces the same
  bundle identity.

### Changed

- README now leads with the regression-check value proposition: whether an
  agent's last change broke the app, answered deterministically.
- `zmr doctor` now ends with a `next` line naming the exact run command for
  whichever platform has a device ready, instead of stopping at a bare status.
  `install.sh` points at `zmr init` and `zmr init` points at `zmr doctor`, so the
  onboarding chain previously dead-ended before the first scenario ever ran.
- Generated `.zmr/AGENTS.md` now opens with a `Start Here` section giving the
  three commands to run in order, and calls out that the iOS XCTest shim must be
  installed before any scenario that taps or types. `zmr init` does not install
  it and the smoke scenario passes without it, so the omission stayed invisible
  until the first real scenario, where it surfaces as `selector not found` with
  an empty `visibleTexts` list — indistinguishable from a wrong selector. The
  section also labels the flat `App Commands` list as a lookup index. Agents and first-time readers were previously handed roughly
  forty commands — including 20-run benchmark suites and production
  release-readiness gates — with no indication of which to run first.
- Split the release gate into phases so failures identify the failing stage.

### Fixed

- A failed device command no longer sends the user back to `zmr doctor`. Doctor
  only inspects the host toolchain, so on a first run it passes and then points
  at the run command that just failed, with no way out of the loop. The hint now
  names the cause that explains almost every first-run failure — the app under
  test not being installed on the target device — and gives the command to check
  it on each platform.
- Generated `.zmr/AGENTS.md` no longer emits `zmr-device-matrix` and
  `zmr-pilot-gate` concatenated into one unrunnable line
  (`--max-failures 0zmr-pilot-gate --android ...`). Every `zmr init` since 0.2.x
  produced this; the test that covered it used a bare substring match, which
  passes regardless of what precedes the command, and is now anchored on the
  preceding newline.
- Evidence packaging is now fully deterministic, and evidence source bytes are
  pinned so bundles cannot drift between validation and publication.
- Hardened evidence validation boundaries: reject control characters in evidence
  paths, reject malicious artifact paths, sanitize CLI validation errors, and
  keep evidence CLI process boundaries contained.
- Recover stale evidence publication locks instead of failing the run.
- Corrected Playwright reporter boundaries and retry classification.
- Handle Windows superscript device names.
- The demo recorder now loads the JS bundle before recording, and restores
  pristine demo state so it is re-runnable against a reused `--app-dir`.

## 0.2.17 (2026-06-29)

### Added

- Added a curl-first `install.sh` for framework-neutral native binary installs,
  including OS/arch release archive selection, mandatory `SHA256SUMS`
  verification, dry-run output, and installer coverage in CI/release gates.
- Added a public metadata guard that fails CI/release gates when public docs,
  current branch metadata, remote branch metadata, or tag metadata reintroduce
  unwanted contributor identity strings.
- Added a support matrix covering Android, iPhone, iPad, tvOS, watchOS, cloud
  device farms, and the evidence required before making stronger product
  claims.

### Changed

- Reworked onboarding, agent workflow, app integration, support, readiness,
  troubleshooting, benchmarking, client, shim, schema, and contribution docs
  around DX-friendly setup paths, evidence-first product claims, and
  agent-first mobile verification.
- Repositioned public onboarding around `curl | sh` plus `zmr init --app`,
  with npm documented as the JavaScript-team convenience path instead of the
  default install story.
- MCP tool schemas now expose strict selector shapes, including `stableId`, so
  agents can discover supported selector fields directly from tool metadata.

### Fixed

- Scenario parsing and validation now reject unknown root, step, and selector
  fields instead of silently accepting typos.
- Selectors now reject empty selector objects and support `stableId` matching as
  a live-session fallback from semantic snapshots.

## 0.2.16 (2026-06-25)

### Fixed

- iOS Expo dev-client custom-link recovery now reopens matched project entries
  from observed launcher state instead of reporting blind coordinate taps as
  accepted. Visible but non-hittable launcher rows are tapped by their matched
  frame, keeping recovery selector/state based.
- Generated iOS shim commands now fingerprint shim inputs and preserve reusable
  app/Pods build outputs. Reinstalls reuse unchanged `build-for-testing`
  products, and stale cleanup removes only ZMR shim products/intermediates.

## 0.2.15 (2026-06-24)

### Fixed

- Generated iOS shim commands now remove app-local ZMR-owned derived data paths
  ending in `ZMRDerivedData` before `build-for-testing` refreshes. This avoids
  reusing stale Xcode absolute paths when app checkouts are copied, while
  refusing to delete arbitrary shared DerivedData locations.
- Release gates now verify that `ZMR_VERSION`, `package.json`, `src/version.zig`,
  archive names, and release-smoked binaries agree before publishing.

## 0.2.14 (2026-06-23)

### Added

- Added a first-class `setLocation` scenario action for simulator/emulator
  location control. iOS simulators grant the target app location permission and
  set coordinates through `simctl`; Android emulators best-effort grant runtime
  location permissions before setting emulator geolocation.

## 0.2.13 (2026-06-23)

### Fixed

- iOS native selector waits now cap each XCTest query to the action timeout,
  retry one transient native command failure, and then fall back to semantic
  snapshots with diagnostics. This prevents one stuck XCTest selector query from
  consuming the whole wait budget while still allowing transient native queries
  to recover.
- iOS native selector scrolling now reads the app-frame viewport from the XCTest
  shim before generating swipe coordinates, so native scrolls use iOS point
  dimensions instead of Android fallback dimensions.
- Expo dev-client URL opening now uses URL-aware fallback handling and avoids
  broad static-text enumeration while accepting deep-link chooser prompts.

## 0.2.12 (2026-06-22)

### Fixed

- iOS XCTest-shim command failures now classify generated shim timeout and
  server-exit stderr into typed ZMR errors, so traces and CLI output distinguish
  response timeouts, server-start timeouts, build timeouts, and server exits from
  generic device command failures.
- iOS native selector actions and semantic snapshot extraction now emit
  `started` trace events before entering XCTest, making long-running simulator
  commands visible while they are in flight.
- The generated app-local iOS shim removes completed request files together with
  response files, preventing stale request buildup during long E2E sessions.

## 0.2.11 (2026-06-22)

### Fixed

- iOS `assertHealthy` now retries transient native health-probe failures within
  the assertion timeout and gives XCTest selector queries enough per-probe
  budget to complete on real simulator runs. This avoids falling back to broad
  snapshots after short health-probe timeouts, which could fail otherwise healthy
  Expo dev-client flows.

## 0.2.10 (2026-06-18)

### Fixed

- iOS snapshots now include identifier-bearing `XCUIElementTypeOther` nodes.
  This lets `scrollUntilVisible`, waits, and assertions see React Native
  `testID`/accessibility identifiers that XCTest exposes as `Other` elements
  without flooding traces with unlabeled layout containers.

## 0.2.9 (2026-06-17)

### Fixed

- iOS `assertHealthy` now bounds each native crash/error selector probe
  independently and falls back to the broad snapshot path after transient
  native query timeouts. This prevents healthy but heavy screens from failing
  when one absent overlay selector consumes the whole observation budget.
- The iOS XCTest shim `query` command now uses the fast selector resolver it
  already validates, avoiding broad element enumeration for exact selector
  checks.

## 0.2.8 (2026-06-17)

### Fixed

- iOS native selector waits now cap each XCTest query to the remaining scenario
  step timeout and retry transient query command timeouts. Missing selectors can
  no longer outlive the scenario `timeoutMs` by waiting on the shim's longer
  cold-start command timeout.

## 0.2.7 (2026-06-15)

### Fixed

- `assertHealthy` now uses native iOS selector probes for known crash and error
  overlays before falling back to a broad accessibility snapshot. This avoids
  false `CommandFailed` failures when XCTest broad snapshot enumeration races
  with animated or reloading screens, while preserving direct overlay detection.

## 0.2.6 (2026-06-15)

### Fixed

- Snapshot-based waits and `assertHealthy` now retry transient observation
  `CommandFailed` errors within the step timeout, recording the retry in the
  trace instead of failing immediately. This fixes iOS XCTest shim snapshot
  races observed after an app reached the expected screen.

## 0.2.5 (2026-06-15)

### Fixed

- `whenVisible` now treats visibility-probe command failures as a skipped
  conditional block, recording the skip error in the trace instead of failing
  the scenario. This matches the action's optional-control-flow contract and
  fixes Expo dev-client deep-link flows where the chooser probe can race with
  the app already reaching the target screen.

## 0.2.4 (2026-06-15)

### Fixed

- Extended the iOS simulator `openLink` interruption sweep to cover Expo
  dev-client deep-link chooser sheets that appear more than six seconds after
  `simctl openurl` returns. The sweep remains bounded, but now covers the
  delayed chooser timing observed in app auth smoke runs.

## 0.2.3 (2026-06-15)

### Fixed

- iOS simulator `openLink` now keeps sweeping delayed XCTest shim
  interruptions until the shim reports that an alert or Expo dev-client
  chooser was actually accepted. This fixes Expo dev-client "Deep link
  received" sheets that appear a few seconds after `simctl openurl` returns,
  so app scenarios no longer need launcher-specific timing workarounds.

## 0.2.2 (2026-06-15)

### Fixed

- Migrated the runner to Zig 0.16 process IO and initialized the process IO
  runtime before spawning child commands. This fixes `OutOfMemory` failures
  when commands such as `zmr devices --platform ios --json` or XCTest shim
  launches tried to call `xcrun` through an uninitialized IO context.
- The iOS XCTest shim now resumes an Expo dev-client project from the
  "Development servers" home screen after an `openLink` command. This covers
  the common case where iOS returns to the Expo launcher instead of immediately
  dispatching a pending app deep link, by selecting the app project row rather
  than requiring each app scenario to add launcher-specific workarounds.
- The generated React Native/Expo demo app no longer sets `accessibilityLabel`
  to its own `testID` values. On iOS the label overrides the visible text in
  the accessibility tree, which made every text selector in the generated iOS
  workflow scenario unmatchable against the generated app itself (and modeled
  an accessibility antipattern — screen readers announced "demo_title" instead
  of the title). Found while recording real demo footage; the fixture's text
  waits now pass on iOS.

### Added

- Added `scripts/record-demo-video.sh` (maintainer-only, npm-excluded): a
  reproducible pipeline that records the launch-demo footage from the
  generated Expo demo app — a passing workflow run, a copy-change break with
  the `zmr explain` diagnosis, and the repaired green run — plus the
  storyboard in `docs/demo-video-storyboard.md`.

## 0.2.1 (2026-06-10)

### Fixed

- iOS simulator `openLink` now asks the XCTest shim to accept the SpringBoard
  "Open in <App>?" confirmation for custom URL schemes too, not just
  http/https universal links. Custom schemes are the common Expo dev-client
  deep-link case (`exp+scheme://expo-development-client/...`), and the
  unaccepted dialog previously blocked navigation entirely. The shim's
  `acceptSystemAlert` also gained a single alert-existence probe so the
  best-effort accept stays fast when no dialog appears.
- The generated Expo dev-client scenarios no longer pass when only the Expo
  dev launcher rendered. The old `waitAny` markers also matched launcher
  chrome ("Home", "Continue", "Sign in"), so runs exited green even though
  the app's JS bundle never loaded. The scenarios now wait for the launcher's
  persistent marker to be gone (`waitNotVisible` on "evelopment servers",
  covering both case-sensitive spellings) — passing immediately when the deep
  link navigates, and failing when the launcher is stuck — then assert no
  bundle-error screen ("Unable to load" / "There was a problem loading") is
  visible before `assertHealthy` and `snapshot`. Verified both directions
  against a real Expo SDK 56 app: passes in ~24s with Metro serving, fails
  with a wait timeout when the bundler is down.

## 0.2.0 (2026-06-10)

### Added

- Added a public-safe iOS simulator benchmark evidence pack with 20 repeated
  runs of the generated iOS smoke scenario.
- Added a public-safe iOS simulator baseline runner benchmark comparison on the
  same generated demo app.
- Added a second public-safe iOS baseline comparison plus a native shim floor
  evidence pack for the generated demo app.
- Added a richer public-safe iOS workflow benchmark pack covering profile
  entry, catalog selection, save, review, and final-state assertion on the
  generated demo app.
- Added the first Android workflow benchmark pack for the generated demo app,
  covering 20 repeated UIAutomator-path ZMR runs.
- Added a generated React Native/Expo benchmark fixture with stable `testID`
  values, accessibility labels, deep-link setup, and Android/iOS ZMR workflow
  scenarios.
- The trace viewer loads a served bundle directly from
  `viewer/index.html?bundle=<url>`, so CI artifact links and shared triage can
  open a trace without manual file selection.
- The iOS XCTest shim cold-build timeout is tunable with the
  `ZMR_IOS_SHIM_TIMEOUT_MS` environment variable for slower CI hardware.
- Added a nightly `device-smoke` GitHub Actions workflow that runs the public
  demo apps on a real Android emulator and iOS simulator and uploads traces,
  reports, and redacted bundles as evidence artifacts.
- Added real captured screenshots under `docs/assets/` (trace viewer, device
  screens, CLI failure-diagnosis loop, HTML report) plus
  `scripts/capture-screenshots.sh` to regenerate them from fresh demo runs.
  The assets ship in the repository only, not in the npm package.
- Added Mermaid architecture, verification-loop, trace-lifecycle, and
  trace-to-test diagrams to the README and core docs, and rewrote the README
  around the AI-coding-agent verification workflow.

### Fixed

- `zmr validate`, `zmr report`, `zmr export`, and `zmr import` now accept
  flags before positional arguments, matching the documented command forms,
  and unknown-flag errors print a help hint.
- Generated Android demo scenarios clear app state before launching so
  repeated runs no longer fail on leftover screens from a previous session.

- Fixed generated iOS shim one-shot log file creation on macOS by using a
  portable `mktemp` template with `XXXXXX` at the end.
- Skipped the slow iOS system-open confirmation probe for simulator custom URL
  schemes while keeping it for universal web links.

## 0.1.8 (2026-06-06)

### Changed

- `zmr-release-readiness --target production` now enforces an
  `agent workflow smoke` gate, satisfied by the local release gate or
  structured MCP/JSON-RPC, trace, discovery, validation, and redacted-export
  evidence.

## 0.1.7 (2026-06-06)

### Added

- Added MCP `assert_visible`, `assert_not_visible`, and `assert_healthy` tools
  so MCP agents can use assertion-grade checks without dropping to JSON-RPC.
- Added MCP `erase_text`, `hide_keyboard`, `wait_not_visible`, `wait_any`, and
  `scroll_until_visible` tools so agents can cover common mobile flow control
  without dropping to JSON-RPC.
- Added MCP `install_app`, `launch_app`, `stop_app`, `clear_state`, and
  `swipe` tools so MCP agents can run full app lifecycle and gesture flows.
- Added MCP `open_link`, unscoped `type`, and `press_back` trace events so
  trace-backed discovery sees full simple action sessions from MCP agents.
- Added MCP `trace_events` cursor metadata so MCP agents get `afterSeq`,
  `nextSeq`, and `latestSeq` parity with JSON-RPC trace polling.
- Added JSON-RPC `trace.explain` and MCP `trace_explain` so live agents can
  get the same failure summary, diagnostics, and next commands as
  `zmr explain --json` without leaving the session.
- Added TypeScript, Python, Go, Rust, Swift, and Kotlin trace explanation helpers
  so reference clients can call JSON-RPC `trace.explain` directly.
- Added `zmr explore --from-trace <trace-dir> --out <scenario.json> --goal
  <goal> --include-actions --validate --json` as a review-first CLI
  exploration handoff for agents. It reuses trace-backed discovery, carries the
  goal in JSON, and returns explicit guardrails instead of claiming autonomous
  crawling.
- Added JSON-RPC `trace.explore` and MCP `trace_explore` so live agents can
  generate the same goal-carrying, review-required scenario draft without
  leaving the active traced session.
- Added TypeScript `exploreTrace()`, Python `explore_trace()`, Go
  `ExploreTrace()`, Rust `explore_trace()`, Swift `exploreTrace()`, and Kotlin
  `exploreTrace()` helpers for the new JSON-RPC exploration method.
- Added trace discovery auditing: `trace.discover` records a `trace.discover` event
  for JSON-RPC and MCP agent sessions so generated scenario candidates are
  visible in the trace.
- Added `zmr draft --from-trace <trace-dir> --out <scenario.json> --json` for
  trace-backed, review-first scenario drafting. The command reads the latest
  semantic snapshot artifact and writes a conservative surface-smoke scenario
  with `launch`, `snapshot`, and stable `assertVisible` checks only.
- Added `zmr draft --include-actions` so agent sessions can turn supported
  successful trace actions into reviewable replay drafts while unsupported
  events are skipped with warnings instead of guessed.
- Added `zmr discover --from-trace <trace-dir> --out <scenario.json>
  --include-actions --validate --json` as the first-class trace-to-test handoff
  for agents. It reuses the review-first draft engine, can validate the
  generated scenario before returning, and reports `mode: "discover"` for
  tooling.
- Added JSON-RPC `trace.discover` and MCP `trace_discover` so live agents can
  generate the same trace-backed scenario candidate without shelling out to the
  CLI after a session.
- Added JSON-RPC `scenario.validate` and MCP `scenario_validate` so agents can
  validate generated or edited scenario files in-band before running them.
- Added TypeScript `discoverTrace()` and Python `discover_trace()` helpers for
  the new JSON-RPC discovery method.
- Added TypeScript `validateScenario()` and Python `validate_scenario()`
  helpers for in-band scenario validation.
- Added Go `DiscoverTrace()` and `ValidateScenario()` helpers so Go agents can
  use the same trace-to-test and validation loop without raw JSON-RPC calls.
- Added Rust `discover_trace()` and `validate_scenario()` helpers so Rust
  agents and host-side harnesses can use the same trace-to-test and validation
  loop without raw JSON-RPC calls.
- Added Swift `discoverTrace()` and `validateScenario()` helpers so macOS
  host-side agents can use the same trace-to-test and validation loop without
  raw JSON-RPC calls.
- Added Kotlin `discoverTrace()` and `validateScenario()` helpers plus an
  always-run source parity test so Kotlin host-side agents keep the same
  trace-to-test and validation entry points even on machines without Gradle.
- Added a trace-backed discovery handoff to traced `zmr run --json`
  `nextCommands`, so agents can generate a reviewable replay scenario directly
  from a run summary.
- Added `zmr run --discover-out <scenario.json> --json` so traced runs can
  write and validate the reviewable replay scenario before returning the run
  summary.
- Added replay coverage metadata to `zmr draft --json`, `zmr discover --json`,
  and embedded run discovery output so agents can see how many trace actions
  became replay steps and how many were skipped.
- Added coordinate-complete `ui.swipe` trace replay so JSON-RPC sessions and
  traced `zmr run` flows can carry swipes into generated replay scenarios
  without guessing missing coordinates.
- Added traced `pressBack` replay parity for `zmr run`, so generated replay
  scenarios preserve back-navigation steps from ordinary scenario runs.
- Added direction and timeout preserving `scrollUntilVisible` trace replay so
  generated scenarios keep the original scroll intent from traced runs and
  live agent sessions.
- Added selector and timeout preserving wait replay so trace-backed discovery
  keeps successful `waitVisible`, `waitNotVisible`, and matched `waitAny`
  steps from ordinary scenario runs.
- Added timeout context to native selector wait trace events and timeout
  diagnostics, so real-device shim traces carry the same timing evidence as
  snapshot-backed waits.
- Added replay metadata for successful `assertNoneVisible` and timed
  `assertHealthy` trace events, so generated replay scenarios preserve
  assertion intent instead of dropping those checks.
- Added selector and timeout preserving `assertVisible` and `assertNotVisible`
  replay so trace-backed discovery keeps assertion intent distinct from waits.
- Added `zmr report --junit <report.xml>` so trace directories and benchmark
  result directories can produce CI-friendly JUnit XML alongside HTML reports.
- Updated generated app report and reliability scripts to write `junit.xml`
  beside `report.html` by default.
- Updated Android and iOS pilot wrappers to emit `junit.xml` beside every
  generated `report.html`.
- Updated CI and tagged release workflows to retain generated run evidence as
  GitHub Actions artifacts: CI keeps traces, coverage output, and the built
  `zmr` binary for 14 days, while releases keep the generated `dist/` bundle
  for 30 days.
- Updated artifact upload workflow steps to a Node 24-compatible
  `actions/upload-artifact` major so CI stays ahead of GitHub Actions runtime
  deprecations.
- Added `schemas/draft-output.schema.json` and included it in `zmr schemas
  --json`.
- Added `schemas/discover-output.schema.json` and included it in `zmr schemas
  --json`.

## 0.1.6 (2026-06-05)

### Added

- Added `zmr inspect --json` as a read-only app and agent handoff command. It
  reports app-local config status, `.zmr/AGENTS.md` presence, configured
  Android/iOS smoke scenarios, safe next commands, and explicit claim limits
  without launching devices or writing tests.
- Added `schemas/inspect-output.schema.json` and included it in `zmr schemas
  --json` for generated clients and agent tooling.

### Changed

- Tagged release workflow now uses npm trusted publishing instead of a
  long-lived `NPM_TOKEN` secret.
- Fixed the tagged release publish step so npm receives the generated local
  tarball instead of interpreting the path as a GitHub package spec.
- Updated the tagged release workflow to Node 24 so npm trusted publishing can
  use the GitHub Actions OIDC identity with a current npm CLI.
- Added a public production-readiness checklist that ties release, framework,
  reliability, trace privacy, and agent workflow claims to concrete evidence.

## 0.1.3 (2026-06-03)

### Fixed

- Hardened the iOS XCTest shim for clean Expo/RN prebuilds by giving cold
  `build-for-testing` runs a 90-minute default timeout with explicit progress
  logging.
- Made iOS simulator `app.stop` idempotent when `simctl terminate` reports the
  app is already stopped.
- Improved selector actions so native `selector.not_found` and
  `selector.not_hittable` responses return a typed unavailable result instead
  of failing the command parser.
- Reused a resolved booted simulator UDID across `build-for-testing` and
  `test-without-building`, and cleared stale shim PID/server/destination state
  when reinstalling the app-local shim.
- Avoided stale XCTest snapshot elements and replaced broad selector scans with
  native predicate-based fallback queries.

## 0.1.2 (2026-05-28)

### Fixed

- Fixed the npm postinstall build path so packages installed without prebuilt
  binaries build a runnable `zmr` executable from source.
- Moved the internal Zig test harness out of the executable entrypoint so the
  published npm package can omit test-only source files safely.

## 0.1.1 (2026-05-28)

### Changed

- Reworked the public README around npm installation, React Native, Expo,
  Flutter, native Android/iOS, and AI-agent mobile testing.
- Demoted language clients in the public positioning so TypeScript and Python
  are presented as common starting points, while Go, Rust, Swift, and Kotlin
  remain reference integrations.
- Removed release process, readiness, and positioning notes from the public
  documentation tree.
- Added a framework guide for React Native selectors, Expo dev-client setup, and
  Flutter platform-level semantics support.

## 0.1.0 (2026-05-22)

### Added

- `zmr doctor` for local environment diagnostics across Zig, ADB, Android devices, `xcrun`, and iOS simulators.
- `zmr init` for scaffolding a starter scenario.
- `zmr validate <scenario.json>` for preflight scenario validation without touching a device.
- Public JSON Schemas under `schemas/` for scenarios, snapshots, action results, trace events, and JSON-RPC messages.
- `schemas/validate-output.schema.json` for the machine-readable `zmr validate --json` preflight result.
- Stable public error-code mapping for CLI/protocol-facing failures.
- Top-level CLI failures now print stable `error[code]` messages instead of
  Zig stack traces.
- JSON-RPC execution errors now include `publicCode` when a stable code is available.
- Demo documentation in `docs/demo.md`.
- Machine-readable protocol compatibility metadata in `runner.capabilities`.
- Go and Rust reference JSON-RPC clients with fake-session examples and CI
  coverage.
- Go and Rust clients now expose the full core mobile control surface for
  session lifecycle, app lifecycle, UI actions, waits, assertions, semantic
  snapshots, trace polling, and trace export.
- Go and Rust fake-session examples now launch `zmr serve` with the fake-device
  backend and exercise agent-style open-link, wait, tap, type, assertion,
  snapshot, trace polling, and redacted export flows.
- `zmr-benchmark-command` for timing app-local baseline commands and writing
  normalized rows that can be compared with ZMR benchmark results.
- `zmr-benchmark --results` / `--replace` for appending ZMR runs to a shared
  comparison JSONL file.
- `zmr-compare-benchmarks` gates for candidate pass rate, failure count, mean
  speedup, and p95 speedup.
- Feature catalog in `FEATURES.md`.
- Architecture decision records under `docs/adr/`.
- AI agent integration guide in `docs/ai-agents.md`.
- Simplified public README plus dedicated scenario authoring and client docs.
- Client installation guide for npm, Homebrew, TypeScript, Python, Go, Rust,
  Swift, and Kotlin.
- SwiftPM and Kotlin/JVM reference clients for host-side native mobile team
  automation.
- Swift and Kotlin fake-session demo entry points now run from `scripts/demo.sh`
  and export redacted traces alongside the TypeScript, Python, Go, and Rust
  client demos.
- Kotlin/JVM client calls now reject JSON-RPC error responses instead of
  returning error payloads as successful raw strings.
- The npm package keeps `zmr-release-readiness` for app-local evidence checks
  but keeps source-only helper scripts out of the app install command surface.
- `zmr-release-readiness` / `scripts/release-readiness.sh` now converts
  app-local `evidence.jsonl` into explicit readiness summaries with missing
  evidence listed for agents.
- `schemas/release-readiness-output.schema.json` and `zmr schemas --json`
  metadata for agent-readable evidence output.
- `zmr-release-readiness --json` now includes `nextSteps` commands for missing
  evidence so agents can continue blocked checks without scraping text.
- `zmr-release-readiness --json` now includes per-requirement status rows so
  agents can see which evidence was satisfied, missing, failed, planned, or
  insufficient.
- `zmr-compare-benchmarks` now supports `--evidence-out` so benchmark
  comparisons can append structured evidence directly.
- `zmr-assert-ios-physical-ready` now accepts `--xcrun`, and
  `zmr-pilot-gate` forwards custom `--xcrun` paths into the physical iOS
  readiness preflight as well as the iOS pilot run.
- `zmr-pilot-gate` now accepts `--zmr-bin` and forwards the explicit runner
  binary to Android, iOS, and physical iOS readiness checks for app-local CI.
- `zmr-pilot-gate` now records structured app-root and iOS app-artifact
  evidence, and iOS pilots require `--ios-app-root` so production-readiness
  evidence names the tested app source and build.
- Local readiness evidence now runs the generated public iOS simulator demo
  five times by default, with `--local-ios-demo-runs <n>` for explicit run-count
  tuning.
- Local readiness evidence can now run the generated public Android
  emulator demo with `--local-android-avd <name>`, `--local-android-device`,
  and `--local-android-demo-runs <n>`.
- `scripts/assert-ios-physical-ready.sh` now makes hardware readiness mode fail
  unless the requested physical iOS device is present and ready, with retries
  for transient CoreDevice list failures.
- `zmr doctor` now keeps physical iOS checks actionable on multi-device
  machines by reporting disconnected/unavailable device counts even when one
  physical device is ready.
- `zmr doctor --json` now emits structured `count` and `readyCount` fields for
  Android, iOS simulator, and physical iOS device checks so agents do not need
  to parse human-readable detail strings.
- Physical iOS discovery and lifecycle support through `xcrun devicectl`,
  including install, launch, deep-link launch, clear-state uninstall, and
  best-effort stop.
- GitHub issue templates for bug reports and feature requests.
- Reusable `zmr-mobile-testing` agent skill under `skills/`.
- `trace.events` JSON-RPC cursor polling for live trace events during long-running agent sessions.
- `observe.semanticSnapshot` JSON-RPC output with normalized roles, stable
  selectors, center bounds, visible text summary, and recommended actions for
  AI agents.
- `zmr mcp` stdio server for MCP-capable agents, exposing mobile-specific tools
  for semantic snapshots, selector actions, waits, live trace polling, and
  redacted trace export.
- `schemas/semantic-snapshot.schema.json` for the machine-readable semantic
  observation contract.
- `src/cli_output.zig` as the focused home for CLI JSON/text output
  serialization, keeping command routing easier to inspect.
- `src/runner_events.zig` as the focused home for runner trace events and
  selector diagnostics, keeping scenario execution easier to follow.
- `src/json_rpc_protocol.zig` as the focused home for JSON-RPC wire-format
  responses, keeping agent-facing dispatch easier to review.
- `src/trace_summary.zig` as the focused home for reading `trace.json` plus
  `events.jsonl`, keeping run-output and explain-output diagnostics consistent
  for agents.
- `src/ios_devices.zig` as the focused home for iOS simulator and physical
  device discovery plus `xcrun` command construction, keeping `src/ios.zig`
  focused on app lifecycle and UI actions.
- `src/android_shell.zig` as the focused home for Android shell action and
  deep-link intent argument construction, keeping `src/android.zig` focused on
  device orchestration.
- `src/json_fields.zig` as the shared typed JSON field reader for scenario and
  JSON-RPC parameter parsing, reducing duplicated low-level parser code.
- `src/runner_diagnostics.zig` as the focused selector diagnostic JSON builder,
  keeping `src/runner_events.zig` focused on trace event recording.
- `src/trace_summary_diagnostic.zig` as the focused trace diagnostic event
  model and JSON serializer, keeping `src/trace_summary.zig` focused on
  reading trace manifests and event streams.
- `src/run_options.zig` as the focused home for `zmr run`, `zmr serve`, and
  `zmr mcp` option/config precedence, keeping `src/main.zig` closer to a thin
  command router.
- `src/config_paths.zig` as the focused home for app-local `.zmr/config.json`
  loading and relative path resolution across `doctor`, `run`, `serve`, and
  `mcp`.
- `src/runner_native.zig` as the focused home for native selector action
  dispatch and trace events, keeping `src/runner.zig` focused on scenario
  orchestration and snapshot fallback behavior.
- `src/cli_devices.zig` as the focused home for the `zmr devices` command,
  keeping `src/main.zig` closer to command routing.
- `src/cli_doctor.zig` as the focused home for `zmr doctor` flag parsing,
  app-local config resolution, and output dispatch, keeping setup diagnostics
  easier to review.
- `src/cli_validate.zig` as the focused home for `zmr validate` parsing and
  result output, keeping the top-level command router smaller.
- `src/cli_info.zig` as the focused home for `zmr version` and `zmr schemas`
  output, keeping metadata commands out of the top-level router.
- `src/cli_init.zig` as the focused home for `zmr init` app-local and
  single-scenario scaffolding, keeping first-run DX code easier to inspect.
- `src/cli_import.zig` as the focused home for `zmr import flow-yaml`
  migration parsing and dispatch, keeping onboarding/migration code out of the
  top-level router.
- `src/cli_trace.zig` as the focused home for `zmr report`, `zmr explain`, and
  `zmr export` parsing and dispatch, keeping trace-inspection commands out of
  the top-level router.
- `src/cli_serve.zig` as the focused home for `zmr serve` and `zmr mcp`
  parsing, app-local config resolution, trace setup, and Android/iOS server
  dispatch, keeping agent server startup out of the top-level router.
- `src/cli_run.zig` as the focused home for `zmr run` parsing, app-local
  config resolution, emulator preflight, trace setup, and Android/iOS scenario
  dispatch, leaving `src/main.zig` as a thin command router.
- `src/main_tests.zig` and `src/test_harness.zig` as the focused homes for
  command-router integration coverage and module test discovery, keeping
  `src/main.zig` as a runtime-only router.
- `src/runner_tests.zig` as the focused home for runner orchestration tests,
  keeping `src/runner.zig` focused on the runtime scenario engine.
- `src/trace_tests.zig` as the focused home for trace serialization,
  redaction, artifact, and manifest tests, keeping `src/trace.zig` focused on
  trace writing behavior.
- `src/android_tests.zig` as the focused home for Android adapter parser,
  command construction, trace artifact, and native shim tests, keeping
  `src/android.zig` focused on ADB/device behavior.
- `src/ios_tests.zig` as the focused home for iOS simulator, physical device,
  screenshot, open-link, and XCTest-shim behavior tests, keeping `src/ios.zig`
  focused on simctl/devicectl and shim orchestration.
- `src/config_tests.zig` as the focused home for `.zmr/config.json` parser,
  diagnostics, artifact controls, and redaction controls, keeping
  `src/config.zig` focused on the app-local config runtime contract.
- `src/doctor_tests.zig` as the focused home for setup diagnostics, remediation
  hints, fake-device checks, and smoke-scenario validation coverage, keeping
  `src/doctor.zig` focused on environment probe behavior.
- `src/doctor_hints.zig` as the focused home for setup error-code and
  remediation-hint policy, keeping `src/doctor.zig` focused on running probes
  and assembling checks.
- `src/bundle_tests.zig` as the focused home for trace archive, redaction, and
  artifact omission coverage, keeping `src/bundle.zig` focused on deterministic
  `.zmrtrace` packaging behavior.
- `src/scenario_tests.zig` as the focused home for scenario DSL parsing,
  agent-grade flow primitive, simple action, and malformed-input coverage,
  keeping `src/scenario.zig` focused on the runtime scenario parser.
- `src/report_tests.zig` as the focused home for HTML report and trace
  explanation coverage, keeping `src/report.zig` focused on report rendering
  behavior used by local demos and agent diagnostics.
- `src/report_html.zig` as the focused home for shared HTML escaping,
  document framing, file writing, and artifact links used by trace and
  benchmark reports.
- `src/importer_tests.zig` as the focused home for flow-YAML migration
  coverage through the public file import API, keeping `src/importer.zig`
  focused on migration parsing and JSON emission internals.
- `src/validation_tests.zig` as the focused home for scenario preflight and
  source-location diagnostics coverage, keeping `src/validation.zig` focused
  on public validation result construction.
- `src/command_tests.zig` as the focused home for command execution timeout
  and ADB escaping coverage, keeping `src/command.zig` focused on subprocess
  and shell-argument behavior.
- `src/trace_summary_tests.zig` as the focused home for partial visual capture
  explanation coverage, keeping `src/trace_summary.zig` focused on trace
  summary parsing for CLI and agent diagnostics.
- `src/semantic_tests.zig` as the focused home for agent semantic snapshot
  role/action coverage, keeping `src/semantic.zig` focused on observation
  normalization.
- Focused test modules for small public contracts: `src/types_tests.zig`,
  `src/selector_tests.zig`, `src/health_tests.zig`,
  `src/device_registry_tests.zig`, `src/schema_registry_tests.zig`, and
  `src/version_tests.zig`, keeping these runtime modules lean and easier to
  audit.
- `src/uiautomator_tests.zig`, `src/fake_device_tests.zig`, and
  `src/android_emulator_tests.zig` as focused homes for parser, fake-device,
  and emulator-preflight coverage, keeping Android runtime helpers easier to
  review before release pilots.
- Focused CLI parser test modules for `doctor`, `import`, `info`, `init`,
  `trace`, and `validate`, keeping command entry modules shorter while
  preserving parse-error coverage.
- Focused parser test modules for `zmr run` and `zmr serve` startup options,
  keeping the primary execution and agent-server command modules focused on
  config resolution and runtime dispatch.
- Focused public-contract test modules for config path resolution, run/serve
  option precedence, JSON-RPC protocol metadata, and CLI output helpers.
- Focused public-contract test modules for error classification, iOS device
  discovery parsing, runner event diagnostics, and `.zmr` scaffold generation.
- `src/ios_shim_tests.zig` as the focused home for XCTest shim command,
  selector, screenshot, snapshot, and response parsing contracts, keeping
  `src/ios_shim.zig` focused on the shim protocol implementation.
- `src/json_rpc_tests.zig` as the focused home for JSON-RPC dispatch,
  live-trace, event-stream, and protocol-fixture tests.
- `src/json_rpc_methods.zig` now owns JSON-RPC method execution while
  `src/json_rpc.zig` stays focused on stdio/tcp transport and request framing.
- JSON-RPC method dispatch is now grouped by protocol area: core/session,
  app lifecycle, observation, UI actions, waits, assertions, and trace tools.
  This keeps the agent-facing server surface easier to audit before release.
- `src/json_rpc_params.zig` now owns JSON-RPC parameter parsing for selectors,
  primitive fields, directions, and defaults, keeping method dispatch focused
  on protocol behavior.
- `src/json_rpc_trace.zig` now owns JSON-RPC live trace event streaming and
  simple trace payload helpers, keeping method dispatch focused on routing.
- `src/json_rpc_observation.zig` now owns JSON-RPC snapshot response
  serialization and trace artifact events, keeping method dispatch focused on
  observation routing.
- `src/mcp_protocol.zig` now owns MCP response framing, initialization output,
  errors, and tool catalog JSON, keeping the MCP server focused on tool
  execution for agent integrations.
- `src/mcp_trace.zig` now owns MCP trace-event polling and redacted trace
  export tool responses, keeping the MCP server focused on dispatching
  agent-requested tools.
- `src/runner_waits.zig` now owns selector wait, assertion, and scroll polling
  behavior, while `src/runner.zig` stays focused on scenario execution and UI
  actions.
- `src/runner_actions.zig` now owns selector tap/type/erase behavior, keeping
  action targeting separate from high-level scenario orchestration.
- `src/trace_json.zig` now owns trace JSON serialization and redaction rules,
  leaving `src/trace.zig` focused on trace writing and manifest lifecycle.
- `src/bundle_tar.zig` now owns deterministic tar entry writing, leaving
  `src/bundle.zig` focused on trace bundle entry selection and redaction policy.
- `src/importer_model.zig` and `src/importer_json.zig` now own flow-import
  intermediate types and scenario JSON emission, leaving `src/importer.zig`
  focused on translating source flow syntax.
- `src/config_diagnostics.zig` now owns `.zmr/config.json` field-path
  diagnostics, leaving `src/config.zig` focused on parsing the runtime config
  contract.
- `src/android_device_info.zig` now owns Android device listing plus window,
  viewport, and density parsers, leaving `src/android.zig` focused on ADB app
  lifecycle, actions, screenshots, and shim orchestration.
- `src/android_screen_recording.zig` now owns Android screenrecord process
  lifecycle and trace artifact pulling, leaving `src/android.zig` focused on
  app/device orchestration.
- `src/ios_lifecycle.zig` now owns physical iOS `devicectl` install, launch,
  stop, and uninstall helpers, leaving `src/ios.zig` focused on simulator
  lifecycle, XCTest shim orchestration, screenshots, and snapshots.
- `src/ios_snapshot.zig` now owns PNG viewport parsing for screenshot
  artifacts, keeping iOS adapter snapshot orchestration easier to review.
- `scripts/coverage.sh` now guards `kcov` with
  `ZMR_KCOV_TIMEOUT_SECONDS`, so release gates fail fast instead of hanging on
  macOS tracing authorization stalls.
- Field, line, and column diagnostics in `zmr validate --json` for invalid scenarios.
- Scenario authoring guide plus onboarding, referral deep-link, and error-state templates.
- Adapter-level settle hook after mutating scenario actions, with native shim idle support and shell fallback.
- Trace viewer side-by-side screenshot and UI tree inspection with selectable node details.
- App-specific trace redaction denylist/allowlist controls for persisted node text, resource ids, and trace events.
- Release builds now generate SPDX SBOM and third-party license notice artifacts.
- Release builds now generate a Homebrew formula with per-platform checksums.
- Release builds now generate `RELEASE_MANIFEST.json`, a machine-readable
  artifact inventory with sizes and SHA-256 digests.
- Release integrity verification now validates generated archives, metadata
  files, `RELEASE_MANIFEST.json`, and `SHA256SUMS` before packaged binary
  smoke tests.
- Tagged release workflow now publishes GitHub artifact attestation for release
  archives and metadata.
- Tagged release workflow now builds the npm tarball, attests it, uploads it
  with the release assets, and can publish with npm provenance from supported
  CI.
- Release manifests and checksum verification now include generated npm
  tarballs when present.
- Native selector wait timeouts now capture one final snapshot when possible,
  giving iOS XCTest-shim failures the same visible text and candidate
  diagnostics as snapshot-based waits.
- Added `scripts/sign-macos-release.sh` for credentialed release users to sign
  macOS release archives and refresh checksums before upload.
- Added `scripts/notarize-macos-release.sh` for credentialed release users to
  submit signed macOS archives to Apple notarytool, persist receipts, and
  refresh release metadata before upload.
- iOS simulator `clearState` is now idempotent when the app is already uninstalled and documented as best-effort uninstall by bundle id.
- Android pilot wrapper can reset the emulator and boot from a named snapshot before running smoke flows.
- Android pilot wrapper can capture an optional MP4 screen recording for visual flake triage.
- Android and iOS pilot wrappers now run early setup preflights and print
  structured `zmr doctor --json` diagnostics for missing devices/simulators.
- Android pilot wrapper `--adb` overrides now propagate into the underlying
  `zmr run` and repeated-run benchmark calls.
- Added `scripts/pilot-gate.sh` and the `zmr-pilot-gate` npm bin for the
  external Android+iOS pre-release pilot gate.
- `zmr-pilot-gate` now resolves app-local relative paths from the caller's
  checkout, including when invoked through npm's `node_modules/.bin` symlink.
- The iOS shim installer now resolves multi-project workspaces by matching
  `--bundle-id` when multiple projects contain the same `--app-target`.
- The iOS shim installer now patches app-local `.zmr/config.json` with
  `tools.iosShimPath` so selector-grade iOS runs use the installed shim by
  default.
- `zmr init --app`, `zmr-init`, and `zmr-wizard --package-json` now scaffold
  a `zmr:pilot` / `scripts.pilotGate` command for external release pilots.
- `zmr init --app`, `zmr-init`, and `zmr-wizard` now scaffold
  `.zmr/device-matrix.json` plus `zmr:matrix` / `scripts.matrix` so the
  generated app-local setup can run local Android/iOS matrix gates immediately.
- `zmr-wizard --expo-dev-client-scheme` now scaffolds Android and iOS Expo
  development-build open-link smoke scenarios and package scripts.
- Scenario JSON now supports `assertNoneVisible` for app-wide crash/error
  guards after navigation or sign-in steps.
- Scenario JSON now supports zero-config `assertHealthy` guards for common
  mobile redboxes, crash overlays, and development-client load failures.
- Health guard policy now lives in a focused `src/health.zig` module so
  contributors can extend default mobile error detection without editing runner
  orchestration.
- Public schema discovery now lives in `src/schema_registry.zig`, keeping CLI
  command dispatch smaller while preserving `zmr schemas --json` output.
- Device readiness and `zmr devices --json` serialization now live in
  `src/device_registry.zig`, so CLI and JSON-RPC agents share one portable
  readiness policy for Android, iOS simulators, and physical iOS devices.
- `zmr init` and `zmr init --app` now scaffold `assertHealthy` into starter
  smoke scenarios so source/archive installs get the same safer default as the
  npm wizard.
- JSON-RPC and all reference clients now expose `assert.healthy` /
  `assertHealthy` so agents can run the same health guard outside scenario
  files.
- Swift and Kotlin clients now include fake-server package tests that exercise
  the JSON-RPC session path and `assert.healthy` helper.
- Android snapshots now include display density DPI when available.
- Traced Android `zmr run` sessions can capture an opt-in `screenrecord.mp4`, and redacted exports omit screen recordings.
- Redacted `.zmrtrace` exports now keep replayable screenshot artifact paths by replacing PNG screenshots with safe placeholder images.
- `zmr export --redact --omit-screenshots` and JSON-RPC
  `trace.export` `omitScreenshots` can omit screenshot artifacts entirely from
  redacted bundles.
- `zmr run` can now boot an Android AVD, restore a snapshot, reset the emulator, and wait for boot readiness before running a scenario.
- `zmr run` can create a missing Android AVD from an installed system image before booting it.
- iOS pilot runs now execute a selector-driven `ios-shim-smoke` flow and export its report/bundles when `--ios-shim` is provided.
- iOS XCTest shim snapshots now include element `value` fields, and the Zig
  mapper falls back from empty labels to values so text-field contents appear
  in UI trees and agent observations.
- Added `scripts/release-gate.sh` as the one-command local release gate for formatting, tests, demo, coverage, packaging, and release smoke.
- Android shim installer can now copy the instrumentation source directly into an app module and idempotently patch AndroidX test dependencies in Gradle.
- Android shim installer now idempotently patches Gradle `testInstrumentationRunner` when `--gradle-file` is provided and no runner is already configured.
- Android shim installer now reuses an existing Gradle `testInstrumentationRunner` for the generated shim command when `--runner` is omitted.
- Troubleshooting guide for doctor output, scenario validation, shims, trace inspection, and release-gate failures.
- CI and tagged-release workflows now run the same `scripts/release-gate.sh` local acceptance gate.
- `zmr doctor` now includes remediation hints for missing or warning checks, including machine-readable `hint` fields in JSON output.
- Added `schemas/doctor-output.schema.json` for machine-readable setup diagnostics.
- The no-device demo now shows `zmr doctor --json` remediation hints for missing shim setup.
- `zmr doctor --config` now validates configured Android and iOS smoke scenario files and reports remediation hints for missing or malformed files.
- `zmr doctor --json --config` now reports malformed config files as structured `config` checks instead of raw CLI errors.
- Config parsing now rejects non-boolean values for boolean fields instead of silently falling back to defaults.
- Config parsing now rejects unknown fields so app-local config typos do not silently fall back to defaults.
- Config parsing now rejects empty strings for schema-required path, id, redaction list, and script command values.
- `zmr doctor --json --config` now includes stable `errorCode` and `fieldPath` values for actionable app-local config errors.
- `zmr doctor` now warns, with stable setup error codes, when ADB sees zero devices, `xcrun` sees zero booted iOS simulators, `devicectl` sees zero paired physical iOS devices, or physical iOS devices are listed but disconnected/unavailable.
- Physical iOS device discovery now exposes the commandable CoreDevice
  identifier from `devicectl` as the `serial` value agents pass back to
  `--device`, with the hardware UDID retained only as a parser fallback.
- `scripts/run-ios-pilot.sh --ios-device-type physical` now rejects listed but
  disconnected/unavailable physical device identifiers before install with
  `setup.ios.physical_device_not_ready` and prints the matched device state.
- `zmr doctor --json` now includes stable setup `errorCode` values for missing tools, failed tool commands, and missing shim commands.
- `zmr doctor --strict` now exits non-zero when any diagnostic check is warning or missing, so CI and setup scripts can fail before device orchestration.
- `zmr init --app` now scaffolds an app-local `.zmr/config.json`, Android smoke scenario, iOS smoke scenario, and `traces/` gitignore entry without requiring npm.
- `zmr init --json` now emits machine-readable created files and next-step commands for app and scenario bootstraps.
- Added `schemas/init-output.schema.json` for the machine-readable `zmr init --json` contract.
- `zmr import flow-yaml` now converts a supported subset of mobile-flow YAML commands into native `.zmr/*.json` scenarios.
- Added `schemas/import-output.schema.json` for the machine-readable `zmr import --json` contract.
- The no-device demo now shows config-driven `zmr doctor --json` smoke scenario diagnostics for missing files and malformed JSON.
- `zmr devices --json` now emits machine-readable Android device, iOS
  simulator, and physical iOS discovery output for setup scripts.
- `zmr devices --json` and JSON-RPC `device.list` now include a portable
  `ready` boolean so agents can avoid disconnected physical devices without
  duplicating platform state rules.
- `zmr doctor --json` now includes a state breakdown for listed-but-not-ready
  physical iOS devices, such as `disconnected=1, unavailable=1`.
- Added `schemas/devices-output.schema.json` for the machine-readable `zmr devices --json` contract.
- `zmr version --json` now emits machine-readable runner and protocol compatibility metadata for installers and generated clients.
- Added `schemas/version-output.schema.json` for the machine-readable `zmr version --json` contract.
- `runner.capabilities` now reports Android, iOS simulator, and physical iOS
  support as structured `platformSupport` metadata, with `iosPreview: false`.
- Added `schemas/capabilities-output.schema.json` for the machine-readable
  `runner.capabilities` JSON-RPC result.
- `zmr explain --json` now emits machine-readable failure triage for agents and CI.
- Added `schemas/explain-output.schema.json` for the machine-readable `zmr explain --json` contract.
- `zmr schemas --json` now emits a machine-readable index of packaged public schema contracts.
- Added `schemas/schemas-output.schema.json` for the machine-readable `zmr schemas --json` contract.
- `zmr run --json` now emits a machine-readable terminal run summary while preserving failed scenario exit codes.
- Added `schemas/run-output.schema.json` for the machine-readable `zmr run --json` contract.
- Partial iOS visual captures now surface `partialFailure` in `zmr run --json`
  and semantic-extraction diagnostics in `zmr explain --json`, separating
  captured screenshot artifacts from failed accessibility/XCTest extraction.
- Added `zmr-device-matrix` / `scripts/device-matrix.sh` for local Android/iOS
  multi-device smoke gates with `matrix.jsonl`, `summary.json`, and pass-rate
  thresholds.
- `zmr-device-matrix` rows now support `iosDeviceType: "physical"` so matrix
  runs can exercise physical iOS devices through the same `zmr run` flag used
  by pilot gates.
- Added `zmr-compare-benchmarks` / `scripts/compare-benchmarks.py` for generic
  candidate-vs-baseline benchmark reports without naming app projects or
  third-party tools in public fixtures.
- Added `zmr-demo-ios` and `zmr-create-ios-demo-app` flows for a generic
  simulator app with the XCTest shim installed, selector-grade smoke scenario,
  and redacted trace output.
- Added `zmr-create-android-demo-app` for a generic native Android APK and
  `.zmr` smoke scenario built with Android SDK command-line tools.
- Added `zmr-demo-android` for a one-command public Android demo that creates,
  installs, runs, benchmarks, and traces the generated app on an emulator or
  device.
- `zmr validate --json` now reports missing step selectors as `selector.invalid` with `fieldPath: "$.steps[].selector"` instead of falling back to `internal.error`.
- `zmr validate --json` now reports unknown scenario action typos as `scenario.invalid` with `fieldPath: "$.steps[].action"` and source location diagnostics.
- `zmr validate --json` now reports invalid `scrollUntilVisible.direction` values as `scenario.invalid` with `fieldPath: "$.steps[].direction"`.
- `zmr validate --json` now reports missing `openLink.url` values as `scenario.invalid` with `fieldPath: "$.steps[].url"`.
- `zmr validate --json` now reports missing `typeText.text` values as `scenario.invalid` with `fieldPath: "$.steps[].text"`.
- `zmr validate --json` now reports missing `swipe.x1`, `swipe.y1`, `swipe.x2`, and `swipe.y2` values as `scenario.invalid` with field-specific `fieldPath` values.

### Changed

- README now links to install, demo, schema, and roadmap materials.
- Protocol documentation now includes concrete request/response examples and error shapes.
- Protocol versioning now defines the pre-`v1.0.0` compatibility contract and breaking-change policy.
- Android `openLink` now avoids blocking `am start -W`, retries when Android leaves the launcher foregrounded, and lets selector waits absorb transient observation command timeouts.
- iOS simulators are supported for lifecycle, snapshots, logs, deep links,
  clear-state-by-uninstall, and selector-driven XCTest shim interaction.
- iOS XCTest shim commands now retry once when Xcode/CoreSimulator reports a
  transient server bootstrap failure, reducing fresh-simulator flake while
  preserving immediate failures for real command and assertion errors.
- Physical iOS devices are supported for local lifecycle and selector-grade
  XCTest shim interaction. Screenshot artifacts use the XCTest shim; log
  capture remains simulator-first.
- npm package contents now exclude internal test sources, caches, traces, and
  build outputs while keeping runtime source, prebuilds, docs, examples, shims,
  schemas, viewer assets, release scripts, and language clients available.
- Shipped TypeScript and Rust client metadata now matches the runner
  prerelease, with package tests guarding future drift.

### Known Limitations

- Physical iOS log capture is not complete yet.
- Broad cloud-device-farm certification is not included in this dev-preview
  release.
- Real app performance summaries should come from equivalent app-local
  candidate and baseline `zmr-compare-benchmarks` reports, not from generic
  public fixtures.

## 0.1.0-dev.1

Initial local dev preview:

- Zig CLI and JSON-RPC runner.
- Android ADB/UI Automator adapter.
- iOS simulator lifecycle, snapshots, logs, deep links, and selector-driven
  XCTest shim preview.
- Scenario runner with waits, assertions, selectors, retries, and trace writing.
- Fake-device test harness and no-emulator demo.
- Release archive script and CI workflows.
