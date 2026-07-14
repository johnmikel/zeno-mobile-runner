import assert from "node:assert/strict";
import {
  lstat,
  mkdir,
  mkdtemp,
  open,
  readFile,
  readdir,
  rename,
  rm,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { hostname, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import test from "node:test";

import {
  canonicalBytes,
  canonicalize,
  EvidenceValidationError as CanonicalEvidenceValidationError,
  sha256Bytes,
} from "../npm/evidence/canonical-json.mjs";
import {
  createMobileFingerprint,
  createWebFingerprint,
} from "../npm/evidence/fingerprints.mjs";
import {
  assertValidEvidenceManifest,
  ATTESTATION_STATES,
  EVIDENCE_OUTCOMES,
  EVIDENCE_SCHEMA_VERSION,
  EvidenceValidationError,
  isQualifyingTarget,
  PROVENANCE_CLASSES,
  REDACTION_STATES,
  stableSortManifest,
  validateEvidenceManifest,
} from "../npm/evidence/contract.mjs";
import {
  artifactPathForDigest,
  validateEvidencePackage,
  writeEvidencePackage,
} from "../npm/evidence/package-writer.mjs";

const DIGEST_A = `sha256:${"a".repeat(64)}`;
const DIGEST_B = `sha256:${"b".repeat(64)}`;
const DIGEST_C = `sha256:${"c".repeat(64)}`;
const DIGEST_D = `sha256:${"d".repeat(64)}`;
const COMMIT_A = "1".repeat(40);
const COMMIT_B = "2".repeat(40);
const MAX_ARTIFACT_BYTES = 128 * 1024 * 1024;
const PACKAGE_WRITER_TEST_HOOK = Symbol.for("dev.zmr.evidence.package-writer.test-hook");
const LOCK_TOKEN_A = "00000000-0000-4000-8000-000000000001";
const LOCK_TOKEN_B = "00000000-0000-4000-8000-000000000002";
const OLD_LOCK_DATE = new Date("2000-01-01T00:00:00.000Z");

function mobileTarget(overrides = {}) {
  const target = {
    surface: "android",
    environment: "staging",
    fingerprintRecipe: "mobile-v1",
    targetFingerprint: DIGEST_A,
    fingerprintVerification: "recomputed",
    artifactDigest: DIGEST_A,
    appId: "dev.zmr.example",
    version: "1.2.3",
    buildNumber: "42",
    ...overrides,
  };
  if (!("targetFingerprint" in overrides)) {
    target.targetFingerprint = createMobileFingerprint({
      appId: target.appId,
      artifactDigest: target.artifactDigest,
      buildNumber: target.buildNumber,
      recipe: target.fingerprintRecipe,
      surface: target.surface,
      version: target.version,
    });
  }
  return target;
}

function webTarget(overrides = {}) {
  const target = {
    surface: "web",
    environment: "production",
    fingerprintRecipe: "web-v1",
    targetFingerprint: DIGEST_B,
    fingerprintVerification: "recomputed",
    deploymentId: "deployment-42",
    commitSha: COMMIT_A,
    buildManifestDigest: DIGEST_C,
    configDigest: DIGEST_D,
    ...overrides,
  };
  if (!("targetFingerprint" in overrides)) {
    target.targetFingerprint = createWebFingerprint({
      buildManifestDigest: target.buildManifestDigest,
      commitSha: target.commitSha,
      configDigest: target.configDigest,
      deploymentId: target.deploymentId,
      environment: target.environment,
      recipe: target.fingerprintRecipe,
      surface: target.surface,
    });
  }
  return target;
}

function mobileExecution(overrides = {}) {
  return {
    kind: "mobile",
    deviceName: "Pixel 9",
    osName: "Android",
    osVersion: "16",
    ...overrides,
  };
}

function browserExecution(overrides = {}) {
  return {
    kind: "browser",
    browserName: "chromium",
    browserVersion: "126.0",
    ...overrides,
  };
}

function artifact(overrides = {}) {
  return {
    type: "screenshot",
    path: "artifacts/sha256/aa/fixture",
    digest: DIGEST_A,
    sizeBytes: 7,
    contentType: "image/png",
    redactionState: "unreviewed",
    disclosureState: "private",
    ...overrides,
  };
}

function validMobileManifest(overrides = {}) {
  const manifest = {
    schemaVersion: "1.0",
    project: { externalId: "project-42" },
    submission: {
      actorType: "automation",
      externalId: "ci-release",
      claimState: "self_reported",
    },
    producer: {
      name: "zeno-mobile-runner",
      version: "0.2.17",
      adapterVersion: "1.0.0",
      provenanceClass: "zeno_runner",
      attestationState: "unattested",
    },
    release: { externalId: "release-42", commitSha: COMMIT_A },
    target: mobileTarget(),
    run: {
      externalId: "run-42",
      startedAt: "2026-07-13T10:00:00.000Z",
      endedAt: "2026-07-13T10:00:02.000Z",
      outcome: "passed",
      sourceManifestDigest: DIGEST_B,
      completenessState: "complete",
      redactionState: "unreviewed",
    },
    items: [{
      externalId: "scenario-login",
      journeyId: "journey-login",
      scenarioHash: DIGEST_C,
      outcome: "passed",
      attempt: 0,
      startedAt: "2026-07-13T10:00:00.500Z",
      endedAt: "2026-07-13T10:00:01.500Z",
      durationMs: 1000,
      failureClassification: null,
      execution: mobileExecution(),
      artifacts: [],
    }],
  };
  return { ...manifest, ...overrides };
}

function manifestAtCanonicalDepth(depth) {
  const manifest = validMobileManifest();
  let extensionValue = "leaf";
  for (let currentDepth = 2; currentDepth < depth; currentDepth += 1) {
    extensionValue = { value: extensionValue };
  }
  manifest.extensions = { "dev.example.deep": extensionValue };
  return manifest;
}

function validWebManifest(overrides = {}) {
  const manifest = validMobileManifest({
    producer: {
      name: "@playwright/test",
      version: "1.55.0",
      adapterVersion: "1.0.0",
      provenanceClass: "official_adapter",
      attestationState: "unattested",
    },
    target: webTarget(),
  });
  manifest.items[0].execution = browserExecution();
  return { ...manifest, ...overrides };
}

function issuePairs(result) {
  return result.issues.map(({ path, code }) => [path, code]);
}

function assertInvalid(manifest, expectedPairs) {
  const result = validateEvidenceManifest(manifest);
  assert.equal(result.ok, false);
  assert.deepEqual(issuePairs(result), expectedPairs);
  for (const issue of result.issues) {
    assert.equal(typeof issue.message, "string");
    assert.notEqual(issue.message.length, 0);
  }
  return result;
}

test("contract exports the public v1 constants and canonical validation error", () => {
  assert.equal(EVIDENCE_SCHEMA_VERSION, "1.0");
  assert.deepEqual(EVIDENCE_OUTCOMES, [
    "passed", "failed", "partial", "skipped", "timed_out", "interrupted", "unknown",
  ]);
  assert.deepEqual(PROVENANCE_CLASSES, ["zeno_runner", "official_adapter", "imported"]);
  assert.deepEqual(ATTESTATION_STATES, ["unattested", "ci_attested", "signature_verified"]);
  assert.deepEqual(REDACTION_STATES, ["unreviewed", "redacted", "reviewed", "mixed"]);
  assert.equal(EvidenceValidationError, CanonicalEvidenceValidationError);
});

test("valid mobile and web manifests return no issues", () => {
  for (const manifest of [validMobileManifest(), validWebManifest()]) {
    assert.deepEqual(validateEvidenceManifest(manifest), { ok: true, issues: [] });
    assert.equal(assertValidEvidenceManifest(manifest), manifest);
    assert.equal(isQualifyingTarget(manifest.target), true);
  }
});

test("manifest APIs accept depth 512 and reject deeper values without raw stack errors", () => {
  const boundary = manifestAtCanonicalDepth(512);
  assert.doesNotThrow(() => canonicalize(boundary));
  assert.deepEqual(validateEvidenceManifest(boundary), { ok: true, issues: [] });
  assert.equal(assertValidEvidenceManifest(boundary), boundary);
  assert.doesNotThrow(() => stableSortManifest(boundary));

  for (const depth of [513, 20_000]) {
    const manifest = manifestAtCanonicalDepth(depth);
    const result = validateEvidenceManifest(manifest);
    assert.equal(result.ok, false, `depth ${depth}`);
    assert.equal(result.issues.length, 1, `depth ${depth}`);
    assert.equal(result.issues[0].code, "canonical_depth_exceeded", `depth ${depth}`);

    for (const action of [
      () => assertValidEvidenceManifest(manifest),
      () => stableSortManifest(manifest),
    ]) {
      assert.throws(action, (error) => {
        assert.ok(error instanceof CanonicalEvidenceValidationError);
        assert.notEqual(error.name, "RangeError");
        assert.equal(error.code, "invalid_evidence_manifest");
        assert.equal(error.issues?.[0]?.code, "canonical_depth_exceeded");
        return true;
      });
    }
  }
});

test("manifest APIs never invoke enumerable accessors in objects or arrays", async () => {
  await withTemporaryDirectory("zmr-evidence-accessors-", async (parent) => {
    const cases = [
      {
        label: "core object field",
        path: "/project/externalId",
        install(manifest, getter) {
          Object.defineProperty(manifest.project, "externalId", { enumerable: true, get: getter });
        },
      },
      {
        label: "extension object field",
        path: "/extensions/dev.example.state/stateful",
        install(manifest, getter) {
          manifest.extensions = { "dev.example.state": {} };
          Object.defineProperty(
            manifest.extensions["dev.example.state"],
            "stateful",
            { enumerable: true, get: getter },
          );
        },
      },
      {
        label: "array index",
        path: "/items/0",
        install(manifest, getter) {
          Object.defineProperty(manifest.items, "0", { enumerable: true, get: getter });
        },
      },
    ];

    for (let index = 0; index < cases.length; index += 1) {
      const { install, label, path } = cases[index];
      const manifest = validMobileManifest();
      let getterCalls = 0;
      install(manifest, () => {
        getterCalls += 1;
        throw new Error(`${label} getter must not run`);
      });

      const result = validateEvidenceManifest(manifest);
      assert.deepEqual(issuePairs(result), [[path, "invalid_property_descriptor"]], label);
      for (const action of [
        () => assertValidEvidenceManifest(manifest),
        () => stableSortManifest(manifest),
      ]) {
        assert.throws(action, (error) => {
          assert.ok(error instanceof CanonicalEvidenceValidationError, label);
          assert.equal(error.code, "invalid_evidence_manifest", label);
          assert.deepEqual(issuePairs(error), [[path, "invalid_property_descriptor"]], label);
          return true;
        });
      }
      await assert.rejects(
        writeEvidencePackage({
          destination: join(parent, `package-${index}`),
          manifest,
          artifactInputs: [],
        }),
        (error) => {
          assert.ok(error instanceof CanonicalEvidenceValidationError, label);
          assert.equal(error.code, "invalid_evidence_manifest", label);
          assert.deepEqual(issuePairs(error), [[path, "invalid_property_descriptor"]], label);
          return true;
        },
      );
      assert.equal(getterCalls, 0, label);
    }
  });
});

test("manifest APIs reject non-plain object and array containers deterministically", () => {
  class ItemList extends Array {}
  const cases = [
    {
      path: "/project",
      manifest() {
        const value = validMobileManifest();
        value.project = Object.assign(Object.create({ inherited: true }), value.project);
        return value;
      },
    },
    {
      path: "/extensions/dev.example.value",
      manifest() {
        const value = validMobileManifest();
        value.extensions = { "dev.example.value": new Map() };
        return value;
      },
    },
    {
      path: "/items",
      manifest() {
        const value = validMobileManifest();
        value.items = ItemList.from(value.items);
        return value;
      },
    },
  ];

  for (const entry of cases) {
    const manifest = entry.manifest();
    assert.deepEqual(
      issuePairs(validateEvidenceManifest(manifest)),
      [[entry.path, "invalid_container"]],
    );
    for (const action of [
      () => assertValidEvidenceManifest(manifest),
      () => stableSortManifest(manifest),
    ]) {
      assert.throws(action, (error) => {
        assert.ok(error instanceof CanonicalEvidenceValidationError);
        assert.equal(error.code, "invalid_evidence_manifest");
        assert.deepEqual(issuePairs(error), [[entry.path, "invalid_container"]]);
        return true;
      });
    }
  }
});

test("valid unregistered targets are retained and explicitly non-qualifying", () => {
  const manifest = validMobileManifest({
    target: {
      surface: "desktop",
      environment: "lab",
      fingerprintRecipe: "desktop-v2",
      targetFingerprint: DIGEST_D,
      fingerprintVerification: "unregistered_recipe",
    },
  });
  manifest.items[0].execution = {
    kind: "unregistered",
    extensions: { "dev.example.execution": { runtime: "desktop" } },
  };

  assert.deepEqual(validateEvidenceManifest(manifest), { ok: true, issues: [] });
  assert.equal(isQualifyingTarget(manifest.target), false);
  assert.equal(manifest.target.fingerprintVerification, "unregistered_recipe");
});

test("project and self-reported submission claims are required", () => {
  const manifest = validMobileManifest();
  delete manifest.project.externalId;
  delete manifest.submission.externalId;
  delete manifest.submission.claimState;

  assertInvalid(manifest, [
    ["/project/externalId", "required_property"],
    ["/submission/claimState", "required_property"],
    ["/submission/externalId", "required_property"],
  ]);
});

test("identities reject empty, whitespace, edge whitespace, and controls without trimming", () => {
  for (const value of ["", "   ", " leading", "trailing ", "line\nbreak", "delete\u007f"]) {
    const manifest = validMobileManifest();
    manifest.project.externalId = value;
    assertInvalid(manifest, [["/project/externalId", "invalid_identity"]]);
    assert.equal(manifest.project.externalId, value);
  }

  const manifest = validMobileManifest();
  manifest.items[0].journeyId = " journey-login";
  assertInvalid(manifest, [["/items/0/journeyId", "invalid_identity"]]);
});

test("identity length follows JSON Schema Unicode code points", () => {
  const maximum = validMobileManifest();
  maximum.project.externalId = "😀".repeat(256);
  assert.deepEqual(validateEvidenceManifest(maximum), { ok: true, issues: [] });

  const oversized = validMobileManifest();
  oversized.project.externalId = "😀".repeat(257);
  assertInvalid(oversized, [["/project/externalId", "invalid_identity"]]);
});

test("unknown top-level and nested properties are reported in pointer order", () => {
  const manifest = validMobileManifest();
  manifest.project.secret = true;
  manifest.zFuture = true;

  assertInvalid(manifest, [
    ["/project/secret", "unexpected_property"],
    ["/zFuture", "unexpected_property"],
  ]);
});

test("targetFingerprint is required and registered fingerprints are recomputed", () => {
  const missing = validMobileManifest();
  delete missing.target.targetFingerprint;
  assertInvalid(missing, [["/target/targetFingerprint", "required_property"]]);

  const incorrect = validWebManifest();
  incorrect.target.targetFingerprint = DIGEST_A;
  const result = assertInvalid(incorrect, [["/target/targetFingerprint", "fingerprint_mismatch"]]);
  assert.equal(
    result.issues[0].message,
    "targetFingerprint does not match web-v1 inputs",
  );
});

test("run and item intervals are ordered and items stay inside the run", () => {
  const reversedRun = validMobileManifest();
  reversedRun.run.endedAt = "2026-07-13T09:59:59.000Z";
  const reversedResult = validateEvidenceManifest(reversedRun);
  assert.equal(reversedResult.ok, false);
  assert.ok(issuePairs(reversedResult).some(([path, code]) => (
    path === "/run/endedAt" && code === "invalid_time_order"
  )));

  const reversedItem = validMobileManifest();
  reversedItem.items[0].endedAt = "2026-07-13T10:00:00.000Z";
  const itemResult = validateEvidenceManifest(reversedItem);
  assert.equal(itemResult.ok, false);
  assert.ok(issuePairs(itemResult).some(([path, code]) => (
    path === "/items/0/endedAt" && code === "invalid_time_order"
  )));

  const outside = validMobileManifest();
  outside.items[0].startedAt = "2026-07-13T09:59:59.999Z";
  outside.items[0].endedAt = "2026-07-13T10:00:02.001Z";
  outside.items[0].durationMs = 2002;
  assertInvalid(outside, [
    ["/items/0/endedAt", "outside_run_interval"],
    ["/items/0/startedAt", "outside_run_interval"],
  ]);
});

test("durationMs must match the item interval to within one millisecond", () => {
  const tolerated = validMobileManifest();
  tolerated.items[0].durationMs = 1001;
  assert.deepEqual(validateEvidenceManifest(tolerated), { ok: true, issues: [] });

  const mismatched = validMobileManifest();
  mismatched.items[0].durationMs = 1001.01;
  assertInvalid(mismatched, [["/items/0/durationMs", "duration_mismatch"]]);
});

test("mobile executions require device and OS identities", () => {
  const manifest = validMobileManifest();
  delete manifest.items[0].execution.deviceName;
  delete manifest.items[0].execution.osName;
  delete manifest.items[0].execution.osVersion;

  assertInvalid(manifest, [
    ["/items/0/execution/deviceName", "required_property"],
    ["/items/0/execution/osName", "required_property"],
    ["/items/0/execution/osVersion", "required_property"],
  ]);
});

test("browser executions require browser name and version", () => {
  const manifest = validWebManifest();
  delete manifest.items[0].execution.browserName;
  delete manifest.items[0].execution.browserVersion;

  assertInvalid(manifest, [
    ["/items/0/execution/browserName", "required_property"],
    ["/items/0/execution/browserVersion", "required_property"],
  ]);
});

test("artifact paths must remain safe package-relative paths", () => {
  for (const path of ["../secret", "/absolute", "C:/windows", "a/../escape", "a\\b"]) {
    const manifest = validMobileManifest();
    manifest.items[0].artifacts = [artifact({ path })];
    assertInvalid(manifest, [["/items/0/artifacts/0/path", "unsafe_artifact_path"]]);
  }
});

test("conflicting duplicate artifact paths are rejected", () => {
  const conflicting = validMobileManifest();
  conflicting.items[0].artifacts = [
    artifact({ digest: DIGEST_A }),
    artifact({ digest: DIGEST_B }),
  ];
  assertInvalid(conflicting, [["/items/0/artifacts/1/path", "conflicting_artifact_path"]]);

  const identical = validMobileManifest();
  identical.items[0].artifacts = [artifact(), artifact()];
  assert.deepEqual(validateEvidenceManifest(identical), { ok: true, issues: [] });
});

test("attempt is required and externalId plus attempt is unique", () => {
  const missing = validMobileManifest();
  delete missing.items[0].attempt;
  assertInvalid(missing, [["/items/0/attempt", "required_property"]]);

  const duplicate = validMobileManifest();
  duplicate.items.push(structuredClone(duplicate.items[0]));
  assertInvalid(duplicate, [["/items/1/attempt", "duplicate_item_attempt"]]);
});

test("imported provenance and all public attestation states remain legal", () => {
  for (const attestationState of ATTESTATION_STATES) {
    const manifest = validMobileManifest();
    manifest.producer.provenanceClass = "imported";
    manifest.producer.attestationState = attestationState;
    assert.deepEqual(validateEvidenceManifest(manifest), { ok: true, issues: [] });
  }
});

test("extensions require namespaced keys and retain nested source data", () => {
  const valid = validMobileManifest({
    extensions: {
      "dev.example.run": { titlePath: ["suite", "test"], arbitrary: { source: true } },
    },
  });
  valid.items[0].extensions = {
    "dev.playwright.test": { projectName: "chromium", expectedStatus: "passed" },
  };
  assert.deepEqual(validateEvidenceManifest(valid), { ok: true, issues: [] });

  const invalid = validMobileManifest({ extensions: { plain: true } });
  assertInvalid(invalid, [["/extensions/plain", "invalid_extension_namespace"]]);
});

test("items must contain at least one evidence item", () => {
  assertInvalid(validMobileManifest({ items: [] }), [["/items", "min_items"]]);
});

test("web target commit must equal the release commit", () => {
  const manifest = validWebManifest();
  manifest.release.commitSha = COMMIT_B;
  assertInvalid(manifest, [["/target/commitSha", "release_commit_mismatch"]]);
});

test("passing outcomes require null failure classification and other outcomes require a value", () => {
  for (const outcome of ["passed", "skipped"]) {
    const manifest = validMobileManifest();
    manifest.items[0].outcome = outcome;
    manifest.items[0].failureClassification = "unknown";
    assertInvalid(manifest, [["/items/0/failureClassification", "invalid_failure_classification"]]);
  }

  for (const outcome of ["failed", "partial", "timed_out", "interrupted", "unknown"]) {
    const manifest = validMobileManifest();
    manifest.items[0].outcome = outcome;
    manifest.items[0].failureClassification = null;
    assertInvalid(manifest, [["/items/0/failureClassification", "invalid_failure_classification"]]);
  }
});

test("execution branches must correspond to target branches", () => {
  const mobile = validMobileManifest();
  mobile.items[0].execution = browserExecution();
  assertInvalid(mobile, [["/items/0/execution/kind", "execution_target_mismatch"]]);

  const web = validWebManifest();
  web.items[0].execution = mobileExecution();
  assertInvalid(web, [["/items/0/execution/kind", "execution_target_mismatch"]]);
});

test("assertValidEvidenceManifest throws the canonical error with ordered issues", () => {
  const manifest = validMobileManifest();
  manifest.project.externalId = "";
  manifest.zFuture = true;

  assert.throws(() => assertValidEvidenceManifest(manifest), (error) => {
    assert.ok(error instanceof CanonicalEvidenceValidationError);
    assert.equal(error.code, "invalid_evidence_manifest");
    assert.deepEqual(issuePairs({ issues: error.issues }), [
      ["/project/externalId", "invalid_identity"],
      ["/zFuture", "unexpected_property"],
    ]);
    return true;
  });
});

test("stableSortManifest clones, sorts deterministic collections, and preserves semantic arrays", () => {
  const manifest = validMobileManifest({
    extensions: {
      "dev.playwright.test": {
        titlePath: ["z suite", "a test"],
        nested: { z: true, a: true },
      },
    },
  });
  manifest.items = [
    {
      ...structuredClone(manifest.items[0]),
      externalId: "z-test",
      attempt: 1,
      scenarioHash: DIGEST_D,
      artifacts: [
        artifact({ path: "z/file", digest: DIGEST_B }),
        artifact({ path: "a/file", digest: DIGEST_A }),
      ],
    },
    {
      ...structuredClone(manifest.items[0]),
      externalId: "a-test",
      attempt: 0,
      scenarioHash: DIGEST_A,
    },
  ];
  const before = structuredClone(manifest);

  const sorted = stableSortManifest(manifest);

  assert.notEqual(sorted, manifest);
  assert.deepEqual(manifest, before);
  assert.deepEqual(sorted.items.map((item) => item.externalId), ["a-test", "z-test"]);
  assert.deepEqual(sorted.items[1].artifacts.map((entry) => entry.path), ["a/file", "z/file"]);
  assert.deepEqual(
    sorted.extensions["dev.playwright.test"].titlePath,
    ["z suite", "a test"],
  );
  assert.deepEqual(Object.keys(sorted), [...Object.keys(sorted)].sort());
  assert.deepEqual(
    Object.keys(sorted.extensions["dev.playwright.test"].nested),
    ["a", "z"],
  );
});

test("stableSortManifest preserves __proto__ as extension data without changing prototypes", () => {
  const sourceData = JSON.parse('{"__proto__":{"retained":true}}');
  const manifest = validMobileManifest({
    extensions: { "dev.example.data": sourceData },
  });

  const sorted = stableSortManifest(manifest);
  const clonedData = sorted.extensions["dev.example.data"];

  assert.equal(Object.getPrototypeOf(clonedData), Object.prototype);
  assert.equal(Object.prototype.hasOwnProperty.call(clonedData, "__proto__"), true);
  assert.deepEqual(clonedData.__proto__, { retained: true });
});

async function withTemporaryDirectory(prefix, action) {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  try {
    return await action(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function bodyArtifactInput(body, overrides = {}) {
  return {
    itemIndex: 0,
    body,
    type: "test_attachment",
    contentType: "text/plain",
    redactionState: "unreviewed",
    disclosureState: "private",
    ...overrides,
  };
}

function sourceArtifactInput(sourcePath, allowedRoot, overrides = {}) {
  return {
    itemIndex: 0,
    sourcePath,
    allowedRoot,
    type: "test_attachment",
    contentType: "text/plain",
    redactionState: "unreviewed",
    disclosureState: "private",
    ...overrides,
  };
}

function packageArtifactPath(destination, relativePath) {
  return join(destination, ...relativePath.split("/"));
}

async function assertPathMissing(path) {
  await assert.rejects(readFile(path), (error) => error?.code === "ENOENT" || error?.code === "EISDIR");
}

function publishLockPath(destination) {
  return join(dirname(destination), `.${basename(destination)}.publish.lock`);
}

function lockOwner(overrides = {}) {
  const timestamp = OLD_LOCK_DATE.toISOString();
  return {
    token: LOCK_TOKEN_A,
    pid: 123_456,
    hostname: hostname(),
    createdAt: timestamp,
    renewedAt: timestamp,
    ...overrides,
  };
}

async function createTestPublishLock(destination, { metadata, modifiedAt } = {}) {
  const lockPath = publishLockPath(destination);
  await mkdir(lockPath, { mode: 0o700 });
  const ownerPath = join(lockPath, "owner.json");
  if (metadata !== undefined) {
    const bytes = typeof metadata === "string" ? metadata : `${JSON.stringify(metadata)}\n`;
    await writeFile(ownerPath, bytes, { mode: 0o600 });
  }
  if (modifiedAt !== undefined) {
    if (metadata !== undefined) await utimes(ownerPath, modifiedAt, modifiedAt);
    await utimes(lockPath, modifiedAt, modifiedAt);
  }
  return lockPath;
}

function packageWriterDebris(names) {
  return names.filter((name) => (
    name.includes(".tmp-")
    || name.includes(".publish.lock")
    || name.includes(".quarantine-")
  ));
}

test("package writing rejects extreme manifest depth before cloning", async () => {
  await withTemporaryDirectory("zmr-evidence-deep-writer-", async (parent) => {
    await assert.rejects(
      writeEvidencePackage({
        destination: join(parent, "package"),
        manifest: manifestAtCanonicalDepth(20_000),
        artifactInputs: [],
      }),
      (error) => {
        assert.ok(error instanceof CanonicalEvidenceValidationError);
        assert.notEqual(error.name, "RangeError");
        assert.equal(error.code, "invalid_evidence_manifest");
        assert.equal(error.issues?.[0]?.code, "canonical_depth_exceeded");
        return true;
      },
    );
  });
});

test("artifactPathForDigest uses every digest hex character", () => {
  const first = `sha256:${"123456789abc"}${"0".repeat(52)}`;
  const second = `sha256:${"123456789abc"}${"f".repeat(52)}`;

  assert.equal(
    artifactPathForDigest(first),
    `artifacts/sha256/12/${first.slice("sha256:".length + 2)}`,
  );
  assert.equal(
    artifactPathForDigest(second),
    `artifacts/sha256/12/${second.slice("sha256:".length + 2)}`,
  );
  assert.notEqual(artifactPathForDigest(first), artifactPathForDigest(second));
  assert.throws(() => artifactPathForDigest("sha256:short"), CanonicalEvidenceValidationError);
});

test("equal artifact bodies deduplicate storage and preserve both descriptors", async () => {
  await withTemporaryDirectory("zmr-evidence-dedupe-", async (parent) => {
    const destination = join(parent, "package");
    const draft = validMobileManifest();
    const before = structuredClone(draft);
    const body = Buffer.from("identical bytes", "utf8");

    const result = await writeEvidencePackage({
      destination,
      manifest: draft,
      artifactInputs: [bodyArtifactInput(body), bodyArtifactInput(body)],
    });

    assert.deepEqual(draft, before);
    assert.equal(result.manifest.items[0].artifacts.length, 2);
    const [first, second] = result.manifest.items[0].artifacts;
    assert.equal(first.path, second.path);
    assert.equal(first.digest, second.digest);
    assert.deepEqual(await readFile(packageArtifactPath(destination, first.path)), body);
    assert.deepEqual(await readdir(dirname(packageArtifactPath(destination, first.path))), [
      first.path.split("/").at(-1),
    ]);

    const evidenceBytes = await readFile(join(destination, "evidence.json"));
    assert.equal(evidenceBytes.at(-1), 0x0a);
    assert.equal(
      evidenceBytes.toString("utf8"),
      `${JSON.stringify(result.manifest, null, 2)}\n`,
    );
    assert.equal(result.manifestDigest, sha256Bytes(canonicalBytes(result.manifest)));
  });
});

test("same source basename with different bytes cannot collide", async () => {
  await withTemporaryDirectory("zmr-evidence-basename-", async (parent) => {
    const root = join(parent, "source");
    const firstDirectory = join(root, "first");
    const secondDirectory = join(root, "second");
    await mkdir(firstDirectory, { recursive: true });
    await mkdir(secondDirectory, { recursive: true });
    const firstSource = join(firstDirectory, "result.txt");
    const secondSource = join(secondDirectory, "result.txt");
    await writeFile(firstSource, Buffer.from("first bytes"));
    await writeFile(secondSource, Buffer.from("second bytes"));

    const destination = join(parent, "package");
    const result = await writeEvidencePackage({
      destination,
      manifest: validMobileManifest(),
      artifactInputs: [
        sourceArtifactInput(firstSource, root),
        sourceArtifactInput(secondSource, root),
      ],
    });

    const descriptors = result.manifest.items[0].artifacts;
    assert.equal(descriptors.length, 2);
    assert.notEqual(descriptors[0].path, descriptors[1].path);
    assert.ok(descriptors.every(({ path }) => /^artifacts\/sha256\/[a-f0-9]{2}\/[a-f0-9]{62}$/.test(path)));
    assert.ok(descriptors.every(({ path }) => !path.includes("result.txt")));
    const packagedBodies = await Promise.all(
      descriptors.map(({ path }) => readFile(packageArtifactPath(destination, path), "utf8")),
    );
    assert.deepEqual(packagedBodies.sort(), ["first bytes", "second bytes"]);
  });
});

test("reversing artifact input order produces byte-identical evidence", async () => {
  await withTemporaryDirectory("zmr-evidence-order-", async (parent) => {
    const inputs = [
      bodyArtifactInput(Buffer.from("z body"), { type: "z_type" }),
      bodyArtifactInput(Buffer.from("a body"), { type: "a_type" }),
    ];
    const firstDestination = join(parent, "first-package");
    const secondDestination = join(parent, "second-package");
    const first = await writeEvidencePackage({
      destination: firstDestination,
      manifest: validMobileManifest(),
      artifactInputs: inputs,
    });
    const second = await writeEvidencePackage({
      destination: secondDestination,
      manifest: validMobileManifest(),
      artifactInputs: [...inputs].reverse(),
    });

    assert.deepEqual(
      await readFile(join(firstDestination, "evidence.json")),
      await readFile(join(secondDestination, "evidence.json")),
    );
    assert.deepEqual(first.manifest.items[0].artifacts, second.manifest.items[0].artifacts);
    assert.equal(first.manifestDigest, second.manifestDigest);
  });
});

test("equal artifact bytes with different metadata produce byte-identical evidence in either input order", async () => {
  await withTemporaryDirectory("zmr-evidence-equal-body-order-", async (parent) => {
    const body = Buffer.from("identical body");
    const inputs = [
      bodyArtifactInput(body, { type: "z_type" }),
      bodyArtifactInput(body, { type: "a_type" }),
    ];
    const firstDestination = join(parent, "first-package");
    const secondDestination = join(parent, "second-package");
    const first = await writeEvidencePackage({
      destination: firstDestination,
      manifest: validMobileManifest(),
      artifactInputs: inputs,
    });
    const second = await writeEvidencePackage({
      destination: secondDestination,
      manifest: validMobileManifest(),
      artifactInputs: [...inputs].reverse(),
    });

    assert.deepEqual(
      await readFile(join(firstDestination, "evidence.json")),
      await readFile(join(secondDestination, "evidence.json")),
    );
    assert.deepEqual(first.manifest.items[0].artifacts, second.manifest.items[0].artifacts);
    assert.deepEqual(first.manifest.items[0].artifacts.map(({ type }) => type), ["a_type", "z_type"]);
    assert.equal(first.manifestDigest, second.manifestDigest);
  });
});

test("Buffer, Uint8Array, and regular source file inputs retain exact bytes", async () => {
  await withTemporaryDirectory("zmr-evidence-inputs-", async (parent) => {
    const sourceRoot = join(parent, "source");
    await mkdir(sourceRoot);
    const sourcePath = join(sourceRoot, "source.bin");
    const fileBytes = Buffer.from([0, 1, 2, 3, 255]);
    const bufferBytes = Buffer.from("buffer body");
    const typedBytes = new Uint8Array([9, 8, 7, 6]);
    await writeFile(sourcePath, fileBytes);

    const destination = join(parent, "package");
    const result = await writeEvidencePackage({
      destination,
      manifest: validMobileManifest(),
      artifactInputs: [
        sourceArtifactInput(sourcePath, sourceRoot),
        bodyArtifactInput(bufferBytes),
        bodyArtifactInput(typedBytes),
      ],
    });

    const expected = new Map([
      [sha256Bytes(fileBytes), fileBytes],
      [sha256Bytes(bufferBytes), bufferBytes],
      [sha256Bytes(typedBytes), Buffer.from(typedBytes)],
    ]);
    for (const descriptor of result.manifest.items[0].artifacts) {
      assert.deepEqual(
        await readFile(packageArtifactPath(destination, descriptor.path)),
        expected.get(descriptor.digest),
      );
    }
  });
});

test("source byte pins accept unchanged files and reject digest or size mismatches before publication", async () => {
  await withTemporaryDirectory("zmr-evidence-source-pins-", async (parent) => {
    const sourceRoot = join(parent, "source");
    await mkdir(sourceRoot);
    const sourcePath = join(sourceRoot, "source.bin");
    const sourceBytes = Buffer.from("pinned source bytes\n");
    const expectedDigest = sha256Bytes(sourceBytes);
    await writeFile(sourcePath, sourceBytes);

    const validDestination = join(parent, "valid-package");
    const valid = await writeEvidencePackage({
      destination: validDestination,
      manifest: validMobileManifest(),
      artifactInputs: [sourceArtifactInput(sourcePath, sourceRoot, {
        expectedDigest,
        expectedSizeBytes: sourceBytes.length,
      })],
    });
    const [descriptor] = valid.manifest.items[0].artifacts;
    assert.equal(descriptor.digest, expectedDigest);
    assert.equal(descriptor.sizeBytes, sourceBytes.length);
    assert.deepEqual(
      await readFile(packageArtifactPath(validDestination, descriptor.path)),
      sourceBytes,
    );

    const mismatches = [
      {
        field: "expectedDigest",
        value: sha256Bytes(Buffer.from("different source bytes\n")),
        code: "artifact_source_digest_mismatch",
      },
      {
        field: "expectedSizeBytes",
        value: sourceBytes.length + 1,
        code: "artifact_source_size_mismatch",
      },
    ];
    for (let index = 0; index < mismatches.length; index += 1) {
      const { field, value, code } = mismatches[index];
      const destination = join(parent, `mismatch-${index}`);
      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [sourceArtifactInput(sourcePath, sourceRoot, {
            expectedDigest,
            expectedSizeBytes: sourceBytes.length,
            [field]: value,
          })],
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === code
          && error.path === `/artifactInputs/0/${field}`
          && !error.message.includes(sourcePath)
        ),
      );
      await assertPathMissing(destination);
    }
    assert.deepEqual(packageWriterDebris(await readdir(parent)), []);
  });
});

test("failed assembly leaves no destination or sibling temporary directory", async () => {
  await withTemporaryDirectory("zmr-evidence-atomic-error-", async (parent) => {
    const allowedRoot = join(parent, "allowed");
    await mkdir(allowedRoot);
    const outside = join(parent, "outside.txt");
    await writeFile(outside, "outside");
    const destination = join(parent, "package");

    await assert.rejects(
      writeEvidencePackage({
        destination,
        manifest: validMobileManifest(),
        artifactInputs: [
          bodyArtifactInput(Buffer.from("first valid input")),
          sourceArtifactInput(outside, allowedRoot),
        ],
      }),
      CanonicalEvidenceValidationError,
    );

    await assertPathMissing(destination);
    assert.deepEqual(
      (await readdir(parent)).filter((name) => name.includes(".tmp-") || name.includes(".publish.lock")),
      [],
    );
  });
});

test("post-staging failures remove the sibling staging directory and leave no destination", async () => {
  await withTemporaryDirectory("zmr-evidence-post-stage-error-", async (parent) => {
    const destination = join(parent, "package");
    let stagedPath;
    globalThis[PACKAGE_WRITER_TEST_HOOK] = async ({ phase, tempPath }) => {
      if (phase !== "staged") return;
      stagedPath = tempPath;
      assert.equal(dirname(tempPath), parent);
      assert.match(basename(tempPath), /^\.package\.tmp-/);
      assert.deepEqual(await readdir(tempPath), []);
      throw new Error("intentional post-staging failure");
    };

    try {
      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [bodyArtifactInput(Buffer.from("artifact"))],
        }),
        /intentional post-staging failure/,
      );
    } finally {
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
    }

    assert.equal(typeof stagedPath, "string");
    await assertPathMissing(stagedPath);
    await assertPathMissing(destination);
    assert.deepEqual(
      (await readdir(parent)).filter((name) => name.includes(".tmp-") || name.includes(".publish.lock")),
      [],
    );
  });
});

