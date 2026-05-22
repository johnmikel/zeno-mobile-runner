# Zig Mobile Runner

> Agent-native mobile UI automation for Android, iOS simulators, and physical iOS devices.

[![CI](https://github.com/johnmikel/zig-mobile-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/johnmikel/zig-mobile-runner/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/johnmikel/zig-mobile-runner?include_prereleases)](https://github.com/johnmikel/zig-mobile-runner/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

ZMR gives AI agents and test harnesses a typed mobile control plane: observe the
app, choose an action, wait for the UI to settle, assert state, and export a
replayable trace. The runner does not embed an LLM. Agents stay outside and use
ZMR through JSON-RPC, CLI JSON, scenarios, and language clients.

## Why ZMR

- **AI-native protocol:** structured snapshots, semantic mobile trees, actions,
  waits, assertions, live trace events, and redacted trace export over
  JSON-RPC or MCP.
- **Trace-first debugging:** every run can produce screenshots, UI trees, logs,
  timings, action inputs, assertion results, and an HTML report.
- **Fast local core:** Zig owns orchestration, subprocess control, selectors,
  waits, retries, scenario execution, and release artifacts.
- **App-local setup:** `.zmr/config.json`, smoke scenarios, shim commands, and
  traces live in the app repo.
- **Android and iOS:** Android uses ADB/UI Automator plus an optional native
  shim. iOS simulators use `simctl`; physical iOS devices use `devicectl`;
  selector-grade iOS automation uses the XCTest/XCUIAutomation shim.

## Install

Inside a mobile app repo:

```bash
# Available after the npm registry package is published:
npm install --save-dev zig-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
```

For Expo development builds, add `--expo-dev-client-scheme <scheme>` to the
wizard command.

Today, install the release tarball from GitHub:

```bash
npm install --save-dev https://github.com/johnmikel/zig-mobile-runner/releases/download/v0.1.0/zig-mobile-runner-0.1.0.tgz
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
```

From source:

```bash
git clone https://github.com/johnmikel/zig-mobile-runner.git
cd zig-mobile-runner
zig build-exe src/main.zig -target aarch64-macos.15.0 -O Debug -femit-bin=zig-out/bin/zmr
./zig-out/bin/zmr version
```

Release archives and npm tarballs are attached to GitHub releases. The npm
registry package is pending publish.

Homebrew is the preferred binary install for teams that do not use JavaScript:

```bash
brew install --build-from-source ./dist/homebrew/zmr.rb
```

## Try It

No device required:

```bash
./scripts/demo.sh
```

Real iOS simulator demo:

```bash
npx zmr-demo-ios --out /tmp/zmr-ios-demo --device booted
```

The demo command boots an available simulator when none is already running.

Android app-local pilot:

```bash
zmr-pilot-gate \
  --android \
  --android-app-root /path/to/mobile-app \
  --android-app-id com.example.mobiletest \
  --android-device emulator-5554 \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl
```

iOS app-local pilot:

```bash
zmr-pilot-gate \
  --ios \
  --ios-app-root /path/to/mobile-app \
  --ios-app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app \
  --ios-app-id com.example.mobiletest \
  --ios-device booted \
  --ios-shim /path/to/mobile-app/.zmr/ios-shim \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl
```

## Scenario Example

ZMR scenarios are JSON today because JSON is strict, schema-validatable, and
easy for agents and code generators to emit.

```json
{
  "name": "Login smoke",
  "appId": "com.example.mobiletest",
  "steps": [
    { "action": "launch" },
    { "action": "assertHealthy", "timeoutMs": 5000 },
    { "action": "tap", "selector": { "resourceId": "email" } },
    { "action": "typeText", "text": "user@example.com" },
    { "action": "tap", "selector": { "resourceId": "password" } },
    { "action": "typeText", "text": "password" },
    { "action": "tap", "selector": { "text": "Login" } },
    { "action": "waitVisible", "selector": { "text": "Welcome" }, "timeoutMs": 30000 }
  ]
}
```

Validate before touching a device:

```bash
zmr version --json
zmr schemas --json
zmr devices --json
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr validate --json .zmr/login-smoke.json
zmr run .zmr/login-smoke.json --json --trace-dir traces/login-smoke
zmr explain --json traces/login-smoke
zmr import flow-yaml .zmr/legacy-flow.yaml --out .zmr/legacy-flow.json
zmr export traces/login-smoke --out traces/login-smoke-redacted.zmrtrace --redact
```

Stable JSON outputs are documented with schemas:
`version-output.schema.json`, `schemas-output.schema.json`,
`capabilities-output.schema.json`, `init-output.schema.json`,
`devices-output.schema.json`, `validate-output.schema.json`,
`run-output.schema.json`, `explain-output.schema.json`,
`semantic-snapshot.schema.json`, `release-manifest.schema.json`,
`release-readiness-output.schema.json`, and `RELEASE_MANIFEST.json`.

See [docs/dsl.md](docs/dsl.md) for the DSL decision and roadmap.

## Agent And Language Clients

Clients are thin wrappers around `zmr serve --transport stdio`. They do not
replace the runner; they make it easier for agents and test code to call the
same JSON-RPC protocol.

```bash
zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
```

Agents that support the Model Context Protocol can use the native MCP surface:

```bash
zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
```

The MCP server exposes mobile-specific tools such as `semantic_snapshot`,
`tap`, `type`, `wait_visible`, `trace_events`, and `trace_export`.

| Language | Entry point | Example |
| --- | --- | --- |
| TypeScript | `clients/typescript/index.mjs` + `index.d.ts` | `node clients/typescript/examples/fake-session.mjs` |
| Python | `clients/python/zmr_client.py` + `pyproject.toml` | `python3 clients/python/examples/fake_session.py` |
| Go | `clients/go/zmr/client.go` | `go run ./clients/go/examples/fake-session` |
| Rust | `clients/rust/src/lib.rs` | `cargo run --manifest-path clients/rust/Cargo.toml --example fake_session` |
| Swift | `clients/swift/Sources/ZMRClient` | `swift build --package-path clients/swift` |
| Kotlin | `clients/kotlin/src/main/kotlin/dev/zmr` | `gradle -p clients/kotlin build` |

Rust uses `src/lib.rs` because that is the idiomatic crate layout. TypeScript
uses `index.mjs` plus declarations, Python uses a pip-installable module, Go
uses a package directory under `clients/go/zmr`, Swift uses SwiftPM, and Kotlin
uses Gradle.

See [clients/README.md](clients/README.md), [docs/client-installation.md](docs/client-installation.md),
and [docs/ai-agents.md](docs/ai-agents.md).

## Platform Support

| Target | Status | Notes |
| --- | --- | --- |
| Android emulator | Supported | ADB/UI Automator, optional Android shim, emulator lifecycle helpers |
| Android physical device | Supported | Requires ADB connection and app build/install surface |
| iOS simulator | Supported | `simctl` plus app-local XCTest/XCUIAutomation shim for native selector actions, native waits, and bounded snapshots |
| iOS physical device | Supported, evidence-gated | `devicectl` lifecycle plus app-local XCTest/XCUIAutomation shim; run the physical pilot before claiming device reliability |
| Cloud device farms | Not yet | Planned after local matrix certification |

Current release: `0.1.0` developer preview. Protocol version:
`2026-04-28`. Latest local coverage run: `94.40%` line coverage.

## Documentation

- [FEATURES.md](FEATURES.md): complete feature list and limitations
- [docs/install.md](docs/install.md): source, archive, npm, and app setup
- [docs/app-integration.md](docs/app-integration.md): app-side Android/iOS shims
- [docs/protocol.md](docs/protocol.md): JSON-RPC methods and schemas
- [docs/ai-agents.md](docs/ai-agents.md): JSON-RPC and MCP agent workflows
- [docs/dsl.md](docs/dsl.md): scenario DSL decision and roadmap
- [docs/clients.md](docs/clients.md): language client guide
- [docs/client-installation.md](docs/client-installation.md): npm, Homebrew, TS, Python, Go, Rust, Swift, and Kotlin setup
- [docs/market-positioning.md](docs/market-positioning.md): competitive positioning
- [docs/adr/](docs/adr/): architecture decision records
- [docs/shipping.md](docs/shipping.md): release gate and support matrix
- [docs/release-audit.md](docs/release-audit.md): prompt-to-artifact completion audit
- [docs/trace-privacy.md](docs/trace-privacy.md): safe trace export
- [skills/zmr-mobile-testing/SKILL.md](skills/zmr-mobile-testing/SKILL.md): reusable agent skill

## Release Gate

Before publishing:

```bash
./scripts/release-gate.sh
./scripts/build-release.sh
./scripts/verify-release-artifacts.sh
npm pack --dry-run
```

The release gate runs formatting, shell syntax checks, client tests, public
safety scans, Zig tests, the no-device demo, coverage, archive generation,
checksum/manifest verification, host archive smoke, and npm package dry-run.

Release-candidate evidence can be checked explicitly:

```bash
zmr-release-readiness --evidence traces/release-candidate/<run>/evidence.jsonl \
  --target dev-preview
```

Use `--target production` only after repeated real app/device pilots exist, and
`--target market-claim` only after same-host/device benchmark comparison
evidence exists.

## License

MIT
