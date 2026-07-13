# ZMR 1.0 M0: Trust Baseline Design

**Status:** Approved for implementation

**Date:** 2026-07-11

**Amended:** 2026-07-13 — durable Task 4 command supervision and explicit
Task 5 iOS outcome boundary

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
- optional `run-outcomes/` — bounded, registered, sanitized
  producer-to-wrapper sidecars that remain diagnostic evidence but are not a
  third public schema;
- optional links or relative paths to scenario traces and reports.

The workflow uploads the run-level directory even when no scenario trace was
created.

Long-running and background setup commands require a private control plane at
`<attempt>/.evidence-control/`. It contains bounded write-ahead command state,
process-identity leases, session ownership, and terminal intent. It is never a
publishable artifact: read-only bundle validation refuses while the tree exists,
and recovery removes it only after every command and the terminal summary are
durably committed and verified. This durability work is evidence
infrastructure; it does not refactor the scenario runner, dispatcher, or mobile
action surface.

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

An unexpected child signal is not cancellation. Cancellation exists only when
the session owner records an explicit cancellation request before forwarding a
signal and cleanup/evidence finalization both succeed. A requested expected TERM
may be a successful lifecycle stop; TERM-to-KILL escalation is
`runner.cleanup_failed`. Supervisor loss and raw-capture failure are evidence
runner failures even when a child result was also observed.

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

The public event schema does not need a private supervisor identifier. Recovery
stores the exact schema-valid started and terminal event objects inside bounded
private command state and verifies or appends those objects exactly once.

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
| `runner_failure` | `runner.unclassified`, `runner.child_timeout`, `runner.cleanup_failed`, `runner.command_supervisor_lost`, `runner.capture_failed`, `runner.driver_protocol`, `runner.ios_shim.build_failed`, `runner.ios_shim.readiness_timeout`, `runner.trace_failed`, `runner.report_failed`, `runner.evidence_invalid` |
| `configuration_failure` | `config.invalid`, `config.app_artifact_missing`, `config.device_selection`, `config.signing`, `config.unsupported_capability`, `config.required_tool_missing` |
| `infrastructure_failure` | `infra.hosted_runner`, `infra.device_unavailable`, `infra.emulator_provision`, `infra.simulator_provision`, `infra.disk`, `infra.network` |
| `app_failure` | `app.assertion_failed`, `app.crashed`, `app.launch_failed` |
| `cancelled` | `run.cancelled` |

Adding an error code is backward-compatible. Renaming or reassigning an existing
code requires a schema-version change and migration note.

## Component Design

### Evidence core and Bash adapter

One dependency-free Python implementation is the durable authority used by
demo, pilot, and device-matrix wrappers. It owns initialization, exact event
append, command supervision, private write-ahead state, recovery, session
ownership, exactly-once summary finalization, validation, and publication
eligibility.

`scripts/run-evidence.sh` is a thin GNU Bash 3.2 adapter. It exposes event,
foreground run, handled/retry run, stdout capture, dual capture, background
run/wait/stop, instrumented-script delegation, context update, cleanup
registration, and pass/failure intent functions. It does not own durable state
or classify output. When evidence is disabled, the sourced API preserves the
existing scripts' stdin/stdout/stderr/status behavior. It must not require Bash
4 features such as associative arrays, namerefs, `mapfile`, `wait -n`, or
dynamic file descriptors.

The Task 3 `run_evidence.py command` surface remains compatible, but Task 4
routes it through the same supervisor as the adapter. The generic command API
receives a phase, stable configured failure code, failure policy
(`terminal`/`handled`), stop policy (`none`/`expected-term`), execution mode, and
stdin policy. It never infers ownership by matching phase, exit status, or
stderr.

