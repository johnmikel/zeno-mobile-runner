import { randomUUID } from "node:crypto";
import {
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from "node:path";

import {
  canonicalBytes,
  EvidenceValidationError,
  isSha256Digest,
  sha256Bytes,
  sha256File,
} from "./canonical-json.mjs";
import {
  assertValidEvidenceManifest,
  stableSortManifest,
} from "./contract.mjs";

const MAX_ARTIFACT_BYTES = 128 * 1024 * 1024;
const PACKAGE_WRITER_TEST_HOOK = Symbol.for("dev.zmr.evidence.package-writer.test-hook");
const ARTIFACT_REDACTION_STATES = ["unreviewed", "reviewed", "redacted"];
const DISCLOSURE_STATES = ["private", "review_eligible", "disclosed", "withheld"];
const BODY_INPUT_PROPERTIES = new Set([
  "itemIndex",
  "body",
  "type",
  "contentType",
  "redactionState",
  "disclosureState",
]);
const SOURCE_INPUT_PROPERTIES = new Set([
  "itemIndex",
  "sourcePath",
  "allowedRoot",
  "type",
  "contentType",
  "redactionState",
  "disclosureState",
]);

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validationError(code, message, path) {
  return new EvidenceValidationError(message, { code, path });
}

function invalidInput(index, field, message = "artifact input is invalid") {
  const path = field === undefined
    ? `/artifactInputs/${index}`
    : `/artifactInputs/${index}/${field}`;
  return validationError("invalid_artifact_input", message, path);
}

function invalidSource(message = "artifact source is not an authorized regular file") {
  return validationError("invalid_artifact_source", message, "/artifactInputs/sourcePath");
}

async function runPackageWriterTestHook(event) {
  const hook = globalThis[PACKAGE_WRITER_TEST_HOOK];
  if (typeof hook === "function") await hook(Object.freeze(event));
}

function isContained(rootPath, candidatePath) {
  const child = relative(rootPath, candidatePath);
  return child !== ""
    && !isAbsolute(child)
    && child !== ".."
    && !child.startsWith(`..${sep}`);
}

async function pathExists(path) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function acquirePublishLock(destination) {
  const lockPath = join(dirname(destination), `.${basename(destination)}.publish.lock`);
  try {
    await mkdir(lockPath, { mode: 0o700 });
  } catch (cause) {
    if (cause?.code === "EEXIST") {
      throw validationError(
        "package_publish_locked",
        "Another evidence package writer is publishing to this destination",
        "/destination",
      );
    }
    throw validationError(
      "package_publish_failed",
      "Evidence package publication lock could not be acquired",
      "/destination",
    );
  }
  return lockPath;
}

function cloneDraft(value, path = "", active = new Set()) {
  if (value === null || typeof value !== "object") return value;
  if (active.has(value)) {
    throw validationError("invalid_evidence_manifest", "Evidence manifest cannot contain cycles", path);
  }
  if (!Array.isArray(value)) {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      throw validationError(
        "invalid_evidence_manifest",
        "Evidence manifest must contain plain JSON objects",
        path,
      );
    }
  }

  active.add(value);
  try {
    if (Array.isArray(value)) {
      return value.map((entry, index) => cloneDraft(entry, `${path}/${index}`, active));
    }
    const cloned = {};
    for (const key of Object.keys(value)) {
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (descriptor === undefined || !("value" in descriptor)) {
        throw validationError(
          "invalid_evidence_manifest",
          "Evidence manifest must use data properties",
          `${path}/${key}`,
        );
      }
      Object.defineProperty(cloned, key, {
        configurable: true,
        enumerable: true,
        value: cloneDraft(descriptor.value, `${path}/${key}`, active),
        writable: true,
      });
    }
    return cloned;
  } finally {
    active.delete(value);
  }
}

