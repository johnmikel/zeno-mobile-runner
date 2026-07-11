# Zeno Mobile Runner 1.0 Program Design

**Status:** Proposed for implementation planning

**Date:** 2026-07-11

**Target:** Zeno Mobile Runner 1.0

## Executive Decision

Zeno Mobile Runner 1.0 will be positioned and built as the agent-native mobile
verification runtime, not as a generic "native app test runner" and not as a
feature-for-feature clone of competing mobile runners.

The 1.0 program combines:

1. a framework-agnostic, local-first device control plane;
2. production-grade reliability, diagnostics, release integrity, and protocol
   compatibility;
3. selective command and selector parity needed to migrate real suites;
4. an agent-specific verification loop that converts structured observation and
   actions into deterministic, reviewable CI scenarios and replayable evidence;
5. optional framework-aware synchronization adapters where black-box waits are
   insufficient.

The program is intentionally decomposed into milestone-sized specifications and
implementation plans. This document is the release contract and dependency map;
it is not a single implementation plan.

## Context

The current `0.2.x` product already has strong foundations:

- one native Zig binary with Android and iOS backends;
- CLI JSON, JSON-RPC, MCP, and committed JSON scenarios over one runner model;
- semantic snapshots, typed actions, waits, assertions, trace explanation,
  trace-to-scenario discovery, HTML/JUnit reports, and redacted bundles;
- public JSON Schemas and reference clients in six languages;
- checksums, SBOM generation, release attestations, and scheduled real-device
  emulator/simulator smoke workflows.

The remaining gap is not a missing version number. The current remote state has
an unprotected and red `main` branch, recent scheduled device-smoke failures,
pre-trace failures that can produce no useful artifact, stale competitive
benchmarks, a sequential device matrix, a narrower action/selector surface than
the incumbents, and manually duplicated public protocol definitions.

Releasing `1.0.0` without closing those gaps would weaken the product's strongest
claim: trustworthy evidence.

## Product Thesis

### Primary user

An application engineer or coding agent that changes a mobile app and must prove
the change on a real emulator, simulator, or attached device before the change
is accepted.

### Core job

> Observe the actual mobile UI as structured state, perform a bounded action,
> verify the expected outcome, diagnose failures, and leave deterministic,
> reviewable evidence that can replay in CI without an LLM.

### Secondary users

- mobile test engineers migrating smoke and release-critical flows;
- CI and release engineers operating self-managed device pools;
- SDK/client authors embedding a stable mobile automation protocol;
- teams testing native, React Native, Expo, or Flutter applications through one
  platform-level contract.

### Differentiation

ZMR 1.0 wins when an agent-driven development workflow needs all of the
following together:

- token-efficient semantic state rather than terminal prose;
- typed, capability-discovered actions with stable public errors;
- risk-aware and secret-safe execution;
- trace-backed failure explanations and run comparisons;
- conversion of a reviewed live session into a deterministic test;
- portable local execution without a required hosted account;
- current, reproducible evidence for supported device classes.

MCP availability by itself is not differentiation. Framework agnosticism by
itself is not differentiation. Startup speed by itself is not differentiation.
The compound verification workflow is the product.

## 1.0 Scope

### Tier 1 production support

- Android emulators on supported Linux and macOS hosts.
- Attached Android devices through ADB.
- iPhone simulators on supported macOS/Xcode combinations.
- Native, React Native, Expo development-client, and Flutter applications that
  expose stable platform accessibility semantics.
- CLI, JSON-RPC stdio, MCP stdio, and committed scenario execution.

### Tier 1.5 certified-with-evidence support

- Physical iPhone devices through `devicectl` plus the XCTest shim.
- iPad simulators and physical iPads, certified separately from iPhone layouts.

These targets may ship in 1.0 only with explicit evidence labels. Missing
hardware evidence must not block the stable core release, but must prevent an
unqualified production-support claim for that target.

### Deferred from 1.0

- A ZMR-owned hosted device cloud.
- Web-browser automation.
- tvOS and watchOS.
- Flutter widget-tree or Dart-state inspection.
- A built-in LLM or an unbounded autonomous crawler.
- Exhaustive parity with every competing runner or platform automation API.

## Quality Attributes

The following attributes are release requirements, not aspirational roadmap
items.

### Reliability

- A failed command must terminate or clean up every child process it owns.
- Every failure after command start must produce a machine-readable phase,
  stable error category, remediation hint, and artifact location.
- Bootstrap failures must be diagnosable even when a scenario trace never
  starts.
- Device and shim state machines must have explicit deadlines, cancellation,
  retry budgets, and stale-state cleanup.
- Repeated-run evidence must distinguish product failures, app failures, and
  external infrastructure failures without silently discarding any row.

### Compatibility

- `1.0` establishes a semantic-versioned public protocol line.
- Existing 1.x clients must continue to work across additive 1.x server
  releases.
- Breaking scenario, JSON-RPC, MCP, trace, or error changes require a 2.0 line
  or an explicitly documented compatibility bridge.
