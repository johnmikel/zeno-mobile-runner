import { constants as fsConstants, readFileSync } from "node:fs";
import { lstat, mkdir, open, readFile, realpath } from "node:fs/promises";
import path from "node:path";

import {
  EvidenceValidationError,
  assertSafeRelativePath,
  canonicalBytes,
  canonicalize,
  isSha256Digest,
  sha256Bytes,
} from "./canonical-json.mjs";
import { createWebFingerprint } from "./fingerprints.mjs";
import { writeEvidencePackage } from "./package-writer.mjs";

const ADAPTER_VERSION = "1.0.0";
const PACKAGE_VERSION = JSON.parse(
  readFileSync(new URL("../../package.json", import.meta.url), "utf8"),
).version;
const IDENTITY_PATTERN = /^(?!\s)(?!.*\s$)[^\u0000-\u001f\u007f]+$/;
const GIT_SHA_PATTERN = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/;
const UNSUPPORTED_ATTACHMENT_BODY = Symbol("unsupported attachment body");
const REPORTER_OPTION_KEYS = new Set([
  "artifactRoot",
  "browserName",
  "browserVersion",
  "buildManifestDigest",
  "buildManifestPath",
  "commitSha",
  "configDigest",
  // Playwright 1.42 injects configDir when it constructs a configured custom reporter.
  "configDir",
  "deploymentId",
  "environment",
  "journeyAnnotation",
  "journeyMap",
  "outputDir",
  "projectId",
  "releaseId",
  "runId",
  "submitterId",
  "submitterType",
]);
const UNSAFE_PROPERTY_KEYS = new Set(["__proto__", "constructor", "prototype"]);

function reporterError(code, message, field) {
  return new EvidenceValidationError(message, {
    code,
    ...(field === undefined ? {} : { field, path: field }),
  });
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertPlainRecord(value, field) {
  if (!isObject(value)) {
    throw reporterError("invalid_reporter_options", `${field} must be an object`, field);
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw reporterError(
      "invalid_reporter_options",
      `${field} must be a plain or null-prototype object`,
      field,
    );
  }
}

function snapshotOwnDataProperties(value, field, allowedKeys) {
  assertPlainRecord(value, field);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const snapshot = Object.create(null);
  for (const key of Reflect.ownKeys(descriptors)) {
    if (
      typeof key !== "string"
      || (allowedKeys !== null && !allowedKeys.has(key))
      || UNSAFE_PROPERTY_KEYS.has(key)
    ) {
      throw reporterError(
        "invalid_reporter_options",
        `${field} contains an unsupported property`,
        field,
      );
    }
    const descriptor = descriptors[key];
    if (!Object.hasOwn(descriptor, "value")) {
      throw reporterError(
        "invalid_reporter_options",
        `${field}.${key} must be a data property`,
        `${field}.${key}`,
      );
    }
    snapshot[key] = descriptor.value;
  }
  return snapshot;
}

function snapshotReporterOptions(options) {
  const snapshot = snapshotOwnDataProperties(options, "Reporter options", REPORTER_OPTION_KEYS);
  if (Object.hasOwn(snapshot, "journeyMap") && snapshot.journeyMap !== undefined) {
    snapshot.journeyMap = Object.freeze(
      snapshotOwnDataProperties(snapshot.journeyMap, "journeyMap", null),
    );
  }
  return Object.freeze(snapshot);
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
    throw reporterError(
      "invalid_identity",
      `${field} must be 1 to 256 characters with no edge whitespace or controls`,
      field,
    );
  }
  return value;
}

function assertPath(value, field) {
  if (typeof value !== "string" || value.length === 0) {
    throw reporterError("invalid_reporter_options", `${field} must be a non-empty path`, field);
  }
  return value;
}

