# ZMR 1.0 M0: Trust Baseline Design

**Status:** Proposed for implementation planning

**Date:** 2026-07-11

**Parent:** `2026-07-11-zmr-1-0-program-design.md`

## Goal

Make repository status and device-smoke evidence trustworthy before changing the
runner architecture or expanding the command surface.

At the end of M0:

- the exact remote revision under evaluation has a green required quality gate;
- direct pushes cannot bypass that gate;
- scheduled Android/iOS smoke jobs always publish a structured result and useful
  diagnostic artifact, including failures before a scenario trace exists;
- failure rows distinguish runner, app, infrastructure, configuration, and
  cancelled outcomes;
- release and CI dependencies are reproducible enough to serve as the foundation
  for later certification evidence.

M0 does not claim to fix every underlying Android or iOS runner flake. It makes
those failures observable, classifiable, reproducible, and impossible to hide.

## Current Problems

1. Remote `main` currently fails the public-metadata guard after a README-only
   commit.
2. `main` has no branch protection and accepts direct pushes.
3. Recent scheduled device-smoke failures include iOS shim readiness timeouts and
   an Android wait/ADB failure.
4. The iOS job uploads only the trace directory. When shim prewarming fails
   before trace creation, the workflow reports that no files were found.
5. Workflow dependencies use mutable major tags and downloaded toolchains are
   not checksum-verified.
6. Existing 20-run gates are useful smoke tests but are not statistically strong
   enough for a production reliability claim.

## In Scope

### 1. Restore a green mainline candidate

- Reproduce and fix the public-metadata guard failure on the current remote
  README without weakening the guard.
- Ensure the full local quality gate passes on the candidate commit.
- Keep the public README outcome-oriented while satisfying the repository's
  public-safety policy.

### 2. Stable workflow contracts

- Give required workflow jobs stable names that can be referenced by repository
  rules.
- Set least-privilege explicit workflow permissions.
- Add concurrency policies that cancel superseded pull-request runs without
  cancelling release or scheduled certification work.
- Ensure diagnostic upload steps run with `if: always()` and fail loudly when a
  required summary is missing.
- Keep success artifacts bounded by documented retention periods.

### 3. Bootstrap evidence

Add a run-level evidence directory that is created before app, device, emulator,
simulator, or shim setup. It is separate from an optional scenario trace.

The directory contains:

- `run-summary.json` — stable machine-readable terminal status;
- `bootstrap-events.jsonl` — ordered phase transitions and diagnostics;
- `commands/` — bounded stdout/stderr logs for setup subprocesses;
- optional links or relative paths to scenario traces and reports.

The workflow uploads the run-level directory even when no scenario trace was
created.

### 4. Failure classification

Every run summary has exactly one terminal classification:

- `passed`;
- `runner_failure` — ZMR code, protocol, driver, cleanup, or evidence pipeline;
- `app_failure` — assertion, app crash, or app-owned behavior;
- `infrastructure_failure` — hosted runner, emulator/simulator provisioning,
  external service, disk, or tool availability outside ZMR's control;
- `configuration_failure` — invalid app path, device selection, signing, or
  unsupported capability;
- `cancelled` — explicit user or CI cancellation.

Classification includes:

- stable `phase`;
- stable public `errorCode` for every failed or cancelled result;
- human summary and remediation hint for every failed or cancelled result;
- command exit status, or explicit `null` when no subprocess owns the failure;
- runner, host, platform, device, and toolchain metadata;
- trace/report paths when present;
- retry attempt and whether the result is first-attempt or eventual.

Unknown failures default to `runner_failure` with an `unclassified` error code;
they may not be omitted from readiness calculations.

### 5. Evidence statistics

- Treat a logical execution and an attempt as different records. A logical
  execution has one `executionId`; its first attempt and every retry have unique
  `runId` values and monotonically increasing `attempt` numbers.
- Store one `run-summary.json` per attempt directory. An aggregate index groups
  attempt summaries by `executionId`; no retry overwrites an earlier summary.
- Extend readiness evidence to retain every attempt.
- Report first-attempt pass rate separately from eventual pass rate.
- Support a certification sample-size gate, defaulting to 300 for Tier 1 stable
  claims while preserving smaller configurable local pilot gates. Certification
  sample size counts logical executions, never retry attempts.
- Report classification counts and runner-attributable failures.
- Do not exclude infrastructure rows from raw results. A report may present an
  adjusted runner rate only alongside total and first-attempt rates.

Two logical executions are equivalent certification rows only when this
comparability tuple is identical:

- `candidateRevision` — full source commit SHA;
- `fixtureId` and `fixtureVersion`;
- `scenarioDigest` and `appBuildDigest`;
- `platform`, `deviceClass`, and declared OS/runtime version;
- host OS, architecture, and declared CI/hardware class;
- `runnerVersion` and `protocolVersion`;
- `timingMode` (`cold-command` or `warm-session`);
- declared toolchain versions that affect execution.

The producer writes a deterministic `comparabilityKey` from that tuple. The key
is `sha256:` plus the digest of a UTF-8 JSON object whose tuple keys are sorted
lexicographically, whose strings are unescaped except as required by JSON, and
whose encoding contains no insignificant whitespace. A missing tuple value is
encoded as JSON `null`; if any tuple value is null, `comparabilityKey` is also
null, `certificationEligible` is false, and `ineligibilityReasons` lists the
missing field paths. Such a row remains valid diagnostic evidence but cannot
enter a 1.0 certification cohort. The readiness report states the exact
candidate revision and non-null comparability key for every certification
cohort.

Certification uses at least 300 eligible logical executions. Any attempt in the
cohort classified as `runner_failure` fails the cohort, even when a later retry
passes. Retries never increase sample size and never erase first-attempt or
runner-failure counts. A new certification cohort must use the fixed candidate
revision.

### 6. Reproducible CI and release inputs

- Pin GitHub Actions to immutable commit SHAs with readable version comments.
- Pin Rust, Ruby gem, and other fetched build tools used in CI/release.
- Verify Zig archive checksums before extraction.
- Add tests that detect mutable action references and unverified tool downloads
  in release-critical workflows.

macOS signing/notarization and npm trusted provenance remain later M0-follow-up
release tasks if credentials or external package settings are required. M0 must
leave explicit machine-readable readiness failures for them rather than claiming
completion.

### 7. Repository rules

After the new stable quality job exists on the default branch, configure the
repository to:

- require a pull request for `main`;
- require the quality job;
- require branches to be current before merge;
- block force pushes and branch deletion;
- require conversation resolution;
- allow an explicitly documented emergency administrator bypass without making
  it the normal release path.

Repository-rule changes are an external deployment step. The implementation
plan must print the exact intended rule before applying it and verify the final
state through the GitHub API.

## Out of Scope

- Refactoring the scenario runner or MCP dispatcher.
- Adding new mobile actions or selectors.
- Implementing device sharding or a worker pool.
- Solving every iOS shim timeout or Android device flake.
- Protocol 1.0 freeze or a `1.0.0` version bump.
- Hosted dashboards or a ZMR cloud service.
- Framework-aware synchronization.

## Data Contracts

### Run summary

Add a public JSON Schema for the run-level summary. Required top-level fields:

```json
{
  "schemaVersion": 1,
  "runId": "device-smoke-ios-exec-42-attempt-1",
  "executionId": "device-smoke-ios-exec-42",
  "fixtureId": "generated-ios-demo",
  "fixtureVersion": "1",
  "candidateRevision": "<full-git-sha>",
  "scenarioDigest": "sha256:<digest>",
  "appBuildDigest": "sha256:<digest>",
  "comparabilityKey": "sha256:<digest-of-comparability-tuple>",
  "certificationEligible": true,
  "ineligibilityReasons": [],
  "status": "failed",
  "classification": "runner_failure",
  "phase": "shim.prewarm",
  "errorCode": "runner.ios_shim.readiness_timeout",
  "summary": "iOS XCTest shim did not become ready before its deadline",
  "startedAt": "2026-07-11T00:00:00Z",
  "finishedAt": "2026-07-11T00:05:00Z",
  "durationMs": 300000,
  "attempt": 1,
  "firstAttempt": true,
  "platform": "ios",
  "deviceClass": "ios-simulator",
  "runtimeVersion": "18.5",
  "timingMode": "cold-command",
  "runnerVersion": "0.2.17",
  "protocolVersion": "2026-04-28",
  "commandStatus": null,
  "hint": "Inspect commands/ios-shim-server.log and retry with a clean shim state",
  "host": {
    "os": "macos",
    "arch": "arm64",
    "class": "github-macos-15-arm64",
    "ci": true
  },
  "device": {
    "requested": "booted",
    "resolved": "<simulator-udid>"
  },
  "toolchain": {
    "xcode": "16.4",
    "zig": "0.16.0"
  },
  "artifacts": {
    "bootstrapEvents": "bootstrap-events.jsonl",
    "commands": "commands",
    "trace": null,
    "report": null
  }
}
```

The schema applies these conditional requirements:

| `status` | Allowed `classification` | Required failure fields |
| --- | --- | --- |
| `passed` | `passed` | `phase` must be `complete`; `errorCode`, `summary`, and `hint` are omitted |
| `failed` | `runner_failure`, `app_failure`, `infrastructure_failure`, or `configuration_failure` | non-empty `errorCode`, `summary`, and `hint`; `commandStatus` is an integer or `null` when no subprocess owns the failure |
| `cancelled` | `cancelled` | `errorCode` is `run.cancelled`; non-empty `summary` and `hint`; `commandStatus` may be `null` |

Every status requires `artifacts.bootstrapEvents` and `artifacts.commands`.
`trace` and `report` are nullable. Every failed or cancelled summary therefore
points to an artifact root even if it has no scenario trace. `host`, `device`,
and `toolchain` objects are required, but fields that cannot exist before device
resolution may be `null`. The source revision and requested fixture/platform
identifiers should be populated whenever the invocation supplied them; values
that truly cannot be known use explicit `null`, not fabricated placeholders.
`comparabilityKey`, `certificationEligible`, and `ineligibilityReasons` are
always required: incomplete rows use a null key, false eligibility, and one or
more missing-field reasons. Additional CI metadata fields are optional and
additive. Absolute local paths must be sanitized before public publication.

Readiness consumers recompute the canonical comparability key from source
fields and reject a non-null producer-supplied key that does not match; they do
not trust the supplied digest as an assertion.

`firstAttempt` must equal `attempt == 1`. `runId` is unique per attempt;
`executionId` is shared by retries of the same logical execution. An eventual
pass means the last attempt for an execution passed, while its failed first
attempt remains a failed row in first-attempt statistics.

### Bootstrap event

Each JSONL event includes sequence, timestamp, phase, status, and optional
error/command/artifact metadata. Valid status values are `started`, `passed`,
`failed`, `skipped`, and `cancelled`.

The stable M0 phase vocabulary is:

- `invocation`;
- `evidence.init`;
- `device.acquire`;
- `device.preflight`;
- `device.boot`;
- `app.build`;
- `app.install`;
- `shim.build`;
- `shim.start`;
- `shim.prewarm`;
- `scenario.validate`;
- `scenario.execute`;
- `trace.finalize`;
- `report.generate`;
- `evidence.finalize`;
- `cleanup`;
- `complete`.

New phases may be added in a backward-compatible schema release. Existing phase
meaning may not be changed within schema version 1.

### Classification precedence and error codes

Classification follows ownership of the primary cause, not merely the phase in
which it surfaced. When several failures occur, the summary records one primary
failure plus secondary diagnostics. Apply this precedence:

1. A failure to write, validate, finalize, or retain mandatory evidence is a
   `runner_failure`, regardless of the original cause.
2. A ZMR process, driver, shim, protocol, deadline, cancellation cleanup, or
   runner-owned child-process failure is a `runner_failure`.
3. Invalid configuration, missing app artifacts, unsupported requested
   capabilities, signing setup, or ambiguous device selection is a
   `configuration_failure`.
4. A demonstrable hosted-runner, OS provisioning, disk, network-download, or
   external emulator/simulator service failure is an `infrastructure_failure`.
5. An app assertion failure, app crash, or app-owned behavior mismatch is an
   `app_failure` when the driver and evidence pipeline remained healthy.
6. A requested cancellation is `cancelled` only when cleanup and evidence
   finalization succeed; otherwise the cleanup/evidence failure is primary and
   classified as `runner_failure`.
7. Anything not proven to belong to another class defaults to
   `runner_failure` with `runner.unclassified`.

The implementation maintains a tested error-code registry. M0 begins with:

| Classification | Stable M0 error codes |
| --- | --- |
| `runner_failure` | `runner.unclassified`, `runner.child_timeout`, `runner.cleanup_failed`, `runner.driver_protocol`, `runner.ios_shim.build_failed`, `runner.ios_shim.readiness_timeout`, `runner.trace_failed`, `runner.report_failed`, `runner.evidence_invalid` |
| `configuration_failure` | `config.invalid`, `config.app_artifact_missing`, `config.device_selection`, `config.signing`, `config.unsupported_capability`, `config.required_tool_missing` |
| `infrastructure_failure` | `infra.hosted_runner`, `infra.device_unavailable`, `infra.emulator_provision`, `infra.simulator_provision`, `infra.disk`, `infra.network` |
| `app_failure` | `app.assertion_failed`, `app.crashed`, `app.launch_failed` |
| `cancelled` | `run.cancelled` |

