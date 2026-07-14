import assert from "node:assert/strict";
import {
  cp,
  mkdir,
  mkdtemp,
  open as openFile,
  readFile,
  realpath,
  readdir,
  lstat,
  rm,
  symlink,
  unlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  EvidenceValidationError,
  canonicalBytes,
  sha256Bytes,
} from "../npm/evidence/canonical-json.mjs";
import { validateEvidenceManifest } from "../npm/evidence/contract.mjs";
import { createMobileFingerprint } from "../npm/evidence/fingerprints.mjs";
import { writeEvidencePackage } from "../npm/evidence/package-writer.mjs";
import { DEFAULT_TAR_LIMITS, parseZmrTar } from "../npm/evidence/tar.mjs";
import { adaptZmrTrace, loadZmrTrace } from "../npm/evidence/zmr-adapter.mjs";

const BLOCK_SIZE = 512;
const MIB = 1024 * 1024;
const ZMR_ADAPTER_TEST_HOOK = Symbol.for("dev.zmr.evidence.zmr-adapter.test-hook");
const encoder = new TextEncoder();

function fieldBytes(value) {
  if (value instanceof Uint8Array) return value;
  return encoder.encode(value);
}

function writeField(target, offset, length, value) {
  const bytes = fieldBytes(value);
  assert.ok(bytes.length <= length, `field exceeds ${length} bytes`);
  target.set(bytes, offset);
}

function writeOctal(target, offset, length, value) {
  const encoded = value.toString(8).padStart(length - 1, "0");
  assert.equal(encoded.length, length - 1, "octal field overflow");
  writeField(target, offset, length - 1, encoded);
  target[offset + length - 1] = 0;
}

function headerChecksum(header) {
  let total = 0;
  for (let index = 0; index < header.length; index += 1) {
    total += index >= 148 && index < 156 ? 0x20 : header[index];
  }
  return total;
}

function makeHeader({
  name,
  prefix = "",
  size = 0,
  type = "0",
  magic = "ustar\0",
  sizeBytes,
} = {}) {
  const header = Buffer.alloc(BLOCK_SIZE);
  writeField(header, 0, 100, name);
  writeOctal(header, 100, 8, 0o644);
  writeOctal(header, 108, 8, 0);
  writeOctal(header, 116, 8, 0);
  if (sizeBytes !== undefined) {
    writeField(header, 124, 12, sizeBytes);
  } else {
    writeOctal(header, 124, 12, BigInt(size));
  }
  writeOctal(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  if (type !== "\0") writeField(header, 156, 1, type);
  writeField(header, 257, 6, magic);
  writeField(header, 263, 2, "00");
  writeField(header, 345, 155, prefix);
  writeOctal(header, 148, 8, BigInt(headerChecksum(header)));
  return header;
}

function concat(chunks) {
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)));
}

function makeTar(entries, { endBlocks = 2, trailing = Buffer.alloc(0) } = {}) {
  const chunks = [];
  for (const entry of entries) {
    const body = Buffer.from(entry.body ?? "");
    const size = entry.size ?? body.length;
    chunks.push(makeHeader({ ...entry, size }));
    chunks.push(body);
    chunks.push(Buffer.alloc((BLOCK_SIZE - (body.length % BLOCK_SIZE)) % BLOCK_SIZE));
  }
  chunks.push(Buffer.alloc(endBlocks * BLOCK_SIZE));
  chunks.push(trailing);
  return concat(chunks);
}

function assertEvidenceError(fn, code) {
  assert.throws(fn, (error) => {
    assert.ok(error instanceof EvidenceValidationError);
    if (code !== undefined) assert.equal(error.code, code);
    return true;
  });
}

test("parseZmrTar reads current ustar regular files in deterministic path order", () => {
  const archive = makeTar([
    { name: "trace.json", body: "{}\n" },
    { name: "final.txt", prefix: "artifacts", body: "done\n", type: "\0" },
    { name: "events.jsonl", body: "{\"kind\":\"scenario.end\"}\n" },
  ]);

  const entries = parseZmrTar(archive);

  assert.deepEqual(entries.map((entry) => entry.path), [
    "artifacts/final.txt",
    "events.jsonl",
    "trace.json",
  ]);
  assert.deepEqual(entries.map((entry) => entry.sizeBytes), [5, 24, 3]);
  assert.equal(entries[0].body.toString("utf8"), "done\n");
  assert.equal(entries[0].contentType, "text/plain; charset=utf-8");
  assert.equal(entries[1].contentType, "application/x-ndjson");
  assert.equal(entries[2].contentType, "application/json");
});

test("parseZmrTar rejects checksum corruption", () => {
  const archive = makeTar([{ name: "trace.json", body: "{}" }]);
  archive[1] ^= 1;
  assertEvidenceError(() => parseZmrTar(archive), "invalid_tar_checksum");
});

test("parseZmrTar rejects a truncated entry body before slicing", () => {
  const header = makeHeader({ name: "large.bin", size: 600 });
  const archive = concat([header, Buffer.alloc(511)]);
  assertEvidenceError(() => parseZmrTar(archive), "truncated_tar");
});

test("parseZmrTar rejects duplicate accepted paths", () => {
  const archive = makeTar([
    { name: "events.jsonl", body: "one" },
    { name: "events.jsonl", body: "two" },
  ]);
  assertEvidenceError(() => parseZmrTar(archive), "duplicate_tar_path");
});

