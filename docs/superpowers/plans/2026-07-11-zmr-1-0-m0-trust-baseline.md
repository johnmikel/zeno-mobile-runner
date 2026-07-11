# ZMR 1.0 M0 Trust Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the exact ZMR revision under test produce green required CI and complete, classified, statistically honest device-run evidence even when failure occurs before a scenario trace starts.

**Architecture:** Add a dependency-free Python evidence core plus a small shell adapter. The evidence core owns canonical run-summary/bootstrap-event contracts, atomic finalization, classification, comparability hashes, and aggregation; existing demo/pilot/matrix scripts only emit phase transitions through the adapter. CI wraps each platform run in this evidence lifecycle, and release-readiness recomputes rather than trusts cohort keys.

**Tech Stack:** Zig 0.16 schema registry, Python 3 standard library, Bash, JSON Schema draft 2020-12, GitHub Actions, GitHub REST API.

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
- `scripts/run-evidence.sh` — shell adapter/wrapper and trap-safe finalization.
- `tests/run_evidence_test.py` — Python unit tests for contracts, hashing,
  finalization, classification, and statistics.
- `tests/run-evidence-script-test.sh` — shell integration and injected-failure
  tests.
- `tests/run-evidence-acceptance-test.sh` — table-driven fake-driver acceptance
  tests for every required failure-injection boundary and complete artifact
  bundle.
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
- `scripts/demo-android-real.sh`, `scripts/demo-ios-real.sh` — emit top-level
  build/device/pilot phases when an evidence context is present.
- `scripts/run-android-pilot.sh`, `scripts/run-ios-pilot.sh` — emit validation,
  install, shim, scenario, report, and cleanup phases.
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
- Attempt directories are append-only. `init` fails if its root already exists;
  a retry always receives a new root and never replaces an earlier summary.
