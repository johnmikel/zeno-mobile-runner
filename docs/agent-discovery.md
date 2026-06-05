# Agent Discovery

ZMR supports agent-led discovery today through its JSON-RPC and MCP interfaces.
An external agent can observe the app, choose typed actions, inspect trace
events, and write a repeatable scenario file as it learns a flow.

ZMR does not include a built-in autonomous crawler or test writer in this
developer preview. Keep the planning loop in the agent, and keep ZMR as the
deterministic mobile control plane.

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
7. Write successful steps into a candidate scenario, for example
   `.zmr/discovered/login-smoke.json`.
8. Validate the candidate scenario:

   ```bash
   zmr validate --json .zmr/discovered/login-smoke.json
   ```

9. Re-run it deterministically:

   ```bash
   zmr run .zmr/discovered/login-smoke.json \
     --platform ios \
     --device booted \
     --trace-dir traces/zmr-login-smoke \
     --json
   ```

10. Export a redacted bundle before sharing artifacts:

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
- Redact traces before sharing them outside the local team.

## Future Shape

A future command could wrap this loop:

```bash
zmr explore --goal "find the login flow" --out .zmr/discovered/login-smoke.json
```

That command is not shipped today. The safer product direction is to make
scenario discovery explicit, reviewable, and trace-backed before it becomes a
one-command workflow.