export function artifactPathForDigest(digest) {
  if (!isSha256Digest(digest)) {
    throw validationError(
      "invalid_artifact_digest",
      "Artifact digest must be a lowercase sha256 value",
      "/digest",
    );
  }
  const hex = digest.slice("sha256:".length);
  return `artifacts/sha256/${hex.slice(0, 2)}/${hex.slice(2)}`;
}

function validateMetadata(input, index) {
  if (typeof input.type !== "string" || input.type.length === 0) {
    throw invalidInput(index, "type");
  }
  if (typeof input.contentType !== "string" || input.contentType.length === 0) {
    throw invalidInput(index, "contentType");
  }
  if (!ARTIFACT_REDACTION_STATES.includes(input.redactionState)) {
    throw invalidInput(index, "redactionState");
  }
  if (!DISCLOSURE_STATES.includes(input.disclosureState)) {
    throw invalidInput(index, "disclosureState");
  }
}

function validateClosedInput(input, allowedProperties, index) {
  for (const key of Object.keys(input)) {
    if (!allowedProperties.has(key)) throw invalidInput(index, key);
  }
}

async function lstatSourceComponents(rootPath, sourcePath) {
  const child = relative(rootPath, sourcePath);
  if (
    child === ""
    || isAbsolute(child)
    || child === ".."
    || child.startsWith(`..${sep}`)
  ) {
    throw invalidSource();
  }

  const segments = child.split(sep);
  let current = rootPath;
  for (let index = 0; index < segments.length; index += 1) {
    current = join(current, segments[index]);
    let info;
    try {
      info = await lstat(current);
    } catch {
      throw invalidSource();
    }
    if (info.isSymbolicLink()) throw invalidSource();
    if (index < segments.length - 1 && !info.isDirectory()) throw invalidSource();
    if (index === segments.length - 1 && !info.isFile()) throw invalidSource();
  }
}

