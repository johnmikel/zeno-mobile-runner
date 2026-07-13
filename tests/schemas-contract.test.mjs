import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repositoryRoot = new URL("../", import.meta.url);

function readSchema(name) {
  return JSON.parse(
    readFileSync(new URL("schemas/" + name, repositoryRoot), "utf8"),
  );
}

const runSummarySchema = readSchema("run-summary.schema.json");
const bootstrapEventSchema = readSchema("bootstrap-event.schema.json");
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validateRunSummary = ajv.compile(runSummarySchema);
const validateBootstrapEvent = ajv.compile(bootstrapEventSchema);

function expectValid(validate, value, label) {
  assert.equal(
    validate(value),
    true,
    label + ": " + JSON.stringify(validate.errors, null, 2),
  );
}

function expectInvalid(validate, value, label) {
  assert.equal(validate(value), false, label + ": unexpectedly valid");
}

function validRunSummary() {
  return {
    schemaVersion: 1,
    runId: "ios-smoke-1-attempt-1",
    executionId: "ios-smoke-1",
    fixtureId: "generated-ios-demo",
    fixtureVersion: "1",
    candidateRevision: "a".repeat(40),
    scenarioDigest: "sha256:" + "b".repeat(64),
    appBuildDigest: "sha256:" + "c".repeat(64),
    comparabilityKey: "sha256:" + "d".repeat(64),
    certificationEligible: true,
    ineligibilityReasons: [],
    status: "passed",
    classification: "passed",
    phase: "complete",
    startedAt: "2026-07-11T10:00:00Z",
    finishedAt: "2026-07-11T10:00:05Z",
    durationMs: 5000,
    attempt: 1,
    firstAttempt: true,
    platform: "ios",
    deviceClass: "ios-simulator",
    runtimeVersion: "18.5",
    timingMode: "cold-command",
    runnerVersion: "0.2.17",
    protocolVersion: "2026-04-28",
    commandStatus: 0,
    host: {
      os: "macos",
      arch: "arm64",
      class: "github-macos-15-arm64",
      ci: true,
    },
    device: {
      requested: "booted",
      resolved: "simulator-udid",
    },
    toolchain: {
      xcode: "16.4",
      zig: "0.16.0",
    },
    artifacts: {
      bootstrapEvents: "bootstrap-events.jsonl",
      commands: "commands",
      trace: null,
      report: "reports/run.html",
    },
    ciJobId: "device-smoke-ios",
  };
}

function validBootstrapEvent() {
  return {
    schemaVersion: 1,
    seq: 1,
    timestamp: "2026-07-11T10:00:00Z",
    phase: "invocation",
    status: "started",
    artifact: null,
  };
}

const invalidArtifactPaths = [
  "/abs",
  "../x",
  "a/../../x",
  "..\\..\\x",
  "C:..\\x",
  "C:/x",
  "file:///tmp/x",
  "https://example.test/x",
  "artifact:commands/x",
  "./x",
  ".",
  "..",
  "a/./x",
  "a/../x",
  "a//b",
  "a\\\\b",
];

test("schemas compile strictly as draft 2020-12 with date-time formats", () => {
  assert.equal(
    runSummarySchema.$schema,
    "https://json-schema.org/draft/2020-12/schema",
  );
  assert.equal(
    bootstrapEventSchema.$schema,
    "https://json-schema.org/draft/2020-12/schema",
  );
  assert.equal(typeof validateRunSummary, "function");
  assert.equal(typeof validateBootstrapEvent, "function");
});

test("run summary bounds the public run id component", () => {
  const exact = validRunSummary();
  exact.runId = "r".repeat(128);
  expectValid(validateRunSummary, exact, "128-character run id");

  const oversized = validRunSummary();
  oversized.runId = "r".repeat(129);
  expectInvalid(validateRunSummary, oversized, "129-character run id");

  for (const runId of [".", "..", "unsafe/run", "unsafe\\run", "x\u001fy", "file:run"]) {
    const unsafe = validRunSummary();
    unsafe.runId = runId;
    expectInvalid(validateRunSummary, unsafe, "unsafe run id " + JSON.stringify(runId));
  }
});

test("run summary accepts each terminal status contract", () => {
  expectValid(validateRunSummary, validRunSummary(), "passed summary");

  const failed = validRunSummary();
  Object.assign(failed, {
    status: "failed",
    classification: "runner_failure",
    phase: "shim.prewarm",
    errorCode: "runner.ios_shim.readiness_timeout",
    summary: "Shim readiness timed out",
    hint: "Inspect the shim command log",
    commandStatus: null,
  });
  expectValid(validateRunSummary, failed, "failed summary");

  const cancelled = validRunSummary();
  Object.assign(cancelled, {
    status: "cancelled",
    classification: "cancelled",
    phase: "cleanup",
    errorCode: "run.cancelled",
    summary: "Run cancelled by request",
    hint: "Retry when ready",
    commandStatus: null,
  });
  expectValid(validateRunSummary, cancelled, "cancelled summary");
});

