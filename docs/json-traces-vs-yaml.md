# JSON Scenarios And Trace Evidence

ZMR accepts imported Maestro YAML as a migration input, but committed ZMR
scenarios are JSON. That is a product decision, not an implementation accident.

## Why JSON

AI agents and CI systems need strict machine contracts:

- Unknown fields are rejected instead of ignored.
- Validation can return stable field paths and source locations.
- Scenario generators can mutate structured objects without reformatting a DSL.
- JSON schemas can be used by editors, agents, and custom harnesses.
- Runtime output can include executable `nextCommands` without parsing terminal
  prose.

Human-readable syntax matters, but ZMR optimizes for reviewable automation. The
review loop should be: generate or edit JSON, validate it, run it, inspect the
trace, then commit the scenario.

## Why Traces

Most mobile failures are not explained by a final pass/fail status. ZMR writes
trace evidence so humans and agents can answer:

- What was visible when the action was chosen?
- Which selector was used?
- What did the device return?
- Which wait or assertion failed?
- What screenshot and UI hierarchy were captured?
- What commands should run next for report, explanation, discovery, or export?

The trace directory is the local source of truth. The `.zmrtrace` bundle is the
portable, redacted sharing format.

## Practical Contract

For every important workflow, keep these artifacts:

```bash
zmr validate --json .zmr/login-smoke.json
zmr run .zmr/login-smoke.json --json --trace-dir traces/login-smoke
zmr explain --json traces/login-smoke
zmr report traces/login-smoke --out traces/login-smoke/report.html --junit traces/login-smoke/junit.xml
zmr export traces/login-smoke --out traces/login-smoke.zmrtrace --redact
```

Agents should prefer these structured artifacts over screenshots alone. Screens
help disambiguate, but semantic snapshots, trace events, selector diagnostics,
and JSON results are the durable contract.

## When YAML Still Helps

Use YAML when evaluating an existing Maestro suite:

```bash
zmr import maestro flows/login.yaml --out .zmr/login-smoke.json --json
```

After import, treat the generated `.zmr/*.json` file as the source of truth.
Do not keep a long-term runtime dependency on two scenario formats unless the
team has a specific migration window.