async function readAuthorizedSource(sourcePath, allowedRoot) {
  const lexicalRoot = resolve(allowedRoot);
  const lexicalSource = resolve(sourcePath);
  let resolvedRoot;
  let resolvedSource;
  try {
    resolvedRoot = await realpath(lexicalRoot);
    resolvedSource = await realpath(lexicalSource);
  } catch {
    throw invalidSource();
  }

  let rootInfo;
  try {
    rootInfo = await lstat(resolvedRoot);
  } catch {
    throw invalidSource();
  }
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw invalidSource();
  if (!isContained(lexicalRoot, lexicalSource) || !isContained(resolvedRoot, resolvedSource)) {
    throw invalidSource();
  }
  await lstatSourceComponents(lexicalRoot, lexicalSource);

  let handle;
  try {
    handle = await open(lexicalSource, "r");
    const info = await handle.stat();
    if (!info.isFile()) throw invalidSource();
    if (info.size > MAX_ARTIFACT_BYTES) {
      throw validationError(
        "artifact_too_large",
        "Artifact exceeds the 128 MiB Evidence Contract v1 limit",
        "/artifactInputs/sourcePath",
      );
    }
    const bytes = await handle.readFile();
    if (bytes.length !== info.size) throw invalidSource("artifact source changed while it was read");
    return bytes;
  } catch (error) {
    if (error instanceof EvidenceValidationError) throw error;
    throw invalidSource();
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function normalizeArtifactInput(input, index, itemCount) {
  if (!isObject(input)) throw invalidInput(index);
  if (!Number.isInteger(input.itemIndex) || input.itemIndex < 0 || input.itemIndex >= itemCount) {
    throw invalidInput(index, "itemIndex");
  }

  const hasBody = hasOwn(input, "body");
  const hasSource = hasOwn(input, "sourcePath");
  const hasRoot = hasOwn(input, "allowedRoot");
  const isBodyBranch = hasBody && !hasSource && !hasRoot;
  const isSourceBranch = !hasBody && hasSource && hasRoot;
  if (!isBodyBranch && !isSourceBranch) throw invalidInput(index);

  validateClosedInput(
    input,
    isBodyBranch ? BODY_INPUT_PROPERTIES : SOURCE_INPUT_PROPERTIES,
    index,
  );
  validateMetadata(input, index);

  let bytes;
  if (isBodyBranch) {
    if (!Buffer.isBuffer(input.body) && !(input.body instanceof Uint8Array)) {
      throw invalidInput(index, "body");
    }
    if (input.body.byteLength > MAX_ARTIFACT_BYTES) {
      throw validationError(
        "artifact_too_large",
        "Artifact exceeds the 128 MiB Evidence Contract v1 limit",
        `/artifactInputs/${index}/body`,
      );
    }
    bytes = Buffer.from(input.body);
  } else {
    if (
      typeof input.sourcePath !== "string" || input.sourcePath.length === 0
      || typeof input.allowedRoot !== "string" || input.allowedRoot.length === 0
    ) {
      throw invalidInput(index);
    }
    bytes = await readAuthorizedSource(input.sourcePath, input.allowedRoot);
  }

  const digest = sha256Bytes(bytes);
  return {
    bytes,
    descriptor: {
      type: input.type,
      path: artifactPathForDigest(digest),
      digest,
      sizeBytes: bytes.length,
      contentType: input.contentType,
      redactionState: input.redactionState,
      disclosureState: input.disclosureState,
    },
    itemIndex: input.itemIndex,
  };
}

async function syncFile(path) {
  const handle = await open(path, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function writeStagedPackage(tempPath, manifest, evidenceBytes, uniqueArtifacts) {
  await mkdir(tempPath, { mode: 0o700 });
  await runPackageWriterTestHook({ phase: "staged", tempPath });
  for (const [digest, bytes] of [...uniqueArtifacts.entries()].sort(([left], [right]) => (
    left < right ? -1 : left > right ? 1 : 0
  ))) {
    const relativePath = artifactPathForDigest(digest);
    const destination = join(tempPath, ...relativePath.split("/"));
    await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
    await writeFile(destination, bytes, { flag: "wx", mode: 0o600 });
    const info = await lstat(destination);
    if (!info.isFile() || info.isSymbolicLink() || info.size !== bytes.length) {
      throw validationError(
        "artifact_write_verification_failed",
        "Packaged artifact could not be verified",
        "/artifacts",
      );
    }
    if (await sha256File(destination) !== digest) {
      throw validationError(
        "artifact_write_verification_failed",
        "Packaged artifact digest verification failed",
        "/artifacts",
      );
    }
  }

  const manifestPath = join(tempPath, "evidence.json");
  await writeFile(manifestPath, evidenceBytes, { flag: "wx", mode: 0o600 });
  await syncFile(manifestPath);
  return manifest;
}

async function restoreBackupAfterFailure(destination, backup, tempPath, newPublished) {
  if (newPublished) {
    try {
      await rename(destination, tempPath);
    } catch {
      return false;
    }
  }
  try {
    await rename(backup, destination);
  } catch {
    if (newPublished) {
      await rename(tempPath, destination).catch(() => {});
    }
    return false;
  }
  if (newPublished) await rm(tempPath, { recursive: true, force: true }).catch(() => {});
  return true;
}

async function publishStagedPackage(tempPath, destination, force) {
  const parent = dirname(destination);
  const stem = basename(destination);
  const backup = join(parent, `.${stem}.backup-${randomUUID()}`);
  let tempExists = true;
  let backupExists = false;
  let newPublished = false;

  try {
    if (force && await pathExists(destination)) {
      await rename(destination, backup);
      backupExists = true;
      await runPackageWriterTestHook({ phase: "backup_moved", destination, tempPath });
    }
    if (!force) {
      // Portable Node 18 has no directory rename-without-replace primitive. The sibling
      // lock serializes cooperating writers; this lstat narrows, but cannot eliminate,
      // the final recheck-to-rename race with an arbitrary noncooperating creator.
      if (await pathExists(destination)) {
        throw validationError(
          "destination_exists",
          "Evidence package destination already exists",
          "/destination",
        );
      }
    }
    await rename(tempPath, destination);
    tempExists = false;
    newPublished = true;
    if (backupExists) {
      await rm(backup, { recursive: true, force: true });
      backupExists = false;
    }
  } catch (cause) {
    if (backupExists) {
      const restored = await restoreBackupAfterFailure(
        destination,
        backup,
        tempPath,
        newPublished,
      );
      if (restored) {
        backupExists = false;
        newPublished = false;
      }
    }
    if (cause instanceof EvidenceValidationError) throw cause;
    throw validationError(
      "package_publish_failed",
      "Evidence package could not be published atomically",
      "/destination",
    );
  } finally {
    if (tempExists) await rm(tempPath, { recursive: true, force: true }).catch(() => {});
  }
}

export async function writeEvidencePackage({
  destination,
  manifest,
  artifactInputs,
  force = false,
} = {}) {
  if (typeof destination !== "string" || destination.length === 0) {
    throw validationError("invalid_package_options", "destination must be a non-empty string", "/destination");
  }
  if (!Array.isArray(artifactInputs)) {
    throw validationError("invalid_package_options", "artifactInputs must be an array", "/artifactInputs");
  }
  if (typeof force !== "boolean") {
    throw validationError("invalid_package_options", "force must be a boolean", "/force");
  }

  const destinationPath = resolve(destination);
  const parent = dirname(destinationPath);
  const stem = basename(destinationPath);
  if (destinationPath === parent || stem.length === 0) {
    throw validationError("invalid_package_options", "destination must name a package directory", "/destination");
  }
  await mkdir(parent, { recursive: true });
  if (!force && await pathExists(destinationPath)) {
    throw validationError(
      "destination_exists",
      "Evidence package destination already exists",
      "/destination",
    );
  }

  assertValidEvidenceManifest(manifest);
  const draft = cloneDraft(manifest);
  assertValidEvidenceManifest(draft);
  for (let index = 0; index < draft.items.length; index += 1) {
    if (draft.items[index].artifacts.length !== 0) {
      throw validationError(
        "invalid_manifest_draft",
        "Evidence manifest draft items must start with empty artifacts arrays",
        `/items/${index}/artifacts`,
      );
    }
  }

  const normalized = [];
  for (let index = 0; index < artifactInputs.length; index += 1) {
    normalized.push(await normalizeArtifactInput(artifactInputs[index], index, draft.items.length));
  }
  const uniqueArtifacts = new Map();
  for (const entry of normalized) {
    draft.items[entry.itemIndex].artifacts.push(entry.descriptor);
    if (!uniqueArtifacts.has(entry.descriptor.digest)) {
      uniqueArtifacts.set(entry.descriptor.digest, entry.bytes);
    }
  }

  const finalManifest = stableSortManifest(draft);
  assertValidEvidenceManifest(finalManifest);
  const manifestDigest = sha256Bytes(canonicalBytes(finalManifest));
  const evidenceBytes = Buffer.from(`${JSON.stringify(finalManifest, null, 2)}\n`, "utf8");
  const tempPath = join(parent, `.${stem}.tmp-${randomUUID()}`);
  const lockPath = await acquirePublishLock(destinationPath);

  try {
    await writeStagedPackage(tempPath, finalManifest, evidenceBytes, uniqueArtifacts);
    await publishStagedPackage(tempPath, destinationPath, force);
  } catch (error) {
    await rm(tempPath, { recursive: true, force: true }).catch(() => {});
    throw error;
  } finally {
    await rm(lockPath, { recursive: true, force: true }).catch(() => {});
  }

  return {
    manifest: finalManifest,
    manifestDigest,
    manifestPath: join(destinationPath, "evidence.json"),
  };
}

function packageArtifactError(code, message, path) {
  return validationError(code, message, path);
}

async function validateStoredArtifact(packageRoot, descriptor, path) {
  const segments = descriptor.path.split("/");
  let current = packageRoot;
  let leafInfo;
  for (let index = 0; index < segments.length; index += 1) {
    current = join(current, segments[index]);
    let info;
    try {
      info = await lstat(current);
    } catch {
      throw packageArtifactError("artifact_missing", "Packaged artifact is missing", `${path}/path`);
    }
    if (info.isSymbolicLink()) {
      throw packageArtifactError(
        "unsafe_package_artifact",
        "Packaged artifact paths must not contain symbolic links",
        `${path}/path`,
      );
    }
    if (index < segments.length - 1 && !info.isDirectory()) {
      throw packageArtifactError(
        "unsafe_package_artifact",
        "Packaged artifact path contains a non-directory component",
        `${path}/path`,
      );
    }
    if (index === segments.length - 1) leafInfo = info;
  }

  if (!leafInfo?.isFile()) {
    throw packageArtifactError(
      "unsafe_package_artifact",
      "Packaged artifact must be a regular file",
      `${path}/path`,
    );
  }
  let resolvedLeaf;
  try {
    resolvedLeaf = await realpath(current);
  } catch {
    throw packageArtifactError("artifact_missing", "Packaged artifact is missing", `${path}/path`);
  }
  if (!isContained(packageRoot, resolvedLeaf)) {
    throw packageArtifactError(
      "unsafe_package_artifact",
      "Packaged artifact must remain inside the package",
      `${path}/path`,
    );
  }
  if (leafInfo.size !== descriptor.sizeBytes) {
    throw packageArtifactError(
      "artifact_size_mismatch",
      "Packaged artifact size does not match its descriptor",
      `${path}/sizeBytes`,
    );
  }
  if (await sha256File(current) !== descriptor.digest) {
    throw packageArtifactError(
      "artifact_digest_mismatch",
      "Packaged artifact digest does not match its descriptor",
      `${path}/digest`,
    );
  }
}

export async function validateEvidencePackage(manifestPath) {
  if (typeof manifestPath !== "string" || manifestPath.length === 0) {
    throw validationError("invalid_package_options", "manifestPath must be a non-empty string", "/manifestPath");
  }
  const lexicalManifest = resolve(manifestPath);
  let manifestInfo;
  try {
    manifestInfo = await lstat(lexicalManifest);
  } catch {
    throw validationError("invalid_evidence_package", "Evidence manifest is missing", "/manifestPath");
  }
  if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink()) {
    throw validationError(
      "invalid_evidence_package",
      "Evidence manifest must be a regular file",
      "/manifestPath",
    );
  }

  let packageRoot;
  let resolvedManifest;
  try {
    packageRoot = await realpath(dirname(lexicalManifest));
    resolvedManifest = await realpath(lexicalManifest);
  } catch {
    throw validationError("invalid_evidence_package", "Evidence package cannot be resolved", "/manifestPath");
  }
  if (!isContained(packageRoot, resolvedManifest)) {
    throw validationError(
      "invalid_evidence_package",
      "Evidence manifest must remain inside its package",
      "/manifestPath",
    );
  }

  let manifest;
  try {
    manifest = JSON.parse(await readFile(lexicalManifest, "utf8"));
  } catch {
    throw validationError("invalid_evidence_json", "Evidence manifest is not valid JSON", "/manifestPath");
  }
  assertValidEvidenceManifest(manifest);

  for (let itemIndex = 0; itemIndex < manifest.items.length; itemIndex += 1) {
    for (
      let artifactIndex = 0;
      artifactIndex < manifest.items[itemIndex].artifacts.length;
      artifactIndex += 1
    ) {
      await validateStoredArtifact(
        packageRoot,
        manifest.items[itemIndex].artifacts[artifactIndex],
        `/items/${itemIndex}/artifacts/${artifactIndex}`,
      );
    }
  }

  return {
    ok: true,
    manifest,
    manifestDigest: sha256Bytes(canonicalBytes(manifest)),
    manifestPath: lexicalManifest,
  };
}
