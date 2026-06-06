# ZMR Language Clients

ZMR clients are small wrappers around the same newline-delimited JSON-RPC
protocol exposed by:

```bash
zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
```

They are intended for AI agents, CI harnesses, and app teams that want typed
or idiomatic calls without reimplementing JSON-RPC framing. TypeScript and
Python are the most direct starting points for app and agent automation. Go,
Rust, Swift, and Kotlin stay available as reference integrations for teams that
want to embed host-side orchestration in those ecosystems.
Each client includes `devices()` for `device.list`, including the portable
`ready` boolean, and a semantic snapshot helper for `observe.semanticSnapshot`
so agents can work from normalized roles, selectors, bounds, and recommended
actions instead of raw platform hierarchy classes.
The TypeScript and Python clients expose the broadest app-facing control
surface: session lifecycle, app launch/stop/link/state, snapshot and semantic
snapshot, tap/type/erase/hide-keyboard/swipe/back/scroll, waits, assertions,
scenario validation, trace event polling, trace discovery, and trace export.
The Go and Rust clients also include typed scenario validation and trace
discovery helpers. Swift includes lightweight validation and discovery helpers
for macOS host-side agents. Kotlin remains a smaller reference client for teams
that want to embed the protocol shape in that ecosystem.
Use the `assertHealthy`/`assert_healthy` helper after launches, links, and major
navigation steps to catch native crash overlays and development-client failures
without hand-maintaining negative selectors in every client.

For install commands across package managers, see
[docs/client-installation.md](../docs/client-installation.md).

## TypeScript

Runtime: `clients/typescript/index.mjs`
Types: `clients/typescript/index.d.ts`

```bash
node clients/typescript/examples/fake-session.mjs
```

```js
import { createZmrClient } from "./clients/typescript/index.mjs";

const zmr = createZmrClient({
  command: "zmr",
  args: ["serve", "--transport", "stdio", "--config", ".zmr/config.json"],
});
```

## Python

Runtime: `clients/python/zmr_client.py`

```bash
python3 -m pip install "git+https://github.com/johnmikel/zeno-mobile-runner.git#subdirectory=clients/python"
```

```bash
python3 clients/python/examples/fake_session.py
```

```python
from zmr_client import ZmrClient

with ZmrClient("zmr", ["serve", "--transport", "stdio", "--config", ".zmr/config.json"]) as zmr:
    snapshot = zmr.snapshot()
```

## Go

Runtime: `clients/go/zmr/client.go`

```bash
go get github.com/johnmikel/zeno-mobile-runner/clients/go@main
```

```bash
go run ./clients/go/examples/fake-session \
  --zmr ./zig-out/bin/zmr \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-go-client
```

```go
client, err := zmr.Start(ctx, "zmr", "serve", "--transport", "stdio", "--config", ".zmr/config.json")
discovered, err := client.DiscoverTrace(ctx, ".zmr/discovered/go-agent.json", zmr.TraceDiscoverOptions{IncludeActions: true, Validate: true, Force: true})
validation, err := client.ValidateScenario(ctx, discovered.Out)
```

## Rust

Runtime: `clients/rust/src/lib.rs`

Cargo packages library code from `src/lib.rs` by convention. Because this repo
is not yet published as a Rust crate, consume the client from a local checkout:

```bash
git submodule add https://github.com/johnmikel/zeno-mobile-runner.git vendor/zeno-mobile-runner
```

```toml
[dependencies]
zmr-client = { path = "vendor/zeno-mobile-runner/clients/rust" }
```

```bash
cargo run --manifest-path clients/rust/Cargo.toml --example fake_session -- \
  --zmr ./zig-out/bin/zmr \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-rust-client
```

```rust
let mut client = zmr_client::Client::start("zmr", ["serve", "--transport", "stdio", "--config", ".zmr/config.json"])?;
let snapshot = client.snapshot()?;
let discovered = client.discover_trace(".zmr/discovered/rust-agent.json", zmr_client::TraceDiscoverOptions {
    include_actions: true,
    validate: true,
    force: true,
    ..Default::default()
})?;
let validation = client.validate_scenario(&discovered.out)?;
```

## Swift

Runtime: `clients/swift/Sources/ZMRClient/ZMRClient.swift`

Use the Swift client from a local SwiftPM package path until it is published as
a standalone Swift package:

```bash
git submodule add https://github.com/johnmikel/zeno-mobile-runner.git vendor/zeno-mobile-runner
```

```swift
.package(path: "vendor/zeno-mobile-runner/clients/swift")
```

```swift
let client = ZMRClient(arguments: ["serve", "--transport", "stdio", "--config", ".zmr/config.json"])
try client.start()
let out = ".zmr/discovered/swift-agent.json"
let discovered = try client.discoverTrace(
    out: out,
    options: TraceDiscoverOptions(includeActions: true, validate: true, force: true)
)
let validation = try client.validateScenario(path: out)
client.close()
```

Swift is useful for macOS host-side automation next to iOS app code. It is not
an SDK embedded in the app under test.

## Kotlin

Runtime: `clients/kotlin/src/main/kotlin/dev/zmr/ZmrClient.kt`

```bash
git submodule add https://github.com/johnmikel/zeno-mobile-runner.git vendor/zeno-mobile-runner
gradle -p vendor/zeno-mobile-runner/clients/kotlin build
```

Kotlin is useful for Android teams that want host-side orchestration in Kotlin.
It still drives the external `zmr` binary.

Rust has `src/lib.rs` because Cargo packages libraries from that path by
convention. The other clients use the equivalent idiomatic layout for their
ecosystem: ESM entry file for TypeScript, a pip-installable Python module, a Go
package directory, a SwiftPM package, and a Gradle/Kotlin source package.
