# ZMR 1.0 M0 Trust Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the exact ZMR revision under test produce green required CI and complete, classified, statistically honest device-run evidence even when failure occurs before a scenario trace starts.

**Architecture:** Add a dependency-free Python evidence core with a durable command supervisor and a thin Bash 3.2 adapter. The Python core owns canonical run-summary/bootstrap-event contracts, private write-ahead command state, session ownership, crash recovery, atomic finalization, classification, comparability hashes, and aggregation; existing demo/pilot/matrix scripts use the adapter without becoming lifecycle authorities. CI wraps each platform run in this evidence lifecycle, and release-readiness recomputes rather than trusts cohort keys.

**Tech Stack:** Zig 0.16 schema registry, Python 3 standard library, GNU Bash 3.2 compatibility, JSON Schema draft 2020-12, GitHub Actions, GitHub REST API.

---

## Scope and execution constraints

This plan implements only M0 from
`docs/superpowers/specs/2026-07-11-zmr-1-0-m0-trust-baseline-design.md`.
It does not refactor the runner, add mobile commands, implement sharding, fix all
iOS/Android flakes, or bump the public version. An observed device failure may
remain red after M0, but it must become classified and diagnosable.

Use @superpowers:test-driven-development for every behavior change. Before any
completion claim, use @superpowers:verification-before-completion. Commit after
each task; do not combine unrelated tasks into one commit.

The implementation worktree is:

```text
/Users/johnmikelregida/.config/superpowers/worktrees/zeno-mobile-runner/production-1-0
```

## File map

### New files

- `schemas/run-summary.schema.json` — public terminal attempt-summary contract.
- `schemas/bootstrap-event.schema.json` — public bootstrap JSONL event contract.
- `scripts/run_evidence.py` — dependency-free evidence core and CLI.
- `scripts/run_evidence_lib/command_state.py` — private command-state schema,
  write-ahead transitions, leases, and recovery inspection.
- `scripts/run_evidence_lib/command_supervisor.py` — process-group lifecycle,
  concurrent stream draining, bounded raw capture, and signal delivery.
- `scripts/run_evidence_lib/session.py` — owner/borrower claims, bounded terminal
  intent, command registry, and owner-only finalization dispatch.
- `scripts/run-evidence.sh` — GNU Bash 3.2-compatible adapter over the Python
  session and command APIs.
- `tests/run_evidence_test.py` — Python unit tests for contracts, hashing,
  finalization, classification, and statistics.
- `tests/run_evidence_cases/command_state.py` — private-state schema,
  transition, lease, and recovery tests.
- `tests/run_evidence_cases/command_supervisor.py` — process-group, stream,
  signal, capture, and crash-injection tests.
- `tests/run_evidence_cases/session.py` — owner/borrower, terminal-intent, and
  exactly-once finalization tests.
- `tests/run-evidence-script-test.sh` — shell integration and injected-failure
  tests.
- `tests/run-evidence-acceptance-test.sh` — table-driven fake-driver acceptance
  tests for every required failure-injection boundary and complete artifact
  bundle.
- `src/run_outcome.zig` and `src/run_outcome_tests.zig` — bounded atomic
  producer-to-wrapper outcome sidecar used by instrumented `zmr run` calls;
  this is an internal M0 boundary, not a third public schema.
- `scripts/run_evidence_lib/run_outcome.py` and
  `tests/run_evidence_cases/run_outcome.py` — strict sidecar validation and
  translation into evidence context/terminal intent outside the generic
  command supervisor.
- `tests/workflow-pinning-test.py` — immutable action/toolchain policy tests.
- `docs/run-evidence.md` — operator guide for summaries, phases,
  classification, reproduction, and certification.

### Modified files

- `README.md` — remove the denied vendor-specific plugin phrase while preserving
  truthful distribution documentation.
- `tests/docs-readiness-test.sh` — align outcome checks with the current README
  structure rather than the replaced older copy.
- `src/schema_registry.zig` and `src/schema_registry_tests.zig` — register and
  test the two new public schemas.
- `schemas/README.md` and `tests/schemas-json-test.sh` — document/index the
  contracts and update the schema count from 24 to 26.
- `scripts/run_evidence_lib/commands.py`,
  `scripts/run_evidence_lib/constants.py`,
  `scripts/run_evidence_lib/cli.py`,
  `scripts/run_evidence_lib/lifecycle.py`,
  `scripts/run_evidence_lib/summaries.py`, and
  `scripts/run_evidence_lib/bundle.py` — route command execution through the
  durable supervisor, enforce the lock/recovery protocol, and keep private
  control state out of publishable bundles.
- `tests/run_evidence_cases/commands.py`,
  `tests/run_evidence_cases/cli.py`,
  `tests/run_evidence_cases/lifecycle.py`, and
  `tests/run_evidence_cases/bundle.py` — cover the refactored command/session
  CLI, concurrent lifecycle operations, and control-state publication gate.
- `scripts/demo-android-real.sh`, `scripts/demo-ios-real.sh` — emit top-level
  build/device/pilot phases when an evidence context is present.
- `scripts/run-android-pilot.sh`, `scripts/run-ios-pilot.sh` — emit validation,
  install, shim, scenario, report, and cleanup phases.
- `src/cli_run.zig`, `src/cli_output.zig`, `src/cli_run_tests.zig`,
  `src/cli_output_tests.zig`, and `src/main_tests.zig` — expose and verify the
  atomic run-outcome sidecar without changing normal `zmr run --json` output.
- `scripts/device-matrix.sh` — create distinct logical execution/attempt metadata
  and retain every attempt summary.
- `tests/android-real-demo-script-test.sh`, `tests/ios-real-demo-script-test.sh`,
  `tests/android-pilot-script-test.sh`, `tests/ios-pilot-script-test.sh`, and
  `tests/device-matrix-test.sh` — assert phase and failure evidence behavior.
- `scripts/release-readiness.sh`, `scripts/release-readiness.py`,
  `schemas/release-readiness-output.schema.json`, and
  `tests/release-readiness-script-test.sh` — consume attempt summaries and report
  honest cohort statistics.
- `.github/workflows/ci.yml`, `.github/workflows/device-smoke.yml`, and
  `.github/workflows/release.yml` — stable gates, least privilege, evidence
  upload, immutable action pins, and verified toolchains.
- `tests/workflow-readiness-test.sh`, `scripts/ci-gate.sh`, and
  `scripts/release-gate.sh` — enforce the workflow/evidence policy.
- `docs/production-readiness.md`, `docs/benchmarking.md`, `FEATURES.md`, and
  `CHANGELOG.md` — document M0 behavior and claim boundaries.

## Stable constants selected by this plan

- Required GitHub check: `CI / quality-gate`.
- Default CI/device evidence retention: 14 days.
- Default release artifact retention: 30 days.
- Default command log limit: 10 MiB per log; retain the first and final 5 MiB
  and record `truncated: true`.
- Raw shell capture is limited to 1 MiB per requested stream. Raw argv,
  environment values, and command output never enter private command state or
  the publication root; only sanitized 10 MiB recovery spools/logs do.
- Private supervisor state lives only under
  `<attempt>/.evidence-control/`. `validate-bundle` refuses to publish while
  that tree exists; recovery verifies and removes committed state before a
  read-only validation succeeds.
- Private limits are: 16 KiB `session.json`, 32 KiB
  `terminal-intent.json`, 64 KiB per command `state.json`, eight secondary
  terminal diagnostics, and eight concurrently active commands.
- Command and session IDs are 32 lowercase hexadecimal characters. A request
  accepts at most 256 argv elements, 16 KiB per element, and 64 KiB total
  encoded argv.
- Command-supervisor readiness and evidence-lock acquisition each time out
  after five seconds. TERM grace is two seconds, KILL settlement is two
  seconds, and status polling uses a 50 ms interval.
- Task 4 adds stable runner codes `runner.command_supervisor_lost` and
  `runner.capture_failed`; all cleanup escalation continues to use
  `runner.cleanup_failed`.
- The shell adapter must parse and run under the system `/bin/bash` GNU Bash
  3.2 baseline; it may not require associative arrays, namerefs, `mapfile`,
  `readarray`, `wait -n`, dynamic file descriptors, or `&>>`.
- Attempt directories are append-only. `init` fails if its root already exists;
  a retry always receives a new root and never replaces an earlier summary.
- The publishable layout is
  `<publication-root>/attempt-index.json` plus
  `<publication-root>/attempts/<runId>/{run-summary.json,bootstrap-events.jsonl,commands/...,run-outcomes/...}`.
  `run-outcomes/` is optional and contains only bounded, registered, sanitized
  producer-to-wrapper sidecars; it is not part of the public schema registry.
  `ZMR_RUN_EVIDENCE_ROOT` names the attempt root and
  `ZMR_RUN_EVIDENCE_INDEX` names the sibling index.
- `attempt-index.json` paths are relative to the index location and use `/` as
  the separator. Absolute artifact paths are never publishable evidence.
- Default Tier 1 certification minimum: 300 eligible logical executions.
- Rust: `1.92.0`.
- `xcodeproj`: `1.28.1`.
- Zig: `0.16.0`, verified with the four platform checksums recorded in Task 8.

### Immutable action map

```text
actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd          # v5
actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16          # v6
actions/setup-java@0f481fcb613427c0f801b606911222b5b6f3083a       # v5
actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e       # v6
actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a   # v7
actions/attest@f6bf1532d7d6793fce74eac584813a8eee607999          # v4
softprops/action-gh-release@7c4723f7a335432393329f8f1c564994ce50185d # v3
reactivecircus/android-emulator-runner@4c44018e59b437e86cdfc41da381398f93ed8808 # v2
```

## Task 1: Restore the documentation and public-metadata gates

**Files:**

- Modify: `README.md:1-270`
- Modify: `tests/docs-readiness-test.sh:100-220`
- Test: `tests/public-metadata-guard-test.sh`
- Test: `tests/docs-readiness-test.sh`

- [ ] **Step 1: Reproduce both current failures**

Run:

```bash
bash tests/docs-readiness-test.sh
bash tests/public-metadata-guard-test.sh
```

Expected: the first fails on obsolete README phrases/headings; the second fails
because tracked README content contains the denied vendor-specific plugin name.

- [ ] **Step 2: Replace obsolete README assertions with current outcome checks**

Keep assertions that protect user outcomes and canonical links, but update
case-sensitive headings and removed detail. The relevant block should assert at
least:

```bash
require_grep 'Agent-native mobile UI automation' README.md
require_grep '## Why this exists' README.md
require_grep '### As an MCP server for a coding agent' README.md
require_grep '### Deterministic scenarios for CI' README.md
require_grep 'trace-to-test loop' README.md
require_grep '## Project status' README.md
require_grep 'docs/production-readiness.md' README.md
require_not_grep '<denied vendor-specific assistant name>' README.md
```

The executable readiness test uses the guard's concrete denied name; this
public plan keeps the example vendor-neutral.

Remove assertions for headings or timeout details intentionally moved to their
canonical documents. Do not remove the corresponding canonical-document checks.

- [ ] **Step 3: Make the README distribution wording vendor-neutral**

Replace the denied line with truthful generic wording, for example:

```markdown
- **Distribution.** Also shipped with an agent-plugin manifest
  (`.claude-plugin/`) and registered as an MCP server (`glama.json`).
```

Do not weaken `scripts/public-metadata-guard.sh`.

- [ ] **Step 4: Run the focused gates**

Run:

```bash
bash tests/docs-readiness-test.sh
bash tests/public-metadata-guard-test.sh
bash tests/public-safety-test.sh
git diff --check
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add README.md tests/docs-readiness-test.sh
git commit -m "fix(ci): restore public documentation gates"
```

## Task 2: Publish run-summary and bootstrap-event contracts

**Files:**

- Create: `schemas/run-summary.schema.json`
- Create: `schemas/bootstrap-event.schema.json`
- Modify: `src/schema_registry.zig:9-37`
- Modify: `src/schema_registry_tests.zig:5-65`
- Modify: `schemas/README.md:1-45`
- Modify: `tests/schemas-json-test.sh:1-45`
- Test: `src/main_tests.zig:378-387`

- [ ] **Step 1: Write failing registry and schema-index tests**

Add `saw_run_summary` and `saw_bootstrap_event` checks to
`src/schema_registry_tests.zig`, and change the shell expectation to 26 schemas:

```bash
grep -q '"count":26' <<< "$OUTPUT"
grep -q '"name":"run-summary"' <<< "$OUTPUT"
grep -q '"path":"schemas/run-summary.schema.json"' <<< "$OUTPUT"
grep -q '"name":"bootstrap-event"' <<< "$OUTPUT"
grep -q '"path":"schemas/bootstrap-event.schema.json"' <<< "$OUTPUT"
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
zig test src/test_harness.zig -target aarch64-macos.15.0
bash tests/schemas-json-test.sh
```

Expected: registry/schema-count failures because the files and entries do not
exist.

- [ ] **Step 3: Add the complete bootstrap-event schema**

The schema is draft 2020-12, rejects unknown fields, and requires:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://zmr.dev/schemas/bootstrap-event.schema.json",
  "title": "ZMR Bootstrap Event",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "seq", "timestamp", "phase", "status"],
  "properties": {
    "schemaVersion": {"const": 1},
    "seq": {"type": "integer", "minimum": 1},
    "timestamp": {"type": "string", "format": "date-time"},
    "phase": {"enum": ["invocation", "evidence.init", "device.acquire", "device.preflight", "device.boot", "app.build", "app.install", "shim.build", "shim.start", "shim.prewarm", "scenario.validate", "scenario.execute", "trace.finalize", "report.generate", "evidence.finalize", "cleanup", "complete"]},
    "status": {"enum": ["started", "passed", "failed", "skipped", "cancelled"]},
    "errorCode": {"type": ["string", "null"]},
    "summary": {"type": ["string", "null"]},
    "command": {"type": ["string", "null"]},
    "commandStatus": {"type": ["integer", "null"]},
    "artifact": {"type": ["string", "null"]}
  }
}
```

- [ ] **Step 4: Add the complete run-summary schema**

Model the required common fields from the approved M0 spec. Important schema
rules:

```json
{
  "required": [
    "schemaVersion", "runId", "executionId", "fixtureId",
    "fixtureVersion", "candidateRevision", "scenarioDigest",
    "appBuildDigest", "comparabilityKey", "certificationEligible",
    "ineligibilityReasons", "status", "classification", "phase",
    "startedAt", "finishedAt", "durationMs", "attempt", "firstAttempt",
    "platform", "deviceClass", "runtimeVersion", "timingMode",
    "runnerVersion", "protocolVersion", "commandStatus", "host",
    "device", "toolchain", "artifacts"
  ]
}
```

Use `allOf` conditionals for the passed/failed/cancelled field rules. Permit
explicit `null` for values unavailable before device/app resolution. Require a
null `comparabilityKey`, `certificationEligible: false`, and at least one
`ineligibilityReasons` item when any tuple value is null. Require non-null key,
true eligibility, and an empty reasons array for complete rows.

- [ ] **Step 5: Register and document both schemas**

Insert both entries before `release-readiness-output` so
`schemas-output` remains the final registry item. Update `schemas/README.md`.

- [ ] **Step 6: Run focused tests**

Run:

```bash
zig test src/test_harness.zig -target aarch64-macos.15.0
mkdir -p zig-out/bin
zig build-exe src/main.zig -target aarch64-macos.15.0 -O Debug -femit-bin=zig-out/bin/zmr
bash tests/schemas-json-test.sh
```

Expected: all pass and `zmr schemas --json` reports 26.

- [ ] **Step 7: Commit**

```bash
git add schemas/run-summary.schema.json schemas/bootstrap-event.schema.json schemas/README.md src/schema_registry.zig src/schema_registry_tests.zig tests/schemas-json-test.sh
git commit -m "feat(evidence): publish run evidence schemas"
```

## Task 3: Implement the dependency-free evidence core

**Files:**

- Create: `scripts/run_evidence.py`
- Create: `tests/run_evidence_test.py`

- [ ] **Step 1: Write failing tests for canonical comparability**

Tests must import `scripts/run_evidence.py` and cover:

```python
def test_complete_comparability_tuple_is_eligible():
    result = run_evidence.comparability(complete_context())
    assert result["certificationEligible"] is True
    assert result["comparabilityKey"].startswith("sha256:")
    assert result["ineligibilityReasons"] == []


def test_missing_tuple_value_is_valid_but_ineligible():
    context = complete_context()
    context["appBuildDigest"] = None
    result = run_evidence.comparability(context)
    assert result == {
        "comparabilityKey": None,
        "certificationEligible": False,
        "ineligibilityReasons": ["$.appBuildDigest"],
    }
```

Also assert key stability across insertion order and key changes across any tuple
value, including host OS/architecture/class.

Add attempt-identity tests that create an index beside several attempt roots and
assert:

- `runId` is globally unique;
- a new `executionId` must begin at attempt 1;
- attempt numbers for an execution are unique, positive, and monotonically
  appended;
- retry roots cannot already exist and relative summary paths cannot escape the
  index directory;
- every retry preserves the same raw comparability tuple, including explicit
  nulls, until an atomic context update resolves those nulls consistently for
  the whole execution;
- changing an already-resolved candidate revision, fixture, digest, platform,
  device/host identity, runner/protocol version, timing mode, or toolchain value
  is rejected before registration.

- [ ] **Step 2: Write failing tests for conditional validation and precedence**

Cover passed, every failed classification, graceful cancellation, cancellation
with cleanup failure, unknown failure fallback, invalid phase, and mismatched
`firstAttempt`/`attempt`. The precedence expectation is:

```python
assert classify(["app.assertion_failed", "runner.cleanup_failed"]) == (
    "runner_failure",
    "runner.cleanup_failed",
)
assert classify(["unknown"]) == ("runner_failure", "runner.unclassified")
```

- [ ] **Step 3: Run the new test module and verify failure**

Run:

```bash
python3 -W error -m unittest tests/run_evidence_test.py
```

Expected: FAIL because `scripts/run_evidence.py` does not exist.

- [ ] **Step 4: Implement constants, canonicalization, and validation**

The module must expose focused functions:

```python
PHASES = (...)
COMPARABILITY_FIELDS = (...)
ERROR_CLASSIFICATION = {...}