- The publishable layout is
  `<publication-root>/attempt-index.json` plus
  `<publication-root>/attempts/<runId>/{run-summary.json,bootstrap-events.jsonl,commands/...}`.
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
require_not_grep 'Claude Code' README.md
```

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

`command` is the only evidence-enabled subprocess path. It records a started
event, executes without `shell=True`, captures stdout and stderr separately,
records the true return code or signal, sanitizes before either replaying or
persisting output, writes logs and metadata atomically, then records the
terminal event. Sensitive environment-name segments match
`TOKEN|SECRET|PASSWORD|PASS|KEY|AUTH|AUTHORIZATION|CREDENTIAL|CREDENTIALS`
case-insensitively plus the comma-separated exact names in
`ZMR_EVIDENCE_SECRET_NAMES`; known secret values are replaced everywhere with
`<redacted>`. Persisted argv redacts the value after credential flags and
credentials embedded in URLs. Path sanitization replaces
the repository workspace, run root, and home with their named placeholders and
any remaining absolute path with `<absolute-path>`.

With `--capture-stdout`, the command suppresses normal stdout replay and returns
raw stdout only on the CLI's stdout so the shell adapter can capture it in a
variable; stderr is still replayed sanitized. The adapter disables xtrace around
that command substitution and never echoes or persists the raw captured value.

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

## Task 4: Add the trap-safe shell adapter and injected-failure harness

**Files:**

- Create: `scripts/run-evidence.sh`
- Create: `tests/run-evidence-script-test.sh`
- Create: `tests/run-evidence-acceptance-test.sh`
- Modify: `scripts/ci-gate.sh`
- Modify: `scripts/release-gate.sh`
- Modify: `tests/ci-gate-script-test.sh`
- Modify: `tests/release-gate-script-test.sh`

- [ ] **Step 1: Write failing shell integration tests**

Use temporary directories and fake commands to assert:

- successful wrapped command creates `run-summary.json` and
  `bootstrap-events.jsonl`;
- exit 7 remains exit 7 and finalizes the requested classification/code;
- SIGTERM produces `cancelled` only after successful cleanup;
- no explicit finalization triggers `runner.unclassified` in the EXIT trap;
- a deliberately invalid context retains `run-summary.invalid.json` and emits a
  valid `runner.evidence_invalid` fallback;
- `zmr_evidence_run` preserves the command's status and creates sanitized,
  bounded stdout/stderr logs and metadata for success, failure, and signals;
- the adapter refuses to publish a bundle containing a seeded secret or raw
  absolute path;
- command logs are present for every command-owning terminal result.

Write `tests/run-evidence-acceptance-test.sh` as a table-driven fake-driver
harness. Inject failures at all seven approved boundaries:

| Boundary | Phase | Expected code/classification |
| --- | --- | --- |
| emulator/simulator acquisition | `device.acquire` | `infra.emulator_provision` or `infra.simulator_provision` / `infrastructure_failure` |
| app install (missing artifact) | `app.install` | `config.app_artifact_missing` / `configuration_failure` |
| shim build | `shim.build` | `runner.ios_shim.build_failed` / `runner_failure` |
| shim readiness | `shim.prewarm` | `runner.ios_shim.readiness_timeout` / `runner_failure` |
| scenario execution | `scenario.execute` | healthy-driver `app.assertion_failed` / `app_failure` |
| report generation | `report.generate` | `runner.report_failed` / `runner_failure` |
| summary validation | `evidence.finalize` | `runner.evidence_invalid` / `runner_failure` |

For every row, assert the original injected exit status, exactly one terminal
schema-valid summary, ordered individually valid JSONL events, one metadata file
with its bounded stdout/stderr logs for each executed fake command, sanitized
paths/secrets, and the exact precedence-derived phase/code/classification. Add
unknown, missing-app, unsupported-device, cancellation, and cleanup-failure
rows so every terminal classification and precedence override is exercised.

- [ ] **Step 2: Run the test and verify failure**

Run:

```bash
bash tests/run-evidence-script-test.sh
bash tests/run-evidence-acceptance-test.sh
```

Expected: FAIL because the adapter does not exist.

- [ ] **Step 3: Implement the shell adapter**

Support wrapper mode:

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

And sourced-library functions when `ZMR_RUN_EVIDENCE_ROOT` is set:

```bash
zmr_evidence_event <phase> <status> [error-code] [summary] [artifact]
zmr_evidence_run <phase> <name> <failure-code> -- <command> [args...]
zmr_evidence_capture <destination-variable> <phase> <name> <failure-code> -- <command> [args...]
zmr_evidence_run_background <phase> <name> <failure-code> -- <command> [args...]
zmr_evidence_wait <evidence-child-id>
zmr_evidence_update_context <json-patch>
zmr_evidence_finalize_pass
zmr_evidence_finalize_failure <classification> <phase> <code> <summary> <hint> [status]
```

The wrapper installs EXIT/INT/TERM traps, preserves the wrapped command status,
and always validates the complete sanitized bundle before returning.
`zmr_evidence_run` delegates to `run_evidence.py command`; scripts must not
manually redirect an evidence-enabled setup subprocess because that would bypass
bounded capture and redaction. Background commands use
`zmr_evidence_run_background`/`zmr_evidence_wait`, which retain the child PID but
finalize the same metadata/log record only after wait observes its true status.
For discovery commands whose stdout drives later shell logic,
`zmr_evidence_capture` assigns raw stdout to the named shell variable only in
memory with xtrace disabled, while persisting/replaying only its sanitized form;
the raw value is never written beneath the publication root. Integration tests
cover spaces/newlines, nonzero status, and a secret-bearing captured value.

- [ ] **Step 4: Add the new tests to fast and release gates**

Insert:

```bash
run "python3 -W error -m unittest tests/run_evidence_test.py"
run "bash tests/run-evidence-script-test.sh"
run "bash tests/run-evidence-acceptance-test.sh"
```

Update dry-run assertions accordingly.

- [ ] **Step 5: Run focused tests**

Run:

```bash
bash tests/run-evidence-script-test.sh
bash tests/run-evidence-acceptance-test.sh
bash tests/ci-gate-script-test.sh
bash tests/release-gate-script-test.sh
bash -n scripts/run-evidence.sh
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/run-evidence.sh tests/run-evidence-script-test.sh tests/run-evidence-acceptance-test.sh scripts/ci-gate.sh scripts/release-gate.sh tests/ci-gate-script-test.sh tests/release-gate-script-test.sh
git commit -m "feat(evidence): add trap-safe command wrapper"
```

## Task 5: Instrument demos, pilots, and device-matrix attempts

**Files:**

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

- [ ] **Step 1: Extend fake-script tests with an evidence context**

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

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
bash tests/android-real-demo-script-test.sh
bash tests/ios-real-demo-script-test.sh
bash tests/android-pilot-script-test.sh
bash tests/ios-pilot-script-test.sh
bash tests/device-matrix-test.sh
```

Expected: new evidence assertions fail.

- [ ] **Step 3: Source the adapter without changing behavior when disabled**

At each script's initialization:

```bash
# shellcheck source=run-evidence.sh
source "$ROOT/scripts/run-evidence.sh"
```

Every evidence helper must be a no-op when `ZMR_RUN_EVIDENCE_ROOT` is unset, so
existing app-local scripts and output remain compatible.

- [ ] **Step 4: Emit phase boundaries around existing commands**

Refactor each script's central `run`/capture/background helper to delegate every build,
device acquisition/preflight, install, shim build/start/readiness, scenario,
report, and cleanup subprocess to `zmr_evidence_run`, `zmr_evidence_capture`, or
the background/wait pair. The adapter emits the before/after events and command records; do not also
emit duplicate boundaries. When evidence is disabled, the helper executes the
same command directly with unchanged stdout, stderr, status, and retry behavior.

For a command failure, emit the primary error code before returning. Unknown
failures remain runner failures. A healthy-driver scenario assertion failure is
`app.assertion_failed`; an absent app path is
`config.app_artifact_missing`; known hosted provisioning failures use the
matching `infra.*` code.

- [ ] **Step 5: Give matrix rows stable logical/attempt identity**

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

- [ ] **Step 6: Run the focused script suite**

Run the commands from Step 2. Expected: all pass and existing non-evidence
assertions remain unchanged.

- [ ] **Step 7: Commit**

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
`codex/production-1-0` and open a draft PR, but do not infer merge approval from
this plan.

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