Adding an error code is backward-compatible. Renaming or reassigning an existing
code requires a schema-version change and migration note.

## Component Design

### Evidence helper

Create one implementation used by demo, pilot, and device-matrix wrappers to:

- initialize a run directory;
- append bootstrap events safely;
- execute or record bounded command logs;
- finalize a summary exactly once;
- recover an `unclassified` failure summary from shell traps;
- validate the summary against its public schema.

If a candidate summary fails validation, retain it as
`run-summary.invalid.json`, retain validator output, and atomically emit a
minimal schema-valid `run-summary.json` classified as
`runner_failure`/`runner.evidence_invalid`.

The first implementation may be a small dependency-free script compatible with
the project's current shell/Python release tooling. The data contract, not the
language, is the stable boundary.

### Workflow integration

Each device-smoke job creates its run directory before setup and passes it to the
platform demo/pilot wrapper. `actions/upload-artifact` uploads that root rather
than only `traces/`. Scenario traces remain nested or linked beneath the root.

### Readiness integration

`zmr-release-readiness` and benchmark reporting consume the new summaries in
addition to existing evidence rows. During transition, existing evidence remains
accepted but cannot satisfy the final 1.0 certification gate without the new
classification fields.

## Error Handling

- A shell EXIT trap finalizes a failure summary only if no terminal summary
  exists.
- Finalization uses a temporary file plus atomic rename.
- Log capture has explicit size limits and records truncation.
- Redaction/public-metadata guards run before artifacts become public.
- Summary validation failure is itself a `runner_failure` and keeps the invalid
  file plus validator output for diagnosis.
- Artifact upload failure fails the device-smoke job because missing evidence
  invalidates the result.

## Security

- Command logs pass through existing public-safety and redaction controls before
  publication.
- Environment variables and command arguments known to contain credentials are
  represented by redacted placeholders in events.
- Workflows use explicit minimal permissions.
- Third-party actions are pinned by full SHA.
- Downloaded toolchains are verified against pinned checksums from an
  authenticated repository-controlled value.

## Testing

### Unit and script tests

- create/finalize successful summary;
- trap-finalized unclassified failure;
- each terminal classification;
- atomic finalization and duplicate-finalize rejection;
- bounded/truncated command log behavior;
- path sanitization and secret redaction;
- schema validation and malformed-event rejection;
- 20-row local pilot and 300-row certification calculations;
- first-attempt versus eventual pass-rate reporting;
- immutable action reference and checksum policy checks.

### Workflow/static tests

- stable required job name;
- explicit permissions;
- appropriate concurrency behavior;
- `if: always()` evidence upload;
- required evidence path cannot be silently absent;
- release-critical action references are full SHAs.

### End-to-end acceptance

Using fake drivers, inject failures at:

- emulator/simulator acquisition;
- app install;
- shim build;
- shim readiness;
- scenario execution;
- report generation;
- summary validation.

Every injection must produce a valid run summary, bootstrap event stream, and
bounded command log with the expected classification.

The acceptance table follows the precedence rules above. In particular: shim
build/readiness and runner-owned wait failures are `runner_failure`; missing app
artifacts and unsupported device requests are `configuration_failure`; a
healthy-driver assertion miss is `app_failure`; known hosted provisioning
failures are `infrastructure_failure`; and unknown injected errors are
`runner_failure`.

## Acceptance Criteria

M0 is complete when:

1. the full local quality gate passes on the candidate revision;
2. the candidate's GitHub quality workflow passes;
3. static tests prove workflow pinning, permissions, concurrency, and evidence
   upload requirements;
4. all injected pre-trace failures generate valid diagnostic artifacts;
5. release-readiness reports total, first-attempt, eventual, and classified
   rates without dropping rows;
6. the default branch rules are applied and verified after the required job is
   available;
7. documentation explains how to inspect and reproduce a classified failure;
8. no public contract claims that the underlying iOS/Android flakes are fixed;
9. the work is committed in reviewable, independently verified changes.

## Rollout

1. Land code and workflow changes through the feature branch.
2. Verify the new quality job and device-smoke artifact contract on the branch.
3. Merge through a PR using the existing repository state.
4. Apply and verify default-branch repository rules immediately after the stable
   required job is present on `main`.
5. Observe scheduled device-smoke results for seven days before M1 uses them as
   a reliability baseline.
6. Treat any missing or invalid evidence artifact as a gate failure.

## Follow-on Dependency

M1 may begin planning in parallel, but its implementation cannot claim improved
reliability until M0 evidence can measure it. M2 device-lifecycle work uses M0's
failure phases and classification as its acceptance harness.