function validateOptions(options) {
  if (!isObject(options)) {
    throw reporterError("invalid_reporter_options", "Reporter options must be an object");
  }
  assertPath(options.outputDir, "outputDir");
  if (options.configDir !== undefined) assertPath(options.configDir, "configDir");
  for (const field of [
    "projectId",
    "submitterId",
    "releaseId",
    "deploymentId",
    "environment",
  ]) assertIdentity(options[field], field);
  if (!(["user", "automation"].includes(options.submitterType))) {
    throw reporterError(
      "invalid_reporter_options",
      "submitterType must be user or automation",
      "submitterType",
    );
  }
  if (typeof options.commitSha !== "string" || !GIT_SHA_PATTERN.test(options.commitSha)) {
    throw reporterError("invalid_reporter_options", "commitSha must be a full lower-case Git SHA", "commitSha");
  }
  if (!isSha256Digest(options.configDigest)) {
    throw reporterError("invalid_reporter_options", "configDigest must be a SHA-256 digest", "configDigest");
  }
  const hasDigest = Object.hasOwn(options, "buildManifestDigest");
  const hasPath = Object.hasOwn(options, "buildManifestPath");
  if (hasDigest === hasPath) {
    throw reporterError(
      "invalid_reporter_options",
      "Exactly one of buildManifestDigest or buildManifestPath is required",
    );
  }
  if (hasDigest && !isSha256Digest(options.buildManifestDigest)) {
    throw reporterError(
      "invalid_reporter_options",
      "buildManifestDigest must be a SHA-256 digest",
      "buildManifestDigest",
    );
  }
  if (hasPath) assertPath(options.buildManifestPath, "buildManifestPath");
  for (const field of ["runId", "browserName", "browserVersion"]) {
    if (options[field] !== undefined) assertIdentity(options[field], field);
  }
  if (options.journeyAnnotation !== undefined) {
    assertIdentity(options.journeyAnnotation, "journeyAnnotation");
  }
  if (options.journeyMap !== undefined) {
    if (!isObject(options.journeyMap)) {
      throw reporterError("invalid_reporter_options", "journeyMap must be an object", "journeyMap");
    }
    for (const [key, journeyId] of Object.entries(options.journeyMap)) {
      if (key.length === 0) {
        throw reporterError("invalid_reporter_options", "journeyMap keys must be non-empty", "journeyMap");
      }
      assertIdentity(journeyId, `journeyMap.${key}`);
    }
  }
  if (options.artifactRoot !== undefined) assertPath(options.artifactRoot, "artifactRoot");
  return options;
}

function statusOutcome(status) {
  return ({
    passed: "passed",
    failed: "failed",
    timedOut: "timed_out",
    timedout: "timed_out",
    skipped: "skipped",
    interrupted: "interrupted",
  })[status] ?? "unknown";
}

function failureClassification(status) {
  if (status === "timedOut" || status === "timedout") return "timeout";
  if (status === "interrupted") return "interrupted";
  if (status === "passed" || status === "skipped") return null;
  return "unknown";
}

function testProject(testCase) {
  const project = testCase?.parent?.project?.();
  if (!isObject(project)) {
    throw reporterError("invalid_playwright_test", "TestCase must belong to a FullProject");
  }
  return project;
}

function snapshotConfig(config) {
  if (!isObject(config)) {
    throw reporterError("invalid_playwright_config", "FullConfig is required");
  }
  const rootDir = assertPath(config.rootDir, "config.rootDir");
  const version = assertIdentity(config.version, "config.version");
  const shardValue = config.shard;
  let shard = null;
  if (shardValue !== null && shardValue !== undefined) {
    const { current, total } = shardValue;
    if (
      !Number.isSafeInteger(current)
      || !Number.isSafeInteger(total)
      || current < 1
      || total < 1
      || current > total
    ) {
      throw reporterError("invalid_playwright_shard", "FullConfig shard must be a valid current/total tuple");
    }
    shard = Object.freeze({ current, total });
  }
  return Object.freeze({ rootDir, version, shard });
}

function snapshotTestError(error) {
  if (!isObject(error)) return null;
  return Object.freeze({
    message: error.message,
    value: error.value,
  });
}