for (const unsafePath of [
  "/absolute",
  "../escape",
  "nested/../../escape",
  "C:/windows",
  "safe\\windows",
  "nul\0inside",
  "control\u0001inside",
  "safe/../file",
  "./file",
  "a//b",
]) {
  test(`parseZmrTar rejects unsafe raw path ${JSON.stringify(unsafePath)}`, () => {
    const archive = makeTar([{ name: unsafePath }]);
    assertEvidenceError(() => parseZmrTar(archive), "unsafe_tar_path");
  });
}

for (const prefix of ["../prefix", "safe/..", "./prefix", "a//b"]) {
  test(`parseZmrTar rejects malicious ustar prefix ${JSON.stringify(prefix)}`, () => {
    const archive = makeTar([{ name: "file", prefix }]);
    assertEvidenceError(() => parseZmrTar(archive), "unsafe_tar_path");
  });
}

for (const [label, type] of [
  ["hard link", "1"],
  ["symlink", "2"],
  ["character device", "3"],
  ["block device", "4"],
  ["FIFO", "6"],
  ["PAX metadata", "x"],
  ["global PAX metadata", "g"],
]) {
  test(`parseZmrTar rejects ${label} entries before reading bodies`, () => {
    const archive = makeTar([{ name: "unsafe", type, size: 128 * MIB + 1 }]);
    assertEvidenceError(() => parseZmrTar(archive), "unsupported_tar_entry_type");
  });
}

test("parseZmrTar enforces the default entry-count limit", () => {
  const entries = Array.from({ length: DEFAULT_TAR_LIMITS.maxEntries + 1 }, (_, index) => ({
    name: `files/${index}`,
  }));
  assertEvidenceError(() => parseZmrTar(makeTar(entries)), "tar_entry_limit_exceeded");
});

test("parseZmrTar rejects a declared entry over 128 MiB before allocation or bounds checks", () => {
  const archive = concat([
    makeHeader({ name: "huge.bin", size: 128 * MIB + 1 }),
    Buffer.alloc(BLOCK_SIZE * 2),
  ]);
  assertEvidenceError(() => parseZmrTar(archive), "tar_entry_size_exceeded");
});

test("parseZmrTar uses BigInt octal parsing and rejects malformed or base-256 sizes", () => {
  const malformed = makeTar([{ name: "bad.bin", sizeBytes: encoder.encode("0000000008\0") }]);
  assertEvidenceError(() => parseZmrTar(malformed), "invalid_tar_size");

  const base256 = Buffer.alloc(12);
  base256[0] = 0x80;
  const encoded = makeTar([{ name: "base256.bin", sizeBytes: base256 }]);
  assertEvidenceError(() => parseZmrTar(encoded), "invalid_tar_size");
});

test("parseZmrTar enforces cumulative accepted content before copying", () => {
  assert.equal(DEFAULT_TAR_LIMITS.maxTotalBytes, 512 * MIB);
  const archive = makeTar([
    { name: "a.bin", body: "aa" },
    { name: "b.bin", body: "bb" },
  ]);
  assertEvidenceError(
    () => parseZmrTar(archive, { ...DEFAULT_TAR_LIMITS, maxTotalBytes: 3 }),
    "tar_total_size_exceeded",
  );
});

test("parseZmrTar requires two zero end-marker blocks", () => {
  assertEvidenceError(
    () => parseZmrTar(makeTar([{ name: "trace.json", body: "{}" }], { endBlocks: 1 })),
    "missing_tar_end_marker",
  );
});

test("parseZmrTar rejects trailing non-zero bytes after the end marker", () => {
  const archive = makeTar(
    [{ name: "trace.json", body: "{}" }],
    { trailing: Buffer.from([0, 0, 1, 0]) },
  );
  assertEvidenceError(() => parseZmrTar(archive), "trailing_tar_data");
});

test("parseZmrTar rejects non-ustar headers", () => {
  const archive = makeTar([{ name: "trace.json", body: "{}", magic: "legacy" }]);
  assertEvidenceError(() => parseZmrTar(archive), "invalid_tar_format");
});

test("public ZMR archive-security cases execute against the hardened parser", async () => {
  const catalog = JSON.parse(await readFile(new URL("../fixtures/evidence/v1/cases.json", import.meta.url)));
  const cases = catalog.filter(
    (entry) => entry.phase === "zmr-adapter-v1" && entry.kind === "archive-security",
  );
  assert.deepEqual(cases.map((entry) => entry.id), [
    "zmr-tar-parent-traversal",
    "zmr-tar-symlink-entry",
    "zmr-tar-oversized-entry",
  ]);

  for (const entry of cases) {
    const archive = concat([
      makeHeader({
        name: entry.input.path,
        type: entry.input.type,
        size: entry.input.size,
      }),
      Buffer.alloc(BLOCK_SIZE * 2),
    ]);
    assertEvidenceError(() => parseZmrTar(archive));
  }
});

const zmrFixtureRoot = fileURLToPath(
  new URL("../fixtures/evidence/v1/sources/zmrtrace", import.meta.url),
);
const SCENARIO_HASH = `sha256:${"c".repeat(64)}`;
const COMMIT_SHA = "1".repeat(40);

function fixturePath(name) {
  return join(zmrFixtureRoot, name);
}

