# On-Device AI Feature Evals — Design Doc

Status: proposal, pre-build. Parked per the ideas list until the runner's
demand test completes (mid-August 2026). Written now so the build window opens
with a settled design.

## Problem

Mobile apps are shipping LLM and on-device-model features — summaries, smart
replies, classifiers, generated UI copy — with no regression harness. Outputs
are non-deterministic, so the classic `assertVisible` step cannot judge them.
Teams eyeball the feature once and hope the next model or app update does not
change it.

## Idea

The runner already drives the screen and captures semantic snapshots and
evidence. Add an eval layer on top: versioned scenario packs that exercise AI
features, a scoring layer that judges non-deterministic output across repeated
runs, and a regression gate that compares scores across app and model
versions.

## Building blocks that already exist

- `schemas/scenario.schema.json` — steps including `snapshot`, `typeText`,
  `assertVisible`, `waitVisible`
- `schemas/semantic-snapshot.schema.json` — the structured screen capture the
  scorers read
- `schemas/evidence-v1.schema.json` and `docs/evidence-contract.md` — the
  artifact contract an eval report joins
- ADR 0004 (`docs/adr/0004-benchmark-claims-and-baseline-collection.md`) — the
  baseline-collection discipline the regression gate reuses

## Design

### 1. Scenario pack v2 — `expect` blocks

Extend the scenario schema with an optional expectation block on any step:

```yaml
- action: tap
  selector: { id: "summarise" }
  expect:
    ai:
      mustContain: ["order", "total"]
      mustNotContain: ["lorem", "TODO"]
      maxLatencyMs: 4000
      rubric: "summary states the correct total and mentions the delayed item"
```

Deterministic checks (`mustContain`, `mustNotContain`, `maxLatencyMs`) run
locally with no judge. Rubric checks go to the judge layer.

### 2. Judge layer — pluggable scorers

- **Heuristic scorer (v1):** deterministic checks over the semantic snapshot —
  presence, length bounds, format, banned strings, latency.
- **Similarity scorer (v1):** embedding distance against versioned golden
  outputs, thresholded. Tolerates phrasing drift, catches semantic drift.
- **Rubric scorer (v2):** model-graded against a versioned rubric.
  Provider-agnostic, behind a config flag, never required for local runs.

### 3. Repetition model

Non-deterministic output needs N runs per scenario. Report `pass@k` and
`pass^k` per scenario plus latency percentiles, using the baseline-collection
rules from ADR 0004 for what may be claimed publicly.

### 4. Score manifest

New versioned artifact: `eval-report.schema.json`. Per-scenario scores,
aggregates by dimension (correctness, format, refusal behaviour, latency), and
an environment fingerprint (device, OS, app version, model version). The
regression gate diffs two manifests and fails when any dimension drops past a
configured threshold.

### 5. CI integration

`zmr eval run pack.yaml --baseline previous.json --gate` exits non-zero on
regression. The evidence contract gains an `eval` artifact type so a report
travels with the rest of the run evidence.

### 6. Fixtures and goldens

Golden outputs live in the repo like the existing protocol fixtures. Refresh
is an explicit command and a review event — same discipline as snapshot
testing: a golden update without a stated reason is a red flag in review.

## What it deliberately is not

- Not a generic LLM benchmark suite. It judges *features in apps*, on devices.
- Not pixel-diffing. Visual change detection is the semantic trace diff's job
  (the parked `zmr diff` idea), and the two share the snapshot format.
- Not a cloud service. Local-first like the runner; scorers that need a model
  run against whatever the operator configures, including fully local ones.

## Milestones (only if the demand test justifies them)

- M1: `expect` blocks + heuristic scorer + N-run repetition
- M2: score manifest + regression gate
- M3: similarity scorer + golden workflow
- M4: rubric scorer (provider-agnostic)

## Open questions

1. Do AI-feature scenarios need record/replay network mocking so evals stay
   comparable across runs, or is the whole point that the live feature is
   exercised?
2. What N is affordable on-device before CI time becomes the objection?
3. Does the score manifest extend `evidence-v1` or stand alone as a new
   versioned schema?
