# Zeno Release Passport: Product and Technical Design

**Date:** 2026-07-13  
**Status:** Approved by the user on 2026-07-13<br>
**Initial market:** UK digital product agencies shipping mobile and web products  
**Initial surfaces:** Web, iOS, and Android

## 1. Executive summary

Zeno will expand from a first-party mobile test runner into a focused release-acceptance product for agencies.

The product will not attempt to become a universal test runner. Instead, it will turn release scope and evidence from existing tools into one client-ready release record, identify what remains unproven, and record an explicit client decision.

The core promise is:

> Know what changed. Prove what works. Get it approved.

The main product artifact is a **Release Passport**. A Passport binds the following into one versioned record:

- promised scope and acceptance criteria;
- exact web and mobile build identities;
- protected business journeys;
- runtime evidence from Zeno Mobile Runner, Playwright, and generic imports;
- deterministic coverage gaps;
- exclusions and accepted risks;
- selectively disclosed, redacted artifacts; and
- a named client approval or request for changes.

The core workflow is:

> Scope → Verify → Find gaps → Accept

The release, rather than an individual test run, is the unit of value.

## 2. Product position

### 2.1 Category

Zeno is a **client release-acceptance layer** or **release-proof platform**, not a test-management suite, device farm, report host, or deployment-approval system.

### 2.2 Initial customer profile

The initial customer is a UK or EU digital product agency with approximately 5–30 employees that:

- delivers web and iOS/Android applications for paying clients;
- ships client releases at least monthly, ideally multiple times per month;
- uses GitHub and existing CI automation;
- has no large dedicated QA platform team;
- manually assembles screenshots, recordings, CI links, and written summaries;
- experiences approval delays, evidence-preparation work, or release-scope disputes; and
- increasingly uses coding agents embedded in editors, terminals, and hosted workflows.

The economic buyer is normally the founder, technical director, head of delivery, engineering director, or QA lead. Engineers and QA staff prepare evidence. A client product owner or delivery stakeholder reviews the Passport.

### 2.3 Positioning hierarchy

Primary message:

> Zeno maps release scope to mobile and web evidence, flags what remains untested, and gives your client one private page to approve or request changes.

Supporting message:

> Turn your existing tests into a client-approved release record across every surface you ship.

Secondary AI-era message:

> Your coding agent says done. Zeno proves it.

The AI message must remain secondary. Zeno sells faster, safer client handoff and a clearer release decision.

### 2.4 Competitive guardrail

Broad result ingestion, shareable reports, internal approvals, audit trails, redaction, and AI-generated test ideas are already available in established test-management, device-cloud, workflow, and reporting products.

Zeno must therefore compete on the complete external-client workflow:

> Requirement → protected journey → exact build → runtime evidence → disclosed gaps → client decision

No single feature is assumed to be an enduring moat. The defensible advantage is the integrated workflow, Zeno-runner mobile evidence, accumulated mappings between scope and critical journeys, agency-specific templates, and repeatable client release history.

## 3. Goals and non-goals

### 3.1 MVP goals

The MVP must allow one agency to:

1. create a release spanning web and mobile;
2. declare or import release scope;
3. bind the release to exact web, iOS, and Android targets;
4. configure three to five protected business journeys;
5. ingest Zeno Mobile Runner evidence;
6. ingest Playwright evidence;
7. optionally import JUnit or CTRF results;
8. calculate deterministic cross-surface coverage;
9. propose relevant tests for unresolved evidence gaps;
10. resolve, exclude, or accept each material gap;
11. preview and publish a private, redacted Release Passport;
12. receive a verified client approval or request for changes;
13. invalidate approval after a material release change; and
14. repeat the flow for a second release with little or no founder intervention.

### 3.2 Non-goals

The MVP will not include:

- a hosted device or browser farm;
- a proprietary first-party web runner;
- watch, TV, desktop, console, or embedded-device runners;
- a full test-case management suite;
- a defect tracker;
- generic AI test generation unrelated to release scope;
- autonomous approval decisions;
- enterprise compliance certification;
- advanced portfolio analytics;
- complex pricing tiers or per-seat billing;
- extensive Jira, Linear, Teams, or test-tool integrations; or
- claims that a release is bug-free, compliant, or exhaustively tested.

“Any platform” is an evidence-contract and adapter promise, not an initial execution promise.

## 4. Product principles

1. **Evidence is scope-bound.** A green test is meaningful only when connected to a promised behaviour, required surface, and exact build.
2. **Deterministic truth comes first.** Rules calculate status. AI may explain or propose, but cannot mark evidence as verified.
3. **Compatibility is wide; the market is narrow.** The evidence model may accept many sources while the initial customer remains a cross-surface agency.
4. **The customer keeps its runners.** Zeno supplements existing mobile, web, and CI tools instead of requiring a migration.
5. **A client sees decisions, not testing jargon.** Internal detail is available to engineers but translated into business journeys for reviewers.
6. **Published records are immutable.** Material changes create new snapshots rather than rewriting history.
7. **Privacy is visible.** Agencies control which evidence leaves CI and which artifacts clients see.
8. **Every status is explainable.** A user can inspect the rule, evidence, build, and decision that produced a status.
9. **Supporting a source is described honestly.** Zeno distinguishes Zeno-runner evidence, official-adapter evidence, and generic imports without treating producer identity as independent attestation.

