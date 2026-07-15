# Zeno Cloud Beta: Sellable Vertical Slice Design

**Date:** 2026-07-15  
**Status:** Approved in conversation on 2026-07-15  
**Delivery constraint:** 8–12 weeks, part-time  
**Commercial constraint:** Working beta before cold outreach  
**Initial market:** UK digital product agencies shipping web and mobile products

## 1. Purpose

This document narrows the approved
[Zeno Release Passport design](./2026-07-13-zeno-release-passport-design.md)
into the smallest hosted beta that can support a real paid pilot.

The open-source runner now provides the local Evidence Contract, Zeno Mobile
Runner adapter, Playwright reporter, package validation, target fingerprints,
and conformance fixtures. The next product risk is not another runner feature.
It is whether an agency will use combined release evidence to obtain an explicit
client decision.

The beta therefore implements one complete value path:

> Create release → connect mobile and web proof → expose gaps → publish a
> private Release Passport → receive a verified client decision

The beta is deliberately narrow. Manual setup is acceptable where it does not
break the customer-facing workflow. The hosted product must nevertheless be
secure, tenant-safe, durable, and usable without manual database intervention.

### 1.1 Relationship to the parent design

The parent design remains authoritative for product trust and security
invariants. This document deliberately narrows its delivery scope for the beta:
manual scope replaces GitHub import, while JUnit/CTRF, Slack, billing, and
self-service team administration are deferred. These are beta deferrals, not
changes to the eventual MVP direction.

The status vocabulary, provenance rules, immutable-history rules, and
scope-bound coverage identity remain aligned with the parent design. Section 19
defines acceptance of this hosted beta slice; it does not claim that every item
in the parent design's broader MVP acceptance criteria has shipped.

## 2. Product promise and success condition

The beta promise is:

> Turn one web-and-mobile release into a private, client-approvable record,
> with untested gaps made explicit.

The beta succeeds when a small agency can:

1. create a client project and release;
2. define three to five protected customer journeys;
3. register exact web, iOS, and Android release targets;
4. submit ZMR mobile and Playwright web evidence;
5. understand every Verified, Failed, Stale, or Unverified cell and its exact
   gap reason, including missing or target-mismatched evidence;
6. receive a scoped proposed test for a genuine gap;
7. resolve the gap with evidence, exclusion, or explicit risk acceptance;
8. publish an immutable private Passport;
9. obtain an email-verified Approve or Request changes decision; and
10. repeat the process for a changed build without corrupting the first
    snapshot or its decision.

The first commercial target remains a paid Release Proof Pilot. Pricing is a
hypothesis, not a product invariant: £750–£1,250 for the first pilot and roughly
£249 per month for a later founding-agency subscription.

## 3. Users and authority

### 3.1 Internal users

The beta supports these internal roles:

- **Owner:** tenant administration plus every Delivery Lead action.
- **Delivery Lead:** manages releases, scope, targets, journey policy, gap
  resolutions, Passport publishing, review links, and revocation.
- **Contributor:** uploads and links evidence and may draft scope or test
  proposals. A Contributor cannot exclude scope, accept risk, publish, or
  decide.

Self-service invitations and advanced team management are deferred. Beta users
may be provisioned through a controlled operator flow, but normal sign-in and
role enforcement must work in the application.

### 3.2 External reviewer

An external reviewer has no Zeno account and no tenant-wide session. A reviewer
can:

- open one assigned Passport through an unguessable private link;
- view only the snapshot and artifacts selected for disclosure;
- verify the assigned email address with a one-time code; and
- record at most one Approve or Request changes decision for that reviewer
  assignment and snapshot, with safe retry of the same idempotent request.

The reviewer cannot browse projects, releases, evidence, other snapshots, or
other reviewers.

### 3.3 Automation identity

An automation credential is scoped to one agency, project, and release. It may
create or resume evidence ingestions only. It cannot mutate release scope,
change targets, resolve gaps, publish a Passport, issue review links, or decide.

The self-reported project and submitter fields inside `evidence.json` are never
used as authorization credentials. The authenticated upload context is
authoritative and must be compared with the manifest claims.

## 4. Included product journey

### 4.1 Release preparation

1. The user signs in and selects an agency.
2. The user creates a client and project.
3. The user creates a release with a human-readable name, release identifier,
   source commit, and environment.
4. The user enters concise release scope and acceptance criteria manually.
5. The user links every included scope item to at least one protected journey
   and selects the required surfaces for that route. An unmapped included item
   remains an explicit blocking gap.
6. The user configures three to five stable customer journeys, their required
   surfaces, criticality, and current scenario hash.
7. The release pins the system-controlled `beta-1` release policy version.
8. The user registers one active target build per required surface.
9. Zeno shows source-specific commands for generating and uploading evidence.

GitHub scope import is deferred. Manual scope is sufficient for the beta, but
the model retains source type and source reference fields so GitHub can be added
without redefining scope identity.

### 4.2 Evidence connection

The open-source package currently exposes `zmr-evidence from-zmr` and
`zmr-evidence validate`; it does not expose an upload command. The beta adds:

```text
zmr-evidence upload <package-directory> \
  --endpoint <zeno-cloud-origin> \
  --release <release-id>
```

The credential is read from `ZENO_INGEST_TOKEN`. It must not be accepted as a
normal command-line value because process lists, shell history, and CI logs can
expose arguments.

The command:

1. validates the local package before network access;
2. submits the canonical manifest digest and metadata;
3. receives an idempotent ingestion session and the list of missing artifacts;
4. uploads only requested artifact bytes to short-lived signed locations;
5. finalizes the session;
6. prints one compact JSON result containing stable status and safe next steps;
7. never prints the token, signed upload URLs, raw evidence, or local absolute
   paths; and
8. resumes an incomplete session when the same package is retried.

