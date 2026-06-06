# ZMR Rust Client

Small synchronous JSON-RPC client for driving `zmr serve --transport stdio`
from Rust agents and test harnesses.

```rust
let mut client = zmr_client::Client::start(
    "zmr",
    ["serve", "--transport", "stdio", "--config", ".zmr/config.json"],
)?;
let snapshot = client.snapshot()?;
let healthy = client.assert_healthy(Some(1000))?;
let discovered = client.discover_trace(
    ".zmr/discovered/rust-agent.json",
    zmr_client::TraceDiscoverOptions {
        include_actions: true,
        validate: true,
        force: true,
        ..Default::default()
    },
)?;
let validation = client.validate_scenario(&discovered.out)?;
```

Run the fake-session example from the repository root:

```sh
cargo run --manifest-path clients/rust/Cargo.toml --example fake_session -- \
  --zmr ./zig-out/bin/zmr \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-rust-client
```