def comparability(context: dict) -> dict: ...
def recompute_comparability(summary: dict) -> dict: ...
def classify(error_codes: list[str]) -> tuple[str, str]: ...
def validate_event(event: dict) -> list[str]: ...
def validate_summary(summary: dict) -> list[str]: ...
def sanitize_text(value: str, *, roots: dict[str, str], secrets: list[str]) -> str: ...
def register_attempt(index_path: Path, attempt_root: Path, context: dict) -> dict: ...
def update_context(root: Path, patch: dict) -> dict: ...
def validate_bundle(root: Path, *, secrets: list[str]) -> list[str]: ...
```

Canonical JSON uses:

```python
encoded = json.dumps(tuple_object, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
digest = "sha256:" + hashlib.sha256(encoded).hexdigest()
```

- [ ] **Step 5: Write failing lifecycle tests**

Cover atomic non-overwriting initialization, monotonically increasing events,
exactly-once finalization, atomic context mutation, invalid-candidate
preservation as `run-summary.invalid.json`, schema-valid
`runner.evidence_invalid` fallback, and command-log truncation.

The context tests must initialize with a null `appBuildDigest`, update it through
the public API, and prove finalization recomputes `comparabilityKey` from the
updated tuple. They must reject mutation of identity fields after an attempt has
finalized and reject any retry whose tuple differs from its execution's index
entry.

Add command-execution tests for success, nonzero exit, signal termination,
stdout-only output, stderr-only output, interleaved output, and output larger
than 10 MiB. Every case must create separate bounded stdout/stderr logs plus a
metadata record containing sanitized argv, exit status, original byte counts,
and truncation flags.

Add sanitization tests before implementation. Seed a fake workspace, home, run
root, URL credential, `API_TOKEN`, `PASSWORD`, `AUTHORIZATION`, and explicit
`ZMR_EVIDENCE_SECRET_NAMES` values through command arguments, environment,
stdout, stderr, event fields, summary fields, and deliberately invalid-summary
diagnostics. Assert only `${WORKSPACE}`, `${RUN_ROOT}`, `${HOME}`,
`<absolute-path>`, and `<redacted>` placeholders survive. A bundle containing a
known secret, an unsanitized absolute path, or a credential-bearing URL must
fail validation.

- [ ] **Step 6: Implement lifecycle and CLI subcommands**

Required public CLI:

```text
run_evidence.py init --root <dir> --context-json <json>
                     --index <attempt-index.json>
run_evidence.py context --root <dir> --set-json <json>
run_evidence.py event --root <dir> --phase <phase> --status <status> [fields]
run_evidence.py command --root <dir> --phase <phase> --name <slug>
                        --failure-code <code> [--capture-stdout]
                        -- <command> [args...]
run_evidence.py external --root <dir> --phase <phase> --name <slug>
                         --outcome <success|failure|cancelled>
                         --failure-code <code>
run_evidence.py finalize --root <dir> --status <status> [failure fields]
run_evidence.py validate --summary <run-summary.json>
run_evidence.py validate-bundle --root <dir>
run_evidence.py aggregate --summary <path> [--summary <more> ...] --json
```

Use temporary sibling files plus `os.replace()` for atomic JSON writes. Protect
event sequencing, context mutation, and index mutation with lock files created
by `os.open(..., O_CREAT | O_EXCL)`; retry each lock for a bounded five seconds
and remove it in `finally`. `init` creates the attempt directory itself and
fails on `FileExistsError`; it registers the relative attempt path in
`attempt-index.json` in the same operation or removes the new empty root if
registration fails. The index has this stable shape:

```json
{
  "schemaVersion": "1.0",
  "executions": [
    {
      "executionId": "device-a-logical-1",
      "comparabilityTuple": {},
      "attempts": [
        {
          "runId": "device-a-logical-1-attempt-1",
          "attempt": 1,
          "summary": "attempts/device-a-logical-1-attempt-1/run-summary.json"
        }
      ]
    }
  ]
}
```

`context` accepts only an allowlisted patch, writes it atomically, recomputes
comparability, and updates the index under the same lock ordering. It may
resolve previously null tuple values, but it may not change a resolved value or
make sibling attempts disagree. Finalize recomputes again and never trusts a
stored producer key.

`command` is the compatibility entry point for evidence-enabled subprocesses.
It records a started event, executes without `shell=True`, captures stdout and
stderr separately, records the true return code or signal, sanitizes before
either replaying or persisting output, writes logs and metadata atomically, then
records the terminal event. Task 4 replaces its synchronous internals with the
durable command supervisor while preserving this CLI. No lifecycle, event,
command-gate, or per-command state lock may remain held while a child is
spawned, running, drained, waited, replayed, joined, slept for, or signalled.
Sensitive environment-name segments match
`TOKEN|SECRET|PASSWORD|PASS|KEY|AUTH|AUTHORIZATION|CREDENTIAL|CREDENTIALS`
case-insensitively plus the comma-separated exact names in
`ZMR_EVIDENCE_SECRET_NAMES`; known secret values are replaced everywhere with
`<redacted>`. Persisted argv redacts the value after credential flags and
credentials embedded in URLs. Path sanitization replaces
the repository workspace, run root, and home with their named placeholders and
any remaining absolute path with `<absolute-path>`.

With `--capture-stdout`, the compatibility command maps to Task 4's
`capture-stdout` supervisor mode. It suppresses normal stdout replay and returns
at most 1 MiB of raw stdout on the CLI's stdout so the shell adapter can capture
it in a variable; stderr is still replayed sanitized. The adapter disables
xtrace around that command substitution and never echoes or persists the raw
captured value. Overflow, NUL bytes, or capture-channel failure becomes
`runner.capture_failed`; raw capture never enters command state or a file.

`external` is reserved for GitHub action boundaries whose internal subprocess
streams are unavailable. It writes a bounded synthetic stdout/stderr pair and
metadata with `source: "github-action"`, `exitStatus: null`, the stable action
step id, outcome, phase, and sanitized remediation text; it never pretends to
contain the inaccessible hosted log. Unit tests cover all three outcomes and
ensure a failed acquisition still has a complete command-shaped record.

Log truncation keeps first/final 5 MiB and writes adjacent metadata containing
the original byte count and `truncated` flag. `validate-bundle` validates the
summary and every JSONL event, requires at least one command metadata record and
its referenced stdout/stderr logs for a command-owning terminal result, rejects
path traversal, then scans all publishable text for known secrets, raw absolute
paths, credential-bearing URLs, and existing public-safety deny-list patterns.
Validator diagnostics are sanitized before being written to the invalid file or
fallback summary. Failure to prove sanitization makes the bundle invalid and
blocks publication.

- [ ] **Step 7: Run unit tests**

Run:

```bash
python3 -W error -m unittest tests/run_evidence_test.py
python3 -m py_compile scripts/run_evidence.py
```

Expected: all pass with no warnings.

- [ ] **Step 8: Commit**

```bash
git add scripts/run_evidence.py tests/run_evidence_test.py
git commit -m "feat(evidence): add classified run evidence core"
```

## Task 4: Add durable command supervision and the Bash 3.2 lifecycle adapter

Task 4 replaces the shell-only lifecycle design. Python is the durable authority
for command state, process ownership, recovery, and finalization. Shell traps
only persist terminal intent and invoke the owner dispatcher; they never decide
that a bundle is complete merely because a shell process is exiting.

**Files:**

- Create: `scripts/run_evidence_lib/command_state.py`
- Create: `scripts/run_evidence_lib/command_supervisor.py`
- Create: `scripts/run_evidence_lib/session.py`
- Create: `tests/run_evidence_cases/command_state.py`
- Create: `tests/run_evidence_cases/command_supervisor.py`
- Create: `tests/run_evidence_cases/session.py`
- Create: `scripts/run-evidence.sh`
- Create: `tests/run-evidence-script-test.sh`
- Create: `tests/run-evidence-acceptance-test.sh`
- Modify: `scripts/run_evidence_lib/commands.py`
- Modify: `scripts/run_evidence_lib/constants.py`
- Modify: `scripts/run_evidence_lib/cli.py`
- Modify: `scripts/run_evidence_lib/lifecycle.py`
- Modify: `scripts/run_evidence_lib/summaries.py`
- Modify: `scripts/run_evidence_lib/bundle.py`
- Modify: `schemas/run-summary.schema.json`
- Modify: `tests/schemas-contract.test.mjs`
- Modify: `tests/run_evidence_cases/commands.py`
- Modify: `tests/run_evidence_cases/cli.py`
- Modify: `tests/run_evidence_cases/lifecycle.py`
- Modify: `tests/run_evidence_cases/bundle.py`
- Modify: `tests/run_evidence_test.py`
- Modify: `scripts/ci-gate.sh`
- Modify: `scripts/release-gate.sh`
- Modify: `tests/ci-gate-script-test.sh`
- Modify: `tests/release-gate-script-test.sh`

The completed Python CLI must expose this contract while retaining the Task 3
`command` compatibility entry point:

```text
run_evidence.py command-id
run_evidence.py session-claim --root <dir> --owner-pid <pid>
run_evidence.py session-status --root <dir> --session-id <32hex>
                               --generation <positive-int>
run_evidence.py session-intent --root <dir> --session-id <32hex>
                               --generation <positive-int>
                               --intent-json <json>
run_evidence.py session-close --root <dir> --session-id <32hex>
                              --generation <positive-int>
run_evidence.py session-finalize --root <dir> --session-id <32hex>
                                 --generation <positive-int>
run_evidence.py command-supervise --root <dir> --command-id <32hex>
                                  --session-id <32hex>
                                  --generation <positive-int>
                                  --phase <phase> --name <slug>
                                  --failure-code <code>
                                  --failure-policy <terminal|handled>
                                  --stop-policy <none|expected-term>
                                  --mode <foreground|background|capture-stdout|capture-both>
                                  --stdin-policy <devnull|inherit>
                                  -- <command> [args...]
run_evidence.py command-status --root <dir> --command-id <32hex>
                               --session-id <32hex>
                               --generation <positive-int> [--wait]
run_evidence.py command-stop --root <dir> --command-id <32hex>
                             --session-id <32hex>
                             --generation <positive-int>
                             --kind <expected|cancel>
run_evidence.py command-recover --root <dir> --session-id <32hex>
                                --generation <positive-int> [--cancel-live]
```

`--owner-pid` is an assertion, not authority. For a new claim or takeover it
must equal the CLI's immediate parent PID. Python reads that parent's stable
birth identity before and after acquiring the stable `.commands.lock`, which is
the session/command gate for claim, takeover, launch, recovery claim, close, and
finalization. It rejects any
PID, parent, or identity change. The adapter exports both
`ZMR_EVIDENCE_SESSION_ID` and `ZMR_EVIDENCE_SESSION_GENERATION`. Every adapter
mutation supplies the exact pair; stale-generation mutations fail before any
recovery, event allocation, or filesystem change. `session-close` and
`session-finalize` additionally require the CLI's immediate parent to be the
stored owner PID with the same birth identity. A borrower is accepted only
when an at-most-64-process, cycle-checked ancestry walk contains that stored owner
identity. Once `prepared` is durably authorized, the exact stored supervisor
identity may advance only that command despite later shell exit or reparenting;
it may not launch another command or mutate unrelated session state.

Takeover runs entirely under `.commands.lock`, after the old owner identity is
absent. For every bounded noncommitted command, its stable supervisor lease
must be immediately acquirable and its stored supervisor birth identity absent;
any disagreement blocks takeover. All supervisor/recovery lease claims briefly
take the same gate, so no claim can appear between this scan and the atomic
session-generation increment. The new owner authorizes recovery of any same-
session command whose immutable `creationGeneration` is less than or equal to
the new current generation; it never rewrites those command identities. Old
terminal diagnostics remain stamped with their original `recordedGeneration`,
and new diagnostics use the new one, so takeover needs no multi-file intent
rollover. A live group anchor is recovered after takeover under the normal
exclusive supervisor-lease claim.

Linux birth identity is `linux:<boot-id>:<proc-start-ticks>`, using the kernel
boot ID and field 22 of `/proc/<pid>/stat` with parentheses-safe parsing. macOS
uses `libproc` `PROC_PIDTBSDINFO` start seconds and microseconds. Sensitive
identity observations are read twice; provider absence or disagreement fails
closed. The implementation must work on Python 3.10+ on Linux and macOS and
must not rely on `pidfd`, `preexec_fn`, Linux `/proc` on macOS, or
second-resolution `ps` output.

The Task 3 `context`, `event`, and `external` commands gain optional paired
`--session-id`/`--generation` arguments, and the compatibility `command` reads
the inherited pair. Both values are mandatory whenever an active or finalizing
control session exists and forbidden as a partial pair. The legacy `finalize`
entry point is refused while control state exists; only owner-authorized
`session-finalize` may commit that attempt. Outside an adapter, the Task 3
surfaces retain their one-shot compatibility behavior.

`stdin-policy=inherit` is valid only for foreground/capture/delegated commands;
background commands use `devnull`. A foreground supervisor returns the child's
shell-visible status, while metadata retains the exact exit code or signal.
`failure-policy=handled` records complete command evidence without committing a
terminal run intent, so platform retry logic can decide whether a later failure
is primary. The generic supervisor accepts the caller's phase and stable failure
code; it must not infer app, runner, configuration, or infrastructure ownership
from phase names, exit codes, or stderr text.

When the compatibility `command` is invoked outside an adapter session, it
creates a one-shot handled session for the invoking process, commits the command
record, and removes that session control record without finalizing the run. This
preserves the existing explicit `command`-then-`finalize` CLI workflow. Inside
an adapter it joins the inherited session. For background mode, the adapter
starts `command-supervise` as a shell background job, registers the command ID
before spawn, and polls `command-status` for verified `running`/
`stop_requested` or fully `committed` for at most five seconds. `prepared`,
`anchored`, `anchor_stop_requested`, `exited`, and `materialized` are
transitional and are not ready.
`command-status --wait` may block for child completion but never holds an
evidence lock while waiting. Its strict JSON query succeeds with exit zero and
contains the stored `shellStatus`; the adapter returns that status. A readiness
timeout records supervisor-control failure, requests stop/recovery, and returns
reserved adapter status 125 rather than abandoning a possibly starting
supervisor. Committed command state remains queryable throughout an active
adapter session and is removed only during owner finalization; one-shot
compatibility sessions may remove it after delivering the result. A session is
capped at 1,024 total command directories in addition to the eight-active
command limit.

- [ ] **Step 1: Write failing private-state contract tests**

Assert that all durable supervisor recovery state is confined to this non-publishable
tree and is opened with rooted, no-symlink safety:

```text
<attempt>/.evidence-control/
  .commands.lock
  session.json
  terminal-intent.json
  commands/<32hex-command-id>/
    state.lock
    state.json
    supervisor.lease
    group.lease
    stdout.recovery
    stderr.recovery
```

Every private directory has exact mode `0700` and every private file exact mode
`0600`; wrong or special bits are corruption and are never silently repaired.
Lease identities use canonical `<device>:<inode>` syntax whose two components
are unsigned decimal 64-bit integers without signs, whitespace, or leading zero
except the value `0` itself.

`session.json` has exactly these fields:

```json
{
  "schemaVersion": 1,
  "sessionId": "0123456789abcdef0123456789abcdef",
  "runId": "logical-1-attempt-1",
  "ownerPid": 1234,
  "ownerBirthIdentity": "platform-stable-process-start-token",
  "state": "active",
  "generation": 1,
  "startedAt": "2026-07-11T00:00:00Z"
}
```

`state` is `active`, `finalizing`, or `committed`. A session ID is 32 lowercase
hexadecimal characters. `terminal-intent.json` binds the session, but not one
mutable current generation: it contains `schemaVersion`, `sessionId`,
`nextOrdinal`, one nullable `primary`, a `secondary` array, and `droppedCount`.
Each persisted diagnostic contains only `status`, `classification`, `phase`,
`errorCode`, `summary`, `hint`, `commandStatus`, `source`, `recordedAt`, and a
server-assigned `ordinal` and `recordedGeneration`; callers cannot supply the
last three fields. Summary and hint are each capped at 512 UTF-8 bytes and
unsafe control characters are rejected, ensuring nine worst-case escaped
diagnostics fit the fixed 32 KiB document bound. Passed
intent omits failure fields. Updates atomically deduplicate identical
diagnostics over the normalized caller fields (everything except the three
server fields), but only against the currently retained primary-plus-secondary
set, and recompute primary under the fixed public precedence. The strongest
diagnostic is primary; the next eight unique diagnostics are secondary,
ordered strongest-precedence first and ordinal ascending for ties. A retained-
key duplicate allocates no ordinal and increments neither counter. Every
delivery whose key is absent from the retained set allocates/increments
`nextOrdinal`; every such delivery that is not retained increments
`droppedCount`. Dropped keys are not remembered. A stronger insertion evicts
the weakest and atomically removes its semantic key; redelivery after eviction
or dropping is therefore a new insertion, allocates another ordinal, and is
counted again if it remains unretained.
Thus a late evidence or cleanup fault cannot be rejected because the array is
full.

Each command `state.json` has exactly these top-level fields:

```json
{
  "schemaVersion": 1,
  "commandId": "0123456789abcdef0123456789abcdef",
  "sessionId": "fedcba9876543210fedcba9876543210",
  "creationGeneration": 1,
  "stage": "prepared",
  "requestFingerprint": "sha256:<canonical-persisted-request>",
  "request": {
    "phase": "scenario.execute",
    "name": "zmr-run",
    "failureCode": "runner.unclassified",
    "failurePolicy": "terminal",
    "stopPolicy": "none",
    "mode": "foreground",
    "stdinPolicy": "devnull",
    "sanitizedArgv": ["zmr", "run", "<absolute-path>"]
  },
  "paths": {
    "metadata": "commands/zmr-run.json",
    "stdout": "commands/zmr-run.stdout.log",
    "stderr": "commands/zmr-run.stderr.log"
  },
  "startedEvent": {
    "schemaVersion": 1,
    "seq": 3,
    "timestamp": "2026-07-11T00:00:01Z",
    "phase": "scenario.execute",
    "status": "started",
    "command": "commands/zmr-run.json"
  },
  "supervisor": {
    "pid": 1234,
    "birthIdentity": "linux:boot-id:start-ticks",
    "leaseIdentity": "123:456",
    "role": "launch",
    "predecessor": null
  },
  "anchorReservation": {
    "groupLeaseIdentity": "123:457",
    "controlProtocolVersion": 1
  },
  "anchor": null,
  "child": null,
  "stopIntent": null,
  "outcome": null,
  "capture": null,
  "materialized": null
}
```

Only legal stage-specific null/object combinations are accepted. State advances
monotonically through `prepared -> anchored -> running -> stop_requested? ->
exited -> materialized -> committed`. `anchored -> anchor_stop_requested ->
exited(stopped_before_ack)` handles a stop before positive exec acknowledgement.
The exact negative exec handshake is `anchored -> exited(exec_failure:127)`.
`prepared`, `anchored`, `anchor_stop_requested`, `running`, and
`stop_requested` may terminate as `exited(supervisor_failure:125)` under the
strict role and identity rules below.
`creationGeneration` never changes and may be less than the authoritative
current `session.json.generation` after takeover. Mutation authorization always
checks the caller's current session generation separately. The immutable
`requestFingerprint` is SHA-256 over canonical native JSON containing exactly
`sessionId`, `creationGeneration`, `request`, and `paths`; it is recomputed on
every read and is not rewritten by recovery.

The strict non-null running-stage identities are:

```json
{
  "supervisor": {
    "pid": 1234,
    "birthIdentity": "platform-stable-token",
    "leaseIdentity": "123:456",
    "role": "launch",
    "predecessor": null
  },
  "anchorReservation": {
    "groupLeaseIdentity": "123:457",
    "controlProtocolVersion": 1
  },
  "anchor": {
    "pid": 1235,
    "birthIdentity": "platform-stable-token",
    "sid": 1235,
    "pgid": 1235,
    "groupLeaseIdentity": "123:457",
    "controlProtocolVersion": 1
  },
  "child": {
    "pid": 1236,
    "birthIdentity": "platform-stable-token",
    "execAcknowledgedAt": "2026-07-11T00:00:02Z"
  }
}
```

`role` is `launch` or `recovery`; `predecessor` is null or the SHA-256 digest of
the canonical prior supervisor object. A recovery claim replaces `supervisor`
with the exact claimant and stores that bounded digest, never a recursive chain.
`leaseIdentity` remains the same stable `supervisor.lease` device/inode across
launch and every recovery claim; only PID, birth identity, role, and predecessor
identify the new claimant.
`anchorReservation` has exactly the future anchor's `groupLeaseIdentity` and
`controlProtocolVersion`; both are immutable and cross-bound to the actual
stable group-lease inode. Prepared requires only non-null supervisor and
reservation. Entry into anchored requires the verified launch supervisor; a
later same-stage recovery claim may replace it. Anchored requires an anchor
with null child/stop/outcome/capture/materialization. Anchor-stop-requested adds only
stop intent while child remains null. Running adds the acknowledged child;
stop-requested adds stop intent. Exited requires outcome and capture;
materialized adds hash bindings; committed retains all historical objects.
Once a pre-exit state has a recovery-role supervisor it may only retain its
stage, persist stop intent via anchored-to-anchor-stop-requested or
running-to-stop-requested, and then terminate as supervisor failure. Normal
exit/signal, exec-failure, and stopped-before-ack results are forbidden. Anchor
PID, SID, and PGID must be equal and all PIDs
are positive and distinct where the OS reports distinct processes. Unknown
fields, illegal null combinations, identity mutation outside the recovery
claim rule, or a fingerprint mismatch are corruption.

Stop intent has exactly `{kind, requestedAt, killAuthorizedAt}`. Expected stop
is legal only when request `stopPolicy` is `expected-term`; cancellation is
always legal. The initial anchored/running stop transition requires
`killAuthorizedAt: null`. After the grace deadline, the current lease holder
must atomically persist and fsync the sole legal same-stage stop-intent mutation
from null to a UTC timestamp no earlier than `requestedAt` before sending KILL.
The timestamp is immutable write-ahead proof of `runner.cleanup_failed` across
crash recovery. Recovery claim and kill authorization are separate transitions
and may not alter any other fields.

The direct negative exec-handshake branch has exactly this exited-stage shape;
no other `anchored -> exited` exec-failure shape is legal:

```text
supervisor = <the verified launch supervisor object>
anchor = {pid, birthIdentity, sid, pgid, groupLeaseIdentity,
          controlProtocolVersion}
child = null
stopIntent = null
outcome = {kind: "exec_failure", exitStatus: 127, signal: null,
           shellVisibleStatus: 127, execFailedAt: <RFC3339 UTC timestamp>}
capture = {
  captureComplete: true,
  stdout: {originalBytes: 0, sanitizedBytes: 0, storedBytes: 0,
           truncated: false},
  stderr: {originalBytes: N, sanitizedBytes: M, storedBytes: M,
           truncated: false}
}
materialized = null
```

`N` and `M` are bounded non-negative integers, `M` is at most 10 MiB, and the
bounded negative-handshake diagnostic is complete so `truncated` is false.
The anchor is verified and retained because it completed the negative
handshake; `child` is null because no executable image was acknowledged.
Consequently `child.execAcknowledgedAt` is mandatory only for the positive
handshake that enters `running`. A missing, malformed, timed-out, or transport-
failed handshake is a supervisor/capture failure, not status-127 exec failure.

The exact supervisor-control failure outcome is:

```text
outcome = {kind: "supervisor_failure",
           errorCode: "runner.command_supervisor_lost" | "runner.capture_failed",
           exitStatus: null, signal: null, shellVisibleStatus: 125,
           failedAt: <RFC3339 UTC timestamp>}
capture = {captureComplete: false,
           stdout: {originalBytes: N, sanitizedBytes: M, storedBytes: M,
                    truncated: true},
           stderr: {originalBytes: N, sanitizedBytes: M, storedBytes: M,
                    truncated: true}}
```

Counts are lower bounds. Supervisor loss requires a recovery-role claimant with
the exact predecessor digest. Capture failure may be recorded by a verified
launch or recovery supervisor. Reservation and identities known at the source
stage are retained. If stop arrives while anchored but before exec
acknowledgement, the only normal terminal branch is `stopped_before_ack` with
exact fields `kind`, `requestKind`, `graceExpired`, `escalated`,
`shellVisibleStatus`, and `stoppedAt`. Healthy expected stop is
`false,false,0`; healthy cancellation is `false,false,130`; escalation is
`true,true,125` and records `runner.cleanup_failed`. Mixed booleans or any other
status are corrupt. Those flags cross-bind exactly to
`stopIntent.killAuthorizedAt`; they are not the escalation authority. Every
non-supervisor-failure outcome has `captureComplete: true`. A normal
exit/signal's shell-visible status is its natural child status without a stop,
`0` for healthy expected stop, `130` for healthy cancellation, and `125` when
KILL was authorized.

The prepared record is the write-ahead copy of the exact started event and
always contains the verified launch identity of the process holding the stable
`supervisor.lease` descriptor and the actual reserved `group.lease` inode.
Reservation creates every stable command file before state exists. Creating
prepared verifies the still-live descriptor with `fstat`, its rooted path and
identity, exclusive ownership, and the current supervisor PID; an identity
string alone grants no authority. Under commands -> lifecycle -> events ->
state-lock, launch allocates the exact event and paths, fsyncs `prepared`, then
appends and fsyncs that exact event. No anchor or child is spawned before both
records verify. Every event allocation briefly takes `.commands.lock`; recovery
fills a missing stored sequence only when it is exactly next, accepts already
identical bytes, and treats an occupied different sequence as corruption.

The anchor acquires and verifies the exact reserved group lease, reports its
identity, and waits. The supervisor persists/fsyncs/re-reads `anchored` before
sending `GO`; the anchor never forks or execs before `GO` and exits on supervisor
EOF before `GO`. Stale prepared recovery holds the free supervisor lease,
acquires the exact group lease, and re-reads prepared before recording
supervisor loss; a held group lease means busy/wait with no mutation. Running is
persisted only after a positive child exec acknowledgement. A direct negative
handshake uses the strict `anchored -> exited(exec_failure:127)` shape above and
is never advertised as running. Authority-sensitive actions immediately
re-verify persisted lease identities against the still-held descriptors. Every
rooted read cross-binds the supervisor, reservation, and non-null anchor lease
identities to the visible stable files; every rooted command-state mutation
also verifies the candidate supervisor's current PID and identity against the
live held supervisor descriptor immediately before writing.
materialized state binds hashes and sizes for both logs, metadata, and the exact
terminal event; each log binding size equals its capture `storedBytes`. Raw
argv, environment values, and raw output are never stored.
Command state is capped at 256 KiB so every admitted 64 KiB sanitized argv,
including worst-case JSON quotes/backslashes, remains encodable. Tests enforce
the constants in this plan, relative paths only, immutable request fields, and
rejection without mutation for corrupt, oversized, unknown-field, or
mismatched-session state.

- [ ] **Step 2: Run the state tests, implement the minimal state machine, and commit**

Run:

```bash
python3 -W error -m unittest tests.run_evidence_cases.command_state -v
```

Expected before implementation: FAIL because the modules and control-state
contracts do not exist. Implement bounded strict decoding, atomic sibling-file
replacement, canonical fingerprints, legal transitions, and rooted path
validation. Run the command again; expected: PASS.

```bash
git add scripts/run_evidence_lib/command_state.py scripts/run_evidence_lib/constants.py tests/run_evidence_cases/command_state.py
git commit -m "feat(evidence): add durable command state"
```

- [ ] **Step 3: Write failing command-recovery tests**

Inject process death after every durable transition and assert this recovery
table:

Include distinct launch faults before prepared, after prepared but before the
exact event append, after that append but before anchor spawn, after anchor
lease acquisition/report, after anchor report but before `anchored`, after
`anchored` but before `GO`, after `GO` but before exec acknowledgement, and
immediately after acknowledgement.
Every case yields zero or exactly one byte-identical started event, never
allocates over a different occupied sequence, and proves no child was spawned
before durable started evidence.

| Durable state | Lease observation | Required recovery |
| --- | --- | --- |
| reserved directory without `state.json` | exact five-file empty layout is byte-stable after acquiring the free state lock plus supervisor/group leases and re-reading under `.commands.lock` | remove it as never prepared and emit no command event |
| reserved directory without `state.json` | any file content, mode, identity, unknown entry, or lock/lease observation disagrees | retain it as unsafe; block mutation and finalization |
| `prepared` | supervisor live | report busy; do not alter state |
| stale `prepared` | supervisor lease free; exact reserved group lease held | report busy or wait for the pre-`anchored` anchor to exit; do not mutate state |
| stale `prepared` | supervisor lease and exact reserved group lease free; state still byte-identical after both claims | claim recovery, append or verify the exact stored started event, persist the recovery supervisor, publish bounded incomplete logs/metadata, and append exactly one `runner.command_supervisor_lost` terminal event |
| `anchored`, `anchor_stop_requested`, `running`, or `stop_requested` | supervisor live | report busy; finalization refuses |
| `anchored`, `anchor_stop_requested`, `running`, or `stop_requested` | supervisor free; anchor lease, PID/birth/SID/PGID agree | claim recovery, TERM the anchored process group, wait two seconds, KILL if needed, and materialize incomplete recovered evidence |
| `anchored`, `anchor_stop_requested`, `running`, or `stop_requested` | group lease free; anchor identity absent; two settlement-separated `killpg(pgid, 0)` probes return `ESRCH` | treat the group as gone and materialize incomplete recovered evidence |
| `anchored`, `anchor_stop_requested`, `running`, or `stop_requested` | lease, anchor identity, membership, or signal probe disagree | treat as corruption; do not signal or finalize |
| `exited` | supervisor lost before materialization | retain the observed child result as secondary; make command recovery/capture loss primary |
| `materialized` | outputs partially committed | verify matching hashes, complete only missing exact outputs/event, and never overwrite a mismatch |
| `committed` | all bound outputs match | verify and retain during an active adapter session; remove only on owner finalization or after a one-shot result is delivered |
| any stage | corrupt/unsafe state or unproven PID reuse | do not signal, delete, overwrite, or finalize; block mutation and publication |

Recovered streams set `captureComplete: false` and `truncated: true`; recorded
byte counts are lower bounds. Re-running recovery must be idempotent: the exact
stored started and terminal events appear once, and a recovered command cannot
produce a second terminal result.

- [ ] **Step 4: Implement recovery, verify it, and commit**

Implement recovery in `command_state.py`/`commands.py` and invoke it before every
mutating lifecycle, command, session, or finalization operation. Read-only
`validate-bundle` never recovers: it refuses any remaining
`.evidence-control` tree. Once a committed receipt and every bound output have
been verified, only owner finalization (or completed one-shot delivery) removes
committed state so validation can proceed. Recovery is two-phase: under short
locks a worker acquires the free `supervisor.lease` as its exclusive recovery
claim and persists its identity; it then releases every mutation lock before
signal, wait, drain, sleep, or join, and reacquires locks only to persist the
next transition. Two recoverers can therefore never both signal or materialize
one command.

Run:

```bash
python3 -W error -m unittest tests.run_evidence_cases.command_state tests.run_evidence_cases.commands tests.run_evidence_cases.bundle -v
```

Expected: PASS.

```bash
git add scripts/run_evidence_lib/command_state.py scripts/run_evidence_lib/commands.py scripts/run_evidence_lib/bundle.py tests/run_evidence_cases/command_state.py tests/run_evidence_cases/commands.py tests/run_evidence_cases/bundle.py
git commit -m "feat(evidence): recover interrupted commands"
```

- [ ] **Step 5: Write failing short-lock and finalization-gate tests**

Start a command that runs for more than five seconds. While it is running,
append an ordinary event and start an independent command; both must complete
their short critical sections without timing out. Race command launch against
`session-close` and prove exactly one outcome: launch durably reaches `prepared`
before close inspects it and close proceeds with that command durably owned, or
close commits `finalizing` first and launch refuses. Also assert the
eight-active-command ceiling and that
a live or recoverable noncommitted command blocks terminal summary creation.

The only valid nested lock order is:

```text
.transactions.lock
  -> attempt-index lock (only when needed)
  -> .commands.lock
  -> .lifecycle.lock
  -> .events.lock
  -> per-command state lock
```

A caller may omit locks it does not need but may never acquire a listed lock
after one to its right. No lock is held across spawn, wait, stream drain,
sanitized replay, thread join, readiness/status polling, sleep, or signal
delivery. These are short mutation locks. `supervisor.lease` and `group.lease`
are long-lived ownership leases and are expressly exempt from that duration
rule. `.commands.lock`, `state.lock`, and both lease files have stable inodes:
they are never atomically replaced or unlinked while any possible holder may
exist; only JSON payload files are atomically replaced. `command-stop` records
intent under the state lock, releases every
lock, then signals. Command launch takes `.commands.lock`, rejects a terminal
summary, recovers stale state, persists `prepared`, and commits the exact started
event in short transactions. Owner EXIT calls `session-close` before shell
cleanup. That operation atomically changes `active -> finalizing` under the
same command gate. Once finalizing, new commands, ordinary events, context
changes, delegation, and pass intent are rejected; stop/recovery and
cleanup/evidence diagnostics remain permitted. Final summary commit locks in
transaction -> index -> commands -> lifecycle -> events order, rechecks the
generation/finalizing state and absence of live/noncommitted commands, and
changes the session to committed only after the durable finalize receipt
verifies. A launch/close race has exactly one serial winner.

- [ ] **Step 6: Refactor command execution to the short-lock protocol**

Route the compatibility `command` entry point and the new command CLI through
the state machine. Add `commandId`, `configuredFailureCode`, `captureComplete`,
the backward-compatible `supervisorFailure` boolean, and an exact `termination`
object to command metadata. `supervisorFailure` distinguishes runner-owned
control failure from independently truthful capture completeness and child
outcome. `termination` records
`kind` (`exit` or `signal`), numeric code/signal, whether stop was requested,
the request kind, grace/escalation state, and the shell-visible status. Keep
existing 10 MiB sanitized head/tail log semantics.

Run:

```bash
python3 -W error -m unittest tests.run_evidence_cases.commands tests.run_evidence_cases.lifecycle tests.run_evidence_cases.cli -v
```

Expected: PASS, including the command-over-five-seconds concurrency test.

```bash
git add scripts/run_evidence_lib/commands.py scripts/run_evidence_lib/cli.py scripts/run_evidence_lib/lifecycle.py scripts/run_evidence_lib/summaries.py tests/run_evidence_cases/commands.py tests/run_evidence_cases/cli.py tests/run_evidence_cases/lifecycle.py
git commit -m "refactor(evidence): keep command locks short"
```

- [ ] **Step 7: Write failing process-group, lease, and signal tests**

Use real child/grandchild processes plus injected PID/birth-identity providers
to prove:

- every command uses a trusted Python anchor started with
  `start_new_session=True`; the anchor is SID/PGID leader and the actual command
  joins that group;
- only the supervisor holds `supervisor.lease`; only the trusted anchor holds
  the long-lived `group.lease`, so arbitrary executables closing descriptors
  cannot invalidate ownership;
- the anchor reports a bounded exec handshake, child PID/birth identity, and
  wait outcome over anonymous control pipes and stays alive until the
  supervisor has persisted the result, drained both streams, and proved no
  non-anchor member remains;
- SIGINT/SIGTERM received by the session owner persists cancellation intent
  before forwarding TERM to active command groups;
- an unexpected child signal is the caller's configured failure, not
  cancellation;
- an `expected-term` stop passes only when the requested signal ends the group
  inside the two-second grace period;
- KILL escalation is `runner.cleanup_failed`, even after requested cancellation;
- a lost supervisor is `runner.command_supervisor_lost`;
- a free group lease alone never proves group death: anchor identity must be
  absent and `killpg(pgid, 0)` must return `ESRCH` twice across settlement;
  any lease/identity/SID/PGID/membership disagreement blocks signalling and
  finalization.

Kill the supervisor after `prepared`, after child spawn, after child exit, and
during materialization. Recovery must follow the table in Step 3 without
leaking a descendant or misclassifying a signal. Also prove a child that closes
every descriptor >=3 cannot release the anchor lease, and a direct child that
exits before a grandchild is still recovered. The anchor handles group TERM
without exiting; KILL escalation intentionally ends it and releases the lease.
If its supervisor control pipe closes, it remains as the stable group identity
and does not mutate evidence.

- [ ] **Step 8: Implement process supervision and verify crash recovery**

Implement concurrent stdout/stderr draining, supervisor/group leases, stable
PID birth identity, process-group signalling, TERM/KILL timing, and exact
termination metadata in `command_supervisor.py`. Linux group membership uses
`/proc`; macOS uses `libproc` plus `getsid`. If the platform cannot prove a
stored process identity or membership, fail closed: retain the control state
and block finalization instead of signalling.

Run:

```bash
python3 -W error -m unittest tests.run_evidence_cases.command_supervisor tests.run_evidence_cases.command_state tests.run_evidence_cases.commands -v
```

Expected: PASS with no surviving test descendants.

```bash
git add scripts/run_evidence_lib/command_supervisor.py scripts/run_evidence_lib/command_state.py scripts/run_evidence_lib/commands.py tests/run_evidence_cases/command_supervisor.py tests/run_evidence_cases/command_state.py tests/run_evidence_cases/commands.py
git commit -m "feat(evidence): supervise command process groups"
```

- [ ] **Step 9: Write failing bounded-capture tests**

Cover `foreground`, `background`, `capture-stdout`, and `capture-both` with
stdout-only, stderr-only, interleaved, non-UTF-8, NUL, trailing-newline, nonzero,
and signalled commands. A stress child writes 256 MiB to each stream
concurrently; the supervisor must not deadlock or retain unbounded memory.

Requested raw streams are capped independently at 1 MiB and exist only in
memory/pipes. Capture emits exactly one strict ASCII JSON/base64 envelope over
a dedicated anonymous result pipe which Python verifies by `fstat` is a FIFO or
socket, never a regular file or terminal. The envelope is capped at 3 MiB and
contains only `schemaVersion`, `commandId`, `shellStatus`, nullable payloads,
exact decoded lengths, SHA-256 digests, and `captureComplete`. Raw capture
overflow, a NUL byte, malformed/truncated/digest-mismatched envelope, or a
broken capture channel records `runner.capture_failed`; no partial raw payload
is returned and the observed child outcome remains secondary. Sanitized recovery
spools/logs remain independently capped at 10 MiB per stream with first/final
5 MiB retention. Secrets, credentials, and raw absolute paths may appear in the
in-memory test value but never in state, logs, metadata, events, or diagnostics.
Exact 1 MiB succeeds and 1 MiB+1 fails. Embedded newlines and invalid UTF-8
survive base64 transport; assignment intentionally follows Bash command-
substitution trailing-newline removal. Complete capture returns the child's
shell-visible status. Supervisor or capture-control failure returns reserved
adapter status 125 and leaves every destination unchanged; child nonzero with a
complete capture still assigns output and returns that child status.

- [ ] **Step 10: Implement capture modes, verify bounds, and commit**

Implement bounded raw channels without temporary regular files. The Bash
adapter disables xtrace before capture, holds the ASCII envelope in memory, and
feeds it with builtin `printf` into a Python decoder that reads only stdin and
writes exactly one selected decoded stream to stdout. `capture-both` decodes
each stream independently and assigns only after the envelope and both streams
validate; identical destinations are rejected. Raw-derived data never enters
argv, environment variables, here-documents, here-strings, or regular files.
Restore the caller's prior xtrace/errexit state only after intermediates are
unset. Tests monitor attempt files, `TMPDIR`, xtrace, and every non-child
process argv/environment for raw markers.

Run:

```bash
python3 -W error -m unittest tests.run_evidence_cases.command_supervisor tests.run_evidence_cases.commands tests.run_evidence_cases.sanitization -v
```

Expected: PASS, including the 256 MiB dual-stream stress case.

```bash
git add scripts/run_evidence_lib/command_supervisor.py scripts/run_evidence_lib/commands.py tests/run_evidence_cases/command_supervisor.py tests/run_evidence_cases/commands.py
git commit -m "feat(evidence): add bounded command capture"
```

- [ ] **Step 11: Write failing owner/borrower and terminal-intent tests**

The first adapter process for an attempt claims ownership and exports
`ZMR_EVIDENCE_SESSION_ID` and `ZMR_EVIDENCE_SESSION_GENERATION`; instrumented
descendants that inherit both values and whose bounded ancestry still proves
the stored owner identity are borrowers. Assert:

- an independent second owner is rejected while the stored owner PID and birth
  identity are live;
- borrowers may append events, run commands, register cleanup, and defer a
  failure, but cannot finalize pass or commit the run summary;
- a borrower exit never finalizes the owner's attempt;
- orphan takeover requires the exact stored owner process to be gone and no
  live supervisor lease; generation increments atomically and every old-
  generation borrower mutation is rejected without change;
- spoofed owner PID, unrelated same-user process, borrower finalization, and
  same-PID/different-birth injection fail before mutation;
- all permutations of ten mixed-precedence diagnostics choose the same primary
  class; a ninth evidence/cleanup fault displaces a weaker diagnostic, a
  retained-key duplicate is idempotent, and redelivery after eviction or drop
  allocates/counts again while remaining bounded;
- cleanup callbacks are shell-local and never serialized: each borrower runs
  its own LIFO callbacks before deferring failure, while the owner runs only
  owner-local callbacks and durably enumerates/stops every command regardless
  of inherited Bash arrays;
- owner EXIT first closes the session launch gate, then runs cleanup, requests
  stops for all durably active commands, recovers state, resolves intent,
  finalizes exactly once, removes verified control state, and validates.

Terminal resolution order is fixed:

1. evidence/control failure with server-owned code `runner.evidence_invalid`,
   `runner.command_supervisor_lost`, or `runner.capture_failed`;
2. cleanup failure or expected-stop escalation as `runner.cleanup_failed`;
3. an explicit/deferred concrete classified failure under the public precedence
   registry (excluding `runner.unclassified`);
4. requested cancellation as `run.cancelled` only when cleanup and evidence are
   healthy;
5. a nonzero unclassified shell exit as `runner.unclassified`;
6. pass.

Caller-controlled `source` never selects a tier, and all permutations of the
same retained diagnostic set resolve identically.

- [ ] **Step 12: Implement session ownership and owner-only finalization**

Implement `session-claim`, `session-status`, `session-intent`, `session-close`,
and `session-finalize`. Persist the owner PID's platform-stable birth identity,
not only its numeric PID, and bind every mutation to the session generation.
`session-close` performs owner-authorized `active -> finalizing` before shell
cleanup; `session-finalize` requires finalizing state and changes it to
committed only around the existing durable finalization receipt. The same call
verifies the committed summary/receipt and removes fully committed control
state before bundle validation; a retry completes that sequence after a crash
after close, cleanup, recovery, summary write, receipt write, committed state,
or control cleanup.

Run:

```bash
python3 -W error -m unittest tests.run_evidence_cases.session tests.run_evidence_cases.lifecycle tests.run_evidence_cases.command_state -v
```

Expected: PASS.

```bash
git add scripts/run_evidence_lib/session.py scripts/run_evidence_lib/cli.py scripts/run_evidence_lib/summaries.py scripts/run_evidence_lib/bundle.py tests/run_evidence_cases/session.py tests/run_evidence_cases/cli.py tests/run_evidence_cases/lifecycle.py tests/run_evidence_cases/bundle.py
git commit -m "feat(evidence): add owner-only finalization"
```

- [ ] **Step 13: Write failing GNU Bash 3.2 adapter tests**

Run every adapter test with `/bin/bash`, assert it is compatible with GNU Bash
3.2 syntax, and cover wrapper mode:

```text
scripts/run-evidence.sh \
  --root <dir> \
  --index <attempt-index.json> \
  --context-json <json> \
  --phase scenario.execute \
  --failure-classification runner_failure \
  --failure-code runner.unclassified \
  --failure-hint <text> \
  -- <command> [args...]
```

The sourced API is:

```bash
zmr_evidence_register_cleanup <function> [args...]
zmr_evidence_event <phase> <status> [error-code] [summary] [artifact]
zmr_evidence_run <phase> <name> <failure-code> -- <command> [args...]
zmr_evidence_try <phase> <name> <failure-code> -- <command> [args...]
zmr_evidence_capture <destination-variable> <phase> <name> <failure-code> -- <command> [args...]
zmr_evidence_capture_both <stdout-variable> <stderr-variable> <phase> <name> <failure-code> -- <command> [args...]
zmr_evidence_run_background <handle-variable> <phase> <name> <failure-code> [--expected-stop] -- <command> [args...]
zmr_evidence_wait <command-id>
zmr_evidence_stop <command-id> <expected|cancel>
zmr_evidence_delegate <phase> <name> <failure-code> -- <instrumented-script> [args...]
zmr_evidence_update_context <json-patch>
zmr_evidence_finalize_pass
zmr_evidence_finalize_failure <classification> <phase> <code> <summary> <hint> [status]
```

The two `zmr_evidence_finalize_*` names are compatibility APIs: they persist
pass/failure intent only. They never write a summary directly; only the owner
EXIT dispatcher calls `session-close` before cleanup and `session-finalize`
after cleanup and recovery.

`try` selects handled-failure policy for retries. `delegate` preserves the
session ID and generation so the nested script is a borrower. Background command IDs are
assigned to the caller's destination variable with `printf -v` and registered
in indexed arrays in the current shell; callers must not use command
substitution to obtain a background handle. Tests preserve caller errexit and
xtrace settings, spaces/newlines, status, nested borrowing, stdin inheritance,
expected stops, cancellation, and cleanup order. They also reject unsupported
destination names without evaluating them as shell code.

- [ ] **Step 14: Implement the thin adapter, verify it, and commit**

The adapter uses indexed arrays only and delegates every state mutation to the
Python CLI. Owner INT/TERM traps persist cancellation intent before requesting
command stops. The owner EXIT dispatcher first calls `session-close`, then is
the only path that may call `session-finalize`; borrower traps run only their
shell-local cleanup and persist a deferred failure. No trap silently converts
an unexpected signal into cancellation.

Run:

```bash
/bin/bash -n scripts/run-evidence.sh
/bin/bash tests/run-evidence-script-test.sh
python3 -W error -m unittest tests.run_evidence_cases.cli tests.run_evidence_cases.session -v
```

Expected: PASS under the system Bash 3.2 baseline.

```bash
git add scripts/run-evidence.sh tests/run-evidence-script-test.sh scripts/run_evidence_lib/cli.py scripts/run_evidence_lib/session.py tests/run_evidence_cases/cli.py tests/run_evidence_cases/session.py
git commit -m "feat(evidence): add Bash 3.2 lifecycle adapter"
```

- [ ] **Step 15: Build the table-driven failure and concurrency acceptance harness**

Inject failures at all seven approved boundaries:

| Boundary | Phase | Expected code/classification |
| --- | --- | --- |
| emulator/simulator acquisition | `device.acquire` | `infra.emulator_provision` or `infra.simulator_provision` / `infrastructure_failure` |
| app install (missing artifact) | `app.install` | `config.app_artifact_missing` / `configuration_failure` |
| shim build | `shim.build` | `runner.ios_shim.build_failed` / `runner_failure` |
| shim readiness | `shim.prewarm` | `runner.ios_shim.readiness_timeout` / `runner_failure` |
| scenario execution | `scenario.execute` | proven healthy-driver `app.assertion_failed` / `app_failure` |
| report generation | `report.generate` | `runner.report_failed` / `runner_failure` |
| summary validation | `evidence.finalize` | `runner.evidence_invalid` / `runner_failure` |

Task 4's fake driver supplies those ownership decisions explicitly. Task 5 is
responsible for deriving real iOS ownership from the stable run-outcome sidecar;
neither the supervisor nor this harness may classify a real command by matching
stderr.

For every row, assert the original shell-visible command status, exactly one
terminal schema-valid summary, ordered individually valid JSONL events, one
metadata record with bounded stdout/stderr logs for every executed command,
sanitized paths/secrets, and the exact precedence-derived
phase/code/classification. Add rows for unknown failure, missing app,
unsupported device, cancellation, cancellation plus cleanup failure, unexpected
signal, expected TERM, TERM-to-KILL escalation, supervisor loss, raw-capture
overflow, corrupt private state, and evidence invalidation.

Add race/crash cases for a command running longer than five seconds while an
event is appended, concurrent command launch versus `session-close`, all durable
state transitions, nested owner/borrower delegation, rejected independent
ownership, orphan takeover, PID reuse, and 256 MiB concurrent stdout/stderr.
`validate-bundle` must refuse live/private state and succeed only after verified
recovery removes committed control data.

- [ ] **Step 16: Add the tests to gates, run the complete Task 4 suite, and commit**

Insert:

```bash
run "python3 -W error -m unittest tests/run_evidence_test.py"
run "/bin/bash tests/run-evidence-script-test.sh"
run "/bin/bash tests/run-evidence-acceptance-test.sh"
```

Update dry-run assertions, then run:

```bash
python3 -W error -m unittest tests/run_evidence_test.py
/bin/bash tests/run-evidence-script-test.sh
/bin/bash tests/run-evidence-acceptance-test.sh
bash tests/ci-gate-script-test.sh
bash tests/release-gate-script-test.sh
/bin/bash -n scripts/run-evidence.sh
```

Expected: all pass; no descendant process or `.evidence-control` tree remains
after a successfully finalized test attempt.

The gate matrix includes native macOS with Python 3.10 and system Bash 3.2 plus
Linux with Python 3.10. Both run birth-identity/PID-reuse, stable lock/lease
inode, group-anchor recovery, and invalid-byte capture smoke tests; macOS also
runs `/bin/bash -n` and the full adapter suite. Fixture tests cover Linux
`/proc/<pid>/stat` names containing spaces and parentheses, native provider
failure, child FD closure, leader-before-grandchild exit, and all close/
recovery/finalization crash boundaries.

```bash
git add tests/run_evidence_test.py tests/run-evidence-acceptance-test.sh scripts/ci-gate.sh scripts/release-gate.sh tests/ci-gate-script-test.sh tests/release-gate-script-test.sh
git commit -m "test(evidence): gate durable command supervision"
```

## Task 5: Instrument demos, pilots, and device-matrix attempts

**Files:**

- Create: `src/run_outcome.zig`
- Create: `src/run_outcome_tests.zig`
- Create: `scripts/run_evidence_lib/run_outcome.py`
- Create: `tests/run_evidence_cases/run_outcome.py`
- Modify: `src/cli_run.zig`
- Modify: `src/cli_output.zig`
- Modify: `src/cli_run_tests.zig`
- Modify: `src/cli_output_tests.zig`
- Modify: `src/main_tests.zig`
- Modify: `scripts/run_evidence_lib/cli.py`
- Modify: `tests/run_evidence_test.py`
- Modify: `scripts/demo-android-real.sh`
- Modify: `scripts/demo-ios-real.sh`
- Modify: `scripts/run-android-pilot.sh`
- Modify: `scripts/run-ios-pilot.sh`
- Modify: `scripts/device-matrix.sh`
- Modify: `tests/android-real-demo-script-test.sh`
- Modify: `tests/ios-real-demo-script-test.sh`
- Modify: `tests/android-pilot-script-test.sh`
- Modify: `tests/ios-pilot-script-test.sh`
- Modify: `tests/device-matrix-test.sh`

- [ ] **Step 1: Write failing iOS provenance and run-outcome contract tests**

Add `--outcome-file <attempt-relative-path>` and
`--ios-shim-mode <disabled|generated|provided>` parsing tests without changing
the existing `--json` stdout contract. Preserve compatibility by normalizing an
omitted mode to `disabled` when no shim path is present and `provided` when the
existing `--ios-shim` flag is present. An explicit `generated` or `provided`
mode requires a shim path; explicit `disabled` forbids one.

Simulator and physical invocations are independent provenance rows. The
selected target kind must be recorded and no simulator shim path/mode may be
silently reused for a physical run or vice versa. The generated demo explicitly
selects `generated`; an app-supplied path selects `provided`; a smoke path with
no selector shim selects `disabled`.

The producer-to-wrapper sidecar is an internal, versioned M0 contract with a
64 KiB maximum and no unknown fields:

```json
{
  "schemaVersion": 1,
  "status": "failed",
  "failureOwner": "app",
  "errorCode": "app.assertion_failed",
  "phase": "scenario.execute",
  "summary": "Scenario assertion failed while the driver remained healthy",
  "hint": "Inspect the trace failure and app state",
  "trace": "traces/ios-run-1",
  "report": null,
  "childStatus": 1,
  "iosShim": {
    "targetKind": "simulator",
    "mode": "generated",
    "digest": "sha256:<digest>"
  }
}
```

`status` is `passed`, `failed`, or `cancelled`. `failureOwner` is one of
`none`, `runner`, `app`, `configuration`, or `infrastructure`. Passed rows use
`phase: "complete"`, owner `none`, and null failure fields. Cancelled rows also
use owner `none` and the stable `run.cancelled` code. Failed/cancelled rows
require a stable code, phase, summary, and hint. Trace/report references are
null or normalized attempt-relative paths. `iosShim` is null for Android and a
target-specific object for iOS; its digest is null for `disabled` and a SHA-256
digest when available.

When `--outcome-file` is present, `ZMR_RUN_EVIDENCE_ROOT` is required and the
path must normalize beneath `run-outcomes/` in that attempt. The sidecar is
registered from a bootstrap event, scanned with the publishable bundle, and
must contain only sanitized data. It is durable diagnostic evidence but does
not add a public JSON Schema in M0.

The consumer binds the filename's command ID to committed command metadata and
requires any non-null `childStatus` to match that metadata's shell-visible
status. A path, command, session, status, or artifact mismatch is evidence
invalidation, not an opportunity to guess which source is correct.

Test atomic replacement and failure before replacement, no-symlink/path escape,
strict bounded decoding, handled `zmr run` failure, and a sidecar-write failure.
The sidecar must be durable before `zmr run` returns success or a handled run
error. `scripts/run_evidence_lib/run_outcome.py` validates it, registers
trace/report through the evidence context API, and translates ownership into a
session terminal intent. It does not parse stderr.

Task 5 adds this internal evidence CLI for the shell integration:

```text
run_evidence.py consume-outcome --root <dir> --session-id <32hex>
                                --path run-outcomes/<command-id>.json
```

It returns success when the sidecar was valid and consumed regardless of the
represented app/runner outcome; the adapter separately preserves the supervised
child's shell-visible status after recording the structured terminal intent.

Ownership tests are exact:

- missing/contradictory shim configuration is `configuration` with
  `config.invalid`; a disabled shim for a required selector capability is
  `config.unsupported_capability`;
- shim build/start/prewarm/protocol failures after valid configuration are
  `runner` with the existing `runner.ios_shim.*` or
  `runner.driver_protocol` code;
- an assertion/app crash is `app` only when the structured runner/trace outcome
  proves the driver and evidence path remained healthy;
- anything unproven is `runner`/`runner.unclassified`;
- a missing, malformed, oversized, or mismatched mandatory outcome sidecar is
  evidence failure, `runner.evidence_invalid`.

- [ ] **Step 2: Run outcome tests and verify failure**

Run:

```bash
zig build test --summary all
python3 -W error -m unittest tests.run_evidence_cases.run_outcome -v
```

Expected: FAIL because the sidecar module, flags, and consumer do not exist.

- [ ] **Step 3: Implement the atomic sidecar and consumer, then commit**

Build one structured in-memory result, preserve the existing `--json` stdout
fields and behavior, and serialize the additional ownership/provenance contract
only to an atomic sibling temporary file followed by rename when requested.
Keep raw local paths and stderr out of that contract. A runner error must be
captured into the sidecar before it is returned to the CLI dispatcher. The
Python consumer reads only a rooted regular file, validates the exact contract,
registers it in a bootstrap event, sanitizes diagnostics, updates trace/report
context, and persists terminal intent outside `command_supervisor.py`.

Run the commands from Step 2. Expected: PASS.

```bash
git add src/run_outcome.zig src/run_outcome_tests.zig src/cli_run.zig src/cli_output.zig src/cli_run_tests.zig src/cli_output_tests.zig src/main_tests.zig scripts/run_evidence_lib/run_outcome.py scripts/run_evidence_lib/cli.py tests/run_evidence_cases/run_outcome.py tests/run_evidence_test.py
git commit -m "feat(evidence): add atomic run outcome sidecar"
```

- [ ] **Step 4: Extend fake-script tests with an evidence context**

For each wrapper, set `ZMR_RUN_EVIDENCE_ROOT` to a temporary initialized run and
assert the expected phase sequence. Minimum phase coverage:

```text
Android demo: app.build -> device.preflight -> device.acquire -> device.boot -> app.install -> scenario.execute
iOS demo: app.build -> device.preflight -> device.acquire -> device.boot -> app.install -> shim.build -> shim.start -> shim.prewarm -> scenario.execute
Android pilot: scenario.validate -> app.install -> scenario.execute -> report.generate -> cleanup
iOS pilot: scenario.validate -> app.install -> shim.build -> shim.start -> shim.prewarm -> scenario.execute -> report.generate -> cleanup
Device matrix: one executionId with one unique runId per attempt
```

Reuse the Task 4 table for emulator and simulator acquisition, install, shim
build, shim readiness, scenario execution, report generation, and summary
validation. Each script-specific test asserts the complete artifact bundle—not
only the event sequence—including schema-valid summary, ordered valid events,
bounded stdout/stderr plus metadata for every executed command, sanitized
content, and exact phase/code/classification. The acceptance test is the common
exhaustive table; each demo/pilot test covers the rows its platform owns.

For iOS, run separate simulator/physical fixtures across `disabled`,
`generated`, and `provided` modes. Assert that scripts consume the atomic
sidecar for terminal ownership and trace/report registration. Stderr substring
matching may decide whether an existing `simctl` retry is transient, but it may
not determine the final failure owner, classification, or stable error code.

- [ ] **Step 5: Run focused tests and verify failure**

Run:

```bash
bash tests/android-real-demo-script-test.sh
bash tests/ios-real-demo-script-test.sh
bash tests/android-pilot-script-test.sh
bash tests/ios-pilot-script-test.sh
bash tests/device-matrix-test.sh
```

Expected: new evidence assertions fail.

- [ ] **Step 6: Source the adapter and instrument commands without changing disabled behavior**

At each script's initialization:

```bash
# shellcheck source=run-evidence.sh
source "$ROOT/scripts/run-evidence.sh"
```

Every evidence helper must be a no-op when `ZMR_RUN_EVIDENCE_ROOT` is unset, so
existing app-local scripts and output remain compatible.

Refactor each script's central run/capture/background helper to delegate every
build, device acquisition/preflight, install, shim build/start/readiness,
scenario, report, and cleanup subprocess to `zmr_evidence_run`,
`zmr_evidence_try`, `zmr_evidence_capture`, `zmr_evidence_capture_both`, or the
background/wait/stop API. Instrumented demo-to-pilot calls use
`zmr_evidence_delegate`, so the nested pilot borrows the existing session. The
adapter emits before/after events and command records; do not emit duplicate
boundaries. When evidence is disabled, each helper executes the same command
directly with unchanged stdout, stderr, status, stdin, and retry behavior.

Map platform mechanics onto Task 4 rather than changing the generic supervisor:

- the iOS shim prewarm pipeline uses foreground `stdin-policy=inherit` so its
  JSON request remains intact;
- each retryable simulator install attempt uses handled-failure policy and
  bounded dual capture; only the final exhausted attempt supplies terminal
  intent;
- long-lived emulator, Metro, recorder, and shim processes use background
  handles plus `expected-term` stop policy where termination is normal cleanup;
- cleanup registers before the command that creates the resource, runs LIFO,
  and turns escalation into `runner.cleanup_failed`;
- `zmr run` receives a unique attempt-relative `--outcome-file`; after wait,
  the Python outcome consumer—not stderr—registers trace/report paths and
  terminal ownership.

For a command failure, emit the primary error code before returning. Unknown
failures remain runner failures. A healthy-driver scenario assertion failure is
`app.assertion_failed`; an absent app path is
`config.app_artifact_missing`; known hosted provisioning failures use the
matching `infra.*` code.

- [ ] **Step 7: Give matrix rows stable logical/attempt identity**

Derive:

```text
executionId = <matrix-run-id>-<device-slug>-logical-<run-number>
runId       = <executionId>-attempt-<attempt-number>
attempt     = 1 for M0's existing no-retry matrix loop
```

Create a separate attempt evidence directory for every row through `init`; do
not pre-create it or overwrite failed rows. Maintain one matrix-level
`attempt-index.json` grouping relative summary paths by `executionId`. Populate
full candidate SHA and digests when available; otherwise write explicit nulls
and ineligibility reasons. Before finalization, use the atomic context API to
resolve app/scenario digests, and reject any retry that changes the execution's
raw comparability tuple. Tests create two retries and prove unique `runId`, one
attempt 1, monotonic attempt numbers, stable comparability identity, and retained
first-attempt failure evidence.

- [ ] **Step 8: Run the focused script suite**

Run the commands from Step 5 plus:

```bash
zig build test --summary all
python3 -W error -m unittest tests.run_evidence_cases.run_outcome -v
```

Expected: all pass and existing non-evidence assertions remain unchanged.

- [ ] **Step 9: Commit script instrumentation**

```bash
git add scripts/demo-android-real.sh scripts/demo-ios-real.sh scripts/run-android-pilot.sh scripts/run-ios-pilot.sh scripts/device-matrix.sh tests/android-real-demo-script-test.sh tests/ios-real-demo-script-test.sh tests/android-pilot-script-test.sh tests/ios-pilot-script-test.sh tests/device-matrix-test.sh
git commit -m "feat(evidence): instrument device run phases"
```

## Task 6: Add honest certification aggregation to release-readiness

**Files:**

- Modify: `scripts/release-readiness.sh`
- Modify: `scripts/release-readiness.py`
- Modify: `schemas/release-readiness-output.schema.json`
- Modify: `tests/release-readiness-script-test.sh`

- [ ] **Step 1: Write failing tests for run-summary input**

Add `--run-summary <file-or-directory>` and
`--attempt-index <file>` and `--certification-min-executions <n>` cases.
Preserve all existing evidence JSONL tests. New tests must prove:

- retries share an execution and do not increase sample size;
- first-attempt and eventual pass rates differ correctly;
- every attempt remains in classification counts;
- a producer-supplied mismatched comparability key blocks the row;
- null/incomplete keys remain diagnostic but certification-ineligible;
- 299 eligible logical executions fail a 300 gate;
- 300 eligible executions with no runner failure pass;
- any runner-failed attempt fails the entire cohort even if its retry passes;
- cohorts never mix candidate revisions or comparability keys;
- index paths are relative and resolve to every retained summary exactly once;
- duplicate `runId`, duplicate/missing attempt 1, non-monotonic attempt numbers,
  changed retry identity, path escape, or an indexed missing summary blocks
  certification with a diagnostic rather than being silently skipped.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
bash tests/release-readiness-script-test.sh
```

Expected: unknown new flags or missing `runEvidence` output.

- [ ] **Step 3: Parse run-summary inputs without breaking existing inputs**

Keep the existing targets and JSONL evidence behavior. The new flag is additive.
`--certification-min-executions` defaults to 300 when at least one run summary is
provided; smaller explicit values support local pilots.

Use `scripts/run_evidence.py` to validate summaries and recompute each key from
source fields. Never trust the supplied digest. When a directory or
`--attempt-index` is supplied, resolve only normalized relative paths under the
index root, cross-check all identity invariants, and require the indexed set and
discovered summary set to match exactly.

- [ ] **Step 4: Implement aggregation**

Group attempts by `executionId` after index/identity validation, then cohorts by
recomputed non-null `comparabilityKey`. Produce:

```json
{
  "runEvidence": {
    "attempts": 301,
    "logicalExecutions": 300,
    "eligibleLogicalExecutions": 300,
    "firstAttemptPassRate": 99.6666666667,
    "eventualPassRate": 100.0,
    "classificationCounts": {
      "passed": 300,
      "runner_failure": 1,
      "app_failure": 0,
      "infrastructure_failure": 0,
      "configuration_failure": 0,
      "cancelled": 0
    },
    "certificationMinimum": 300,
    "certificationReady": false,
    "blockingReasons": ["runner failure occurred in certification cohort"]
  }
}
```

An eventual pass never erases the runner-failure count. Invalid or mismatched
keys block certification and appear in output diagnostics.

- [ ] **Step 5: Extend the output schema and documentation strings**

Add an optional `runEvidence` object so invocations with legacy evidence only
remain schema-compatible. When `--run-summary` is present, require it in the
actual emitted output and include exact cohort revision/key details.

- [ ] **Step 6: Run focused tests**

Run:

```bash
python3 -W error -m unittest tests/run_evidence_test.py
bash tests/release-readiness-script-test.sh
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/release-readiness.sh scripts/release-readiness.py schemas/release-readiness-output.schema.json tests/release-readiness-script-test.sh
git commit -m "feat(readiness): aggregate classified run evidence"
```

## Task 7: Make CI checks stable and device evidence mandatory

**Files:**

- Create: `scripts/finalize-workflow-evidence.sh`
- Create: `tests/workflow-evidence-finalizer-test.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/device-smoke.yml`
- Modify: `tests/workflow-readiness-test.sh`
- Modify: `scripts/ci-gate.sh`
- Modify: `scripts/release-gate.sh`
- Modify: `tests/ci-gate-script-test.sh`
- Modify: `tests/release-gate-script-test.sh`

- [ ] **Step 1: Write failing static workflow assertions**

Assert:

```text
CI job key: quality-gate
displayed check: CI / quality-gate
permissions: contents: read
PR concurrency cancels superseded runs
scheduled/device work is not cancellation-prone
device jobs initialize run evidence before platform setup
every setup, acquisition, smoke, report, and finalizer step has a stable id
every post-init third-party action has start/always-close evidence steps
an if: always() finalizer maps step outcomes before artifact upload
the finalizer validates the exact required summary/event/command bundle
device uploads use if: always()
device uploads target the run root, not only traces/
if-no-files-found: error for mandatory run evidence
retention-days: 14
```

- [ ] **Step 2: Run the static test and verify failure**

Run:

```bash
bash tests/workflow-readiness-test.sh
```

Expected: FAIL on the current `test` job, missing pre-setup initializer/finalizer,
and trace-only device uploads.

- [ ] **Step 3: Rename and harden the CI job**

Use:

```yaml
permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  quality-gate:
    name: quality-gate
```

Keep `./scripts/ci-gate.sh` as the single local/hosted gate.

- [ ] **Step 4: Write a failing workflow-finalizer integration test**

Create `tests/workflow-evidence-finalizer-test.sh`. Drive the finalizer with fake
GitHub step outcomes and assert:

- a Java/Zig download failure before any smoke command produces
  `infra.network` / `infrastructure_failure`, while a deterministically missing
  required local tool produces `config.required_tool_missing` /
  `configuration_failure`; both include a synthetic bounded external-step log;
- Android emulator-action and iOS simulator-acquisition failures produce their
  exact `infra.emulator_provision`/`infra.simulator_provision` results;
- a failed smoke step with an existing valid terminal summary preserves that
  more-specific result;
- a failed smoke step with no summary is finalized as `runner.unclassified`;
- an invalid or missing terminal summary after an otherwise successful run is
  preserved diagnostically and replaced by `runner.evidence_invalid`, and the
  finalizer exits nonzero;
- cancelled setup is `cancelled` only if cleanup and bundle validation succeed;
- cleanup or bundle failure overrides cancellation as `runner_failure`;
- success requires exactly one valid summary, ordered valid events, and every
  referenced bounded command log; a merely nonempty run root fails.

Run:

```bash
bash tests/workflow-evidence-finalizer-test.sh
```

Expected: FAIL because `scripts/finalize-workflow-evidence.sh` is missing.

- [ ] **Step 5: Implement the outcome-driven workflow finalizer**

The script accepts the attempt root, sibling index, plus repeated mappings in the form
`step-id:outcome:phase:error-code`. It first validates an existing terminal
summary. If none exists, it records sanitized external-step metadata/logs for
failed or cancelled action steps that could not run through
`zmr_evidence_run`, applies the M0 precedence registry, and finalizes exactly
once. It then runs `validate-bundle`; invalid candidates are retained and become
`runner.evidence_invalid`. The script returns nonzero for any failed bundle or
terminal result, but always leaves the best valid publishable bundle possible.

- [ ] **Step 6: Initialize evidence before every platform setup step**

In each device job, checkout is followed immediately by an `evidence_init` shell
step that invokes `run_evidence.py init` with
`<publication-root>/attempts/<runId>` and
`<publication-root>/attempt-index.json`. It must run before Java, Zig, Android
SDK/emulator, Xcode/simulator, app, or shim setup. Pass a context with the exact
`${{ github.sha }}`, fixture, host, platform, runtime, runner, and toolchain
metadata. If app/scenario digests are unavailable, leave them null and use the
atomic `context` command as soon as each artifact exists. The update must
recompute and persist comparability before finalization.

Give every subsequent setup, app build, acquisition, smoke, report, cleanup,
finalizer, validator, and upload step a stable `id`. Route shell setup commands
through `zmr_evidence_run`. Bracket every post-init third-party setup/action step
with an evidence start step and an `if: always()` close step that calls
`run_evidence.py external` with the action's `${{ steps.<id>.outcome }}`. This is
required because action internals do not expose process streams as artifact
files; the synthetic record states that limitation rather than fabricating the
hosted log. In particular, the pinned Android emulator action is bracketed this
way, and its `script:` body invokes the evidence-enabled demo rather than an
unwrapped smoke command. The finalizer remains the safety net if a close step
itself does not run.

- [ ] **Step 7: Always finalize and validate before upload**

After all setup/smoke/report work, add an `if: always()` shell finalizer. Pass
`${{ steps.<stable-id>.outcome }}` for every mapped step to
`finalize-workflow-evidence.sh`; do not infer success from file existence. This
step runs before the upload and requires the attempt's `run-summary.json`, valid
ordered `bootstrap-events.jsonl`, the publication root's `attempt-index.json`,
and all command metadata/logs referenced by executed phases. A missing summary
is synthesized from step outcomes; an invalid summary becomes an evidence
failure.

Upload:

```yaml
- name: Upload iOS smoke evidence
  if: always()
  uses: actions/upload-artifact@<pinned-sha> # v7
  with:
    name: device-smoke-ios
    path: /tmp/zmr-ios-demo/run-evidence/
    if-no-files-found: error
    retention-days: 14
```

Traces and reports live beneath or are referenced from this run root.

- [ ] **Step 8: Run workflow tests**

Add `bash tests/workflow-evidence-finalizer-test.sh` to both gates and update
their dry-run assertions before running:

Run:

```bash
bash tests/workflow-evidence-finalizer-test.sh
bash tests/workflow-readiness-test.sh
bash tests/ci-gate-script-test.sh
bash tests/release-gate-script-test.sh
```

Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add scripts/finalize-workflow-evidence.sh tests/workflow-evidence-finalizer-test.sh .github/workflows/ci.yml .github/workflows/device-smoke.yml tests/workflow-readiness-test.sh scripts/ci-gate.sh scripts/release-gate.sh tests/ci-gate-script-test.sh tests/release-gate-script-test.sh
git commit -m "ci: require classified device smoke evidence"
```

## Task 8: Pin release-critical actions and toolchains

**Files:**

- Create: `tests/workflow-pinning-test.py`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/device-smoke.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `tests/workflow-readiness-test.sh`
- Modify: `scripts/ci-gate.sh`
- Modify: `scripts/release-gate.sh`

- [ ] **Step 1: Write the failing policy test**

Parse all workflow YAML as text without adding a YAML dependency. Fail when a
`uses:` value is local and not `./...`, or remote and not suffixed by a full
40-character lowercase SHA. Also assert no `rustup ... stable`, unversioned
`gem install xcodeproj`, or Zig extraction before checksum verification.

The test must allow readable comments such as `# v7` after the SHA.

- [ ] **Step 2: Run it and verify failure**

Run:

```bash
python3 -W error -m unittest tests/workflow-pinning-test.py
```

Expected: FAIL on current mutable action tags and toolchain commands.

- [ ] **Step 3: Pin every action to the map at the top of this plan**

Replace tags in all three workflows. Keep the semantic tag as an end-of-line
comment.

- [ ] **Step 4: Pin Rust and xcodeproj**

Use:

```bash
rustup toolchain install 1.92.0 --profile minimal
rustup default 1.92.0
gem install xcodeproj -v 1.28.1 --no-document
```

For `kcov`, install through Homebrew and immediately require major version 43;
record the Homebrew core revision `10337882d491f362de4651ce05ca4f28229b78c8`
in the workflow/policy test. A different installed version fails before release
tests rather than silently changing the toolchain.

- [ ] **Step 5: Verify Zig archives before extraction**

Select the expected checksum by host target:

```text
aarch64-macos: b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
x86_64-macos: 0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
aarch64-linux: ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
x86_64-linux: 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
```

On macOS use `shasum -a 256 -c`; on Linux use `sha256sum -c`. Extraction must
occur only after verification succeeds.

- [ ] **Step 6: Add policy tests to CI/release gates and update old assertions**

Replace tests that expect mutable tags/toolchains with exact SHA/version checks,
and add:

```bash
run "python3 -W error -m unittest tests/workflow-pinning-test.py"
```

- [ ] **Step 7: Run focused workflow tests**

Run:

```bash
python3 -W error -m unittest tests/workflow-pinning-test.py
bash tests/workflow-readiness-test.sh
bash tests/ci-gate-script-test.sh
bash tests/release-gate-script-test.sh
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/device-smoke.yml .github/workflows/release.yml tests/workflow-pinning-test.py tests/workflow-readiness-test.sh scripts/ci-gate.sh scripts/release-gate.sh tests/ci-gate-script-test.sh tests/release-gate-script-test.sh
git commit -m "build: pin release-critical workflow inputs"
```

## Task 9: Document and verify the complete M0 behavior

**Files:**

- Create: `docs/run-evidence.md`
- Modify: `docs/production-readiness.md`
- Modify: `docs/benchmarking.md`
- Modify: `FEATURES.md`
- Modify: `CHANGELOG.md`
- Modify: `tests/docs-readiness-test.sh`

- [ ] **Step 1: Write failing documentation assertions**

Require canonical documentation for:

- all classifications and phases;
- first-attempt versus eventual rate;
- retry non-erasure;
- 300-execution certification default;
- incomplete evidence eligibility;
- comparability-key recomputation;
- append-only attempt indexing and atomic context updates;
- command capture, path sanitization, secret redaction, and publication refusal;
- bootstrap artifacts when no trace exists;
- the claim that M0 improves evidence, not underlying device reliability.

- [ ] **Step 2: Run docs readiness and verify failure**

Run:

```bash
bash tests/docs-readiness-test.sh
```

Expected: FAIL because `docs/run-evidence.md` is missing.

- [ ] **Step 3: Write the operator guide**

Document:

```text
run root layout
attempt-index layout and retry identity invariants
run-summary field meanings
bootstrap event phases
command metadata/stdout/stderr capture and external-action limitations
classification precedence and code registry
how to reproduce each platform phase
how retries are grouped
how readiness forms a cohort
why any runner-failed attempt invalidates certification
artifact sensitivity/redaction rules
workflow always-finalizer behavior for pre-smoke setup failures
```

- [ ] **Step 4: Update production and benchmark claim boundaries**

State explicitly that legacy 20-run pilots remain useful local gates but do not
satisfy the default 1.0 certification sample. Describe total, first-attempt,
eventual, adjusted runner, and raw classification counts together.

- [ ] **Step 5: Run the full local M0 verification**

Run:

```bash
git diff --check
bash tests/docs-readiness-test.sh
bash tests/public-metadata-guard-test.sh
bash tests/public-safety-test.sh
python3 -W error -m unittest tests/run_evidence_test.py tests/workflow-pinning-test.py
bash tests/run-evidence-script-test.sh
bash tests/run-evidence-acceptance-test.sh
bash tests/release-readiness-script-test.sh
bash tests/workflow-evidence-finalizer-test.sh
bash tests/workflow-readiness-test.sh
bash tests/android-real-demo-script-test.sh
bash tests/ios-real-demo-script-test.sh
bash tests/android-pilot-script-test.sh
bash tests/ios-pilot-script-test.sh
bash tests/device-matrix-test.sh
npm test
./scripts/ci-gate.sh
```

Expected: every command passes. If `ci-gate.sh` is longer than the current
session checkpoint, run it in a yielded process and preserve its final exit code
and output.

- [ ] **Step 6: Commit documentation**

```bash
git add docs/run-evidence.md docs/production-readiness.md docs/benchmarking.md FEATURES.md CHANGELOG.md tests/docs-readiness-test.sh
git commit -m "docs: document classified reliability evidence"
```

## Task 10: Review, publish the branch, and deploy repository protection

**Files:**

- No new code files; this is the reviewed deployment step.

- [ ] **Step 1: Request code review**

Use @superpowers:requesting-code-review against the merge base with
`origin/main`. Resolve all correctness findings and rerun affected tests.

- [ ] **Step 2: Verify branch state**

Run:

```bash
git status --short
git log --oneline origin/main..HEAD
git diff --check origin/main...HEAD
```

Expected: clean worktree, intentional task commits, no whitespace errors.

- [ ] **Step 3: Use the branch-finishing workflow**

Invoke @superpowers:finishing-a-development-branch. The expected choice is push
the current production branch and open a draft PR, but do not infer merge
approval from this plan.

- [ ] **Step 4: Verify the hosted branch quality gate and evidence contract**

Required check name: `CI / quality-gate`. Trigger or observe a manual Device
Smoke branch run and verify both platform artifacts contain a valid
`run-summary.json`, including an intentionally injected pre-trace failure if
safe to run.

- [ ] **Step 5: Merge only after required hosted checks pass**

Use the repository's normal PR merge path. Do not bypass a failed check.

- [ ] **Step 6: Print and apply the intended default-branch protection**

After `CI / quality-gate` exists on `main`, show this policy before applying it:

```json
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["CI / quality-gate"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "required_approving_review_count": 0,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "required_conversation_resolution": true,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
```

Approval count remains zero while the repository has one maintainer, preventing
a self-review deadlock. Raise it to one when a second active maintainer exists.
`enforce_admins: false` is the documented emergency bypass; it must not be the
normal path.

Apply with `gh api --method PUT repos/johnmikel/zeno-mobile-runner/branches/main/protection --input -`, then immediately read the protection endpoint back.

- [ ] **Step 7: Verify protection invariants**

Confirm through the GitHub API:

```text
strict status checks enabled
CI / quality-gate required
pull request required
conversation resolution required
linear history required
force pushes disabled
branch deletion disabled
```

Record the API verification in the PR or release evidence. If the API rejects a
field because of repository-plan limitations, stop and report the exact gap; do
not silently omit protection.

## Final M0 completion criteria

M0 is complete only when:

1. the local full gate and hosted `CI / quality-gate` pass;
2. Android and iOS scheduled/manual jobs always upload valid run evidence;
3. injected pre-trace failures retain command logs and valid classifications;
4. readiness recomputes comparability keys and refuses incomplete/mixed cohorts;
5. 300 means 300 logical executions, not attempts;
6. any runner-failed attempt blocks certification despite later retry success;
7. workflows and toolchains satisfy immutable pin/checksum policy;
8. `main` protection is applied and read back after merge;
9. documentation does not claim the underlying device flakes are already fixed.