test("non-force publication preserves a destination created during staging", async () => {
  await withTemporaryDirectory("zmr-evidence-destination-race-", async (parent) => {
    const destination = join(parent, "package");
    let createdDestination;
    globalThis[PACKAGE_WRITER_TEST_HOOK] = async ({ phase }) => {
      if (phase !== "staged") return;
      await mkdir(destination, { mode: 0o711 });
      createdDestination = await lstat(destination);
    };

    try {
      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [],
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === "destination_exists"
        ),
      );
    } finally {
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
    }

    const retainedDestination = await lstat(destination);
    assert.equal(retainedDestination.dev, createdDestination.dev);
    assert.equal(retainedDestination.ino, createdDestination.ino);
    await assert.rejects(
      readFile(join(destination, "evidence.json")),
      (error) => error?.code === "ENOENT",
    );
    assert.deepEqual(
      (await readdir(parent)).filter((name) => name.includes(".tmp-") || name.includes(".publish.lock")),
      [],
    );
  });
});

test("simultaneous cooperating writers are serialized by a sibling publication lock", {
  timeout: 5_000,
}, async () => {
  await withTemporaryDirectory("zmr-evidence-concurrent-writers-", async (parent) => {
    const destination = join(parent, "package");
    let releaseFirst;
    const firstCanContinue = new Promise((resolve) => {
      releaseFirst = resolve;
    });
    let firstStaged;
    const firstReachedStaging = new Promise((resolve) => {
      firstStaged = resolve;
    });
    let stagedCount = 0;
    globalThis[PACKAGE_WRITER_TEST_HOOK] = async ({ phase }) => {
      if (phase !== "staged") return;
      stagedCount += 1;
      if (stagedCount === 1) {
        firstStaged();
        await firstCanContinue;
      }
    };

    const firstWrite = writeEvidencePackage({
      destination,
      manifest: validMobileManifest(),
      artifactInputs: [],
    });
    await firstReachedStaging;
    let firstError;
    try {
      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [],
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === "package_publish_locked"
        ),
      );
    } finally {
      releaseFirst();
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
      try {
        await firstWrite;
      } catch (error) {
        firstError = error;
      }
    }

    assert.equal(firstError, undefined);
    assert.equal(stagedCount, 1);
    assert.equal(JSON.parse(await readFile(join(destination, "evidence.json"), "utf8")).schemaVersion, "1.0");
    assert.deepEqual(
      (await readdir(parent)).filter((name) => name.includes(".tmp-") || name.includes(".publish.lock")),
      [],
    );
  });
});

