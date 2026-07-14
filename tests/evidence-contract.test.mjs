import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  assertSafeRelativePath,
  canonicalBytes,
  canonicalize,
  EvidenceValidationError,
  isSha256Digest,
  sha256Bytes,
  sha256File,
} from "../npm/evidence/canonical-json.mjs";
import {
  buildMobileFingerprintInput,
  buildWebFingerprintInput,
  createMobileFingerprint,
  createWebFingerprint,
  isRegisteredTarget,
  recomputeTargetFingerprint,
} from "../npm/evidence/fingerprints.mjs";

const schemaUrl = new URL("../schemas/evidence-v1.schema.json", import.meta.url);
const schema = JSON.parse(await readFile(schemaUrl, "utf8"));

const identityRef = "#/$defs/identity";
const digestRef = "#/$defs/digest";

const mobileFingerprintInput = {
  appId: "com.example.app",
  artifactDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  buildNumber: "42",
  recipe: "mobile-v1",
  surface: "android",
  version: "1.2.3",
};

const webFingerprintInput = {
  buildManifestDigest: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  commitSha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  configDigest: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  deploymentId: "dpl_123",
  environment: "staging",
  recipe: "web-v1",
  surface: "web",
};

function assertValidationFieldError(action, field) {
  assert.throws(action, (error) => {
    assert.ok(error instanceof EvidenceValidationError);
    assert.equal(error.field, field);
    assert.match(error.message, new RegExp(field));
    return true;
  });
}

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
    "artifacts/evil\u0000.png", "artifacts/line\nbreak.png", "artifacts/del\u007f.png",
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

test("canonical JSON sorts object keys recursively using UTF-16 order", () => {
  assert.equal(
    canonicalize({ z: 1, a: { d: 4, b: 2 } }),
    '{"a":{"b":2,"d":4},"z":1}',
  );
  assert.equal(
    canonicalize({ "\ufffd": 1, "\ud83d\ude00": 2 }),
    '{"😀":2,"�":1}',
  );
});

test("canonical JSON emits stable UTF-8 bytes and preserves array order", () => {
  const expected = '{"message":"café 😀","values":[3,1,2]}';
  const bytes = canonicalBytes({ values: [3, 1, 2], message: "café 😀" });

  assert.ok(Buffer.isBuffer(bytes));
  assert.deepEqual(bytes, Buffer.from(expected, "utf8"));
  assert.equal(bytes.toString("utf8"), expected);
});

test("canonical JSON serializes negative zero as zero", () => {
  assert.equal(canonicalize(-0), "0");
  assert.equal(canonicalize({ value: -0 }), '{"value":0}');
});

test("canonical JSON preserves representative RFC/JCS number formatting", () => {
  for (const [value, expected] of [
    [333333333.33333329, "333333333.3333333"],
    [1e30, "1e+30"],
    [4.50, "4.5"],
    [2e-3, "0.002"],
    [1e-27, "1e-27"],
    [1e-6, "0.000001"],
    [1e-7, "1e-7"],
    [1e20, "100000000000000000000"],
    [1e21, "1e+21"],
    [Number.MIN_VALUE, "5e-324"],
    [Number.MAX_VALUE, "1.7976931348623157e+308"],
  ]) {
    assert.equal(canonicalize(value), expected);
  }
});

test("canonical JSON rejects unsupported and ambiguous values", () => {
  class CustomValue {}

  const cyclic = {};
  cyclic.self = cyclic;

  const cases = [
    ["NaN", NaN],
    ["positive infinity", Infinity],
    ["negative infinity", -Infinity],
    ["BigInt", 1n],
    ["root undefined", undefined],
    ["nested undefined", { value: undefined }],
    ["array undefined", [undefined]],
    ["function", () => {}],
    ["symbol", Symbol("value")],
    ["nested symbol", { value: Symbol("value") }],
    ["cyclic object", cyclic],
    ["Date", new Date(0)],
    ["Map", new Map()],
    ["custom instance", new CustomValue()],
    ["high lone surrogate", "\ud800"],
    ["low lone surrogate", "\udc00"],
    ["lone surrogate key", { "\ud800": "value" }],
  ];

  for (const [label, value] of cases) {
    assert.throws(
      () => canonicalize(value),
      EvidenceValidationError,
      `${label} should be rejected`,
    );
  }
});

