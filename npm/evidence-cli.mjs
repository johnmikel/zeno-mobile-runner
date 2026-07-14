#!/usr/bin/env node

import { resolve } from "node:path";

import { EvidenceValidationError } from "./evidence/canonical-json.mjs";
import {
  validateEvidencePackage,
  writeEvidencePackage,
} from "./evidence/package-writer.mjs";
import { adaptZmrTrace } from "./evidence/zmr-adapter.mjs";

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
]);

function safeEvidenceCode(error) {
  return typeof error.code === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(error.code)
    ? error.code
    : "evidence_validation_error";
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
      message: SAFE_EVIDENCE_MESSAGES.get(code) ?? `Evidence command failed (${code})`,
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
  process.stdout.write(`${USAGE}\n`);
}

function printError(error) {
  const payload = {
    ok: false,
    error: publicError(error),
  };
  process.stderr.write(`${JSON.stringify(payload)}\n`);
  if (process.env.ZENO_EVIDENCE_DEBUG === "1") {
    const debugName = error instanceof CliUsageError
      ? "CliUsageError"
      : error instanceof EvidenceValidationError
        ? "EvidenceValidationError"
        : "Error";
    process.stderr.write(
      `Debug stack:\n${debugName}: ${payload.error.message}\n    at zmr-evidence\n`,
    );
  }
}

function parseFromZmrOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const option = args[index];
    if (option === "--force") {
      if (Object.hasOwn(options, "force")) {
        throw new CliUsageError("duplicate_option", "--force may only be provided once");
      }
      options.force = true;
      continue;
    }
    const property = FROM_ZMR_OPTIONS.get(option);
    if (property === undefined) {
      const code = typeof option === "string" && option.startsWith("-")
        ? "unknown_option"
        : "unexpected_argument";
      throw new CliUsageError(code, code === "unknown_option"
        ? "Unknown from-zmr option"
        : "from-zmr does not accept positional arguments");
    }
    if (Object.hasOwn(options, property)) {
      throw new CliUsageError("duplicate_option", `${option} may only be provided once`);
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
  process.stdout.write(`${JSON.stringify({
    ok: true,
    command: "from-zmr",
    output: resolve(destination),
    manifestDigest: written.manifestDigest,
    items: written.manifest.items.length,
    artifacts,
  })}\n`);
}

async function runValidate(args) {
  if (args.length === 0) {
    throw new CliUsageError("missing_manifest", "validate requires a path to evidence.json");
  }
  if (args[0].startsWith("-")) {
    throw new CliUsageError("unknown_option", "Unknown validate option");
  }
  if (args.length !== 1) {
    throw new CliUsageError("unexpected_argument", "validate accepts exactly one evidence.json path");
  }
  const validated = await validateEvidencePackage(args[0]);
  const artifacts = validated.manifest.items.reduce(
    (count, item) => count + item.artifacts.length,
    0,
  );
  process.stdout.write(`${JSON.stringify({
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
  printError(error);
  process.exitCode = error instanceof CliUsageError ? 2 : 1;
}