ZMR and Playwright both use the same upload command after producing an Evidence
Contract package. Direct reporter-to-cloud upload, generic JUnit/CTRF import,
and browser-based archive upload are deferred.

### 4.3 Gap resolution and publication

The release workspace presents a journey-by-surface coverage matrix. The atomic
records remain scope-item × journey × surface evaluations. A visible matrix
cell summarizes all included scope items linked to that journey and surface;
it is Verified only when every underlying evaluation is Verified. Otherwise it
shows the highest-severity unresolved condition, or Resolved with risk/exclusion
when no unresolved condition remains but a human overlay exists. Aggregate
ordering is severity Blocking → Warning → Informational, then base status Failed
→ Stale → Unverified, then stable rule code and scope-item ID. Selecting a cell
reveals each scope-item evaluation and shows:

- the current deterministic status;
- the rule and rule version that produced it;
- qualifying and rejected evidence;
- exact target identity;
- scenario or policy identity;
- safe artifacts and timestamps; and
- allowed resolutions for the current role.

For a gap, a Delivery Lead may:

- attach or upload qualifying evidence;
- exclude the affected scope with a required reason; or
- accept the risk with a required reason.

Exclusion and risk acceptance are visible resolution overlays. They do not turn
the underlying deterministic status into Verified.

When every active scope-mapping, target-configuration, and coverage gap is
closed or has an authorized visible resolution, no relevant ingestion is
pending, and every selected disclosure is safe, the Delivery Lead assigns the
named reviewer and previews the exact client view including that reviewer
assignment. Publishing then creates an immutable Passport snapshot.

### 4.4 Client decision

After publication, the Delivery Lead sends an expiring private link to the
reviewer already bound to the snapshot. The reviewer can read the Passport
before verification. Approve and Request changes require a one-time code sent
to the assigned email.

A recorded decision is bound to one snapshot. A material release change creates
a new draft and cannot move, rewrite, or invalidate the historical meaning of
the old decision.

## 5. Explicit non-goals

The beta does not include:

- billing or subscription enforcement;
- GitHub App installation, webhook scope import, or check publication;
- Slack notifications;
- JUnit or CTRF imports;
- hosted mobile devices or browsers;
- a proprietary web runner;
- self-service team invitations;
- advanced custom branding;
- public Passport pages;
- portfolio analytics;
- Jira, Linear, Teams, device-cloud, or test-management integrations;
- autonomous test execution;
- automatic risk acceptance or release approval;
- broad AI test generation unrelated to a release gap; or
- compliance, non-repudiation, or bug-free claims.

## 6. Repository and deployment boundaries

### 6.1 Repositories

Two release boundaries remain:

```text
zeno-mobile-runner    Public/open-source
├── ZMR mobile runner
├── Playwright reporter
├── Evidence Contract and schemas
├── local package writer and validator
├── conformance fixtures
└── zmr-evidence upload command

zeno-cloud            Private/hosted product
├── agency workspace
├── ingestion API and processing
├── deterministic coverage engine
├── test-gap proposals
├── Release Passports
├── external review
└── public marketing surface
```

`zeno-cloud` consumes only published public exports and schemas from an exact
version of `zeno-mobile-runner`. It must not import unpublished repository
internals.

### 6.2 Managed stack

The hosted beta is a TypeScript modular monolith:

- **Next.js on Vercel:** public site, internal workspace, Passport pages, API
  routes, and server-side mutations.
- **Supabase PostgreSQL:** domain data, transactional state, and row-level
  tenant policies.
- **Supabase Auth:** internal user authentication.
- **Supabase Storage:** private evidence artifacts and disclosed previews.
- **Inngest:** durable ingestion, normalization, evaluation, notification, and
  retention workflows.
- **Resend:** reviewer invitations and one-time verification emails.
- **AI provider adapter:** on-demand scoped test proposals behind a server-only
  interface. The exact model provider is an implementation-plan choice.

The application and data services should use compatible EU regions where the
providers make them available. Before processing pilot customer data, the
operator must verify provider agreements, retention configuration, and the
actual deployment regions. The beta makes no compliance claim merely because a
region is selected.

Relevant provider capabilities:

- [Next.js on Vercel](https://vercel.com/docs/frameworks/full-stack/nextjs)
- [Supabase Auth](https://supabase.com/docs/guides/auth)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase private storage buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals)
- [Supabase signed upload URLs](https://supabase.com/docs/reference/javascript/file-buckets-createsigneduploadurl)
- [Inngest durable functions](https://www.inngest.com/docs/learn/inngest-functions)
- [Inngest retries and idempotency](https://www.inngest.com/docs/guides/error-handling)
- [Resend with Next.js](https://resend.com/docs/send-with-nextjs)

### 6.3 Modular monolith

The application contains these domain modules:

- **Accounts:** agencies, members, roles, clients, and automation identities.
- **Projects:** projects, surfaces, journeys, and journey versions.
- **Releases:** releases, scope, targets, and material-change tracking.
- **Evidence:** ingestion sessions, manifests, runs, items, artifacts, and
  quarantine.
- **Coverage:** deterministic rules, evaluations, gaps, and resolutions.
- **Passports:** previews, canonical snapshots, disclosures, and supersession.
- **Reviews:** reviewer assignments, links, verification, and decisions.
- **Audit:** append-only material event records.
- **Suggestions:** provider-neutral AI proposal requests and outputs.

Route handlers, server actions, and Inngest functions call the same domain
services. Domain services do not import UI components or transport-specific
request objects. There is no separate API service, event broker, or fleet of
microservices in the beta.

## 7. Core data model

Every tenant-owned mutable table includes `agency_id`, stable identifier,
creation timestamp, and an explicit version where optimistic concurrency or
historical meaning requires it. IDs exposed in URLs are opaque and not
sequential.

### 7.1 Account and project records

- `agencies`
- `agency_memberships`
- `clients`
- `projects`
- `project_surfaces`
- `automation_credentials`
- `journeys`
- `journey_versions`

Automation credentials store a one-way token hash, fixed scope, creation actor,
last-used timestamp, expiry, and revocation state. Raw tokens are shown once.

Journey display names may change without changing stable journey IDs. A
material journey definition change creates a new `journey_version` with a new
policy or scenario hash.

### 7.2 Release records

- `releases`
- `release_scope_items`
- `release_journeys`
- `scope_item_journeys`
- `target_builds`
- `release_material_versions`
- `release_policy_versions`
- `release_policy_assignments`

`scope_item_journeys` binds one included acceptance criterion to one protected
journey and its required-surface subset. Mapping surfaces must be a non-empty
subset of the selected journey version's allowed surfaces; a mapping may narrow
that set but cannot introduce another surface. The mapping is versioned with
release material state. Every included scope item needs at least one active
mapping or produces an unmapped-scope gap; excluded scope keeps its mapping
history.

The beta ships one immutable, system-controlled release policy,
`beta-1`. It pins:

- the coverage rule-set version and official producer allowlist;
- outcome and retry interpretation;
- severity mapping from journey criticality and rule code;
- required target, environment, artifact, and disclosure checks;
- which resolutions Owner and Delivery Lead may apply; and
- the publication gate.

There is no tenant policy editor in the beta. A later operator policy change
creates a new immutable policy version. Moving a release to it requires an
Owner or Delivery Lead action and increments the release material version.

The beta permits one active target per release and required surface. Replacing
a target marks the old target superseded and increments the material version.

Each target stores the complete registered fingerprint recipe inputs and the
recomputed fingerprint. A mutable URL, commit alone, or human build name cannot
qualify as an exact target.

### 7.3 Evidence records

- `ingestion_sessions`
- `ingestion_artifacts`
- `evidence_runs`
- `evidence_items`
- `evidence_artifacts`
- `quarantined_ingestions`

The manifest digest plus authenticated agency, project, and release context is
the duplicate key. Evidence runs, evidence items, and received manifest facts
are append-only. A normalization correction creates a replacement record linked
to its predecessor.

Artifact database records store semantic type, content digest, byte size,
storage key, redaction state, disclosure eligibility, verification state, and
retention metadata. Storage object keys are server-generated and do not contain
caller-controlled path segments.

### 7.4 Coverage and resolution records

- `coverage_evaluations`
- `coverage_evidence_links`
- `gaps`
- `coverage_gaps`
- `scope_mapping_gaps`
- `target_configuration_gaps`
- `gap_resolutions`

A coverage evaluation key is:

```text
release × scope item × journey version × required surface
        × active target fingerprint × release policy version
```

Each evaluation stores its rule-set version, status, explanation payload,
qualifying evidence, rejected evidence and reasons, evaluation input digest,
and evaluated timestamp.

`gaps` stores common lifecycle, rule, severity, and resolution facts. Exactly
one kind-specific record must exist:

- `coverage_gaps` requires one `coverage_evaluation_id` and therefore inherits
  its scope item, journey, surface, target, and policy identity.
- `scope_mapping_gaps` requires release, included scope item, and policy version
  only. It has no journey, surface, target, or coverage evaluation and uses the
  blocking `ZB001_SCOPE_UNMAPPED` rule.
- `target_configuration_gaps` requires release, required surface, and policy
  version only. It has no target or coverage evaluation and uses the blocking
  `ZB002_TARGET_MISSING_OR_INVALID` rule.

The database schema and domain constructors enforce the exclusive gap kind.
Scope-mapping gaps appear in release setup, the Proofline Scope stage, and the
gap queue. Target-configuration gaps appear in the Proofline Builds stage and
gap queue. Neither appears as a fabricated journey-matrix cell.

No coverage evaluation is persisted for a surface outside a mapping. The UI
synthesizes `not_required` for a journey/surface with zero active required
mappings. A matrix cell with at least one required mapping aggregates only its
persisted required evaluations.

A gap resolution stores the original gap, resolution type, reason, authorized
actor, evidence or scope reference where relevant, and timestamp. It never
overwrites the evaluation status.

### 7.5 Passport and review records

- `passport_snapshots`
- `passport_disclosures`
- `reviewer_assignments`
- `reviewer_identity_vault`
- `review_links`
- `review_verifications`
- `review_decisions`
- `audit_events`

Published snapshot canonical JSON is stored as immutable text with its
`sha256:` content digest. The canonical payload includes:

- release identity and material version;
- included and excluded scope;
- journey versions and required surfaces;
- exact target fingerprints;
- coverage statuses, rule versions, and qualifying evidence digests;
- visible gaps and resolutions;
- disclosed artifact digests and disclosure states; and
- immutable reviewer-assignment ID and reviewer-identity digest.

`reviewer_assignments` is immutable and contains no clear-text PII. Reviewer
display name and email live in the separately access-controlled
`reviewer_identity_vault`; the assignment stores only its opaque vault ID and a
domain-separated keyed digest over the assignment ID, a random 256-bit identity
nonce kept only in the vault, and the normalized identity. The snapshot binds
that digest and assignment ID, so changing the named reviewer requires a new
snapshot.

The vault is the explicit privacy exception to append-only domain facts. An
authorized pseudonymization operation irreversibly removes the name/email
ciphertext or wrapped data key and the identity nonce, leaves a non-identifying
tombstone, closes links and verification, and appends an audit event containing
only opaque IDs. Removing the nonce prevents later identity-digest dictionary
matching even if the server digest key remains available. Pseudonymization does
not change the assignment, snapshot content hash, decision type, verified role
fact, or timestamp. Clear-text reviewer PII must never be copied into snapshots,
decisions, audit events, analytics, or job payloads.

Short-lived artifact URLs and review-link tokens are never part of canonical
snapshot content.

Published snapshots, decisions, and audit events cannot be updated or deleted
through application roles. Revocation and supersession create new append-only
records.

## 8. Deterministic coverage engine

### 8.1 Statuses

Each required coverage cell has exactly one base status:

| Status | Meaning |
|---|---|
| `verified` | The selected current evidence passed with exact target and journey identities |
| `failed` | The selected current qualifying evidence completed with a non-passing outcome |
| `stale` | Relevant evidence exists but targets an older build, journey, scenario, or policy version |
| `unverified` | No qualifying evidence exists |
| `not_required` | The surface is outside this journey's release scope |

`not_required` is displayed but does not produce a gap. Every other
non-verified required status produces or updates an explainable gap. Missing
evidence, target mismatch, stale journey, and partial outcome remain distinct
coverage rule codes and explanations rather than becoming competing top-level
statuses. Processing ingestion uses the transient publication-blocking rule
`ZB009_INGESTION_PENDING`. An unsupported producer uses ingestion reason
`ZI001_UNSUPPORTED_PRODUCER`, not a coverage rule, and never creates or changes
a coverage evaluation or gap.

Ingestion progress is stored as evaluation freshness (`pending` or `current`),
not as a fifth coverage truth state. A pending relevant ingestion blocks
publication but does not erase the previous deterministic evaluation. When no
previous evaluation exists, the required cell is `unverified` with
`ZB009_INGESTION_PENDING` until ingestion reaches a terminal state. When a
previous evaluation exists, its base status and existing gap remain unchanged
while freshness is `pending`; the transient `ZB009` reason is stored alongside
freshness. `ZB009` cannot be resolved or overridden and disappears when the
terminal ingestion result causes deterministic re-evaluation.

### 8.2 Qualification and selection

For beta rule set `beta-1`:

1. The included scope item must have an active mapping to the protected journey
   and required surface under the pinned release policy.
2. The active target must have a complete registered fingerprint.
3. The manifest must use Evidence Contract schema `1.0` and match one supported
   official producer tuple:
   - `zeno-mobile-runner` + `zeno_runner` + `unattested` for iOS or Android,
     with adapter version `1.0.0`, `mobile-v1`, and recomputed fingerprint;
   - `playwright` + `official_adapter` + `unattested` for web, with adapter
     version `1.0.0`, `web-v1`, and recomputed fingerprint.
4. Imported, unknown, unsupported-version, or contradictory producer tuples
   cannot qualify. The beta quarantines them before artifact upload with
   `ZI001_UNSUPPORTED_PRODUCER` rather than treating a conforming self-reported
   manifest as official evidence. This ingestion result does not create or
   modify coverage. Independently, a cell with no supported official evidence
   remains `unverified` under `ZB003_EVIDENCE_MISSING`.
5. Evidence must match the authenticated agency, project, and release context;
   self-reported manifest claims cannot broaden that context.
6. Evidence must match surface, environment, target fingerprint, stable journey
   ID, and current journey scenario hash. The evaluation separately pins and
   records the active release-policy version.
7. The evidence package and all referenced qualifying artifacts must have
   completed digest verification.
8. The evidence item's aggregate outcome is used; individual retries remain
   visible but do not get independently promoted.
9. When several exact current items exist, choose the latest completed item by
   normalized completion time and break a tie with manifest digest ordering.
10. The selected item's passing aggregate outcome yields `verified`. A failed,
    timed-out, interrupted, skipped, or partial aggregate outcome yields
    `failed` under `beta-1`, with the precise outcome retained in the gap.
11. Without exact current evidence, relevant evidence for an older target,
    journey, scenario, or policy yields `stale`; otherwise the result is
    `unverified`. Target mismatch and missing evidence remain distinct gap
    reasons.
12. A relevant in-progress ingestion marks evaluation freshness `pending` and
    blocks publication with `ZB009_INGESTION_PENDING`. It preserves any previous
    base status and gap. Without a previous evaluation, the cell is
    `unverified` under transient `ZB009`. Completion or terminal failure removes
    `ZB009` and deterministically re-evaluates the cell from terminal facts.

Re-evaluating identical inputs under the same rule version must produce the
same status, explanation, and input digest.

### 8.3 Gaps and resolutions

Each gap contains:

- stable rule code and rule version;
- affected release, policy version, and gap kind;
- the scope item for scope-mapping gaps;
- the required surface for target-configuration gaps;
- the complete scope item, journey, surface, and target identity inherited from
  the evaluation for coverage gaps;
- severity derived by the pinned policy from journey criticality, rule code,
  and failure class;
- deterministic summary and explanation;
- qualifying and rejected evidence references;
- recommended deterministic action; and
- current lifecycle and resolution overlay.

A release is ready to publish only when:

- no relevant evaluation freshness is `pending`; `ZB009` cannot be resolved or
  overridden;
- every gap of every subtype under the active release material version and
  policy is either closed because its mapping, target, or evidence truth was
  corrected, or has an active policy-allowed and authorized `excluded_scope` or
  `accepted_risk` resolution; and
- every artifact selected for disclosure has a confirmed safe disclosure state;
  `ZB008` cannot be resolved or overridden.

This gate applies equally to `scope_mapping_gaps`,
`target_configuration_gaps`, and `coverage_gaps`. Therefore an unresolved
`ZB001` always blocks publication. An authorized, visible risk acceptance may
permit publication with `ZB002` and an incomplete required target, but the
missing target never becomes Verified and no journey-matrix cell is fabricated.
Pending ingestion and unsafe disclosure remain unconditional blockers.

Risk acceptance remains visible to the client and cannot be applied by an
automation identity or Contributor. Under `beta-1`, Owner and Delivery Lead may
accept even a blocking risk only with a non-empty client-visible reason; this
does not alter its severity or base status.

### 8.4 Exact `beta-1` policy

`beta-1` accepts journey criticality values `critical`, `high`, and `normal`.
The following table pins its initial publication-rule severity:

| Rule | Critical | High | Normal |
|---|---|---|---|
| `ZB001_SCOPE_UNMAPPED` | Blocking | Blocking | Blocking |
| `ZB002_TARGET_MISSING_OR_INVALID` | Blocking | Blocking | Blocking |
| `ZB003_EVIDENCE_MISSING` | Blocking | Blocking | Warning |
| `ZB004_EVIDENCE_FAILED_OR_INCOMPLETE` | Blocking | Blocking | Warning |
| `ZB005_EVIDENCE_STALE_TARGET` | Blocking | Blocking | Warning |
| `ZB006_EVIDENCE_STALE_SCENARIO_OR_POLICY` | Blocking | Blocking | Warning |
| `ZB007_RETRY_ONLY_OR_FLAKY` | Blocking | Warning | Warning |
| `ZB009_INGESTION_PENDING` | Blocking | Blocking | Blocking |

Configuration rules that do not belong to one journey use the severity shown
in every column. `not_required` and historical evidence that is not selected
are Informational and do not create resolvable gaps.

Outcome treatment is fixed:

- A ZMR item qualifies as passing only when the run is `complete`, the selected
  item outcome is `passed`, and every other identity rule succeeds. `partial`,
  `failed`, `timed_out`, `interrupted`, `skipped`, or unknown/non-passing
  outcomes use `ZB004`.
- Playwright items are grouped by stable `externalId` and the highest retry is
  selected. The item qualifies as passing only when the trusted adapter's
  `aggregateOutcome` is `expected`, the selected attempt outcome is `passed`,
  and its `expectedStatus` is `passed`.
- Playwright `flaky` always produces base status `failed` with
  `ZB007_RETRY_ONLY_OR_FLAKY` and does not verify coverage even when the final
  retry passed. `unexpected`, `skipped`, expected non-passing tests, partial
  runs, and unknown outcomes produce base status `failed` with `ZB004`.
- A newer exact qualifying result supersedes an older result for current status;
  an older pass cannot hide a newer failure.

Environment and execution treatment is fixed:

- evidence environment must exactly match the release target environment;
- mobile evidence must carry concrete device, OS name, and OS version, but the
  beta does not enforce a device matrix; and
- web evidence must carry concrete browser name and version, but the beta does
  not enforce a browser matrix.

Artifact and disclosure treatment is fixed:

- Verified coverage requires a valid manifest and digest verification for every
  artifact the package declares, but no optional screenshot, video, trace, or
  report type is mandatory; an evidence item with zero optional artifacts may
  verify coverage.
- A Passport may publish with no disclosed artifact. Any selected artifact must
  have verified bytes, redaction state `reviewed` or `redacted`, and an explicit
  Cloud disclosure record. `unreviewed` artifacts cannot be selected.
- Evidence Contract artifacts arrive `private` unless their producer says
  otherwise. The Cloud review action creates a separate `review_eligible` or
  `disclosed` record; it never rewrites the append-only source descriptor.
- Unsafe selected disclosure uses publication error
  `ZB008_DISCLOSURE_UNSAFE` and blocks publishing on every criticality. It is a
  preview/publication validation error, not a fabricated coverage evaluation.

Resolution treatment is fixed:

- Owner and Delivery Lead may apply `accepted_risk` to `ZB001`–`ZB007`,
  including `ZB002`, with a bounded non-empty client-visible reason;
  Contributor and automation may not. It may permit publication only and never
  changes a base status, fabricates a matrix cell, or asserts Verified coverage.
- Owner and Delivery Lead may exclude an affected scope item with a bounded
  non-empty client-visible reason. Exclusion removes its active coverage routes
  but preserves their history. `excluded_scope` is available only when an
  affected scope item can be excluded under the release model.
- A target-configuration gap disappears only after a valid target is registered
  or no included mapping requires that surface. Risk acceptance may permit
  publication but never creates Verified coverage.
- No role can resolve `ZB008` with risk acceptance; the selected artifact must
  be made safe or removed from disclosure.
- No role can resolve `ZB009`; ingestion must complete or fail terminally before
  publication can be re-evaluated.

## 9. AI test proposals

AI is an optional explanatory assistant, not a truth source.

Proposals are generated on demand for one gap. The provider receives only:

- client-safe scope description;
- acceptance criteria;
- journey name and safe description;
- required surface;
- deterministic gap code and explanation;
- supported ZMR or Playwright action vocabulary; and
- explicit output schema.

Raw screenshots, trace archives, secrets, reviewer data, and full application
logs are excluded by default.

The structured response contains suggested setup, actions, assertions,
assumptions, and limitations. It is validated before display and stored with the
provider-independent prompt version, safe input digest, creation actor, and
model metadata required for debugging.

An AI failure does not change the gap, block deterministic evaluation, or
prevent a user from writing a test manually. A proposal cannot execute itself,
change release policy, accept risk, exclude scope, publish, or approve.

## 10. Ingestion protocol and state machine

### 10.1 API sequence

1. `create ingestion`: authenticate the scoped credential, validate request
   shape, compare release/project claims, and upsert by idempotency key.
2. `plan artifacts`: return only missing content digests with short-lived signed
   upload instructions and enforced size/type limits.
3. `upload artifacts`: upload directly to private storage.
4. `finalize ingestion`: atomically record the request to verify and enqueue
   durable processing.
5. `verify`: check every expected object, size, digest, path mapping, and
   completeness rule.
6. `normalize`: create append-only evidence runs and items.
7. `evaluate`: recompute only affected release cells under the pinned rule
   version.
8. `complete`: expose a safe stable result and audit event.

### 10.2 States

```text
created → awaiting_artifacts → uploaded → verifying → normalizing
        → evaluating → completed

Any processing state → retrying → previous processing state
Any authenticated, well-formed but permanently disallowed package → quarantined
An abandoned incomplete session → expired
```

Finalization is idempotent. A completed package retry returns the existing
evidence run. An incomplete retry resumes only missing artifacts. Quarantined
content cannot affect coverage.

A rejected request sits outside this state machine and does not create an
ingestion session. A quarantined session records only bounded safe metadata and
the fixed reason code unless artifact bytes had already been accepted before a
digest or content failure.

### 10.3 Failure behaviour

| Failure | Behaviour |
|---|---|
| Malformed JSON or invalid manifest shape | Reject before creating a session; retain only a bounded security event |
| Well-formed unsupported schema | Create a metadata-only quarantined session with `ZI002_UNSUPPORTED_SCHEMA`; request no artifacts and do not create or modify coverage |
| Well-formed supported schema with an unsupported producer tuple | Create a metadata-only quarantined session with `ZI001_UNSUPPORTED_PRODUCER`; request no artifacts and do not create or modify coverage |
| Unauthorized project/release claim | Reject without revealing whether the claimed resource exists |
| Missing, malformed, or contradictory fingerprint | Create a metadata-only quarantined session; never verify coverage |
| Valid fingerprint for a different active target | Complete as non-qualifying context and produce a Stale target-mismatch gap |
| Artifact digest or size mismatch | Quarantine the ingestion and object; no normalization |
| Worker retry exhaustion | Preserve previous valid coverage and show a recoverable ingestion error |
| Duplicate upload | Return the existing session or evidence result |
| AI provider failure | Keep the deterministic gap and show proposal unavailable |
| Email provider failure | Preserve the snapshot and retry notification; do not fabricate delivery |
| Redaction uncertainty | Keep the artifact private and block its disclosure |

## 11. Passport lifecycle

### 11.1 Release states

```text
draft → collecting_evidence → resolving_gaps → ready_for_review
      → in_client_review → approved | changes_requested
      → superseded
```

These lifecycle labels summarize state. They do not replace the underlying
coverage and review records.

### 11.2 Publishing transaction

Publishing must execute as one transactional domain operation:

1. authorize Owner or Delivery Lead;
2. lock the release material version;
3. reject stale client state through expected-version comparison;
4. require the pre-publication reviewer assignment and compute its
   domain-separated identity digest;
5. rerun or verify current coverage evaluations;
6. enforce publication gates and disclosure safety;
7. construct canonical snapshot content;
8. compute the content digest;
9. insert immutable snapshot, reviewer binding, and disclosure records;
10. transition the release review pointer; and
11. append the publication audit event.

A partial publication is not visible.

### 11.3 Material invalidation

The following create a new draft material version and prevent the old decision
from being treated as current:

- target fingerprint replacement;
- included scope or required-surface change;
- protected journey or scenario hash change;
- release policy change;
- change to qualifying evidence selected for publication;
- exclusion or risk-acceptance change; or
- changed disclosed substance.

The material mutation transaction immediately closes the current snapshot to
new decisions, records `decision_closed_at` with reason `material_change`,
revokes its active review links, increments the release material version, and
opens the new draft. It does not wait for the replacement snapshot to be
published. If the old snapshot already has a decision, that decision remains
historical and immutable. If it has no decision, it can no longer receive one.
The old snapshot, link history, verification, and any existing decision remain
available to authorized internal users as history.

## 12. Review access and decisions

### 12.1 Private link

Review tokens contain at least 256 bits of cryptographically secure randomness.
Only SHA-256 of the high-entropy token is stored. Tokens are scoped to one
reviewer assignment and snapshot, expire, can be revoked, and are rate limited.

Passport responses send `noindex` directives, a restrictive Referrer Policy,
Content Security Policy, and safe content-disposition headers for artifacts.
Client pages never contain tenant navigation or stable internal object IDs.

### 12.2 Verification

Approve and Request changes require a short-lived, single-use code sent to the
assigned email. Because the code has low entropy, it is stored as a
domain-separated HMAC using a server secret plus assignment, nonce, and code;
a plain unsalted digest is prohibited. Codes have attempt limits, expire, and
cannot be reused for another snapshot or reviewer.

Successful verification creates a short-lived, HttpOnly, Secure, appropriately
scoped review session. Viewing the Passport does not silently verify identity.

### 12.3 Decision

The decision endpoint requires:

- active link and review session;
- verified intended reviewer;
- current, decision-open, non-revoked, non-expired snapshot;
- explicit decision value;
- optional bounded comment; and
- unique idempotency key.

The database enforces at most one decision for each reviewer assignment and
Passport snapshot. The transaction inserts that immutable decision and its
audit event. Replaying the same idempotency key returns the original decision;
reusing the key with different input fails, and a different key submitted after
a decision receives a stable already-decided conflict without creating another
row.

## 13. Security and privacy model

### 13.1 Tenant isolation

- Every tenant-owned row carries `agency_id` directly or through a constrained
  immutable parent relationship.
- Every application mutation performs server-side membership and role checks.
- PostgreSQL Row Level Security is enabled on every exposed tenant table.
- The browser never receives a service-role key.
- Background jobs use privileged credentials only through domain services that
  require explicit agency, project, and release context.
- Cross-agency access tests are mandatory for every new domain table and
  storage path.

### 13.2 Artifact privacy

- Storage buckets are private.
- Upload and download URLs are short-lived and server-issued.
- Client artifact access is checked against the snapshot disclosure record
  before a URL is created.
- Originals and redacted derivatives use separate object and permission
  records.
- Operational logs exclude raw artifacts, tokens, OTP codes, signed URLs,
  secrets, and unbounded caller text.
- Retention deletion preserves a digest tombstone without mutating historical
  snapshot hashes.

### 13.3 Append-only facts

Evidence facts, published snapshots, decisions, and audit events are
append-only. Application roles cannot update or delete them. Corrections,
revocations, retention deletion, and supersession are modeled as new records
with explicit links and reasons. The separately isolated
`reviewer_identity_vault` is the only beta exception: its PII may be
irreversibly erased as defined in section 7.5 while immutable domain records
retain only opaque identity and verification facts.

### 13.4 Abuse controls

Apply rate and size limits to authentication, ingestion creation, artifact
upload, review link access, OTP issuance, verification attempts, decisions, and
AI proposals. Reject path traversal, symlinks, unexpected object types,
decompression abuse, unsupported MIME types, oversize files, and ambiguous
Unicode/control characters at trust boundaries.

## 14. User experience

### 14.1 Visual direction

The approved direction is a calm release workbench rather than a generic SaaS
dashboard.

The visual language uses:

- evidence-paper ivory and graphite foundations;
- verification green, warning amber, failure coral, and blueprint blue;
- strong editorial hierarchy and restrained rounded geometry;
- visible product artifacts rather than decorative terminal theatre;
- concise, candid microcopy with light functional humour; and
- a Proofline showing Scope → Builds → Surfaces → Approval.

It must not copy PostHog's desktop metaphor, character, orange palette, or page
composition.

The approved brainstorming mockup is stored in the ignored local companion
directory and is not a production artifact.

### 14.2 Internal routes and views

- Release list ordered by attention required.
- Project/release setup for identity, scope, targets, journeys, and upload
  instructions.
- Release workspace centered on the journey-by-surface matrix.
- Gap detail with deterministic rule, evidence, proposal, and authorized
  actions.
- Exact client preview with disclosure selection.

The internal workspace is desktop-first and remains usable on tablet.

### 14.3 Client Passport

The client-facing order is:

1. exact release being reviewed;
2. what changed;
3. what was verified by customer journey and surface;
4. known limitations, exclusions, and accepted risks;
5. selected proof artifacts; and
6. Approve or Request changes.

The Passport is fully responsive, keyboard accessible, and suitable for a
reviewer opening it on a phone. Testing terminology is secondary to business
journey language.

### 14.4 Required view states

Every relevant view defines loading, empty, processing, partial, success,
recoverable error, permanent error, permission denied, expired, revoked, and
superseded states. Meaning cannot rely on color alone. Motion respects reduced
motion preferences. The target is WCAG 2.2 AA.

## 15. Public launch surface

The same Next.js application provides:

- a concise public homepage;
- an interactive sample Passport using non-customer fixture data;
- a plain-language Scope → Verify → Find gaps → Accept explanation;
- accurate mobile, Playwright, and Evidence Contract integration details;
- a transparent Release Proof Pilot offer; and
- an Apply for a Release Proof Pilot form.

The public site contains no fake customer logos, invented usage counts,
unverified performance comparisons, or claims that Zeno proves a release is
bug-free or independently attested.

Cold outreach begins only after the full automated journey, deployed hosted
smoke gate, and sample Passport are working, as requested by the user.

## 16. Observability and product analytics

Operational signals include:

- ingestion duration and failure reason by schema/source;
- artifact verification and quarantine counts;
- durable-job retries and terminal failures;
- coverage evaluation duration and rule errors;
- OTP issuance, verification failure, and rate-limit events;
- review-link access failures;
- decision idempotency conflicts;
- publication failures and material invalidations; and
- storage and retention work.

Product events include:

- project and release created;
- first journey and target configured;
- first mobile and web evidence completed;
- first gap viewed, proposed, and resolved;
- Passport previewed and published;
- reviewer opened and verified;
- decision recorded; and
- second Passport published.

Analytics payloads use stable internal IDs and coarse metadata, not raw scope,
screenshots, comments, tokens, email addresses, or evidence payloads.

## 17. Verification strategy

### 17.1 Unit and rule tests

- Table-driven tests for every `beta-1` coverage rule and precedence case.
- Scope-item-to-journey mapping cardinality, unmapped-scope gaps, and
  journey-matrix aggregation over multiple scope items.
- Mapping surfaces remain subsets of journey surfaces; `not_required` is
  synthesized without a persisted coverage row.
- Gap subtype constraints represent scope-mapping, target-configuration, and
  coverage gaps without impossible foreign keys.
- The publication gate evaluates every gap subtype: an unresolved mapping gap
  blocks, while an authorized accepted-risk target gap can permit publication
  without becoming Verified.
- The immutable `beta-1` policy hash, severity mapping, producer allowlist,
  exact retry/outcome rules, artifact/disclosure rules, resolution permissions,
  and publication gate.
- Playwright `flaky` deterministically produces `failed`/`ZB007`.
- Pending ingestion without a prior evaluation produces
  `unverified`/`ZB009`; pending ingestion with a prior evaluation preserves its
  base status; neither case can publish until terminal re-evaluation.
- An unsupported producer is quarantined with `ZI001`, never mutates coverage,
  and leaves a cell without supported evidence `unverified`/`ZB003`.
- Target fingerprint and manifest identity matching.
- Exact ZMR and Playwright producer tuples qualify while every unknown,
  imported, contradictory, or unsupported adapter tuple does not.
- Deterministic input digest and identical-input re-evaluation.
- Gap lifecycle and authorization.
- Snapshot canonicalization and content hashing.
- Material-change classification and invalidation.
- Token and OTP hashing, expiry, attempt, and idempotency rules.
- Reviewer-vault pseudonymization removes recoverable PII while preserving the
  opaque assignment, snapshot digest, verification fact, and decision history.
- Safe error serialization and sensitive-value redaction.

### 17.2 Contract tests

Every public ZMR and Playwright Evidence Contract fixture is submitted to the
cloud normalizer and asserted against expected stored runs, items, artifacts,
provenance, target identity, and outcomes.

The cloud must include valid passed, failed, partial, retry-pass, missing target,
unknown schema, malformed manifest, malicious path, digest mismatch, redacted,
and omitted-artifact cases.

### 17.3 Integration and security tests

- Database migrations apply from empty and upgrade the previous schema.
- RLS denies cross-agency reads and writes for every table.
- Storage policies deny cross-agency listing, upload, and download.
- Service operations remain explicitly tenant-scoped.
- Ingestion creation, upload, finalize, retry, duplicate, quarantine, and expiry
  behave idempotently.
- Worker failure never replaces previous valid coverage.
- Hidden artifacts never appear in Passport payloads.
- Clear-text reviewer PII never appears in canonical snapshots, decisions,
  audit events, analytics, or durable-job payloads.
- Review tokens and codes enforce scope, expiry, revocation, rate limits, and
  replay protection.
- Decisions are immutable and cannot move between snapshots.

### 17.4 End-to-end acceptance test

The beta is not complete until one reliable Playwright test demonstrates:

1. sign in as a Delivery Lead;
2. create an agency client and cross-surface project;
3. create a release with scope and three to five journeys;
4. register exact web, iOS, and Android targets;
5. submit ZMR and Playwright Evidence Contract packages;
6. observe a deliberately Unverified Android evaluation with a missing-evidence
   gap reason;
7. request and display a scoped test proposal without status mutation;
8. accept the visible risk or add qualifying evidence;
9. assign the reviewer, preview, and publish an immutable Passport;
10. open the external private link;
11. verify the reviewer and request changes;
12. replace a target build and prove that the first snapshot closes to new
    decisions immediately;
13. add new evidence and publish a second snapshot;
14. verify and approve it; and
15. make another material change and prove that a new pending draft appears while the
    approved snapshot and decision remain unchanged.

CI runs this journey against isolated service instances and controlled provider
adapters. That test is necessary but not sufficient for outreach.

A separate pre-outreach hosted smoke gate must run through a deployed Vercel
staging application, a real Supabase staging project for Auth/PostgreSQL/private
Storage, Inngest's managed durable execution, and Resend delivery to a
controlled test inbox. It starts with `zmr-evidence upload` across the network
and finishes with a real reviewer-code decision. No in-memory or local substitute
may satisfy this hosted gate. The configured AI provider must also return one
schema-valid fixture proposal, although its failure never changes deterministic
coverage.

## 18. Delivery sequence

### Weeks 1–2: Foundation

- create private `zeno-cloud` repository;
- configure preview, hosted staging, and production environments;
- establish TypeScript, formatting, tests, and CI;
- implement managed authentication and tenant model;
- build the design tokens, application shell, and public shell; and
- prove RLS with cross-tenant tests before adding domain breadth.

### Weeks 3–4: Release definition

- clients, projects, surfaces, and roles;
- releases, manual scope, journeys, and versions;
- exact target registration and fingerprint verification;
- setup and empty/error states; and
- audit foundation.

### Weeks 5–6: Evidence pipeline

- cloud ingestion API and private storage;
- durable verification and normalization;
- append-only evidence records and quarantine;
- `zmr-evidence upload` in the public repository;
- ZMR and Playwright conformance integration; and
- safe operator diagnostics.

### Weeks 7–8: Coverage and gaps

- `beta-1` deterministic rule engine;
- matrix and evidence drill-down;
- gap lifecycle, exclusion, and risk acceptance;
- role enforcement and audit; and
- on-demand structured test proposals.

### Weeks 9–10: Passport and review

- exact client preview and disclosure controls;
- canonical snapshot publication;
- private review links and email verification;
- Approve and Request changes decisions;
- revocation, expiry, and supersession; and
- responsive client Passport.

### Weeks 11–12: Hardening and launch

- complete acceptance journey;
- security and accessibility pass;
- realistic web/iOS/Android demo release;
- public homepage, interactive sample, and pilot application;
- operational runbook, backups, retention, and failure drills; and
- production readiness review before outreach.

If the schedule slips, deferred integrations and polish variants remain out.
The end-to-end decision workflow, tenant safety, deterministic rules, and
immutable history are not cut.

## 19. Beta acceptance criteria

The working beta is accepted only when:

- the deployed hosted staging application passes the managed-service smoke gate
  across Vercel, Supabase Auth/PostgreSQL/Storage, Inngest, Resend, the configured
  AI provider, and the networked evidence upload command;
- one release spans web and at least one mobile surface, with the demo covering
  web, iOS, and Android;
- current ZMR and Playwright packages ingest through a documented CI-safe
  command;
- exact target fingerprints are required for Verified;
- every included scope item maps to at least one of three to five protected
  journeys and its required surfaces;
- every required cell has an explainable deterministic status;
- publication evaluates scope-mapping, target-configuration, and coverage gaps;
  unresolved gaps block unless an authorized `beta-1` resolution applies, and
  accepted risk never creates Verified coverage;
- AI proposes a scoped test without changing truth state;
- authorized users can add evidence, exclude scope, or accept visible risk;
- disclosure is previewed before publishing;
- published snapshots are immutable and content-addressed;
- a named external reviewer can verify and decide without an account;
- material changes create a new draft and preserve historical decisions;
- tenant isolation, artifact privacy, upload abuse, and review replay tests pass;
- the full automated acceptance journey passes;
- the hosted smoke gate passes without a local provider substitute;
- no normal customer flow requires manual database intervention; and
- the public sample and pilot application are ready before cold outreach.

## 20. Approved decision summary

The approved beta direction is:

- optimize for a working beta before outreach;
- deliver in 8–12 weeks part-time;
- use managed infrastructure;
- build a separate private `zeno-cloud` modular monolith;
- keep ZMR and Playwright as evidence producers;
- add only the upload capability required to connect the open package to cloud;
- make the journey-by-surface gap matrix the internal focal point;
- make deterministic rules authoritative;
- keep AI proposals scoped, optional, and non-authoritative;
- publish immutable client-facing Release Passports;
- verify reviewer email before decisions;
- preserve old snapshots and decisions after material changes;
- use the approved calm, minimal, evidence-first visual direction;
- defer integrations, billing, generic imports, and broad analytics; and
- begin cold outreach only after the complete beta and sample Passport work.
