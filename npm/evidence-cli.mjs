#!/usr/bin/env node

import { resolve } from "node:path";

import { EvidenceValidationError } from "./evidence/canonical-json.mjs";
import {
  validateEvidencePackage,
  writeEvidencePackage,
} from "./evidence/package-writer.mjs";
import { adaptZmrTrace } from "./evidence/zmr-adapter.mjs";

let intendedSemanticExitCode = 0;
let terminatingForStreamError = false;

function setIntendedSemanticExitCode(code) {
  intendedSemanticExitCode = code;
  process.exitCode = code;
}

function terminateForStreamError(error) {
  if (terminatingForStreamError) return;
  terminatingForStreamError = true;
  process.exit(error?.code === "EPIPE" ? intendedSemanticExitCode : 1);
}

process.stdout.on("error", terminateForStreamError);
process.stderr.on("error", terminateForStreamError);

function writeStream(stream, output) {
  try {
    stream.write(output);
  } catch (error) {
    terminateForStreamError(error);
  }
}

function writeSuccess(output) {
  setIntendedSemanticExitCode(0);
  writeStream(process.stdout, output);
}

const USAGE = `Usage: zmr-evidence <command> [options]

Commands:
  from-zmr   Convert a Zeno Mobile Runner trace into an evidence package
  validate   Validate evidence.json and its sibling artifact bytes
  help       Show this help`;

class CliUsageError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "CliUsageError";
    this.code = code;
  }
}

const FROM_ZMR_OPTIONS = new Map([
  ["--trace", "tracePath"],
  ["--scenario", "scenarioPath"],
  ["--scenario-hash", "scenarioHash"],
  ["--project-id", "projectId"],
  ["--submitter-type", "submitterType"],
  ["--submitter-id", "submitterId"],
  ["--release-id", "releaseId"],
  ["--commit-sha", "commitSha"],
  ["--surface", "surface"],
  ["--app-artifact", "appArtifactPath"],
  ["--app-id", "appId"],
  ["--app-version", "appVersion"],
  ["--build-number", "buildNumber"],
  ["--environment", "environment"],
  ["--journey-id", "journeyId"],
  ["--item-id", "itemId"],
  ["--run-id", "runId"],
  ["--device-name", "deviceName"],
  ["--os-name", "osName"],
  ["--os-version", "osVersion"],
  ["--out", "destination"],
]);

const REQUIRED_FROM_ZMR_OPTIONS = [
  "--trace",
  "--project-id",
  "--submitter-type",
  "--submitter-id",
  "--release-id",
  "--commit-sha",
  "--surface",
  "--app-artifact",
  "--app-id",
  "--app-version",
  "--build-number",
  "--environment",
  "--journey-id",
  "--item-id",
  "--run-id",
  "--device-name",
  "--os-name",
  "--os-version",
  "--out",
];

const SAFE_EVIDENCE_MESSAGES = new Map([
  ["artifact_digest_mismatch", "Packaged artifact digest does not match its descriptor"],
  ["artifact_missing", "Packaged artifact is missing"],
  ["artifact_size_mismatch", "Packaged artifact size does not match its descriptor"],
  ["destination_exists", "Evidence package destination already exists"],
  ["invalid_evidence_json", "Evidence manifest is not valid JSON"],
  ["invalid_evidence_manifest", "Evidence manifest is invalid"],
  ["invalid_evidence_package", "Evidence package is invalid"],
  ["invalid_adapter_options", "Evidence adapter options are invalid"],
  ["invalid_identity", "Evidence identity is invalid"],
  ["invalid_scenario_identity", "Evidence scenario identity is invalid"],
  ["invalid_source_path", "Evidence source is unavailable or unreadable"],
  ["source_changed_during_read", "Evidence source changed while it was read"],
  ["source_file_too_large", "Evidence source exceeds its size limit"],
  ["source_not_directory", "Evidence source must be a directory"],
  ["source_not_regular_file", "Evidence source must be a regular file"],
  ["symlink_source_rejected", "Evidence source path contains a symbolic link"],
]);

// Fixed hint, never interpolated with a user path: on macOS /tmp is a symlink to
// /private/tmp, so the default scratch location fails the no-symlink rule.
const SYMLINK_HINT = "; on macOS /tmp is a symlink to /private/tmp, so pass the resolved path";

