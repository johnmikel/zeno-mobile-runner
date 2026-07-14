import assert from "node:assert/strict";
import {
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import ZenoPlaywrightReporter, {
  playwrightJourneyKey,
} from "../npm/evidence/playwright-reporter.mjs";
import { canonicalBytes, sha256Bytes } from "../npm/evidence/canonical-json.mjs";
import { createWebFingerprint } from "../npm/evidence/fingerprints.mjs";
import { validateEvidencePackage } from "../npm/evidence/package-writer.mjs";

const DIGEST_C = `sha256:${"c".repeat(64)}`;
const DIGEST_D = `sha256:${"d".repeat(64)}`;
const COMMIT_SHA = "1".repeat(40);
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test.after(async () => {
  const debris = (await readdir(repositoryRoot))
    .filter((name) => name.startsWith("\\") && name.includes("\\zmr-playwright-reporter-"));
  assert.deepEqual(debris, [], "reporter tests must not leave lexical temp paths in the worktree");
});

function reporterOptions(outputDir, overrides = {}) {
  return {
    outputDir,
    projectId: "web-project-42",
    submitterType: "automation",
    submitterId: "web-ci",
    releaseId: "release-web-42",
    commitSha: COMMIT_SHA,
    deploymentId: "deployment-42",
    environment: "staging",
    configDigest: DIGEST_D,
    buildManifestDigest: DIGEST_C,
    runId: "web-run-42",
    browserName: "chromium",
    browserVersion: "126.0",
    ...overrides,
  };
}

async function workspace(t) {
  const lexicalRoot = await mkdtemp(path.join(os.tmpdir(), "zmr-playwright-reporter-"));
  const rootDir = await realpath(lexicalRoot);
  t.after(async () => {
    await rm(rootDir, { recursive: true, force: true });
  });
  return rootDir;
}

function apiTest(rootDir, overrides = {}) {
  const project = {
    name: "chromium",
    metadata: {
      zenoEvidence: {
        browserName: "chromium",
        browserVersion: "126.0",
      },
    },
  };
  return {
    id: "playwright-source-login",
    title: "user can sign in",
    titlePath: () => ["auth", "user can sign in"],
    location: {
      file: path.join(rootDir, "tests", "auth.spec.ts"),
      line: 10,
      column: 1,
    },
    expectedStatus: "passed",
    annotations: [{ type: "zeno:journey", description: "journey-login" }],
    outcome: () => "expected",
    parent: { project: () => project },
    ...overrides,
  };
}

function apiResult(overrides = {}) {
  return {
    retry: 0,
    status: "passed",
    startTime: new Date("2026-07-13T10:00:00.500Z"),
    duration: 1000,
    error: undefined,
    attachments: [],
    ...overrides,
  };
}

function apiConfig(rootDir, overrides = {}) {
  return {
    rootDir,
    version: "1.42.0",
    shard: null,
    projects: [],
    ...overrides,
  };
}

function apiFullResult(overrides = {}) {
  return {
    status: "passed",
    startTime: new Date("2026-07-13T10:00:00.000Z"),
    duration: 2000,
    ...overrides,
  };
}

async function runPassedLifecycle(t, overrides = {}) {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await writeFile(path.join(rootDir, "tests", "auth.spec.ts"), "export const login = true;\n");
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, overrides.options));
  const testCase = apiTest(rootDir, overrides.test);
  reporter.onBegin(apiConfig(rootDir, overrides.config), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult(overrides.result));
  return { rootDir, outputDir, reporter, testCase };
}

async function runFixtureLifecycle(
  t,
  fixtureName,
  optionOverrides = {},
  resultTransform = (result) => result,
) {
  const fixture = JSON.parse(await readFile(
    path.join(repositoryRoot, "fixtures", "evidence", "v1", "sources", "playwright", fixtureName),
    "utf8",
  ));
  assert.equal(fixture.format, "zeno-playwright-reporter-fixture-v1");
  const tempRoot = await workspace(t);
  const rootDir = path.join(tempRoot, fixture.config.rootDir);
  const projects = new Map(fixture.config.projects.map((project) => [project.name, {
    name: project.name,
    metadata: project.metadata,
  }]));
  const tests = [];
  for (const source of fixture.tests) {
    const sourcePath = path.join(rootDir, ...source.location.relativeFile.split("/"));
    await mkdir(path.dirname(sourcePath), { recursive: true });
    await writeFile(sourcePath, `// ${source.id}\nexport const fixture = true;\n`);
    const project = projects.get(source.projectName);
    const testCase = {
      id: source.id,
      title: source.title,
      titlePath: () => [...source.titlePath],
      location: {
        file: sourcePath,
        line: source.location.line,
        column: source.location.column,
      },
      expectedStatus: source.expectedStatus,
      annotations: source.annotations.map((annotation) => ({ ...annotation })),
      outcome: () => source.outcome,
      parent: { project: () => project },
    };
    tests.push(testCase);
  }
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, optionOverrides));
  const config = {
    ...apiConfig(rootDir),
    version: fixture.config.version,
    projects: [...projects.values()],
  };
  reporter.onBegin(config, { allTests: () => tests });
  for (let testIndex = 0; testIndex < fixture.tests.length; testIndex += 1) {
    for (const result of fixture.tests[testIndex].results) {
      reporter.onTestEnd(tests[testIndex], resultTransform({
        retry: result.retry,
        status: result.status,
        startTime: new Date(result.startTime),
        duration: result.durationMs,
        error: result.error,
        attachments: result.attachments.map((attachment) => ({ ...attachment })),
      }, result));
    }
  }
  const fullResult = {
    status: fixture.fullResult.status,
    startTime: new Date(fixture.fullResult.startTime),
    duration: fixture.fullResult.durationMs,
  };
  return { fixture, outputDir, reporter, tests, fullResult };
}

test("printsToStdio reports that the reporter is silent", () => {
  const reporter = new ZenoPlaywrightReporter(reporterOptions("evidence"));
  assert.equal(reporter.printsToStdio(), false);
});