async function temporaryDirectory(t) {
  const directory = await mkdtemp(join(tmpdir(), "zmr-evidence-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return realpath(directory);
}

async function walkFiles(root, current = root) {
  const paths = [];
  for (const entry of await readdir(current, { withFileTypes: true })) {
    const absolute = join(current, entry.name);
    if (entry.isDirectory()) {
      paths.push(...await walkFiles(root, absolute));
    } else if (entry.isFile()) {
      paths.push(relative(root, absolute).split("\\").join("/"));
    }
  }
  return paths.sort();
}

async function traceArchiveFromDirectory(traceDirectory) {
  const trace = JSON.parse(await readFile(join(traceDirectory, "trace.json"), "utf8"));
  const accepted = ["trace.json", trace.eventsPath];
  if (trace.reportPath !== null) accepted.push(trace.reportPath);
  const artifactsPath = join(traceDirectory, trace.artifactsDir);
  try {
    for (const path of await walkFiles(traceDirectory, artifactsPath)) accepted.push(path);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  const entries = [];
  for (const path of [...new Set(accepted)].sort()) {
    entries.push({ name: path, body: await readFile(join(traceDirectory, path)) });
  }
  return makeTar(entries);
}

async function makeAppArtifact(directory, bytes = Buffer.from("fixture app binary\n")) {
  const appArtifactPath = join(directory, "fixture.appbin");
  await writeFile(appArtifactPath, bytes);
  return appArtifactPath;
}

function baseAdapterOptions({ tracePath, appArtifactPath, scenarioPath, scenarioHash } = {}) {
  return {
    tracePath,
    projectId: "project-42",
    submitterType: "automation",
    submitterId: "ci-release",
    releaseId: "release-42",
    commitSha: COMMIT_SHA,
    surface: "android",
    appArtifactPath,
    appId: "dev.zmr.fixture",
    appVersion: "1.2.3",
    buildNumber: "42",
    environment: "staging",
    journeyId: "journey-login",
    itemId: "source-item-007",
    runId: "run-007",
    deviceName: "Pixel 9",
    osName: "Android",
    osVersion: "16",
    ...(scenarioPath === undefined ? {} : { scenarioPath }),
    ...(scenarioHash === undefined ? {} : { scenarioHash }),
  };
}

function inputForType(artifactInputs, type) {
  return artifactInputs.find((input) => input.type === type);
}

async function editableFixture(t, name = "passed") {
  const temporary = await temporaryDirectory(t);
  const tracePath = join(temporary, `trace-${name}`);
  await cp(fixturePath(name), tracePath, { recursive: true });
  return {
    temporary,
    tracePath,
    appArtifactPath: await makeAppArtifact(temporary),
  };
}

async function updateTrace(tracePath, transform) {
  const path = join(tracePath, "trace.json");
  const trace = JSON.parse(await readFile(path, "utf8"));
  transform(trace);
  await writeFile(path, `${JSON.stringify(trace)}\n`);
}

async function assertAdapterRejects(options, code) {
  await assert.rejects(adaptZmrTrace(options), (error) => {
    assert.ok(error instanceof EvidenceValidationError);
    if (code !== undefined) assert.equal(error.code, code);
    return true;
  });
}

test("directory and archive adaptation are source-digest equivalent and package exact artifacts", async (t) => {
  const temporary = await temporaryDirectory(t);
  const passedDirectory = fixturePath("passed");
  const archivePath = join(temporary, "passed.zmrtrace");
  await writeFile(archivePath, await traceArchiveFromDirectory(passedDirectory));
  const appBytes = Buffer.from("streamed app artifact bytes\n");
  const appArtifactPath = await makeAppArtifact(temporary, appBytes);
  const scenarioPath = join(passedDirectory, "scenario.json");

  const directorySource = await loadZmrTrace(passedDirectory);
  const archiveSource = await loadZmrTrace(archivePath);
  assert.equal(directorySource.sourceManifestDigest, archiveSource.sourceManifestDigest);
  assert.deepEqual(
    directorySource.entries.map(({ path, body }) => [path, sha256Bytes(body)]),
    archiveSource.entries.map(({ path, body }) => [path, sha256Bytes(body)]),
  );

  const directoryResult = await adaptZmrTrace(baseAdapterOptions({
    tracePath: passedDirectory,
    appArtifactPath,
    scenarioPath,
  }));
  const archiveResult = await adaptZmrTrace(baseAdapterOptions({
    tracePath: archivePath,
    appArtifactPath,
    scenarioPath,
  }));

  assert.equal(
    directoryResult.manifest.run.sourceManifestDigest,
    archiveResult.manifest.run.sourceManifestDigest,
  );
  assert.deepEqual(validateEvidenceManifest(directoryResult.manifest), { ok: true, issues: [] });
  assert.deepEqual(validateEvidenceManifest(archiveResult.manifest), { ok: true, issues: [] });
  assert.deepEqual(directoryResult.manifest, archiveResult.manifest);

  const traceFileInputs = directoryResult.artifactInputs.filter(
    (input) => Object.hasOwn(input, "sourcePath") && input.type !== "scenario_source",
  );
  assert.ok(traceFileInputs.length >= 3);
  for (const input of traceFileInputs) {
    const sourceBytes = await readFile(input.sourcePath);
    assert.equal(input.allowedRoot, passedDirectory);
    assert.equal(input.expectedDigest, sha256Bytes(sourceBytes));
    assert.equal(input.expectedSizeBytes, sourceBytes.length);
  }
  assert.ok(archiveResult.artifactInputs.every(
    (input) => input.type === "scenario_source" || Object.hasOwn(input, "body"),
  ));
  const scenarioInput = inputForType(directoryResult.artifactInputs, "scenario_source");
  const scenarioBytes = await readFile(scenarioPath);
  assert.equal(scenarioInput.allowedRoot, dirname(scenarioPath));
  assert.equal(scenarioInput.expectedDigest, sha256Bytes(scenarioBytes));
  assert.equal(scenarioInput.expectedSizeBytes, scenarioBytes.length);
  assert.equal(directoryResult.artifactInputs.some((input) => input.sourcePath === appArtifactPath), false);

  const target = directoryResult.manifest.target;
  const artifactDigest = sha256Bytes(appBytes);
  assert.equal(target.artifactDigest, artifactDigest);
  assert.equal(target.targetFingerprint, createMobileFingerprint({
    recipe: "mobile-v1",
    surface: "android",
    artifactDigest,
    appId: "dev.zmr.fixture",
    version: "1.2.3",
    buildNumber: "42",
  }));
  assert.equal(JSON.stringify(directoryResult.manifest).includes(appArtifactPath), false);
  assert.equal(JSON.stringify(directoryResult.manifest).includes(scenarioPath), false);

  const scenario = JSON.parse(await readFile(scenarioPath, "utf8"));
  const item = directoryResult.manifest.items[0];
  assert.equal(item.scenarioHash, sha256Bytes(canonicalBytes(scenario)));
  assert.equal(item.externalId, "source-item-007");
  assert.equal(item.attempt, 0);
  assert.equal(item.journeyId, "journey-login");
  assert.deepEqual(item.execution, {
    kind: "mobile",
    deviceName: "Pixel 9",
    osName: "Android",
    osVersion: "16",
  });
  assert.equal(item.durationMs, 2000);
  assert.equal(item.startedAt, new Date(1783936800000).toISOString());
  assert.equal(item.endedAt, new Date(1783936802000).toISOString());
  assert.equal(directoryResult.manifest.run.externalId, "run-007");
  assert.deepEqual(directoryResult.manifest.project, { externalId: "project-42" });
  assert.deepEqual(directoryResult.manifest.submission, {
    actorType: "automation",
    externalId: "ci-release",
    claimState: "self_reported",
  });
  assert.deepEqual(directoryResult.manifest.producer, {
    name: "zeno-mobile-runner",
    version: "0.2.17",
    adapterVersion: "1.0.0",
    provenanceClass: "zeno_runner",
    attestationState: "unattested",
  });

  const directoryPackage = join(temporary, "directory-evidence");
  const archivePackage = join(temporary, "archive-evidence");
  const packagedDirectory = await writeEvidencePackage({
    destination: directoryPackage,
    ...directoryResult,
  });
  const packagedArchive = await writeEvidencePackage({
    destination: archivePackage,
    ...archiveResult,
  });
  assert.deepEqual(packagedDirectory.manifest, packagedArchive.manifest);
  assert.deepEqual(
    packagedDirectory.manifest.items[0].artifacts.map((artifact) => artifact.type).sort(),
    ["event_log", "scenario_source", "trace_manifest", "zmr_artifact"],
  );
  for (const artifact of packagedDirectory.manifest.items[0].artifacts) {
    const stored = await readFile(join(directoryPackage, artifact.path));
    assert.equal(stored.length, artifact.sizeBytes);
    assert.equal(sha256Bytes(stored), artifact.digest);
    assert.equal(artifact.redactionState, "unreviewed");
    assert.equal(artifact.disclosureState, "private");
  }
  assert.equal(
    (await readFile(join(
      directoryPackage,
      packagedDirectory.manifest.items[0].artifacts.find((artifact) => artifact.type === "zmr_artifact").path,
    ))).toString("utf8"),
    "done\n",
  );
});

test("directory trace and scenario source pins reject mutation after adaptation before packaging", async (t) => {
  await t.test("trace artifact", async (child) => {
    const fixture = await editableFixture(child);
    const result = await adaptZmrTrace(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioHash: SCENARIO_HASH,
    }));
    const artifactInput = inputForType(result.artifactInputs, "zmr_artifact");
    const original = await readFile(artifactInput.sourcePath);
    const mutation = Buffer.from(original);
    mutation[0] ^= 1;
    await writeFile(artifactInput.sourcePath, mutation);

    const destination = join(fixture.temporary, "mutated-trace-package");
    await assert.rejects(
      writeEvidencePackage({ destination, ...result }),
      (error) => (
        error instanceof EvidenceValidationError
        && error.code === "artifact_source_digest_mismatch"
      ),
    );
    await assert.rejects(lstat(destination), (error) => error?.code === "ENOENT");
    assert.deepEqual(
      (await readdir(fixture.temporary)).filter((name) => (
        name.includes(".tmp-") || name.includes(".publish.lock")
      )),
      [],
    );
  });

  await t.test("scenario source", async (child) => {
    const fixture = await editableFixture(child);
    const scenarioPath = join(fixture.tracePath, "scenario.json");
    const result = await adaptZmrTrace(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioPath,
    }));
    const original = await readFile(scenarioPath);
    const mutation = Buffer.from(original);
    mutation[0] ^= 1;
    await writeFile(scenarioPath, mutation);

    const destination = join(fixture.temporary, "mutated-scenario-package");
    await assert.rejects(
      writeEvidencePackage({ destination, ...result }),
      (error) => (
        error instanceof EvidenceValidationError
        && error.code === "artifact_source_digest_mismatch"
      ),
    );
    await assert.rejects(lstat(destination), (error) => error?.code === "ENOENT");
    assert.deepEqual(
      (await readdir(fixture.temporary)).filter((name) => (
        name.includes(".tmp-") || name.includes(".publish.lock")
      )),
      [],
    );
  });
});