test("dead same-host publication lock owners are quarantined and recovered", async () => {
  await withTemporaryDirectory("zmr-evidence-dead-lock-", async (parent) => {
    const destination = join(parent, "package");
    const owner = lockOwner();
    await createTestPublishLock(destination, { metadata: owner, modifiedAt: OLD_LOCK_DATE });
    let livenessChecks = 0;
    globalThis[PACKAGE_WRITER_TEST_HOOK] = ({ phase, pid }) => {
      if (phase !== "lock_owner_liveness") return undefined;
      livenessChecks += 1;
      assert.equal(pid, owner.pid);
      return false;
    };

    try {
      await writeEvidencePackage({
        destination,
        manifest: validMobileManifest(),
        artifactInputs: [],
      });
    } finally {
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
    }

    assert.ok(livenessChecks >= 1);
    assert.equal(JSON.parse(await readFile(join(destination, "evidence.json"), "utf8")).schemaVersion, "1.0");
    assert.deepEqual(packageWriterDebris(await readdir(parent)), []);
  });
});

test("a live same-host publication lock remains active without leaking owner metadata", async () => {
  await withTemporaryDirectory("zmr-evidence-live-lock-", async (parent) => {
    const destination = join(parent, "package");
    const owner = lockOwner({ pid: process.pid });
    const lockPath = await createTestPublishLock(destination, {
      metadata: owner,
      modifiedAt: OLD_LOCK_DATE,
    });

    await assert.rejects(
      writeEvidencePackage({
        destination,
        manifest: validMobileManifest(),
        artifactInputs: [],
      }),
      (error) => {
        assert.ok(error instanceof CanonicalEvidenceValidationError);
        assert.equal(error.code, "package_publish_locked");
        assert.equal(error.message.includes(owner.token), false);
        assert.equal(error.message.includes(String(owner.pid)), false);
        return true;
      },
    );

    assert.deepEqual(JSON.parse(await readFile(join(lockPath, "owner.json"), "utf8")), owner);
    assert.deepEqual(
      packageWriterDebris(await readdir(parent)),
      [basename(lockPath)],
    );
    await rm(lockPath, { recursive: true });
  });
});

