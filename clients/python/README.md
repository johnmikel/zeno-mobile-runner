# ZMR Python Reference Client

Standard-library Python client for host-side agents and harnesses using ZMR's
newline-delimited JSON-RPC protocol.

```python
from zmr_client import ZmrClient

with ZmrClient(
    "zmr",
    [
        "serve",
        "--transport", "stdio",
        "--device", "emulator-5554",
        "--app-id", "com.example.mobiletest",
        "--trace-dir", "traces/agent-session",
    ],
) as zmr:
    zmr.create_session()
    zmr.open_link("exampleapp://e2e-auth?probe=1")
    zmr.wait_until({"text": "E2E auth probe"}, timeout_ms=30000)
    snapshot = zmr.snapshot()
    events = zmr.trace_events(0, limit=100)
    explanation = zmr.explain_trace()
    discovered = zmr.discover_trace(
        ".zmr/discovered/agent-session.json",
        include_actions=True,
        validate=True,
        force=True,
    )
    explored = zmr.explore_trace(
        ".zmr/discovered/agent-goal.json",
        "find a stable login smoke",
        include_actions=True,
        validate=True,
        force=True,
    )
    validation = zmr.validate_scenario(discovered["out"])
    print(snapshot["nodes"])
    print(len(events["events"]))
    print(explanation["status"])
    print(discovered["out"])
    print(explored["reviewRequired"])
    print(validation["ok"])
    zmr.export_trace("traces/agent-session-redacted.zmrtrace", redact=True, omit_screenshots=True)
```

The client intentionally avoids runtime dependencies so agents can vendor or
copy it into automation harnesses easily.
