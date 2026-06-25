# Client Guide

ZMR clients are reference implementations for the JSON-RPC protocol used by
`zmr serve`. They are intentionally small, dependency-light, and host-side.
They do not replace the `zmr` binary and they do not run inside the app under
test.

TypeScript and Python are the most common starting points for app teams and
agent harnesses. Go, Rust, Swift, and Kotlin are reference integrations for
teams that want host-side orchestration in those ecosystems. Go and Rust include
typed trace discovery and scenario validation helpers; Swift and Kotlin include
lightweight discovery and validation helpers for native mobile teams.

| Language | Entry point | Example |
| --- | --- | --- |
| TypeScript | `clients/typescript/index.mjs` + `index.d.ts` | `node clients/typescript/examples/fake-session.mjs` |
| Python | `clients/python/zmr_client.py` + `pyproject.toml` | `python3 clients/python/examples/fake_session.py` |
| Go | `clients/go/zmr/client.go` | `go run ./clients/go/examples/fake-session` |
| Rust | `clients/rust/src/lib.rs` | `cargo run --manifest-path clients/rust/Cargo.toml --example fake_session` |
| Swift | `clients/swift/Sources/ZMRClient` | `swift build --package-path clients/swift` |
| Kotlin | `clients/kotlin/src/main/kotlin/dev/zmr` | `gradle -p clients/kotlin build` |

## What Clients Mean

The runner is still the Zig binary. A client starts or connects to:

```bash
zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
```

Then it sends JSON-RPC methods such as:

- `runner.capabilities`
- `session.create`
- `observe.snapshot`
- `observe.semanticSnapshot`
- `ui.tap`
- `wait.until`
- `assert.visible`
- `assert.healthy`
- `scenario.validate`
- `trace.events`
- `trace.explain`
- `trace.explore`
- `trace.discover`
- `trace.export`

Use clients when an AI agent, service, or test harness wants to drive ZMR
programmatically instead of shelling out for each scenario. For package-manager
install commands, see [client-installation.md](client-installation.md).
Prefer the semantic snapshot helper for agent planning; it normalizes native
Android/iOS classes into roles, selectors, bounds, and recommended actions.
Use `assert.healthy` after launches, deep links, and high-risk transitions so
agent-written tests fail on crash overlays and development-client load errors
even when normal page text is also present.

## Language Layouts

| Language | Files | Why it looks this way |
| --- | --- | --- |
| TypeScript | `clients/typescript/index.mjs`, `index.d.ts` | ESM runtime plus type declarations, including `explainTrace`, `exploreTrace`, `discoverTrace`, and `validateScenario` helpers |
| Python | `clients/python/zmr_client.py`, `pyproject.toml` | Standard-library importable module with `explain_trace`, `explore_trace`, `discover_trace`, and `validate_scenario` helpers |
| Go | `clients/go/zmr/client.go` | Normal Go package inside a module, including `ExplainTrace`, `ExploreTrace`, `DiscoverTrace`, and `ValidateScenario` helpers |
| Rust | `clients/rust/src/lib.rs` | Cargo library crate convention, including `explain_trace`, `explore_trace`, `discover_trace`, and `validate_scenario` helpers |
| Swift | `clients/swift/Sources/ZMRClient/ZMRClient.swift` | SwiftPM package for macOS host-side tools, including `explainTrace`, `exploreTrace`, `discoverTrace`, and `validateScenario` helpers |
| Kotlin | `clients/kotlin/src/main/kotlin/dev/zmr/ZmrClient.kt` | Gradle/Kotlin source package for JVM host-side tools, including `explainTrace`, `exploreTrace`, `discoverTrace`, and `validateScenario` helpers |

Rust has `src/lib.rs` because Cargo expects a library crate there. The other
clients do have equivalent entry points; they are just idiomatic for their
languages rather than named `lib.rs`. Swift and Kotlin are useful for native
mobile teams, but they still run on the development machine and drive the
external `zmr` binary. They are not app-runtime SDKs.

## Quick Starts

TypeScript:

```bash
node clients/typescript/examples/fake-session.mjs
```

Python:

```bash
python3 clients/python/examples/fake_session.py
```

Go:

```bash
go run ./clients/go/examples/fake-session \
  --zmr ./zig-out/bin/zmr \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-go-client
```

Rust:

```bash
cargo run --manifest-path clients/rust/Cargo.toml --example fake_session -- \
  --zmr ./zig-out/bin/zmr \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-rust-client
```

Swift:

```bash
swift build --package-path clients/swift
```

Kotlin:

```bash
gradle -p clients/kotlin build
```

For real app usage, replace the fake server with `zmr serve --transport stdio`
and pass `.zmr/config.json`.