test("a supported passed lifecycle writes and validates durable evidence", async (t) => {
  const { outputDir, reporter } = await runPassedLifecycle(t);

  const completion = reporter.onEnd(apiFullResult());
  assert.equal(typeof completion?.then, "function", "onEnd must be async");
  assert.equal(await completion, undefined);

  const manifestPath = path.join(outputDir, "evidence.json");
  const validation = await validateEvidencePackage(manifestPath);
  assert.equal(validation.ok, true);
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  assert.equal(manifest.producer.name, "playwright");
  assert.equal(manifest.producer.version, "1.42.0");
  assert.equal(manifest.producer.adapterVersion, "1.0.0");
  assert.equal(manifest.items.length, 1);
  assert.equal(manifest.items[0].outcome, "passed");
  assert.equal(manifest.items[0].journeyId, "journey-login");
  assert.deepEqual(manifest.items[0].execution, {
    kind: "browser",
    browserName: "chromium",
    browserVersion: "126.0",
  });
  assert.equal(
    manifest.target.targetFingerprint,
    createWebFingerprint({
      recipe: "web-v1",
      surface: "web",
      environment: "staging",
      deploymentId: "deployment-42",
      commitSha: COMMIT_SHA,
      buildManifestDigest: DIGEST_C,
      configDigest: DIGEST_D,
    }),
  );
});

test("onEnd does not resolve before evidence and artifacts are durable", async (t) => {
  const { outputDir, reporter } = await runPassedLifecycle(t, {
    result: {
      attachments: [{
        name: "console",
        contentType: "text/plain",
        body: Buffer.from("durable attachment", "utf8"),
      }],
    },
  });

  await reporter.onEnd(apiFullResult());
  const validation = await validateEvidencePackage(path.join(outputDir, "evidence.json"));
  assert.equal(validation.manifest.items[0].artifacts.length, 1);
  const artifact = validation.manifest.items[0].artifacts[0];
  assert.equal(await readFile(path.join(outputDir, artifact.path), "utf8"), "durable attachment");
});

test("constructor retains expected option errors and onEnd fails closed", async (t) => {
  const rootDir = await workspace(t);
  const outputDir = path.join(rootDir, "evidence");
  assert.doesNotThrow(() => new ZenoPlaywrightReporter(reporterOptions(outputDir, {
    projectId: " bad-project",
  })));
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, {
    projectId: " bad-project",
  }));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });

  assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  assert.equal(await readFile(path.join(outputDir, "evidence-error.json"), "utf8").then(Boolean), true);
});

test("packaging failures are retained, reported safely, and override the run status", async (t) => {
  const rootDir = await workspace(t);
  const outsideRoot = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await writeFile(path.join(rootDir, "tests", "auth.spec.ts"), "export const login = true;\n");
  const attachment = path.join(outsideRoot, "secret.txt");
  await writeFile(attachment, "must not escape", "utf8");
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, {
    artifactRoot: rootDir,
  }));
  const testCase = apiTest(rootDir);
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult({
    attachments: [{ name: "outside", contentType: "text/plain", path: attachment }],
  }));

  assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  const errorBody = await readFile(path.join(outputDir, "evidence-error.json"), "utf8");
  assert.doesNotMatch(errorBody, new RegExp(outsideRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  await assert.rejects(readFile(path.join(outputDir, "evidence.json")));
});

test("the passed conformance fixture translates only supported Playwright API members", async (t) => {
  const { fixture, outputDir, reporter, fullResult } = await runFixtureLifecycle(
    t,
    "passed.json",
    { browserName: undefined, browserVersion: undefined },
  );
  assert.equal(await reporter.onEnd(fullResult), undefined);
  const manifest = JSON.parse(await readFile(path.join(outputDir, "evidence.json"), "utf8"));
  const item = manifest.items[0];
  assert.equal(manifest.producer.version, fixture.config.version);
  assert.equal(item.journeyId, "journey-login");
  assert.equal(item.extensions["dev.playwright.test"].projectName, "chromium");
  assert.equal(item.extensions["dev.playwright.test"].expectedStatus, "passed");
  assert.deepEqual(item.extensions["dev.playwright.test"].location, {
    relativeFile: "tests/auth.spec.ts",
    line: 10,
    column: 1,
  });
  assert.deepEqual(item.execution, {
    kind: "browser",
    browserName: "chromium",
    browserVersion: "126.0",
  });
  assert.equal(Object.hasOwn(item, "projectName"), false);
  assert.equal(Object.hasOwn(item, "expectedStatus"), false);
  assert.doesNotMatch(JSON.stringify(manifest), new RegExp(outputDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

test("the retry fixture preserves every attempt and flaky aggregate source context", async (t) => {
  const { fixture, outputDir, reporter, fullResult } = await runFixtureLifecycle(t, "retry-pass.json");
  assert.equal(await reporter.onEnd(fullResult), undefined);
  const manifest = JSON.parse(await readFile(path.join(outputDir, "evidence.json"), "utf8"));
  assert.deepEqual(manifest.items.map(({ attempt, outcome }) => ({ attempt, outcome })), [
    { attempt: 0, outcome: "failed" },
    { attempt: 1, outcome: "passed" },
  ]);
  assert.equal(manifest.items[0].failureClassification, "unknown");
  assert.equal(manifest.items[1].failureClassification, null);
  assert.equal(manifest.items[0].externalId, manifest.items[1].externalId);
  const expectedExternalId = `playwright:${sha256Bytes(Buffer.from(fixture.tests[0].id)).slice("sha256:".length)}`;
  assert.equal(manifest.items[0].externalId, expectedExternalId);
  assert.notEqual(manifest.items[0].externalId, fixture.tests[0].id);
  for (const item of manifest.items) {
    const extension = item.extensions["dev.playwright.test"];
    assert.equal(extension.aggregateOutcome, "flaky");
    assert.equal(extension.sourceTestIdDigest, sha256Bytes(Buffer.from(fixture.tests[0].id)));
  }
  assert.doesNotMatch(JSON.stringify(manifest), new RegExp(fixture.tests[0].id));
});

test("public TestResult statuses map without expected-status rewriting", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "statuses.spec.ts");
  await writeFile(sourcePath, "export const statuses = true;\n");
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir));
  const statuses = ["passed", "failed", "timedOut", "skipped", "interrupted"];
  const cases = statuses.map((status, index) => apiTest(rootDir, {
    id: `status-${status}`,
    title: status,
    titlePath: () => ["statuses", status],
    location: { file: sourcePath, line: index + 1, column: 1 },
    expectedStatus: status === "failed" ? "failed" : "passed",
    outcome: () => status === "failed" ? "expected" : "unexpected",
  }));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => cases });
  for (let index = 0; index < cases.length; index += 1) {
    reporter.onTestEnd(cases[index], apiResult({
      status: statuses[index],
      startTime: new Date(Date.parse("2026-07-13T10:00:00.500Z") + index * 1000),
    }));
  }
  assert.equal(await reporter.onEnd(apiFullResult({ status: "interrupted", duration: 6000 })), undefined);
  const manifest = JSON.parse(await readFile(path.join(outputDir, "evidence.json"), "utf8"));
  const byTitle = new Map(manifest.items.map((item) => [
    item.extensions["dev.playwright.test"].titlePath.at(-1),
    item,
  ]));
  assert.deepEqual(statuses.map((status) => byTitle.get(status).outcome), [
    "passed", "failed", "timed_out", "skipped", "interrupted",
  ]);
  assert.deepEqual(statuses.map((status) => byTitle.get(status).failureClassification), [
    null, "unknown", "timeout", null, "interrupted",
  ]);
  assert.equal(byTitle.get("failed").outcome, "failed", "expected-to-fail stays an actual failure");
  assert.equal(manifest.run.outcome, "interrupted");
  assert.equal(manifest.run.completenessState, "partial");
});

