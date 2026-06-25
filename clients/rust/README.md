# ZMR Rust Client

Small synchronous JSON-RPC client for Rust agents and host-side test harnesses
that drive `zmr serve --transport stdio`.

```rust
let mut client = zmr_client::Client::start(
    "zmr",
    ["serve", "--transport", "stdio", "--config", ".zmr/config.json"],
)?;
let snapshot = client.snapshot()?;
let healthy = client.assert_healthy(Some(1000))?;
let explanation = client.explain_trace()?;
let discovered = client.discover_trace(
    ".zmr/discovered/rust-agent.json",
    zmr_client::TraceDiscoverOptions {
        include_actions: true,
        validate: true,
        force: true,
        ..Default::default()
    },
)?;
let explored = client.explore_trace(
    ".zmr/discovered/rust-goal.json",
    "find a stable login smoke",
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
