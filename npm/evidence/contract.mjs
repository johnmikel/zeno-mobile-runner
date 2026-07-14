import {
  assertSafeRelativePath,
  EvidenceValidationError,
  isSha256Digest,
} from "./canonical-json.mjs";
import {
  isRegisteredTarget,
  recomputeTargetFingerprint,
} from "./fingerprints.mjs";

export { EvidenceValidationError };

export const EVIDENCE_SCHEMA_VERSION = "1.0";
export const EVIDENCE_OUTCOMES = Object.freeze([
  "passed",
  "failed",
  "partial",
  "skipped",
  "timed_out",
  "interrupted",
  "unknown",
]);
export const PROVENANCE_CLASSES = Object.freeze([
  "zeno_runner",
  "official_adapter",
  "imported",
]);
export const ATTESTATION_STATES = Object.freeze([
  "unattested",
  "ci_attested",
  "signature_verified",
]);
export const REDACTION_STATES = Object.freeze([
  "unreviewed",
  "redacted",
  "reviewed",
  "mixed",
]);

const ACTOR_TYPES = Object.freeze(["user", "automation"]);
const COMPLETENESS_STATES = Object.freeze(["complete", "partial", "incomplete"]);
const FAILURE_CLASSIFICATIONS = Object.freeze([
  "assertion",
  "timeout",
  "interrupted",
  "infrastructure",
  "application",
  "unknown",
  null,
]);
const ARTIFACT_REDACTION_STATES = Object.freeze(["unreviewed", "reviewed", "redacted"]);
const DISCLOSURE_STATES = Object.freeze([
  "private",
  "review_eligible",
  "disclosed",
  "withheld",
]);
const IDENTITY_PATTERN = /^(?!\s)(?!.*\s$)[^\u0000-\u001f\u007f]+$/;
const GIT_SHA_PATTERN = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/;
const EXTENSION_NAMESPACE_PATTERN = /^[a-z0-9]+(?:[.-][a-z0-9-]+)+$/;
const RFC3339_PATTERN = /^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:[Zz]|([+-])(\d{2}):(\d{2}))$/;

const ROOT_REQUIRED = [
  "schemaVersion",
  "project",
  "submission",
  "producer",
  "release",
  "target",
  "run",
  "items",
];
const ROOT_PROPERTIES = [...ROOT_REQUIRED, "extensions"];

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function pointerSegment(value) {
  return String(value).replaceAll("~", "~0").replaceAll("/", "~1");
}

function childPath(path, key) {
  return `${path}/${pointerSegment(key)}`;
}

function compareText(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function unicodeLength(value) {
  let length = 0;
  for (const _character of value) length += 1;
  return length;
}

function sortIssues(issues) {
  return issues.sort((left, right) => (
    compareText(left.path, right.path)
      || compareText(left.code, right.code)
      || compareText(left.message, right.message)
  ));
}

function createCollector() {
  const issues = [];
  return {
    issues,
    add(path, code, message) {
      issues.push({ path, code, message });
    },
  };
}

function validateObjectShape(value, path, required, properties, collector) {
  if (!isObject(value)) {
    collector.add(path, "invalid_type", "value must be an object");
    return false;
  }

  const allowed = new Set(properties);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      collector.add(childPath(path, key), "unexpected_property", "property is not allowed");
    }
  }
  for (const key of required) {
    if (!hasOwn(value, key)) {
      collector.add(childPath(path, key), "required_property", "property is required");
    }
  }
  return true;
}

function validateIdentity(value, path, collector) {
  if (typeof value !== "string") {
    collector.add(path, "invalid_type", "identity must be a string");
    return false;
  }
  const length = unicodeLength(value);
  if (length < 1 || length > 256 || !IDENTITY_PATTERN.test(value)) {
    collector.add(
      path,
      "invalid_identity",
      "identity must be 1 to 256 characters with no edge whitespace or controls",
    );
    return false;
  }
  return true;
}