test("missing or corrupt owner metadata is reclaimed only after the grace period", async () => {
  await withTemporaryDirectory("zmr-evidence-incomplete-lock-", async (parent) => {
    for (const [index, metadata] of [undefined, "{not-json"].entries()) {
      const destination = join(parent, `package-${index}`);
      const lockPath = await createTestPublishLock(destination, { metadata });

      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [],
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === "package_publish_locked"
        ),
      );
      assert.equal((await lstat(lockPath)).isDirectory(), true);
      assert.deepEqual(
        packageWriterDebris(await readdir(parent)),
        [basename(lockPath)],
      );

      await utimes(lockPath, OLD_LOCK_DATE, OLD_LOCK_DATE);
      if (metadata !== undefined) {
        await assert.rejects(
          writeEvidencePackage({
            destination,
            manifest: validMobileManifest(),
            artifactInputs: [],
          }),
          (error) => (
            error instanceof CanonicalEvidenceValidationError
            && error.code === "package_publish_locked"
          ),
        );
        await utimes(
          join(lockPath, "owner.json"),
          OLD_LOCK_DATE,
          OLD_LOCK_DATE,
        );
      }
      await writeEvidencePackage({
        destination,
        manifest: validMobileManifest(),
        artifactInputs: [],
      });
      assert.equal(JSON.parse(await readFile(join(destination, "evidence.json"), "utf8")).schemaVersion, "1.0");
      assert.deepEqual(packageWriterDebris(await readdir(parent)), []);
    }
  });
});