test("explicit mapping overrides the final matching annotation and missing mapping stays null", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "mapping.spec.ts");
  await writeFile(sourcePath, "export const mapping = true;\n");
  const mapped = apiTest(rootDir, {
    id: "mapped-test",
    titlePath: () => ["mapping", "mapped"],
    location: { file: sourcePath, line: 1, column: 1 },
    annotations: [
      { type: "zeno:journey", description: "annotation-first" },
      { type: "other", description: "ignored" },
      { type: "zeno:journey", description: "annotation-final" },
    ],
  });
  const unmapped = apiTest(rootDir, {
    id: "unmapped-test",
    titlePath: () => ["mapping", "unmapped"],
    location: { file: sourcePath, line: 2, column: 1 },
    annotations: [],
  });
  const mappingKey = playwrightJourneyKey({
    projectName: "chromium",
    relativeFile: "tests/mapping.spec.ts",
    titlePath: ["mapping", "mapped"],
  });
  const reporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, "evidence"), {
    journeyMap: { [mappingKey]: "explicit-journey" },
  }));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [mapped, unmapped] });
  reporter.onTestEnd(mapped, apiResult());
  reporter.onTestEnd(unmapped, apiResult({ startTime: new Date("2026-07-13T10:00:01.500Z") }));
  assert.equal(await reporter.onEnd(apiFullResult({ duration: 3000 })), undefined);
  const manifest = JSON.parse(await readFile(path.join(rootDir, "evidence", "evidence.json"), "utf8"));
  const byTitle = new Map(manifest.items.map((item) => [
    item.extensions["dev.playwright.test"].titlePath.at(-1),
    item,
  ]));
  assert.equal(byTitle.get("mapped").journeyId, "explicit-journey");
  assert.equal(byTitle.get("mapped").extensions["dev.playwright.test"].mappingState, "mapped");
  assert.equal(byTitle.get("unmapped").journeyId, null);
  assert.equal(byTitle.get("unmapped").extensions["dev.playwright.test"].mappingState, "unmapped");
  assert.notEqual(byTitle.get("unmapped").journeyId, "unmapped");
});

test("buildManifestPath hashes exact bytes after resolving against config.rootDir", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await mkdir(path.join(rootDir, "dist"), { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "build.spec.ts");
  const buildManifestBytes = Buffer.from("{\"assets\":[\"app.js\"]}\n", "utf8");
  await writeFile(sourcePath, "export const build = true;\n");
  await writeFile(path.join(rootDir, "dist", "manifest.json"), buildManifestBytes);
  const options = reporterOptions("evidence");
  delete options.buildManifestDigest;
  options.buildManifestPath = "dist/manifest.json";
  const reporter = new ZenoPlaywrightReporter(options);
  const testCase = apiTest(rootDir, {
    id: "build-manifest-test",
    location: { file: sourcePath, line: 1, column: 1 },
  });
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult());

  assert.equal(await reporter.onEnd(apiFullResult()), undefined);
  const manifest = JSON.parse(await readFile(path.join(rootDir, "evidence", "evidence.json"), "utf8"));
  const expectedDigest = sha256Bytes(buildManifestBytes);
  assert.equal(manifest.target.buildManifestDigest, expectedDigest);
  assert.equal(manifest.target.targetFingerprint, createWebFingerprint({
    recipe: "web-v1",
    surface: "web",
    environment: "staging",
    deploymentId: "deployment-42",
    commitSha: COMMIT_SHA,
    buildManifestDigest: expectedDigest,
    configDigest: DIGEST_D,
  }));
  assert.doesNotMatch(JSON.stringify(manifest), /dist\/manifest\.json/);
});

test("scenarioHash changes with either source bytes or titlePath", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "scenario.spec.ts");

  const run = async (outputName, sourceBytes, titlePath) => {
    await writeFile(sourcePath, sourceBytes);
    const reporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, outputName)));
    const testCase = apiTest(rootDir, {
      id: `scenario-${outputName}`,
      titlePath: () => [...titlePath],
      location: { file: sourcePath, line: 1, column: 1 },
    });
    reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
    reporter.onTestEnd(testCase, apiResult());
    assert.equal(await reporter.onEnd(apiFullResult()), undefined);
    const manifest = JSON.parse(await readFile(path.join(rootDir, outputName, "evidence.json"), "utf8"));
    return manifest.items[0].scenarioHash;
  };

  const original = await run("evidence-a", "export const value = 'a';\n", ["suite", "test"]);
  const changedBytes = await run("evidence-b", "export const value = 'b';\n", ["suite", "test"]);
  const changedTitle = await run("evidence-c", "export const value = 'a';\n", ["suite", "renamed"]);
  assert.notEqual(original, changedBytes);
  assert.notEqual(original, changedTitle);
});