## 5. Terminology

| Term | Meaning |
|---|---|
| Agency | The paying Zeno tenant that prepares releases |
| Client | The agency customer receiving the release |
| Project | A client product delivered by the agency |
| Surface | Web, iOS, Android, or a future supported product surface |
| Journey | A stable business flow such as sign-in or guest checkout |
| Protected journey | A critical journey whose verification policy and scenario changes require explicit review |
| Scope item | A requirement or acceptance criterion promised in a release |
| Target build | An exact deployment or mobile artifact being reviewed |
| Target fingerprint | A mandatory canonical digest that binds evidence to one exact surface-specific build identity |
| Evidence run | One normalised execution result from a runner or importer |
| Evidence item | A journey- or test-level result within an evidence run |
| Artifact | A screenshot, recording, trace, log, snapshot, or report |
| Coverage evaluation | The deterministic result for a scope, journey, surface, and target combination |
| Gap | An explainable unresolved absence, failure, mismatch, or policy violation |
| Release Passport | The client-facing record for a frozen release snapshot |
| Passport snapshot | An immutable version of scope, evidence, gaps, risks, and target identities |
| Decision | Approve or Request changes, recorded for a named reviewer |

## 6. System context and repository boundary

### 6.1 Existing runner

Zeno Mobile Runner remains the first-party iOS and Android evidence producer.

The existing scenario runner is already generic over the device passed to it in src/runner.zig. Platform selection and preflight logic are explicitly Android/iOS in src/cli_run.zig and src/run_options.zig. The current trace manifest is schema version 1 in src/trace.zig and is consumed by viewer/parser.js.

The MVP must not refactor the runner into a universal web/mobile execution engine. It must preserve the existing trace contract and adapt it at the evidence boundary.

### 6.2 Repository strategy

Two release boundaries are recommended:

~~~text
zeno-mobile-runner              Open-source
├── iOS/Android execution
├── .zmrtrace bundle
├── platform-neutral evidence schema
├── conformance fixtures
└── evidence export/upload command

zeno-cloud                      Hosted product
├── agency workspace
├── evidence ingestion
├── deterministic gap engine
├── Release Passports
├── external review
└── integrations
~~~

The platform-neutral Evidence Contract should be open and versioned with the runner. Zeno Cloud may remain proprietary.

### 6.3 High-level architecture

~~~mermaid
flowchart LR
    Scope["GitHub or manual release scope"]
    Mobile["Zeno Mobile Runner"]
    Web["Playwright"]
    Generic["JUnit or CTRF"]

    Mobile --> Adapters["Local and CI evidence adapters"]
    Web --> Adapters
    Generic --> Adapters
    Adapters --> Contract["Zeno Evidence Contract"]
    Contract --> Ingestion["Zeno Cloud ingestion"]
    Scope --> Release["Release record"]
    Ingestion --> Release
    Release --> Gaps["Deterministic gap engine"]
    Gaps --> Suggestions["AI-assisted proposals"]
    Gaps --> Passport["Release Passport snapshot"]
    Passport --> Review["Verified client decision"]
~~~

### 6.4 Hosted modules

The hosted MVP should be a TypeScript modular monolith with the following domain modules:

- **Accounts:** agencies, clients, internal members, named reviewers, and tenancy;
- **Projects:** products, surfaces, protected journeys, and policies;
- **Releases:** scope, targets, environments, versions, and lifecycle;
- **Evidence:** ingestion sessions, provenance, normalised results, artifacts, and redaction;
- **Coverage:** deterministic rules, evaluations, gaps, and accepted risks;
- **Reviews:** Passport snapshots, private links, reviewer verification, and decisions;
- **Integrations:** GitHub metadata and Slack notifications; and
- **Audit:** append-only records for material mutations and external decisions.

The implementation should initially use managed PostgreSQL, private object storage, and a durable transactional background-job mechanism. Specific vendors are deferred to implementation planning.

## 7. Core data model

### 7.1 Relationship model

~~~mermaid
flowchart LR
    Agency --> Client
    Client --> Project
    Project --> Journey
    Project --> Release
    Release --> ScopeItem
    Release --> TargetBuild
    TargetBuild --> EvidenceRun
    EvidenceRun --> EvidenceItem
    EvidenceItem --> Artifact
    ScopeItem --> CoverageEvaluation
    Journey --> CoverageEvaluation
    TargetBuild --> CoverageEvaluation
    EvidenceItem --> CoverageEvaluation
    CoverageEvaluation --> Gap
    Release --> PassportSnapshot
    PassportSnapshot --> ReviewDecision
~~~

### 7.2 Required entities

#### Agency

- stable ID;
- display name and agency branding;
- billing state outside the first implementation slice;
- default retention policy;
- members and roles; and
- creation and update timestamps.

#### Project

- stable ID and agency ID;
- client ID;
- name and slug;
- supported surfaces;
- repository references;
- default protected journeys;
- release policy version; and
- active or archived state.

#### Journey

- stable project-scoped ID;
- client-readable name and description;
- criticality;
- owning scope area;
- required surfaces;
- current scenario or policy hash;
- version;
- protected flag; and
- active or retired state.

Journey IDs must remain stable when display names change.

#### Release