test("failed traces map timeout failure and authoritative terminal outcome", async (t) => {
  const temporary = await temporaryDirectory(t);
  const result = await adaptZmrTrace(baseAdapterOptions({
    tracePath: fixturePath("failed"),
    appArtifactPath: await makeAppArtifact(temporary),
    scenarioHash: SCENARIO_HASH,
  }));

  assert.equal(result.manifest.run.outcome, "failed");
  assert.equal(result.manifest.run.completenessState, "complete");
  assert.equal(result.manifest.items[0].outcome, "failed");
  assert.equal(result.manifest.items[0].failureClassification, "timeout");
  assert.deepEqual(result.manifest.items[0].error, { name: "TimeoutError" });
  assert.deepEqual(validateEvidenceManifest(result.manifest), { ok: true, issues: [] });
});

test("partial traces preserve partial outcome despite a passed terminal event and accept null trace appId", async (t) => {
  const temporary = await temporaryDirectory(t);
  const result = await adaptZmrTrace(baseAdapterOptions({
    tracePath: fixturePath("partial"),
    appArtifactPath: await makeAppArtifact(temporary),
    scenarioHash: SCENARIO_HASH,
  }));

  assert.equal(result.manifest.target.appId, "dev.zmr.fixture");
  assert.equal(result.manifest.run.outcome, "partial");
  assert.equal(result.manifest.run.completenessState, "partial");
  assert.equal(result.manifest.items[0].outcome, "partial");
  assert.equal(result.manifest.items[0].failureClassification, "unknown");
  assert.equal(result.manifest.items[0].extensions["dev.zmr.trace"].partialFailureCount, 1);
  assert.equal(result.manifest.items[0].extensions["dev.zmr.trace"].terminalStatus, "passed");
  assert.deepEqual(validateEvidenceManifest(result.manifest), { ok: true, issues: [] });
});