A direct compatibility `command` outside an adapter uses a one-shot handled
session and removes it after the command commits; it does not finalize the run.
Task 3 `context`, `event`, and `external` mutations accept an optional exact
session/generation pair, which becomes mandatory whenever control state exists;
the compatibility command reads the inherited pair. Partial/stale pairs fail
before recovery or mutation, and legacy `finalize` is refused while a control
session exists. Outside an adapter these surfaces retain one-shot compatibility.
Background adapter launch registers its command ID before spawn, waits at most
five seconds for verified `running`/`stop_requested` or fully `committed`
readiness, and later waits by status without holding evidence locks. Prepared,
exited, and materialized states are transitional, not ready. Committed command
state remains queryable during an active adapter session and is removed only by
owner finalization; a one-shot session may remove it after delivering the
result. The total command count per session is capped at 1,024, independently
of the eight-active-command limit. Readiness/control failure returns reserved
adapter status 125 and never abandons a possibly starting supervisor.

If a candidate summary fails validation, retain it as
`run-summary.invalid.json`, retain sanitized validator output, and atomically
emit a minimal schema-valid `run-summary.json` classified as
`runner_failure`/`runner.evidence_invalid`.

### Private control state

The nonpublishable control layout is:

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

Private documents use strict bounded JSON with no duplicate or unknown keys.
The fixed limits are 16 KiB for `session.json`, 32 KiB for terminal intent,
256 KiB for each command state, one primary plus at most eight secondary terminal
diagnostics, and at most eight active commands. Command/session IDs are 32
lowercase hexadecimal characters. A command accepts at most 256 argv elements,
16 KiB per element, and 64 KiB total encoded argv. The larger state bound is
required because an admitted sanitized argv can expand substantially under
canonical JSON escaping; the 64 KiB argv contract remains unchanged.
Terminal diagnostic summary and hint fields are independently capped at 512
UTF-8 bytes so the primary plus eight secondaries remain encodable within the
32 KiB terminal-intent bound even under worst-case JSON escaping.

`.commands.lock`, lifecycle/event locks, and `state.lock` are short mutation
locks. `supervisor.lease` and `group.lease` are long-lived ownership leases and
are not mutation locks. Every lock/lease path has a stable inode which is never
atomically replaced or unlinked while a possible holder exists; JSON state is
the replaceable payload.
Private directories have exact mode `0700` and private files exact mode `0600`;
wrong or special mode bits are corruption, not silently repaired. Lease
identities are canonical `<device>:<inode>` strings: each component is an
unsigned decimal 64-bit integer with no sign, whitespace, or leading zero
except the value `0` itself.

`session.json` binds `schemaVersion`, `sessionId`, `runId`, owner PID, a
platform-stable owner birth identity, `state`, `generation`, and `startedAt`.
Session state advances `active -> finalizing -> committed`.

Each command state binds `schemaVersion`, command/session identity, immutable
`creationGeneration`, stage, a canonical persisted-request fingerprint,
sanitized request and relative output paths, the exact started event,
supervisor identity, an immutable `anchorReservation`, anchor/child identity,
stop intent, child outcome, capture state, and materialization hashes. It
advances monotonically:

```text
prepared -> anchored -> running -> stop_requested? -> exited -> materialized -> committed
                    \-> anchor_stop_requested -> exited(stopped_before_ack)
                    \-> exited(exec_failure:127)
prepared|anchored|anchor_stop_requested|running|stop_requested
                    \-> exited(supervisor_failure:125)
```

`prepared` is the write-ahead record for the exact started event and contains a
non-null verified launch-supervisor PID/birth/lease identity plus the exact
stable group-lease inode reserved for its future anchor. Under commands ->
lifecycle -> events -> state-lock order, launch first reserves the complete
stable command layout, writes/fsyncs `prepared`, and then appends/fsyncs those
exact event bytes. No anchor or child is spawned before both records verify.
Every event allocation briefly takes `.commands.lock`, allowing a crash-created
prepared/event hole to be repaired before another sequence is assigned.

The trusted anchor opens and verifies the reserved group lease, reports its
identity, and waits behind a one-way launch barrier. The supervisor persists,
fsyncs, re-reads, and verifies `anchored` before sending `GO`; the anchor never
forks or execs a child before `GO` and exits if the supervisor pipe closes
first. `running` is durable only after a positive child exec acknowledgement.
A direct negative exec handshake is the sole legal `anchored -> exited`
exec-failure transition: it retains the verified anchor, no child object, the
exact status-127 outcome, and complete bounded capture described below.
Missing, malformed, timed-out, or transport-failed handshakes are
supervisor/capture failures, not this variant.

