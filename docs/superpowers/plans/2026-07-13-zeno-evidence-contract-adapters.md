# Zeno Evidence Contract and Mobile/Web Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Ship a public, deterministic Evidence Contract v1 plus first-party adapters that turn completed Zeno Mobile Runner traces and Playwright web runs into self-contained, locally verifiable evidence packages.

**Architecture:** Add a dependency-free Node 18 evidence layer inside the existing npm package. The layer owns canonical JSON, digests, exact target fingerprints, manifest validation, safe artifact packaging, hardened ZMR archive reading, and a supported Playwright custom reporter. Keep the Zig runner, trace v1, viewer, cloud ingestion, Passport UI, approval workflow, and gap engine unchanged in this slice.

**Tech Stack:** Node.js 18 ESM and built-in modules at runtime, JSON Schema Draft 2020-12, a disposable pinned Ajv conformance harness for tests, RFC 8785-compatible JSON canonicalization for supported values, SHA-256, Zig 0.16 schema registry tests, Node test runner, Playwright 1.42+ public Reporter API types only.

---

## Outcome and scope

At the end of this plan:

- zmr-evidence from-zmr creates a directory containing evidence.json and artifacts/ from either a trace directory or a .zmrtrace archive.
- zmr-evidence validate verifies schema-level semantics, target fingerprint recomputation, safe paths, file sizes, and artifact digests.
- zeno-mobile-runner/playwright-reporter is a supported Playwright custom reporter that writes the same package shape after a web test run.
- Every qualifying package has explicit release identity, exact build/deployment identity, a target fingerprint, provenance class, attestation state, stable journey mapping, scenario hash, attempts, outcomes, and artifact digests.
- Missing identity is a hard local error. No adapter infers a target fingerprint from a URL, commit alone, build label, test title, or run ID.
- Public versioned fixtures let other producers test conformance without Zeno Cloud.

This plan intentionally excludes:

- hosted ingestion, authentication, tenants, uploads, and storage;
- Release Passport UI and client review;
- the deterministic Evidence Gap Engine and AI test proposals;
- release decisions, Accepted risk, and Excluded states;
- JUnit/CTRF or other generic imports;
- cryptographic signing and CI attestation;
- changes to src/trace.zig, schemas/trace-manifest.schema.json, src/bundle.zig, viewer/parser.js, or Zig CLI dispatch.

Those are separate implementation plans. The expected program order is:

1. Evidence Contract plus ZMR and Playwright adapters — this plan.
2. JUnit/CTRF generic imports plus the remaining cross-adapter conformance matrix — required before MVP.
3. Release domain and deterministic gap engine.
4. Hosted Passport and client approval.
5. GitHub scope sync, pilot operations, and product UI.

## Non-negotiable contract decisions

### Evidence package

The package is a directory:

    evidence-package/
      evidence.json
      artifacts/
        sha256/
          85/
            bc2a1f...<remaining digest hex>
          d4/
            c61c9a...<remaining digest hex>

evidence.json never contains absolute source paths. Included artifacts are content-addressed, copied into artifacts/, and referenced with safe POSIX-relative paths. Identical bytes are stored once.

The manifest itself has no self-referential digest field. Commands return its SHA-256 digest in their JSON stdout summary. Cloud ingestion can later use that digest as an idempotency input.

### Producer trust

Adapters in this plan emit:

| Adapter | provenanceClass | attestationState |
|---|---|---|
| ZMR trace, producer zeno-mobile-runner | zeno_runner | unattested |
| Playwright reporter, producer playwright | official_adapter | unattested |

These values describe the processing path. They do not claim independent authenticity. Do not use “independently verified execution” in code, documentation, output, or fixtures.

### Project and submission identity

Every manifest requires:

    "project": {
      "externalId": "agency-project-id"
    },
    "submission": {
      "actorType": "automation",
      "externalId": "github-actions:org/repo:run-1842",
      "claimState": "self_reported"
    }

project.externalId provides stable tenant-local project routing before cloud IDs exist.

submission is an explicitly untrusted producer claim. It records useful local/CI context but never authorizes ingestion and never proves who ran the test. Future Zeno Cloud ingestion must store its authenticated user/service principal in a separate ingestion envelope and audit record; it must not replace authorization with submission.externalId.

### Exact target fingerprint recipes

Both recipes canonicalize the exact object shown, encode it as UTF-8, hash it with SHA-256, and prefix lower-case hexadecimal with sha256:.

Mobile recipe:

    {
      "appId": "com.example.app",
      "artifactDigest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "buildNumber": "42",
      "recipe": "mobile-v1",
      "surface": "android",
      "version": "1.2.3"
    }

Expected fingerprint:

    sha256:db1eb8afc3eb86f49a47b387e9ba2ee3c14891d2b6a3ee70db83f83612af37b5

Web recipe:

    {
      "buildManifestDigest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "commitSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "configDigest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "deploymentId": "dpl_123",
      "environment": "staging",
      "recipe": "web-v1",
      "surface": "web"
    }

Expected fingerprint:

    sha256:eb73d4d6a2e408508a2a2839f8cce980434ac6fa935a024bc2f322420dbdd98f

Do not add optional recipe fields, empty strings, URLs, device names, browser names, or timestamps to these objects. A future recipe changes the recipe version.

### Outcome mapping

Evidence attempt outcomes are:

    passed | failed | partial | skipped | timed_out | interrupted | unknown

ZMR partial remains partial. For Playwright, derive each attempt from TestResult.status, not TestCase.outcome alone. Preserve expectedStatus and the aggregate Playwright classification in a namespaced extension. An expected-to-fail test that failed must not become passing evidence, and a retry-pass must remain visibly flaky rather than collapsing to an ordinary pass.

### Journey and scenario identity

- ZMR traces do not contain a journey ID or scenario source. from-zmr requires --journey-id plus exactly one of --scenario or --scenario-hash.
- When --scenario is used, parse the JSON and hash its canonical representation. Never hash scenarioName as a substitute.
- A Playwright item qualifies for journey coverage only when a test annotation of type zeno:journey or an exact journeyMap record supplies the ID. Never infer a journey from the test title.
- Unmapped Playwright items are retained with journeyId null solely as non-qualifying context, so the later gap engine can still report the missing mapping.
- A Playwright scenario hash is the digest of canonical JSON containing the test file digest and titlePath.

### Redaction and disclosure

- An unredacted ZMR bundle produces artifact redactionState unreviewed.
- A ZMR bundle with its existing redaction.enabled flag produces redacted for included artifacts and retains omission metadata under extensions.
- The adapter never emits reviewed automatically.
- Every local artifact has an open semantic type plus disclosureState private. Future cloud publication may transition disclosureState through review_eligible, disclosed, or withheld, but local adapters never do.
- This slice writes local packages only. Later cloud ingestion must default uncertain artifacts to private and block client disclosure.

### Forward compatibility

Evidence Contract v1.0 registers only web-v1 and mobile-v1 for qualifying evidence because those target identities are recomputable. It also has an explicit unregistered-target branch: an unknown surface/recipe with a digest-shaped targetFingerprint is retained as non-qualifying context with fingerprintVerification unregistered_recipe. The runtime never pretends it can recompute that opaque recipe. Registering watches, desktop, API, or another surface requires a deterministic recipe, a backward-compatible 1.x schema update when possible, and public conformance fixtures; a breaking interpretation requires a new schema major version. Namespaced extensions and the unregistered branch preserve future source details but cannot make an unregistered recipe qualifying.

## File map

Create:

- schemas/evidence-v1.schema.json
- npm/evidence/canonical-json.mjs
- npm/evidence/fingerprints.mjs
- npm/evidence/contract.mjs
- npm/evidence/package-writer.mjs
- npm/evidence/tar.mjs
- npm/evidence/zmr-adapter.mjs
- npm/evidence/playwright-reporter.mjs
- npm/evidence/playwright-reporter.d.ts
- npm/evidence-cli.mjs
- docs/evidence-contract.md
- examples/playwright-zeno-reporter.config.ts
- examples/playwright-zeno-journey.spec.ts
- fixtures/evidence/v1/README.md
- fixtures/evidence/v1/cases.json
- fixtures/evidence/v1/manifests/zeno-passed.json
- fixtures/evidence/v1/manifests/zeno-failed.json
- fixtures/evidence/v1/manifests/zeno-partial.json
- fixtures/evidence/v1/manifests/playwright-passed.json
- fixtures/evidence/v1/manifests/playwright-retry-pass.json
- fixtures/evidence/v1/manifests/unregistered-target.json
- fixtures/evidence/v1/manifests/missing-optional-artifacts.json
- fixtures/evidence/v1/manifests/redacted-omitted-screenshot.json
- fixtures/evidence/v1/invalid/missing-target-fingerprint.json
- fixtures/evidence/v1/invalid/empty-project-id.json
- fixtures/evidence/v1/invalid/whitespace-journey-id.json
- fixtures/evidence/v1/invalid/unknown-schema-version.json
- fixtures/evidence/v1/invalid/malformed-manifest.json
- fixtures/evidence/v1/invalid/malicious-artifact-path.json
- fixtures/evidence/v1/invalid/artifact-digest-mismatch/evidence.json
- fixtures/evidence/v1/invalid/artifact-digest-mismatch/artifacts/actual.txt
- fixtures/evidence/v1/sources/zmrtrace/passed/scenario.json
- fixtures/evidence/v1/sources/zmrtrace/passed/trace.json
- fixtures/evidence/v1/sources/zmrtrace/passed/events.jsonl
- fixtures/evidence/v1/sources/zmrtrace/passed/artifacts/final.txt
- fixtures/evidence/v1/sources/zmrtrace/failed/trace.json
- fixtures/evidence/v1/sources/zmrtrace/failed/events.jsonl
- fixtures/evidence/v1/sources/zmrtrace/partial/trace.json
- fixtures/evidence/v1/sources/zmrtrace/partial/events.jsonl
- fixtures/evidence/v1/sources/zmrtrace/redacted/trace.json
- fixtures/evidence/v1/sources/zmrtrace/redacted/events.jsonl
- fixtures/evidence/v1/sources/zmrtrace/redacted/artifacts/snapshot.json
- fixtures/evidence/v1/sources/playwright/passed.json
- fixtures/evidence/v1/sources/playwright/retry-pass.json
- tests/evidence-conformance.test.mjs
- tests/evidence-json-schema-conformance.test.mjs
- tests/evidence-contract.test.mjs
- tests/evidence-package.test.mjs
- tests/evidence-zmr-adapter.test.mjs
- tests/evidence-cli.test.mjs
- tests/evidence-playwright-reporter.test.mjs
- tests/packed-evidence-smoke.mjs

