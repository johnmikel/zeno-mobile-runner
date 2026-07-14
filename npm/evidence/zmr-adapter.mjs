import { createHash } from "node:crypto";
import { constants } from "node:fs";
import {
  lstat,
  open,
  readdir,
} from "node:fs/promises";
import {
  basename,
  dirname,
  extname,
  isAbsolute,
  join,
  parse as parsePath,
  relative,
  resolve,
  sep,
} from "node:path";

import {
  EvidenceValidationError,
  assertSafeRelativePath,
  canonicalBytes,
  isSha256Digest,
  sha256Bytes,
} from "./canonical-json.mjs";
import { assertValidEvidenceManifest } from "./contract.mjs";
import { createMobileFingerprint } from "./fingerprints.mjs";
import { DEFAULT_TAR_LIMITS, parseZmrTar } from "./tar.mjs";

const ADAPTER_VERSION = "1.0.0";
const APP_HASH_BUFFER_BYTES = 64 * 1024;
const ZMR_ADAPTER_TEST_HOOK = Symbol.for("dev.zmr.evidence.zmr-adapter.test-hook");
const IDENTITY_PATTERN = /^(?!\s)(?!.*\s$)[^\u0000-\u001f\u007f]+$/;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

const CONTENT_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".jpeg", "image/jpeg"],
  [".jpg", "image/jpeg"],
  [".json", "application/json"],
  [".jsonl", "application/x-ndjson"],
  [".log", "text/plain; charset=utf-8"],
  [".mp4", "video/mp4"],
  [".png", "image/png"],
  [".txt", "text/plain; charset=utf-8"],
  [".webm", "video/webm"],
  [".xml", "application/xml"],
]);