test("redacted trace metadata is retained and a separate scenario makes aggregate redaction mixed", async (t) => {
  const temporary = await temporaryDirectory(t);
  const scenarioPath = join(fixturePath("passed"), "scenario.json");
  const result = await adaptZmrTrace(baseAdapterOptions({
    tracePath: fixturePath("redacted"),
    appArtifactPath: await makeAppArtifact(temporary),
    scenarioPath,
  }));

  assert.equal(result.manifest.run.redactionState, "mixed");
  const traceInputs = result.artifactInputs.filter((input) => input.type !== "scenario_source");
  assert.ok(traceInputs.every((input) => input.redactionState === "redacted"));
  assert.equal(inputForType(result.artifactInputs, "scenario_source").redactionState, "unreviewed");
  assert.equal(inputForType(result.artifactInputs, "ui_snapshot").contentType, "application/json");
  assert.deepEqual(
    result.manifest.items[0].extensions["dev.zmr.trace"].redaction,
    {
      enabled: true,
      screenshots: "omitted",
      screenRecordings: "omitted",
      textArtifacts: "scrubbed",
      screenshotsOmitted: true,
      screenshotsRedacted: false,
      screenRecordingsOmitted: true,
    },
  );
  assert.deepEqual(validateEvidenceManifest(result.manifest), { ok: true, issues: [] });
});

test("trace schema rejects an invalid snapshotCount", async (t) => {
  const fixture = await editableFixture(t);
  await updateTrace(fixture.tracePath, (trace) => {
    trace.snapshotCount = -1;
  });
  await assertAdapterRejects(baseAdapterOptions({
    tracePath: fixture.tracePath,
    appArtifactPath: fixture.appArtifactPath,
    scenarioHash: SCENARIO_HASH,
  }), "invalid_trace_manifest");
});

test("trace completion, timing, and event-count contradictions are rejected", async (t) => {
  const cases = [
    ["running status", (trace) => { trace.status = "running"; }, "incomplete_trace"],
    ["missing endedAtMs", (trace) => { trace.endedAtMs = null; }, "invalid_trace_manifest"],
    ["duration mismatch", (trace) => { trace.durationMs += 1; }, "invalid_trace_timing"],
    ["event count mismatch", (trace) => { trace.eventCount += 1; }, "trace_event_count_mismatch"],
  ];
  for (const [name, mutate, code] of cases) {
    await t.test(name, async (child) => {
      const fixture = await editableFixture(child);
      await updateTrace(fixture.tracePath, mutate);
      await assertAdapterRejects(baseAdapterOptions({
        tracePath: fixture.tracePath,
        appArtifactPath: fixture.appArtifactPath,
        scenarioHash: SCENARIO_HASH,
      }), code);
    });
  }
});