- Deprecations remain discoverable through capabilities for at least two minor
  releases before removal.

### Security and privacy

- Secrets can be supplied by references/handles that never persist in traces,
  reports, snapshots, generated scenarios, or logs.
- TCP remains loopback-only unless a future authenticated transport is designed.
- Trace artifacts have explicit sensitivity metadata and configurable retention.
- Release inputs and CI actions are pinned and verified.
- Stable releases are signed/notarized where the platform supports it and carry
  checksums, SBOM, provenance, and artifact attestations.

### Performance and scalability

- A persistent session avoids per-action runner and shim startup.
- Multiple devices can execute independently through bounded workers.
- Cancellation releases the device lease and child processes.
- Semantic observations support deltas so agents do not repeatedly consume a
  full unchanged hierarchy.
- Trace writing is bounded and configurable for long suites.

### Operability

- CI and scheduled smoke workflows publish summaries and diagnostic artifacts
  on both success and failure.
- Failure categories can be aggregated into a reliability dashboard.
- A release-readiness command evaluates evidence, protocol compatibility,
  current benchmarks, platform certification, and supply-chain requirements.

## Target Architecture

### Canonical public contract

Introduce one canonical action and protocol specification layer. It will be the
source for:

- scenario JSON Schema;
- MCP tool schemas;
- JSON-RPC method metadata;
- capability output;
- generated client types and method stubs where practical;
- documentation tables;
- protocol golden fixtures and conformance tests.

Zig enums and exhaustive switches remain the runtime safety boundary. Generated
metadata removes duplicated hand-maintained JSON and documentation; it does not
replace typed execution.

### Runner components

The core will be divided into independently testable units:

1. **Session manager** — owns device leases, cancellation, deadlines, and trace
   lifecycle.
2. **Action handlers** — lifecycle, observation, input, assertion, environment,
   and orchestration groups.
3. **Platform drivers** — Android and Apple adapters implementing a versioned
   capability contract.
4. **Synchronization providers** — black-box settling by default and optional
   framework-aware idleness providers.
5. **Evidence pipeline** — bootstrap diagnostics, trace events, artifacts,
   reports, redaction, comparison, and export.
6. **Transport adapters** — CLI, JSON-RPC, and MCP mapping to the same generated
   public contract.
7. **Scheduler** — bounded parallel device workers, sharding, retries, and
   aggregate reporting.

### Capability negotiation

Every session returns exact support for the selected platform and driver,
including command availability, selector features, synchronization provider,
physical-device constraints, artifact features, and deprecation metadata.
Unsupported operations fail before partially changing device state.

### Evidence lifecycle

The execution lifecycle is:

```text
invocation
  -> bootstrap record
  -> device acquire/preflight
  -> app/shim prepare
  -> session trace
  -> action/assertion events
  -> terminal classification
  -> report/export/comparison
  -> retention cleanup
```

The bootstrap record exists before device or shim work begins. A scenario trace
may reference it, but no failure is allowed to erase it.

## Milestone Decomposition

### M0 — Trust baseline

Restore a protected green mainline, make all CI/device failures publish useful
diagnostics, introduce structured failure classification, harden workflow
permissions and dependency pinning, and define statistically meaningful
reliability evidence. This milestone has its own design specification.

### M1 — Protocol and runtime boundaries

Create the canonical action/protocol registry, generated metadata and fixtures,
driver capability contract, session cancellation model, and split action
handlers. Preserve all existing public behavior through compatibility tests.

### M2 — Device reliability

Implement explicit Android and Apple lifecycle state machines, harden the iOS
shim build/server lifecycle, guarantee child cleanup, add chaos/fault-injection
tests, and certify the Tier 1 platform matrix.

### M3 — Migration-grade authoring surface

Add the high-value actions, selectors, subflows, variables, environment
profiles, scoped retries, and import compatibility reports required by real
competing-runner migration pilots. Features are prioritized by pilot evidence,
not raw parity count.

### M4 — Parallel execution and integrations

Add device leasing, bounded workers, `shard-all` and `shard-split`, deterministic
artifact naming, cancellation, aggregate reports, and reusable integrations for
GitHub Actions, Fastlane, EAS/Expo, and generic self-hosted CI.

### M5 — Agent-native advantage

Add semantic snapshot deltas, action-risk policies, secret handles, trace diff,
flake classification, replay-coverage scoring, and improved reviewed
trace-to-test generation.

### M6 — Optional synchronization and 1.0 certification

Add opt-in synchronization providers for supported React Native and Flutter
signals, execute current-version competitive benchmarks, complete design-partner
pilots, freeze 1.0 contracts, publish migration notes, and pass the release
gates below.

Each milestone receives a focused design, implementation plan, verification
report, and review before the next milestone depends on it.

## Release Gates

`1.0.0` may be tagged only when all mandatory gates pass.

### Repository and release gates