Modify:

- src/schema_registry.zig
- src/schema_registry_tests.zig
- schemas/README.md
- package.json
- tests/npm-package.test.mjs
- tests/schemas-json-test.sh
- tests/docs-readiness-test.sh
- scripts/ci-gate.sh
- tests/ci-gate-script-test.sh
- .github/workflows/ci.yml
- README.md
- FEATURES.md

No package-lock.json should be created or committed.

## Task 1: Publish the strict Evidence Contract v1 schema

**Files:**

- Create: schemas/evidence-v1.schema.json
- Create: tests/evidence-contract.test.mjs
- Modify: src/schema_registry.zig
- Modify: src/schema_registry_tests.zig
- Modify: tests/schemas-json-test.sh
- Modify: schemas/README.md

- [ ] Add the first failing Node contract test.

The test must load schemas/evidence-v1.schema.json and assert:

    test("Evidence Contract v1 exposes strict identity and trust fields", () => {
      assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
      assert.equal(schema.$id, "https://zmr.dev/schemas/evidence-v1.schema.json");
      assert.equal(schema.properties.schemaVersion.const, "1.0");
      assert.deepEqual(schema.required, [
        "schemaVersion", "project", "submission", "producer",
        "release", "target", "run", "items"
      ]);
      assert.equal(schema.additionalProperties, false);
      assert.equal(schema.$defs.digest.pattern, "^sha256:[a-f0-9]{64}$");
      assert.deepEqual(
        schema.$defs.producer.properties.provenanceClass.enum,
        ["zeno_runner", "official_adapter", "imported"]
      );
      assert.deepEqual(
        schema.$defs.producer.properties.attestationState.enum,
        ["unattested", "ci_attested", "signature_verified"]
      );
    });

Also assert that the schema has separate mobile-v1, web-v1, and explicitly non-qualifying unregistered target branches; the exact shared identity pattern; explicit project/submission identity; strict attempt outcomes; normalized execution environments; artifact type/redaction/disclosure policy; relative artifact paths; and namespaced extension keys.

- [ ] Run the test and see it fail because the schema does not exist.

Run:

    node --test tests/evidence-contract.test.mjs

Expected: FAIL with ENOENT for schemas/evidence-v1.schema.json.

- [ ] Add failing registry assertions before changing the registry.

In src/schema_registry_tests.zig, add a found_evidence_v1 flag and assert the exact values:

    name: evidence-v1
    path: schemas/evidence-v1.schema.json
    id: https://zmr.dev/schemas/evidence-v1.schema.json

Keep the existing assertion that schemas-output is the final registry entry.

In tests/schemas-json-test.sh:

- change the expected count from 24 to 25;
- assert name evidence-v1;
- assert path schemas/evidence-v1.schema.json;
- assert the matching public ID.

- [ ] Run the registry test and see it fail.

Run:

    zig test src/test_harness.zig

Expected: FAIL because evidence-v1 is not registered.

- [ ] Create the schema header, top-level properties, and closed-object policy.

Use Draft 2020-12, schemaVersion const 1.0, and additionalProperties false at the top level and in every defined object except extensions. The exact top-level structure is:

    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://zmr.dev/schemas/evidence-v1.schema.json",
      "title": "Zeno Evidence Contract v1",
      "type": "object",
      "required": [
        "schemaVersion", "project", "submission", "producer",
        "release", "target", "run", "items"
      ],
      "properties": {
        "schemaVersion": {"const": "1.0"},
        "project": {"$ref": "#/$defs/project"},
        "submission": {"$ref": "#/$defs/submission"},
        "producer": {"$ref": "#/$defs/producer"},
        "release": {"$ref": "#/$defs/release"},
        "target": {"oneOf": [
          {"$ref": "#/$defs/mobileTarget"},
          {"$ref": "#/$defs/webTarget"},
          {"$ref": "#/$defs/unregisteredTarget"}
        ]},
        "run": {"$ref": "#/$defs/run"},
        "items": {
          "type": "array",
          "minItems": 1,
          "items": {"$ref": "#/$defs/item"}
        },
        "extensions": {"$ref": "#/$defs/extensions"}
      },
      "additionalProperties": false
    }

- [ ] Add the shared identity, digest, Git SHA, outcome, timestamp, path, and extension definitions.

Define these exact reusable constraints:

- identity: a string with minLength 1, maxLength 256, and pattern `^(?!\\s)(?!.*\\s$)[^\\u0000-\\u001F\\u007F]+$`; it rejects leading/trailing whitespace and ASCII control characters without trimming or rewriting caller input
- digest: string matching ^sha256:[a-f0-9]{64}$
- gitSha: lower-case 40- or 64-character hexadecimal
- outcome: passed, failed, partial, skipped, timed_out, interrupted, or unknown
- failureClassification: assertion, timeout, interrupted, infrastructure, application, unknown, or null
- completenessState: complete, partial, or incomplete
- run redactionState: unreviewed, redacted, reviewed, or mixed
- artifact disclosureState: private, review_eligible, disclosed, or withheld
- extensions: object whose propertyNames match ^[a-z0-9]+(?:[.-][a-z0-9-]+)+$ and whose values are arbitrary JSON
- artifact path: non-empty canonical POSIX-relative string that does not start with /, a Windows drive, or a backslash and contains no empty, `.` or `..` segment; runtime validation remains authoritative
- timestamp: string with format date-time

- [ ] Add the strict project, submission, producer, and release definitions.

project requires externalId.

submission requires actorType, externalId, and claimState. actorType is user or automation. claimState is const self_reported. Document in the schema description that this object is not authenticated and cannot authorize ingestion.

producer requires name, version, adapterVersion, provenanceClass, and attestationState.

release requires externalId and commitSha.

Use `$defs.identity` for project.externalId, submission.externalId, producer.name/version/adapterVersion, release.externalId, run.externalId, item.externalId, every non-null journeyId, and every mobile/browser execution identity. Also use it for open target identity strings such as environment, appId, version, buildNumber, deploymentId, and unknown surface/recipe names. Enum/const strings remain closed by their enum/const. The runtime must apply the same rule and must never call trim before storing or comparing an identity.

- [ ] Add mutually exclusive mobile-v1 and web-v1 target definitions.

mobileTarget requires:

    surface, environment, fingerprintRecipe, targetFingerprint,
    fingerprintVerification, artifactDigest, appId, version, buildNumber

surface is ios or android, fingerprintRecipe is mobile-v1, and fingerprintVerification is const recomputed.

webTarget requires:

    surface, environment, fingerprintRecipe, targetFingerprint,
    fingerprintVerification, deploymentId, commitSha,
    buildManifestDigest, configDigest

surface is web, fingerprintRecipe is web-v1, and fingerprintVerification is const recomputed.

unregisteredTarget requires surface, environment, fingerprintRecipe, targetFingerprint, and fingerprintVerification. Its surface must not be web, ios, or android; its fingerprintRecipe must not be web-v1 or mobile-v1; and fingerprintVerification is const unregistered_recipe. The targetFingerprint still uses the digest shape so packages remain content-addressable, but this branch is explicitly non-qualifying because v1 cannot recompute the recipe. Use `not` constraints against the registered enums rather than a fragile negative-lookahead regex.

- [ ] Add strict run, item, error, and artifact definitions.

run requires externalId, startedAt, endedAt, outcome, sourceManifestDigest, completenessState, and redactionState.

item requires externalId, journeyId, scenarioHash, outcome, attempt, startedAt, endedAt, durationMs, failureClassification, execution, and artifacts. journeyId accepts `$defs.identity` or null. attempt is a zero-based integer. durationMs is a non-negative finite number because Playwright reports number-valued milliseconds. Optional fields are error and extensions. Source-specific fields such as Playwright expectedStatus and projectName are allowed only beneath the namespaced `dev.playwright.test` extension, never in the neutral item core.

error is a strict object with optional non-empty name (maxLength 256) and message (maxLength 4096) strings and requires at least one of them. It has no value, stack, location, or source-snippet field.

execution is one of:

- mobile: kind mobile plus required deviceName, osName, and osVersion;
- browser: kind browser plus required browserName and browserVersion;
- unregistered: kind unregistered plus a required non-empty namespaced extensions object carrying source context. It is legal only with an unregistered target and is always non-qualifying until a normalized execution branch and fingerprint recipe are registered.

artifact requires type, path, digest, sizeBytes, contentType, redactionState, and disclosureState. type is an open non-empty semantic string such as screenshot, video, trace_manifest, event_log, ui_snapshot, report, test_attachment, or scenario_source. redactionState is unreviewed, reviewed, or redacted. disclosureState is private, review_eligible, disclosed, or withheld. Omitted source artifacts are not represented as fake files; omission policy belongs in extensions.

- [ ] Register evidence-v1 immediately before schemas-output.

Add this entry to src/schema_registry.zig:

    .{
        .name = "evidence-v1",
        .path = "schemas/evidence-v1.schema.json",
        .id = "https://zmr.dev/schemas/evidence-v1.schema.json",
        .description = "Platform-neutral Zeno Evidence Contract v1 manifest",
    },

- [ ] Document the schema in schemas/README.md.