test("malformed JSONL and missing, duplicate, or contradictory terminals are rejected", async (t) => {
  const cases = [
    ["malformed JSONL", "not-json\n", "invalid_trace_events", 1],
    [
      "missing terminal",
      "{\"seq\":1,\"timestampMs\":1783936800000,\"kind\":\"scenario.start\",\"payload\":{}}\n",
      "invalid_trace_terminal",
      1,
    ],
    [
      "duplicate terminal",
      "{\"seq\":1,\"timestampMs\":1783936800000,\"kind\":\"scenario.end\",\"payload\":{\"status\":\"passed\"}}\n{\"seq\":2,\"timestampMs\":1783936802000,\"kind\":\"scenario.end\",\"payload\":{\"status\":\"passed\"}}\n",
      "invalid_trace_terminal",
      2,
    ],
    [
      "contradictory terminal",
      "{\"seq\":1,\"timestampMs\":1783936800000,\"kind\":\"scenario.start\",\"payload\":{}}\n{\"seq\":2,\"timestampMs\":1783936802000,\"kind\":\"scenario.end\",\"payload\":{\"status\":\"failed\",\"error\":\"Error\"}}\n",
      "trace_terminal_mismatch",
      2,
    ],
  ];
  for (const [name, events, code, eventCount] of cases) {
    await t.test(name, async (child) => {
      const fixture = await editableFixture(child);
      await writeFile(join(fixture.tracePath, "events.jsonl"), events);
      await updateTrace(fixture.tracePath, (trace) => { trace.eventCount = eventCount; });
      await assertAdapterRejects(baseAdapterOptions({
        tracePath: fixture.tracePath,
        appArtifactPath: fixture.appArtifactPath,
        scenarioHash: SCENARIO_HASH,
      }), code);
    });
  }
});

test("explicit appId must match a non-null trace appId", async (t) => {
  const temporary = await temporaryDirectory(t);
  await assertAdapterRejects({
    ...baseAdapterOptions({
      tracePath: fixturePath("passed"),
      appArtifactPath: await makeAppArtifact(temporary),
      scenarioHash: SCENARIO_HASH,
    }),
    appId: "dev.zmr.different",
  }, "trace_app_id_mismatch");
});

test("iOS surfaces and user submitters are accepted while unsupported enum values are rejected", async (t) => {
  const temporary = await temporaryDirectory(t);
  const options = {
    ...baseAdapterOptions({
      tracePath: fixturePath("passed"),
      appArtifactPath: await makeAppArtifact(temporary),
      scenarioHash: SCENARIO_HASH,
    }),
    surface: "ios",
    submitterType: "user",
  };
  const result = await adaptZmrTrace(options);
  assert.equal(result.manifest.target.surface, "ios");
  assert.equal(result.manifest.submission.actorType, "user");
  await assertAdapterRejects({ ...options, surface: "watchos" }, "invalid_adapter_options");
  await assertAdapterRejects({ ...options, submitterType: "service" }, "invalid_adapter_options");
});

test("itemId is verbatim, remains independent of scenario bytes, and rejects edge whitespace", async (t) => {
  const fixture = await editableFixture(t);
  const scenarioPath = join(fixture.temporary, "scenario.json");
  await writeFile(scenarioPath, "{\"value\":1}\n");
  const options = {
    ...baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioPath,
    }),
    itemId: "source item 007",
  };
  const first = await adaptZmrTrace(options);
  await writeFile(scenarioPath, "{\"value\":2}\n");
  const second = await adaptZmrTrace(options);
  assert.equal(first.manifest.items[0].externalId, "source item 007");
  assert.equal(second.manifest.items[0].externalId, "source item 007");
  assert.notEqual(first.manifest.items[0].scenarioHash, second.manifest.items[0].scenarioHash);

  for (const itemId of ["", " item", "item ", "\titem"] ) {
    await assertAdapterRejects({ ...options, itemId }, "invalid_identity");
  }
});

test("scenarioPath and scenarioHash are mutually exclusive and one is required", async (t) => {
  const temporary = await temporaryDirectory(t);
  const common = baseAdapterOptions({
    tracePath: fixturePath("passed"),
    appArtifactPath: await makeAppArtifact(temporary),
    scenarioHash: SCENARIO_HASH,
  });
  const { scenarioHash: _removed, ...withoutScenario } = common;
  await assertAdapterRejects(withoutScenario, "invalid_scenario_identity");
  await assertAdapterRejects({
    ...common,
    scenarioPath: join(fixturePath("passed"), "scenario.json"),
  }, "invalid_scenario_identity");
  await assertAdapterRejects({ ...common, scenarioHash: "not-a-digest" }, "invalid_scenario_identity");
});

test("all required identity and execution strings reject edge whitespace without trimming", async (t) => {
  const temporary = await temporaryDirectory(t);
  const options = baseAdapterOptions({
    tracePath: fixturePath("passed"),
    appArtifactPath: await makeAppArtifact(temporary),
    scenarioHash: SCENARIO_HASH,
  });
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
    await assertAdapterRejects({ ...options, [field]: ` ${options[field]}` }, "invalid_identity");
  }
});

test("unsafe declared trace paths are rejected before filesystem resolution", async (t) => {
  for (const [field, value] of [
    ["eventsPath", "../events.jsonl"],
    ["artifactsDir", "/absolute-artifacts"],
    ["reportPath", "safe/../report.html"],
  ]) {
    await t.test(field, async (child) => {
      const fixture = await editableFixture(child);
      await updateTrace(fixture.tracePath, (trace) => { trace[field] = value; });
      await assertAdapterRejects(baseAdapterOptions({
        tracePath: fixture.tracePath,
        appArtifactPath: fixture.appArtifactPath,
        scenarioHash: SCENARIO_HASH,
      }), "unsafe_trace_path");
    });
  }
});