- stable ID;
- project ID;
- human-readable version/name;
- source repository and base/head commit identities;
- status;
- scope version;
- active policy version;
- current draft snapshot ID;
- latest published snapshot ID;
- created, prepared, published, decisioned, and superseded timestamps.

#### ScopeItem

- stable release-scoped ID;
- source type: manual, GitHub issue, PR, or release note;
- source reference;
- title and client-readable description;
- acceptance criteria;
- required surfaces;
- linked journeys;
- criticality;
- inclusion state;
- exclusion reason and actor when excluded; and
- source revision identity.

#### TargetBuild

- release ID;
- surface;
- environment;
- mandatory canonical target fingerprint;
- commit SHA;
- deployment ID, build ID, or artifact ID;
- artifact or deployment digest;
- application identifier or URL;
- non-secret environment-configuration digest where required by policy;
- OS/device/browser policy;
- created and registered timestamps; and
- current or superseded state.

Evidence can qualify for the coverage status Verified only when its target fingerprint exactly matches the registered target fingerprint.

The fingerprint is surface-specific:

- **iOS and Android:** application artifact SHA-256, application identifier, version, and build number.
- **Web:** immutable deployment-provider ID, source commit SHA, build-output manifest SHA-256, environment name, and an allowlisted non-secret configuration SHA-256.

The fingerprint input is a surface-specific JSON object using the exact fields above, serialised as UTF-8 with RFC 8785 JSON Canonicalization Scheme and then hashed with SHA-256. The stored value uses lower-case hexadecimal with the sha256: prefix. Missing required fields are errors rather than empty strings. A future fingerprint recipe requires a new recipe version and cannot reinterpret an existing fingerprint.

A mutable URL, commit SHA alone, human build label, or locally generated run ID is insufficient. When the required fingerprint inputs are unavailable, evidence may be retained as context but cannot produce Verified coverage.

The fingerprint establishes identity, not authenticity. It does not prove who executed a runner or that a submitted manifest is truthful.

#### EvidenceRun

- source type and provenance class;
- submitting user or automation identity;
- attestation state;
- adapter and schema versions;
- ingestion ID;
- target build ID;
- runner-specific run ID;
- started and ended timestamps;
- overall outcome;
- manifest digest;
- completeness and redaction state; and
- received and normalised timestamps.

#### EvidenceItem

- evidence run ID;
- stable journey/test identifier;
- scenario hash;
- linked journey and scope references;
- surface and environment;
- outcome;
- retry/attempt metadata;
- failure classification;
- relevant change metadata where available; and
- evidence timestamp.

#### Artifact

- content digest;
- storage key;
- type and MIME type;
- size;
- originating evidence item;
- redaction state;
- disclosure state;
- derived preview reference;
- retention deadline;
- retention state and tombstone metadata; and
- upload verification state.

#### CoverageEvaluation

- release, scope item, journey, surface, and target identifiers;
- calculated status;
- severity;
- qualifying evidence IDs;
- rejected evidence IDs and rejection reasons;
- rule-set version;
- evaluated timestamp; and
- explanation payload.

#### Gap

- stable rule code;
- rule version;
- affected coverage evaluation;
- severity;
- summary and deterministic explanation;
- evidence considered;
- recommended deterministic action;
- lifecycle state;
- resolution type;
- resolving actor;
- resolution justification; and
- resolved timestamp.

#### PassportSnapshot

- release ID and monotonically increasing version;
- immutable serialised scope;
- target identities;
- journey and policy hashes;
- evidence references and digests;
- calculated statuses;
- exclusions and accepted risks;
- disclosed artifact references;
- content hash;
- published actor and timestamp;
- review state; and
- superseding snapshot ID.

#### ReviewDecision

- Passport snapshot ID;
- decision: approve or request_changes;
- named reviewer identity;
- verified email;
- decision comment;
- verification event;
- request metadata appropriate for audit without retaining unnecessary personal data;
- timestamp; and
- idempotency key.

### 7.3 Authorisation and human-control invariants

Internal roles are:

| Role | Allowed material actions |
|---|---|
| Owner | Manage tenant security, members, retention, projects, and all Delivery Lead actions |
| Delivery Lead | Manage scope and targets; approve protected-journey/policy changes; exclude scope; accept risk; publish, revoke, and supersede Passports; appoint reviewers |
| Contributor | Upload and link evidence; draft scope, journeys, tests, and proposed resolutions; cannot exclude, accept risk, publish, or approve policy changes |
| Viewer | Read internal project and release information |
| Automation identity | Ingest evidence and report processing state only; cannot change scope/policy, resolve risk, publish, or decide |
| External reviewer | View an assigned Passport and record Approve or Request changes after email verification |

Only an Owner or Delivery Lead may exclude scope, accept risk, publish a Passport, or approve a protected-journey/policy change. An external reviewer acknowledges disclosed risks by approving the snapshot but cannot create an internal exclusion or risk acceptance.

Protected-journey and release-policy changes never become active merely because an automation identity or coding agent submitted them. A human Owner or Delivery Lead must record an explicit approval after the most recent change. Until then, affected evidence is Stale or Unverified according to the deterministic rule.

The MVP separates automation from human authority but does not require two distinct human approvers, because the initial agencies may have very small delivery teams. A future project policy may require human author and approver separation. All privileged actions are enforced server-side and included in the snapshot/audit history.

