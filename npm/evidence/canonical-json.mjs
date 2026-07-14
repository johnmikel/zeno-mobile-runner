import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";

const SHA256_DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/;
const WINDOWS_DRIVE_PATTERN = /^[A-Za-z]:/;
const WINDOWS_RESERVED_DEVICE_PATTERN = /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$/i;
const MAX_CANONICAL_DEPTH = 512;

export class EvidenceValidationError extends Error {
  constructor(message, {
    code = "evidence_validation_error",
    field,
    path,
  } = {}) {
    super(message);
    this.name = "EvidenceValidationError";
    this.code = code;
    if (field !== undefined) this.field = field;
    if (path !== undefined) this.path = path;
  }
}

function validationError(message, path, code = "invalid_canonical_json") {
  return new EvidenceValidationError(`${message} at ${path}`, {
    code,
    path,
  });
}

function isWellFormedString(value) {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (index + 1 >= value.length || next < 0xdc00 || next > 0xdfff) return false;
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function jsonPointerSegment(value) {
  return value.replaceAll("~", "~0").replaceAll("/", "~1");
}

function serializeString(value, path) {
  if (!isWellFormedString(value)) {
    throw validationError("Canonical JSON strings must contain valid Unicode", path);
  }
  return JSON.stringify(value);
}

function withActiveContainer(value, activeContainers, path, serialize) {
  if (activeContainers.has(value)) {
    throw validationError("Canonical JSON cannot contain cycles", path);
  }

  activeContainers.add(value);
  try {
    return serialize();
  } finally {
    activeContainers.delete(value);
  }
}

function dataPropertyValue(container, key, path) {
  const descriptor = Object.getOwnPropertyDescriptor(container, key);
  if (descriptor === undefined || !("value" in descriptor)) {
    throw validationError(
      "Canonical JSON containers must use data properties, not accessor properties",
      path,
    );
  }
  return descriptor.value;
}

function serializeArray(value, activeContainers, path, depth) {
  return withActiveContainer(value, activeContainers, path, () => {
    if (Object.getOwnPropertySymbols(value).length > 0) {
      throw validationError("Canonical JSON arrays cannot have symbol properties", path);
    }

    for (const key of Object.keys(value)) {
      if (!/^(?:0|[1-9][0-9]*)$/.test(key) || Number(key) >= value.length) {
        throw validationError("Canonical JSON arrays cannot have named properties", `${path}/${jsonPointerSegment(key)}`);
      }
    }

    const items = [];
    for (let index = 0; index < value.length; index += 1) {
      const itemPath = `${path}/${index}`;
      const item = dataPropertyValue(value, String(index), itemPath);
      items.push(serializeValue(item, activeContainers, itemPath, depth + 1));
    }
    return `[${items.join(",")}]`;
  });
}

function serializeObject(value, activeContainers, path, depth) {
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw validationError("Canonical JSON objects must be plain objects", path);
  }
  if (Object.getOwnPropertySymbols(value).length > 0) {
    throw validationError("Canonical JSON objects cannot have symbol properties", path);
  }

  return withActiveContainer(value, activeContainers, path, () => {
    const entries = [];
    for (const key of Object.keys(value).sort()) {
      const keyPath = `${path}/${jsonPointerSegment(key)}`;
      const propertyValue = dataPropertyValue(value, key, keyPath);
      entries.push(`${serializeString(key, keyPath)}:${serializeValue(propertyValue, activeContainers, keyPath, depth + 1)}`);
    }
    return `{${entries.join(",")}}`;
  });
}

function serializeValue(value, activeContainers, path, depth) {
  if (depth > MAX_CANONICAL_DEPTH) {
    throw validationError(
      `Canonical JSON exceeds maximum depth of ${MAX_CANONICAL_DEPTH}`,
      path,
      "canonical_depth_exceeded",
    );
  }
  if (value === null) return "null";

  switch (typeof value) {
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) {
        throw validationError("Canonical JSON numbers must be finite", path);
      }
      return JSON.stringify(value);
    case "string":
      return serializeString(value, path);
    case "object":
      return Array.isArray(value)
        ? serializeArray(value, activeContainers, path, depth)
        : serializeObject(value, activeContainers, path, depth);
    default:
      throw validationError(`Canonical JSON does not support ${typeof value} values`, path);
  }
}

export function canonicalize(value) {
  return serializeValue(value, new Set(), "$", 0);
}

export function canonicalBytes(value) {
  return Buffer.from(canonicalize(value), "utf8");
}

export function sha256Bytes(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

export async function sha256File(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk);
  }
  return `sha256:${hash.digest("hex")}`;
}

export function isSha256Digest(value) {
  return typeof value === "string" && SHA256_DIGEST_PATTERN.test(value);
}

export function assertSafeRelativePath(value, fieldName = "path") {
  const reject = (reason) => {
    throw new EvidenceValidationError(`${fieldName} ${reason}`, {
      code: "unsafe_relative_path",
      field: fieldName,
      path: fieldName,
    });
  };

  if (typeof value !== "string") reject("must be a string");
  if (value.length === 0) reject("must not be empty");
  if (!isWellFormedString(value)) reject("must contain valid Unicode");
  if (CONTROL_CHARACTER_PATTERN.test(value)) reject("must not contain control characters");
  if (value.includes("\\")) reject("must use forward slashes");
  if (value.startsWith("/")) reject("must be relative");
  if (WINDOWS_DRIVE_PATTERN.test(value)) reject("must not use a Windows drive path");
  if (value.includes(":")) reject("must not contain colons");

  for (const segment of value.split("/")) {
    if (segment.length === 0) reject("must not contain empty path segments");
    if (segment === "." || segment === "..") reject("must not contain dot path segments");
    if (WINDOWS_RESERVED_DEVICE_PATTERN.test(segment)) {
      reject("must not contain reserved Windows device names");
    }
    if (segment.endsWith(".") || segment.endsWith(" ")) {
      reject("must not contain segments ending in a dot or space");
    }
  }

  return value;
}