test("directory ingestion rejects symlinks for declared files and nested artifacts", async (t) => {
  await t.test("declared events file", async (child) => {
    const fixture = await editableFixture(child);
    const eventsPath = join(fixture.tracePath, "events.jsonl");
    await unlink(eventsPath);
    await symlink(join(fixturePath("passed"), "events.jsonl"), eventsPath);
    await assertAdapterRejects(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioHash: SCENARIO_HASH,
    }), "symlink_source_rejected");
  });
  await t.test("nested artifact", async (child) => {
    const fixture = await editableFixture(child);
    await symlink(join(fixturePath("passed"), "events.jsonl"), join(fixture.tracePath, "artifacts", "link"));
    await assertAdapterRejects(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioHash: SCENARIO_HASH,
    }), "symlink_source_rejected");
  });
});

test("archive ingestion rejects undeclared regular files", async (t) => {
  const temporary = await temporaryDirectory(t);
  const archivePath = join(temporary, "unexpected.zmrtrace");
  const archive = await traceArchiveFromDirectory(fixturePath("passed"));
  const withoutEnd = archive.subarray(0, archive.length - (2 * BLOCK_SIZE));
  await writeFile(archivePath, concat([
    withoutEnd,
    makeTar([{ name: "unexpected.txt", body: "nope" }]),
  ]));
  await assertAdapterRejects(baseAdapterOptions({
    tracePath: archivePath,
    appArtifactPath: await makeAppArtifact(temporary),
    scenarioHash: SCENARIO_HASH,
  }), "unexpected_trace_entry");
});

test("declared report and trace artifacts receive deterministic semantic types", async (t) => {
  const fixture = await editableFixture(t);
  await writeFile(join(fixture.tracePath, "report.html"), "<html>report</html>\n");
  await updateTrace(fixture.tracePath, (trace) => { trace.reportPath = "report.html"; });
  const artifactCases = [
    ["screen.png", "screenshot"],
    ["screen.jpeg", "screenshot"],
    ["recording.mp4", "video"],
    ["recording.webm", "video"],
    ["snapshot-2.xml", "ui_snapshot"],
    ["other.bin", "zmr_artifact"],
  ];
  for (const [name] of artifactCases) {
    await writeFile(join(fixture.tracePath, "artifacts", name), name);
  }
  const result = await adaptZmrTrace(baseAdapterOptions({
    tracePath: fixture.tracePath,
    appArtifactPath: fixture.appArtifactPath,
    scenarioHash: SCENARIO_HASH,
  }));
  assert.equal(inputForType(result.artifactInputs, "report").contentType, "text/html; charset=utf-8");
  const types = result.artifactInputs.map((input) => input.type);
  assert.equal(types.filter((type) => type === "screenshot").length, 2);
  assert.equal(types.filter((type) => type === "video").length, 2);
  for (const [, type] of artifactCases) assert.ok(types.includes(type));
  assert.ok(result.artifactInputs.every((input) => input.disclosureState === "private"));
});

test("a declared report nested under artifactsDir is accepted once as a report", async (t) => {
  const fixture = await editableFixture(t);
  await writeFile(join(fixture.tracePath, "artifacts", "report.html"), "<html>nested</html>\n");
  await updateTrace(fixture.tracePath, (trace) => { trace.reportPath = "artifacts/report.html"; });
  const result = await adaptZmrTrace(baseAdapterOptions({
    tracePath: fixture.tracePath,
    appArtifactPath: fixture.appArtifactPath,
    scenarioHash: SCENARIO_HASH,
  }));
  assert.equal(result.artifactInputs.filter((input) => input.type === "report").length, 1);
});

test("directory and archive sources reject oversized files before reading them", async (t) => {
  await t.test("directory entry", async (child) => {
    const fixture = await editableFixture(child);
    const hugePath = join(fixture.tracePath, "artifacts", "huge.bin");
    const handle = await openFile(hugePath, "w");
    await handle.truncate((128 * MIB) + 1);
    await handle.close();
    await assertAdapterRejects(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioHash: SCENARIO_HASH,
    }), "source_file_too_large");
  });
  await t.test("archive source", async (child) => {
    const temporary = await temporaryDirectory(child);
    const archivePath = join(temporary, "huge.zmrtrace");
    const handle = await openFile(archivePath, "w");
    await handle.truncate((512 * MIB) + 1);
    await handle.close();
    await assert.rejects(loadZmrTrace(archivePath), (error) => {
      assert.ok(error instanceof EvidenceValidationError);
      assert.equal(error.code, "source_file_too_large");
      return true;
    });
  });
});

test("trace schemaVersion must be exactly 1 and required trace files must exist", async (t) => {
  await t.test("unsupported schema", async (child) => {
    const fixture = await editableFixture(child);
    await updateTrace(fixture.tracePath, (trace) => { trace.schemaVersion = 2; });
    await assertAdapterRejects(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioHash: SCENARIO_HASH,
    }), "unsupported_trace_schema");
  });
  await t.test("missing trace.json", async (child) => {
    const fixture = await editableFixture(child);
    await unlink(join(fixture.tracePath, "trace.json"));
    await assertAdapterRejects(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioHash: SCENARIO_HASH,
    }), "invalid_source_path");
  });
  await t.test("missing declared events", async (child) => {
    const fixture = await editableFixture(child);
    await unlink(join(fixture.tracePath, "events.jsonl"));
    await assertAdapterRejects(baseAdapterOptions({
      tracePath: fixture.tracePath,
      appArtifactPath: fixture.appArtifactPath,
      scenarioHash: SCENARIO_HASH,
    }), "invalid_source_path");
  });
});