function validateNonemptyString(value, path, collector, maxLength) {
  if (typeof value !== "string") {
    collector.add(path, "invalid_type", "value must be a string");
    return false;
  }
  if (value.length === 0) {
    collector.add(path, "min_length", "value must not be empty");
    return false;
  }
  if (maxLength !== undefined && unicodeLength(value) > maxLength) {
    collector.add(path, "max_length", `value must not exceed ${maxLength} characters`);
    return false;
  }
  return true;
}

function validateEnum(value, path, allowed, collector) {
  if (!allowed.includes(value)) {
    collector.add(path, "invalid_enum", "value is not in the allowed set");
    return false;
  }
  return true;
}

function validateStringEnum(value, path, allowed, collector) {
  if (typeof value !== "string") {
    collector.add(path, "invalid_type", "value must be a string");
    return false;
  }
  return validateEnum(value, path, allowed, collector);
}

function validateConst(value, path, expected, collector) {
  if (value !== expected) {
    collector.add(path, "invalid_const", "value does not match the required constant");
    return false;
  }
  return true;
}

function validateDigest(value, path, collector) {
  if (typeof value !== "string") {
    collector.add(path, "invalid_type", "digest must be a string");
    return false;
  }
  if (!isSha256Digest(value)) {
    collector.add(path, "invalid_digest", "digest must be a lowercase sha256 value");
    return false;
  }
  return true;
}

function validateGitSha(value, path, collector) {
  if (typeof value !== "string") {
    collector.add(path, "invalid_type", "commit SHA must be a string");
    return false;
  }
  if (!GIT_SHA_PATTERN.test(value)) {
    collector.add(path, "invalid_git_sha", "commit SHA must contain 40 or 64 lowercase hex characters");
    return false;
  }
  return true;
}

function parseTimestamp(value, path, collector) {
  if (typeof value !== "string") {
    collector.add(path, "invalid_type", "timestamp must be a string");
    return null;
  }
  const match = RFC3339_PATTERN.exec(value);
  if (match === null) {
    collector.add(path, "invalid_timestamp", "timestamp must be RFC 3339 date-time text");
    return null;
  }

  const [, yearText, monthText, dayText, hourText, minuteText, secondText,
    , , offsetHourText, offsetMinuteText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const offsetHour = offsetHourText === undefined ? 0 : Number(offsetHourText);
  const offsetMinute = offsetMinuteText === undefined ? 0 : Number(offsetMinuteText);
  const daysInMonth = month >= 1 && month <= 12
    ? new Date(Date.UTC(year, month, 0)).getUTCDate()
    : 0;
  if (
    month < 1 || month > 12
    || day < 1 || day > daysInMonth
    || hour > 23 || minute > 59 || second > 59
    || offsetHour > 23 || offsetMinute > 59
  ) {
    collector.add(path, "invalid_timestamp", "timestamp contains an invalid date or time");
    return null;
  }

  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) {
    collector.add(path, "invalid_timestamp", "timestamp contains an invalid date or time");
    return null;
  }
  return milliseconds;
}

function validateJsonValue(value, path, collector, active = new Set()) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      collector.add(path, "invalid_extension_value", "extension values must be valid JSON");
    }
    return;
  }
  if (typeof value !== "object") {
    collector.add(path, "invalid_extension_value", "extension values must be valid JSON");
    return;
  }
  if (active.has(value)) {
    collector.add(path, "invalid_extension_value", "extension values must not contain cycles");
    return;
  }
  if (!Array.isArray(value) && !isObject(value)) {
    collector.add(path, "invalid_extension_value", "extension values must be plain JSON objects");
    return;
  }

  active.add(value);
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      validateJsonValue(value[index], childPath(path, index), collector, active);
    }
  } else {
    for (const [key, nested] of Object.entries(value)) {
      validateJsonValue(nested, childPath(path, key), collector, active);
    }
  }
  active.delete(value);
}

function validateExtensions(value, path, collector, { minProperties = 0 } = {}) {
  if (!isObject(value)) {
    collector.add(path, "invalid_type", "extensions must be an object");
    return false;
  }
  const keys = Object.keys(value);
  if (keys.length < minProperties) {
    collector.add(path, "min_properties", `extensions must contain at least ${minProperties} property`);
  }
  for (const key of keys) {
    const keyPath = childPath(path, key);
    if (!EXTENSION_NAMESPACE_PATTERN.test(key)) {
      collector.add(
        keyPath,
        "invalid_extension_namespace",
        "extension keys must use a public reverse-domain-style namespace",
      );
    }
    validateJsonValue(value[key], keyPath, collector);
  }
  return true;
}