function snapshotAttachments(attachments) {
  if (!Array.isArray(attachments)) {
    throw reporterError("invalid_playwright_result", "TestResult attachments must be an array");
  }
  return Object.freeze(attachments.map((attachment) => {
    if (!isObject(attachment)) {
      throw reporterError("invalid_attachment", "Attachment must be an object");
    }
    const body = attachment.body;
    return Object.freeze({
      name: attachment.name,
      contentType: attachment.contentType,
      path: attachment.path,
      body: body === undefined
        ? undefined
        : Buffer.isBuffer(body)
          ? Buffer.from(body)
          : UNSUPPORTED_ATTACHMENT_BODY,
    });
  }));
}

function snapshotTestRecord(testCase, result, rootDir) {
  if (!isObject(testCase)) {
    throw reporterError("invalid_playwright_test", "TestCase is required");
  }
  if (!isObject(result)) {
    throw reporterError("invalid_playwright_result", "TestResult is required");
  }
  const rawProject = testProject(testCase);
  const rawLocation = testCase.location;
  if (!isObject(rawLocation)) {
    throw reporterError("invalid_test_location", "Test location is required");
  }
  const location = Object.freeze({
    file: rawLocation.file,
    line: rawLocation.line,
    column: rawLocation.column,
  });
  const relativeFile = safeRelativeTestFile(rootDir, location.file);
  const rawTitlePath = testCase.titlePath();
  if (!Array.isArray(rawTitlePath)) {
    throw reporterError("invalid_playwright_test", "TestCase titlePath must be an array");
  }
  const titlePath = Object.freeze([...rawTitlePath]);
  const id = assertIdentity(testCase.id, "test.id");
  const rawAnnotations = Array.isArray(testCase.annotations) ? testCase.annotations : [];
  const annotations = Object.freeze(rawAnnotations.map((annotation) => Object.freeze({
    type: annotation?.type,
    description: annotation?.description,
  })));
  const evidenceMetadata = rawProject.metadata?.zenoEvidence;
  const project = Object.freeze({
    name: rawProject.name,
    browserName: evidenceMetadata?.browserName,
    browserVersion: evidenceMetadata?.browserVersion,
  });
  const capturedResult = Object.freeze({
    retry: result.retry,
    status: result.status,
    startTimeMs: result.startTime instanceof Date
      ? result.startTime.valueOf()
      : new Date(result.startTime).valueOf(),
    duration: result.duration,
    error: snapshotTestError(result.error),
    attachments: snapshotAttachments(result.attachments),
  });
  const externalId = `playwright:${sha256Bytes(Buffer.from(id, "utf8")).slice("sha256:".length)}`;
  return Object.freeze({
    id,
    location,
    relativeFile,
    titlePath,
    annotations,
    expectedStatus: testCase.expectedStatus,
    aggregateOutcome: testCase.outcome(),
    project,
    result: capturedResult,
    externalId,
  });
}

function snapshotFullResult(fullResult) {
  if (!isObject(fullResult)) {
    throw reporterError("invalid_full_result", "FullResult is required");
  }
  return Object.freeze({
    status: fullResult.status,
    startTimeMs: fullResult.startTime instanceof Date
      ? fullResult.startTime.valueOf()
      : new Date(fullResult.startTime).valueOf(),
    duration: fullResult.duration,
  });
}

function isWindowsAbsolute(value) {
  return typeof value === "string"
    && /^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))/.test(value);
}

function rootPathImplementation(rootDir) {
  return isWindowsAbsolute(rootDir) ? path.win32 : path;
}

function resolveFromRoot(rootDir, value) {
  return rootPathImplementation(rootDir).resolve(rootDir, value);
}

