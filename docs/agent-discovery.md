# Agent Discovery

ZMR supports agent-led discovery today through its JSON-RPC and MCP interfaces,
trace events, semantic snapshot artifacts, in-band trace discovery, and offline
scenario drafting. An external agent can observe the app, choose typed actions,
inspect trace events, draft a small repeatable scenario from the trace, and
then edit it as it learns a flow.

ZMR does not include a built-in autonomous crawler or fully autonomous test
writer in this developer preview. Keep the planning loop in the agent, and keep
ZMR as the deterministic mobile control plane.

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
7. Generate a reviewable scenario candidate from the trace. JSON-RPC agents can
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

8. After editing a generated scenario, validate it in-band with JSON-RPC:

   ```json
   {"jsonrpc":"2.0","id":8,"method":"scenario.validate","params":{"path":".zmr/discovered/replay-smoke.json"}}
   ```

   MCP agents can call `scenario_validate` with the same `path` argument. The
   result matches `zmr validate --json`, including field paths and source
   locations for invalid files.

9. Use the lower-level draft primitive when you want separate surface and
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
   launch, deep links, selector taps, selector text entry, waits, back, keyboard
   hiding, and selector scrolls. Unsupported events stay out of the scenario and
   are reported as warnings.

10. Edit the draft or discovery output into a candidate flow, for example
   `.zmr/discovered/login-smoke.json`, by copying only steps that were observed
   and understood.
11. Validate the candidate scenario:

   ```bash
   zmr validate --json .zmr/discovered/login-smoke.json
   ```

12. Re-run it deterministically:

   ```bash
   zmr run .zmr/discovered/login-smoke.json \
     --platform ios \
     --device booted \
     --trace-dir traces/zmr-login-smoke \
     --json
   ```

13. Export a redacted bundle before sharing artifacts:

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
- Treat `zmr discover` output as a starting point, not as a production-ready
  flow.
- Treat `zmr draft` output as a starting point, not as a production-ready flow.
- Use `--include-actions` only after reviewing the trace events that produced
  the replay draft.
- Redact traces before sharing them outside the local team.

## Future Shape

A future command could add goal-driven exploration on top of this loop:

```bash
zmr explore --goal "find the login flow" --out .zmr/discovered/login-smoke.json
```

That command is not shipped today. The current product direction is to keep
scenario discovery explicit, reviewable, and trace-backed before it becomes a
goal-driven crawler.
