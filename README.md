# Zeno Mobile Runner

> Agent-native mobile UI automation for React Native, Expo, Flutter, and native Android/iOS apps.

[![CI](https://github.com/johnmikel/zeno-mobile-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/johnmikel/zeno-mobile-runner/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/johnmikel/zeno-mobile-runner?include_prereleases)](https://github.com/johnmikel/zeno-mobile-runner/releases)
[![npm](https://img.shields.io/npm/v/zeno-mobile-runner)](https://www.npmjs.com/package/zeno-mobile-runner)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

ZMR gives AI agents and test harnesses a typed mobile control plane. It can
install and launch apps, observe the UI, choose an action, wait for the screen to
settle, assert state, and export a replayable trace. The runner does not embed an
LLM. Agents stay outside and use ZMR through CLI JSON, scenarios, JSON-RPC, MCP,
or optional protocol clients.

## Install

Inside a mobile app repo:

```bash
npm install --save-dev zeno-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
```

Run a generated smoke scenario:

```bash
npm run zmr:validate
npm run zmr:android
npm run zmr:ios
```

## React Native, Expo, and Flutter

ZMR works below the JavaScript or Dart framework layer. It drives the installed
Android or iOS app through platform lifecycle commands, deep links, accessibility
semantics, screenshots, logs, selector actions, waits, assertions, and traces.

- **React Native:** prefer `testID`, `accessibilityLabel`, stable text, and deep
  links for direct navigation into important states.
- **Expo development builds:** pass `--expo-dev-client-scheme <scheme>` to the
  wizard so ZMR scaffolds dev-client open-link scenarios.
- **Flutter:** ZMR supports Flutter apps at the Android and iOS app level when
  the app exposes stable semantics labels, text, deep links, or native ids. It is
  not a Flutter widget-tree driver and does not inspect Flutter internals.
- **Native Android/iOS:** use resource ids, content descriptions, accessibility
  identifiers, XCTest labels, and app-owned deep links.

See [docs/frameworks.md](docs/frameworks.md) and
[docs/app-integration.md](docs/app-integration.md) for app-side setup guidance.

## Why ZMR

- **Agent-native protocol:** structured snapshots, semantic mobile trees,
  actions, waits, assertions, live trace events, and redacted trace export over
  JSON-RPC or MCP.
- **Trace-first debugging:** every run can produce screenshots, UI trees, logs,
  timings, action inputs, assertion results, and an HTML report.
- **Fast local core:** Zig owns orchestration, subprocess control, selectors,
  waits, retries, scenario execution, and packaged binaries.
- **App-local setup:** `.zmr/config.json`, smoke scenarios, shim commands, and
  traces live in the app repo.
- **Android and iOS:** Android uses ADB/UI Automator plus an optional native
  shim. iOS simulators use `simctl`; physical iOS devices use `devicectl`;
  selector-grade iOS automation uses the XCTest/XCUIAutomation shim.

## Scenario Example

ZMR scenarios are JSON so agents and build scripts can generate, validate, and
mutate them without a second DSL.

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

Useful commands:

```bash
zmr version --json
zmr schemas --json
zmr devices --json
zmr inspect --json
zmr draft --from-trace traces/zmr-agent --out .zmr/discovered/surface-smoke.json --json
zmr draft --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --json
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr validate --json .zmr/login-smoke.json
zmr run .zmr/login-smoke.json --json --trace-dir traces/login-smoke
zmr explain --json traces/login-smoke
zmr import flow-yaml .zmr/legacy-flow.yaml --out .zmr/legacy-flow.json
zmr export traces/login-smoke --out traces/login-smoke-redacted.zmrtrace --redact
```

See [docs/scenario-authoring.md](docs/scenario-authoring.md) for selector and
wait guidance.

## Agent Workflow

Agents can use the CLI, JSON-RPC, or MCP surface. Start JSON-RPC over stdio:

```bash
zmr inspect --json --dir .
```

`zmr inspect --json` gives agents a read-only handoff for the app checkout:
config status, generated agent instructions, configured platform scenarios, and
recommended next commands. It does not launch devices or write tests.

After a live session has produced semantic snapshot artifacts, agents can ask
ZMR to draft a conservative surface-smoke scenario from the trace:

```bash
zmr draft --from-trace traces/zmr-agent \
  --out .zmr/discovered/surface-smoke.json \
  --json
zmr validate --json .zmr/discovered/surface-smoke.json
```

`zmr draft` is offline and review-first. It writes `launch`, `snapshot`, and
`assertVisible` steps from stable visible selectors. It does not crawl the app,
tap controls, type into fields, discover credentials, or commit tests.

When the trace was produced by an agent or JSON-RPC/MCP session that took typed
actions, add `--include-actions` to replay successful supported actions before
the final snapshot assertions:

```bash
zmr draft --from-trace traces/zmr-agent \
  --out .zmr/discovered/replay-smoke.json \
  --include-actions \
  --json
zmr validate --json .zmr/discovered/replay-smoke.json
```

Replay drafts only use trace events with enough stable data to reproduce them,
such as launch, deep links, selector taps, selector text entry, waits, back,
keyboard hiding, and selector scrolls. Unsupported or underspecified events are
skipped with warnings instead of guessed. Text entry events whose text was
redacted from the trace are also skipped.

```bash
zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
```

Agents that support the Model Context Protocol can use the native MCP surface:

```bash
zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
```

The MCP server exposes mobile-specific tools such as `semantic_snapshot`, `tap`,
`type`, `wait_visible`, `trace_events`, and `trace_export`.

For agent-led discovery and test authoring, see
[docs/agent-discovery.md](docs/agent-discovery.md). ZMR supports that loop
through MCP, JSON-RPC, trace events, offline surface drafts, and replay drafts
today; a built-in autonomous crawler is not shipped in this preview.

## Optional Protocol Clients

Clients are thin wrappers around `zmr serve --transport stdio`. They do not
replace the runner; they make it easier for agents and test code to call the
same JSON-RPC protocol.

TypeScript and Python are the most common starting points for app teams and
agent harnesses. Go, Rust, Swift, and Kotlin clients are reference integrations
for teams that want to embed the protocol from those ecosystems.

| Language | Entry point | Example |
| --- | --- | --- |
| TypeScript | `clients/typescript/index.mjs` + `index.d.ts` | `node clients/typescript/examples/fake-session.mjs` |
| Python | `clients/python/zmr_client.py` + `pyproject.toml` | `python3 clients/python/examples/fake_session.py` |
| Go | `clients/go/zmr/client.go` | `go run ./clients/go/examples/fake-session` |
| Rust | `clients/rust/src/lib.rs` | `cargo run --manifest-path clients/rust/Cargo.toml --example fake_session` |
| Swift | `clients/swift/Sources/ZMRClient` | `swift build --package-path clients/swift` |
| Kotlin | `clients/kotlin/src/main/kotlin/dev/zmr` | `gradle -p clients/kotlin build` |

See [clients/README.md](clients/README.md), [docs/clients.md](docs/clients.md),
and [docs/client-installation.md](docs/client-installation.md).

## Platform Support

| Target | Status | Notes |
| --- | --- | --- |
| Android emulator | Supported | ADB/UI Automator, optional Android shim, emulator lifecycle helpers |
| Android physical device | Supported | Requires ADB connection and app build/install surface |
| iOS simulator | Supported | `simctl` plus app-local XCTest/XCUIAutomation shim for native selector actions, native waits, and bounded snapshots |
| iOS physical device | Supported, validate locally | `devicectl` lifecycle plus app-local XCTest/XCUIAutomation shim; run pilots on your own app/device before relying on it in CI |
| Cloud device farms | Not included | ZMR is focused on local and self-managed device targets in this preview |

Current release: `0.1.7` developer preview. Protocol version:
`2026-04-28`.

## Documentation

- [FEATURES.md](FEATURES.md): complete feature list and limitations
- [docs/install.md](docs/install.md): source, npm, Homebrew, and app setup
- [docs/frameworks.md](docs/frameworks.md): React Native, Expo, Flutter, and native app guidance
- [docs/expo-smoke.md](docs/expo-smoke.md): reproducible Expo and iOS smoke test
- [docs/production-readiness.md](docs/production-readiness.md): release, reliability, framework, and agent-readiness gates
- [docs/app-integration.md](docs/app-integration.md): app-side Android/iOS shims
- [docs/scenario-authoring.md](docs/scenario-authoring.md): selectors, waits, and scenario design
- [docs/agent-discovery.md](docs/agent-discovery.md): agent-led discovery and scenario authoring loop
- [docs/protocol.md](docs/protocol.md): JSON-RPC methods and schemas
- [docs/ai-agents.md](docs/ai-agents.md): JSON-RPC and MCP agent workflows
- [docs/clients.md](docs/clients.md): language client guide
- [docs/client-installation.md](docs/client-installation.md): npm, Homebrew, TS, Python, Go, Rust, Swift, and Kotlin setup
- [docs/trace-privacy.md](docs/trace-privacy.md): safe trace export
- [docs/troubleshooting.md](docs/troubleshooting.md): common setup and runtime issues
- [skills/zmr-mobile-testing/SKILL.md](skills/zmr-mobile-testing/SKILL.md): reusable agent skill

## License

MIT