### 7.4 Append-only, retention, and immutability rules

- Evidence runs and published Passport snapshots are append-only.
- A normalisation correction creates a replacement evidence version and preserves the original.
- A published snapshot cannot be edited.
- A material release change creates a new draft snapshot.
- Previous approvals remain associated with the exact snapshot reviewed.
- Decisions are never moved from one snapshot to another.
- Audit events record material changes, risk acceptance, exclusions, publishing, verification, decisions, revocation, and supersession.
- Snapshot canonical content includes artifact digests and disclosure metadata, not a guarantee that artifact bytes are retained forever.
- Retention deletion removes stored artifact bytes but leaves an immutable tombstone containing the digest, original type, deletion timestamp, retention-policy version, and deletion reason.
- Artifact deletion never recalculates or mutates the snapshot content hash.
- Historical views show that an artifact expired under retention policy rather than pretending it remains downloadable.
- Where privacy law or tenant policy requires removal of reviewer personal data, identity fields may be irreversibly pseudonymised while preserving the decision type, snapshot, role, verification fact, and timestamp.

## 8. Evidence Contract

### 8.1 Purpose

The Evidence Contract normalises source-specific execution output without pretending that producer format establishes independent authenticity.

The contract must:

- be versioned independently of runner internals;
- use stable identifiers;
- support unknown future surfaces and artifact types;
- allow manifests without all optional artifacts;
- carry exact provenance and build identity;
- permit local redaction and omission;
- use content digests for uploaded files;
- preserve source-specific extensions under a namespaced field; and
- reject ambiguous status or identity values.

### 8.2 Provenance classes and attestation

| Provenance class | Meaning | May contribute to Verified coverage? |
|---|---|---|
| Zeno runner | Normalised from a valid Zeno Mobile Runner bundle submitted by an authorised tenant user or CI identity | Yes, subject to exact target match and project policy |
| Official adapter | Produced through a supported Zeno adapter such as Playwright and submitted by an authorised identity | Yes, subject to exact target match and project policy |
| Imported | Normalised generic or third-party result with weaker semantics | No; it may support investigation, while a human may separately resolve the resulting gap as Accepted risk |

Provenance class describes the processing path. It does not describe test outcome and does not independently prove that the claimed execution occurred.

The MVP records a separate attestation state:

- **Unattested:** authorised tenant or CI submission with validated schema and digests, but no independently verified execution signature;
- **CI-attested:** optional future state in which a supported CI identity signs build and execution claims; and
- **Signature-verified:** optional future state in which Zeno validates a supported producer signature.

Only Unattested is required for the MVP. User-facing copy must say “Zeno runner evidence” or “official adapter evidence,” never “independently verified execution,” unless a supported attestation was actually validated. Coverage status Verified means the stored evidence satisfies the project policy for the exact target; it is not a third-party audit opinion.

### 8.3 Conceptual manifest

~~~json
{
  "schemaVersion": "1.0",
  "producer": {
    "name": "zeno-mobile-runner",
    "version": "0.x",
    "adapterVersion": "1.x",
    "provenanceClass": "zeno_runner",
    "attestationState": "unattested"
  },
  "release": {
    "externalId": "agency-release-id",
    "commitSha": "full-sha"
  },
  "target": {
    "surface": "android",
    "environment": "staging",
    "buildId": "284",
    "artifactDigest": "sha256:...",
    "targetFingerprint": "sha256:...",
    "device": "Pixel 9",
    "os": "Android 16"
  },
  "run": {
    "externalId": "run-id",
    "startedAt": "RFC3339 timestamp",
    "endedAt": "RFC3339 timestamp",
    "outcome": "passed"
  },
  "items": [
    {
      "externalId": "guest-checkout",
      "journeyId": "checkout.guest",
      "scenarioHash": "sha256:...",
      "outcome": "passed",
      "artifacts": [
        {
          "path": "artifacts/final.png",
          "digest": "sha256:...",
          "redactionState": "reviewed"
        }
      ]
    }
  ]
}
~~~

### 8.4 Existing Zeno trace adaptation

The existing .zmrtrace archive remains a valid source artifact. A Zeno adapter will:

1. parse trace.json, events.jsonl, and the artifacts directory;
2. validate the existing schema and terminal outcome;
3. accept release and target identity from CI arguments or environment metadata;
4. calculate the scenario and artifact digests;
5. map the result to a stable project journey;
6. apply or confirm redaction;
7. generate the Evidence Manifest; and
8. optionally upload the selected bundle and artifacts.

The trace schema should not be expanded with hosted-product concerns unless the runner independently needs the fields.

### 8.5 Playwright adaptation

The first official web adapter will consume supported Playwright reporter output and available traces/screenshots/videos. It must require or derive:

- project and release identity;
- exact web deployment or commit identity;
- browser/environment metadata;
- stable journey or test identifiers;
- attempt and retry data;
- execution outcomes;
- relevant artifact digests; and
- explicit disclosure/redaction state.

Playwright remains the execution engine.

### 8.6 Generic import

JUnit or CTRF import provides compatibility for other tools. Generic imports:

- receive the Imported provenance class by default;
- must preserve their source format and importer version;
- must not silently infer a missing target fingerprint;
- may contribute context and failure evidence;
- cannot produce Verified coverage for protected release scope; an Owner or Delivery Lead may instead resolve the resulting gap as Accepted risk when policy permits; and
- must display the weaker provenance in both internal and client views where relevant.