test("path and body attachments use the writer with semantic private metadata", async (t) => {
  const rootDir = await workspace(t);
  const artifactRoot = path.join(rootDir, "artifacts");
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await mkdir(artifactRoot, { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "attachments.spec.ts");
  const screenshotPath = path.join(artifactRoot, "actual.png");
  await writeFile(sourcePath, "export const attachments = true;\n");
  await writeFile(screenshotPath, Buffer.from("png bytes"));
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, { artifactRoot }));
  const testCase = apiTest(rootDir, {
    id: "attachments-test",
    location: { file: sourcePath, line: 1, column: 1 },
  });
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult({
    attachments: [
      { name: "actual", contentType: "image/png", path: screenshotPath },
      { name: "trace", contentType: "application/zip", body: Buffer.from("zip bytes") },
      { name: "movie", contentType: "video/webm", body: Buffer.from("video bytes") },
      { name: "log", contentType: "text/plain", body: Buffer.from("log bytes") },
    ],
  }));
  assert.equal(await reporter.onEnd(apiFullResult()), undefined);
  const validation = await validateEvidencePackage(path.join(outputDir, "evidence.json"));
  const artifacts = validation.manifest.items[0].artifacts;
  assert.deepEqual(new Set(artifacts.map((artifact) => artifact.type)), new Set([
    "screenshot", "trace", "video", "test_attachment",
  ]));
  for (const artifact of artifacts) {
    assert.equal(artifact.redactionState, "unreviewed");
    assert.equal(artifact.disclosureState, "private");
    assert.match(artifact.path, /^artifacts\/sha256\/[a-f0-9]{2}\/[a-f0-9]{62}$/);
  }
  assert.doesNotMatch(JSON.stringify(validation.manifest), new RegExp(rootDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

test("a symlink attachment is rejected through the fail-closed path", async (t) => {
  const rootDir = await workspace(t);
  const artifactRoot = path.join(rootDir, "artifacts");
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await mkdir(artifactRoot, { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "symlink.spec.ts");
  const targetPath = path.join(artifactRoot, "target.txt");
  const linkPath = path.join(artifactRoot, "link.txt");
  await writeFile(sourcePath, "export const symlink = true;\n");
  await writeFile(targetPath, "target");
  const { symlink } = await import("node:fs/promises");
  await symlink(targetPath, linkPath);
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, { artifactRoot }));
  const testCase = apiTest(rootDir, {
    id: "symlink-test",
    location: { file: sourcePath, line: 1, column: 1 },
  });
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult({
    attachments: [{ name: "link", contentType: "text/plain", path: linkPath }],
  }));
  assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  await assert.rejects(readFile(path.join(outputDir, "evidence.json")));
});

test("TestError message fallback is bounded and redacts paths, controls, and secrets", async (t) => {
  const rootDir = await workspace(t);
  const artifactRoot = path.join(rootDir, "artifacts");
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await mkdir(artifactRoot, { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "error.spec.ts");
  const attachmentPath = path.join(artifactRoot, "failure.txt");
  await writeFile(sourcePath, "export const error = true;\n");
  await writeFile(attachmentPath, "failure attachment");
  const rawSecret = "should-never-survive";
  const controlSeparatedSecrets = [
    "bearer-control-secret",
    "token-control-secret",
    "api-key-control-secret",
  ];
  const rawValue = [
    `failure at ${sourcePath}`,
    `root ${rootDir}`,
    `attachment ${attachmentPath}`,
    String.raw`windows C:\Users\alice\tests\secret.spec.ts`,
    `Bearer ${rawSecret}`,
    `authorization=${rawSecret}`,
    `token: ${rawSecret}`,
    `API_KEY=${rawSecret}`,
    `password=${rawSecret}`,
    `secret=${rawSecret}`,
    `Bearer\u000a${controlSeparatedSecrets[0]}`,
    `token\u0001=\u0002${controlSeparatedSecrets[1]}`,
    `api_key\u0003:\u0004${controlSeparatedSecrets[2]}`,
    "controls\u0000stay\u0007separated\u001f",
    "x".repeat(5000),
  ].join(" | ");
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, { artifactRoot }));
  const testCase = apiTest(rootDir, {
    id: "error-test",
    location: { file: sourcePath, line: 1, column: 1 },
  });
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult({
    status: "failed",
    error: { value: rawValue },
    attachments: [{ name: "failure", contentType: "text/plain", path: attachmentPath }],
  }));
  assert.equal(await reporter.onEnd(apiFullResult({ status: "failed" })), undefined);
  const manifest = JSON.parse(await readFile(path.join(outputDir, "evidence.json"), "utf8"));
  const storedError = manifest.items[0].error;
  assert.deepEqual(Object.keys(storedError), ["message"]);
  assert.ok(storedError.message.length <= 4096);
  assert.match(storedError.message, /<redacted-path>/);
  assert.match(storedError.message, /<redacted-secret>/);
  assert.doesNotMatch(storedError.message, /[\u0000-\u001f\u007f]/);
  assert.doesNotMatch(storedError.message, new RegExp(rawSecret));
  for (const secret of controlSeparatedSecrets) {
    assert.doesNotMatch(storedError.message, new RegExp(secret));
  }
  assert.match(storedError.message, /controls stay separated/);
  assert.doesNotMatch(storedError.message, /Users\\alice/);
  assert.doesNotMatch(storedError.message, new RegExp(rootDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.equal(Object.hasOwn(storedError, "value"), false);
  assert.equal(Object.hasOwn(storedError, "name"), false);
});

test("message takes precedence over TestError value", async (t) => {
  const { outputDir, reporter } = await runPassedLifecycle(t, {
    result: {
      status: "failed",
      error: { message: "preferred message", value: "discarded value" },
    },
  });
  assert.equal(await reporter.onEnd(apiFullResult({ status: "failed" })), undefined);
  const manifest = JSON.parse(await readFile(path.join(outputDir, "evidence.json"), "utf8"));
  assert.deepEqual(manifest.items[0].error, { message: "preferred message" });
  assert.doesNotMatch(JSON.stringify(manifest), /discarded value/);
});