State that evidence-v1 is the cross-runner evidence package contract, while trace-manifest remains the ZMR-internal trace summary.

- [ ] Run the focused and registry tests.

Run:

    node --test tests/evidence-contract.test.mjs
    zig test src/test_harness.zig
    zig build
    bash tests/schemas-json-test.sh

Expected: all PASS and zmr schemas --json reports count 25.

- [ ] Commit Task 1.

    git add schemas/evidence-v1.schema.json schemas/README.md tests/evidence-contract.test.mjs src/schema_registry.zig src/schema_registry_tests.zig tests/schemas-json-test.sh
    git commit -m "feat: publish Evidence Contract v1 schema"

## Task 2: Implement canonical JSON, digests, and exact fingerprints

**Files:**

- Create: npm/evidence/canonical-json.mjs
- Create: npm/evidence/fingerprints.mjs
- Modify: tests/evidence-contract.test.mjs

- [ ] Add failing canonicalization and safety tests.

Cover:

- object keys sort deterministically at every depth;
- UTF-8 output is stable;
- arrays preserve order;
- -0 serializes as 0;
- non-finite numbers, BigInt, undefined, functions, symbols, cyclic values, non-plain objects, and lone Unicode surrogates are rejected;
- sha256Bytes and sha256File return lower-case prefixed digests;
- safeRelativePath accepts artifacts/final.png and rejects raw paths with empty, `.` or `..` segments before any normalization;
- safeRelativePath rejects absolute POSIX paths, Windows drive paths, backslashes, empty segments, dot segments, parent segments, NUL, and control characters.