`requestFingerprint` is SHA-256 over canonical native JSON containing exactly
`sessionId`, `creationGeneration`, `request`, and `paths`, and is recomputed on
every read. Running state has these exact non-null identity shapes:

```text
supervisor = {pid, birthIdentity, leaseIdentity, role, predecessor}
anchorReservation = {groupLeaseIdentity, controlProtocolVersion}
anchor     = {pid, birthIdentity, sid, pgid, groupLeaseIdentity,
              controlProtocolVersion}
child      = {pid, birthIdentity, execAcknowledgedAt}
```

Supervisor role is `launch` or `recovery`; predecessor is null or a SHA-256
digest of the prior canonical supervisor object, preventing recursive history.
Anchor PID/SID/PGID are equal; PIDs are positive and distinct where the OS
reports distinct processes. `anchorReservation` has exactly
`groupLeaseIdentity` and `controlProtocolVersion`; both are immutable and must
equal the later anchor fields. Prepared requires the reservation and supervisor
only. Entry into anchored requires the verified launch supervisor; a later
same-stage recovery claim may replace it. Anchored requires an anchor with null
child, stop, outcome, capture, and materialization. Anchor-stop-requested adds only
stop intent while child remains null. Running adds the acknowledged child;
stop-requested adds stop intent; exited adds outcome/capture; materialized adds
exact hashes; and committed retains the historical objects. A recovery claim
may replace only the supervisor object under its stable lease and predecessor
rule; `leaseIdentity` is that stable file's device/inode identity and never
changes, while PID, birth identity, role, and predecessor identify the new
claimant. Once a pre-exit state has a recovery-role supervisor it may only retain
its stage, persist stop intent via `anchored -> anchor_stop_requested` or
`running -> stop_requested`, and then terminate as `supervisor_failure`; it may
never produce a normal exit/signal, exec failure, or stopped-before-ack result.
Stale prepared recovery may only produce the supervisor-loss branch. Every
other identity mutation,
illegal null combination, unknown field, or fingerprint mismatch is corruption.
The current session generation authorizes mutation separately and may exceed
creationGeneration after takeover.

Stop intent has exactly `{kind, requestedAt, killAuthorizedAt}`. `kind` is
`expected` or `cancel`; expected is legal only for a request whose stop policy is
`expected-term`. The two transitions that first request stop require
`killAuthorizedAt: null`. If the group remains live after the grace deadline,
the current lease holder atomically persists and fsyncs the sole legal
same-stage stop-intent mutation, null to an RFC3339 UTC timestamp no earlier
than `requestedAt`, before sending KILL. That timestamp is immutable and is the
write-ahead proof that escalation owns `runner.cleanup_failed`, including after
a crash before or after signal delivery. A recovery claim and kill authorization
are separate transitions; neither may smuggle changes to other fields.

The direct negative exec-handshake variant has exactly this complete exited
shape (in addition to the immutable common fields):

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

`N` and `M` are bounded non-negative integers and `M` is at most the public
10 MiB stream limit. The bounded negative handshake is the complete stderr
diagnostic, so it cannot be truncated. `child` is null because no executable
image was acknowledged; `child.execAcknowledgedAt` exists only on the positive
handshake required for `running`. Any exited status-127 record with a null
anchor, a non-null child, a different outcome/capture shape, or an ambiguous
handshake is corrupt rather than an exec-failure result.

A supervisor-owned control failure has exactly this exited outcome:

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

The byte counts are lower bounds. Supervisor loss requires a recovery-role
supervisor with a digest predecessor; capture failure may be recorded by a
verified launch or recovery supervisor. The reservation and every identity
known at the source stage are retained exactly.