test("failed summary classification owns an exact stable error-code enum", () => {
  const ownedCodes = {
    runner_failure: [
      "runner.unclassified",
      "runner.child_timeout",
      "runner.command_supervisor_lost",
      "runner.capture_failed",
      "runner.cleanup_failed",
      "runner.driver_protocol",
      "runner.ios_shim.build_failed",
      "runner.ios_shim.readiness_timeout",
      "runner.trace_failed",
      "runner.report_failed",
      "runner.evidence_invalid",
    ],
    configuration_failure: [
      "config.invalid",
      "config.app_artifact_missing",
      "config.device_selection",
      "config.signing",
      "config.unsupported_capability",
      "config.required_tool_missing",
    ],
    infrastructure_failure: [
      "infra.hosted_runner",
      "infra.device_unavailable",
      "infra.emulator_provision",
      "infra.simulator_provision",
      "infra.disk",
      "infra.network",
    ],
    app_failure: [
      "app.assertion_failed",
      "app.crashed",
      "app.launch_failed",
    ],
  };

  for (const [classification, codes] of Object.entries(ownedCodes)) {
    for (const errorCode of codes) {
      const summary = validRunSummary();
      Object.assign(summary, {
        status: "failed",
        classification,
        phase: "scenario.execute",
        errorCode,
        summary: "Classified failure",
        hint: "Inspect evidence",
        commandStatus: null,
      });
      expectValid(validateRunSummary, summary, classification + "/" + errorCode);
    }
  }

  const unknown = validRunSummary();
  Object.assign(unknown, {
    status: "failed",
    classification: "runner_failure",
    phase: "scenario.execute",
    errorCode: "unknown.failure",
    summary: "Unknown failure",
    hint: "Inspect evidence",
  });
  expectInvalid(validateRunSummary, unknown, "unknown failed error code");

  const mismatched = validRunSummary();
  Object.assign(mismatched, {
    status: "failed",
    classification: "infrastructure_failure",
    phase: "scenario.execute",
    errorCode: "app.assertion_failed",
    summary: "Mismatched failure",
    hint: "Inspect evidence",
  });
  expectInvalid(validateRunSummary, mismatched, "mismatched failure owner");
});

test("run summary rejects terminal status contract mismatches", () => {
  const passedWithFailure = validRunSummary();
  Object.assign(passedWithFailure, {
    errorCode: "runner.unclassified",
    summary: "Unexpected",
    hint: "Inspect logs",
  });
  expectInvalid(
    validateRunSummary,
    passedWithFailure,
    "passed summary with failure fields",
  );

  const passedAtWrongPhase = validRunSummary();
  passedAtWrongPhase.phase = "cleanup";
  expectInvalid(
    validateRunSummary,
    passedAtWrongPhase,
    "passed summary at non-complete phase",
  );

  const failedAsPassed = validRunSummary();
  Object.assign(failedAsPassed, {
    status: "failed",
    classification: "passed",
    errorCode: "runner.unclassified",
    summary: "Unexpected",
    hint: "Inspect logs",
  });
  expectInvalid(
    validateRunSummary,
    failedAsPassed,
    "failed summary with passed classification",
  );

  const failedWithoutHint = validRunSummary();
  Object.assign(failedWithoutHint, {
    status: "failed",
    classification: "runner_failure",
    errorCode: "runner.unclassified",
    summary: "Unexpected",
  });
  expectInvalid(
    validateRunSummary,
    failedWithoutHint,
    "failed summary without hint",
  );

  const cancelledWithWrongCode = validRunSummary();
  Object.assign(cancelledWithWrongCode, {
    status: "cancelled",
    classification: "cancelled",
    errorCode: "runner.unclassified",
    summary: "Cancelled",
    hint: "Retry",
  });
  expectInvalid(
    validateRunSummary,
    cancelledWithWrongCode,
    "cancelled summary with non-cancellation code",
  );
});

test("firstAttempt exactly reflects whether attempt is one", () => {
  const first = validRunSummary();
  expectValid(validateRunSummary, first, "first attempt");

  first.firstAttempt = false;
  expectInvalid(validateRunSummary, first, "attempt one marked non-first");

  const retry = validRunSummary();
  retry.attempt = 2;
  retry.firstAttempt = false;
  expectValid(validateRunSummary, retry, "retry");

  retry.firstAttempt = true;
  expectInvalid(validateRunSummary, retry, "retry marked first");
});