test("every invalid reporter identity is retained by the constructor", async (t) => {
  const rootDir = await workspace(t);
  const invalidOverrides = [
    { projectId: "" },
    { submitterId: " submitter" },
    { releaseId: "release " },
    { deploymentId: "deploy\u0000ment" },
    { environment: "\tstaging" },
    { runId: " " },
    { browserName: "chromium " },
    { browserVersion: "\u0007126" },
    { journeyAnnotation: " journey" },
  ];
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    for (const overrides of invalidOverrides) {
      const outputDir = path.join(rootDir, `error-${invalidOverrides.indexOf(overrides)}`);
      let reporter;
      assert.doesNotThrow(() => {
        reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, overrides));
      });
      reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
      assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
    }
  } finally {
    process.stderr.write = originalWrite;
  }
});

test("onBegin and onTestEnd retain invalid derived execution identities", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await writeFile(path.join(rootDir, "tests", "identity.spec.ts"), "export const identity = true;\n");
  const invalidConfigReporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, "config-error")));
  invalidConfigReporter.onBegin(apiConfig(rootDir, { version: " 1.42.0" }), { allTests: () => [] });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await invalidConfigReporter.onEnd(apiFullResult()), { status: "failed" });

    const invalidTestReporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, "test-error")));
    const invalidTest = apiTest(rootDir, { id: "" });
    invalidTestReporter.onBegin(apiConfig(rootDir), { allTests: () => [invalidTest] });
    invalidTestReporter.onTestEnd(invalidTest, apiResult());
    assert.deepEqual(await invalidTestReporter.onEnd(apiFullResult()), { status: "failed" });

    const invalidProjectReporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, "project-error"), {
      browserName: undefined,
      browserVersion: undefined,
    }));
    const invalidProjectTest = apiTest(rootDir, {
      parent: {
        project: () => ({
          name: " chromium",
          metadata: { zenoEvidence: { browserName: "Chromium 126", browserVersion: "" } },
        }),
      },
    });
    invalidProjectReporter.onBegin(apiConfig(rootDir), { allTests: () => [invalidProjectTest] });
    invalidProjectReporter.onTestEnd(invalidProjectTest, apiResult());
    assert.deepEqual(await invalidProjectReporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
});

test("a zero-result run always takes the fail-closed path", async (t) => {
  const rootDir = await workspace(t);
  const outputDir = path.join(rootDir, "empty-evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
  await assert.rejects(readFile(path.join(outputDir, "evidence.json")));
});

test("sourceManifestDigest covers sorted public attempt records and derived run IDs are digests", async (t) => {
  const { fixture, outputDir, reporter, fullResult } = await runFixtureLifecycle(t, "retry-pass.json", {
    runId: undefined,
  });
  assert.equal(await reporter.onEnd(fullResult), undefined);
  const manifest = JSON.parse(await readFile(path.join(outputDir, "evidence.json"), "utf8"));
  const scenarioByAttempt = new Map(manifest.items.map((item) => [item.attempt, item.scenarioHash]));
  const externalId = `playwright:${sha256Bytes(Buffer.from(fixture.tests[0].id)).slice("sha256:".length)}`;
  const sourceRecords = fixture.tests[0].results.map((result) => ({
    externalId,
    attempt: result.retry,
    status: result.status,
    expectedStatus: fixture.tests[0].expectedStatus,
    startTime: result.startTime,
    durationMs: result.durationMs,
    scenarioHash: scenarioByAttempt.get(result.retry),
    attachments: result.attachments.map(({ name, contentType }) => ({ name, contentType })),
  }));
  assert.equal(manifest.run.sourceManifestDigest, sha256Bytes(canonicalBytes(sourceRecords)));
  assert.match(manifest.run.externalId, /^playwright-run:[a-f0-9]{64}$/);

  const second = await runFixtureLifecycle(
    t,
    "retry-pass.json",
    { runId: undefined },
    (result) => ({ ...result, startTime: new Date(result.startTime.valueOf() + 1000) }),
  );
  second.fullResult.duration = 4000;
  assert.equal(await second.reporter.onEnd(second.fullResult), undefined);
  const secondManifest = JSON.parse(await readFile(path.join(second.outputDir, "evidence.json"), "utf8"));
  assert.notEqual(manifest.run.externalId, secondManifest.run.externalId);
});

test("a configured shard is appended to outputDir and retained as run context", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await writeFile(path.join(rootDir, "tests", "shard.spec.ts"), "export const shard = true;\n");
  const reporter = new ZenoPlaywrightReporter(reporterOptions("evidence"));
  const testCase = apiTest(rootDir, {
    id: "shard-test",
    location: { file: path.join(rootDir, "tests", "shard.spec.ts"), line: 1, column: 1 },
  });
  reporter.onBegin(apiConfig(rootDir, { shard: { current: 2, total: 3 } }), {
    allTests: () => [testCase],
  });
  reporter.onTestEnd(testCase, apiResult());
  assert.equal(await reporter.onEnd(apiFullResult()), undefined);
  const expectedOutput = path.join(rootDir, "evidence", "shard-2-of-3");
  const manifest = JSON.parse(await readFile(path.join(expectedOutput, "evidence.json"), "utf8"));
  assert.deepEqual(manifest.extensions["dev.playwright.run"], {
    shard: { current: 2, total: 3 },
  });
});

