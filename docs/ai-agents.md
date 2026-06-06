# AI Agent Guide

ZMR is built for external agents. The runner provides device state, typed
actions, waits, assertions, and trace export; the agent decides the next step.

## Agent Setup Loop

Start inside the app checkout:

```bash
zmr inspect --json --dir .
zmr doctor --json --config .zmr/config.json
zmr validate --json .zmr/android-smoke.json
zmr validate --json .zmr/ios-smoke.json
zmr schemas --json
```

Use `zmr doctor --strict --json` in CI or setup flows that should fail on any
warning. Prefer JSON output for automation because it includes stable error
codes, field paths, and remediation hints.

Use `zmr inspect --json --dir .` first when an agent enters a repo. It is a
read-only handoff with config status, generated agent instruction status,
platform smoke scenario paths, safe next commands, and explicit claim limits.

## Live JSON-RPC Session

Agents should prefer `zmr serve` for interactive work:

```bash
zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent
```

Recommended flow:

1. Call `runner.capabilities` and check protocol/platform support.
2. Call `session.create`.
3. Call `observe.semanticSnapshot` when choosing the next action, or
   `observe.snapshot` when raw adapter details are needed.
4. Choose one typed action or assertion.
5. Let ZMR settle, then observe again.
6. Poll `trace.events` during long runs.
7. Call `trace.discover` when you want a reviewable scenario candidate from
   the active trace.
8. Call `scenario.validate` after editing generated scenario files.
9. Call `trace.export` with `redact: true` before sharing artifacts.
10. Call `session.close`.

Do not parse screenshots or terminal text when the same fact is available from
snapshot nodes, action results, CLI JSON, or trace events.

If `zmr run --json` returns `status: "partial"`, inspect `partialFailure`.
For iOS visual captures, `artifactStatus: "captured"` with
`semanticStatus: "failed"` means screenshot proof exists but accessibility or
XCTest hierarchy extraction failed. Use `zmr explain --json <trace-dir>` for
the same diagnostic shape after the run.

For traced CLI runs, `zmr run --json` also returns `nextCommands` with the
HTML/JUnit report, explain, `zmr discover --from-trace`, and redacted export
handoffs.
Agents should prefer those commands over reconstructing trace paths from text.
When an agent should create the reviewable scenario in the same process, pass
`--discover-out .zmr/discovered/<name>.json`; the run JSON will include a
`discovery` object with validation results and `replay` coverage metadata.

## MCP Session

Agents that support the Model Context Protocol can use ZMR directly as a local
stdio MCP server:

```bash
zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
```

The MCP server exposes mobile-specific tools:

- `snapshot`: raw ZMR observation JSON
- `semantic_snapshot`: normalized roles, names, selectors, bounds, and
  recommended actions
- `install_app`, `launch_app`, `stop_app`, and `clear_state`
- `tap`, `type`, `erase_text`, `hide_keyboard`, `swipe`, `press_back`,
  `open_link`, and `scroll_until_visible`
- `wait_visible`, `wait_not_visible`, and `wait_any`
- `assert_visible`, `assert_not_visible`, and `assert_healthy`
- `scenario_validate`
- `trace_events`, `trace_discover`, and `trace_export`

Prefer `semantic_snapshot` for action planning. It avoids forcing an agent to
infer intent from platform-specific Android/UI Automator or XCTest class names.

## Agent-Led Discovery

Agents can use ZMR to discover flows and draft scenarios by looping over
`observe.semanticSnapshot`, one typed action, trace events, and scenario
validation. After a session has produced trace artifacts, call JSON-RPC
`trace.discover` or MCP `trace_discover` to create and validate a reviewable
starting point without leaving the live agent session. Use JSON-RPC
`scenario.validate` or MCP `scenario_validate` after edits. The CLI command is
the offline equivalent:

```bash
zmr discover --from-trace traces/zmr-agent \
  --out .zmr/discovered/replay-smoke.json \
  --include-actions \
  --validate \
  --json
```

`zmr discover` is review-first. It writes from trace evidence, validates the
generated scenario when asked, and returns next commands for deterministic
reruns. It does not crawl, discover credentials, or commit tests. The JSON
`replay` object lets agents compare trace action events considered for replay,
generated replay steps, and skipped events before making coverage claims.