If stop is requested after the anchor is durable but before child exec
acknowledgement, `anchor_stop_requested` advances to an exited
`stopped_before_ack` outcome. The outcome contains exactly `kind`,
`requestKind`, `graceExpired`, `escalated`, `shellVisibleStatus`, and
`stoppedAt`. A healthy expected stop is `(false, false, 0)`; a healthy
cancellation is `(false, false, 130)`; escalation is `(true, true, 125)` and
owns `runner.cleanup_failed`. Mixed grace/escalation booleans or any other
status are corrupt. These flags are derived from and cross-bound to
`stopIntent.killAuthorizedAt`; they are not the durable escalation authority.
Every non-supervisor-failure outcome requires `captureComplete: true`. For a
normal exit/signal, shell-visible status is the natural child status when no
stop exists, `0` for a healthy expected stop, `130` for healthy cancellation,
and `125` whenever KILL was authorized.

`materialized` binds the exact terminal event and hashes/sizes for metadata and
both logs; each log binding's byte size equals its capture `storedBytes`.
`committed` means those exact outputs/events have been verified and
the private command directory may be removed only at owner finalization or
after one-shot delivery. Raw argv, environment values, and
raw command output never enter state. Recovery spools contain only sanitized
data and use the public 10 MiB-per-stream head/tail limit.

### Command supervision and recovery

Each command has a trusted Python group anchor launched with
`start_new_session=True`. The anchor is SID/PGID leader and sole long-lived
holder of `group.lease`; the actual executable joins its group and never owns
the lease invariant. The anchor reports a bounded exec handshake, child
PID/birth identity, and wait outcome through anonymous control pipes. The
supervisor concurrently drains stdout and stderr so either stream can fill
without deadlock and is the sole holder of `supervisor.lease`.

Command reservation creates every stable file before state exists and returns
the actual held supervisor-lease descriptor plus the actual group-lease inode
identity. Creating `prepared` verifies the live descriptor with `fstat`, its
rooted path identity, exclusive ownership, and the current supervisor PID; a
persisted identity string alone grants no authority. Recovery of stale
`prepared` first holds the free supervisor lease, acquires the exact reserved
group lease, and re-reads the state before concluding that no anchor exists. If
the group lease is held, recovery reports busy or waits and does not mutate
state. Every rooted read cross-binds the supervisor, reservation, and non-null
anchor lease identities to the visible stable files. Every rooted command-state
mutation additionally verifies the candidate supervisor's current PID and
identity against the still-held supervisor lease descriptor immediately before
writing; authority-sensitive actions repeat descriptor-backed verification
immediately before acting.

The anchor remains alive after direct-child exit until the result is durable,
both streams are drained, and no non-anchor group member remains. It handles
group TERM without exiting; KILL escalation intentionally ends it. If the
supervisor pipe closes, the anchor remains as the stable group identity and
does not mutate evidence. Linux membership uses `/proc`; macOS uses `libproc`
plus `getsid`. Stored anchor PID, process birth identity, SID, PGID, membership,
and lease observations must agree before recovery may signal. A free group
lease alone is not death: the anchor identity must be absent and two
settlement-separated `killpg(pgid, 0)` probes must return `ESRCH`. Any
disagreement fails closed and blocks finalization.

Linux identity is `linux:<boot-id>:<proc-start-ticks>`, with parentheses-safe
field-22 parsing. macOS identity is `libproc` `PROC_PIDTBSDINFO` start seconds
and microseconds. Authorization-sensitive observations are performed twice.
The implementation supports Python 3.10+ on Linux and macOS without `pidfd`,
`preexec_fn`, second-resolution `ps`, or Linux-only assumptions on macOS.

Raw shell capture is independently capped at 1 MiB per requested stream and
exists only in memory/pipes. The supervisor emits one strict ASCII JSON/base64
envelope over a dedicated anonymous FD that it verifies with `fstat` is a FIFO
or socket, never a regular file or terminal. The envelope is capped at 3 MiB and
binds schema version, command ID, shell status, nullable payloads, decoded
lengths, SHA-256 digests, and capture completeness. Overflow, NUL, malformed or
truncated data, digest mismatch, or channel failure is `runner.capture_failed`,
with no partial payload and any child result retained as secondary. Sanitized
logs remain capped at 10 MiB per stream, retaining the first and final 5 MiB.
The stress requirement is simultaneous 256 MiB stdout and stderr without
deadlock or unbounded retention.