function validateProject(value, path, collector) {
  if (!validateObjectShape(value, path, ["externalId"], ["externalId"], collector)) return;
  if (hasOwn(value, "externalId")) validateIdentity(value.externalId, `${path}/externalId`, collector);
}

function validateSubmission(value, path, collector) {
  const required = ["actorType", "externalId", "claimState"];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "actorType")) {
    validateStringEnum(value.actorType, `${path}/actorType`, ACTOR_TYPES, collector);
  }
  if (hasOwn(value, "externalId")) validateIdentity(value.externalId, `${path}/externalId`, collector);
  if (hasOwn(value, "claimState")) {
    validateConst(value.claimState, `${path}/claimState`, "self_reported", collector);
  }
}

function validateProducer(value, path, collector) {
  const required = [
    "name",
    "version",
    "adapterVersion",
    "provenanceClass",
    "attestationState",
  ];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  for (const key of ["name", "version", "adapterVersion"]) {
    if (hasOwn(value, key)) validateIdentity(value[key], `${path}/${key}`, collector);
  }
  if (hasOwn(value, "provenanceClass")) {
    validateStringEnum(value.provenanceClass, `${path}/provenanceClass`, PROVENANCE_CLASSES, collector);
  }
  if (hasOwn(value, "attestationState")) {
    validateStringEnum(value.attestationState, `${path}/attestationState`, ATTESTATION_STATES, collector);
  }
}

function validateRelease(value, path, collector) {
  const required = ["externalId", "commitSha"];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "externalId")) validateIdentity(value.externalId, `${path}/externalId`, collector);
  if (hasOwn(value, "commitSha")) validateGitSha(value.commitSha, `${path}/commitSha`, collector);
}

function canRecomputeMobile(target) {
  return (
    target.fingerprintRecipe === "mobile-v1"
    && (target.surface === "ios" || target.surface === "android")
    && typeof target.environment === "string" && validateIdentityQuiet(target.environment)
    && typeof target.appId === "string" && validateIdentityQuiet(target.appId)
    && typeof target.version === "string" && validateIdentityQuiet(target.version)
    && typeof target.buildNumber === "string" && validateIdentityQuiet(target.buildNumber)
    && isSha256Digest(target.artifactDigest)
    && isSha256Digest(target.targetFingerprint)
  );
}

function canRecomputeWeb(target) {
  return (
    target.fingerprintRecipe === "web-v1"
    && target.surface === "web"
    && typeof target.environment === "string" && validateIdentityQuiet(target.environment)
    && typeof target.deploymentId === "string" && validateIdentityQuiet(target.deploymentId)
    && GIT_SHA_PATTERN.test(target.commitSha)
    && isSha256Digest(target.buildManifestDigest)
    && isSha256Digest(target.configDigest)
    && isSha256Digest(target.targetFingerprint)
  );
}

function validateIdentityQuiet(value) {
  const length = unicodeLength(value);
  return length >= 1 && length <= 256 && IDENTITY_PATTERN.test(value);
}

function validateRegisteredFingerprint(target, path, collector, canRecompute) {
  if (!canRecompute) return;
  const expected = recomputeTargetFingerprint(target);
  if (target.targetFingerprint !== expected) {
    collector.add(
      `${path}/targetFingerprint`,
      "fingerprint_mismatch",
      `targetFingerprint does not match ${target.fingerprintRecipe} inputs`,
    );
  }
}