Use `zmr draft` when you want the lower-level split workflow. It writes
`launch`, `snapshot`, and conservative `assertVisible` checks by default. For
traces produced by an agent session with successful typed actions, add
`--include-actions` to generate a replay draft from supported events before the
final snapshot assertions:

```bash
zmr draft --from-trace traces/zmr-agent \
  --out .zmr/discovered/replay-smoke.json \
  --include-actions \
  --json
zmr validate --json .zmr/discovered/replay-smoke.json
```

Unsupported or underspecified events are skipped with warnings instead of being
guessed. Supported replay steps preserve selector and timeout data for waits,
selector and timeout data for `assertVisible` and `assertNotVisible`, selector
arrays for `assertNoneVisible`, and timeouts for `assertHealthy` when the trace
records them. See [Agent Discovery](agent-discovery.md) for the
recommended reviewable loop.

ZMR does not ship a built-in autonomous crawler or test writer in this developer
preview. Keep autonomous planning outside the runner, then commit only reviewed
scenario JSON.

## Scenario File Workflow

For repeatable tests, generate or edit `.zmr/*.json` scenarios:

```bash
zmr validate --json .zmr/login-smoke.json
zmr run .zmr/login-smoke.json --json --trace-dir traces/zmr-login-smoke
zmr explain --json traces/zmr-login-smoke
zmr export traces/zmr-login-smoke --out traces/zmr-login-smoke-redacted.zmrtrace --redact
```

Use stable selectors in this order when available:

- app accessibility identifiers or resource ids
- content descriptions or accessibility labels
- exact visible text for stable product copy
- `textContains` only when the visible text legitimately varies
- coordinate actions only as a last resort

Use `waitAny` for screens with legitimate branches, and `whenVisible` for
optional platform or dev-client screens. Keep credentials and app-private data
in the app repository or environment, not in public scenarios.

## Failure Triage

When a run fails, inspect:

- `zmr run --json` terminal summary
- `zmr explain --json <trace-dir>`
- `trace.json`
- `events.jsonl`
- the last snapshot JSON
- the trace viewer report from `zmr report`

Selector failures include active app context, visible text, disabled/hidden or
offscreen exact candidates, and nearest text matches when available. Treat
those diagnostics as the source of truth before changing a selector.

## Benchmarking

Use ZMR repeated runs first:

```bash
zmr-benchmark --zmr .zmr/android-smoke.json --platform android --device emulator-5554 --app-id com.example.mobiletest --app-build <build-id-or-artifact> --runs 20 --trace-root traces/zmr-android-reliability --results traces/bench-comparison/results.jsonl --replace --min-pass-rate 100 --max-failures 0
```

For a fair comparison with an app-local baseline command, collect normalized
rows and compare them:

```bash
zmr-benchmark-command --tool baseline --platform android --device emulator-5554 --app-id com.example.mobiletest --scenario .zmr/android-smoke.json --app-build <build-id-or-artifact> --runs 20 --trace-root traces/baseline --results traces/bench-comparison/results.jsonl -- <baseline command>
zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl --candidate zmr --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25 --out traces/bench-comparison/comparison.md --evidence-out traces/bench-comparison/evidence.jsonl
```

Only share benchmark summaries when the candidate and baseline exercise
equivalent app paths under the same device state. Useful benchmark context
includes `platform`, `device`, `appId`, `scenario`, and `appBuild`, plus enough
candidate and baseline rows for your team to trust the result.

## Evidence Summaries

Teams that collect repeated app/device pilot rows can evaluate them with:

```bash
zmr-release-readiness --json \
  --evidence traces/zmr-pilots/evidence.jsonl \
  --target production
```

Use `satisfied` for proven requirements and `blocked`, `missing`,
`insufficient`, `failed`, and `planned` for remaining work. Use
`recommendedWording` for the human-facing status and keep
`claimLimitations` intact. When blocked, run `nextSteps[].commands` in order
and use `nextSteps[].covers` to map each command back to the blocked
requirements it resolves.

## Safety Rules

- Run `tests/public-safety-test.sh` before publishing docs, examples, or traces.
- Do not commit app-private traces, screenshots, credentials, tokens, bundle
  identifiers, or private app names.
- Prefer `zmr export --redact`; add `--omit-screenshots` for public bundles
  when visual artifacts may contain sensitive data.
- Keep app-local state under `.zmr/` and generated run output under `traces/`.
