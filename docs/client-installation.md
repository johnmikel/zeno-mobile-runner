# Client Installation

ZMR has two layers:

1. The `zmr` binary controls devices, runs scenarios, serves JSON-RPC, and writes traces.
2. Language clients are optional wrappers around `zmr serve --transport stdio`.

For fastest adoption, install the binary once with npm, a release tarball, or
Homebrew. Then use a language client only when you want tests or agents written
in that language.

## Binary First

Today, install the GitHub release tarball:

```bash
npm install --save-dev https://github.com/johnmikel/zig-mobile-runner/releases/download/v0.1.0/zig-mobile-runner-0.1.0.tgz
npx zmr version
```

After the npm registry package is published:

```bash
npm install --save-dev zig-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
```

Homebrew is the best install path for non-JavaScript teams because it gives any
language the same `zmr` executable:

```bash
# Today, after downloading or building a release archive:
brew install --build-from-source ./dist/homebrew/zmr.rb

# Intended tap install after the tap is published:
brew tap johnmikel/zmr
brew install zmr
```

## TypeScript

```bash
npm install --save-dev zig-mobile-runner
```

```js
import { createZmrClient } from "zig-mobile-runner/clients/typescript/index.mjs";

const zmr = createZmrClient({
  command: "zmr",
  args: ["serve", "--transport", "stdio", "--config", ".zmr/config.json"],
});
```

## Python

```bash
python3 -m pip install "git+https://github.com/johnmikel/zig-mobile-runner.git#subdirectory=clients/python"
```

```python
from zmr_client import ZmrClient

with ZmrClient("zmr", ["serve", "--transport", "stdio", "--config", ".zmr/config.json"]) as zmr:
    zmr.create_session()
    snapshot = zmr.snapshot()
```

## Go

```bash
go get github.com/johnmikel/zig-mobile-runner/clients/go@main
```

```go
client, err := zmr.Start(ctx, "zmr", "serve", "--transport", "stdio", "--config", ".zmr/config.json")
```

## Rust

Until the Rust client is published as its own crate, add the repository as a
vendor checkout or submodule and depend on the client package by path:

```bash
git submodule add https://github.com/johnmikel/zig-mobile-runner.git vendor/zig-mobile-runner
```

```toml
[dependencies]
zmr-client = { path = "vendor/zig-mobile-runner/clients/rust" }
```

```rust
let mut client = zmr_client::Client::start("zmr", ["serve", "--transport", "stdio"])?;
```

## Swift

Until the Swift client is split into a standalone SwiftPM repository or package
registry entry, add the repository as a vendor checkout or submodule and use a
local SwiftPM package path:

```bash
git submodule add https://github.com/johnmikel/zig-mobile-runner.git vendor/zig-mobile-runner
```

```swift
.package(path: "vendor/zig-mobile-runner/clients/swift")
```

The Swift client is for macOS agent/test tools. It is not embedded in the iOS
app under test.

## Kotlin

Use the Kotlin client as source or build a local jar:

```bash
git submodule add https://github.com/johnmikel/zig-mobile-runner.git vendor/zig-mobile-runner
gradle -p vendor/zig-mobile-runner/clients/kotlin build
```

```kotlin
val zmr = ZmrClient(listOf("zmr", "serve", "--transport", "stdio", "--config", ".zmr/config.json"))
```

The Kotlin client is useful for Android teams that prefer Kotlin for host-side
test orchestration. It does not replace the Android app shim or run inside the
app process.

## Which Client Should You Use?

- Use only the CLI for committed `.zmr/*.json` scenarios and CI.
- Use TypeScript or Python for most AI agents because they are easy to generate
  and inspect.
- Use Go or Rust for long-running infrastructure services.
- Use Swift or Kotlin when native mobile teams want host-side tooling in their
  everyday language.

All clients call the same public JSON-RPC protocol, so feature parity should
come from the runner, not from language-specific behavior.
