import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const schemaUrl = new URL("../schemas/evidence-v1.schema.json", import.meta.url);
const schema = JSON.parse(await readFile(schemaUrl, "utf8"));

const identityRef = "#/$defs/identity";
const digestRef = "#/$defs/digest";

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

test("shared definitions preserve caller identities and namespace extensions", () => {
  assert.deepEqual(schema.$defs.identity, {
    type: "string",
    minLength: 1,
    maxLength: 256,
    pattern: String.raw`^(?!\s)(?!.*\s$)[^\u0000-\u001F\u007F]+$`,
  });
  assert.deepEqual(schema.$defs.outcome.enum, [
    "passed", "failed", "partial", "skipped",
    "timed_out", "interrupted", "unknown",
  ]);
  assert.deepEqual(schema.$defs.failureClassification.enum, [
    "assertion", "timeout", "interrupted", "infrastructure",
    "application", "unknown", null,
  ]);
  assert.deepEqual(schema.$defs.completenessState.enum, [
    "complete", "partial", "incomplete",
  ]);
  assert.equal(
    schema.$defs.extensions.propertyNames.pattern,
    "^[a-z0-9]+(?:[.-][a-z0-9-]+)+$",
  );
  assert.equal(schema.$defs.extensions.additionalProperties, true);
  assert.equal(schema.$defs.timestamp.format, "date-time");

  const identity = new RegExp(schema.$defs.identity.pattern);
  assert.equal(identity.test("release 42"), true);
  for (const invalid of ["", " leading", "trailing ", "line\nbreak", "delete\u007f"]) {
    assert.equal(identity.test(invalid), false, `identity should reject ${JSON.stringify(invalid)}`);
  }
});

test("project, submission, producer, release, and run identities are explicit", () => {
  assert.deepEqual(schema.$defs.project.required, ["externalId"]);
  assert.equal(schema.$defs.project.properties.externalId.$ref, identityRef);

  assert.deepEqual(schema.$defs.submission.required, [
    "actorType", "externalId", "claimState",
  ]);
  assert.deepEqual(schema.$defs.submission.properties.actorType.enum, ["user", "automation"]);
  assert.equal(schema.$defs.submission.properties.externalId.$ref, identityRef);
  assert.equal(schema.$defs.submission.properties.claimState.const, "self_reported");
  assert.match(schema.$defs.submission.description, /unauthenticated/i);
  assert.match(schema.$defs.submission.description, /cannot authorize ingestion/i);

  for (const field of ["name", "version", "adapterVersion"]) {
    assert.equal(schema.$defs.producer.properties[field].$ref, identityRef);
  }
  assert.deepEqual(schema.$defs.release.required, ["externalId", "commitSha"]);
  assert.equal(schema.$defs.release.properties.externalId.$ref, identityRef);
  assert.equal(schema.$defs.release.properties.commitSha.$ref, "#/$defs/gitSha");

  assert.deepEqual(schema.$defs.run.required, [
    "externalId", "startedAt", "endedAt", "outcome",
    "sourceManifestDigest", "completenessState", "redactionState",
  ]);
  assert.equal(schema.$defs.run.properties.externalId.$ref, identityRef);
  assert.equal(schema.$defs.run.properties.sourceManifestDigest.$ref, digestRef);
  assert.deepEqual(schema.$defs.run.properties.redactionState.enum, [
    "unreviewed", "redacted", "reviewed", "mixed",
  ]);
});

test("target branches distinguish registered recipes from non-qualifying targets", () => {
  assert.deepEqual(schema.properties.target.oneOf.map((branch) => branch.$ref), [
    "#/$defs/mobileTarget",
    "#/$defs/webTarget",
    "#/$defs/unregisteredTarget",
  ]);

  const mobile = schema.$defs.mobileTarget;
  assert.deepEqual(mobile.required, [
    "surface", "environment", "fingerprintRecipe", "targetFingerprint",
    "fingerprintVerification", "artifactDigest", "appId", "version", "buildNumber",
  ]);
  assert.deepEqual(mobile.properties.surface.enum, ["ios", "android"]);
  assert.equal(mobile.properties.environment.$ref, identityRef);
  assert.equal(mobile.properties.fingerprintRecipe.const, "mobile-v1");
  assert.equal(mobile.properties.targetFingerprint.$ref, digestRef);
  assert.equal(mobile.properties.fingerprintVerification.const, "recomputed");
  for (const field of ["appId", "version", "buildNumber"]) {
    assert.equal(mobile.properties[field].$ref, identityRef);
  }

  const web = schema.$defs.webTarget;
  assert.deepEqual(web.required, [
    "surface", "environment", "fingerprintRecipe", "targetFingerprint",
    "fingerprintVerification", "deploymentId", "commitSha",
    "buildManifestDigest", "configDigest",
  ]);
  assert.equal(web.properties.surface.const, "web");
  assert.equal(web.properties.environment.$ref, identityRef);
  assert.equal(web.properties.fingerprintRecipe.const, "web-v1");
  assert.equal(web.properties.fingerprintVerification.const, "recomputed");
  assert.equal(web.properties.deploymentId.$ref, identityRef);

  const unregistered = schema.$defs.unregisteredTarget;
  assert.deepEqual(unregistered.required, [
    "surface", "environment", "fingerprintRecipe",
    "targetFingerprint", "fingerprintVerification",
  ]);
  assert.equal(unregistered.properties.surface.$ref, identityRef);
  assert.deepEqual(unregistered.properties.surface.not.enum, ["web", "ios", "android"]);
  assert.equal(unregistered.properties.fingerprintRecipe.$ref, identityRef);
  assert.deepEqual(
    unregistered.properties.fingerprintRecipe.not.enum,
    ["web-v1", "mobile-v1"],
  );
  assert.equal(unregistered.properties.targetFingerprint.$ref, digestRef);
  assert.equal(
    unregistered.properties.fingerprintVerification.const,
    "unregistered_recipe",
  );
});