test("run summary rejects malformed provenance values", () => {
  const malformedValues = [
    ["candidateRevision", "a".repeat(39)],
    ["candidateRevision", "A".repeat(40)],
    ["candidateRevision", "g".repeat(40)],
    ["scenarioDigest", "sha256:" + "b".repeat(63)],
    ["scenarioDigest", "sha256:" + "B".repeat(64)],
    ["scenarioDigest", "md5:" + "b".repeat(64)],
    ["appBuildDigest", "sha256:" + "c".repeat(65)],
    ["appBuildDigest", "sha256:" + "z".repeat(64)],
  ];

  for (const [field, value] of malformedValues) {
    const summary = validRunSummary();
    summary[field] = value;
    expectInvalid(validateRunSummary, summary, field + "=" + value);
  }
});

test("approved provenance fields remain nullable but make rows ineligible", () => {
  for (const field of [
    "candidateRevision",
    "scenarioDigest",
    "appBuildDigest",
  ]) {
    const summary = validRunSummary();
    summary[field] = null;
    summary.comparabilityKey = null;
    summary.certificationEligible = false;
    summary.ineligibilityReasons = ["$." + field];
    expectValid(validateRunSummary, summary, "null " + field);
  }
});

test("comparability completeness controls key and eligibility", () => {
  const completeButIneligible = validRunSummary();
  completeButIneligible.comparabilityKey = null;
  completeButIneligible.certificationEligible = false;
  completeButIneligible.ineligibilityReasons = ["$.candidateRevision"];
  expectInvalid(
    validateRunSummary,
    completeButIneligible,
    "complete tuple marked ineligible",
  );

  const missingBuild = validRunSummary();
  missingBuild.appBuildDigest = null;
  expectInvalid(
    validateRunSummary,
    missingBuild,
    "incomplete tuple marked eligible",
  );

  missingBuild.comparabilityKey = null;
  missingBuild.certificationEligible = false;
  missingBuild.ineligibilityReasons = ["$.appBuildDigest"];
  expectValid(validateRunSummary, missingBuild, "incomplete tuple");

  const missingToolchainVersion = validRunSummary();
  missingToolchainVersion.toolchain.zig = null;
  missingToolchainVersion.comparabilityKey = null;
  missingToolchainVersion.certificationEligible = false;
  missingToolchainVersion.ineligibilityReasons = ["$.toolchain.zig"];
  expectValid(
    validateRunSummary,
    missingToolchainVersion,
    "incomplete toolchain tuple",
  );

  missingToolchainVersion.ineligibilityReasons = [];
  expectInvalid(
    validateRunSummary,
    missingToolchainVersion,
    "incomplete tuple without reason",
  );
});

test("both schemas publish one equivalent normalized relative-path pattern", () => {
  const runPattern = runSummarySchema.$defs?.relativePath?.pattern;
  const bootstrapPattern = bootstrapEventSchema.$defs?.relativePath?.pattern;
  assert.equal(typeof runPattern, "string");
  assert.equal(bootstrapPattern, runPattern);
});

test("run summary rejects artifact paths that are absolute or non-normalized", () => {
  for (const field of ["bootstrapEvents", "commands", "trace", "report"]) {
    for (const path of invalidArtifactPaths) {
      const summary = validRunSummary();
      summary.artifacts[field] = path;
      expectInvalid(validateRunSummary, summary, field + "=" + path);
    }
  }
});

test("run summary accepts normalized paths and optional nullable links", () => {
  const summary = validRunSummary();
  summary.artifacts = {
    bootstrapEvents: "events/bootstrap-events.jsonl",
    commands: "commands/attempt-1",
    trace: null,
  };
  expectValid(validateRunSummary, summary, "normalized paths without report");

  summary.artifacts.trace = "trace/trace.json";
  summary.artifacts.report = null;
  expectValid(validateRunSummary, summary, "normalized paths with null report");
});

test("bootstrap event artifact uses the normalized relative-path contract", () => {
  const withoutArtifact = validBootstrapEvent();
  delete withoutArtifact.artifact;
  expectValid(validateBootstrapEvent, withoutArtifact, "omitted artifact");

  const nullableArtifact = validBootstrapEvent();
  expectValid(validateBootstrapEvent, nullableArtifact, "null artifact");

  const relativeArtifact = validBootstrapEvent();
  relativeArtifact.artifact = "commands/invocation/stdout.log";
  expectValid(validateBootstrapEvent, relativeArtifact, "relative artifact");

  for (const path of invalidArtifactPaths) {
    const event = validBootstrapEvent();
    event.artifact = path;
    expectInvalid(validateBootstrapEvent, event, "artifact=" + path);
  }
});

test("date-time fields reject malformed timestamps", () => {
  const summary = validRunSummary();
  summary.startedAt = "not-a-date";
  expectInvalid(validateRunSummary, summary, "invalid summary timestamp");

  const event = validBootstrapEvent();
  event.timestamp = "not-a-date";
  expectInvalid(validateBootstrapEvent, event, "invalid event timestamp");
});