- `main` is protected against direct pushes and requires the full quality gate.
- The latest commit and release candidate are green.
- Every GitHub Actions dependency is pinned to an immutable commit.
- Build tool downloads are version-pinned and checksum-verified.
- macOS artifacts are signed and notarized.
- npm publication uses trusted publishing/provenance.
- Archives include verified checksums, SPDX SBOM, provenance, attestations, and
  third-party notices.

### Reliability gates

- At least 300 equivalent logical executions per Tier 1 platform fixture. Rows
  are equivalent only when their candidate revision, fixture ID and version,
  scenario digest, app-build digest, platform/device class, runner/protocol
  versions, host OS/architecture/class, and declared timing mode match. Every
  retry remains attached to its logical execution but does not increase the
  certification sample size.
- Zero runner-attributable failed attempts in the certification cohort. An
  eventual retry pass does not erase or neutralize an earlier runner failure;
  the cohort must be restarted after the defect is fixed on a new candidate
  revision.
- App and infrastructure failures remain in the evidence with classification;
  they are not deleted or converted into passes.
- A 30-day scheduled canary history with at least 99% runner success after
  separately identified external infrastructure incidents.
- No leaked runner-owned child processes in cancellation and timeout tests.
- Every injected bootstrap, driver, action, trace, and report failure produces a
  stable category and artifact bundle.

### Compatibility gates

- Scenario, JSON-RPC, MCP, trace, and client conformance fixtures pass across
  the supported compatibility matrix.
- A previous compatible client can drive the 1.0 server.
- Capabilities expose commands, features, limitations, and deprecations without
  failure probing.
- Upgrade and migration documentation is complete.

### Product gates

- Current competing-runner comparisons on native and React Native fixtures.
- A fair current competing-runner comparison on a React Native fixture.
- Cold-command, warm-session, suite-throughput, memory, and reliability results
  are published with raw sanitized rows and fixture definitions.
- At least three real application pilots covering two framework classes and both
  Tier 1 platforms.
- The agent verification loop succeeds from observation through deterministic
  replay and redacted evidence without hand-editing generated protocol payloads.

## Success Metrics

- Median time from installation to first verified traced flow: under 10 minutes.
- Warm semantic observation p95: target set per platform fixture and enforced by
  benchmark baselines rather than a universal hardcoded number.
- Agent-generated scenario deterministic replay coverage: at least 95% of
  supported successful trace actions, with every skipped action explained.
- Runner-attributable flake rate during certification: 0/300 per Tier 1 fixture.
- Failure-classification coverage: 100% of non-user-cancelled failures.
- Redacted export secret-leak tests: zero known-secret matches across structured
  and free-text artifacts.

## Testing Strategy

- Unit tests for parsers, selectors, action handlers, state machines, redaction,
  scheduling, statistics, and error classification.
- Property/fuzz tests for scenario, RPC, trace, and archive parsing.
- Contract tests generated from the canonical public specification.
- Fake-driver tests for every state transition and injected failure.
- Real Android emulator and iOS simulator canaries on pinned platform matrices.
- Physical-device evidence lanes where hardware is available.
- Long-running soak, cancellation, disk-full, process-crash, stale-state, and
  malformed-driver-response tests.
- Differential benchmark fixtures shared with competitor adapters.

## Rollout and Compatibility

- Continue `0.x` releases while milestone contracts may still change.
- Introduce the canonical registry and compatibility harness before freezing
  method names or payloads.
- Publish one release candidate line (`1.0.0-rc.N`) for design partners.
- Keep importers and migration reports additive during the release-candidate
  period.
- Tag `1.0.0` only from the exact commit that passed the recorded readiness
  evidence; do not rebuild artifacts after approval.

## Key Risks and Mitigations

### Scope expansion

Risk: chasing incumbent feature counts delays reliability and weakens the agent
focus. Mitigation: M3 features require a real pilot or a release-critical
workflow; deferred commands remain discoverable limitations.

### Optional instrumentation complexity

Risk: framework-aware synchronization recreates a competing runner's
compatibility burden. Mitigation: keep black-box operation as the default and
ship synchronization as capability-negotiated adapters with strict version
matrices.

### Hosted-cloud distraction

Risk: building a device cloud consumes the team before the local engine is
stable. Mitigation: define a provider adapter and partner with existing device
farms; defer a hosted control plane.

### Evidence gaming

Risk: retries or discarded infrastructure rows inflate reliability claims.
Mitigation: preserve every attempt, classify it, publish raw sanitized rows, and
report first-attempt and eventual pass rates separately.

### Single-maintainer operations

Risk: release, protocol, and security decisions have a single point of failure.
Mitigation: automate release policy, require reviewed PRs, document response and
deprecation policy, and add maintainers/design partners before stable release.

## First Delivery Slice

Implementation begins with M0, defined in
`2026-07-11-zmr-1-0-m0-trust-baseline-design.md`. No command-parity or version
bump work starts until the repository and evidence pipeline can reliably tell us
whether later changes improve or regress the product.