const SAFE_ADAPTER_FIELD_MESSAGES = new Map([
  ["invalid_adapter_options", new Map([
    ["tracePath", "--trace must be a non-empty path"],
    ["scenarioPath", "--scenario must be a non-empty path"],
    ["appArtifactPath", "--app-artifact must be a non-empty path"],
    ["submitterType", "--submitter-type must be user or automation"],
    ["surface", "--surface must be ios or android"],
  ])],
  ["invalid_identity", new Map([
    ["projectId", "--project-id must be 1 to 256 characters with no edge whitespace or controls"],
    ["submitterId", "--submitter-id must be 1 to 256 characters with no edge whitespace or controls"],
    ["releaseId", "--release-id must be 1 to 256 characters with no edge whitespace or controls"],
    ["commitSha", "--commit-sha must be 1 to 256 characters with no edge whitespace or controls"],
    ["appId", "--app-id must be 1 to 256 characters with no edge whitespace or controls"],
    ["appVersion", "--app-version must be 1 to 256 characters with no edge whitespace or controls"],
    ["buildNumber", "--build-number must be 1 to 256 characters with no edge whitespace or controls"],
    ["environment", "--environment must be 1 to 256 characters with no edge whitespace or controls"],
    ["journeyId", "--journey-id must be 1 to 256 characters with no edge whitespace or controls"],
    ["itemId", "--item-id must be 1 to 256 characters with no edge whitespace or controls"],
    ["runId", "--run-id must be 1 to 256 characters with no edge whitespace or controls"],
    ["deviceName", "--device-name must be 1 to 256 characters with no edge whitespace or controls"],
    ["osName", "--os-name must be 1 to 256 characters with no edge whitespace or controls"],
    ["osVersion", "--os-version must be 1 to 256 characters with no edge whitespace or controls"],
  ])],
  ["invalid_scenario_identity", new Map([
    ["scenarioHash", "--scenario-hash must be a SHA-256 digest"],
  ])],
  ["invalid_source_path", new Map([
    ["tracePath", "--trace is unavailable or unreadable"],
    ["appArtifactPath", "--app-artifact is unavailable or unreadable"],
    ["scenarioPath", "--scenario is unavailable or unreadable"],
  ])],
  ["symlink_source_rejected", new Map([
    ["tracePath", `--trace must not contain a symbolic link${SYMLINK_HINT}`],
    ["appArtifactPath", `--app-artifact must not contain a symbolic link${SYMLINK_HINT}`],
    ["scenarioPath", `--scenario must not contain a symbolic link${SYMLINK_HINT}`],
    ["trace.artifactsDir", "trace.artifactsDir must not contain a symbolic link"],
  ])],
  ["source_not_regular_file", new Map([
    ["tracePath", "--trace must be a trace directory or a regular .zmrtrace file"],
    ["appArtifactPath", "--app-artifact must be a regular file; zip an .app bundle or pass an .ipa"],
    ["scenarioPath", "--scenario must be a regular JSON file"],
  ])],
  ["source_not_directory", new Map([
    ["tracePath", "--trace must be a trace directory or a regular .zmrtrace file"],
    ["trace.artifactsDir", "trace.artifactsDir must be a directory"],
  ])],
  ["source_file_too_large", new Map([
    ["tracePath", "--trace exceeds the trace size limit"],
    ["scenarioPath", "--scenario exceeds the file-size limit"],
  ])],
  ["source_changed_during_read", new Map([
    ["tracePath", "--trace changed while it was read; keep it unmodified during packaging"],
    ["appArtifactPath", "--app-artifact changed while it was hashed; keep it unmodified during packaging"],
    ["scenarioPath", "--scenario changed while it was read; keep it unmodified during packaging"],
  ])],
]);

const SAFE_EVIDENCE_CODES = new Set([
  "evidence_validation_error",
  ...SAFE_EVIDENCE_MESSAGES.keys(),
]);

function safeEvidenceCode(error) {
  return typeof error.code === "string" && SAFE_EVIDENCE_CODES.has(error.code)
    ? error.code
    : "evidence_validation_error";
}

function safeAdapterFieldMessage(error, code) {
  if (typeof error.field !== "string" || error.field !== error.path) return undefined;
  return SAFE_ADAPTER_FIELD_MESSAGES.get(code)?.get(error.field);
}

function publicError(error) {
  if (error instanceof CliUsageError) {
    return {
      code: error.code,
      message: error.message,
      issues: [],
    };
  }
  if (error instanceof EvidenceValidationError) {
    const code = safeEvidenceCode(error);
    return {
      code,
      message: safeAdapterFieldMessage(error, code)
        ?? SAFE_EVIDENCE_MESSAGES.get(code)
        ?? "Evidence command failed",
      issues: [],
    };
  }
  return {
    code: "internal_error",
    message: "Unexpected evidence CLI failure",
    issues: [],
  };
}

function printHelp() {
  writeSuccess(`${USAGE}\n`);
}

function printError(error, exitCode) {
  setIntendedSemanticExitCode(exitCode);
  const payload = {
    ok: false,
    error: publicError(error),
  };
  writeStream(process.stderr, `${JSON.stringify(payload)}\n`);
  if (process.env.ZENO_EVIDENCE_DEBUG === "1") {
    const debugName = error instanceof CliUsageError
      ? "CliUsageError"
      : error instanceof EvidenceValidationError
        ? "EvidenceValidationError"
        : "Error";
    writeStream(
      process.stderr,
      `Debug stack:\n${debugName}: ${payload.error.message}\n    at zmr-evidence\n`,
    );
  }
}

function parseFromZmrOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--force") {
      if (Object.hasOwn(options, "force")) {
        throw new CliUsageError("duplicate_option", "--force may only be provided once");
      }
      options.force = true;
      continue;
    }
    const separator = argument.indexOf("=");
    const hasInlineValue = separator !== -1;
    const option = hasInlineValue ? argument.slice(0, separator) : argument;
    const property = FROM_ZMR_OPTIONS.get(option);
    if (property === undefined) {
      const code = typeof argument === "string" && argument.startsWith("-")
        ? "unknown_option"
        : "unexpected_argument";
      throw new CliUsageError(code, code === "unknown_option"
        ? "Unknown from-zmr option"
        : "from-zmr does not accept positional arguments");
    }
    if (Object.hasOwn(options, property)) {
      throw new CliUsageError("duplicate_option", `${option} may only be provided once`);
    }
    if (hasInlineValue) {
      options[property] = argument.slice(separator + 1);
      continue;
    }
    if (index + 1 >= args.length || args[index + 1].startsWith("--")) {
      throw new CliUsageError("missing_option_value", `${option} requires a value`);
    }
    options[property] = args[index + 1];
    index += 1;
  }

  for (const option of REQUIRED_FROM_ZMR_OPTIONS) {
    if (!Object.hasOwn(options, FROM_ZMR_OPTIONS.get(option))) {
      throw new CliUsageError("missing_option", `${option} is required`);
    }
  }
  const hasScenarioPath = Object.hasOwn(options, "scenarioPath");
  const hasScenarioHash = Object.hasOwn(options, "scenarioHash");
  if (!hasScenarioPath && !hasScenarioHash) {
    throw new CliUsageError(
      "missing_scenario_identity",
      "Exactly one of --scenario or --scenario-hash is required",
    );
  }
  if (hasScenarioPath && hasScenarioHash) {
    throw new CliUsageError(
      "conflicting_scenario_identity",
      "--scenario and --scenario-hash are mutually exclusive",
    );
  }
  return options;
}

async function runFromZmr(args) {
  const options = parseFromZmrOptions(args);
  const { destination, force = false, ...adapterOptions } = options;
  const { manifest, artifactInputs } = await adaptZmrTrace(adapterOptions);
  const written = await writeEvidencePackage({
    destination,
    manifest,
    artifactInputs,
    force,
  });
  const artifacts = written.manifest.items.reduce(
    (count, item) => count + item.artifacts.length,
    0,
  );
  writeSuccess(`${JSON.stringify({
    ok: true,
    command: "from-zmr",
    output: resolve(destination),
    manifestDigest: written.manifestDigest,
    items: written.manifest.items.length,
    artifacts,
  })}\n`);
}

async function runValidate(args) {
  if (args.length === 0 || (args[0] === "--" && args.length === 1)) {
    throw new CliUsageError("missing_manifest", "validate requires a path to evidence.json");
  }
  const terminated = args[0] === "--";
  const manifestPath = terminated ? args[1] : args[0];
  if (!terminated && manifestPath.startsWith("-")) {
    throw new CliUsageError("unknown_option", "Unknown validate option");
  }
  if (args.length !== (terminated ? 2 : 1)) {
    throw new CliUsageError("unexpected_argument", "validate accepts exactly one evidence.json path");
  }
  const validated = await validateEvidencePackage(manifestPath);
  const artifacts = validated.manifest.items.reduce(
    (count, item) => count + item.artifacts.length,
    0,
  );
  writeSuccess(`${JSON.stringify({
    ok: true,
    command: "validate",
    output: validated.manifestPath,
    manifestDigest: validated.manifestDigest,
    items: validated.manifest.items.length,
    artifacts,
  })}\n`);
}

async function main(args) {
  const command = args[0];
  if (command === "--help" || command === "-h" || command === "help") {
    printHelp();
    return;
  }
  if (command === undefined) {
    throw new CliUsageError("missing_command", USAGE);
  }
  if (command === "from-zmr") {
    if (args[1] === "--help" || args[1] === "-h") {
      printHelp();
      return;
    }
    await runFromZmr(args.slice(1));
    return;
  }
  if (command === "validate") {
    if (args[1] === "--help" || args[1] === "-h") {
      printHelp();
      return;
    }
    await runValidate(args.slice(1));
    return;
  }
  throw new CliUsageError("unknown_command", "Unknown command");
}

try {
  await main(process.argv.slice(2));
} catch (error) {
  printError(error, error instanceof CliUsageError ? 2 : 1);
}
