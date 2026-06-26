# Command Reference

This page documents the public command surface from a DX and agent handoff
perspective. Each command should be understandable without reading source code.

## Setup And Metadata

| Command | What it does | Agent use | CI use | Failure behavior | Artifacts |
| --- | --- | --- | --- | --- | --- |
| `zmr version --json` | Prints runner and protocol versions | Confirm protocol support before tool use | Pin and record runner version | Exits nonzero for runtime failures | JSON metadata |
| `zmr schemas --json` | Lists public JSON schemas | Fetch contracts for scenario and protocol generation | Validate generated artifacts against known schemas | Unknown flags fail | JSON schema list |
| `zmr inspect --json --dir <app-root>` | Reads app-local ZMR setup without touching devices | First command when entering an app repo | Setup audit before device jobs | Reports missing config and next commands | JSON inspection |
| `zmr doctor --strict --json` | Checks host, app config, and platform dependencies | Decide whether the agent can touch a device | Gate CI setup before running scenarios | Strict mode exits nonzero on warnings | JSON checks and remediation hints |

## Scenario Lifecycle

| Command | What it does | Agent use | CI use | Failure behavior | Artifacts |
| --- | --- | --- | --- | --- | --- |
| `zmr init --app` | Scaffolds app-local config, scenarios, scripts, and agent notes | Bootstrap a repo before the first device run | Standardize setup across apps | Refuses unsafe overwrite without `--force` | `.zmr/` files and optional package scripts |
| `zmr import maestro` | Imports a Maestro YAML smoke flow into ZMR JSON | Migrate existing smoke tests into reviewed JSON | One-time migration during rollout | Unsupported commands fail instead of being guessed | Scenario JSON and compatibility report |
| `zmr validate --json <scenario>` | Validates scenario syntax and schema | Check generated or edited scenarios before run | Required preflight for committed scenarios | Field errors return stable diagnostics | JSON validation result |
| `zmr draft --from-trace` | Drafts a conservative scenario from trace snapshots | Turn observed UI into a review candidate | Seed smoke scenarios from known-good traces | Requires trace evidence | Scenario JSON |
| `zmr discover --from-trace` | Generates replay-oriented scenario candidates | Convert exploratory agent sessions into reviewed tests | Backfill deterministic tests from evidence | Skips unsupported events with warnings | Scenario JSON and replay metadata |
| `zmr explore --from-trace --goal` | Adds goal and guardrails to trace-backed discovery | Produce review-required scenario candidates with intent | Audit generated coverage before commit | Requires explicit output path | Scenario JSON and guardrails |

## Device And Runtime

| Command | What it does | Agent use | CI use | Failure behavior | Artifacts |
| --- | --- | --- | --- | --- | --- |
| `zmr devices --json` | Lists Android and iOS targets | Choose a device explicitly | Inventory local matrix targets | Missing platform tools are reported | JSON device list |
| `zmr run --json <scenario>` | Executes a deterministic scenario | Verify a product flow without an LLM in the loop | Main scenario execution command | Returns status, failure, and next commands | Trace directory |
| `zmr serve --transport stdio` | Starts JSON-RPC control plane | Embed ZMR in a custom harness or agent runtime | Advanced harness integration | Protocol errors are structured | Active trace directory |
| `zmr mcp` | Starts the MCP server | Primary AI coding agent integration | Agent-driven CI experiments | Tool errors return typed results | Active trace directory |

## Evidence

| Command | What it does | Agent use | CI use | Failure behavior | Artifacts |
| --- | --- | --- | --- | --- | --- |
| `zmr explain --json <trace-dir>` | Summarizes trace status and failure diagnostics | Debug before changing code or selectors | Store machine-readable failure context | Invalid traces fail with trace error codes | JSON diagnostic |
| `zmr report <trace-dir> --out <html> --junit <xml>` | Renders human and CI reports | Share trace outcome with humans | Upload HTML and JUnit artifacts | Missing trace/report paths fail | HTML and JUnit |
| `zmr export <trace-dir> --out <bundle.zmrtrace> --redact` | Creates portable trace bundle | Share evidence safely | Attach redacted evidence to CI or issue tracker | Invalid trace or output path fails | `.zmrtrace` |

## Common Patterns

Agent live verification:

```bash
zmr mcp --config .zmr/config.json --trace-dir traces/zmr-live
zmr report traces/zmr-live --out traces/zmr-live/report.html --junit traces/zmr-live/junit.xml
zmr export traces/zmr-live --out traces/zmr-live.zmrtrace --redact
```

Maestro smoke migration:

```bash
zmr import maestro flows/login.yaml --out .zmr/login-smoke.json --json
zmr validate --json .zmr/login-smoke.json
zmr run .zmr/login-smoke.json --json --trace-dir traces/zmr-login-smoke
```

Evidence-first failure triage:

```bash
zmr explain --json traces/zmr-login-smoke
zmr report traces/zmr-login-smoke --out traces/zmr-login-smoke/report.html --junit traces/zmr-login-smoke/junit.xml
```
