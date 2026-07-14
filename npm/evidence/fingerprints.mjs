import {
  canonicalBytes,
  EvidenceValidationError,
  isSha256Digest,
  sha256Bytes,
} from "./canonical-json.mjs";

function fingerprintInputError(field, message) {
  throw new EvidenceValidationError(`${field} ${message}`, {
    code: "invalid_fingerprint_input",
    field,
    path: field,
  });
}

function validateRequiredString(input, field) {
  const value = input?.[field];
  if (typeof value !== "string") {
    fingerprintInputError(field, "must be a string");
  }
  if (value.trim().length === 0) {
    fingerprintInputError(field, "must not be blank");
  }
  return value;
}

function validateExactString(input, field, allowedValues) {
  const value = validateRequiredString(input, field);
  if (!allowedValues.includes(value)) {
    fingerprintInputError(field, `must be ${allowedValues.join(" or ")}`);
  }
  return value;
}

function validateDigest(input, field) {
  const value = validateRequiredString(input, field);
  if (!isSha256Digest(value)) {
    fingerprintInputError(field, "must be a lowercase sha256: digest");
  }
  return value;
}

export function buildMobileFingerprintInput(input) {
  return {
    appId: validateRequiredString(input, "appId"),
    artifactDigest: validateDigest(input, "artifactDigest"),
    buildNumber: validateRequiredString(input, "buildNumber"),
    recipe: validateExactString(input, "recipe", ["mobile-v1"]),
    surface: validateExactString(input, "surface", ["ios", "android"]),
    version: validateRequiredString(input, "version"),
  };
}

export function buildWebFingerprintInput(input) {
  return {
    buildManifestDigest: validateDigest(input, "buildManifestDigest"),
    commitSha: validateRequiredString(input, "commitSha"),
    configDigest: validateDigest(input, "configDigest"),
    deploymentId: validateRequiredString(input, "deploymentId"),
    environment: validateRequiredString(input, "environment"),
    recipe: validateExactString(input, "recipe", ["web-v1"]),
    surface: validateExactString(input, "surface", ["web"]),
  };
}

export function createMobileFingerprint(input) {
  return sha256Bytes(canonicalBytes(buildMobileFingerprintInput(input)));
}

export function createWebFingerprint(input) {
  return sha256Bytes(canonicalBytes(buildWebFingerprintInput(input)));
}

export function isRegisteredTarget(target) {
  if (target === null || typeof target !== "object" || Array.isArray(target)) {
    return false;
  }

  return (
    (target.surface === "ios" || target.surface === "android")
      && target.fingerprintRecipe === "mobile-v1"
  ) || (
    target.surface === "web"
      && target.fingerprintRecipe === "web-v1"
  );
}

export function recomputeTargetFingerprint(target) {
  if (!isRegisteredTarget(target)) {
    throw new EvidenceValidationError(
      "fingerprintRecipe is not registered for the target surface",
      {
        code: "unregistered_fingerprint_recipe",
        field: "fingerprintRecipe",
        path: "fingerprintRecipe",
      },
    );
  }

  if (target.fingerprintRecipe === "mobile-v1") {
    return createMobileFingerprint({
      appId: target.appId,
      artifactDigest: target.artifactDigest,
      buildNumber: target.buildNumber,
      recipe: target.fingerprintRecipe,
      surface: target.surface,
      version: target.version,
    });
  }

  return createWebFingerprint({
    buildManifestDigest: target.buildManifestDigest,
    commitSha: target.commitSha,
    configDigest: target.configDigest,
    deploymentId: target.deploymentId,
    environment: target.environment,
    recipe: target.fingerprintRecipe,
    surface: target.surface,
  });
}