Core assertions:

    assert.equal(
      canonicalize({z: 1, a: {d: 4, b: 2}}),
      "{\"a\":{\"b\":2,\"d\":4},\"z\":1}"
    );
    assert.equal(
      sha256Bytes(Buffer.from("abc")),
      "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );

- [ ] Add failing known-vector fingerprint tests.

Call createMobileFingerprint and createWebFingerprint with the exact recipe inputs in “Non-negotiable contract decisions” and assert the two expected fingerprints verbatim.

Also test:

- a missing field throws a field-specific EvidenceValidationError;
- whitespace-only strings are rejected;
- digest input must already be lower-case sha256 form;
- surface ios works with mobile-v1;
- extra fields do not enter the canonical recipe;
- changing one required input changes the fingerprint.
- registered targets are identified exactly, while an unknown recipe is retained as unregistered and never recomputed.

- [ ] Run the focused test and see missing-module failures.

    node --test tests/evidence-contract.test.mjs

Expected: FAIL because canonical-json.mjs and fingerprints.mjs do not exist.

- [ ] Implement primitive validation and serialization in canonical-json.mjs.

Export:

    canonicalize(value)
    canonicalBytes(value)
    sha256Bytes(value)
    sha256File(path)
    isSha256Digest(value)
    assertSafeRelativePath(value, fieldName = "path")

Canonicalization must recursively serialize null, booleans, finite numbers, well-formed strings, arrays, and plain objects.

- [ ] Add recursive array/object handling and cycle detection.

Sort object keys with JavaScript UTF-16 lexical ordering, matching RFC 8785 property ordering. Use JSON.stringify for primitive string and number serialization after validation. Detect cycles with a Set that is removed again when recursion leaves a container.

Do not use JSON.stringify(object, sortedKeys), because a global replacer array drops nested keys that are absent from the top-level key list.

- [ ] Add canonicalBytes, SHA-256 byte/file helpers, and safe relative-path validation.

Use createHash from node:crypto and streaming file reads. Return only lower-case sha256: digests.

- [ ] Implement the two closed recipe input builders in fingerprints.mjs.

Export:

    buildMobileFingerprintInput(input)
    buildWebFingerprintInput(input)
    createMobileFingerprint(input)
    createWebFingerprint(input)
    isRegisteredTarget(target)
    recomputeTargetFingerprint(target)

Each builder returns a fresh object containing only the recipe fields in this plan. validateRequiredString must preserve exact values after rejecting empty/whitespace-only strings; it must not trim and silently change identity.

- [ ] Implement recipe dispatch, hashing, and unknown-recipe errors.

createMobileFingerprint and createWebFingerprint must be equivalent to:

    "sha256:" + createHash("sha256")
      .update(canonicalBytes(recipeInput))
      .digest("hex")

isRegisteredTarget returns true only for the exact registered surface/recipe pairs: ios or android with mobile-v1, and web with web-v1. recomputeTargetFingerprint dispatches only on those registered pairs and rejects unknown recipes. The contract validator uses isRegisteredTarget before recomputation; unregistered targets are structurally valid only with fingerprintVerification unregistered_recipe and remain non-qualifying context.

- [ ] Run the focused tests.

    node --test tests/evidence-contract.test.mjs

Expected: PASS.

- [ ] Commit Task 2.

    git add npm/evidence/canonical-json.mjs npm/evidence/fingerprints.mjs tests/evidence-contract.test.mjs
    git commit -m "feat: add deterministic evidence fingerprints"

## Task 3: Build semantic validation and deterministic package writing

**Files:**

- Create: npm/evidence/contract.mjs
- Create: npm/evidence/package-writer.mjs
- Create: tests/evidence-package.test.mjs
- Create: tests/evidence-conformance.test.mjs
- Create: tests/evidence-json-schema-conformance.test.mjs
- Create: fixtures/evidence/v1/README.md
- Create: fixtures/evidence/v1/cases.json
- Create: fixtures/evidence/v1/manifests/zeno-passed.json
- Create: fixtures/evidence/v1/manifests/zeno-failed.json
- Create: fixtures/evidence/v1/manifests/zeno-partial.json
- Create: fixtures/evidence/v1/manifests/playwright-passed.json
- Create: fixtures/evidence/v1/manifests/playwright-retry-pass.json
- Create: fixtures/evidence/v1/manifests/unregistered-target.json
- Create: fixtures/evidence/v1/manifests/missing-optional-artifacts.json
- Create: fixtures/evidence/v1/manifests/redacted-omitted-screenshot.json
- Create: fixtures/evidence/v1/invalid/missing-target-fingerprint.json
- Create: fixtures/evidence/v1/invalid/empty-project-id.json
- Create: fixtures/evidence/v1/invalid/whitespace-journey-id.json
- Create: fixtures/evidence/v1/invalid/unknown-schema-version.json
- Create: fixtures/evidence/v1/invalid/malformed-manifest.json
- Create: fixtures/evidence/v1/invalid/malicious-artifact-path.json
- Create: fixtures/evidence/v1/invalid/artifact-digest-mismatch/evidence.json
- Create: fixtures/evidence/v1/invalid/artifact-digest-mismatch/artifacts/actual.txt
- Create: fixtures/evidence/v1/sources/playwright/passed.json
- Create: fixtures/evidence/v1/sources/playwright/retry-pass.json

- [ ] Add failing manifest validation tests.

Use a minimal valid manifest factory and public fixtures. Assert:

- a valid mobile manifest and valid web manifest return no issues;
- a valid unregistered target is retained with fingerprintVerification unregistered_recipe and is explicitly non-qualifying;
- missing project or self-reported submission identity fails;
- empty, whitespace-only, leading/trailing-whitespace, and control-character identities fail at their exact paths without trimming;
- unknown top-level or nested fields fail;
- missing targetFingerprint fails;
- a syntactically valid but incorrectly recomputed fingerprint fails at /target/targetFingerprint;
- endedAt before startedAt fails;
- item timestamps outside the enclosing run fail;
- a mobile item without device/OS identity fails;
- a browser item without browser name/version fails;
- unsafe artifact paths fail;
- duplicate artifact paths with different digests fail;
- attempt is never inferred;
- imported provenance remains legal in the public contract;
- extensions require namespaced keys;
- an empty items array fails.

Use this result shape:

    {
      ok: false,
      issues: [
        {
          path: "/target/targetFingerprint",
          code: "fingerprint_mismatch",
          message: "targetFingerprint does not match web-v1 inputs"
        }
      ]
    }

- [ ] Run the test and see it fail.

    node --test tests/evidence-package.test.mjs

Expected: FAIL because contract.mjs does not exist.

- [ ] Implement contract constants, EvidenceValidationError, and issue collection.

Export:

    EVIDENCE_SCHEMA_VERSION
    EVIDENCE_OUTCOMES
    PROVENANCE_CLASSES
    ATTESTATION_STATES
    REDACTION_STATES
    EvidenceValidationError
    validateEvidenceManifest(manifest)
    assertValidEvidenceManifest(manifest)
    stableSortManifest(manifest)
    isQualifyingTarget(target)

- [ ] Implement strict recursive shape/type/enum validation matching the public schema.

Unknown properties must produce deterministic unexpected_property issues at their JSON Pointer paths.

- [ ] Add cross-field semantic validation.

The runtime validator mirrors the public schema and adds semantic rules JSON Schema cannot safely enforce:

- recompute and compare the exact target fingerprint;
- require registered targets to use fingerprintVerification recomputed; accept an unknown surface/recipe only through the unregistered branch with fingerprintVerification unregistered_recipe, and make isQualifyingTarget return false for it;
- enforce the exact `$defs.identity` rule across every identity-bearing field without trimming or normalization;
- compare RFC3339 timestamps and require endedAt at or after startedAt;
- require each item interval to be inside its run interval and durationMs to match the interval within one millisecond;
- require mobile targets to contain mobile execution items, web targets to contain browser execution items, and unregistered targets to contain only unregistered execution items;
- require passed/skipped items to use failureClassification null and non-passing terminal items to use a non-null classification;
- reject unsafe artifact paths;
- require unique item identity as externalId plus attempt;
- reject conflicting duplicate artifact paths;
- require web target.commitSha to equal release.commitSha;
- preserve unknown future source details only under extensions.

Return all safe-to-report issues in deterministic path/code order. Do not throw on the first ordinary validation issue. assertValidEvidenceManifest throws EvidenceValidationError containing the ordered issue array.

The validator accepts all attestation states in the public v1 schema so future signed producers remain contract-compatible. The two adapters implemented here are separately tested to emit unattested only.

- [ ] Implement stableSortManifest without mutating caller-owned values.

stableSortManifest must:

- keep semantic arrays such as titlePath unchanged inside extensions;
- sort items by externalId, then attempt, then scenarioHash;
- sort each item’s artifacts by path, then digest;
- sort every object’s keys recursively through canonical JSON, producing deterministic pretty evidence.json bytes without mutating caller-owned objects.

- [ ] Add failing package-writer tests.

Test in temporary directories:

- two equal artifact bodies are copied once and both references use the same relative path;
- different files with the same basename cannot collide;
- reversing artifact input order produces byte-identical evidence.json and paths;
- two synthetic valid digests that share the first 12 hex characters but differ later map to different full-digest paths;
- an attachment body and a source file both work;
- output evidence.json is pretty-printed with a final newline;
- the returned manifestDigest equals the digest of canonical manifest bytes;
- writing uses a sibling temporary directory and leaves no partial destination after a forced error;
- an existing destination fails unless force is true;
- source symlinks, symlinked intermediate components, and paths outside each input's allowedRoot are rejected;
- package validation rejects a symlinked `artifacts/` directory that points outside the package;
- both file and body inputs over 128 MiB are rejected before publication;
- public artifact paths contain the complete digest and never depend on the original basename or input order;
- validateEvidencePackage catches changed bytes and changed size.

- [ ] Implement artifact input normalization and allowed-root enforcement.

Export:

    writeEvidencePackage({destination, manifest, artifactInputs, force = false})
    validateEvidencePackage(manifestPath)
    artifactPathForDigest(digest)

Adapters return:

    {
      manifest,
      artifactInputs: [
        {
          itemIndex: 0,
          sourcePath AND allowedRoot, OR body,
          type,
          contentType,
          redactionState,
          disclosureState
        }
      ]
    }

manifest items initially contain empty artifacts arrays. writeEvidencePackage deep-clones the manifest, resolves every artifact input by itemIndex, copies and digests the bytes, appends the resulting public descriptor to that item, then stable-sorts and validates the complete clone. It never mutates the adapter-owned draft.

Artifact input is one of:

    {
      itemIndex, sourcePath, allowedRoot, type, contentType,
      redactionState, disclosureState
    }

    {
      itemIndex, body, type, contentType,
      redactionState, disclosureState
    }

For sourcePath:

- realpath both allowedRoot and the source;
- require the source realpath to be inside allowedRoot;
- lstat every path component below allowedRoot and reject any symbolic link, not merely a symlink at the selected leaf;
- enforce a 128 MiB per-artifact limit in v1.

For body, accept Buffer or Uint8Array only and enforce the same 128 MiB limit before copying or hashing. The writer API has no ambient collector root: every file input carries the precise allowedRoot that authorized it.

- [ ] Implement content digesting, deduplication, and collision-safe destination names.

Derive destination paths solely from the full digest, never a basename, artifact order, or truncated digest:

    sha256:<64 hex> -> artifacts/sha256/<first 2 hex>/<remaining 62 hex>

The full digest is the deduplication key and identical bytes share the same path. Copy or write exact bytes, then verify the destination digest before publishing evidence.json.

artifactPathForDigest is a small deterministic utility used by the writer and directly tested with synthetic same-prefix digests; it performs no filesystem access.

- [ ] Implement complete-manifest assembly and validation after artifact collection.

Deep-clone the adapter draft, attach descriptors by itemIndex, stable-sort, validate, and compute the canonical manifest digest.

- [ ] Implement atomic destination publication and force rollback.

Write to destination plus a random .tmp- suffix in the same parent, fsync evidence.json, then rename atomically. With force, rename the prior destination to a temporary backup, publish the new directory, and remove the backup only after success; restore it on failure.

- [ ] Implement validateEvidencePackage byte, size, path, and symlink checks.

validateEvidencePackage reads evidence.json, validates the manifest, realpaths the package root, lstats every artifact path component before following it, rejects symlinks including an `artifacts/` directory symlink, realpaths the final regular file and requires containment under the package root, then checks exact size and SHA-256 digest. Add an explicit test where `artifacts` points outside the package.

- [ ] Create the public case catalog and shared conformance harness.

fixtures/evidence/v1/cases.json is data, not executable code. Each case records:

    id
    kind
    input
    expectedSchemaValid
    expectedSemanticValid
    expectedPackageValid
    expectedAdapterValid
    expectedIssueCodes
    adapter
    phase

tests/evidence-conformance.test.mjs iterates this catalog and routes manifest/package cases through the handwritten semantic validator. Tar-security cases use the versioned malicious path/type/size values from cases.json to construct archives in a temporary directory. This keeps malicious binary blobs out of git while making their exact inputs versioned.

tests/evidence-json-schema-conformance.test.mjs is the independent public-schema gate. In a temporary directory outside the repository it writes a minimal package.json and installs exactly `ajv@8.20.0` and `ajv-formats@3.0.1` with `--ignore-scripts --no-save --no-package-lock`. Use createRequire rooted at that temporary package to load `ajv/dist/2020` and `ajv-formats`, compile schemas/evidence-v1.schema.json as Draft 2020-12, and validate every catalogued manifest fixture. For every fixture, assert the actual JSON Schema result against expectedSchemaValid and validateEvidenceManifest against expectedSemanticValid; for semantic-invalid cases, also assert the handwritten issue codes from cases.json. A package-byte tamper case can therefore be schema-valid and semantic-manifest-valid while expectedPackageValid is false. The temporary validator packages are test tooling only: do not add a repository dependency or package-lock.json, and always remove the temporary directory.

The harness must cover in this plan:

- valid, failed, partial, missing-artifact, redacted, and omitted-screenshot ZMR cases;
- valid Playwright and retry/flaky manifest cases;
- a valid unknown-surface/unregistered-recipe manifest retained as non-qualifying context;
- serializable zeno-playwright-reporter-fixture-v1 event sets for passed and retry/flaky lifecycle tests;
- missing target identity;
- empty and whitespace identity cases across public fixtures and adapter-produced drafts;
- unknown schema version;
- a syntactically valid JSON value with malformed manifest structure/types;
- malicious manifest and archive paths;
- artifact digest mismatch;
- missing optional artifacts.

Use null only when a validation layer is genuinely not applicable, and require every case in phase evidence-contract-v1 to have a non-null expectation for each applicable layer. JUnit and CTRF cases are listed with phase generic-import-v1 and all not-yet-applicable expectations null so the catalog makes the pre-MVP obligation visible. Task 2 of the program must add source files, adapters, and executable expectations before the MVP conformance gate can be called complete.

- [ ] Create and document public conformance fixtures.

fixtures/evidence/v1/README.md must label each fixture as valid or intentionally invalid and explain that fixture bytes are versioned API surface.

All valid manifest fixtures must pass both the compiled Draft 2020-12 schema and validateEvidenceManifest. The Playwright retry fixture must contain two attempts for the same externalId and mark expectedStatus, projectName, and aggregate source classification as source-specific values only under the `dev.playwright.test` namespaced extension.

Each invalid fixture must fail with exactly the issue codes declared in cases.json. missing-target-fingerprint.json must fail only for the documented missing fingerprint/required identity errors.

- [ ] Run contract and package tests.

    node --test tests/evidence-contract.test.mjs tests/evidence-package.test.mjs tests/evidence-conformance.test.mjs tests/evidence-json-schema-conformance.test.mjs

Expected: PASS.

- [ ] Commit Task 3.

    git add npm/evidence/contract.mjs npm/evidence/package-writer.mjs tests/evidence-package.test.mjs tests/evidence-conformance.test.mjs tests/evidence-json-schema-conformance.test.mjs fixtures/evidence/v1
    git commit -m "feat: validate and package release evidence"

## Task 4: Read ZMR traces through a hardened ingestion boundary

**Files:**

- Create: npm/evidence/tar.mjs
- Create: npm/evidence/zmr-adapter.mjs
- Create: tests/evidence-zmr-adapter.test.mjs
- Create: fixtures/evidence/v1/sources/zmrtrace/passed/scenario.json
- Create: fixtures/evidence/v1/sources/zmrtrace/passed/trace.json
- Create: fixtures/evidence/v1/sources/zmrtrace/passed/events.jsonl
- Create: fixtures/evidence/v1/sources/zmrtrace/passed/artifacts/final.txt
- Create: fixtures/evidence/v1/sources/zmrtrace/failed/trace.json
- Create: fixtures/evidence/v1/sources/zmrtrace/failed/events.jsonl
- Create: fixtures/evidence/v1/sources/zmrtrace/partial/trace.json
- Create: fixtures/evidence/v1/sources/zmrtrace/partial/events.jsonl
- Create: fixtures/evidence/v1/sources/zmrtrace/redacted/trace.json
- Create: fixtures/evidence/v1/sources/zmrtrace/redacted/events.jsonl
- Create: fixtures/evidence/v1/sources/zmrtrace/redacted/artifacts/snapshot.json

- [ ] Add failing hardened tar tests.

Reuse or extract the small makeTar helper pattern from tests/viewer-parser.test.mjs. Test:

- a valid current ZMR ustar archive returns deterministic regular-file entries;
- name plus prefix is handled;
- checksum corruption fails;
- truncation fails;
- duplicate paths fail;
- /absolute, ../escape, nested/../../escape, Windows drives, backslashes, NUL/control characters fail;
- malicious USTAR prefixes plus raw `safe/../file`, `./file`, and `a//b` paths fail before normalization;
- symlink, hard link, device, FIFO, and unsupported PAX entry types fail;
- more than 10,000 entries fails;
- one entry over 128 MiB fails without allocation;
- total accepted content over 512 MiB fails;
- trailing non-zero bytes after the end marker fail.

Do not change viewer/parser.js. It remains a browser presentation parser, not an ingestion security boundary.

- [ ] Run the focused test and see it fail.

    node --test tests/evidence-zmr-adapter.test.mjs

Expected: FAIL because tar.mjs does not exist.

- [ ] Implement ustar header parsing, octal size parsing, and checksum validation.

Export:

    parseZmrTar(buffer, limits = DEFAULT_TAR_LIMITS)

Return:

    [{path, body, sizeBytes, contentType}]

Requirements:

- accept only regular file typeflags NUL and 0;
- validate the ustar checksum with the checksum field treated as spaces;
- parse octal sizes without precision loss and reject malformed/base-256 values;
- strip only field-padding NUL bytes and reject embedded NUL/control bytes in name or prefix;
- validate bounds before slicing;

- [ ] Add archive path/type/duplicate validation.

- reject unsupported entry types before reading their bodies;
- combine a non-empty USTAR prefix and name with one literal `/`; do not call path.posix.join or normalize before validation because normalization can erase `..`, `.`, and empty segments;
- validate the raw combined string through assertSafeRelativePath, requiring a canonical path with no empty, `.` or `..` segment, then retain that exact validated string;
- reject duplicate accepted paths.

- [ ] Add entry-count, per-entry, cumulative-size, truncation, and end-marker limits.

- validate bounds before slicing;
- enforce entry count, individual size, and cumulative size before copying;
- require a valid end-of-archive marker;
- infer content type only from a small explicit extension map and default to application/octet-stream.

- [ ] Add failing ZMR directory and archive adaptation tests.

Build public passed, failed, partial, and redacted fixtures plus temporary incomplete, mismatched, malformed JSONL, and unsafe cases. Assert:

- directory and archive inputs with identical entries produce the same sourceManifestDigest;
- schemaVersion must be exactly 1;
- trace.json, its declared eventsPath, and a terminal scenario.end event are required;
- eventCount must equal the number of parsed JSONL rows and exactly one scenario.end event is allowed;
- endedAtMs must be present;
- durationMs must equal endedAtMs minus startedAtMs;
- trace status passed/failed must match the terminal status;
- manifest partial remains partial even when terminal status is passed and partialFailureCount is positive;
- malformed JSONL is rejected, not converted to a synthetic parse-error event;
- a non-null appId in trace must match the explicit --app-id identity, while the trace-v1-legal null appId is accepted and the explicit app identity remains authoritative;
- projectId, submitterType, and submitterId are preserved as self-reported context;
- journeyId is required;
- itemId is required, preserved verbatim as the stable source item identity, and rejects empty/whitespace values without trimming;
- scenarioPath canonical JSON and explicit scenarioHash are mutually exclusive and either one is required;
- changing scenario bytes changes scenarioHash but never changes the supplied itemId/externalId;
- artifacts retain exact bytes and digests;
- raw artifacts are unreviewed;
- redaction.enabled artifacts are redacted and redaction/omission metadata is retained under dev.zmr.trace;
- producer is zeno-mobile-runner, version comes from trace.runnerVersion, adapterVersion is 1.0.0, provenance is zeno_runner, and attestation is unattested;
- the item contains explicit deviceName, osName, and osVersion;
- the item timing equals the completed single-scenario run timing;
- trace partial maps run completenessState partial; passed/failed completed traces map complete;
- every emitted artifact has a semantic type and disclosureState private;
- target fingerprint uses the provided app artifact bytes plus app ID, version, build number, and surface.

- [ ] Implement safe trace-directory and .zmrtrace loading.

Export:

    loadZmrTrace(inputPath)
    adaptZmrTrace(options)

options requires:

    tracePath
    projectId
    submitterType
    submitterId
    releaseId
    commitSha
    surface
    appArtifactPath
    appId
    appVersion
    buildNumber
    environment
    journeyId
    itemId
    runId
    deviceName
    osName
    osVersion
    scenarioPath OR scenarioHash

surface accepts only ios or android. submitterType accepts user or automation. All identity and execution-environment strings are required and must satisfy the contract identity definition without trimming.

For a directory:

- read trace.json and declared eventsPath;
- walk only the declared artifactsDir;
- reject unsafe declared eventsPath, artifactsDir, and reportPath values;
- reject symlinks and enforce the same file-count/size limits as archives;
- create an in-memory list of accepted relative paths and bytes.

For .zmrtrace, reject a source file over 512 MiB before reading it, then use parseZmrTar.

- [ ] Implement trace schema, JSONL, timestamp, and terminal consistency checks.

Reject running/incomplete traces, malformed event rows, and contradictions before constructing a manifest.

- [ ] Implement source entry indexing and sourceManifestDigest.

Compute sourceManifestDigest from canonical JSON of all accepted entries sorted by path:

    [
      {"path": "artifacts/final.txt", "digest": "sha256:...", "sizeBytes": 5},
      {"path": "events.jsonl", "digest": "sha256:...", "sizeBytes": 421},
      {"path": "trace.json", "digest": "sha256:...", "sizeBytes": 388}
    ]

This makes archive and directory input equivalent.

- [ ] Implement exact mobile target, run, item, and scenario mapping.

Convert startedAtMs and endedAtMs with new Date(value).toISOString(). Map the trace to one evidence item and use runId verbatim as run.externalId. Never derive a run identity from scenarioName.

The scenario hash is either the validated explicit digest or SHA-256 of canonical parsed scenario JSON.

Set item.externalId exactly to the required itemId option, verbatim. This is the caller's stable source item identity and must remain unchanged when scenario bytes or scenarioHash change. journeyId and scenarioHash remain separate coverage coordinates and must not be folded into externalId.

Set attempt to 0. A CI retry is a separate ZMR evidence run with its own runId; v1 does not collapse separate trace packages into attempts.

Set item.startedAt, item.endedAt, and item.durationMs from the trace manifest. execution is the mobile branch containing the explicit deviceName, osName, and osVersion. failureClassification is null for passed, timeout when the terminal error name contains Timeout, and unknown for other failed/partial results; do not guess assertion, application, or infrastructure from an unfamiliar error name.

Set run.completenessState to partial when the effective trace outcome is partial, otherwise complete. Set run.redactionState from the aggregate emitted artifact states.

adaptZmrTrace returns {manifest, artifactInputs}. It attaches exact trace.json, events.jsonl, the declared report when present, every accepted file under artifactsDir, and scenarioPath bytes when a scenario file was supplied. Directory-origin file inputs carry the trace directory or scenario parent as their exact allowedRoot; archive-origin entries use bounded in-memory body inputs. Trace-origin files are redacted only when the existing trace redaction metadata says automated redaction was enabled; otherwise they are unreviewed. The separately supplied scenario source is always unreviewed because the trace redactor did not process it. All local artifacts use disclosureState private, and the run aggregate becomes mixed when states differ.

Assign semantic artifact types deterministically:

- trace.json: trace_manifest;
- events.jsonl: event_log;
- declared HTML report: report;
- supplied scenario file: scenario_source;
- PNG/JPEG: screenshot;
- MP4/WebM: video;
- snapshot JSON/XML: ui_snapshot;
- any other declared trace artifact: zmr_artifact.

- [ ] Add app artifact streaming, redaction metadata, and artifact-input assembly.

appArtifactPath is hashed to construct mobile-v1 but is not copied into the evidence package. Resolve it as a regular file and stream its digest so normal mobile binary sizes do not consume one in-memory buffer. Likewise, never include absolute app-artifact or scenario paths in the manifest.

- [ ] Run the focused tests.

    node --test tests/evidence-zmr-adapter.test.mjs

Expected: PASS.

- [ ] Commit Task 4.

    git add npm/evidence/tar.mjs npm/evidence/zmr-adapter.mjs tests/evidence-zmr-adapter.test.mjs fixtures/evidence/v1/sources
    git commit -m "feat: adapt hardened ZMR traces to evidence"

## Task 5: Add the zmr-evidence CLI and npm package surface

**Files:**

- Create: npm/evidence-cli.mjs
- Create: tests/evidence-cli.test.mjs
- Modify: package.json
- Modify: tests/npm-package.test.mjs

- [ ] Add failing CLI tests.

Spawn the CLI with process.execPath and assert:

- no command prints concise usage to stderr and exits 2;
- an unknown command exits 2;
- from-zmr with a complete mobile identity creates evidence.json and artifacts/;
- from-zmr accepts either --scenario or --scenario-hash, not both;
- every required identity option has an actionable missing-option error;
- empty, whitespace-only, leading/trailing-whitespace, and control-character CLI identities are rejected without silently trimming them;
- validate on a valid package prints a one-line JSON success object and exits 0;
- validate after artifact tampering prints a JSON error object and exits 1;
- a failed command leaves stdout empty and uses stderr only;
- --force replaces a complete existing destination without exposing a partial directory;
- help exits 0.

The successful stdout shape is:

    {
      "ok": true,
      "command": "from-zmr",
      "output": "/absolute/path/used/by/the-caller",
      "manifestDigest": "sha256:...",
      "items": 1,
      "artifacts": 1
    }

The error shape is:

    {
      "ok": false,
      "error": {
        "code": "missing_option",
        "message": "--project-id is required",
        "issues": []
      }
    }

Absolute paths are acceptable in local CLI stdout/stderr, but never in evidence.json.

- [ ] Run the CLI test and see it fail.

    node --test tests/evidence-cli.test.mjs

Expected: FAIL because npm/evidence-cli.mjs does not exist.

- [ ] Implement usage text, command selection, and strict option parsing.

Use a Node shebang and built-in modules only. Support:

    zmr-evidence from-zmr \
      --trace traces/checkout.zmrtrace \
      --scenario scenarios/checkout.json \
      --project-id client-shop \
      --submitter-type automation \
      --submitter-id github-actions:agency/shop:run-1842 \
      --release-id rel_2026_07_13 \
      --commit-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      --surface android \
      --app-artifact app-release.apk \
      --app-id com.example.app \
      --app-version 1.2.3 \
      --build-number 42 \
      --environment staging \
      --journey-id checkout.guest \
      --item-id checkout.guest.android \
      --run-id ci_1842 \
      --device-name "Pixel 9" \
      --os-name Android \
      --os-version 16 \
      --out zeno-evidence

And:

    zmr-evidence validate zeno-evidence/evidence.json

from-zmr flow:

1. Parse arguments without coercing identity strings.
2. Call adaptZmrTrace.
3. Pass its manifest draft and artifact inputs to writeEvidencePackage.
4. Print exactly one compact JSON result line.

- [ ] Implement from-zmr orchestration and success output.

Pass all required identity strings verbatim and rely on the adapter for semantic validation.

- [ ] Implement validate orchestration and package-byte verification.

validate flow calls validateEvidencePackage, including sibling artifact bytes.

- [ ] Implement top-level error sanitization and exit codes.

Exit codes:

- 0: success or help;
- 1: invalid source, evidence, digest, package, or destination;
- 2: CLI usage error.

Catch expected errors at the top-level only. Never print a stack trace unless ZENO_EVIDENCE_DEBUG=1. Do not include file contents or secrets in errors.

- [ ] Mark npm/evidence-cli.mjs executable and test the shebang.

    chmod +x npm/evidence-cli.mjs
    test -x npm/evidence-cli.mjs

- [ ] Add package metadata tests before modifying package.json.

In tests/npm-package.test.mjs assert:

    pkg.bin["zmr-evidence"] === "npm/evidence-cli.mjs"
    pkg.files includes "fixtures/evidence/"
    pkg.scripts["test:evidence"] exists

In the npm pack dry-run assertions require:

    npm/evidence-cli.mjs
    npm/evidence/contract.mjs
    schemas/evidence-v1.schema.json
    fixtures/evidence/v1/README.md
    fixtures/evidence/v1/manifests/zeno-passed.json

- [ ] Run the package metadata test and see it fail.

    node --test tests/npm-package.test.mjs

Expected: FAIL because zmr-evidence and fixtures/evidence/ are not published.

- [ ] Update package.json without adding runtime dependencies.

Add:

    "zmr-evidence": "npm/evidence-cli.mjs"

to bin.

Add:

    "fixtures/evidence/"

to files.

Add:

    "test:evidence": "node --test tests/evidence-contract.test.mjs tests/evidence-package.test.mjs tests/evidence-conformance.test.mjs tests/evidence-json-schema-conformance.test.mjs tests/evidence-zmr-adapter.test.mjs tests/evidence-cli.test.mjs"

and call npm run test:evidence after build:zmr and before the existing Node test list in test.

Use the explicit file list for Node 18 and Windows compatibility; do not rely on shell glob expansion. The JSON Schema conformance test provisions its pinned Ajv tooling only in a disposable temporary consumer, so package.json remains dependency-free and no repository lockfile appears.

Do not add a package-lock.json. Do not change the package name or version in this implementation slice.

- [ ] Run CLI and packaging tests.

    node --test tests/evidence-cli.test.mjs
    node --test tests/npm-package.test.mjs
    npm pack --dry-run --json

Expected: PASS; the dry-run includes the evidence modules, schema, docs already included by docs/, and public fixtures, but excludes tests.

- [ ] Commit Task 5.

    git add npm/evidence-cli.mjs tests/evidence-cli.test.mjs package.json tests/npm-package.test.mjs
    git commit -m "feat: ship the zmr-evidence CLI"

## Task 6: Produce web evidence through a supported Playwright reporter

**Files:**

- Create: npm/evidence/playwright-reporter.mjs
- Create: npm/evidence/playwright-reporter.d.ts
- Create: tests/evidence-playwright-reporter.test.mjs
- Create: tests/packed-evidence-smoke.mjs
- Create: examples/playwright-zeno-reporter.config.ts
- Create: examples/playwright-zeno-journey.spec.ts
- Modify: package.json
- Modify: tests/npm-package.test.mjs

- [ ] Add failing reporter lifecycle tests with API-shaped fakes.

Do not install Playwright for unit tests. Construct minimal objects matching the documented Reporter, TestCase, TestResult, Suite, FullConfig, and FullResult members used by the implementation.

Load fixtures/evidence/v1/sources/playwright/passed.json and retry-pass.json and translate their documented zeno-playwright-reporter-fixture-v1 records into those API-shaped fakes. These are Zeno conformance fixtures, not Playwright’s private JSON reporter format.

Cover:

- printsToStdio returns false;
- onBegin records config.rootDir and validates target options;
- onTestEnd records every retry attempt;
- onEnd is async and does not resolve until evidence.json and artifacts are durable;
- a reporter packaging error is caught and returns {status: "failed"} so Playwright exits unsuccessfully instead of swallowing the reporter failure;
- result status passed, failed, timedOut, skipped, and interrupted map to contract outcomes;
- TestCase.expectedStatus is preserved only under dev.playwright.test;
- TestCase.outcome flaky is retained in dev.playwright.test;
- an expected-to-fail test with an actual failed result remains failed;
- a failed first attempt and passed retry produce attempts 0 and 1, plus flaky source classification;
- test.id is hashed into a run-scoped externalId and is never used as the stable journey ID;
- a zeno:journey annotation maps journeyId;
- missing journey annotation produces journeyId null and mappingState unmapped, never an inferred title;
- an explicit journeyMap entry keyed by playwrightJourneyKey overrides an annotation only when documented and tested;
- projectName comes from Suite.project().name and is serialized only under dev.playwright.test;
- browserName and browserVersion come only from reporter options or explicit project metadata, never by parsing projectName;
- project and self-reported submitter identity are present;
- every reporter identity option and derived execution identity obeys the shared no-trim identity rule; empty/whitespace/control values fail closed;
- each item exposes start/end/duration, failureClassification, and a browser execution object;
- full passed/failed runs are complete; timedout/interrupted runs are partial;
- a path attachment and a body attachment are copied and digested;
- each attachment has a semantic type, redactionState unreviewed, and disclosureState private;
- an attachment outside artifactRoot or through a symlink is rejected;
- scenarioHash changes when the test file bytes or titlePath change;
- targetFingerprint is the exact web-v1 fingerprint;
- producer is playwright, version comes from FullConfig.version, adapterVersion is 1.0.0, provenance is official_adapter, and attestation is unattested;
- output contains no absolute test or attachment paths.
- Windows-style root/file pairs serialize a safe POSIX relativeFile, while another drive, sibling-prefix root, or `..` escape fails closed; exercise this with `path.win32` semantics even on non-Windows CI.
- a value-only Playwright TestError becomes error.message, and Unix/Windows absolute paths plus token/Bearer-secret examples are redacted from the stored message.

- [ ] Run the reporter test and see it fail.

    node --test tests/evidence-playwright-reporter.test.mjs

Expected: FAIL because playwright-reporter.mjs does not exist.

- [ ] Implement reporter construction, option normalization, and printsToStdio.

Export a default class with:

    constructor(options)
    onBegin(config, suite)
    onTestEnd(test, result)
    async onEnd(fullResult)
    printsToStdio()

Do not parse Playwright’s private or built-in JSON report shape. Do not import @playwright/test at runtime.

Reporter options:

    {
      outputDir,
      projectId,
      submitterType,
      submitterId,
      releaseId,
      commitSha,
      deploymentId,
      environment,
      configDigest,
      buildManifestDigest OR buildManifestPath,
      runId,
      artifactRoot,
      browserName,
      browserVersion,
      journeyAnnotation = "zeno:journey",
      journeyMap = {}
    }

Required:

- outputDir;
- projectId;
- submitterType user or automation;
- submitterId;
- releaseId;
- a full lower-case commitSha;
- deploymentId;
- environment;
- configDigest;
- exactly one of buildManifestDigest or buildManifestPath.

runId, artifactRoot, browserName, browserVersion, and journey mapping options are optional at the reporter level. Resolve relative buildManifestPath, artifactRoot, and outputDir against config.rootDir. If buildManifestPath is used, hash its exact bytes. artifactRoot defaults to config.rootDir.

Every project that emits an item must resolve both browserName and browserVersion. Use reporter-level values as fallbacks; otherwise read exact strings from FullProject.metadata.zenoEvidence.browserName and browserVersion. If either remains missing, fail evidence generation. Never infer either from project.name, use.channel, or a user-agent string.

- [ ] Implement onBegin root, target, producer-version, and shard setup.

Read the current npm package version from package.json through import.meta.url and retain it under dev.zmr.adapter.packageVersion. Set producer.version from FullConfig.version and adapterVersion to the Evidence Adapter revision 1.0.0. Never emit unknown for producer or adapter versions.

- [ ] Implement stable Playwright test and scenario identity.

Before hashing or serializing a test file, resolve and compare config.rootDir and test.location.file with the matching path implementation. Use win32 semantics when both values are Windows-absolute (including in cross-platform unit fakes), otherwise use the native path implementation. Compute the native relative path, reject an absolute result, another drive, an empty result, or a first segment of `..`, and only after containment succeeds replace native separators with `/` and run assertSafeRelativePath. Never convert separators before checking containment.

Stable Playwright identity:

    scenarioHash = sha256(canonical({
      fileDigest,
      titlePath: test.titlePath()
    }))

    externalId = "playwright:" + sha256Bytes(
      Buffer.from(test.id, "utf8")
    ).slice("sha256:".length)

Do not expose the absolute test.location.file or raw test.id. relativeFile must be safe and relative to config.rootDir. externalId is run-scoped source identity; journeyId plus scenarioHash provide stable cross-run coverage identity.

Compute run.sourceManifestDigest from canonical JSON of sorted attempt source records containing externalId, attempt, actual result status, expectedStatus, startTime, durationMs, scenarioHash, and attachment name/contentType metadata. Evidence artifact bytes are covered separately by their artifact digests and by the final manifest digest.

- [ ] Implement explicit journey mapping and unmapped context.

Journey lookup order:

1. Exact journeyMap key returned by the named export playwrightJourneyKey({projectName, relativeFile, titlePath}).
2. The final annotation whose type exactly matches journeyAnnotation.
3. null with dev.playwright.test.mappingState set to unmapped.

playwrightJourneyKey returns canonicalize({projectName, relativeFile, titlePath}). Declare and test this helper so users never invent delimiter escaping.

- [ ] Implement onTestEnd attempt, status, error, and attachment capture.

Record each onTestEnd call as a separate draft item with result.retry as attempt. Expose result.startTime, calculated endedAt, duration, and normalized failureClassification on the item. Map timedOut to timeout, interrupted to interrupted, passed/skipped to null, and other failures to unknown unless a future explicit classifier supports them.

Copy result attachments only when they have a path or body. Every path input passes artifactRoot as its own allowedRoot; every body input remains subject to the same 128 MiB limit. Preserve contentType. The public custom-reporter API exposes attachment body as a Buffer; accept Buffer and reject undocumented body types. Set semantic type from content type: image/* is screenshot, video/* is video, application/zip is trace, and everything else is test_attachment. All Playwright artifacts are unreviewed and private in this local adapter.

When serializing result.error, set the strict core error.message to a bounded string selected as `result.error.message ?? result.error.value`. Pass it through one deterministic sanitizer that removes ASCII controls, replaces known Unix/Windows absolute root, test-file, and attachment paths with `<redacted-path>`, replaces case-insensitive Bearer credentials and `authorization`, `token`, `api_key`, `apikey`, `password`, or `secret` assignments with `<redacted-secret>`, then caps the result at 4096 code units. The Playwright reporter emits only error.message because Playwright 1.42's public TestError does not define a name. Never emit value as a separate field, and never serialize stack, snippet, location, or other undocumented error fields. A run with zero completed TestResult items does not produce a valid evidence package and must take the fail-closed reporter path.

- [ ] Implement onEnd aggregate metadata, run identity, and package publication.

At onEnd:

1. Derive aggregate classification from test.outcome() for each retained TestCase.
2. Fill dev.playwright.test with sourceTestIdDigest, titlePath, location, projectName, expectedStatus, aggregateOutcome, and mappingState. Location contains only relativeFile, line, and column; raw test.id is not serialized. Do not duplicate projectName or expectedStatus into the neutral item core.
3. Compute run startedAt from FullResult.startTime.
4. Compute endedAt from FullResult.startTime plus FullResult.duration.
5. Use explicit runId when supplied; otherwise derive a digest ID from target fingerprint plus sorted attempt identities and timestamps.
6. Map FullResult.status passed, failed, timedout, and interrupted to the run outcome without overwriting item outcomes.
7. Set completenessState to complete for passed/failed and partial for timedout/interrupted. Set redactionState to unreviewed unless artifact aggregation requires mixed.
8. When config.shard is present, append shard-current-of-total to outputDir and retain the shard tuple under dev.playwright.run.
9. Call writeEvidencePackage and await it.

- [ ] Implement fail-closed reporter error handling.

Playwright documents that reporter errors are swallowed. Every reporter callback must therefore catch its own expected failures and retain a sanitized fatal error. onEnd checks retained errors and wraps package generation in try/catch. On any evidence-generation failure it writes a small evidence-error.json beside the intended output when safe, writes one sanitized stderr line, and returns {status: "failed"} to override the test-run status. On success it returns undefined. Add a unit test for this exact failure path.

The constructor must not throw for an expected missing/invalid option; retain that validation failure so onEnd can return failed. Unexpected module-load failures may still prevent Playwright configuration from loading, which already fails the command.

printsToStdio returns false.

- [ ] Add complete TypeScript declarations.

playwright-reporter.d.ts may use import type from @playwright/test/reporter. Declare ZenoPlaywrightReporterOptions, playwrightJourneyKey, and the default reporter class. Keep @playwright/test optional:

    "peerDependencies": {
      "@playwright/test": ">=1.42.0"
    },
    "peerDependenciesMeta": {
      "@playwright/test": {"optional": true}
    }

No Playwright package is installed by this repository’s normal npm install. Version 1.42 is the minimum because the plan uses FullResult timing/status override plus the test-details annotation syntax. The installed-entrypoint smoke test must run against exactly @playwright/test 1.42.0.

- [ ] Add a non-breaking package subpath export.

Add package exports that preserve the existing main entry and existing deep imports:

    {
      ".": "./npm/index.mjs",
      "./playwright-reporter": {
        "types": "./npm/evidence/playwright-reporter.d.ts",
        "import": "./npm/evidence/playwright-reporter.mjs",
        "default": "./npm/evidence/playwright-reporter.mjs"
      },
      "./evidence": "./npm/evidence/contract.mjs",
      "./schemas/*": "./schemas/*",
      "./*": "./*"
    }

Add tests that import the package root and the reporter subpath from a packed temp installation. The wildcard compatibility export is deliberate because the package previously had no exports field.

Append tests/evidence-playwright-reporter.test.mjs to the explicit package.json test:evidence command. Do not switch the script to a glob.

- [ ] Create an executable examples/playwright-zeno-reporter.config.ts.

The config file imports defineConfig and contains configuration only:

    reporter: [
      ["zeno-mobile-runner/playwright-reporter", {
        outputDir: "zeno-evidence/web",
        projectId: process.env.ZENO_PROJECT_ID!,
        submitterType: "automation",
        submitterId: process.env.ZENO_SUBMITTER_ID!,
        releaseId: process.env.ZENO_RELEASE_ID!,
        commitSha: process.env.GITHUB_SHA!,
        deploymentId: process.env.ZENO_DEPLOYMENT_ID!,
        environment: "staging",
        buildManifestPath: "dist/manifest.json",
        configDigest: process.env.ZENO_CONFIG_DIGEST!,
        browserName: "chromium",
        browserVersion: process.env.ZENO_BROWSER_VERSION!
      }]
    ]

- [ ] Create examples/playwright-zeno-journey.spec.ts for the annotation.

The separate test file shows:

    test("guest checkout", {
      annotation: {
        type: "zeno:journey",
        description: "checkout.guest"
      }
    }, async ({page}) => {
      // test body
    });

Do not put placeholder secret values in the example. Explain that configDigest covers an allowlisted non-secret configuration document, never raw environment secrets.

- [ ] Add the packed minimum-version integration smoke script.

tests/packed-evidence-smoke.mjs must:

1. Assert `process.version` is exactly v18.20.8 and `npm --version` is exactly 10.9.8 so a newer local toolchain cannot masquerade as the minimum-version gate.
2. npm pack the repository into a temporary directory and create a temporary consumer package.
3. With PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1, install the tarball with --ignore-scripts plus exact `@playwright/test@1.42.0`, `typescript@5.4.5`, and `@types/node@18.19.130` versions.
4. Invoke the installed node_modules/.bin/zmr-evidence help and require exit 0.
5. Write an explicit tsconfig.json with `module` and `moduleResolution` set to `NodeNext`, `target` set to `ES2022`, `lib` set to `["ES2022", "ESNext.Disposable"]`, `types` set to `["node"]`, `noEmit: true`, `strict: true`, and `skipLibCheck: false`.
6. Typecheck an import of the packaged reporter and ZenoPlaywrightReporterOptions with that config.
7. Create a browserless Playwright test that uses no page/browser fixture, configures the installed packaged reporter, and uses a zeno:journey annotation.
8. Run that test through Playwright 1.42.0 and require evidence.json to exist.
9. Invoke the installed zmr-evidence validate against that package.
10. Remove the temporary directory in a finally block.

This script validates the npm bin shim/shebang, package exports, declaration surface, Playwright loader, reporter lifecycle, and minimum supported version. API-shaped unit fakes remain useful for edge cases but are not the only compatibility proof.

- [ ] Run focused reporter and package tests.

    node --test tests/evidence-playwright-reporter.test.mjs
    node --test tests/npm-package.test.mjs
    npm pack --dry-run --json
    npx --yes --package=node@18.20.8 --package=npm@10.9.8 -c 'node tests/packed-evidence-smoke.mjs'

Expected: PASS. The packed temporary install can resolve zeno-mobile-runner/playwright-reporter.

- [ ] Commit Task 6.

    git add npm/evidence/playwright-reporter.mjs npm/evidence/playwright-reporter.d.ts tests/evidence-playwright-reporter.test.mjs tests/packed-evidence-smoke.mjs examples/playwright-zeno-reporter.config.ts examples/playwright-zeno-journey.spec.ts package.json tests/npm-package.test.mjs
    git commit -m "feat: add Playwright evidence reporter"

## Task 7: Document trust semantics and wire the canonical CI gate

**Files:**

- Create: docs/evidence-contract.md
- Modify: tests/docs-readiness-test.sh
- Modify: scripts/ci-gate.sh
- Modify: tests/ci-gate-script-test.sh
- Modify: .github/workflows/ci.yml
- Modify: README.md
- Modify: FEATURES.md
- Modify: tests/npm-package.test.mjs

- [ ] Add failing documentation readiness assertions.

In tests/docs-readiness-test.sh require:

- docs/evidence-contract.md exists;
- the document names mobile-v1 and web-v1;
- it explains that unknown surface/recipe pairs are retained as unregistered_recipe, non-qualifying context until a public recipe is registered;
- it says unattested and self-reported;
- it explains project identity and that submission identity is an unauthenticated claim;
- it documents zmr-evidence from-zmr and zmr-evidence validate;
- it documents zeno-mobile-runner/playwright-reporter;
- it says unmapped Playwright tests cannot qualify a journey;
- it warns that unreviewed artifacts remain private by default;
- it documents normalized device/OS and browser/version fields;
- it links to the public fixtures directory.

In tests/npm-package.test.mjs require docs/evidence-contract.md, both Playwright example files, fixtures/evidence/v1/cases.json, and the conformance manifests in the dry-run package.

- [ ] Run documentation and package tests and see them fail.

    bash tests/docs-readiness-test.sh
    node --test tests/npm-package.test.mjs

Expected: FAIL because the guide does not exist.

- [ ] Write docs/evidence-contract.md.

Keep the guide task-oriented and include:

1. What the contract proves and explicitly does not prove.
2. Evidence package layout.
3. Producer provenance and unattested MVP semantics.
4. Project identity, self-reported submission context, and the future authenticated ingestion envelope.
5. Exact mobile-v1 and web-v1 recipes.
6. ZMR command example.
7. Playwright reporter and journey annotation example.
8. validate command and JSON exit behaviour.
9. Artifact semantic type plus redaction/disclosure states.
10. Normalized mobile and browser execution metadata.
11. Versioning, explicit unregistered/non-qualifying future surfaces, recipe registration, and public fixture policy.
12. Security limits and rejected archive/path cases.

Use “Verified coverage” only when explaining that a future project policy may qualify passing evidence for an exact registered fingerprint. Do not describe the local adapter itself as independently verifying execution.

- [ ] Add a short product-facing README entry.

Add one concise section:

    Release evidence (mobile + web)

    Zeno turns completed ZMR and Playwright runs into one open,
    digest-verifiable Evidence Contract. It preserves what ran,
    against which exact build, what passed or failed, and which
    business journey it supports.

Link to docs/evidence-contract.md. Keep the main README focused on the runner; do not reposition every existing command in this slice.

- [ ] Update FEATURES.md with shipped versus planned boundaries.

Mark as shipped:

- open Evidence Contract v1;
- local ZMR evidence packages;
- Playwright custom reporter;
- digest and fingerprint validation.

Mark as planned, not shipped:

- hosted Release Passport;
- evidence gap proposals;
- client approval;
- CI attestation.

- [ ] Add evidence tests to the canonical CI gate.

Before npm package dry-run in scripts/ci-gate.sh add:

    run "npm run test:evidence"

Update tests/ci-gate-script-test.sh so its required command list contains npm run test:evidence.

Do not duplicate each individual evidence test command in ci-gate.sh; package.json owns that test list.

- [ ] Add a pinned Node 18 evidence-compatibility CI job.

In .github/workflows/ci.yml add a separate evidence-node18 job on ubuntu-latest:

    evidence-node18:
      runs-on: ubuntu-latest
      timeout-minutes: 15
      env:
        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD: "1"
      steps:
        - uses: actions/checkout@v5
        - uses: actions/setup-node@v4
          with:
            node-version: "18.20.8"
        - name: Pin npm compatibility version
          run: npm install --global npm@10.9.8
        - name: Assert minimum toolchain
          run: |
            test "$(node --version)" = "v18.20.8"
            test "$(npm --version)" = "10.9.8"
        - name: Evidence unit and conformance tests
          run: npm run test:evidence
        - name: Packed CLI and Playwright 1.42 smoke
          run: node tests/packed-evidence-smoke.mjs

This lane is the compatibility authority for package.json engines >=18. It exercises the exact Ajv fixture gate and the packed Playwright consumer under Node 18.20.8/npm 10.9.8. The existing macOS CI job remains the full project gate.

- [ ] Run documentation, CI dry-run, and package checks.

    bash tests/docs-readiness-test.sh
    bash tests/ci-gate-script-test.sh
    scripts/ci-gate.sh --dry-run
    node --test tests/npm-package.test.mjs
    npm pack --dry-run --json
    rg -n 'node-version: "18.20.8"' .github/workflows/ci.yml

Expected: PASS.

- [ ] Commit Task 7.

    git add docs/evidence-contract.md tests/docs-readiness-test.sh scripts/ci-gate.sh tests/ci-gate-script-test.sh .github/workflows/ci.yml README.md FEATURES.md tests/npm-package.test.mjs
    git commit -m "docs: explain Zeno release evidence"

## Task 8: Verify the complete foundation and freeze the handoff

**Files:**

- Verify all files changed in Tasks 1–7
- Modify only if a verification failure exposes a defect

- [ ] Run the focused evidence suite.

    npm run test:evidence

Expected: all evidence contract, package, ZMR adapter, CLI, and Playwright reporter tests PASS.

- [ ] Run the evidence suite and packed smoke under the minimum Node version.

    npx --yes --package=node@18.20.8 --package=npm@10.9.8 -c 'test "$(node --version)" = "v18.20.8" && test "$(npm --version)" = "10.9.8" && npm run test:evidence && node tests/packed-evidence-smoke.mjs'

Expected: Node is v18.20.8, npm is 10.9.8, and every command passes. The pinned GitHub Actions evidence-node18 job runs the same two logical gates with PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1.

- [ ] Run the full Zig suite and public schema CLI test.

    zig test src/test_harness.zig
    zig build
    bash tests/schemas-json-test.sh

Expected: all existing Zig tests PASS and schema count is 25.

- [ ] Run existing npm/language-client regression tests.

    npm test

Expected: Node, Python, Go, and Rust tests PASS.

- [ ] Run documentation and packaging verification.

    bash tests/docs-readiness-test.sh
    node --test tests/npm-package.test.mjs
    npm pack --dry-run --json

Expected: PASS; no tests, temp evidence directories, package-lock.json, or absolute local paths are published.

- [ ] Run the canonical CI gate.

    ./scripts/ci-gate.sh

Expected: PASS. If an environment-specific optional Swift, Kotlin, or external-tool check is skipped by the existing gate, record the exact skip; do not weaken the gate.

- [ ] Perform repository hygiene checks.

    git diff --check
    git status --short
    test ! -f package-lock.json

Expected: no whitespace errors, no unexpected generated files, and only intentional changes if a final verification fix remains.

- [ ] Inspect one mobile and one web package manually.

Generate from the public ZMR fixture and reporter test fixture, then confirm:

- evidence.json contains no absolute paths;
- project and self-reported submitter identity are present;
- submission.claimState is self_reported and no output treats it as authenticated;
- the target fingerprint recomputes exactly;
- the separate unregistered-target fixture remains parseable but reports non-qualifying and is never recomputed as a registered recipe;
- ZMR provenance is zeno_runner / unattested;
- Playwright producer is playwright and provenance is official_adapter / unattested;
- every artifact digest matches its bytes;
- every artifact has a semantic type, redaction state, and disclosureState private;
- mobile items include device/OS metadata and web items include browser/version metadata;
- item timing and failure classification are inspectable;
- retry attempts remain separate;
- unmapped tests have journeyId null;
- no output claims independent authenticity.

- [ ] Commit any final verification-only fixes.

    git add <only-the-files-fixed-during-verification>
    git commit -m "test: harden evidence adapter verification"

Skip this commit when verification required no fixes.

## Completion criteria

Do not mark this plan complete until all of the following are true:

- The public schema is strict, registered, parseable, documented, and packaged.
- Every versioned manifest fixture passes its expected result through both an actual Draft 2020-12 validator and the dependency-free semantic validator.
- Project identity and explicitly self-reported submission identity are mandatory.
- Identity-bearing fields reject empty, trim-changing, and control-character values without rewriting them.
- Both known target fingerprint vectors match exactly.
- Registered recipes are recomputed and qualifying-capable; unknown future surface/recipe pairs remain valid only as unregistered_recipe, non-qualifying context.
- Runtime validation recomputes fingerprints and artifact digests.
- Artifact storage paths derive only from the complete SHA-256 digest, and both file/body inputs enforce the same size ceiling.
- Archive and filesystem path traversal, symlink escape, duplicate path, checksum, truncation, and size-limit tests pass.
- A completed ZMR trace directory and archive generate equivalent source identity.
- ZMR incomplete or contradictory terminal state cannot become passed evidence.
- The Playwright reporter uses the supported Reporter lifecycle, preserves retries and expected status, and never infers a journey from titles.
- ZMR items preserve the required caller-supplied itemId verbatim as externalId and use attempt 0; scenario changes do not silently change item identity.
- Run completeness/redaction, item timing/failure classification, normalized execution environment, and artifact disclosure semantics are present.
- The npm package exposes zmr-evidence and zeno-mobile-runner/playwright-reporter without runtime dependencies.
- Public conformance fixtures are published.
- All catalogued cases in this slice execute; JUnit/CTRF cases remain explicitly assigned to the named next pre-MVP plan.
- Node 18.20.8/npm 10.9.8 unit, packed-bin, TypeScript 5.4.5 with @types/node 18.19.130, and Playwright 1.42.0 loader smoke tests pass.
- npm test and ./scripts/ci-gate.sh pass.
- No cloud, Passport UI, gap-engine, approval, generic-import, trace-v1, or viewer changes slipped into this slice.

## Follow-on plan boundary

The next pre-MVP plan is **Zeno Generic Imports and Full Conformance**. It must:

- add JUnit and CTRF adapters with Imported provenance;
- prevent imported evidence from directly producing Verified coverage;
- activate the catalogued JUnit/CTRF fixtures;
- make every official adapter pass the same complete data-driven conformance suite;
- preserve source-specific details under namespaced extensions;
- leave target identity mandatory and never infer a fingerprint.

After generic imports, the Release Domain and Deterministic Gap Engine plan should consume this contract rather than revise it casually. It will define:

- Release, ReleaseItem, Journey, TargetBuild, EvidenceRun, EvidenceItem, CoverageCell, Gap, Policy, and Decision persistence;
- exact-target matching and deterministic Verified, Failed, Stale, and Unverified evaluation;
- automatic test-gap proposals that cite release items and missing journey/surface evidence;
- accepted-risk and exclusion authorization;
- immutable evaluation snapshots.

Any contract change discovered by that work requires a backward-compatible 1.x extension or a new recipe/schema version with fresh conformance fixtures.