## 9. Coverage and Evidence Gap Engine

### 9.1 Coverage cell

The atomic coverage question is:

> Is this scope item and protected journey proven on this required surface for this exact target build under the active release policy?

Each required combination receives exactly one calculated status:

| Status | Definition |
|---|---|
| Verified | Policy-qualifying passing evidence exists for the exact target fingerprint and active scenario/policy |
| Failed | Relevant qualifying evidence ran and failed |
| Stale | Relevant evidence exists but belongs to an older target, scenario, or policy |
| Unverified | No qualifying evidence exists |
| Excluded | An Owner or Delivery Lead intentionally removed the requirement with a reason |
| Accepted risk | An Owner or Delivery Lead explicitly accepted the unresolved condition |

Excluded and Accepted risk are human resolutions layered over the underlying deterministic condition. The original condition must remain visible.

Verified is a coverage result, not a provenance or attestation label.

### 9.2 Severity

Severity is independent of status:

- **Blocking:** review or approval is prohibited unless explicitly accepted by policy;
- **Warning:** approval is allowed only with visible acknowledgement; and
- **Informational:** contextual difference with no approval impact.

Project policies map criticality and rule codes to severity.

### 9.3 Deterministic evaluation order

The engine evaluates in this order:

1. **Target identity:** reject evidence whose mandatory surface-specific fingerprint is missing or does not exactly match the reviewed build.
2. **Schema and provenance:** reject unsupported, invalid, or disallowed sources.
3. **Freshness:** compare commit/build, scenario hash, journey version, policy version, and evidence time.
4. **Scope linkage:** confirm every included criterion has an approved verification route.
5. **Surface coverage:** independently evaluate every required surface.
6. **Execution outcome:** interpret passed, failed, skipped, retry, partial, and flaky results according to policy.
7. **Environment policy:** verify required device, OS, browser, and environment coverage.
8. **Artifact policy:** confirm required proof types and acceptable redaction/disclosure state.
9. **Resolution:** apply authorised exclusions or risk acceptances while preserving the original gap.

The output must be reproducible from stored inputs and a versioned rule set.

### 9.4 Initial rule families

The MVP should support at least:

- missing target identity;
- unsupported evidence schema;
- disallowed provenance or attestation state;
- evidence from a superseded build;
- scenario or policy mismatch;
- acceptance criterion with no linked journey or verification method;
- required surface without evidence;
- required journey without execution;
- required environment/device/browser without evidence;
- failed critical journey;
- skipped critical journey;
- flaky or retry-only success where policy disallows it;
- required artifact missing;
- artifact redaction not reviewed;
- evidence incomplete or quarantined; and
- unresolved blocking gap.

### 9.5 Gap record requirements

Every gap must expose:

- stable rule code and version;
- plain-language summary;
- affected requirement, journey, surface, and target;
- severity;
- deterministic reason;
- evidence considered and why it did or did not qualify;
- recommended next action;
- resolution options allowed by policy; and
- relevant audit history.

### 9.6 AI proposals

AI runs after deterministic evaluation and may:

- explain a gap in simpler language;
- correlate a code or scope change with a protected journey;
- recommend the most useful next verification;
- draft a Zeno Mobile Runner scenario;
- draft a Playwright test;
- identify assumptions and confidence; or
- suggest that a human clarify scope.

Each proposal must include:

- the behaviour considered missing;
- the release-specific reason;
- the proposed surface and environment;
- the expected evidence if the test passes;
- assumptions;
- confidence; and
- a link to the deterministic gap that prompted it.

AI must never:

- change a coverage status;
- mark a proposal as executed;
- accept risk;
- exclude scope;
- alter a protected journey without review;
- approve a release; or
- hide the deterministic reason.

If AI is unavailable, the full deterministic workflow must continue to work.

## 10. Release and approval lifecycle

### 10.1 Release states

~~~text
Draft
  → Collecting evidence
  → Needs attention or Ready for review
  → In client review
  → Approved or Changes requested
  → Superseded
~~~

- **Draft:** scope and targets are incomplete or still changing.
- **Collecting evidence:** the release is sufficiently identified and accepts evidence.
- **Needs attention:** blocking gaps remain.
- **Ready for review:** policy requirements are satisfied or visibly resolved.
- **In client review:** an immutable Passport snapshot has been published.
- **Approved:** a verified reviewer approved that snapshot.
- **Changes requested:** a verified reviewer requested changes to that snapshot.
- **Superseded:** a newer snapshot or release version has replaced the reviewed record.

### 10.2 Publishing

Before publishing, the agency must see an exact client-facing preview containing:

- included scope and exclusions;
- exact target identities;
- proof by business journey and surface;
- visible remaining risks;
- evidence provenance;
- selected disclosed artifacts;
- reviewer identity;
- link expiry; and
- the effect of future material changes.

Publishing creates an immutable Passport snapshot with a canonical content hash.

### 10.3 Client access

- Viewing uses an unguessable, revocable, expiring private link.
- Passport pages are never indexed.
- The viewer needs no Zeno account.
- Approve and Request changes require a one-time code sent to the named reviewer email.
- A decision endpoint must be idempotent.
- An expired, revoked, or superseded snapshot cannot receive a new valid decision.
- The agency may issue a replacement link without changing snapshot content.