The Bash adapter disables xtrace before capture, holds only the ASCII envelope,
and pipes it with builtin `printf` to a Python stdin-only decoder which writes
one selected stream to stdout. Dual capture validates both streams before
assigning either destination. Raw-derived bytes never enter argv, environment,
here-documents, here-strings, or regular files. Exact 1 MiB succeeds; 1 MiB+1,
NUL, broken transport, or invalid envelope returns status 125 and leaves
destinations unchanged. Complete capture assigns output using Bash command-
substitution trailing-newline semantics and returns the child's shell-visible
status, including nonzero status.

Command metadata adds `commandId`, `configuredFailureCode`,
`captureComplete`, the backward-compatible `supervisorFailure` boolean, and an
exact `termination` object. The supervisor marker distinguishes a runner-owned
control failure from independently truthful capture completeness and observed
child outcome. An unexpected child signal
uses the configured failure code, not cancellation. An expected TERM is success
only when explicitly requested and completed inside the two-second grace.
Escalation to KILL is `runner.cleanup_failed`. Supervisor loss is
`runner.command_supervisor_lost`.

Recovery is deterministic and idempotent:

| Durable stage/observation | Recovery behavior |
| --- | --- |
| live supervisor | report busy; do not mutate or finalize |
| reserved directory without `state.json`; exact empty layout and state lock plus both leases free | re-read under the command gate, remove it as never prepared, and emit no command event |
| reserved directory without `state.json` whose layout, content, lock, or lease observation disagrees | retain it as unsafe and block mutation/finalization |
| stale `prepared` with exact reserved group lease held | report busy or wait for the pre-`anchored` anchor to exit; do not mutate |
| stale `prepared` with supervisor and exact reserved group leases free after re-read | append/verify the exact started event, materialize incomplete evidence, and emit one supervisor-lost terminal event |
| orphaned `anchored`/`anchor_stop_requested`/`running`/`stop_requested` with proven anchored live group | claim recovery, TERM, wait two seconds, persist KILL authorization before escalation if required, then materialize incomplete evidence |
| group lease free, anchor absent, and two settlement-separated signal probes return `ESRCH` | treat the group as gone and materialize incomplete evidence |
| any lease/anchor/identity/membership disagreement | do not signal; retain state and block finalization |
| `exited` before materialization | retain child result as secondary; recovery/capture loss is primary |
| `materialized` | complete only missing exact hash-bound outputs/event; never overwrite a mismatch |
| `committed` | verify and retain in an active adapter session; remove at owner finalization or after one-shot delivery |
| corrupt state, changed birth identity, or unproven group | do not signal/delete/overwrite; block mutation, finalization, and publication |

Recovered streams set `captureComplete: false`, `truncated: true`, and byte
counts as lower bounds. Repeated recovery cannot duplicate a started or terminal
event. Recovery first claims a free `supervisor.lease` and persists the
recoverer under short locks, then releases mutation locks before signalling,
waiting, sleeping, draining, or joining. Locks are reacquired only to persist
transitions, so two recoverers cannot both act on one command.

### Session ownership and terminal intent

The first adapter process claims the attempt and exports
`ZMR_EVIDENCE_SESSION_ID` and `ZMR_EVIDENCE_SESSION_GENERATION`. `--owner-pid`
is only an assertion: it must equal the CLI's immediate parent, whose stable
birth identity is read before and after stable `.commands.lock` is acquired.
That file is the session/command gate for claim, takeover, launch, recovery
claim, close, and finalization.
Instrumented descendants are borrowers only when they supply the exact session
and generation and an at-most-64-process, cycle-checked ancestry walk proves the stored
owner identity. All authorization observations fail closed on change.