function validateMobileTarget(value, path, collector) {
  const required = [
    "surface",
    "environment",
    "fingerprintRecipe",
    "targetFingerprint",
    "fingerprintVerification",
    "artifactDigest",
    "appId",
    "version",
    "buildNumber",
  ];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "surface")) {
    validateStringEnum(value.surface, `${path}/surface`, ["ios", "android"], collector);
  }
  if (hasOwn(value, "environment")) validateIdentity(value.environment, `${path}/environment`, collector);
  if (hasOwn(value, "fingerprintRecipe")) {
    validateConst(value.fingerprintRecipe, `${path}/fingerprintRecipe`, "mobile-v1", collector);
  }
  if (hasOwn(value, "targetFingerprint")) {
    validateDigest(value.targetFingerprint, `${path}/targetFingerprint`, collector);
  }
  if (hasOwn(value, "fingerprintVerification")) {
    validateConst(value.fingerprintVerification, `${path}/fingerprintVerification`, "recomputed", collector);
  }
  if (hasOwn(value, "artifactDigest")) validateDigest(value.artifactDigest, `${path}/artifactDigest`, collector);
  for (const key of ["appId", "version", "buildNumber"]) {
    if (hasOwn(value, key)) validateIdentity(value[key], `${path}/${key}`, collector);
  }
  validateRegisteredFingerprint(value, path, collector, canRecomputeMobile(value));
}

function validateWebTarget(value, path, collector, release) {
  const required = [
    "surface",
    "environment",
    "fingerprintRecipe",
    "targetFingerprint",
    "fingerprintVerification",
    "deploymentId",
    "commitSha",
    "buildManifestDigest",
    "configDigest",
  ];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "surface")) validateConst(value.surface, `${path}/surface`, "web", collector);
  if (hasOwn(value, "environment")) validateIdentity(value.environment, `${path}/environment`, collector);
  if (hasOwn(value, "fingerprintRecipe")) {
    validateConst(value.fingerprintRecipe, `${path}/fingerprintRecipe`, "web-v1", collector);
  }
  if (hasOwn(value, "targetFingerprint")) {
    validateDigest(value.targetFingerprint, `${path}/targetFingerprint`, collector);
  }
  if (hasOwn(value, "fingerprintVerification")) {
    validateConst(value.fingerprintVerification, `${path}/fingerprintVerification`, "recomputed", collector);
  }
  if (hasOwn(value, "deploymentId")) validateIdentity(value.deploymentId, `${path}/deploymentId`, collector);
  if (hasOwn(value, "commitSha")) validateGitSha(value.commitSha, `${path}/commitSha`, collector);
  for (const key of ["buildManifestDigest", "configDigest"]) {
    if (hasOwn(value, key)) validateDigest(value[key], `${path}/${key}`, collector);
  }
  validateRegisteredFingerprint(value, path, collector, canRecomputeWeb(value));

  if (
    GIT_SHA_PATTERN.test(value.commitSha)
    && isObject(release)
    && GIT_SHA_PATTERN.test(release.commitSha)
    && value.commitSha !== release.commitSha
  ) {
    collector.add(
      `${path}/commitSha`,
      "release_commit_mismatch",
      "web target commitSha must equal release commitSha",
    );
  }
}

function validateUnregisteredTarget(value, path, collector) {
  const required = [
    "surface",
    "environment",
    "fingerprintRecipe",
    "targetFingerprint",
    "fingerprintVerification",
  ];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "surface")) {
    const valid = validateIdentity(value.surface, `${path}/surface`, collector);
    if (valid && ["web", "ios", "android"].includes(value.surface)) {
      collector.add(`${path}/surface`, "invalid_unregistered_surface", "surface has a registered v1 branch");
    }
  }
  if (hasOwn(value, "environment")) validateIdentity(value.environment, `${path}/environment`, collector);
  if (hasOwn(value, "fingerprintRecipe")) {
    const valid = validateIdentity(value.fingerprintRecipe, `${path}/fingerprintRecipe`, collector);
    if (valid && ["web-v1", "mobile-v1"].includes(value.fingerprintRecipe)) {
      collector.add(
        `${path}/fingerprintRecipe`,
        "invalid_unregistered_recipe",
        "fingerprint recipe has a registered v1 branch",
      );
    }
  }
  if (hasOwn(value, "targetFingerprint")) {
    validateDigest(value.targetFingerprint, `${path}/targetFingerprint`, collector);
  }
  if (hasOwn(value, "fingerprintVerification")) {
    validateConst(
      value.fingerprintVerification,
      `${path}/fingerprintVerification`,
      "unregistered_recipe",
      collector,
    );
  }
}