test("lock release preserves a replacement lock whose owner token differs", async () => {
  await withTemporaryDirectory("zmr-evidence-lock-token-", async (parent) => {
    const destination = join(parent, "package");
    const lockPath = publishLockPath(destination);
    const replacementOwner = lockOwner({ token: LOCK_TOKEN_B, pid: process.pid });
    let acquiredOwner;
    globalThis[PACKAGE_WRITER_TEST_HOOK] = async ({ phase, quarantinePath }) => {
      if (phase === "staged") {
        acquiredOwner = JSON.parse(await readFile(join(lockPath, "owner.json"), "utf8"));
        assert.match(acquiredOwner.token, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/);
        assert.equal(acquiredOwner.pid, process.pid);
        assert.equal(acquiredOwner.hostname, hostname());
        assert.equal(Number.isFinite(Date.parse(acquiredOwner.createdAt)), true);
        assert.equal(Number.isFinite(Date.parse(acquiredOwner.renewedAt)), true);
      }
      if (phase === "lock_release_quarantined") {
        const quarantinedOwnerPath = join(quarantinePath, "owner.json");
        assert.equal(
          JSON.parse(await readFile(quarantinedOwnerPath, "utf8")).token,
          acquiredOwner.token,
        );
        await writeFile(quarantinedOwnerPath, `${JSON.stringify(replacementOwner)}\n`, {
          mode: 0o600,
        });
      }
    };

    try {
      await writeEvidencePackage({
        destination,
        manifest: validMobileManifest(),
        artifactInputs: [],
      });
    } finally {
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
    }

    assert.equal(typeof acquiredOwner.token, "string");
    assert.notEqual(acquiredOwner.token, replacementOwner.token);
    assert.deepEqual(
      JSON.parse(await readFile(join(lockPath, "owner.json"), "utf8")),
      replacementOwner,
    );
    const evidenceText = await readFile(join(destination, "evidence.json"), "utf8");
    assert.equal(JSON.parse(evidenceText).schemaVersion, "1.0");
    assert.equal(evidenceText.includes(acquiredOwner.token), false);
    assert.equal(evidenceText.includes(replacementOwner.token), false);
    assert.equal(evidenceText.includes(String(process.pid)), false);
    assert.deepEqual(packageWriterDebris(await readdir(parent)), [basename(lockPath)]);
    await rm(lockPath, { recursive: true });
    assert.deepEqual(packageWriterDebris(await readdir(parent)), []);
  });
});