test("items model strict attempt outcomes and normalized execution", () => {
  const item = schema.$defs.item;
  assert.deepEqual(item.required, [
    "externalId", "journeyId", "scenarioHash", "outcome", "attempt",
    "startedAt", "endedAt", "durationMs", "failureClassification",
    "execution", "artifacts",
  ]);
  assert.deepEqual(Object.keys(item.properties).sort(), [
    ...item.required, "error", "extensions",
  ].sort());
  assert.equal(item.properties.externalId.$ref, identityRef);
  assert.deepEqual(item.properties.journeyId.oneOf, [
    { $ref: identityRef },
    { type: "null" },
  ]);
  assert.equal(item.properties.scenarioHash.$ref, digestRef);
  assert.equal(item.properties.outcome.$ref, "#/$defs/outcome");
  assert.deepEqual(item.properties.attempt, { type: "integer", minimum: 0 });
  assert.deepEqual(item.properties.durationMs, { type: "number", minimum: 0 });
  assert.equal("expectedStatus" in item.properties, false);
  assert.equal("projectName" in item.properties, false);

  assert.deepEqual(schema.$defs.execution.oneOf.map((branch) => branch.$ref), [
    "#/$defs/mobileExecution",
    "#/$defs/browserExecution",
    "#/$defs/unregisteredExecution",
  ]);
  const mobile = schema.$defs.mobileExecution;
  assert.deepEqual(mobile.required, ["kind", "deviceName", "osName", "osVersion"]);
  assert.equal(mobile.properties.kind.const, "mobile");
  for (const field of ["deviceName", "osName", "osVersion"]) {
    assert.equal(mobile.properties[field].$ref, identityRef);
  }
  const browser = schema.$defs.browserExecution;
  assert.deepEqual(browser.required, ["kind", "browserName", "browserVersion"]);
  assert.equal(browser.properties.kind.const, "browser");
  for (const field of ["browserName", "browserVersion"]) {
    assert.equal(browser.properties[field].$ref, identityRef);
  }
  const unregistered = schema.$defs.unregisteredExecution;
  assert.deepEqual(unregistered.required, ["kind", "extensions"]);
  assert.equal(unregistered.properties.kind.const, "unregistered");
  assert.equal(unregistered.properties.extensions.$ref, "#/$defs/extensions");
  assert.equal(unregistered.properties.extensions.minProperties, 1);
});

test("errors and artifacts retain only reviewable evidence", () => {
  const error = schema.$defs.error;
  assert.deepEqual(Object.keys(error.properties), ["name", "message"]);
  assert.equal(error.minProperties, 1);
  assert.deepEqual(error.properties.name, {
    type: "string", minLength: 1, maxLength: 256,
  });
  assert.deepEqual(error.properties.message, {
    type: "string", minLength: 1, maxLength: 4096,
  });

  const artifact = schema.$defs.artifact;
  assert.deepEqual(artifact.required, [
    "type", "path", "digest", "sizeBytes", "contentType",
    "redactionState", "disclosureState",
  ]);
  assert.equal(artifact.properties.type.type, "string");
  assert.equal(artifact.properties.type.minLength, 1);
  assert.equal("enum" in artifact.properties.type, false);
  assert.equal(artifact.properties.path.$ref, "#/$defs/artifactPath");
  assert.equal(artifact.properties.digest.$ref, digestRef);
  assert.deepEqual(artifact.properties.sizeBytes, { type: "integer", minimum: 0 });
  assert.equal(artifact.properties.contentType.minLength, 1);
  assert.deepEqual(artifact.properties.redactionState.enum, [
    "unreviewed", "reviewed", "redacted",
  ]);
  assert.deepEqual(artifact.properties.disclosureState.enum, [
    "private", "review_eligible", "disclosed", "withheld",
  ]);

  const artifactPath = new RegExp(schema.$defs.artifactPath.pattern);
  for (const valid of ["artifact.txt", "artifacts/final.png", ".hidden/file"]) {
    assert.equal(artifactPath.test(valid), true, `artifact path should accept ${valid}`);
  }
  for (const invalid of [
    "", "/absolute", "C:/windows", "C:\\windows", "\\server\\share",
    ".", "..", "./file", "a/./b", "a/../b", "a//b", "a/",
  ]) {
    assert.equal(artifactPath.test(invalid), false, `artifact path should reject ${invalid}`);
  }
});

test("all Evidence Contract objects are closed except extensions", () => {
  for (const name of [
    "project", "submission", "producer", "release",
    "mobileTarget", "webTarget", "unregisteredTarget", "run", "item", "error",
    "mobileExecution", "browserExecution", "unregisteredExecution", "artifact",
  ]) {
    assert.equal(schema.$defs[name].additionalProperties, false, `${name} must be closed`);
  }
  assert.equal(schema.$defs.extensions.additionalProperties, true);
});
