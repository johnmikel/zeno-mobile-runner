# Zeno Mobile Runner

> Agent-first mobile verification with deterministic CI scenarios and
> replayable product evidence.

[![CI](https://github.com/johnmikel/zeno-mobile-runner/actions/workflows/ci.yml/badge.svg)](https://github.com/johnmikel/zeno-mobile-runner/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/johnmikel/zeno-mobile-runner?include_prereleases)](https://github.com/johnmikel/zeno-mobile-runner/releases)
[![npm](https://img.shields.io/npm/v/zeno-mobile-runner)](https://www.npmjs.com/package/zeno-mobile-runner)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

AI agents can edit mobile apps quickly, but they need a reliable way to inspect
the screen, act on native UI, and prove the result. Zeno Mobile Runner (ZMR) is
that verification control plane: one local binary that installs and launches
apps, captures semantic UI state, performs typed actions, waits and asserts, and
exports a replayable trace. ZMR does not embed an LLM. Agents, scripts, and CI
systems drive it through MCP, JSON-RPC, CLI JSON, or committed JSON scenarios.

![ZMR trace viewer showing a passed iOS run with timeline, device screenshot, UI tree, and selector payload](docs/assets/viewer-hero.png)

<p align="center">
  <img src="docs/assets/device-ios-demo.png" width="260" alt="iOS simulator screenshot captured by ZMR during a scenario run" />
  &nbsp;&nbsp;
  <img src="docs/assets/device-android-demo.png" width="260" alt="Android emulator screenshot captured by ZMR during a scenario run" />
</p>

<p align="center"><em>Real on-device screenshots from ZMR traces: the same demo flow
driven on an iOS simulator and an Android emulator.</em></p>

## Why This Exists

- **Agents should verify their own changes.** ZMR turns mobile app state into
  structured observations and typed tool results that fit AI coding loops.
- **Agents need structured mobile state.** ZMR returns semantic UI trees,
  stable selectors, screenshots, and typed action results, so an agent can
  reason from product state instead of guessing from terminal output.
- **Product claims need evidence.** Every traced session can include events,
  screenshots, UI hierarchies, timings, assertion results, HTML and JUnit
  reports, and a redacted bundle for review.
- **Exploration should become tests.** After a live agent session,
  `zmr discover` converts trace evidence into reviewable JSON scenarios that
  replay in CI without an LLM in the loop.

## How It Works

```mermaid
flowchart LR
    A["AI coding agent<br/>Claude Code · Cursor · custom harness"]
    subgraph zmr["ZMR - one small Zig binary"]
        MCP["MCP server<br/><code>zmr mcp</code>"]
        RPC["JSON-RPC stdio/TCP<br/><code>zmr serve</code>"]
        CLI["CLI + JSON scenarios<br/><code>zmr run</code>"]
        CORE["Core engine<br/>selectors · waits · assertions<br/>scenario runner · trace writer"]
        MCP --> CORE
        RPC --> CORE
        CLI --> CORE
    end
    subgraph devices["Devices"]
        AND["Android emulator/device<br/>ADB · UI Automator · optional shim"]
        IOS["iOS simulator/device<br/>simctl · devicectl · XCTest shim"]
    end
    TRACE["Trace<br/>events.jsonl · screenshots · UI trees<br/>report.html · junit.xml · .zmrtrace"]
    A -- "MCP tools" --> MCP
    A -- "JSON-RPC" --> RPC
    A -- "CLI JSON" --> CLI
    CORE --> AND
    CORE --> IOS
    CORE --> TRACE
```

Android can run with no app instrumentation, with an optional app-local shim for
faster native actions. iOS and iPadOS selector actions use an app-local
XCTest/XCUIAutomation shim scaffolded by the wizard. ZMR works below the
JavaScript and Dart layer, so React Native, Expo, Flutter, and native apps share
the same runner model. See [docs/frameworks.md](docs/frameworks.md).

## Five-Minute Start

Run this from the mobile app repository. It installs ZMR, creates app-local
configuration, and verifies the setup before a device run:

```bash
npm install --save-dev zeno-mobile-runner   # bun add --dev zeno-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
```

Hook it up to your coding agent (Claude Code shown; any MCP client works):

```bash
claude mcp add zmr -- npx zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
```

Claude Code users can instead install the plugin, which bundles the MCP server
and a mobile-testing skill:

```text
/plugin marketplace add johnmikel/zeno-mobile-runner
/plugin install zmr@zmr-marketplace
```

Or in an `.mcp.json` / MCP client config:

```json
{
  "mcpServers": {
    "zmr": {
      "command": "npx",
      "args": ["zmr", "mcp", "--config", ".zmr/config.json", "--trace-dir", "traces/zmr-agent"]
    }
  }
}
```

Then ask the agent to verify its own work: "launch the app, walk through
onboarding, and show me the trace."

## Agent Verification Loop

```mermaid
sequenceDiagram
    participant Agent as AI agent
    participant ZMR
    participant Device as Emulator / simulator
    Agent->>ZMR: semantic_snapshot
    ZMR->>Device: capture UI + screenshot
    ZMR-->>Agent: roles, stable selectors, bounds
    Agent->>ZMR: tap / type / swipe / open_link
    ZMR->>Device: execute + settle
    Agent->>ZMR: wait_visible / assert_visible
    ZMR-->>Agent: typed result + trace events
    Agent->>ZMR: trace_discover
    ZMR-->>Agent: reviewable replay scenario
    Agent->>ZMR: trace_export --redact
    ZMR-->>Agent: .zmrtrace evidence bundle
```

The MCP server exposes the loop as mobile-native tools:

| Group | Tools |
| --- | --- |
| Observe | `snapshot`, `semantic_snapshot` |
| App lifecycle | `install_app`, `launch_app`, `stop_app`, `clear_state`, `open_link` |
| Act | `tap`, `type`, `erase_text`, `hide_keyboard`, `swipe`, `press_back` |
| Wait | `wait_visible`, `wait_not_visible`, `wait_any`, `scroll_until_visible` |
| Assert | `assert_visible`, `assert_not_visible`, `assert_healthy` |
| Evidence | `trace_events`, `trace_explain`, `trace_discover`, `trace_explore`, `trace_export`, `scenario_validate` |

The same surface is available over JSON-RPC for harnesses that embed ZMR
directly. See [docs/protocol.md](docs/protocol.md) and
[docs/ai-agents.md](docs/ai-agents.md). When a run fails, `zmr explain`
diagnoses the trace for humans and agents alike:

![Terminal session showing a failed run, zmr explain diagnosing the failure with visible texts, and the fixed run passing](docs/assets/cli-run-explain.png)

## Deterministic Scenarios For CI

Scenarios are plain JSON. Agents and build scripts can generate, validate, and
mutate them without a second DSL, then replay them in CI with no LLM cost:

```json
{
  "name": "Login smoke",
  "appId": "com.example.mobiletest",
  "steps": [
    { "action": "clearState" },
    { "action": "launch" },
    { "action": "assertHealthy", "timeoutMs": 5000 },
    { "action": "tap", "selector": { "resourceId": "email" } },
    { "action": "typeText", "text": "user@example.com" },
    { "action": "tap", "selector": { "text": "Login" } },
    { "action": "waitVisible", "selector": { "text": "Welcome" }, "timeoutMs": 30000 }
  ]
}
```

```bash
zmr validate --json .zmr/login-smoke.json
zmr run .zmr/login-smoke.json --json --trace-dir traces/login-smoke
zmr report traces/login-smoke --out traces/login-smoke/report.html --junit traces/login-smoke/junit.xml
zmr export traces/login-smoke --out login-smoke-redacted.zmrtrace --redact
```

Teams migrating from Maestro can start with the explicit compatibility command:

```bash
zmr import maestro flows/login.yaml --out .zmr/login-smoke.json --json
zmr validate --json .zmr/login-smoke.json
```

Traced `zmr run --json` responses include executable `nextCommands`, so agents
can continue to reporting, explanation, discovery, or export without rebuilding
paths from text.
Open any exported bundle in the static [trace viewer](viewer/index.html) — or
serve it and link straight to it with `viewer/index.html?bundle=<url>`.

For repeat-run reliability gates, p95 duration thresholds, baseline
comparisons against your current E2E tool, and multi-device matrices, see
[docs/benchmarking.md](docs/benchmarking.md) and the public
[Benchmark Lab](docs/benchmarks/README.md) evidence.

## Platform Support

| Target | Status | Notes |
| --- | --- | --- |
| Android emulator | Supported | ADB/UI Automator, optional Android shim, emulator lifecycle helpers |
| Android physical device | Supported | Requires ADB connection and app build/install surface |
| iPhone simulator | Supported | `simctl` plus app-local XCTest/XCUIAutomation shim for native selector actions |
| iPad simulator | Supported, evidence-needed | Same iOS simulator path; validate tablet layouts and size-class branches before production claims |
| iPhone physical device | Supported, validate locally | `devicectl` lifecycle plus XCTest shim; pilot on your app/device before relying on it in CI |
| iPad physical device | Supported, evidence-needed | Same iOS/iPadOS physical path; collect separate iPad pilot evidence before claiming production readiness |
| Apple TV / Apple Watch | Not supported in this preview | Requires separate platform lifecycle, shim, destination, and trace evidence |
| Cloud device farms | Not included | ZMR focuses on local and self-managed device targets in this preview |

Slow CI hardware can extend the generated iOS shim build timeout with
`ZMR_IOS_SHIM_BUILD_TIMEOUT_SECONDS`; `ZMR_IOS_SHIM_RESPONSE_TIMEOUT_SECONDS`
bounds each in-flight request, and `ZMR_IOS_SHIM_TIMEOUT_MS` remains the outer
process ceiling. Current release: `0.2.16` developer preview.
Protocol version: `2026-04-28`.

## Optional Protocol Clients

TypeScript and Python clients are the common starting points; Go, Rust, Swift,
and Kotlin reference clients embed the same JSON-RPC protocol from those
ecosystems. All are thin wrappers around `zmr serve --transport stdio`. See
[docs/clients.md](docs/clients.md) and
[docs/client-installation.md](docs/client-installation.md).

## Documentation

**Start here**

- [docs/install.md](docs/install.md): install paths and first setup checks
- [docs/maestro-migration.md](docs/maestro-migration.md): migrate Maestro smoke flows into reviewed ZMR JSON
- [docs/json-traces-vs-yaml.md](docs/json-traces-vs-yaml.md): why JSON scenarios plus traces are the ZMR runtime contract
- [docs/zmr-live.md](docs/zmr-live.md): live agent verification workflow with MCP, traces, viewer, and export
- [docs/support-matrix.md](docs/support-matrix.md): platform support, evidence
  levels, and Apple-platform scope
- [docs/production-readiness.md](docs/production-readiness.md): release,
  reliability, privacy, and claim gates

**For agents**

- [docs/ai-agents.md](docs/ai-agents.md): JSON-RPC and MCP agent workflows
- [docs/agent-discovery.md](docs/agent-discovery.md): agent-led discovery,
  `zmr explore`/`discover`/`draft`, and the trace-to-test loop
- [skills/zmr-mobile-testing/SKILL.md](skills/zmr-mobile-testing/SKILL.md): reusable agent skill

**For test authors**

- [docs/install.md](docs/install.md): source, npm, Homebrew, and app setup
- [docs/frameworks.md](docs/frameworks.md): React Native, Expo, Flutter, and native app guidance
- [docs/scenario-authoring.md](docs/scenario-authoring.md): selectors, waits, and scenario design
- [docs/command-reference.md](docs/command-reference.md): public command use, agent handoff, CI use, failures, and artifacts
- [docs/app-integration.md](docs/app-integration.md): app-side Android/iOS shims
- [docs/expo-smoke.md](docs/expo-smoke.md): reproducible Expo and iOS smoke test
- [docs/benchmarking.md](docs/benchmarking.md): repeat-run gates, reports, device matrix, baselines
- [docs/self-managed-parallel-ci.md](docs/self-managed-parallel-ci.md): parallel execution without a hosted cloud dependency

**Reference**

- [FEATURES.md](FEATURES.md): complete feature list and limitations
- [docs/protocol.md](docs/protocol.md): JSON-RPC methods and schemas
- [docs/trace-privacy.md](docs/trace-privacy.md): safe trace export
- [docs/troubleshooting.md](docs/troubleshooting.md): common setup and runtime issues
- [docs/benchmarks](docs/benchmarks/README.md): public-safe benchmark evidence

## License

MIT