test("failed-step contradictions between trace and terminal event are rejected", async (t) => {
  const fixture = await editableFixture(t, "failed");
  const eventsPath = join(fixture.tracePath, "events.jsonl");
  const events = (await readFile(eventsPath, "utf8")).replace(
    '"failedStepIndex":1',
    '"failedStepIndex":2',
  );
  await writeFile(eventsPath, events);
  await assertAdapterRejects(baseAdapterOptions({
    tracePath: fixture.tracePath,
    appArtifactPath: fixture.appArtifactPath,
    scenarioHash: SCENARIO_HASH,
  }), "trace_terminal_mismatch");
});

test("unfamiliar failed trace errors map to unknown without guessing", async (t) => {
  const fixture = await editableFixture(t, "failed");
  await updateTrace(fixture.tracePath, (trace) => { trace.error = "UnfamiliarDriverError"; });
  const eventsPath = join(fixture.tracePath, "events.jsonl");
  await writeFile(
    eventsPath,
    (await readFile(eventsPath, "utf8")).replaceAll("TimeoutError", "UnfamiliarDriverError"),
  );
  const result = await adaptZmrTrace(baseAdapterOptions({
    tracePath: fixture.tracePath,
    appArtifactPath: fixture.appArtifactPath,
    scenarioHash: SCENARIO_HASH,
  }));
  assert.equal(result.manifest.items[0].failureClassification, "unknown");
  assert.deepEqual(result.manifest.items[0].error, { name: "UnfamiliarDriverError" });
});

test("app hashing accepts a regular file while app artifact and scenario inputs reject symlinks", async (t) => {
  const temporary = await temporaryDirectory(t);
  const realApp = await makeAppArtifact(temporary);
  const regular = await adaptZmrTrace(baseAdapterOptions({
    tracePath: fixturePath("passed"),
    appArtifactPath: realApp,
    scenarioHash: SCENARIO_HASH,
  }));
  assert.equal(
    regular.manifest.target.artifactDigest,
    sha256Bytes(await readFile(realApp)),
  );
  const appLink = join(temporary, "linked.appbin");
  await symlink(realApp, appLink);
  await assertAdapterRejects(baseAdapterOptions({
    tracePath: fixturePath("passed"),
    appArtifactPath: appLink,
    scenarioHash: SCENARIO_HASH,
  }), "symlink_source_rejected");

  const scenarioLink = join(temporary, "scenario-link.json");
  await symlink(join(fixturePath("passed"), "scenario.json"), scenarioLink);
  await assertAdapterRejects(baseAdapterOptions({
    tracePath: fixturePath("passed"),
    appArtifactPath: realApp,
    scenarioPath: scenarioLink,
  }), "symlink_source_rejected");

  const appDirectory = join(temporary, "app-directory");
  await mkdir(appDirectory);
  await assertAdapterRejects(baseAdapterOptions({
    tracePath: fixturePath("passed"),
    appArtifactPath: appDirectory,
    scenarioHash: SCENARIO_HASH,
  }), "source_not_regular_file");
});

test("app hashing detects same-inode mutation even when mtime is restored", async (t) => {
  const fixture = await editableFixture(t);
  const fixedTime = new Date("2000-01-01T00:00:00.000Z");
  await utimes(fixture.appArtifactPath, fixedTime, fixedTime);
  const before = await lstat(fixture.appArtifactPath, { bigint: true });
  let hookCalls = 0;

  globalThis[ZMR_ADAPTER_TEST_HOOK] = async ({ phase }) => {
    if (phase !== "app-hash-chunk" || hookCalls > 0) return;
    hookCalls += 1;
    const handle = await openFile(fixture.appArtifactPath, "r+");
    try {
      const mutation = Buffer.from(["fixture app binary\n".charCodeAt(0) ^ 1]);
      await handle.write(mutation, 0, mutation.length, 0);
      await handle.sync();
    } finally {
      await handle.close();
    }
    await utimes(fixture.appArtifactPath, fixedTime, fixedTime);
    const mutated = await lstat(fixture.appArtifactPath, { bigint: true });
    assert.equal(mutated.dev, before.dev);
    assert.equal(mutated.ino, before.ino);
    assert.equal(mutated.size, before.size);
    assert.equal(mutated.mtimeNs, before.mtimeNs);
    assert.notEqual(mutated.ctimeNs, before.ctimeNs);
  };
  t.after(() => { delete globalThis[ZMR_ADAPTER_TEST_HOOK]; });

  await assertAdapterRejects(baseAdapterOptions({
    tracePath: fixture.tracePath,
    appArtifactPath: fixture.appArtifactPath,
    scenarioHash: SCENARIO_HASH,
  }), "source_changed_during_read");
  assert.equal(hookCalls, 1);
});

test("directory ingestion enforces the same 10,000 accepted-file limit as archives", async (t) => {
  const fixture = await editableFixture(t);
  const artifactsDirectory = join(fixture.tracePath, "artifacts");
  const additionalCount = DEFAULT_TAR_LIMITS.maxEntries - 2;
  for (let start = 0; start < additionalCount; start += 250) {
    const end = Math.min(additionalCount, start + 250);
    await Promise.all(Array.from({ length: end - start }, (_, offset) => (
      writeFile(join(artifactsDirectory, `empty-${start + offset}.bin`), "")
    )));
  }
  await assertAdapterRejects(baseAdapterOptions({
    tracePath: fixture.tracePath,
    appArtifactPath: fixture.appArtifactPath,
    scenarioHash: SCENARIO_HASH,
  }), "trace_file_limit_exceeded");
});