Borrowers may append events, supervise commands, and defer failure, but they
cannot close or finalize the run. `session-close` and `session-finalize` require
the CLI's immediate parent to be the stored owner with the same birth identity.
An independent owner is rejected while that identity is live. Orphan takeover
requires it to be absent and every supervisor lease free; takeover atomically
replaces owner identity and increments generation. Old-generation mutations
are rejected without recovery or mutation. Once prepared under an authorized
ancestry, the exact stored supervisor identity may advance only that already-
bound command despite later shell exit or reparenting; it cannot launch another
or mutate unrelated session state.

Takeover holds `.commands.lock` and performs a bounded scan of every
noncommitted command. Each stable supervisor lease must be immediately
acquirable and its stored supervisor birth identity absent; lease claims also
briefly require the gate, so none can appear between the scan and generation
increment. Any disagreement blocks takeover. Command `creationGeneration` is
immutable: a new owner may claim/recover an older same-session command using
the current generation without rewriting it. Terminal diagnostics retain
server-stamped `recordedGeneration`; new diagnostics use the new generation.
Thus takeover needs no multi-file rebinding. A live group anchor is handled by
normal post-takeover recovery under an exclusive supervisor lease.

INT/TERM handling persists cancellation intent before forwarding signals.
Owner EXIT first calls `session-close`, atomically moving active to finalizing
under the command gate. New commands, ordinary events, context changes,
delegation, and pass intent then fail; stop/recovery and cleanup/evidence
diagnostics remain permitted. The owner runs only owner-local cleanup in LIFO
order, durably enumerates/stops every remaining group, recovers commands,
resolves terminal intent, finalizes once, verifies/removes fully committed
control state, and validates. Each borrower runs its own shell-local cleanup
before deferring failure; cleanup functions/argv are never serialized. A retry
completes the owner sequence after a crash.
Resolution is:

1. evidence/control failure identified by the server-owned codes
   `runner.evidence_invalid`, `runner.command_supervisor_lost`, or
   `runner.capture_failed`;
2. cleanup failure or expected-stop escalation as `runner.cleanup_failed`;
3. explicit/deferred concrete classified failure under the public precedence
   registry, excluding `runner.unclassified`;
4. requested cancellation as `run.cancelled` when cleanup and evidence are
   healthy;
5. nonzero unclassified shell exit as `runner.unclassified`;
6. pass.

Caller-controlled fields such as diagnostic `source` never choose a resolution
tier. Permuting the same diagnostic set must always select the same primary.

The persisted intent is session-bound rather than current-generation-bound. It
contains a server-assigned ordinal, timestamp, and `recordedGeneration` per
diagnostic, `nextOrdinal`, `droppedCount`, one recomputed primary, and the eight
strongest unique secondaries. Dedupe compares normalized caller semantic fields
only, excluding those three server fields, and only against the currently
retained primary-plus-secondary set. Retained order is strongest precedence
first and ordinal ascending for ties. A retained-key duplicate changes neither
counter. Every delivery whose key is absent from the retained set allocates an
ordinal; an evicted or unretained delivery increments `droppedCount`. Dropped
keys are not remembered. Eviction atomically removes the evicted diagnostic's
semantic key, so any later redelivery is a new insertion and is counted again
with a fresh ordinal; if it remains unretained, it increments `droppedCount`
again. Callers cannot supply the server fields. Atomic
recomputation ensures nested
scripts, concurrent traps, and a full secondary set cannot erase a later
evidence or cleanup cause.

### Locking and publication invariants

The only valid nested lock order is:

```text
.transactions.lock
  -> attempt-index lock (when needed)
  -> .commands.lock
  -> .lifecycle.lock
  -> .events.lock
  -> per-command state lock
```

Locks to the left may be omitted when unnecessary, but never acquired after a
lock to their right. No lock remains held during process spawn/wait, stream
drain/replay, thread join, status polling, sleep, or signal delivery. The
readiness timeout and ordinary evidence-lock timeout are each five seconds;
status polling uses 50 ms and TERM/KILL grace/settlement are two seconds each.
The duration rule applies to mutation locks, not the two ownership leases.