function validateTarget(value, path, collector, release) {
  if (!isObject(value)) {
    collector.add(path, "invalid_type", "target must be an object");
    return "invalid";
  }
  if (value.surface === "ios" || value.surface === "android") {
    validateMobileTarget(value, path, collector);
    return "mobile";
  }
  if (value.surface === "web") {
    validateWebTarget(value, path, collector, release);
    return "web";
  }
  validateUnregisteredTarget(value, path, collector);
  return "unregistered";
}

function validateRun(value, path, collector) {
  const required = [
    "externalId",
    "startedAt",
    "endedAt",
    "outcome",
    "sourceManifestDigest",
    "completenessState",
    "redactionState",
  ];
  if (!validateObjectShape(value, path, required, required, collector)) {
    return { startedAt: null, endedAt: null };
  }
  if (hasOwn(value, "externalId")) validateIdentity(value.externalId, `${path}/externalId`, collector);
  const startedAt = hasOwn(value, "startedAt")
    ? parseTimestamp(value.startedAt, `${path}/startedAt`, collector)
    : null;
  const endedAt = hasOwn(value, "endedAt")
    ? parseTimestamp(value.endedAt, `${path}/endedAt`, collector)
    : null;
  if (hasOwn(value, "outcome")) {
    validateStringEnum(value.outcome, `${path}/outcome`, EVIDENCE_OUTCOMES, collector);
  }
  if (hasOwn(value, "sourceManifestDigest")) {
    validateDigest(value.sourceManifestDigest, `${path}/sourceManifestDigest`, collector);
  }
  if (hasOwn(value, "completenessState")) {
    validateStringEnum(
      value.completenessState,
      `${path}/completenessState`,
      COMPLETENESS_STATES,
      collector,
    );
  }
  if (hasOwn(value, "redactionState")) {
    validateStringEnum(value.redactionState, `${path}/redactionState`, REDACTION_STATES, collector);
  }
  if (startedAt !== null && endedAt !== null && endedAt < startedAt) {
    collector.add(`${path}/endedAt`, "invalid_time_order", "endedAt must not precede startedAt");
  }
  return { startedAt, endedAt };
}

function validateError(value, path, collector) {
  const properties = ["name", "message"];
  if (!validateObjectShape(value, path, [], properties, collector)) return;
  if (Object.keys(value).length === 0) {
    collector.add(path, "min_properties", "error must contain a name or message");
  }
  if (hasOwn(value, "name")) validateNonemptyString(value.name, `${path}/name`, collector, 256);
  if (hasOwn(value, "message")) validateNonemptyString(value.message, `${path}/message`, collector, 4096);
}

function validateMobileExecution(value, path, collector) {
  const required = ["kind", "deviceName", "osName", "osVersion"];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "kind")) validateConst(value.kind, `${path}/kind`, "mobile", collector);
  for (const key of ["deviceName", "osName", "osVersion"]) {
    if (hasOwn(value, key)) validateIdentity(value[key], `${path}/${key}`, collector);
  }
}

function validateBrowserExecution(value, path, collector) {
  const required = ["kind", "browserName", "browserVersion"];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "kind")) validateConst(value.kind, `${path}/kind`, "browser", collector);
  for (const key of ["browserName", "browserVersion"]) {
    if (hasOwn(value, key)) validateIdentity(value[key], `${path}/${key}`, collector);
  }
}

function validateUnregisteredExecution(value, path, collector) {
  const required = ["kind", "extensions"];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "kind")) validateConst(value.kind, `${path}/kind`, "unregistered", collector);
  if (hasOwn(value, "extensions")) {
    validateExtensions(value.extensions, `${path}/extensions`, collector, { minProperties: 1 });
  }
}