test("stale-lock recovery cleans quarantine, lock, and staging state after failure", async () => {
  await withTemporaryDirectory("zmr-evidence-lock-cleanup-", async (parent) => {
    const destination = join(parent, "package");
    await createTestPublishLock(destination, {
      metadata: "{not-json",
      modifiedAt: OLD_LOCK_DATE,
    });
    globalThis[PACKAGE_WRITER_TEST_HOOK] = ({ phase }) => {
      if (phase === "staged") throw new Error("intentional recovered-lock failure");
    };

    try {
      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [],
        }),
        /intentional recovered-lock failure/,
      );
    } finally {
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
    }

    await assertPathMissing(destination);
    assert.deepEqual(packageWriterDebris(await readdir(parent)), []);
  });
});

test("different-host publication locks are never reclaimed through local PID checks", async () => {
  await withTemporaryDirectory("zmr-evidence-remote-lock-", async (parent) => {
    const destination = join(parent, "package");
    const owner = lockOwner({ hostname: `${hostname()}.remote` });
    const lockPath = await createTestPublishLock(destination, {
      metadata: owner,
      modifiedAt: OLD_LOCK_DATE,
    });
    let livenessChecks = 0;
    globalThis[PACKAGE_WRITER_TEST_HOOK] = ({ phase }) => {
      if (phase === "lock_owner_liveness") livenessChecks += 1;
    };

    try {
      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [],
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === "package_publish_locked"
          && !error.message.includes(owner.hostname)
          && !error.message.includes(owner.token)
        ),
      );
    } finally {
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
    }

    assert.equal(livenessChecks, 0);
    assert.deepEqual(JSON.parse(await readFile(join(lockPath, "owner.json"), "utf8")), owner);
    await rm(lockPath, { recursive: true });
    assert.deepEqual(packageWriterDebris(await readdir(parent)), []);
  });
});

