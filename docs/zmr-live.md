# ZMR Live

ZMR Live is the live agent verification workflow built from the existing MCP
server, trace directory, reports, and static viewer. It is not a separate cloud
service. The goal is to let an agent inspect a real device, act on typed mobile
state, produce a reviewable scenario, and export evidence.

## Start A Live Agent Session

Run the MCP server from the mobile app repository:

```bash
zmr mcp --config .zmr/config.json --trace-dir traces/zmr-live
```

Ask the agent to verify a concrete workflow:

```text
Launch the app, verify login reaches the dashboard, generate a replayable
scenario candidate, validate it, and export a redacted trace.
```

The agent should use this loop:

1. `semantic_snapshot`
2. One typed action such as `tap`, `type`, `swipe`, or `open_link`
3. A wait or assertion
4. `trace_explain` if anything fails
5. `trace_discover` or `trace_explore` to generate a reviewable scenario
6. `scenario_validate`
7. `trace_export` with redaction

## Inspect Evidence During Or After The Session

Generate a report:

```bash
zmr report traces/zmr-live --out traces/zmr-live/report.html --junit traces/zmr-live/junit.xml
```

Open the static viewer:

```bash
open viewer/index.html
```

For a portable bundle:

```bash
zmr export traces/zmr-live --out traces/zmr-live.zmrtrace --redact
open viewer/index.html
```

If the viewer and bundle are served over HTTP, link directly to the bundle:

```text
viewer/index.html?bundle=<url-to-zmrtrace>
```

## What The Agent Should Not Do

- Do not infer selectors from screenshots when `semantic_snapshot` includes a
  stable app-owned selector.
- Do not commit a generated scenario without review.
- Do not share raw traces from private apps. Export a redacted `.zmrtrace`.
- Do not turn optional AI analysis into a deterministic pass/fail gate.

## Product Direction

The next ZMR Live product step is a browser surface that watches the active
trace directory, shows MCP calls beside screenshots and semantic nodes, and has
one-click handoffs for report, scenario discovery, validation, rerun, and
redacted export. Until that UI exists, the workflow above is the supported
operator path.