function validateExecution(value, path, collector, targetBranch) {
  if (!isObject(value)) {
    collector.add(path, "invalid_type", "execution must be an object");
    return;
  }

  let actualBranch = "invalid";
  if (value.kind === "mobile") {
    actualBranch = "mobile";
    validateMobileExecution(value, path, collector);
  } else if (value.kind === "browser") {
    actualBranch = "web";
    validateBrowserExecution(value, path, collector);
  } else if (value.kind === "unregistered") {
    actualBranch = "unregistered";
    validateUnregisteredExecution(value, path, collector);
  } else {
    validateObjectShape(value, path, ["kind"], ["kind"], collector);
    if (hasOwn(value, "kind")) {
      validateStringEnum(value.kind, `${path}/kind`, ["mobile", "browser", "unregistered"], collector);
    }
  }

  if (actualBranch !== "invalid" && targetBranch !== "invalid" && actualBranch !== targetBranch) {
    collector.add(
      `${path}/kind`,
      "execution_target_mismatch",
      "execution kind does not correspond to the target branch",
    );
  }
}

function validateArtifact(value, path, collector, artifactPaths) {
  const required = [
    "type",
    "path",
    "digest",
    "sizeBytes",
    "contentType",
    "redactionState",
    "disclosureState",
  ];
  if (!validateObjectShape(value, path, required, required, collector)) return;
  if (hasOwn(value, "type")) validateNonemptyString(value.type, `${path}/type`, collector);

  let safePath = false;
  if (hasOwn(value, "path")) {
    if (typeof value.path !== "string") {
      collector.add(`${path}/path`, "invalid_type", "artifact path must be a string");
    } else {
      try {
        assertSafeRelativePath(value.path, "artifact.path");
        safePath = true;
      } catch (error) {
        if (!(error instanceof EvidenceValidationError)) throw error;
        collector.add(
          `${path}/path`,
          "unsafe_artifact_path",
          "artifact path must be a safe package-relative path",
        );
      }
    }
  }

  const validDigest = hasOwn(value, "digest")
    ? validateDigest(value.digest, `${path}/digest`, collector)
    : false;
  if (hasOwn(value, "sizeBytes")) {
    if (!Number.isInteger(value.sizeBytes) || value.sizeBytes < 0) {
      collector.add(`${path}/sizeBytes`, "invalid_size", "sizeBytes must be a non-negative integer");
    }
  }
  if (hasOwn(value, "contentType")) {
    validateNonemptyString(value.contentType, `${path}/contentType`, collector);
  }
  if (hasOwn(value, "redactionState")) {
    validateStringEnum(
      value.redactionState,
      `${path}/redactionState`,
      ARTIFACT_REDACTION_STATES,
      collector,
    );
  }
  if (hasOwn(value, "disclosureState")) {
    validateStringEnum(
      value.disclosureState,
      `${path}/disclosureState`,
      DISCLOSURE_STATES,
      collector,
    );
  }

  if (safePath && validDigest) {
    const previousDigest = artifactPaths.get(value.path);
    if (previousDigest !== undefined && previousDigest !== value.digest) {
      collector.add(
        `${path}/path`,
        "conflicting_artifact_path",
        "artifact path is already associated with a different digest",
      );
    } else if (previousDigest === undefined) {
      artifactPaths.set(value.path, value.digest);
    }
  }
}