test("Windows roots use win32 containment before POSIX serialization", { concurrency: false }, async (t) => {
  if (process.platform === "win32") {
    t.skip("cross-platform win32 lexical-path exercise uses POSIX literal filenames");
    return;
  }
  const tempRoot = await workspace(t);
  const originalCwd = process.cwd();
  const windowsRoot = String.raw`C:\workspace`;
  const windowsFile = String.raw`C:\workspace\tests\win.spec.ts`;
  process.chdir(tempRoot);
  try {
    await writeFile(windowsFile, "export const windows = true;\n");
    const reporter = new ZenoPlaywrightReporter(reporterOptions("evidence"));
    const testCase = apiTest(windowsRoot, {
      id: "windows-test",
      location: { file: windowsFile, line: 4, column: 2 },
    });
    reporter.onBegin(apiConfig(windowsRoot), { allTests: () => [testCase] });
    reporter.onTestEnd(testCase, apiResult());
    assert.equal(await reporter.onEnd(apiFullResult()), undefined);
    const manifestPath = path.join(tempRoot, String.raw`C:\workspace\evidence`, "evidence.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    assert.equal(
      manifest.items[0].extensions["dev.playwright.test"].location.relativeFile,
      "tests/win.spec.ts",
    );
    assert.doesNotMatch(JSON.stringify(manifest), /C:\\workspace/);

    const invalidFiles = [
      String.raw`D:\workspace\tests\win.spec.ts`,
      String.raw`C:\workspace-other\tests\win.spec.ts`,
      String.raw`C:\workspace\..\escape.spec.ts`,
    ];
    const originalWrite = process.stderr.write;
    process.stderr.write = () => true;
    try {
      for (let index = 0; index < invalidFiles.length; index += 1) {
        const invalidReporter = new ZenoPlaywrightReporter(reporterOptions(`invalid-${index}`));
        const invalidTest = apiTest(windowsRoot, {
          id: `invalid-windows-${index}`,
          location: { file: invalidFiles[index], line: 1, column: 1 },
        });
        invalidReporter.onBegin(apiConfig(windowsRoot), { allTests: () => [invalidTest] });
        invalidReporter.onTestEnd(invalidTest, apiResult());
        assert.deepEqual(await invalidReporter.onEnd(apiFullResult()), { status: "failed" });
      }
    } finally {
      process.stderr.write = originalWrite;
    }
  } finally {
    process.chdir(originalCwd);
  }
});

test("attachments without a public path or Buffer body are ignored, while undocumented bodies fail closed", async (t) => {
  const ignored = await runPassedLifecycle(t, {
    result: {
      attachments: [{ name: "metadata-only", contentType: "text/plain" }],
    },
  });
  assert.equal(await ignored.reporter.onEnd(apiFullResult()), undefined);
  const ignoredManifest = JSON.parse(await readFile(path.join(ignored.outputDir, "evidence.json"), "utf8"));
  assert.deepEqual(ignoredManifest.items[0].artifacts, []);

  const undocumented = await runPassedLifecycle(t, {
    options: { outputDir: path.join(ignored.rootDir, "undocumented") },
    result: {
      attachments: [{
        name: "typed-array",
        contentType: "application/octet-stream",
        body: new Uint8Array([1, 2, 3]),
      }],
    },
  });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await undocumented.reporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
});

test("browser identity is never inferred from projectName", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await writeFile(path.join(rootDir, "tests", "browser.spec.ts"), "export const browser = true;\n");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, "evidence"), {
    browserName: undefined,
    browserVersion: undefined,
  }));
  const testCase = apiTest(rootDir, {
    parent: { project: () => ({ name: "chromium-126", metadata: {} }) },
    location: { file: path.join(rootDir, "tests", "browser.spec.ts"), line: 1, column: 1 },
  });
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult());
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
});

test("an invalid output path fails without writing an error file into config.rootDir", async (t) => {
  const rootDir = await workspace(t);
  const reporter = new ZenoPlaywrightReporter(reporterOptions("", { outputDir: "" }));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
  await assert.rejects(readFile(path.join(rootDir, "evidence-error.json")));
});

test("a closed stderr cannot swallow the failed status override", async (t) => {
  const rootDir = await workspace(t);
  const reporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, "evidence"), {
    projectId: " invalid",
  }));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => {
    throw new Error("stderr closed");
  };
  try {
    assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
});

test("failure marker refuses a symlinked output directory leaf", async (t) => {
  const rootDir = await workspace(t);
  const outsideRoot = await workspace(t);
  const outputDir = path.join(rootDir, "linked-evidence");
  await symlink(outsideRoot, outputDir, "dir");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, {
    projectId: " invalid",
  }));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
  await assert.rejects(readFile(path.join(outsideRoot, "evidence-error.json")));
});

test("failure marker refuses a symlinked intermediate output directory", async (t) => {
  const rootDir = await workspace(t);
  const outsideRoot = await workspace(t);
  const linkedParent = path.join(rootDir, "linked-parent");
  const outputDir = path.join(linkedParent, "nested", "evidence");
  await symlink(outsideRoot, linkedParent, "dir");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, {
    projectId: " invalid",
  }));
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
  await assert.rejects(readFile(path.join(outsideRoot, "nested", "evidence", "evidence-error.json")));
});

test("failure marker preserves existing regular and symlink leaf entries", async (t) => {
  const rootDir = await workspace(t);
  const regularOutput = path.join(rootDir, "regular-output");
  const linkedOutput = path.join(rootDir, "linked-output");
  await mkdir(regularOutput);
  await mkdir(linkedOutput);
  const markerName = "evidence-error.json";
  const regularMarker = path.join(regularOutput, markerName);
  const linkedMarker = path.join(linkedOutput, markerName);
  const outsideSentinel = path.join(rootDir, "outside-sentinel.json");
  await writeFile(regularMarker, "preserve regular marker\n");
  await writeFile(outsideSentinel, "preserve symlink target\n");
  await symlink(outsideSentinel, linkedMarker, "file");

  for (const outputDir of [regularOutput, linkedOutput]) {
    const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, {
      projectId: " invalid",
    }));
    reporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
    const originalWrite = process.stderr.write;
    process.stderr.write = () => true;
    try {
      assert.deepEqual(await reporter.onEnd(apiFullResult()), { status: "failed" });
    } finally {
      process.stderr.write = originalWrite;
    }
  }

  assert.equal(await readFile(regularMarker, "utf8"), "preserve regular marker\n");
  assert.equal(await readFile(outsideSentinel, "utf8"), "preserve symlink target\n");
  assert.equal((await lstat(linkedMarker)).isSymbolicLink(), true);
});