function safeRelativeTestFile(rootDir, file) {
  if (typeof file !== "string" || file.length === 0) {
    throw reporterError("invalid_test_location", "Test location file must be non-empty");
  }
  const rootIsWindows = isWindowsAbsolute(rootDir);
  const fileIsWindows = isWindowsAbsolute(file);
  if (rootIsWindows !== fileIsWindows) {
    throw reporterError("test_file_outside_root", "Test file and config.rootDir must use matching path semantics");
  }
  const pathApi = rootIsWindows ? path.win32 : path;
  const root = pathApi.resolve(rootDir);
  const absoluteFile = pathApi.resolve(file);
  const relativeFile = pathApi.relative(root, absoluteFile);
  const firstSegment = relativeFile.split(pathApi.sep)[0];
  if (
    relativeFile.length === 0
    || pathApi.isAbsolute(relativeFile)
    || firstSegment === ".."
  ) {
    throw reporterError("test_file_outside_root", "Test file must remain inside config.rootDir");
  }
  return assertSafeRelativePath(relativeFile.split(pathApi.sep).join("/"), "relativeFile");
}

function semanticArtifactType(contentType) {
  if (contentType.startsWith("image/")) return "screenshot";
  if (contentType.startsWith("video/")) return "video";
  if (contentType === "application/zip") return "trace";
  return "test_attachment";
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function capCodeUnits(value, limit) {
  let capped = value.slice(0, limit);
  const last = capped.charCodeAt(capped.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) capped = capped.slice(0, -1);
  return capped;
}

function sanitizeErrorMessage(error, knownPaths) {
  if (!isObject(error)) return null;
  const raw = error.message ?? error.value;
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "string") {
    throw reporterError("invalid_test_error", "TestError message or value must be a string");
  }
  let sanitized = raw.replace(/[\u0000-\u001f\u007f]/g, " ");
  const paths = [...new Set(knownPaths.filter((value) => typeof value === "string" && value.length > 0))]
    .sort((left, right) => right.length - left.length);
  for (const knownPath of paths) {
    sanitized = sanitized.replace(new RegExp(escapeRegExp(knownPath), "gi"), "<redacted-path>");
  }
  sanitized = sanitized
    .replace(/\b[A-Za-z]:\\(?:[^\\\s|]+\\)*[^\\\s|]+/g, "<redacted-path>")
    .replace(/\bBearer\s+[^\s|,;]+/gi, "<redacted-secret>")
    .replace(
      /\b(?:authorization|token|api_key|apikey|password|secret)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s|,;]+)/gi,
      "<redacted-secret>",
    );
  sanitized = capCodeUnits(sanitized, 4096);
  if (sanitized.length === 0) {
    throw reporterError("invalid_test_error", "Sanitized TestError message must not be empty");
  }
  return sanitized;
}

function artifactInputsFor(result, itemIndex, artifactRoot) {
  const inputs = [];
  for (const attachment of result.attachments) {
    const hasPath = attachment.path !== undefined;
    const hasBody = attachment.body !== undefined;
    if (!hasPath && !hasBody) continue;
    if (hasPath && hasBody) {
      throw reporterError("invalid_attachment", "Attachment must not provide both path and body");
    }
    const metadata = {
      itemIndex,
      type: semanticArtifactType(attachment.contentType),
      contentType: attachment.contentType,
      redactionState: "unreviewed",
      disclosureState: "private",
    };
    if (hasPath) {
      inputs.push({
        ...metadata,
        sourcePath: attachment.path,
        allowedRoot: artifactRoot,
      });
      continue;
    }
    if (Buffer.isBuffer(attachment.body)) {
      inputs.push({ ...metadata, body: Buffer.from(attachment.body) });
      continue;
    }
    throw reporterError("invalid_attachment", "Attachment must provide a path or Buffer body");
  }
  return inputs;
}

function sameNativePath(left, right) {
  const normalizedLeft = path.resolve(left);
  const normalizedRight = path.resolve(right);
  return process.platform === "win32"
    ? normalizedLeft.toLowerCase() === normalizedRight.toLowerCase()
    : normalizedLeft === normalizedRight;
}

