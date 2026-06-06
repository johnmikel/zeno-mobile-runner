# Agent Discovery

ZMR supports agent-led discovery today through its JSON-RPC and MCP interfaces,
trace events, semantic snapshot artifacts, guarded trace exploration, in-band
trace discovery, and offline scenario drafting. An external agent can observe
the app, choose typed actions, inspect trace events, ask ZMR to write a small
repeatable scenario from the trace, and then edit it as it learns a flow.

`zmr explore` is the built-in review-first exploration command. It is
trace-backed, not an unbounded crawler: it does not launch devices, invent
missing actions, discover credentials, or commit files. Keep autonomous
planning in the agent, and keep ZMR as the deterministic mobile control plane.

## Recommended Loop

1. Validate local setup:

   ```bash
   zmr inspect --json --dir .
   zmr doctor --json --config .zmr/config.json
   zmr validate --json .zmr/ios-smoke.json
   ```

2. Start a live session:

   ```bash
   zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
   ```

   Agents that speak MCP can use:

   ```bash
   zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
   ```

3. Call `runner.capabilities`, then `session.create`.
4. Call `observe.semanticSnapshot` before choosing an action.
5. Choose one typed action, such as `ui.tap`, `ui.type`, `app.openLink`, or
   `wait.until`.
6. Observe again and inspect `trace.events`.
7. If you used `zmr run --json --trace-dir`, read `nextCommands`; traced run
   summaries include HTML/JUnit report output and the matching
   `zmr discover --from-trace` command.
8. If you want the CLI run itself to write the candidate, use:

   ```bash
   zmr run .zmr/login-smoke.json \
     --trace-dir traces/zmr-agent \
     --discover-out .zmr/discovered/replay-smoke.json \
     --json
   ```

   The run response embeds `discovery`, the same JSON payload returned by
   `zmr discover --json`, including `replay` coverage metadata for converted
   and skipped trace actions.
9. Generate a reviewable scenario candidate from the trace. For CLI-driven
   agent loops, prefer `zmr explore` so the goal and guardrails travel with the
   machine-readable result:

   ```bash
   zmr explore --from-trace traces/zmr-agent \
     --out .zmr/discovered/login-smoke.json \
     --goal "find a stable login smoke" \
     --include-actions \
     --validate \
     --json
   ```

   The output is covered by `schemas/explore-output.schema.json` and includes
   `autonomous:false`, `reviewRequired:true`, `guardrails`, replay coverage,
   validation, and deterministic next commands.

10. Use the lower-level trace discovery primitive when the agent already owns
    goal tracking. JSON-RPC agents can
    call `trace.discover`:

   ```json
   {"jsonrpc":"2.0","id":7,"method":"trace.discover","params":{"out":".zmr/discovered/replay-smoke.json","includeActions":true,"validate":true,"force":true}}
   ```

   MCP agents can call `trace_discover` with the same `out`,
   `includeActions`, `validate`, and `force` arguments. The offline CLI
   equivalent is:

   ```bash
   zmr discover --from-trace traces/zmr-agent \
     --out .zmr/discovered/replay-smoke.json \
     --include-actions \
     --validate \
     --json
   ```

   `zmr discover` writes a scenario from trace evidence and, with
   `--validate`, immediately proves that the generated file is syntactically
   runnable by ZMR. It is still review-first: it does not crawl, invent missing
   actions, discover credentials, or commit the scenario.
   Read the `replay` object before trusting coverage: `eventCount` is the
   trace action event count considered for replay, `stepCount` is the number of
   generated replay steps, and `skippedEventCount` is the number of events left
   out.

11. After editing a generated scenario, validate it in-band with JSON-RPC:

   ```json
   {"jsonrpc":"2.0","id":8,"method":"scenario.validate","params":{"path":".zmr/discovered/replay-smoke.json"}}
   ```

   MCP agents can call `scenario_validate` with the same `path` argument. The
   result matches `zmr validate --json`, including field paths and source
   locations for invalid files.

12. Use the lower-level draft primitive when you want separate surface and
   replay files. For a conservative surface-smoke scenario:

   ```bash
   zmr draft --from-trace traces/zmr-agent \
     --out .zmr/discovered/surface-smoke.json \
     --json
   ```

   The draft contains `launch`, `snapshot`, and `assertVisible` steps from
   stable visible selectors. It does not tap, type, crawl, or commit anything.
   If the trace contains successful typed actions and you want a replayable
   starting point, include those supported events explicitly:

   ```bash
   zmr draft --from-trace traces/zmr-agent \
     --out .zmr/discovered/replay-smoke.json \
     --include-actions \
     --json
   ```

   Replay drafts include only supported events with stable replay data, such as
   launch, deep links, selector taps, selector text entry, back, keyboard hiding,
   coordinate-complete swipes, selector/timeout-preserving waits, and
   direction/timeout-preserving selector scrolls, selector/timeout-preserving
   `assertVisible` and `assertNotVisible`, `assertNoneVisible` selector arrays,
   and timed `assertHealthy` checks. Native selector wait traces also retain
   timeout context for successful waits and timeout diagnostics.
   Unsupported events stay out of the scenario and are reported as warnings.

13. Edit the draft, discovery, or exploration output into a candidate flow, for example
   `.zmr/discovered/login-smoke.json`, by copying only steps that were observed
   and understood.
14. Validate the candidate scenario:

   ```bash
   zmr validate --json .zmr/discovered/login-smoke.json
   ```

15. Re-run it deterministically:

   ```bash
   zmr run .zmr/discovered/login-smoke.json \
     --platform ios \
     --device booted \
     --trace-dir traces/zmr-login-smoke \
     --json
   ```

16. Export a redacted bundle before sharing artifacts:

    ```bash
    zmr export traces/zmr-login-smoke \
      --out traces/zmr-login-smoke-redacted.zmrtrace \
      --redact
    ```

## Guardrails

- Set a step budget and a time budget before discovery starts.
- Restrict discovery to known app ids, deep-link schemes, and test accounts.
- Do not ask an agent to discover credentials or secrets.
- Prefer accessibility identifiers, resource ids, stable labels, and exact text
  over coordinates.
- Require human review before committing generated tests.
- Treat `zmr explore` output as a starting point, not as a production-ready
  flow.
- Treat `zmr discover` output as a starting point, not as a production-ready
  flow.
- Treat `zmr draft` output as a starting point, not as a production-ready flow.
- Use `--include-actions` only after reviewing the trace events that produced
  the replay draft.
- Redact traces before sharing them outside the local team.

## Current Shape

`zmr explore` is the first shipped goal-carrying command in this loop. It still
requires an existing trace because the current product direction is to keep
scenario generation explicit, reviewable, and trace-backed before any future
goal-driven crawler can safely act inside an app.