function adapterError(code, message, path) {
  return new EvidenceValidationError(message, {
    code,
    ...(path === undefined ? {} : { field: path, path }),
  });
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function compareText(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

async function runZmrAdapterTestHook(event) {
  const hook = globalThis[ZMR_ADAPTER_TEST_HOOK];
  if (typeof hook === "function") return hook(Object.freeze(event));
  return undefined;
}

function assertIdentity(value, field) {
  let length = 0;
  if (typeof value === "string") {
    for (const _character of value) {
      length += 1;
      if (length > 256) break;
    }
  }
  if (
    typeof value !== "string"
    || length < 1
    || length > 256
    || !IDENTITY_PATTERN.test(value)
  ) {
    throw adapterError(
      "invalid_identity",
      `${field} must be 1 to 256 characters with no edge whitespace or controls`,
      field,
    );
  }
  return value;
}

function assertNonemptyPath(value, field) {
  if (typeof value !== "string" || value.length === 0) {
    throw adapterError("invalid_adapter_options", `${field} must be a non-empty path`, field);
  }
  return value;
}

function assertDeclaredPath(value, field, { nullable = false } = {}) {
  if (nullable && value === null) return null;
  if (typeof value !== "string") {
    throw adapterError("invalid_trace_manifest", `${field} must be a string`, field);
  }
  try {
    return assertSafeRelativePath(value, field);
  } catch (error) {
    if (!(error instanceof EvidenceValidationError)) throw error;
    throw adapterError("unsafe_trace_path", `${field} must be a safe relative path`, field);
  }
}

function inferContentType(path) {
  return CONTENT_TYPES.get(extname(path).toLowerCase()) ?? "application/octet-stream";
}

async function assertNoSymlinkComponents(absolutePath, finalKind, label) {
  if (!isAbsolute(absolutePath)) {
    throw adapterError("invalid_source_path", `${label} could not be resolved`, label);
  }
  const root = parsePath(absolutePath).root;
  const parts = relative(root, absolutePath).split(sep).filter((part) => part.length > 0);
  let current = root;
  let finalStats;
  try {
    for (const part of parts) {
      current = join(current, part);
      const stats = await lstat(current);
      if (stats.isSymbolicLink()) {
        throw adapterError("symlink_source_rejected", `${label} contains a symbolic link`, label);
      }
      finalStats = stats;
    }
  } catch (error) {
    if (error instanceof EvidenceValidationError) throw error;
    throw adapterError("invalid_source_path", `${label} is unavailable`, label);
  }
  if (finalStats === undefined) {
    finalStats = await lstat(root);
  }
  if (finalKind === "file" && !finalStats.isFile()) {
    throw adapterError("source_not_regular_file", `${label} must be a regular file`, label);
  }
  if (finalKind === "directory" && !finalStats.isDirectory()) {
    throw adapterError("source_not_directory", `${label} must be a directory`, label);
  }
  return finalStats;
}

async function readRegularFile(absolutePath, maxBytes, label) {
  await assertNoSymlinkComponents(absolutePath, "file", label);
  let handle;
  try {
    handle = await open(absolutePath, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    const before = await handle.stat({ bigint: true });
    if (!before.isFile()) {
      throw adapterError("source_not_regular_file", `${label} must be a regular file`, label);
    }
    if (before.size > BigInt(maxBytes)) {
      throw adapterError("source_file_too_large", `${label} exceeds the file-size limit`, label);
    }
    const body = await handle.readFile();
    const after = await handle.stat({ bigint: true });
    if (
      before.dev !== after.dev
      || before.ino !== after.ino
      || before.size !== after.size
      || before.mtimeNs !== after.mtimeNs
      || BigInt(body.length) !== after.size
    ) {
      throw adapterError("source_changed_during_read", `${label} changed while it was read`, label);
    }
    return body;
  } catch (error) {
    if (error instanceof EvidenceValidationError) throw error;
    throw adapterError("invalid_source_path", `${label} could not be read`, label);
  } finally {
    await handle?.close().catch(() => {});
  }
}

function parseJson(body, code, label) {
  let text;
  try {
    text = utf8Decoder.decode(body);
  } catch {
    throw adapterError(code, `${label} must contain valid UTF-8`, label);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw adapterError(code, `${label} must contain valid JSON`, label);
  }
}

function declaredTracePaths(trace) {
  if (!isObject(trace)) {
    throw adapterError("invalid_trace_manifest", "trace.json must contain an object", "trace.json");
  }
  const eventsPath = assertDeclaredPath(trace.eventsPath, "trace.eventsPath");
  const artifactsDir = assertDeclaredPath(trace.artifactsDir, "trace.artifactsDir");
  const reportPath = assertDeclaredPath(trace.reportPath, "trace.reportPath", { nullable: true });
  const exactPaths = new Set(["trace.json", eventsPath]);
  if (reportPath !== null) exactPaths.add(reportPath);
  if (exactPaths.size !== (reportPath === null ? 2 : 3)) {
    throw adapterError("duplicate_trace_path", "Declared trace paths must be distinct");
  }
  if ([...exactPaths].some((path) => path === artifactsDir)) {
    throw adapterError("overlapping_trace_path", "Declared files must not equal artifactsDir");
  }
  return { eventsPath, artifactsDir, reportPath, exactPaths };
}

function sourceManifestDigest(entries) {
  const index = entries
    .map((entry) => ({
      path: entry.path,
      digest: entry.digest ?? sha256Bytes(entry.body),
      sizeBytes: entry.sizeBytes,
    }))
    .sort((left, right) => compareText(left.path, right.path));
  return sha256Bytes(canonicalBytes(index));
}

function directoryEntry(path, body, root) {
  return {
    path,
    body,
    digest: sha256Bytes(body),
    sizeBytes: body.length,
    contentType: inferContentType(path),
    sourcePath: join(root, ...path.split("/")),
    allowedRoot: root,
  };
}

async function loadDirectoryTrace(inputPath) {
  const root = resolve(inputPath);
  await assertNoSymlinkComponents(root, "directory", "tracePath");
  const entries = [];
  let totalBytes = 0;

  const addFile = async (path) => {
    if (entries.some((entry) => entry.path === path)) {
      throw adapterError("duplicate_trace_path", `Trace source repeats ${path}`);
    }
    if (entries.length >= DEFAULT_TAR_LIMITS.maxEntries) {
      throw adapterError("trace_file_limit_exceeded", "Trace directory exceeds the file-count limit");
    }
    const remaining = DEFAULT_TAR_LIMITS.maxTotalBytes - totalBytes;
    const body = await readRegularFile(
      join(root, ...path.split("/")),
      Math.min(DEFAULT_TAR_LIMITS.maxEntryBytes, remaining),
      path,
    );
    totalBytes += body.length;
    entries.push(directoryEntry(path, body, root));
    return body;
  };

  const traceBody = await addFile("trace.json");
  const trace = parseJson(traceBody, "invalid_trace_json", "trace.json");
  const paths = declaredTracePaths(trace);
  await addFile(paths.eventsPath);
  if (paths.reportPath !== null) await addFile(paths.reportPath);

  const artifactsAbsolute = join(root, ...paths.artifactsDir.split("/"));
  let artifactsStats;
  try {
    artifactsStats = await assertNoSymlinkComponents(
      artifactsAbsolute,
      "directory",
      "trace.artifactsDir",
    );
  } catch (error) {
    if (error instanceof EvidenceValidationError && error.code === "invalid_source_path") {
      artifactsStats = null;
    } else {
      throw error;
    }
  }

  const walk = async (absoluteDirectory, relativeDirectory) => {
    const children = await readdir(absoluteDirectory, { withFileTypes: true });
    children.sort((left, right) => compareText(left.name, right.name));
    for (const child of children) {
      const relativePath = `${relativeDirectory}/${child.name}`;
      const absolutePath = join(absoluteDirectory, child.name);
      const stats = await lstat(absolutePath);
      if (stats.isSymbolicLink()) {
        throw adapterError(
          "symlink_source_rejected",
          "trace.artifactsDir contains a symbolic link",
          "trace.artifactsDir",
        );
      }
      if (stats.isDirectory()) {
        await walk(absolutePath, relativePath);
      } else if (stats.isFile()) {
        assertDeclaredPath(relativePath, "trace.artifactPath");
        if (!entries.some((entry) => entry.path === relativePath)) {
          await addFile(relativePath);
        }
      } else {
        throw adapterError(
          "unsupported_source_file_type",
          "trace.artifactsDir contains an unsupported file type",
          "trace.artifactsDir",
        );
      }
    }
  };
  if (artifactsStats !== null) await walk(artifactsAbsolute, paths.artifactsDir);

  entries.sort((left, right) => compareText(left.path, right.path));
  return {
    kind: "directory",
    root,
    trace,
    entries,
    sourceManifestDigest: sourceManifestDigest(entries),
  };
}

async function loadArchiveTrace(inputPath) {
  if (extname(inputPath) !== ".zmrtrace") {
    throw adapterError("unsupported_trace_source", "Trace file must use the .zmrtrace extension", "tracePath");
  }
  const absolutePath = resolve(inputPath);
  const archive = await readRegularFile(
    absolutePath,
    DEFAULT_TAR_LIMITS.maxArchiveBytes,
    "tracePath",
  );
  const entries = parseZmrTar(archive);
  const traceEntry = entries.find((entry) => entry.path === "trace.json");
  if (traceEntry === undefined) {
    throw adapterError("missing_trace_manifest", "ZMR archive must contain trace.json");
  }
  const trace = parseJson(traceEntry.body, "invalid_trace_json", "trace.json");
  const paths = declaredTracePaths(trace);
  for (const entry of entries) {
    if (
      !paths.exactPaths.has(entry.path)
      && !entry.path.startsWith(`${paths.artifactsDir}/`)
    ) {
      throw adapterError("unexpected_trace_entry", `ZMR archive contains undeclared entry ${entry.path}`);
    }
  }
  if (!entries.some((entry) => entry.path === paths.eventsPath)) {
    throw adapterError("missing_trace_events", "ZMR archive is missing its declared events file");
  }
  if (
    paths.reportPath !== null
    && !entries.some((entry) => entry.path === paths.reportPath)
  ) {
    throw adapterError("missing_trace_report", "ZMR archive is missing its declared report");
  }
  return {
    kind: "archive",
    trace,
    entries,
    sourceManifestDigest: sourceManifestDigest(entries),
  };
}

export async function loadZmrTrace(inputPath) {
  assertNonemptyPath(inputPath, "tracePath");
  const absolutePath = resolve(inputPath);
  let stats;
  try {
    stats = await assertNoSymlinkComponents(absolutePath, undefined, "tracePath");
  } catch (error) {
    throw error;
  }
  if (stats.isDirectory()) return loadDirectoryTrace(absolutePath);
  if (stats.isFile()) return loadArchiveTrace(absolutePath);
  throw adapterError("unsupported_trace_source", "tracePath must be a directory or .zmrtrace file");
}

function validateTraceManifest(trace) {
  if (trace.schemaVersion !== 1) {
    throw adapterError("unsupported_trace_schema", "trace schemaVersion must be exactly 1", "trace.schemaVersion");
  }
  assertIdentity(trace.runnerVersion, "trace.runnerVersion");
  assertIdentity(trace.protocolVersion, "trace.protocolVersion");
  assertIdentity(trace.scenarioName, "trace.scenarioName");
  if (trace.appId !== null) assertIdentity(trace.appId, "trace.appId");
  if (!(["passed", "failed", "partial"].includes(trace.status))) {
    throw adapterError("incomplete_trace", "trace status must be passed, failed, or partial", "trace.status");
  }
  for (const field of [
    "startedAtMs",
    "endedAtMs",
    "durationMs",
    "eventCount",
    "snapshotCount",
    "partialFailureCount",
  ]) {
    if (!Number.isSafeInteger(trace[field]) || trace[field] < 0) {
      throw adapterError("invalid_trace_manifest", `trace.${field} must be a non-negative safe integer`, `trace.${field}`);
    }
  }
  if (trace.endedAtMs < trace.startedAtMs) {
    throw adapterError("invalid_trace_timing", "trace endedAtMs must not precede startedAtMs");
  }
  if (trace.durationMs !== trace.endedAtMs - trace.startedAtMs) {
    throw adapterError("invalid_trace_timing", "trace durationMs must equal endedAtMs minus startedAtMs");
  }
  if (
    Number.isNaN(new Date(trace.startedAtMs).valueOf())
    || Number.isNaN(new Date(trace.endedAtMs).valueOf())
  ) {
    throw adapterError("invalid_trace_timing", "trace timestamps must be representable dates");
  }
  if (
    trace.failedStepIndex !== null
    && (!Number.isSafeInteger(trace.failedStepIndex) || trace.failedStepIndex < 0)
  ) {
    throw adapterError("invalid_trace_manifest", "trace.failedStepIndex must be null or non-negative");
  }
  if (trace.error !== null && (typeof trace.error !== "string" || trace.error.length === 0)) {
    throw adapterError("invalid_trace_manifest", "trace.error must be null or a non-empty string");
  }
  if (trace.status === "partial" && trace.partialFailureCount < 1) {
    throw adapterError("invalid_partial_trace", "partial traces require a positive partialFailureCount");
  }
  if (trace.redaction !== undefined) {
    if (!isObject(trace.redaction) || typeof trace.redaction.enabled !== "boolean") {
      throw adapterError("invalid_trace_redaction", "trace.redaction must contain an enabled boolean");
    }
    canonicalBytes(trace.redaction);
  }
}

function parseEvents(entry, trace) {
  let text;
  try {
    text = utf8Decoder.decode(entry.body);
  } catch {
    throw adapterError("invalid_trace_events", "events JSONL must contain valid UTF-8");
  }
  const lines = text.split("\n");
  if (lines.at(-1) === "") lines.pop();
  if (lines.length === 0 || lines.some((line) => line.length === 0)) {
    throw adapterError("invalid_trace_events", "events JSONL must contain one JSON object per non-empty line");
  }
  const events = lines.map((line, index) => {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      throw adapterError("invalid_trace_events", `events JSONL row ${index + 1} is malformed`);
    }
    if (!isObject(event) || typeof event.kind !== "string" || !isObject(event.payload)) {
      throw adapterError("invalid_trace_events", `events JSONL row ${index + 1} has an invalid shape`);
    }
    return event;
  });
  if (trace.eventCount !== events.length) {
    throw adapterError("trace_event_count_mismatch", "trace eventCount does not match parsed JSONL rows");
  }
  const terminals = events.filter((event) => event.kind === "scenario.end");
  if (terminals.length !== 1 || events.at(-1) !== terminals[0]) {
    throw adapterError("invalid_trace_terminal", "events must end with exactly one scenario.end event");
  }
  const terminal = terminals[0];
  if (!(["passed", "failed"].includes(terminal.payload.status))) {
    throw adapterError("invalid_trace_terminal", "scenario.end status must be passed or failed");
  }
  if (
    terminal.payload.value !== undefined
    && terminal.payload.value !== trace.scenarioName
  ) {
    throw adapterError("trace_terminal_mismatch", "scenario.end value contradicts trace scenarioName");
  }
  if (
    terminal.payload.error !== undefined
    && (typeof terminal.payload.error !== "string" || terminal.payload.error.length === 0)
  ) {
    throw adapterError("invalid_trace_terminal", "scenario.end error must be a non-empty string");
  }
  if (
    terminal.payload.failedStepIndex !== undefined
    && (
      !Number.isSafeInteger(terminal.payload.failedStepIndex)
      || terminal.payload.failedStepIndex < 0
    )
  ) {
    throw adapterError(
      "invalid_trace_terminal",
      "scenario.end failedStepIndex must be a non-negative safe integer",
    );
  }
  if (trace.status !== "partial" && trace.status !== terminal.payload.status) {
    throw adapterError("trace_terminal_mismatch", "trace status contradicts scenario.end status");
  }
  if (trace.status === "passed" && (trace.error !== null || terminal.payload.error !== undefined)) {
    throw adapterError("trace_terminal_mismatch", "passed trace must not contain a terminal error");
  }
  if (
    trace.error !== null
    && terminal.payload.error !== undefined
    && trace.error !== terminal.payload.error
  ) {
    throw adapterError("trace_terminal_mismatch", "trace error contradicts scenario.end error");
  }
  if (
    trace.failedStepIndex !== null
    && terminal.payload.failedStepIndex !== undefined
    && trace.failedStepIndex !== terminal.payload.failedStepIndex
  ) {
    throw adapterError(
      "trace_terminal_mismatch",
      "trace failedStepIndex contradicts scenario.end failedStepIndex",
    );
  }
  return { events, terminal };
}

function validateAdapterOptions(options) {
  if (!isObject(options)) {
    throw adapterError("invalid_adapter_options", "ZMR adapter options must be an object");
  }
  assertNonemptyPath(options.tracePath, "tracePath");
  assertNonemptyPath(options.appArtifactPath, "appArtifactPath");
  for (const field of [
    "projectId",
    "submitterId",
    "releaseId",
    "commitSha",
    "appId",
    "appVersion",
    "buildNumber",
    "environment",
    "journeyId",
    "itemId",
    "runId",
    "deviceName",
    "osName",
    "osVersion",
  ]) {
    assertIdentity(options[field], field);
  }
  if (!(["user", "automation"].includes(options.submitterType))) {
    throw adapterError("invalid_adapter_options", "submitterType must be user or automation", "submitterType");
  }
  if (!(["ios", "android"].includes(options.surface))) {
    throw adapterError("invalid_adapter_options", "surface must be ios or android", "surface");
  }
  const hasScenarioPath = Object.hasOwn(options, "scenarioPath");
  const hasScenarioHash = Object.hasOwn(options, "scenarioHash");
  if (hasScenarioPath === hasScenarioHash) {
    throw adapterError(
      "invalid_scenario_identity",
      "Exactly one of scenarioPath or scenarioHash is required",
    );
  }
  if (hasScenarioPath) assertNonemptyPath(options.scenarioPath, "scenarioPath");
  if (hasScenarioHash && !isSha256Digest(options.scenarioHash)) {
    throw adapterError("invalid_scenario_identity", "scenarioHash must be a SHA-256 digest", "scenarioHash");
  }
}

async function hashRegularAppArtifact(inputPath) {
  const absolutePath = resolve(inputPath);
  // Component lstat is a best-effort diagnostic preflight. O_NOFOLLOW and the
  // single file descriptor below bind every hashed byte and both identity checks.
  const preflight = await assertNoSymlinkComponents(absolutePath, "file", "appArtifactPath");
  const noFollow = typeof constants.O_NOFOLLOW === "number" ? constants.O_NOFOLLOW : 0;
  let handle;
  try {
    handle = await open(absolutePath, constants.O_RDONLY | noFollow);
    const before = await handle.stat({ bigint: true });
    if (!before.isFile()) {
      throw adapterError(
        "source_not_regular_file",
        "appArtifactPath must be a regular file",
        "appArtifactPath",
      );
    }
    if (
      BigInt(preflight.dev) !== before.dev
      || BigInt(preflight.ino) !== before.ino
      || BigInt(preflight.size) !== before.size
    ) {
      throw adapterError(
        "source_changed_during_read",
        "appArtifactPath changed before it was hashed",
        "appArtifactPath",
      );
    }

    const hash = createHash("sha256");
    const buffer = Buffer.allocUnsafe(APP_HASH_BUFFER_BYTES);
    let position = 0;
    let bytesHashed = 0n;
    while (true) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
      if (bytesRead === 0) break;
      hash.update(buffer.subarray(0, bytesRead));
      position += bytesRead;
      bytesHashed += BigInt(bytesRead);
      await runZmrAdapterTestHook({ phase: "app-hash-chunk", bytesHashed });
    }

    const after = await handle.stat({ bigint: true });
    if (
      before.dev !== after.dev
      || before.ino !== after.ino
      || before.size !== after.size
      || before.mtimeNs !== after.mtimeNs
      || before.ctimeNs !== after.ctimeNs
      || bytesHashed !== after.size
    ) {
      throw adapterError(
        "source_changed_during_read",
        "appArtifactPath changed while it was hashed",
        "appArtifactPath",
      );
    }
    return `sha256:${hash.digest("hex")}`;
  } catch (error) {
    if (error instanceof EvidenceValidationError) throw error;
    throw adapterError(
      "invalid_source_path",
      "appArtifactPath could not be read",
      "appArtifactPath",
    );
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function scenarioIdentity(options) {
  if (Object.hasOwn(options, "scenarioHash")) {
    return { scenarioHash: options.scenarioHash, artifactInput: null };
  }
  const absolutePath = resolve(options.scenarioPath);
  const body = await readRegularFile(
    absolutePath,
    DEFAULT_TAR_LIMITS.maxEntryBytes,
    "scenarioPath",
  );
  const scenario = parseJson(body, "invalid_scenario_json", "scenarioPath");
  const scenarioHash = sha256Bytes(canonicalBytes(scenario));
  const expectedDigest = sha256Bytes(body);
  return {
    scenarioHash,
    artifactInput: {
      itemIndex: 0,
      sourcePath: absolutePath,
      allowedRoot: dirname(absolutePath),
      expectedDigest,
      expectedSizeBytes: body.length,
      type: "scenario_source",
      contentType: inferContentType(basename(absolutePath)),
      redactionState: "unreviewed",
      disclosureState: "private",
    },
  };
}

function semanticArtifactType(path, tracePaths) {
  if (path === "trace.json") return "trace_manifest";
  if (path === tracePaths.eventsPath) return "event_log";
  if (path === tracePaths.reportPath) return "report";
  const extension = extname(path).toLowerCase();
  if (extension === ".png" || extension === ".jpg" || extension === ".jpeg") return "screenshot";
  if (extension === ".mp4" || extension === ".webm") return "video";
  if (
    (extension === ".json" || extension === ".xml")
    && basename(path).toLowerCase().startsWith("snapshot")
  ) return "ui_snapshot";
  return "zmr_artifact";
}

function traceArtifactInputs(source, tracePaths, redactionState) {
  return source.entries.map((entry) => {
    const metadata = {
      itemIndex: 0,
      type: semanticArtifactType(entry.path, tracePaths),
      contentType: entry.contentType,
      redactionState,
      disclosureState: "private",
    };
    if (source.kind === "archive") return { ...metadata, body: entry.body };
    return {
      ...metadata,
      sourcePath: entry.sourcePath,
      allowedRoot: entry.allowedRoot,
      expectedDigest: entry.digest,
      expectedSizeBytes: entry.sizeBytes,
    };
  });
}

function aggregateRedactionState(artifactInputs) {
  const states = new Set(artifactInputs.map((input) => input.redactionState));
  if (states.size === 0) return "unreviewed";
  if (states.size === 1) return states.values().next().value;
  return "mixed";
}

export async function adaptZmrTrace(options) {
  validateAdapterOptions(options);
  const source = await loadZmrTrace(options.tracePath);
  const trace = source.trace;
  validateTraceManifest(trace);
  const tracePaths = declaredTracePaths(trace);
  const eventsEntry = source.entries.find((entry) => entry.path === tracePaths.eventsPath);
  if (eventsEntry === undefined) {
    throw adapterError("missing_trace_events", "Trace source is missing its declared events file");
  }
  const { terminal } = parseEvents(eventsEntry, trace);
  if (trace.appId !== null && trace.appId !== options.appId) {
    throw adapterError("trace_app_id_mismatch", "trace appId does not match the explicit appId", "appId");
  }

  const artifactDigest = await hashRegularAppArtifact(options.appArtifactPath);
  const scenario = await scenarioIdentity(options);
  const traceRedactionState = trace.redaction?.enabled === true ? "redacted" : "unreviewed";
  const artifactInputs = traceArtifactInputs(source, tracePaths, traceRedactionState);
  if (scenario.artifactInput !== null) artifactInputs.push(scenario.artifactInput);
  const redactionState = aggregateRedactionState(artifactInputs);
  const startedAt = new Date(trace.startedAtMs).toISOString();
  const endedAt = new Date(trace.endedAtMs).toISOString();
  const outcome = trace.status;
  const terminalError = terminal.payload.error ?? trace.error;
  const failureClassification = outcome === "passed"
    ? null
    : typeof terminalError === "string" && terminalError.includes("Timeout")
      ? "timeout"
      : "unknown";
  const traceExtension = {
    schemaVersion: trace.schemaVersion,
    protocolVersion: trace.protocolVersion,
    scenarioName: trace.scenarioName,
    terminalStatus: terminal.payload.status,
    partialFailureCount: trace.partialFailureCount,
    ...(trace.redaction === undefined ? {} : { redaction: trace.redaction }),
  };
  const item = {
    externalId: options.itemId,
    journeyId: options.journeyId,
    scenarioHash: scenario.scenarioHash,
    outcome,
    attempt: 0,
    startedAt,
    endedAt,
    durationMs: trace.durationMs,
    failureClassification,
    execution: {
      kind: "mobile",
      deviceName: options.deviceName,
      osName: options.osName,
      osVersion: options.osVersion,
    },
    artifacts: [],
    ...(terminalError === undefined || terminalError === null
      ? {}
      : { error: { name: terminalError } }),
    extensions: {
      "dev.zmr.trace": traceExtension,
    },
  };
  const targetFingerprint = createMobileFingerprint({
    recipe: "mobile-v1",
    surface: options.surface,
    artifactDigest,
    appId: options.appId,
    version: options.appVersion,
    buildNumber: options.buildNumber,
  });
  const manifest = {
    schemaVersion: "1.0",
    project: { externalId: options.projectId },
    submission: {
      actorType: options.submitterType,
      externalId: options.submitterId,
      claimState: "self_reported",
    },
    producer: {
      name: "zeno-mobile-runner",
      version: trace.runnerVersion,
      adapterVersion: ADAPTER_VERSION,
      provenanceClass: "zeno_runner",
      attestationState: "unattested",
    },
    release: {
      externalId: options.releaseId,
      commitSha: options.commitSha,
    },
    target: {
      surface: options.surface,
      environment: options.environment,
      fingerprintRecipe: "mobile-v1",
      targetFingerprint,
      fingerprintVerification: "recomputed",
      artifactDigest,
      appId: options.appId,
      version: options.appVersion,
      buildNumber: options.buildNumber,
    },
    run: {
      externalId: options.runId,
      startedAt,
      endedAt,
      outcome,
      sourceManifestDigest: source.sourceManifestDigest,
      completenessState: outcome === "partial" ? "partial" : "complete",
      redactionState,
    },
    items: [item],
  };
  assertValidEvidenceManifest(manifest);
  return { manifest, artifactInputs };
}