### 10.4 Material invalidation

The current approval becomes historical and a new pending snapshot is required when any of the following changes:

- registered target fingerprint for any surface;
- included release scope;
- required surface;
- protected journey or scenario hash;
- active release policy;
- qualifying evidence used for verification;
- exclusion;
- accepted-risk decision; or
- disclosed evidence in a way that changes the reviewed substance.

Comments, link expiry, reviewer notification settings, and cosmetic wording that does not alter scope or risk do not invalidate approval.

Artifact-byte deletion under an already disclosed retention policy does not invalidate or mutate the snapshot. The historical view replaces availability with the tombstone defined in section 7.4.

The old snapshot and decision remain permanently associated.

## 11. User experience

### 11.1 Interface intent

The internal application is for a technical or delivery lead who has just finished assembling a release and needs to find the remaining risk quickly. The client interface is for a stakeholder who needs to understand the release and make one decision without learning a testing tool.

The experience should feel like a calm release workbench: minimal, decisive, technically credible, and slightly playful in microcopy rather than evidence semantics.

### 11.2 Domain and visual direction

- **Domain:** passports, proof trails, protected journeys, coverage, stamps, handoffs, and decisions.
- **Colour world:** evidence-paper ivory, terminal graphite, verification green, warning amber, failure coral, and blueprint blue.
- **Signature:** the **Proofline**, a compact chain showing scope, builds, surfaces, gaps, and decision state.
- **Rejected defaults:** KPI-card dashboards, rainbow status badges, dense test-case grids, and a chatbot as the primary gap interface.

Example:

~~~text
Scope ✓ ─ Build ✓ ─ Web ✓ ─ iOS ✓ ─ Android ! ─ Approval locked
~~~

### 11.3 Internal views

#### Releases

The home view is a release list ordered by attention required. Each row shows:

- client/project;
- release name;
- strongest unresolved state;
- client decision state;
- last activity; and
- one contextual action.

The primary action is New release. Analytics are secondary.

#### Release setup

The setup flow contains:

1. project and release identity;
2. GitHub or manual scope;
3. web, iOS, and Android targets;
4. protected journeys;
5. evidence connection/upload; and
6. detected gaps.

#### Release workspace

The focal element is a journey-by-surface matrix. Selecting a cell reveals the qualifying and rejected evidence, target identity, artifacts, timestamps, and rule explanation.

The main action is Resolve gaps or Prepare client review, depending on state.

#### Gap review

Gaps appear as a prioritised decision queue. Each item shows:

- what remains unproven;
- why it matters;
- the deterministic rule;
- evidence considered;
- an optional AI-assisted proposal; and
- allowed actions such as run test, attach evidence, exclude, or accept risk.

AI suggestions are inline, not a detached chatbot.

#### Review preview

The agency previews exactly what the client will see and explicitly selects disclosed artifacts. Redaction uncertainty blocks publishing.

### 11.4 Client Passport

The client-facing order is:

1. what is being approved;
2. what changed;
3. what was verified;
4. known limitations, exclusions, and accepted risks;
5. evidence organised by business journey; and
6. Approve or Request changes.

The page uses client-readable behaviour language instead of raw assertion or suite counts. The decision bar remains prominent.

The Passport must be responsive and accessible on mobile. The internal agency workspace may be desktop-first while remaining functional on tablet.

### 11.5 Interface states

Every interactive view must define loading, empty, success, partial, error, expired, revoked, and permission-denied states.

Examples:

- no blocking gaps: “Nothing hiding here. This release is ready for client review.”
- expired review link: agency-branded expiry page with a safe request-new-link path;
- integration delay: retain previous valid evidence and display queued status;
- AI unavailable: preserve deterministic output and show suggestions as temporarily unavailable.

## 12. Ingestion and processing

### 12.1 Ingestion sequence

1. Agency creates the release and target builds.
2. A local or CI adapter reads supported runner output.
3. The adapter validates local files, computes content digests, and constructs the mandatory surface-specific target fingerprint.
4. The adapter creates an Evidence Manifest containing that fingerprint and the submitting identity context.
5. Zeno Cloud validates the schema, provenance class, fingerprint shape, and release-target match before creating an ingestion session.
6. Cloud issues short-lived upload locations only for permitted artifacts.
7. The adapter uploads redacted/selected artifacts directly to private storage.
8. The adapter finalises the ingestion using an idempotency key.
9. A worker verifies object digests and completeness.
10. A normaliser creates evidence runs/items.
11. The deterministic engine recalculates affected coverage cells.
12. The UI receives the resulting statuses, gaps, and processing audit.

### 12.2 Idempotency

- Manifest digest plus tenant/project identity is the primary duplicate signal.
- Repeating a completed upload returns the existing evidence run.
- Retrying an incomplete session resumes missing objects.
- A finalisation call is safe to replay.
- A decision request uses a unique idempotency key and cannot create duplicate decisions.

### 12.3 Failure handling

