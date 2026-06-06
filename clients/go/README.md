# ZMR Go Client

Small standard-library JSON-RPC client for driving `zmr serve --transport stdio`
from Go agents and test harnesses.

```go
client, err := zmr.Start(ctx, "zmr", "serve", "--transport", "stdio")
if err != nil {
    panic(err)
}
defer client.Close()

snapshot, err := client.Snapshot(ctx)
healthy, err := client.AssertHealthy(ctx, 1000)
explanation, err := client.ExplainTrace(ctx)
discovered, err := client.DiscoverTrace(ctx, ".zmr/discovered/go-agent.json", zmr.TraceDiscoverOptions{
    IncludeActions: true,
    Validate: true,
    Force: true,
})
explored, err := client.ExploreTrace(ctx, ".zmr/discovered/go-goal.json", "find a stable login smoke", zmr.TraceDiscoverOptions{
    IncludeActions: true,
    Validate: true,
    Force: true,
})
validation, err := client.ValidateScenario(ctx, discovered.Out)
```

Run the fake-session example from the repository root:

```sh
go run ./clients/go/examples/fake-session \
  --zmr ./zig-out/bin/zmr \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-go-client
```