function validateItem(
  value,
  path,
  collector,
  targetBranch,
  runInterval,
  itemIdentities,
  artifactPaths,
) {
  const required = [
    "externalId",
    "journeyId",
    "scenarioHash",
    "outcome",
    "attempt",
    "startedAt",
    "endedAt",
    "durationMs",
    "failureClassification",
    "execution",
    "artifacts",
  ];
  const properties = [...required, "error", "extensions"];
  if (!validateObjectShape(value, path, required, properties, collector)) return;

  const validExternalId = hasOwn(value, "externalId")
    ? validateIdentity(value.externalId, `${path}/externalId`, collector)
    : false;
  if (hasOwn(value, "journeyId") && value.journeyId !== null) {
    validateIdentity(value.journeyId, `${path}/journeyId`, collector);
  }
  if (hasOwn(value, "scenarioHash")) validateDigest(value.scenarioHash, `${path}/scenarioHash`, collector);
  const validOutcome = hasOwn(value, "outcome")
    ? validateStringEnum(value.outcome, `${path}/outcome`, EVIDENCE_OUTCOMES, collector)
    : false;

  let validAttempt = false;
  if (hasOwn(value, "attempt")) {
    if (!Number.isInteger(value.attempt) || value.attempt < 0) {
      collector.add(`${path}/attempt`, "invalid_attempt", "attempt must be a non-negative integer");
    } else {
      validAttempt = true;
    }
  }
  if (validExternalId && validAttempt) {
    const identity = `${value.externalId}\u0000${value.attempt}`;
    if (itemIdentities.has(identity)) {
      collector.add(`${path}/attempt`, "duplicate_item_attempt", "externalId and attempt must be unique");
    } else {
      itemIdentities.add(identity);
    }
  }

  const startedAt = hasOwn(value, "startedAt")
    ? parseTimestamp(value.startedAt, `${path}/startedAt`, collector)
    : null;
  const endedAt = hasOwn(value, "endedAt")
    ? parseTimestamp(value.endedAt, `${path}/endedAt`, collector)
    : null;
  let validDuration = false;
  if (hasOwn(value, "durationMs")) {
    if (typeof value.durationMs !== "number" || !Number.isFinite(value.durationMs)) {
      collector.add(`${path}/durationMs`, "invalid_type", "durationMs must be a finite number");
    } else if (value.durationMs < 0) {
      collector.add(`${path}/durationMs`, "invalid_duration", "durationMs must not be negative");
    } else {
      validDuration = true;
    }
  }

  if (startedAt !== null && endedAt !== null) {
    if (endedAt < startedAt) {
      collector.add(`${path}/endedAt`, "invalid_time_order", "endedAt must not precede startedAt");
    } else if (validDuration && Math.abs(value.durationMs - (endedAt - startedAt)) > 1) {
      collector.add(
        `${path}/durationMs`,
        "duration_mismatch",
        "durationMs must match the item interval within one millisecond",
      );
    }
    if (
      runInterval.startedAt !== null
      && runInterval.endedAt !== null
      && runInterval.endedAt >= runInterval.startedAt
    ) {
      if (startedAt < runInterval.startedAt) {
        collector.add(`${path}/startedAt`, "outside_run_interval", "item starts before the run");
      }
      if (endedAt > runInterval.endedAt) {
        collector.add(`${path}/endedAt`, "outside_run_interval", "item ends after the run");
      }
    }
  }

  let validClassification = false;
  if (hasOwn(value, "failureClassification")) {
    validClassification = validateEnum(
      value.failureClassification,
      `${path}/failureClassification`,
      FAILURE_CLASSIFICATIONS,
      collector,
    );
  }
  if (validOutcome && validClassification) {
    const requiresNull = value.outcome === "passed" || value.outcome === "skipped";
    if (
      (requiresNull && value.failureClassification !== null)
      || (!requiresNull && value.failureClassification === null)
    ) {
      collector.add(
        `${path}/failureClassification`,
        "invalid_failure_classification",
        requiresNull
          ? "passed and skipped items require a null failureClassification"
          : "non-passing items require a failureClassification",
      );
    }
  }

  if (hasOwn(value, "execution")) {
    validateExecution(value.execution, `${path}/execution`, collector, targetBranch);
  }
  if (hasOwn(value, "artifacts")) {
    if (!Array.isArray(value.artifacts)) {
      collector.add(`${path}/artifacts`, "invalid_type", "artifacts must be an array");
    } else {
      for (let index = 0; index < value.artifacts.length; index += 1) {
        validateArtifact(
          value.artifacts[index],
          `${path}/artifacts/${index}`,
          collector,
          artifactPaths,
        );
      }
    }
  }
  if (hasOwn(value, "error")) validateError(value.error, `${path}/error`, collector);
  if (hasOwn(value, "extensions")) {
    validateExtensions(value.extensions, `${path}/extensions`, collector);
  }
}

export function isQualifyingTarget(target) {
  return isRegisteredTarget(target) && target.fingerprintVerification === "recomputed";
}