test("constructor snapshots supported own options and journeyMap before caller mutation", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await mkdir(path.join(rootDir, "dist"), { recursive: true });
  await mkdir(path.join(rootDir, "captured-artifacts"), { recursive: true });
  await mkdir(path.join(rootDir, "mutated-artifacts"), { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "auth.spec.ts");
  const buildPath = path.join(rootDir, "dist", "captured.json");
  const mutatedBuildPath = path.join(rootDir, "dist", "mutated.json");
  const attachmentPath = path.join(rootDir, "captured-artifacts", "result.txt");
  await writeFile(sourcePath, "export const captured = true;\n");
  await writeFile(buildPath, "captured build\n");
  await writeFile(mutatedBuildPath, "mutated build\n");
  await writeFile(attachmentPath, "captured attachment\n");
  const key = playwrightJourneyKey({
    projectName: "chromium",
    relativeFile: "tests/auth.spec.ts",
    titlePath: ["auth", "user can sign in"],
  });
  const journeyMap = Object.assign(Object.create(null), { [key]: "captured-journey" });
  const options = Object.assign(Object.create(null), reporterOptions("captured-evidence", {
    artifactRoot: "captured-artifacts",
    browserName: "captured-browser",
    browserVersion: "126.0",
    journeyMap,
  }));
  delete options.buildManifestDigest;
  options.buildManifestPath = "dist/captured.json";
  const reporter = new ZenoPlaywrightReporter(options);

  options.outputDir = "mutated-evidence";
  options.projectId = "mutated-project";
  options.submitterId = "mutated-submitter";
  options.releaseId = "mutated-release";
  options.commitSha = "2".repeat(40);
  options.deploymentId = "mutated-deployment";
  options.environment = "mutated-environment";
  options.configDigest = `sha256:${"e".repeat(64)}`;
  options.buildManifestPath = "dist/mutated.json";
  options.artifactRoot = "mutated-artifacts";
  options.browserName = "mutated-browser";
  options.browserVersion = "999.0";
  options.journeyMap = {};
  journeyMap[key] = "mutated-journey";

  const testCase = apiTest(rootDir);
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult({
    attachments: [{ name: "result", contentType: "text/plain", path: attachmentPath }],
  }));
  assert.equal(await reporter.onEnd(apiFullResult()), undefined);
  const capturedPath = path.join(rootDir, "captured-evidence", "evidence.json");
  const manifest = JSON.parse(await readFile(capturedPath, "utf8"));
  assert.equal(manifest.project.externalId, "web-project-42");
  assert.equal(manifest.submission.externalId, "web-ci");
  assert.equal(manifest.release.externalId, "release-web-42");
  assert.equal(manifest.release.commitSha, COMMIT_SHA);
  assert.equal(manifest.target.deploymentId, "deployment-42");
  assert.equal(manifest.target.environment, "staging");
  assert.equal(manifest.target.configDigest, DIGEST_D);
  assert.equal(manifest.target.buildManifestDigest, sha256Bytes(Buffer.from("captured build\n")));
  assert.equal(manifest.items[0].journeyId, "captured-journey");
  assert.deepEqual(manifest.items[0].execution, {
    kind: "browser",
    browserName: "captured-browser",
    browserVersion: "126.0",
  });
  assert.equal(manifest.items[0].artifacts.length, 1);
  await assert.rejects(readFile(path.join(rootDir, "mutated-evidence", "evidence.json")));
});

test("the known Playwright configDir transport option remains compatible", async (t) => {
  const rootDir = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  await writeFile(path.join(rootDir, "tests", "auth.spec.ts"), "export const login = true;\n");
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, {
    configDir: rootDir,
  }));
  const testCase = apiTest(rootDir);
  reporter.onBegin(apiConfig(rootDir), { allTests: () => [testCase] });
  reporter.onTestEnd(testCase, apiResult());
  assert.equal(await reporter.onEnd(apiFullResult()), undefined);
  assert.equal(
    (await validateEvidencePackage(path.join(outputDir, "evidence.json"))).ok,
    true,
  );
});

test("constructor rejects accessors, unknown keys, non-plain options, and unsafe journey maps without invoking getters", async (t) => {
  const rootDir = await workspace(t);
  let optionGetterCalls = 0;
  const accessorOptions = reporterOptions(path.join(rootDir, "accessor"));
  Object.defineProperty(accessorOptions, "projectId", {
    enumerable: true,
    get() {
      optionGetterCalls += 1;
      throw new Error("must not invoke option getter");
    },
  });
  let accessorReporter;
  assert.doesNotThrow(() => {
    accessorReporter = new ZenoPlaywrightReporter(accessorOptions);
  });
  assert.equal(optionGetterCalls, 0);
  accessorReporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
  const originalWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.deepEqual(await accessorReporter.onEnd(apiFullResult()), { status: "failed" });
    assert.equal(optionGetterCalls, 0);

    let mapGetterCalls = 0;
    const journeyMap = {};
    Object.defineProperty(journeyMap, "unsafe", {
      enumerable: true,
      get() {
        mapGetterCalls += 1;
        throw new Error("must not invoke map getter");
      },
    });
    const mapReporter = new ZenoPlaywrightReporter(reporterOptions(path.join(rootDir, "map"), {
      journeyMap,
    }));
    mapReporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
    assert.deepEqual(await mapReporter.onEnd(apiFullResult()), { status: "failed" });
    assert.equal(mapGetterCalls, 0);

    const unknownReporter = new ZenoPlaywrightReporter({
      ...reporterOptions(path.join(rootDir, "unknown")),
      unexpected: "value",
    });
    unknownReporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
    assert.deepEqual(await unknownReporter.onEnd(apiFullResult()), { status: "failed" });

    const symbolOptions = reporterOptions(path.join(rootDir, "symbol-option"));
    Object.defineProperty(symbolOptions, Symbol("unexpected"), { value: "value" });
    const symbolReporter = new ZenoPlaywrightReporter(symbolOptions);
    symbolReporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
    assert.deepEqual(await symbolReporter.onEnd(apiFullResult()), { status: "failed" });

    class ReporterOptions {}
    const classOptions = Object.assign(
      new ReporterOptions(),
      reporterOptions(path.join(rootDir, "class-options")),
    );
    const classReporter = new ZenoPlaywrightReporter(classOptions);
    classReporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
    assert.deepEqual(await classReporter.onEnd(apiFullResult()), { status: "failed" });

    const prototypedMap = Object.create({ inherited: "journey" });
    const prototypeReporter = new ZenoPlaywrightReporter(reporterOptions(
      path.join(rootDir, "prototype-map"),
      { journeyMap: prototypedMap },
    ));
    prototypeReporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
    assert.deepEqual(await prototypeReporter.onEnd(apiFullResult()), { status: "failed" });

    const unsafeMap = Object.create(null);
    Object.defineProperty(unsafeMap, "__proto__", {
      enumerable: true,
      value: "journey-unsafe",
    });
    const unsafeMapReporter = new ZenoPlaywrightReporter(reporterOptions(
      path.join(rootDir, "unsafe-map"),
      { journeyMap: unsafeMap },
    ));
    unsafeMapReporter.onBegin(apiConfig(rootDir), { allTests: () => [] });
    assert.deepEqual(await unsafeMapReporter.onEnd(apiFullResult()), { status: "failed" });
  } finally {
    process.stderr.write = originalWrite;
  }
});