test("canonical JSON permits repeated references that are not cycles", () => {
  const shared = { z: 2, a: 1 };
  assert.equal(
    canonicalize({ right: shared, left: shared }),
    '{"left":{"a":1,"z":2},"right":{"a":1,"z":2}}',
  );
});

test("canonical JSON rejects arrays and objects nested beyond 512 levels", () => {
  let nestedArray = null;
  let nestedObject = null;
  for (let depth = 0; depth < 513; depth += 1) {
    nestedArray = [nestedArray];
    nestedObject = { value: nestedObject };
  }

  for (const value of [nestedArray, nestedObject]) {
    assert.throws(() => canonicalize(value), (error) => {
      assert.ok(error instanceof EvidenceValidationError);
      assert.notEqual(error.name, "RangeError");
      assert.equal(error.code, "canonical_depth_exceeded");
      assert.match(error.message, /maximum depth of 512/);
      return true;
    });
  }
});

test("canonical JSON rejects enumerable object accessors without invoking them", () => {
  let getterCalls = 0;
  const value = {};
  Object.defineProperty(value, "stateful", {
    enumerable: true,
    get() {
      getterCalls += 1;
      return getterCalls;
    },
  });

  assert.throws(() => canonicalize(value), (error) => {
    assert.ok(error instanceof EvidenceValidationError);
    assert.equal(error.code, "invalid_canonical_json");
    assert.match(error.message, /accessor properties/);
    return true;
  });
  assert.equal(getterCalls, 0);
});

test("canonical JSON rejects array index accessors without invoking them", () => {
  let getterCalls = 0;
  const value = [];
  Object.defineProperty(value, "0", {
    enumerable: true,
    get() {
      getterCalls += 1;
      return getterCalls;
    },
  });

  assert.throws(() => canonicalize(value), (error) => {
    assert.ok(error instanceof EvidenceValidationError);
    assert.equal(error.code, "invalid_canonical_json");
    assert.match(error.message, /accessor properties/);
    return true;
  });
  assert.equal(getterCalls, 0);
});