async function assertUnlinkedDirectoryPath(outputDir, createMissing) {
  const absoluteOutputDir = path.resolve(outputDir);
  const { root } = path.parse(absoluteOutputDir);
  let current = root;
  const rootStats = await lstat(root);
  if (rootStats.isSymbolicLink() || !rootStats.isDirectory()) {
    throw reporterError("unsafe_failure_output", "Failure output root must be a real directory");
  }
  for (const segment of absoluteOutputDir.slice(root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    let stats;
    try {
      stats = await lstat(current);
    } catch (error) {
      if (error?.code !== "ENOENT" || !createMissing) throw error;
      try {
        await mkdir(current, { mode: 0o700 });
      } catch (mkdirError) {
        if (mkdirError?.code !== "EEXIST") throw mkdirError;
      }
      stats = await lstat(current);
    }
    if (stats.isSymbolicLink() || !stats.isDirectory()) {
      throw reporterError(
        "unsafe_failure_output",
        "Failure output path must not contain links or non-directories",
      );
    }
  }
  const resolvedOutputDir = await realpath(absoluteOutputDir);
  if (!sameNativePath(resolvedOutputDir, absoluteOutputDir)) {
    throw reporterError("unsafe_failure_output", "Failure output path must not contain links");
  }
  return absoluteOutputDir;
}

async function writeFailureFile(outputDir) {
  if (typeof outputDir !== "string" || outputDir.length === 0) return;
  let handle;
  try {
    const absoluteOutputDir = await assertUnlinkedDirectoryPath(outputDir, true);
    await assertUnlinkedDirectoryPath(absoluteOutputDir, false);
    const markerPath = path.join(absoluteOutputDir, "evidence-error.json");
    const flags = fsConstants.O_WRONLY
      | fsConstants.O_CREAT
      | fsConstants.O_EXCL
      | (fsConstants.O_NOFOLLOW ?? 0);
    handle = await open(markerPath, flags, 0o600);

    const handleStats = await handle.stat();
    await assertUnlinkedDirectoryPath(absoluteOutputDir, false);
    const markerStats = await lstat(markerPath);
    if (
      !handleStats.isFile()
      || markerStats.isSymbolicLink()
      || !markerStats.isFile()
      || handleStats.dev !== markerStats.dev
      || handleStats.ino !== markerStats.ino
    ) {
      throw reporterError("unsafe_failure_output", "Failure marker must be a new regular file");
    }
    const [resolvedOutputDir, resolvedMarkerPath] = await Promise.all([
      realpath(absoluteOutputDir),
      realpath(markerPath),
    ]);
    if (
      !sameNativePath(resolvedOutputDir, absoluteOutputDir)
      || !sameNativePath(
        resolvedMarkerPath,
        path.join(resolvedOutputDir, "evidence-error.json"),
      )
    ) {
      throw reporterError("unsafe_failure_output", "Failure marker escaped its output directory");
    }
    await handle.writeFile(`${JSON.stringify({ error: "Evidence generation failed" }, null, 2)}\n`);
    await handle.sync();
  } catch {
    // Best effort only: the failed status remains the authoritative signal.
  } finally {
    if (handle !== undefined) {
      try {
        await handle.close();
      } catch {
        // Best effort only.
      }
    }
  }
}

export function playwrightJourneyKey({ projectName, relativeFile, titlePath }) {
  return canonicalize({ projectName, relativeFile, titlePath });
}

export default class ZenoPlaywrightReporter {
  constructor(options) {
    this.options = Object.freeze(Object.create(null));
    this.fatalError = null;
    this.config = null;
    this.outputDir = null;
    this.artifactRoot = null;
    this.buildManifestPath = null;
    this.shard = null;
    this.records = [];
    try {
      this.options = snapshotReporterOptions(options);
      validateOptions(this.options);
    } catch (error) {
      this.fatalError = error;
    }
  }

  printsToStdio() {
    return false;
  }

  onBegin(config, _suite) {
    try {
      this.config = snapshotConfig(config);
      if (typeof this.options?.outputDir === "string" && this.options.outputDir.length > 0) {
        this.outputDir = resolveFromRoot(this.config.rootDir, this.options.outputDir);
      }
      this.artifactRoot = resolveFromRoot(
        this.config.rootDir,
        this.options?.artifactRoot ?? this.config.rootDir,
      );
      if (this.options?.buildManifestPath !== undefined) {
        this.buildManifestPath = resolveFromRoot(this.config.rootDir, this.options.buildManifestPath);
      }
      if (this.config.shard !== null) {
        this.shard = this.config.shard;
        if (this.outputDir !== null) {
          this.outputDir = rootPathImplementation(this.config.rootDir).join(
            this.outputDir,
            `shard-${this.shard.current}-of-${this.shard.total}`,
          );
        }
      }
    } catch (error) {
      this.fatalError ??= error;
    }
  }

  onTestEnd(testCase, result) {
    try {
      if (!this.config) throw reporterError("reporter_not_started", "onBegin must run before onTestEnd");
      this.records.push(snapshotTestRecord(testCase, result, this.config.rootDir));
    } catch (error) {
      this.fatalError ??= error;
    }
  }

  async onEnd(fullResult) {
    try {
      const capturedFullResult = snapshotFullResult(fullResult);
      if (this.fatalError) throw this.fatalError;
      if (!this.config) throw reporterError("reporter_not_started", "onBegin must run before onEnd");
      if (this.records.length === 0) {
        throw reporterError("empty_evidence_run", "A Playwright run must contain at least one result");
      }

      const buildManifestDigest = this.buildManifestPath === null
        ? this.options.buildManifestDigest
        : sha256Bytes(await readFile(this.buildManifestPath));
      const items = [];
      const artifactInputs = [];
      const sourceRecords = [];
      for (const record of this.records) {
        const revalidatedRelativeFile = safeRelativeTestFile(
          this.config.rootDir,
          record.location.file,
        );
        if (revalidatedRelativeFile !== record.relativeFile) {
          throw reporterError("test_file_outside_root", "Captured test location changed before read");
        }
        const fileBytes = await readFile(record.location.file);
        const fileDigest = sha256Bytes(fileBytes);
        const scenarioHash = sha256Bytes(canonicalBytes({
          fileDigest,
          titlePath: record.titlePath,
        }));
        const browserName = assertIdentity(
          this.options.browserName ?? record.project.browserName,
          "browserName",
        );
        const browserVersion = assertIdentity(
          this.options.browserVersion ?? record.project.browserVersion,
          "browserVersion",
        );
        const annotation = record.annotations
          .filter((entry) => entry?.type === (this.options.journeyAnnotation ?? "zeno:journey"))
          .at(-1);
        const journeyKey = playwrightJourneyKey({
          projectName: record.project.name,
          relativeFile: record.relativeFile,
          titlePath: record.titlePath,
        });
        const mappedJourneyId = this.options.journeyMap?.[journeyKey];
        const journeyId = mappedJourneyId !== undefined
          ? assertIdentity(mappedJourneyId, "journeyId")
          : annotation === undefined
            ? null
            : assertIdentity(annotation.description, "journeyId");
        const started = new Date(record.result.startTimeMs);
        const durationMs = record.result.duration;
        const ended = new Date(started.valueOf() + durationMs);
        const itemIndex = items.length;
        const inputs = artifactInputsFor(record.result, itemIndex, this.artifactRoot);
        artifactInputs.push(...inputs);
        const errorMessage = sanitizeErrorMessage(record.result.error, [
          this.config.rootDir,
          record.location.file,
          ...record.result.attachments.map((attachment) => attachment.path),
        ]);
        items.push({
          externalId: record.externalId,
          journeyId,
          scenarioHash,
          outcome: statusOutcome(record.result.status),
          attempt: record.result.retry,
          startedAt: started.toISOString(),
          endedAt: ended.toISOString(),
          durationMs,
          failureClassification: failureClassification(record.result.status),
          execution: { kind: "browser", browserName, browserVersion },
          artifacts: [],
          ...(errorMessage === null ? {} : { error: { message: errorMessage } }),
          extensions: {
            "dev.playwright.test": {
              sourceTestIdDigest: sha256Bytes(Buffer.from(record.id, "utf8")),
              titlePath: record.titlePath,
              location: {
                relativeFile: record.relativeFile,
                line: record.location.line,
                column: record.location.column,
              },
              projectName: assertIdentity(record.project.name, "projectName"),
              expectedStatus: record.expectedStatus,
              aggregateOutcome: record.aggregateOutcome,
              mappingState: journeyId === null ? "unmapped" : "mapped",
            },
          },
        });
        sourceRecords.push({
          externalId: record.externalId,
          attempt: record.result.retry,
          status: record.result.status,
          expectedStatus: record.expectedStatus,
          startTime: started.toISOString(),
          durationMs,
          scenarioHash,
          attachments: record.result.attachments.map(({ name, contentType }) => ({ name, contentType })),
        });
      }

      const startedAt = new Date(capturedFullResult.startTimeMs);
      const endedAt = new Date(startedAt.valueOf() + capturedFullResult.duration);
      const targetFingerprint = createWebFingerprint({
        recipe: "web-v1",
        surface: "web",
        environment: this.options.environment,
        deploymentId: this.options.deploymentId,
        commitSha: this.options.commitSha,
        buildManifestDigest,
        configDigest: this.options.configDigest,
      });
      sourceRecords.sort((left, right) => {
        const leftKey = `${left.externalId}\u0000${left.attempt}`;
        const rightKey = `${right.externalId}\u0000${right.attempt}`;
        return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
      });
      const derivedRunDigest = sha256Bytes(canonicalBytes({
        targetFingerprint,
        attempts: sourceRecords.map(({ externalId, attempt, startTime, durationMs }) => ({
          externalId,
          attempt,
          startTime,
          durationMs,
        })),
      }));
      const runOutcome = statusOutcome(capturedFullResult.status);
      const manifest = {
        schemaVersion: "1.0",
        project: { externalId: this.options.projectId },
        submission: {
          actorType: this.options.submitterType,
          externalId: this.options.submitterId,
          claimState: "self_reported",
        },
        producer: {
          name: "playwright",
          version: this.config.version,
          adapterVersion: ADAPTER_VERSION,
          provenanceClass: "official_adapter",
          attestationState: "unattested",
        },
        release: {
          externalId: this.options.releaseId,
          commitSha: this.options.commitSha,
        },
        target: {
          surface: "web",
          environment: this.options.environment,
          fingerprintRecipe: "web-v1",
          targetFingerprint,
          fingerprintVerification: "recomputed",
          deploymentId: this.options.deploymentId,
          commitSha: this.options.commitSha,
          buildManifestDigest,
          configDigest: this.options.configDigest,
        },
        run: {
          externalId: this.options.runId ?? `playwright-run:${derivedRunDigest.slice("sha256:".length)}`,
          startedAt: startedAt.toISOString(),
          endedAt: endedAt.toISOString(),
          outcome: runOutcome,
          sourceManifestDigest: sha256Bytes(canonicalBytes(sourceRecords)),
          completenessState: ["timed_out", "interrupted"].includes(runOutcome) ? "partial" : "complete",
          redactionState: "unreviewed",
        },
        items,
        extensions: {
          "dev.zmr.adapter": { packageVersion: PACKAGE_VERSION },
          ...(this.shard === null ? {} : {
            "dev.playwright.run": { shard: this.shard },
          }),
        },
      };

      await writeEvidencePackage({
        destination: this.outputDir,
        manifest,
        artifactInputs,
      });
      return undefined;
    } catch (error) {
      this.fatalError ??= error;
      await writeFailureFile(this.outputDir);
      try {
        process.stderr.write("zeno-mobile-runner: evidence generation failed\n");
      } catch {
        // The status override must survive a closed diagnostic stream.
      }
      return { status: "failed" };
    }
  }
}
