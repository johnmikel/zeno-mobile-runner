# Changelog

All notable changes to Zeno Mobile Runner are tracked here.

## 0.1.7 (2026-06-06)

### Added

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
- Added a trace-backed discovery handoff to traced `zmr run --json`
  `nextCommands`, so agents can generate a reviewable replay scenario directly
  from a run summary.
- Added `zmr run --discover-out <scenario.json> --json` so traced runs can
  write and validate the reviewable replay scenario before returning the run
  summary.
- Added replay coverage metadata to `zmr draft --json`, `zmr discover --json`,
  and embedded run discovery output so agents can see how many trace actions
  became replay steps and how many were skipped.
- Added `zmr report --junit <report.xml>` so trace directories and benchmark
  result directories can produce CI-friendly JUnit XML alongside HTML reports.
- Updated generated app report and reliability scripts to write `junit.xml`
  beside `report.html` by default.
- Updated Android and iOS pilot wrappers to emit `junit.xml` beside every
  generated `report.html`.
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