test("SHA-256 helpers return lowercase prefixed byte and streaming file digests", async () => {
  const expected = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  assert.equal(sha256Bytes(Buffer.from("abc")), expected);

  const directory = await mkdtemp(join(tmpdir(), "zmr-evidence-digest-"));
  const path = join(directory, "input.bin");
  try {
    await writeFile(path, Buffer.from("abc"));
    assert.equal(await sha256File(path), expected);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("streaming SHA-256 preserves native missing-file errors", async () => {
  const directory = await mkdtemp(join(tmpdir(), "zmr-evidence-missing-"));
  try {
    await assert.rejects(
      sha256File(join(directory, "missing.bin")),
      (error) => error?.code === "ENOENT" && !(error instanceof EvidenceValidationError),
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("SHA-256 digest recognition accepts only lowercase prefixed values", () => {
  const digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  assert.equal(isSha256Digest(digest), true);
  for (const invalid of [
    digest.toUpperCase(),
    "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "sha256:abc",
    `sha256:${"a".repeat(65)}`,
    " aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    null,
  ]) {
    assert.equal(isSha256Digest(invalid), false);
  }
});

test("safe relative paths preserve valid input and reject unsafe raw paths", () => {
  assert.equal(assertSafeRelativePath("artifacts/final.png"), "artifacts/final.png");

  for (const invalid of [
    "",
    "/absolute",
    "C:/windows",
    "C:\\windows",
    "C:drive-relative",
    "\\\\server\\share",
    "artifacts\\final.png",
    ".",
    "..",
    "./file",
    "a/./b",
    "a/../b",
    "a//b",
    "a/",
    "artifacts/evil\u0000.png",
    "artifacts/tab\tname.png",
    "artifacts/line\nbreak.png",
    "artifacts/del\u007f.png",
    "artifacts/NUL",
    "artifacts/CON.txt",
    "artifacts/cOn.log",
    "artifacts/PRN",
    "artifacts/AUX.png",
    "artifacts/COM1",
    "artifacts/com9.txt",
    "artifacts/LPT1",
    "artifacts/lpt9.log",
    "artifacts/file.txt:stream",
    "artifacts/trailing.",
    "artifacts/trailing ",
  ]) {
    assert.throws(
      () => assertSafeRelativePath(invalid),
      EvidenceValidationError,
      `${JSON.stringify(invalid)} should be rejected`,
    );
  }

  assertValidationFieldError(
    () => assertSafeRelativePath("../secret", "artifact.path"),
    "artifact.path",
  );
});

test("fingerprint builders return fresh closed recipe objects", () => {
  const mobileSource = { ...mobileFingerprintInput, ignored: "value" };
  const webSource = { ...webFingerprintInput, ignored: "value" };

  const mobile = buildMobileFingerprintInput(mobileSource);
  const web = buildWebFingerprintInput(webSource);

  assert.deepEqual(mobile, mobileFingerprintInput);
  assert.deepEqual(web, webFingerprintInput);
  assert.notEqual(mobile, mobileSource);
  assert.notEqual(web, webSource);
  assert.deepEqual(Object.keys(mobile), Object.keys(mobileFingerprintInput));
  assert.deepEqual(Object.keys(web), Object.keys(webFingerprintInput));
  assert.equal(createMobileFingerprint(mobileSource), createMobileFingerprint(mobileFingerprintInput));
  assert.equal(createWebFingerprint(webSource), createWebFingerprint(webFingerprintInput));
});

test("fingerprint builders reject each missing required field with field context", () => {
  for (const field of Object.keys(mobileFingerprintInput)) {
    const input = { ...mobileFingerprintInput };
    delete input[field];
    assertValidationFieldError(() => buildMobileFingerprintInput(input), field);
  }

  for (const field of Object.keys(webFingerprintInput)) {
    const input = { ...webFingerprintInput };
    delete input[field];
    assertValidationFieldError(() => buildWebFingerprintInput(input), field);
  }
});

test("fingerprint builders reject blank strings without rewriting nonblank values", () => {
  assertValidationFieldError(
    () => buildMobileFingerprintInput({ ...mobileFingerprintInput, appId: " \t\n " }),
    "appId",
  );
  assertValidationFieldError(
    () => buildWebFingerprintInput({ ...webFingerprintInput, environment: " \t\n " }),
    "environment",
  );

  const mobile = buildMobileFingerprintInput({
    ...mobileFingerprintInput,
    appId: " com.example.app ",
    buildNumber: " 42 ",
    version: " 1.2.3 ",
  });
  assert.equal(mobile.appId, " com.example.app ");
  assert.equal(mobile.buildNumber, " 42 ");
  assert.equal(mobile.version, " 1.2.3 ");

  const web = buildWebFingerprintInput({
    ...webFingerprintInput,
    commitSha: " bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ",
    deploymentId: " dpl_123 ",
    environment: " staging ",
  });
  assert.equal(web.commitSha, " bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ");
  assert.equal(web.deploymentId, " dpl_123 ");
  assert.equal(web.environment, " staging ");
});

test("fingerprint builders require exact recipes, surfaces, and lowercase digests", () => {
  assertValidationFieldError(
    () => buildMobileFingerprintInput({ ...mobileFingerprintInput, recipe: "web-v1" }),
    "recipe",
  );
  assertValidationFieldError(
    () => buildMobileFingerprintInput({ ...mobileFingerprintInput, surface: "web" }),
    "surface",
  );
  assertValidationFieldError(
    () => buildWebFingerprintInput({ ...webFingerprintInput, recipe: "mobile-v1" }),
    "recipe",
  );
  assertValidationFieldError(
    () => buildWebFingerprintInput({ ...webFingerprintInput, surface: "Web" }),
    "surface",
  );

  assertValidationFieldError(
    () => buildMobileFingerprintInput({
      ...mobileFingerprintInput,
      artifactDigest: "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    }),
    "artifactDigest",
  );
  for (const field of ["buildManifestDigest", "configDigest"]) {
    assertValidationFieldError(
      () => buildWebFingerprintInput({
        ...webFingerprintInput,
        [field]: "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      }),
      field,
    );
  }
});

test("mobile-v1 and web-v1 fingerprints match the public known vectors", () => {
  assert.equal(
    createMobileFingerprint(mobileFingerprintInput),
    "sha256:db1eb8afc3eb86f49a47b387e9ba2ee3c14891d2b6a3ee70db83f83612af37b5",
  );
  assert.equal(
    createWebFingerprint(webFingerprintInput),
    "sha256:eb73d4d6a2e408508a2a2839f8cce980434ac6fa935a024bc2f322420dbdd98f",
  );
});

test("mobile-v1 accepts iOS and every required field affects its fingerprint", () => {
  const iosInput = { ...mobileFingerprintInput, surface: "ios" };
  assert.match(createMobileFingerprint(iosInput), /^sha256:[a-f0-9]{64}$/);

  const baseline = createMobileFingerprint(mobileFingerprintInput);
  for (const field of ["appId", "artifactDigest", "buildNumber", "surface", "version"]) {
    const changed = {
      ...mobileFingerprintInput,
      [field]: field === "artifactDigest"
        ? `sha256:${"b".repeat(64)}`
        : field === "surface" ? "ios" : `${mobileFingerprintInput[field]}-changed`,
    };
    assert.notEqual(createMobileFingerprint(changed), baseline, `${field} should affect the fingerprint`);
  }
});

test("web-v1 changes when any required identity input changes", () => {
  const baseline = createWebFingerprint(webFingerprintInput);
  for (const field of [
    "buildManifestDigest", "commitSha", "configDigest",
    "deploymentId", "environment",
  ]) {
    const changed = {
      ...webFingerprintInput,
      [field]: field.endsWith("Digest")
        ? `sha256:${(field === "buildManifestDigest" ? "e" : "f").repeat(64)}`
        : `${webFingerprintInput[field]}-changed`,
    };
    assert.notEqual(createWebFingerprint(changed), baseline, `${field} should affect the fingerprint`);
  }
});

test("registered targets require exact surface and fingerprint recipe pairs", () => {
  for (const target of [
    { surface: "ios", fingerprintRecipe: "mobile-v1" },
    { surface: "android", fingerprintRecipe: "mobile-v1" },
    { surface: "web", fingerprintRecipe: "web-v1" },
  ]) {
    assert.equal(isRegisteredTarget(target), true);
  }

  for (const target of [
    { surface: "watch", fingerprintRecipe: "watch-v1" },
    { surface: "web", fingerprintRecipe: "mobile-v1" },
    { surface: "ios", fingerprintRecipe: "web-v1" },
    { surface: "ios", fingerprintRecipe: "mobile-v1 " },
    { surface: "ios", recipe: "mobile-v1" },
    null,
  ]) {
    assert.equal(isRegisteredTarget(target), false);
  }
});

test("target fingerprint recomputation dispatches only registered recipes", () => {
  assert.equal(
    recomputeTargetFingerprint({
      ...mobileFingerprintInput,
      fingerprintRecipe: mobileFingerprintInput.recipe,
    }),
    createMobileFingerprint(mobileFingerprintInput),
  );
  assert.equal(
    recomputeTargetFingerprint({
      ...webFingerprintInput,
      fingerprintRecipe: webFingerprintInput.recipe,
    }),
    createWebFingerprint(webFingerprintInput),
  );

  for (const target of [
    { surface: "watch", fingerprintRecipe: "watch-v1" },
    { surface: "web", fingerprintRecipe: "mobile-v1" },
    { surface: "ios", fingerprintRecipe: "web-v1" },
    { surface: "android", fingerprintRecipe: "future-v2" },
  ]) {
    assert.throws(
      () => recomputeTargetFingerprint(target),
      EvidenceValidationError,
    );
  }
});
