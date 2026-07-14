import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  isQualifyingTarget,
  validateEvidenceManifest,
} from "../npm/evidence/contract.mjs";
import { validateEvidencePackage } from "../npm/evidence/package-writer.mjs";

const fixturesRoot = fileURLToPath(new URL("../fixtures/evidence/v1/", import.meta.url));
const catalogPath = fileURLToPath(new URL("../fixtures/evidence/v1/cases.json", import.meta.url));
const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
const caseFields = [
  "id",
  "kind",
  "input",
  "expectedSchemaValid",
  "expectedSemanticValid",
  "expectedPackageValid",
  "expectedAdapterValid",
  "expectedIssueCodes",
  "adapter",
  "phase",
].sort();

const requiredFixtureIds = [
  "zeno-passed",
  "zeno-failed",
  "zeno-partial",
  "playwright-passed",
  "playwright-retry-pass",
  "unregistered-target",
  "missing-optional-artifacts",
  "redacted-omitted-screenshot",
  "missing-target-fingerprint",
  "empty-project-id",
  "whitespace-journey-id",
  "unknown-schema-version",
  "malformed-manifest",
  "malicious-artifact-path",
  "artifact-digest-mismatch",
  "playwright-source-passed",
  "playwright-source-retry-pass",
  "future-junit-import",
  "future-ctrf-import",
  "zmr-tar-parent-traversal",
  "zmr-tar-symlink-entry",
  "zmr-tar-oversized-entry",
];

function uniqueIssueCodes(issues) {
  return [...new Set(issues.map(({ code }) => code))].sort();
}

function fixturePath(input) {
  assert.equal(typeof input, "string");
  return fileURLToPath(new URL(input, new URL("../fixtures/evidence/v1/", import.meta.url)));
}

async function readManifestCase(entry) {
  return JSON.parse(await readFile(fixturePath(entry.input), "utf8"));
}

test("public conformance catalog is complete, closed, and honest about future phases", async () => {
  assert.ok(Array.isArray(catalog));
  const ids = new Set();
  for (const entry of catalog) {
    assert.deepEqual(Object.keys(entry).sort(), caseFields, `${entry.id} must use the public case shape`);
    assert.equal(typeof entry.id, "string");
    assert.equal(ids.has(entry.id), false, `duplicate case id ${entry.id}`);
    ids.add(entry.id);

    if (["manifest", "package", "adapter-source"].includes(entry.kind)) {
      await access(fixturePath(entry.input));
    }

    if (entry.phase === "evidence-contract-v1") {
      assert.equal(typeof entry.expectedSchemaValid, "boolean", `${entry.id} schema expectation`);
      assert.equal(typeof entry.expectedSemanticValid, "boolean", `${entry.id} semantic expectation`);
      if (entry.kind === "package") {
        assert.equal(typeof entry.expectedPackageValid, "boolean", `${entry.id} package expectation`);
      } else {
        assert.equal(entry.expectedPackageValid, null, `${entry.id} has no package bytes`);
      }
      assert.equal(entry.expectedAdapterValid, null, `${entry.id} has no adapter execution`);
      assert.ok(Array.isArray(entry.expectedIssueCodes), `${entry.id} must declare issue codes`);
    }

    if (entry.phase === "generic-import-v1") {
      assert.equal(entry.kind, "future-import");
      assert.equal(entry.expectedSchemaValid, null);
      assert.equal(entry.expectedSemanticValid, null);
      assert.equal(entry.expectedPackageValid, null);
      assert.equal(entry.expectedAdapterValid, null);
      assert.equal(entry.expectedIssueCodes, null);
    }

    if (entry.phase === "playwright-reporter-v1" || entry.phase === "zmr-adapter-v1") {
      assert.equal(entry.expectedAdapterValid, null, `${entry.id} must remain inactive until its task`);
    }
  }

  for (const id of requiredFixtureIds) {
    assert.equal(ids.has(id), true, `catalog must include ${id}`);
  }
});

for (const entry of catalog.filter(({ kind }) => kind === "manifest")) {
  test(`semantic conformance: ${entry.id}`, async () => {
    const manifest = await readManifestCase(entry);
    const result = validateEvidenceManifest(manifest);
    assert.equal(result.ok, entry.expectedSemanticValid, JSON.stringify(result.issues, null, 2));
    assert.deepEqual(
      uniqueIssueCodes(result.issues),
      entry.expectedIssueCodes,
      `${entry.id} issue codes`,
    );
    if (entry.id === "unregistered-target") {
      assert.equal(result.ok, true);
      assert.equal(isQualifyingTarget(manifest.target), false);
    }
  });
}

for (const entry of catalog.filter(({ kind }) => kind === "package")) {
  test(`package conformance: ${entry.id}`, async () => {
    const manifestPath = fixturePath(entry.input);
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    const semantic = validateEvidenceManifest(manifest);
    assert.equal(semantic.ok, entry.expectedSemanticValid, JSON.stringify(semantic.issues, null, 2));

    let packageValid = true;
    let issueCodes = [];
    try {
      await validateEvidencePackage(manifestPath);
    } catch (error) {
      packageValid = false;
      issueCodes = [error.code];
    }
    assert.equal(packageValid, entry.expectedPackageValid);
    assert.deepEqual(issueCodes.sort(), entry.expectedIssueCodes);
  });
}

for (const entry of catalog.filter(({ kind }) => entryKindIsSourceFixture(kind))) {
  test(`source fixture is serializable but not prematurely executed: ${entry.id}`, async () => {
    const source = JSON.parse(await readFile(fixturePath(entry.input), "utf8"));
    assert.equal(source.format, "zeno-playwright-reporter-fixture-v1");
    assert.ok(Array.isArray(source.tests));
    assert.equal(entry.expectedAdapterValid, null);
  });
}

function entryKindIsSourceFixture(kind) {
  return kind === "adapter-source";
}

test("future archive cases version exact malicious values without executing Task 4", () => {
  const archiveCases = catalog.filter(({ kind }) => kind === "archive-security");
  assert.deepEqual(
    archiveCases.map(({ input }) => input),
    [
      { path: "../escape", type: "0", size: 0 },
      { path: "safe/link", type: "2", size: 0 },
      { path: "artifacts/huge.bin", type: "0", size: 134217729 },
    ],
  );
  assert.ok(archiveCases.every(({ expectedAdapterValid }) => expectedAdapterValid === null));
});

test("future generic import obligations remain visible without fake execution", () => {
  const future = catalog.filter(({ phase }) => phase === "generic-import-v1");
  assert.deepEqual(future.map(({ adapter }) => adapter).sort(), ["ctrf", "junit"]);
  assert.ok(future.every(({ expectedAdapterValid }) => expectedAdapterValid === null));
});