Every mutation first recovers lifecycle journals and stale command state.
Command launch and `session-close` share the short `.commands.lock` gate:
launch persists `prepared` before release; close performs `active -> finalizing`
before shell cleanup. Therefore a launch/close race has one serial outcome and
cannot create post-close commands. Final summary commit takes transaction ->
index -> commands -> lifecycle -> events locks, rechecks exact generation,
finalizing state, and absence of live/noncommitted commands, and changes the
session to committed only after the existing finalize receipt verifies.
Ordinary events and other commands remain available while an active-session
child runs longer than the five-second lock timeout.

`validate-bundle` is deliberately read-only. It never repairs state and refuses
any `.evidence-control` tree. A prior mutation may remove verified committed
state only during owner finalization (or completed one-shot delivery); only then
can public validation and upload succeed.

### iOS shim provenance and run-outcome boundary

Task 5, not the generic supervisor, owns platform-specific interpretation. Each
iOS target kind (`simulator` and `physical`) independently selects a stable shim
mode:

- `disabled` — no selector shim;
- `generated` — repository-generated XCTest shim;
- `provided` — app/user-supplied shim command.

There is no implicit simulator-to-physical fallback. Existing `--ios-shim`
usage remains compatible by normalizing it to `provided`; the generated demo
explicitly records `generated`. Missing/contradictory shim configuration is a
configuration failure. Build/start/prewarm/protocol failure after valid setup is
a runner failure. App ownership is allowed only when structured runner/trace
state proves the driver and evidence pipeline remained healthy.

Instrumented `zmr run` writes a bounded 64 KiB atomic internal
`run-outcome` sidecar before returning success or a handled failure. It contains
`schemaVersion`, `status` (`passed`/`failed`/`cancelled`), `failureOwner`, stable
nullable `errorCode`, `phase`, nullable `summary`/`hint`, normalized nullable
trace/report references, nullable child status, and nullable target-specific
shim mode/digest (`null` on Android). Passed and cancelled outcomes use owner
`none`; cancellation uses `run.cancelled`. The sidecar path must normalize under
the attempt's `run-outcomes/`, is registered by a bootstrap event, and is
scanned as publishable diagnostic evidence. This versioned sidecar is a
producer-to-wrapper contract, not a third public schema. It contains no raw
stderr or absolute local path, and normal `zmr run --json` output remains
compatible.

The evidence-side outcome consumer strictly validates the sidecar, registers
trace/report paths, and records terminal intent. Missing, malformed, oversized,
or mismatched mandatory sidecars are
`runner_failure`/`runner.evidence_invalid`. Scripts may inspect bounded stderr
to decide whether a `simctl` install attempt is retryable, but never to assign
terminal ownership. iOS prewarm maps its JSON pipe to foreground stdin
inheritance, retries use handled-failure policy, and normal long-lived shim
shutdown uses expected-stop policy; these platform mechanics do not add special
cases to the generic supervisor.

Consumption binds `run-outcomes/<command-id>.json` to that command's committed
metadata and the active session. Any non-null sidecar child status must match
the supervisor's shell-visible status; identity/status/artifact disagreement is
evidence invalidation rather than a tie-breaker.

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

- Shell traps persist bounded terminal intent. Only the owning Python-backed
  EXIT dispatcher may finalize, and only after cleanup, background-command
  shutdown, and command recovery complete.
- Borrower shells never finalize the owner's run; orphan takeover requires
  stored PID birth-identity and lease proof.
- Unexpected child signals remain configured failures. Explicit cancellation is
  reported only after healthy cleanup/evidence; escalation is a cleanup runner
  failure.
- Supervisor/capture loss takes precedence over an observed child result and
  leaves incomplete, truncated recovery metadata rather than claiming complete
  capture.
- Finalization uses a temporary file plus atomic rename.
- Log capture has explicit size limits and records truncation.
- Redaction/public-metadata guards run before artifacts become public.
- Corrupt or unsafe private state blocks mutation/finalization/publication and
  is never deleted or signalled through speculatively.