export function validateEvidenceManifest(manifest) {
  const collector = createCollector();
  if (!validateObjectShape(manifest, "", ROOT_REQUIRED, ROOT_PROPERTIES, collector)) {
    return { ok: false, issues: sortIssues(collector.issues) };
  }

  if (hasOwn(manifest, "schemaVersion")) {
    if (typeof manifest.schemaVersion !== "string") {
      collector.add("/schemaVersion", "invalid_type", "schemaVersion must be a string");
    } else if (manifest.schemaVersion !== EVIDENCE_SCHEMA_VERSION) {
      collector.add(
        "/schemaVersion",
        "unsupported_schema_version",
        `schemaVersion must be ${EVIDENCE_SCHEMA_VERSION}`,
      );
    }
  }
  if (hasOwn(manifest, "project")) validateProject(manifest.project, "/project", collector);
  if (hasOwn(manifest, "submission")) {
    validateSubmission(manifest.submission, "/submission", collector);
  }
  if (hasOwn(manifest, "producer")) validateProducer(manifest.producer, "/producer", collector);
  if (hasOwn(manifest, "release")) validateRelease(manifest.release, "/release", collector);
  const targetBranch = hasOwn(manifest, "target")
    ? validateTarget(manifest.target, "/target", collector, manifest.release)
    : "invalid";
  const runInterval = hasOwn(manifest, "run")
    ? validateRun(manifest.run, "/run", collector)
    : { startedAt: null, endedAt: null };

  if (hasOwn(manifest, "items")) {
    if (!Array.isArray(manifest.items)) {
      collector.add("/items", "invalid_type", "items must be an array");
    } else {
      if (manifest.items.length === 0) {
        collector.add("/items", "min_items", "items must contain at least one item");
      }
      const itemIdentities = new Set();
      const artifactPaths = new Map();
      for (let index = 0; index < manifest.items.length; index += 1) {
        validateItem(
          manifest.items[index],
          `/items/${index}`,
          collector,
          targetBranch,
          runInterval,
          itemIdentities,
          artifactPaths,
        );
      }
    }
  }
  if (hasOwn(manifest, "extensions")) {
    validateExtensions(manifest.extensions, "/extensions", collector);
  }

  const issues = sortIssues(collector.issues);
  return issues.length === 0 ? { ok: true, issues } : { ok: false, issues };
}

export function assertValidEvidenceManifest(manifest) {
  const result = validateEvidenceManifest(manifest);
  if (!result.ok) {
    const error = new EvidenceValidationError(
      `Evidence manifest is invalid (${result.issues.length} issue${result.issues.length === 1 ? "" : "s"})`,
      {
        code: "invalid_evidence_manifest",
        path: result.issues[0]?.path,
      },
    );
    error.issues = result.issues;
    throw error;
  }
  return manifest;
}

function cloneWithSortedKeys(value, path, active) {
  if (value === null || typeof value !== "object") return value;
  if (active.has(value)) {
    throw new EvidenceValidationError("Evidence manifest cannot contain cycles", {
      code: "invalid_evidence_manifest",
      path: `/${path.map(pointerSegment).join("/")}`,
    });
  }
  active.add(value);
  try {
    if (Array.isArray(value)) {
      const cloned = value.map((item, index) => cloneWithSortedKeys(item, [...path, index], active));
      if (path.length === 1 && path[0] === "items") {
        cloned.sort((left, right) => (
          compareText(String(left?.externalId ?? ""), String(right?.externalId ?? ""))
          || (Number(left?.attempt ?? 0) - Number(right?.attempt ?? 0))
          || compareText(String(left?.scenarioHash ?? ""), String(right?.scenarioHash ?? ""))
        ));
      } else if (
        path.length === 3
        && path[0] === "items"
        && Number.isInteger(path[1])
        && path[2] === "artifacts"
      ) {
        cloned.sort((left, right) => (
          compareText(String(left?.path ?? ""), String(right?.path ?? ""))
          || compareText(String(left?.digest ?? ""), String(right?.digest ?? ""))
        ));
      }
      return cloned;
    }

    const cloned = {};
    for (const key of Object.keys(value).sort()) {
      Object.defineProperty(cloned, key, {
        configurable: true,
        enumerable: true,
        value: cloneWithSortedKeys(value[key], [...path, key], active),
        writable: true,
      });
    }
    return cloned;
  } finally {
    active.delete(value);
  }
}

export function stableSortManifest(manifest) {
  return cloneWithSortedKeys(manifest, [], new Set());
}