test("force publish failures restore the original destination and remove staging state", async () => {
  await withTemporaryDirectory("zmr-evidence-force-rollback-", async (parent) => {
    const destination = join(parent, "package");
    await mkdir(destination);
    const sentinel = join(destination, "sentinel.txt");
    await writeFile(sentinel, "original package");
    let backupMoved = false;
    globalThis[PACKAGE_WRITER_TEST_HOOK] = async ({ phase }) => {
      if (phase !== "backup_moved") return;
      backupMoved = true;
      await assert.rejects(readFile(sentinel), (error) => error?.code === "ENOENT");
      throw new Error("intentional force publish failure");
    };

    try {
      await assert.rejects(
        writeEvidencePackage({
          destination,
          manifest: validMobileManifest(),
          artifactInputs: [bodyArtifactInput(Buffer.from("replacement"))],
          force: true,
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === "package_publish_failed"
        ),
      );
    } finally {
      delete globalThis[PACKAGE_WRITER_TEST_HOOK];
    }

    assert.equal(backupMoved, true);
    assert.equal(await readFile(sentinel, "utf8"), "original package");
    assert.deepEqual(
      (await readdir(parent)).filter((name) => (
        name.includes(".tmp-") || name.includes(".backup-") || name.includes(".publish.lock")
      )),
      [],
    );
  });
});

test("existing destinations fail unless force is true and forced validation errors retain old bytes", async () => {
  await withTemporaryDirectory("zmr-evidence-force-", async (parent) => {
    const destination = join(parent, "package");
    await mkdir(destination);
    const sentinel = join(destination, "sentinel.txt");
    await writeFile(sentinel, "original package");

    await assert.rejects(
      writeEvidencePackage({
        destination,
        manifest: validMobileManifest(),
        artifactInputs: [],
      }),
      (error) => error instanceof CanonicalEvidenceValidationError && error.code === "destination_exists",
    );
    assert.equal(await readFile(sentinel, "utf8"), "original package");

    await assert.rejects(
      writeEvidencePackage({
        destination,
        manifest: validMobileManifest(),
        artifactInputs: [bodyArtifactInput("not bytes")],
        force: true,
      }),
      CanonicalEvidenceValidationError,
    );
    assert.equal(await readFile(sentinel, "utf8"), "original package");

    await writeEvidencePackage({
      destination,
      manifest: validMobileManifest(),
      artifactInputs: [bodyArtifactInput(Buffer.from("replacement"))],
      force: true,
    });
    await assertPathMissing(sentinel);
    assert.equal(JSON.parse(await readFile(join(destination, "evidence.json"), "utf8")).schemaVersion, "1.0");
  });
});

test("source paths must be contained regular files with no symlink components", async () => {
  await withTemporaryDirectory("zmr-evidence-source-security-", async (parent) => {
    const root = join(parent, "root");
    const realDirectory = join(root, "real");
    await mkdir(realDirectory, { recursive: true });
    const regular = join(realDirectory, "regular.txt");
    await writeFile(regular, "regular");
    const leafLink = join(root, "leaf-link.txt");
    const directoryLink = join(root, "directory-link");
    await symlink(regular, leafLink);
    await symlink(realDirectory, directoryLink);
    const outside = join(parent, "outside.txt");
    await writeFile(outside, "outside");

    const invalidSources = [
      leafLink,
      join(directoryLink, "regular.txt"),
      outside,
    ];
    for (let index = 0; index < invalidSources.length; index += 1) {
      await assert.rejects(
        writeEvidencePackage({
          destination: join(parent, `invalid-${index}`),
          manifest: validMobileManifest(),
          artifactInputs: [sourceArtifactInput(invalidSources[index], root)],
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === "invalid_artifact_source"
          && !error.message.includes(parent)
        ),
      );
    }

    const valid = await writeEvidencePackage({
      destination: join(parent, "valid"),
      manifest: validMobileManifest(),
      artifactInputs: [sourceArtifactInput(regular, root)],
    });
    assert.equal(valid.manifest.items[0].artifacts.length, 1);
  });
});

test("body and file inputs larger than 128 MiB fail before publication", async () => {
  await withTemporaryDirectory("zmr-evidence-size-limit-", async (parent) => {
    const oversizedBody = Buffer.allocUnsafe(MAX_ARTIFACT_BYTES + 1);
    await assert.rejects(
      writeEvidencePackage({
        destination: join(parent, "body-package"),
        manifest: validMobileManifest(),
        artifactInputs: [bodyArtifactInput(oversizedBody)],
      }),
      (error) => error instanceof CanonicalEvidenceValidationError && error.code === "artifact_too_large",
    );

    const root = join(parent, "source");
    await mkdir(root);
    const oversizedFile = join(root, "oversized.bin");
    const handle = await open(oversizedFile, "w");
    try {
      await handle.truncate(MAX_ARTIFACT_BYTES + 1);
    } finally {
      await handle.close();
    }
    await assert.rejects(
      writeEvidencePackage({
        destination: join(parent, "file-package"),
        manifest: validMobileManifest(),
        artifactInputs: [sourceArtifactInput(oversizedFile, root)],
      }),
      (error) => error instanceof CanonicalEvidenceValidationError && error.code === "artifact_too_large",
    );
  });
});

test("artifact input validation is closed, typed, and sanitized", async () => {
  await withTemporaryDirectory("zmr-evidence-invalid-input-", async (parent) => {
    const privatePath = join(parent, "private-secret.txt");
    await writeFile(privatePath, "private");
    const base = bodyArtifactInput(Buffer.from("body"));
    const invalidInputs = [
      { ...base, itemIndex: 9 },
      { ...base, sourcePath: privatePath, allowedRoot: parent },
      { itemIndex: 0, type: "x", contentType: "text/plain", redactionState: "unreviewed", disclosureState: "private" },
      { ...base, body: "text" },
      { ...base, type: "" },
      { ...base, redactionState: "mixed" },
      { ...base, disclosureState: "public" },
      { ...base, displayName: "secret attachment" },
      sourceArtifactInput(privatePath, parent, { expectedDigest: "sha256:invalid" }),
      sourceArtifactInput(privatePath, parent, { expectedSizeBytes: -1 }),
      sourceArtifactInput(privatePath, parent, { expectedSizeBytes: 1.5 }),
      sourceArtifactInput(privatePath, parent, { expectedSizeBytes: MAX_ARTIFACT_BYTES + 1 }),
    ];

    for (let index = 0; index < invalidInputs.length; index += 1) {
      await assert.rejects(
        writeEvidencePackage({
          destination: join(parent, `package-${index}`),
          manifest: validMobileManifest(),
          artifactInputs: [invalidInputs[index]],
        }),
        (error) => (
          error instanceof CanonicalEvidenceValidationError
          && error.code === "invalid_artifact_input"
          && !error.message.includes(privatePath)
          && !error.message.includes("secret attachment")
        ),
      );
    }
  });
});

test("package writing rejects an own __proto__ manifest field instead of dropping it", async () => {
  await withTemporaryDirectory("zmr-evidence-proto-field-", async (parent) => {
    const manifest = validMobileManifest();
    Object.defineProperty(manifest, "__proto__", {
      configurable: true,
      enumerable: true,
      value: { injected: true },
      writable: true,
    });

    await assert.rejects(
      writeEvidencePackage({
        destination: join(parent, "package"),
        manifest,
        artifactInputs: [],
      }),
      (error) => (
        error instanceof CanonicalEvidenceValidationError
        && error.code === "invalid_evidence_manifest"
        && error.issues?.some(({ path, code }) => (
          path === "/__proto__" && code === "unexpected_property"
        ))
      ),
    );
  });
});

test("validateEvidencePackage accepts intact packages and catches byte or size tampering", async () => {
  await withTemporaryDirectory("zmr-evidence-tamper-", async (parent) => {
    const destination = join(parent, "package");
    const result = await writeEvidencePackage({
      destination,
      manifest: validMobileManifest(),
      artifactInputs: [bodyArtifactInput(Buffer.from("hello"))],
    });
    const manifestPath = join(destination, "evidence.json");
    const descriptor = result.manifest.items[0].artifacts[0];
    const storedPath = packageArtifactPath(destination, descriptor.path);

    const validation = await validateEvidencePackage(manifestPath);
    assert.equal(validation.ok, true);
    assert.deepEqual(validation.manifest, result.manifest);
    assert.equal(validation.manifestDigest, result.manifestDigest);

    await writeFile(storedPath, "HELLO");
    await assert.rejects(
      validateEvidencePackage(manifestPath),
      (error) => error instanceof CanonicalEvidenceValidationError && error.code === "artifact_digest_mismatch",
    );

    await writeFile(storedPath, "hello!");
    await assert.rejects(
      validateEvidencePackage(manifestPath),
      (error) => error instanceof CanonicalEvidenceValidationError && error.code === "artifact_size_mismatch",
    );
  });
});

test("package validation rejects a symlinked artifacts directory", async () => {
  await withTemporaryDirectory("zmr-evidence-package-symlink-", async (parent) => {
    const destination = join(parent, "package");
    await writeEvidencePackage({
      destination,
      manifest: validMobileManifest(),
      artifactInputs: [bodyArtifactInput(Buffer.from("artifact"))],
    });
    const outsideArtifacts = join(parent, "outside-artifacts");
    await rename(join(destination, "artifacts"), outsideArtifacts);
    await symlink(outsideArtifacts, join(destination, "artifacts"));

    await assert.rejects(
      validateEvidencePackage(join(destination, "evidence.json")),
      (error) => (
        error instanceof CanonicalEvidenceValidationError
        && error.code === "unsafe_package_artifact"
      ),
    );
  });
});
