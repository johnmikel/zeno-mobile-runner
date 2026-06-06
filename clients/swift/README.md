# ZMR Swift Client

Small Foundation-based client for macOS test harnesses and agents that drive
`zmr serve --transport stdio`.

Add it to a Swift package. Until this client is published as a standalone Swift
package, consume it from a local checkout:

```bash
git submodule add https://github.com/johnmikel/zeno-mobile-runner.git vendor/zeno-mobile-runner
```

```swift
.package(path: "vendor/zeno-mobile-runner/clients/swift")
```

Then depend on the `ZMRClient` product from `clients/swift`.

```swift
let client = ZMRClient(arguments: ["serve", "--transport", "stdio", "--config", ".zmr/config.json"])
try client.start()
let out = ".zmr/discovered/swift-agent.json"
let discovered = try client.discoverTrace(
    out: out,
    options: TraceDiscoverOptions(includeActions: true, validate: true, force: true)
)
let explored = try client.exploreTrace(
    out: ".zmr/discovered/swift-goal.json",
    goal: "find a stable login smoke",
    options: TraceDiscoverOptions(includeActions: true, validate: true, force: true)
)
let validation = try client.validateScenario(path: out)
let explanation = try client.explainTrace()
client.close()
```

Run the package test from this directory:

```bash
swift test
```

Run the fake-session example against a local checkout:

```bash
swift run ZMRFakeSession \
  --zmr ../../zig-out/bin/zmr \
  --adb ../../tests/fake-adb.sh \
  --trace-dir ../../traces/demo-swift-client \
  --trace-out ../../traces/demo-swift-client-redacted.zmrtrace
```

The Swift client is host-side. It is for macOS automation code, not code that
runs inside the iOS app.