test("onBegin, onTestEnd, and onEnd snapshot public lifecycle values before caller mutation", async (t) => {
  const rootDir = await workspace(t);
  const otherRoot = await workspace(t);
  await mkdir(path.join(rootDir, "tests"), { recursive: true });
  const sourcePath = path.join(rootDir, "tests", "snapshot.spec.ts");
  await writeFile(sourcePath, "export const snapshot = true;\n");
  const outputDir = path.join(rootDir, "evidence");
  const reporter = new ZenoPlaywrightReporter(reporterOptions(outputDir, {
    browserName: undefined,
    browserVersion: undefined,
  }));
  const project = {
    name: "captured-project",
    metadata: { zenoEvidence: { browserName: "captured-browser", browserVersion: "126.0" } },
  };
  const location = { file: sourcePath, line: 7, column: 3 };
  const annotations = [{ type: "zeno:journey", description: "captured-journey" }];
  const titlePath = ["suite", "captured title"];
  const testCase = {
    id: "captured-test-id",
    title: "captured title",
    titlePath: () => titlePath,
    location,
    expectedStatus: "passed",
    annotations,
    outcome: () => "flaky",
    parent: { project: () => project },
  };
  const body = Buffer.from("captured body", "utf8");
  const attachment = { name: "captured", contentType: "text/plain", body };
  const result = {
    retry: 1,
    status: "passed",
    startTime: new Date("2026-07-13T10:00:00.500Z"),
    duration: 1000,
    error: undefined,
    attachments: [attachment],
  };
  const config = apiConfig(rootDir, { version: "1.42.0" });
  reporter.onBegin(config, { allTests: () => [testCase] });
  config.rootDir = otherRoot;
  config.version = "mutated-version";
  config.shard = { current: 9, total: 9 };
  reporter.onTestEnd(testCase, result);

  testCase.id = "mutated-test-id";
  testCase.title = "mutated title";
  testCase.titlePath = () => ["mutated", "title"];
  location.file = path.join(otherRoot, "missing.spec.ts");
  location.line = 99;
  location.column = 99;
  annotations[0].description = "mutated-journey";
  testCase.expectedStatus = "failed";
  testCase.outcome = () => "unexpected";
  project.name = "mutated-project";
  project.metadata.zenoEvidence.browserName = "mutated-browser";
  project.metadata.zenoEvidence.browserVersion = "999.0";
  result.retry = 9;
  result.status = "failed";
  result.startTime = new Date("2026-07-13T10:00:10.000Z");
  result.duration = 9999;
  result.error = { message: "mutated error" };
  attachment.name = "mutated";
  attachment.contentType = "application/zip";
  attachment.body = Buffer.from("mutated replacement");
  body.fill(0x78);
  result.attachments = [];

  const fullResult = apiFullResult({
    status: "passed",
    startTime: new Date("2026-07-13T10:00:00.000Z"),
    duration: 2000,
  });
  const completion = reporter.onEnd(fullResult);
  fullResult.status = "interrupted";
  fullResult.startTime = new Date("2027-01-01T00:00:00.000Z");
  fullResult.duration = 1;
  assert.equal(await completion, undefined);

  const validation = await validateEvidencePackage(path.join(outputDir, "evidence.json"));
  const manifest = validation.manifest;
  const item = manifest.items[0];
  const extension = item.extensions["dev.playwright.test"];
  const capturedDigest = sha256Bytes(Buffer.from("captured-test-id"));
  assert.equal(manifest.producer.version, "1.42.0");
  assert.equal(manifest.run.outcome, "passed");
  assert.equal(manifest.run.startedAt, "2026-07-13T10:00:00.000Z");
  assert.equal(manifest.run.endedAt, "2026-07-13T10:00:02.000Z");
  assert.equal(item.externalId, `playwright:${capturedDigest.slice("sha256:".length)}`);
  assert.equal(extension.sourceTestIdDigest, capturedDigest);
  assert.deepEqual(extension.titlePath, ["suite", "captured title"]);
  assert.deepEqual(extension.location, { relativeFile: "tests/snapshot.spec.ts", line: 7, column: 3 });
  assert.equal(extension.projectName, "captured-project");
  assert.equal(extension.expectedStatus, "passed");
  assert.equal(extension.aggregateOutcome, "flaky");
  assert.equal(item.journeyId, "captured-journey");
  assert.equal(item.attempt, 1);
  assert.equal(item.outcome, "passed");
  assert.equal(item.startedAt, "2026-07-13T10:00:00.500Z");
  assert.equal(item.endedAt, "2026-07-13T10:00:01.500Z");
  assert.deepEqual(item.execution, {
    kind: "browser",
    browserName: "captured-browser",
    browserVersion: "126.0",
  });
  assert.equal(item.artifacts.length, 1);
  assert.equal(
    await readFile(path.join(outputDir, item.artifacts[0].path), "utf8"),
    "captured body",
  );
  assert.doesNotMatch(JSON.stringify(manifest), /mutated/);
});