- Summary validation failure is itself a `runner_failure` and keeps the invalid
  file plus validator output for diagnosis.
- Artifact upload failure fails the device-smoke job because missing evidence
  invalidates the result.

## Security

- Command logs pass through existing public-safety and redaction controls before
  publication.
- Raw capture remains bounded in memory/pipes and is never written to command
  state, recovery files, or the publication root.
- Environment variables and command arguments known to contain credentials are
  represented by redacted placeholders in events.
- Private state uses rooted regular-file/no-symlink checks and is rejected by
  public bundle validation. Recovery signals only a process group whose stored
  PID, birth identity, PGID, and leases still prove ownership.
- The iOS run-outcome sidecar is bounded, atomic, path-normalized, and contains
  structured ownership rather than raw stderr.
- Workflows use explicit minimal permissions.
- Third-party actions are pinned by full SHA.
- Downloaded toolchains are verified against pinned checksums from an
  authenticated repository-controlled value.

## Testing

### Unit and script tests

- create/finalize successful summary;
- owner-dispatched and borrower-deferred unclassified failure;
- each terminal classification;
- atomic finalization and duplicate-finalize rejection;
- strict bounded private-state schemas and legal monotonic transitions;
- crash recovery after every command stage, including idempotent exact-event
  replay and fail-closed corrupt/PID-reuse cases;
- a command running longer than five seconds while events and independent
  command launches continue, plus launch/session-close races;
- process-group descendant cleanup, expected TERM, cancellation, unexpected
  signal, escalation, and supervisor loss;
- 1 MiB raw capture limits and 256 MiB simultaneous stdout/stderr stress;
- strict anonymous-pipe capture envelopes at exact/+1 bounds, malformed/digest
  failure status 125, unchanged destinations, and no raw marker in argv,
  environment, xtrace, attempt files, or monitored temporary directories;
- owner/borrower nesting, rejected independent ownership, orphan takeover, and
  shell-local LIFO cleanup, including spoofed owner, stale generation, ancestry
  race, and same-PID/different-birth rejection;
- session-close launch-gate races, two-recoverer claims, top-eight terminal
  precedence/eviction, and every close/finalize crash boundary;
- Linux boot-ID/start-tick and macOS libproc birth providers, child FD closure,
  leader-before-grandchild exit, and ambiguous lease/group fail-closed cases;
- GNU Bash 3.2 parsing and behavior without Bash 4-only features;
- bounded/truncated command log behavior;
- path sanitization and secret redaction;
- atomic iOS run-outcome sidecars, simulator/physical shim provenance, and
  structured ownership without stderr classification;
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

The harness also injects supervisor death at each durable command stage,
capture overflow, unexpected signal, requested cancellation, expected TERM,
TERM-to-KILL escalation, cleanup failure, corrupt private state, nested borrower
failure, owner loss/takeover, and launch/session-close races. A command running longer
than five seconds cannot block ordinary event append. Read-only validation must
refuse live private state and succeed only after verified recovery removes all
committed control data during owner finalization or one-shot delivery.

The acceptance table follows the precedence rules above. In particular: shim
build/readiness and runner-owned wait failures are `runner_failure`; missing app
artifacts and unsupported device requests are `configuration_failure`; a
healthy-driver assertion miss is `app_failure`; known hosted provisioning
failures are `infrastructure_failure`; and unknown injected errors are
`runner_failure`.

Real iOS acceptance covers simulator and physical targets separately for
`disabled`, `generated`, and `provided` shim modes. The final app/runner/config
ownership and trace/report references must come from the atomic run-outcome
sidecar. Missing or invalid mandatory sidecar data is evidence failure; stderr
text is not an ownership oracle.

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
9. the work is committed in reviewable, independently verified changes;
10. long-running commands do not hold lifecycle locks, crash recovery stops
    every descendant whose identity is proven and blocks safely when it is not,
    and no private control tree is publishable;
11. iOS simulator/physical shim provenance is explicit and terminal ownership
    comes from a valid atomic run-outcome sidecar rather than stderr matching.

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