| Failure | Required behaviour |
|---|---|
| Malformed manifest | Reject before upload and return precise field errors |
| Unsupported schema | Quarantine; show supported versions and upgrade guidance |
| Missing or mismatched target fingerprint | Store as non-qualifying context when safe; do not verify scope |
| Digest mismatch | Quarantine affected artifact and evidence item |
| Partial upload | Preserve session for retry; do not evaluate incomplete evidence |
| Duplicate upload | Return existing evidence result |
| Source integration outage | Queue retry and retain previous valid evidence |
| Normalisation failure | Quarantine source payload; no coverage mutation |
| Gap evaluation failure | Retain previous evaluation, mark it stale, and alert operators |
| AI failure | Omit proposal; deterministic gaps remain available |
| Redaction uncertainty | Keep artifact private and block disclosure |
| New build after review | Preserve old snapshot; create new pending release state |
| Expired/revoked review link | Deny review and offer safe agency contact/reissue path |

Silent fallback is prohibited for target identity, provenance, attestation, status, redaction, or approval.

## 13. Security, privacy, and trust

### 13.1 Required MVP controls

- strict tenant and project isolation;
- server-side authorisation for every object and mutation;
- encryption in transit and at rest;
- private object storage;
- short-lived signed artifact URLs;
- local redaction before upload where possible;
- server-side validation of redaction metadata;
- explicit artifact disclosure selection;
- expiring and revocable review links;
- named reviewer verification before decisions;
- rate limiting on authentication, upload, review, and decision operations;
- secret and token filtering;
- append-only decision/audit storage;
- configurable artifact retention and tombstone-preserving deletion;
- no public indexing or predictable Passport identifiers;
- Content Security Policy and safe content-disposition headers;
- malicious archive and path-traversal protection;
- file type, size, and decompression limits; and
- structured security events without sensitive artifact content.

### 13.2 Disclosure model

- Raw trace archives remain private by default.
- A Passport discloses only explicitly selected derived previews and artifacts.
- Redacted and original artifacts, if both retained, use separate storage references and permissions.
- A retained snapshot whose artifact bytes were deleted shows an immutable expiry tombstone; it never silently removes the artifact reference or recalculates the snapshot hash.
- Clients cannot enumerate other project or agency resources.
- Revoking a review link removes access immediately without changing snapshot history.

### 13.3 Claims

Initial messaging may describe a Passport as an auditable, versioned release record. It must not claim formal compliance, legal non-repudiation, independently attested execution, or exhaustive assurance without the corresponding controls and independent review. In the MVP, evidence is submitted by an authorised agency user or CI identity and remains self-reported even when its schema, target fingerprint, and uploaded digests validate.

## 14. Integrations

### 14.1 GitHub

The first scope integration should support:

- repository connection;
- PR and issue references;
- release/base/head commit identities;
- source revision tracking;
- webhook updates;
- link back to the Release Passport;
- optional check/status summary; and
- least-privilege installation permissions.

GitHub metadata assists scope and freshness evaluation but does not replace runtime evidence.

### 14.2 Slack

The first notification integration may send:

- evidence ingestion completed or failed;
- blocking gaps detected;
- Passport ready for review;
- client requested changes;
- client approved; and
- approval invalidated by a material change.

Slack is a notification channel, not the system of record.

### 14.3 Deferred integrations

Issue trackers, team chat, mobile test frameworks, browser tools, test-management systems, and additional reporters should be added only after repeated paying-customer demand. A useful threshold is three paying customers requesting an integration and at least one willing to prepay or participate in a design partnership.

## 15. Observability and product analytics

### 15.1 Operational signals

Track:

- ingestion duration and failure rate by source/schema;
- normalisation and digest-verification failures;
- gap-evaluation duration and rule errors;
- quarantined evidence;
- review-link verification failures;
- decision idempotency conflicts;
- approval invalidations;
- worker lag; and
- storage and retention jobs.

No operational log should contain raw secrets, tokens, screenshots, or full artifact payloads.

### 15.2 Product signals

The north-star metric is:

> Client-decisioned Release Passports per active client project per month.

Activation events:

- project created;
- first protected journey configured;
- first mobile evidence ingested;
- first web evidence ingested;
- first gap resolved;
- first Passport published;
- external reviewer opened Passport;
- first client decision; and
- second Passport published.

Key targets for paid pilots:

- evidence connected within two business days;
- first Passport within seven days;
- reviewer opens within 48 hours;
- client decision within five days;
- agency preparation below 15 minutes per repeat release;
- second Passport within 45 days; and
- founder intervention below 30 minutes for the second release.

## 16. Verification strategy

### 16.1 Evidence-contract conformance

Maintain versioned fixtures for:

- valid Zeno traces;
- failed and partial Zeno traces;
- valid Playwright result sets;
- retries and flaky Playwright runs;
- JUnit and CTRF imports;
- missing target identities;
- unknown schema versions;
- malformed manifests;
- malicious archive paths;
- mismatched digests;
- missing optional artifacts;
- redacted artifacts; and
- deliberately omitted screenshots.

Every official adapter must pass the same conformance suite.

### 16.2 Gap-rule tests

Each deterministic rule must be represented as a versioned table of:

- inputs;
- active policy;
- qualifying and rejected evidence;
- expected status;
- expected severity;
- expected rule code; and
- expected explanation.

Essential cases:

1. Web, iOS, and Android are evaluated independently.
2. A new web deployment makes only relevant web evidence stale.
3. A new Android build does not invalidate unrelated web evidence.
4. A protected scenario change invalidates affected evidence.
5. Missing or mismatched target fingerprint cannot verify scope.
6. Imported evidence follows project provenance and human-resolution policy.
7. Failed critical journeys block review.
8. Retry-only success follows flake policy.
9. Exclusion requires a reason and an Owner or Delivery Lead.
10. Risk acceptance retains the original unresolved condition.
11. AI availability never changes deterministic status.
12. Re-evaluation with identical inputs produces identical output.

### 16.3 Lifecycle and security tests

Verify:

- published snapshots cannot be edited;
- material changes create a new pending snapshot;
- old approvals remain accessible;
- decisions cannot be copied between snapshots;
- expired, revoked, or superseded snapshots reject decisions;
- decision requests are idempotent;
- review tokens are unguessable and scoped;
- reviewer verification cannot be replayed;
- cross-agency access is denied;
- direct object URLs expire;
- hidden artifacts never appear in Passport payloads;
- automation identities cannot exclude scope, accept risk, approve protected changes, publish, or decide;
- privileged actions require the roles defined in section 7.3;
- deletion/retention jobs preserve immutable digests, tombstones, and snapshot hashes; and
- audit records exist for all material transitions.

### 16.4 End-to-end acceptance journey

The MVP is not complete until an automated or reliably repeatable test demonstrates:

1. create an agency project;
2. configure web, iOS, and Android plus protected journeys;
3. create a release and import GitHub scope;
4. register exact target builds;
5. ingest Zeno mobile evidence;
6. ingest Playwright web evidence;
7. detect a deliberately missing Android journey;
8. show a scoped AI proposal without changing deterministic status;
9. attach new evidence or accept the risk;
10. preview disclosure and redaction;
11. publish a Passport;
12. verify an external reviewer;
13. record Request changes;
14. register a replacement build and evidence;
15. publish a new immutable snapshot;
16. record approval; and
17. prove that a subsequent material change creates a new pending state while preserving the approved snapshot.

The Zeno Cloud web application should use Playwright for its own browser-level acceptance tests. Zeno Mobile Runner retains its existing unit, integration, trace, bundle, redaction, and device-path verification.

## 17. MVP commercial validation

The product must be validated with real paid releases before widening platform scope.

Suggested pilot:

**Release Proof Pilot — £1,250 plus VAT upfront**

- one agency;
- one live client project;
- at least two surfaces;
- three to five critical journeys;
- existing Zeno, Playwright, or JUnit evidence;
- one branded private Release Passport;
- one external client decision; and
- one repeat release within 30 days.

Suggested founding subscription after the pilot:

**Founding Agency — approximately £249 per month**

- up to five active client projects;
- practical monthly Passport allowance;
- unlimited internal users and external reviewers;
- agency branding;
- private expiring links;
- release history; and
- GitHub integration.

Pricing remains a hypothesis until paid validation.

Continue when:

- at least two qualified agencies pay for pilots;
- at least two of three pilots produce real external decisions;
- customers publish a second Passport within 45 days;
- onboarding can fall below eight founder hours;
- repeat support can fall below one hour per customer per month; and
- buyers accept approximately the proposed recurring price.

Stop or reposition when:

- zero of five qualified buyers pays at least £750;
- client reviewers do not use the decision workflow;
- buyers value only inexpensive report hosting;
- most prospects actually need a device farm or managed QA service;
- each customer requires bespoke integrations; or
- repeat usage does not occur.

## 18. MVP acceptance criteria

The first sellable version is accepted only when all of the following are true:

- a release can contain web and at least one mobile surface;
- Zeno and Playwright evidence are ingested through versioned adapters;
- exact target identity is required for Verified status;
- three to five protected journeys can be mapped to release scope;
- the required initial gap-rule families are implemented and explainable;
- an AI proposal can be generated for a scoped gap without altering status;
- the agency can resolve, exclude, or accept gaps according to policy;
- disclosure and redaction can be previewed before publishing;
- a private immutable Passport can be published;
- a named external reviewer can approve or request changes;
- material changes require a new snapshot;
- historical snapshots and decisions remain accessible;
- tenant isolation and artifact privacy tests pass;
- the complete end-to-end acceptance journey passes; and
- a second release can be prepared without manual database or operator intervention.

## 19. Deferred implementation choices

The following are intentionally deferred to the implementation plan:

- hosted application repository name and visibility;
- managed PostgreSQL/auth/storage provider;
- durable job mechanism;
- transactional email provider;
- AI model/provider and prompt implementation;
- exact API routes and transport;
- exact UI framework and component primitives;
- billing provider;
- UK/EU deployment region sequence;
- artifact size and retention limits; and
- whether GitHub check publication is included in the first or second delivery slice.

These choices must preserve the approved domain invariants and MVP boundary.

## 20. Approved decision summary

The approved direction is:

- start with web, iOS, and Android;
- keep Zeno Mobile Runner as the first-party mobile engine;
- use Playwright rather than build a proprietary web runner;
- normalise other evidence through JUnit/CTRF;
- make the Release Passport the primary product;
- make deterministic release-specific gaps the central differentiator;
- allow AI to propose tests but never assert proof;
- target small cross-surface agencies and external client handoff;
- preserve immutable snapshot and decision history;
- build a focused modular monolith;
- validate with paid pilots before expanding platforms; and
- defer watches, TV, desktop, device farms, and full test management.
