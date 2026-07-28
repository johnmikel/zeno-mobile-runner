import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  closeSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = resolve(root, "npm/evidence-cli.mjs");
const passedTraceFixture = resolve(root, "fixtures/evidence/v1/sources/zmrtrace/passed");
const scenarioHash = `sha256:${"c".repeat(64)}`;

const requiredFromZmrOptions = [
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

function runCli(args, options = {}) {
  return spawnSync(process.execPath, [cliPath, ...args], {
    cwd: options.cwd ?? root,
    env: { ...process.env, ...options.env },
    encoding: "utf8",
  });
}

function runCliWithClosedOutput(args, { close, cwd = root, env = {} }) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(process.execPath, [cliPath, ...args], {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    if (close === "stdout") {
      child.stdout.destroy();
      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
    } else {
      assert.equal(close, "stderr");
      child.stderr.destroy();
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
      });
    }
    child.once("error", rejectPromise);
    child.once("close", (status, signal) => {
      resolvePromise({ status, signal, stdout, stderr });
    });
  });
}

function parseJsonLine(output) {
  assert.match(output, /^[^\r\n]+\n$/);
  return JSON.parse(output);
}

function makeFixture(t) {
  const directory = mkdtempSync(join(tmpdir(), "zmr-evidence-cli-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  cpSync(passedTraceFixture, join(directory, "trace"), { recursive: true });
  writeFileSync(join(directory, "fixture.appbin"), "fixture app binary\n");
  return directory;
}

function fromZmrArgs({
  scenario = "path",
  overrides = {},
  force = false,
} = {}) {
  const values = {
    "--trace": "trace",
    "--project-id": "client-shop",
    "--submitter-type": "automation",
    "--submitter-id": "github-actions:agency/shop:run-1842",
    "--release-id": "rel_2026_07_13",
    "--commit-sha": "b".repeat(40),
    "--surface": "android",
    "--app-artifact": "fixture.appbin",
    "--app-id": "dev.zmr.fixture",
    "--app-version": "1.2.3",
    "--build-number": "42",
    "--environment": "staging",
    "--journey-id": "checkout.guest",
    "--item-id": "checkout.guest.android",
    "--run-id": "ci_1842",
    "--device-name": "Pixel 9",
    "--os-name": "Android",
    "--os-version": "16",
    "--out": "zeno-evidence",
    ...overrides,
  };
  const args = ["from-zmr"];
  if (scenario === "path" || scenario === "both") {
    args.push("--scenario", "trace/scenario.json");
  }
  if (scenario === "hash" || scenario === "both") {
    args.push("--scenario-hash", scenarioHash);
  }
  for (const option of requiredFromZmrOptions) {
    if (Object.hasOwn(values, option)) args.push(option, values[option]);
  }
  if (force) args.push("--force");
  return args;
}

function withoutOption(args, option) {
  const index = args.indexOf(option);
  assert.notEqual(index, -1, `fixture is missing ${option}`);
  return [...args.slice(0, index), ...args.slice(index + 2)];
}

function withOptionValue(args, option, value) {
  const updated = [...args];
  const index = updated.indexOf(option);
  assert.notEqual(index, -1, `fixture is missing ${option}`);
  updated[index + 1] = value;
  return updated;
}

function withEqualsOptions(args) {
  const converted = [args[0]];
  for (let index = 1; index < args.length; index += 1) {
    const option = args[index];
    if (option === "--force") {
      converted.push(option);
      continue;
    }
    converted.push(`${option}=${args[index + 1]}`);
    index += 1;
  }
  return converted;
}

test("no command reports concise JSON usage on stderr and exits 2", () => {
  const result = runCli([]);

  assert.equal(result.status, 2);
  assert.equal(result.stdout, "");
  const error = parseJsonLine(result.stderr);
  assert.equal(error.ok, false);
  assert.equal(error.error.code, "missing_command");
  assert.match(error.error.message, /Usage: zmr-evidence/);
  assert.deepEqual(error.error.issues, []);
});

test("unknown commands are usage errors", () => {
  const result = runCli(["definitely-not-a-command"]);

  assert.equal(result.status, 2);
  assert.equal(result.stdout, "");
  const error = parseJsonLine(result.stderr);
  assert.equal(error.error.code, "unknown_command");
  assert.equal(error.error.message, "Unknown command");
});

test("usage errors do not echo unknown argument contents", (t) => {
  const directory = makeFixture(t);
  const secret = "SUPER_SECRET_UNKNOWN_ARGUMENT";
  for (const args of [
    [secret],
    [...fromZmrArgs(), `--${secret}`],
    ["validate", `--${secret}`],
  ]) {
    const result = runCli(args, { cwd: directory });
    assert.equal(result.status, 2);
    assert.equal(result.stdout, "");
    parseJsonLine(result.stderr);
    assert.equal(result.stderr.includes(secret), false);
  }
});

test("help exits 0 and the executable starts with a Node shebang", () => {
  const result = runCli(["--help"]);

  assert.equal(result.status, 0);
  assert.equal(result.stderr, "");
  assert.match(result.stdout, /^Usage: zmr-evidence/m);
  assert.equal(readFileSync(cliPath, "utf8").split("\n", 1)[0], "#!/usr/bin/env node");
  assert.notEqual(statSync(cliPath).mode & 0o111, 0);
  if (process.platform !== "win32") {
    const direct = spawnSync(cliPath, ["--help"], { encoding: "utf8" });
    assert.equal(direct.status, 0, direct.stderr);
    assert.match(direct.stdout, /^Usage: zmr-evidence/m);
  }
});

test("closed stdout is a quiet EPIPE with the intended help and success exit codes", async (t) => {
  const directory = makeFixture(t);
  for (const [args, cwd] of [
    [["--help"], directory],
    [fromZmrArgs(), directory],
  ]) {
    const result = await runCliWithClosedOutput(args, { close: "stdout", cwd });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.signal, null);
    assert.equal(result.stdout, "");
    assert.equal(result.stderr, "");
    assert.equal(result.stderr.includes("Unhandled 'error' event"), false);
    assert.equal(result.stderr.includes("node:events"), false);
    assert.equal(result.stderr.includes(directory), false);
    assert.equal(result.stderr.includes(root), false);
  }
});

test("closed stderr is a quiet EPIPE with usage and domain exit codes", async (t) => {
  const directory = makeFixture(t);
  const missing = join(directory, "SUPER_SECRET_MISSING_MANIFEST", "evidence.json");
  for (const [args, expectedStatus] of [
    [[], 2],
    [["validate", missing], 1],
  ]) {
    const result = await runCliWithClosedOutput(args, {
      close: "stderr",
      cwd: directory,
      env: { ZENO_EVIDENCE_DEBUG: "1" },
    });
    assert.equal(result.status, expectedStatus);
    assert.equal(result.signal, null);
    assert.equal(result.stdout, "");
    assert.equal(result.stdout.includes("SUPER_SECRET"), false);
    assert.equal(result.stdout.includes(directory), false);
    assert.equal(result.stdout.includes(root), false);
  }
});

test("non-EPIPE output failures terminate quietly without recursive diagnostics", {
  skip: process.platform === "win32",
}, (t) => {
  const directory = makeFixture(t);
  const readOnlyPath = join(directory, "read-only-output");
  writeFileSync(readOnlyPath, "");
  const readOnlyFd = openSync(readOnlyPath, "r");
  let result;
  try {
    result = spawnSync(process.execPath, [cliPath, "--help"], {
      cwd: directory,
      encoding: "utf8",
      stdio: ["ignore", readOnlyFd, "pipe"],
    });
  } finally {
    closeSync(readOnlyFd);
  }
  assert.equal(result.status, 1);
  assert.equal(result.signal, null);
  assert.equal(result.stderr, "");
  assert.equal(result.stderr.includes(directory), false);
  assert.equal(result.stderr.includes(root), false);
});

test("from-zmr creates an evidence package and prints exactly one compact JSON result", (t) => {
  const directory = makeFixture(t);
  const result = runCli(fromZmrArgs({
    overrides: { "--project-id": "client shop" },
  }), { cwd: directory });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "");
  const success = parseJsonLine(result.stdout);
  const manifestPath = join(directory, "zeno-evidence", "evidence.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const artifactCount = manifest.items.reduce((count, item) => count + item.artifacts.length, 0);
  assert.deepEqual(success, {
    ok: true,
    command: "from-zmr",
    output: realpathSync(join(directory, "zeno-evidence")),
    manifestDigest: success.manifestDigest,
    items: manifest.items.length,
    artifacts: artifactCount,
  });
  assert.match(success.manifestDigest, /^sha256:[a-f0-9]{64}$/);
  assert.equal(manifest.project.externalId, "client shop");
  assert.equal(existsSync(join(directory, "zeno-evidence", "artifacts")), true);
  assert.equal(JSON.stringify(manifest).includes(directory), false);
});

test("from-zmr accepts a scenario hash instead of a scenario file", (t) => {
  const directory = makeFixture(t);
  const result = runCli(fromZmrArgs({ scenario: "hash" }), { cwd: directory });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "");
  const success = parseJsonLine(result.stdout);
  const manifest = JSON.parse(readFileSync(join(directory, "zeno-evidence", "evidence.json"), "utf8"));
  assert.equal(manifest.items[0].scenarioHash, scenarioHash);
  assert.equal(success.artifacts, manifest.items[0].artifacts.length);
  assert.equal(manifest.items[0].artifacts.some((artifact) => artifact.type === "scenario_source"), false);
});

test("from-zmr requires exactly one scenario identity", (t) => {
  const directory = makeFixture(t);
  for (const [scenario, code] of [
    ["none", "missing_scenario_identity"],
    ["both", "conflicting_scenario_identity"],
  ]) {
    const result = runCli(fromZmrArgs({ scenario }), { cwd: directory });
    assert.equal(result.status, 2);
    assert.equal(result.stdout, "");
    assert.equal(parseJsonLine(result.stderr).error.code, code);
  }
});

test("every required from-zmr option has an actionable missing-option error", (t) => {
  const directory = makeFixture(t);
  const complete = fromZmrArgs();
  for (const option of requiredFromZmrOptions) {
    const result = runCli(withoutOption(complete, option), { cwd: directory });
    assert.equal(result.status, 2, option);
    assert.equal(result.stdout, "", option);
    const error = parseJsonLine(result.stderr);
    assert.equal(error.error.code, "missing_option", option);
    assert.equal(error.error.message, `${option} is required`, option);
    assert.deepEqual(error.error.issues, [], option);
  }
});

test("from-zmr preserves identities verbatim and rejects edge whitespace or controls", (t) => {
  const directory = makeFixture(t);
  for (const value of ["", "   ", " leading", "trailing ", "line\nbreak", "control\u0001byte"]) {
    const result = runCli(fromZmrArgs({
      overrides: {
        "--project-id": value,
        "--out": `invalid-${Buffer.from(value).toString("hex") || "empty"}`,
      },
    }), { cwd: directory });
    assert.equal(result.status, 1, JSON.stringify(value));
    assert.equal(result.stdout, "", JSON.stringify(value));
    const error = parseJsonLine(result.stderr);
    assert.equal(error.error.code, "invalid_identity", JSON.stringify(value));
    if (value.length > 0) {
      assert.equal(error.error.message.includes(value), false, JSON.stringify(value));
    }
  }
});

test("adapter validation exposes only fixed actionable option rules", (t) => {
  const directory = makeFixture(t);
  const secret = "SUPER_SECRET_DO_NOT_ECHO";
  const cases = [
    ["--surface", `web-${secret}`, "invalid_adapter_options", "--surface must be ios or android"],
    [
      "--submitter-type",
      `robot-${secret}`,
      "invalid_adapter_options",
      "--submitter-type must be user or automation",
    ],
    [
      "--project-id",
      ` ${secret}/Users/attacker/.ssh/id_rsa`,
      "invalid_identity",
      "--project-id must be 1 to 256 characters with no edge whitespace or controls",
    ],
  ];
  for (const [option, value, code, message] of cases) {
    for (const debug of [false, true]) {
      const result = runCli(fromZmrArgs({
        overrides: { [option]: value },
      }), {
        cwd: directory,
        env: { ZENO_EVIDENCE_DEBUG: debug ? "1" : "0" },
      });
      assert.equal(result.status, 1, option);
      assert.equal(result.stdout, "", option);
      const [jsonLine] = result.stderr.split("\n");
      const payload = JSON.parse(jsonLine);
      assert.deepEqual(payload, {
        ok: false,
        error: { code, message, issues: [] },
      });
      assert.equal(result.stderr.includes(secret), false, option);
      assert.equal(result.stderr.includes("/Users/attacker"), false, option);
      assert.equal(result.stderr.includes(directory), false, option);
      assert.equal(result.stderr.includes(root), false, option);
    }
  }
});

test("every strict identity error names its CLI flag with a fixed rule", (t) => {
  const directory = makeFixture(t);
  const identityOptions = requiredFromZmrOptions.filter((option) => ![
    "--trace",
    "--submitter-type",
    "--surface",
    "--app-artifact",
    "--out",
  ].includes(option));
  for (const option of identityOptions) {
    const args = withEqualsOptions(fromZmrArgs({
      overrides: { [option]: "" },
    }));
    const result = runCli(args, { cwd: directory });
    assert.equal(result.status, 1, option);
    assert.equal(result.stdout, "", option);
    assert.deepEqual(parseJsonLine(result.stderr).error, {
      code: "invalid_identity",
      message: `${option} must be 1 to 256 characters with no edge whitespace or controls`,
      issues: [],
    });
  }
});

test("unknown validation fields and codes keep generic no-leak errors", {
  skip: process.platform === "win32",
}, (t) => {
  const directory = makeFixture(t);
  const secret = "SUPER_SECRET_UNKNOWN_VALIDATION_DETAIL";
  const traceManifestPath = join(directory, "trace", "trace.json");
  const traceManifest = JSON.parse(readFileSync(traceManifestPath, "utf8"));
  traceManifest.runnerVersion = ` ${secret}/Users/attacker/.ssh/id_rsa`;
  writeFileSync(traceManifestPath, `${JSON.stringify(traceManifest, null, 2)}\n`);
  // unsupported_trace_source stays outside SAFE_EVIDENCE_MESSAGES, so a trace
  // file that misses the .zmrtrace extension still exercises the unknown-code
  // collapse with an attacker-controlled path in the flag value.
  const unknownCodeSource = `${secret}/Users/attacker/.ssh/id_rsa`;
  mkdirSync(join(directory, secret, "Users", "attacker", ".ssh"), { recursive: true });
  writeFileSync(join(directory, unknownCodeSource), "not a .zmrtrace archive\n");

  const cases = [
    [fromZmrArgs({ overrides: { "--out": "unknown-field-evidence" } }), {
      code: "invalid_identity",
      message: "Evidence identity is invalid",
      issues: [],
    }],
    [fromZmrArgs({ overrides: {
      "--trace": unknownCodeSource,
      "--out": "unknown-code-evidence",
    } }), {
      code: "evidence_validation_error",
      message: "Evidence command failed",
      issues: [],
    }],
  ];
  for (const [args, expectedError] of cases) {
    for (const debug of [false, true]) {
      const result = runCli(args, {
        cwd: directory,
        env: { ZENO_EVIDENCE_DEBUG: debug ? "1" : "0" },
      });
      assert.equal(result.status, 1);
      assert.equal(result.stdout, "");
      const [jsonLine] = result.stderr.split("\n");
      assert.deepEqual(JSON.parse(jsonLine).error, expectedError);
      assert.equal(result.stderr.includes(secret), false);
      assert.equal(result.stderr.includes("/Users/attacker"), false);
      assert.equal(result.stderr.includes(directory), false);
      assert.equal(result.stderr.includes(root), false);
    }
  }
});

test("symlinked and non-file sources name their flag and fix without leaking the path", {
  skip: process.platform === "win32",
}, (t) => {
  const directory = makeFixture(t);
  const secret = "SUPER_SECRET_SOURCE_PATH_DETAIL";
  const symlinkHint = "; on macOS /tmp is a symlink to /private/tmp, so pass the resolved path";
  mkdirSync(join(directory, secret, "Users", "attacker"), { recursive: true });
  symlinkSync(join(directory, "trace"), join(directory, secret, "Users", "attacker", "trace"), "dir");
  symlinkSync(
    join(directory, "trace", "scenario.json"),
    join(directory, secret, "Users", "attacker", "scenario.json"),
    "file",
  );
  symlinkSync(
    join(directory, "fixture.appbin"),
    join(directory, secret, "Users", "attacker", "app.appbin"),
    "file",
  );
  mkdirSync(join(directory, secret, "Users", "attacker", "Fixture.app"), { recursive: true });
  writeFileSync(join(directory, secret, "Users", "attacker", "Fixture.app", "Fixture"), "mach-o\n");

  const cases = [
    [
      { "--trace": `${secret}/Users/attacker/trace` },
      "symlink_source_rejected",
      `--trace must not contain a symbolic link${symlinkHint}`,
    ],
    [
      { "--app-artifact": `${secret}/Users/attacker/app.appbin` },
      "symlink_source_rejected",
      `--app-artifact must not contain a symbolic link${symlinkHint}`,
    ],
    [
      { "--app-artifact": `${secret}/Users/attacker/Fixture.app` },
      "source_not_regular_file",
      "--app-artifact must be a regular file; zip an .app bundle or pass an .ipa",
    ],
  ];
  let index = 0;
  for (const [overrides, code, message] of cases) {
    index += 1;
    const label = JSON.stringify(overrides);
    for (const debug of [false, true]) {
      const result = runCli(fromZmrArgs({
        overrides: { ...overrides, "--out": `source-path-evidence-${index}` },
      }), {
        cwd: directory,
        env: { ZENO_EVIDENCE_DEBUG: debug ? "1" : "0" },
      });
      assert.equal(result.status, 1, label);
      assert.equal(result.stdout, "", label);
      const [jsonLine] = result.stderr.split("\n");
      assert.deepEqual(JSON.parse(jsonLine).error, { code, message, issues: [] }, label);
      assert.equal(result.stderr.includes(secret), false, label);
      assert.equal(result.stderr.includes("/Users/attacker"), false, label);
      assert.equal(result.stderr.includes(directory), false, label);
      assert.equal(result.stderr.includes(root), false, label);
    }
  }
});

test("a symlinked --scenario names its flag with the same fixed hint", {
  skip: process.platform === "win32",
}, (t) => {
  const directory = makeFixture(t);
  const secret = "SUPER_SECRET_SCENARIO_PATH_DETAIL";
  mkdirSync(join(directory, secret), { recursive: true });
  symlinkSync(
    join(directory, "trace", "scenario.json"),
    join(directory, secret, "scenario.json"),
    "file",
  );
  const args = withOptionValue(
    fromZmrArgs(),
    "--scenario",
    `${secret}/scenario.json`,
  );
  const result = runCli(args, { cwd: directory });

  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.deepEqual(parseJsonLine(result.stderr).error, {
    code: "symlink_source_rejected",
    message: "--scenario must not contain a symbolic link"
      + "; on macOS /tmp is a symlink to /private/tmp, so pass the resolved path",
    issues: [],
  });
  assert.equal(result.stderr.includes(secret), false);
});

test("strict option parsing rejects unknown, duplicate, missing-value, and positional arguments", (t) => {
  const directory = makeFixture(t);
  const cases = [
    [[...fromZmrArgs(), "--unknown"], "unknown_option"],
    [[...fromZmrArgs(), "--project-id", "duplicate"], "duplicate_option"],
    [[...withoutOption(fromZmrArgs(), "--project-id"), "--project-id"], "missing_option_value"],
    [[...fromZmrArgs(), "positional"], "unexpected_argument"],
  ];
  for (const [args, code] of cases) {
    const result = runCli(args, { cwd: directory });
    assert.equal(result.status, 2, code);
    assert.equal(result.stdout, "", code);
    assert.equal(parseJsonLine(result.stderr).error.code, code);
  }
});

test("equals-form options preserve literal dash values and empty values", (t) => {
  const directory = makeFixture(t);
  cpSync(join(directory, "trace"), join(directory, "--trace"), { recursive: true });
  writeFileSync(join(directory, "--app"), "dash-prefixed app binary\n");
  const literalValue = "--surface";
  const args = withEqualsOptions(fromZmrArgs({
    overrides: {
      "--trace": "--trace",
      "--project-id": literalValue,
      "--release-id": "--client",
      "--app-artifact": "--app",
      "--out": "--evidence",
    },
  })).map((argument) => argument === "--scenario=trace/scenario.json"
    ? "--scenario=--trace/scenario.json"
    : argument);
  const result = runCli(args, { cwd: directory });
  assert.equal(result.status, 0, result.stderr);
  const manifest = JSON.parse(readFileSync(join(directory, "--evidence", "evidence.json"), "utf8"));
  assert.equal(manifest.project.externalId, literalValue);
  assert.equal(manifest.release.externalId, "--client");

  const empty = runCli(withEqualsOptions(fromZmrArgs({
    overrides: { "--project-id": "", "--out": "empty-value-evidence" },
  })), { cwd: directory });
  assert.equal(empty.status, 1);
  assert.deepEqual(parseJsonLine(empty.stderr).error, {
    code: "invalid_identity",
    message: "--project-id must be 1 to 256 characters with no edge whitespace or controls",
    issues: [],
  });
});

test("equals-form options retain strict duplicate and unknown checks", (t) => {
  const directory = makeFixture(t);
  for (const [args, code] of [
    [[...withEqualsOptions(fromZmrArgs()), "--project-id=duplicate"], "duplicate_option"],
    [[...withEqualsOptions(fromZmrArgs()), "--unknown=value"], "unknown_option"],
    [[...withoutOption(fromZmrArgs(), "--project-id"), "--project-id", "--client"], "missing_option_value"],
    [[...withoutOption(fromZmrArgs(), "--project-id"), "--project-id", "--surface"], "missing_option_value"],
  ]) {
    const result = runCli(args, { cwd: directory });
    assert.equal(result.status, 2, code);
    assert.equal(result.stdout, "", code);
    assert.equal(parseJsonLine(result.stderr).error.code, code);
  }
});

test("--force replaces a complete destination and leaves a valid complete package", (t) => {
  const directory = makeFixture(t);
  const first = runCli(fromZmrArgs(), { cwd: directory });
  assert.equal(first.status, 0, first.stderr);
  const marker = join(directory, "zeno-evidence", "stale-marker.txt");
  writeFileSync(marker, "old package marker\n");

  const refused = runCli(fromZmrArgs(), { cwd: directory });
  assert.equal(refused.status, 1);
  assert.equal(refused.stdout, "");
  assert.equal(parseJsonLine(refused.stderr).error.code, "destination_exists");
  assert.equal(existsSync(marker), true);

  const replaced = runCli(fromZmrArgs({ force: true }), { cwd: directory });
  assert.equal(replaced.status, 0, replaced.stderr);
  assert.equal(replaced.stderr, "");
  assert.equal(existsSync(marker), false);
  const manifest = JSON.parse(readFileSync(join(directory, "zeno-evidence", "evidence.json"), "utf8"));
  assert.equal(Array.isArray(manifest.items), true);
  assert.equal(existsSync(join(directory, "zeno-evidence", "artifacts")), true);
});

test("validate verifies evidence.json and sibling artifacts with compact success output", (t) => {
  const directory = makeFixture(t);
  const created = runCli(fromZmrArgs(), { cwd: directory });
  assert.equal(created.status, 0, created.stderr);

  const result = runCli(["validate", "zeno-evidence/evidence.json"], { cwd: directory });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "");
  const success = parseJsonLine(result.stdout);
  const manifestPath = realpathSync(join(directory, "zeno-evidence", "evidence.json"));
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  assert.deepEqual(success, {
    ok: true,
    command: "validate",
    output: manifestPath,
    manifestDigest: success.manifestDigest,
    items: manifest.items.length,
    artifacts: manifest.items.reduce((count, item) => count + item.artifacts.length, 0),
  });
  assert.match(success.manifestDigest, /^sha256:[a-f0-9]{64}$/);
});

test("validate supports -- before a literal dash-prefixed manifest path", (t) => {
  const directory = makeFixture(t);
  const created = runCli(fromZmrArgs(), { cwd: directory });
  assert.equal(created.status, 0, created.stderr);
  const packageRoot = join(directory, "zeno-evidence");
  const literalManifest = join(packageRoot, "--manifest");
  writeFileSync(literalManifest, readFileSync(join(packageRoot, "evidence.json")));

  const result = runCli(["validate", "--", "--manifest"], { cwd: packageRoot });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(parseJsonLine(result.stdout).output, realpathSync(literalManifest));

  for (const args of [
    ["validate", "--"],
    ["validate", "--", "--manifest", "extra"],
    ["validate", "--", "--manifest", "--force"],
  ]) {
    const rejected = runCli(args, { cwd: packageRoot });
    assert.equal(rejected.status, 2, args.join(" "));
    assert.equal(rejected.stdout, "", args.join(" "));
  }
});

test("validate detects sibling artifact tampering and keeps normal failures on stderr only", (t) => {
  const directory = makeFixture(t);
  const created = runCli(fromZmrArgs(), { cwd: directory });
  assert.equal(created.status, 0, created.stderr);
  const manifestPath = join(directory, "zeno-evidence", "evidence.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const artifact = manifest.items[0].artifacts[0];
  writeFileSync(join(directory, "zeno-evidence", artifact.path), Buffer.alloc(artifact.sizeBytes, 0x78));

  const result = runCli(["validate", manifestPath], { cwd: directory });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  const error = parseJsonLine(result.stderr);
  assert.equal(error.ok, false);
  assert.equal(error.error.code, "artifact_digest_mismatch");
  assert.equal(
    error.error.message,
    "Packaged artifact digest does not match its descriptor",
  );
  assert.deepEqual(error.error.issues, []);
  assert.equal(result.stderr.includes("\n    at "), false);
});

test("validate never includes malformed evidence contents in its JSON error", (t) => {
  const directory = makeFixture(t);
  const packageRoot = join(directory, "malformed-package");
  cpSync(join(directory, "trace"), packageRoot, { recursive: true });
  const secret = "SUPER_SECRET_DO_NOT_ECHO";
  const manifestPath = join(packageRoot, "evidence.json");
  writeFileSync(manifestPath, `{not-json:${secret}}\n`);

  const result = runCli(["validate", manifestPath], { cwd: directory });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  const error = parseJsonLine(result.stderr);
  assert.equal(error.error.code, "invalid_evidence_json");
  assert.equal(result.stderr.includes(secret), false);
});

test("validate redacts attacker-controlled manifest issues and local paths in normal and debug modes", (t) => {
  const directory = makeFixture(t);
  const created = runCli(fromZmrArgs(), { cwd: directory });
  assert.equal(created.status, 0, created.stderr);
  const manifestPath = join(directory, "zeno-evidence", "evidence.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const attackerStrings = [
    "SUPER_SECRET_DO_NOT_ECHO",
    "ghp_ATTACKER_CONTROLLED_TOKEN_123456789",
    "/Users/attacker/.ssh/id_rsa",
    "file:///private/var/secrets/client-token.txt",
    "Bearer eyJhbGciOiJub25lIn0.attacker.signature",
  ];
  manifest[attackerStrings[0]] = attackerStrings[1];
  manifest.release[attackerStrings[2]] = attackerStrings[3];
  manifest.project.externalId = attackerStrings[4];
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  for (const debug of [false, true]) {
    const result = runCli(["validate", manifestPath], {
      cwd: directory,
      env: { ZENO_EVIDENCE_DEBUG: debug ? "1" : "0" },
    });
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    const [jsonLine, ...debugLines] = result.stderr.split("\n");
    assert.match(jsonLine, /^[^\r\n]+$/);
    assert.deepEqual(JSON.parse(jsonLine), {
      ok: false,
      error: {
        code: "invalid_evidence_manifest",
        message: "Evidence manifest is invalid",
        issues: [],
      },
    });
    if (debug) {
      assert.match(debugLines.join("\n"), /EvidenceValidationError/);
      assert.match(debugLines.join("\n"), /at zmr-evidence/);
    } else {
      assert.deepEqual(debugLines, [""]);
    }
    for (const secret of attackerStrings) {
      assert.equal(result.stderr.includes(secret), false, secret);
    }
    assert.equal(result.stderr.includes(directory), false);
    assert.equal(result.stderr.includes(root), false);
  }
});

test("source and native filesystem failures redact caller paths in normal and debug modes", (t) => {
  const directory = makeFixture(t);
  const missingTrace = join(directory, "SUPER_SECRET_MISSING_TRACE");
  const blockedParent = join(directory, "SUPER_SECRET_BLOCKED_PARENT");
  writeFileSync(blockedParent, "not a directory\n");
  const commands = [
    fromZmrArgs({ overrides: { "--trace": missingTrace, "--out": "missing-output" } }),
    fromZmrArgs({ overrides: { "--out": join(blockedParent, "SUPER_SECRET_DESTINATION") } }),
  ];

  for (const args of commands) {
    for (const debug of [false, true]) {
      const result = runCli(args, {
        cwd: directory,
        env: { ZENO_EVIDENCE_DEBUG: debug ? "1" : "0" },
      });
      assert.equal(result.status, 1);
      assert.equal(result.stdout, "");
      const [jsonLine] = result.stderr.split("\n");
      const payload = JSON.parse(jsonLine);
      assert.equal(payload.ok, false);
      assert.equal(typeof payload.error.code, "string");
      assert.equal(typeof payload.error.message, "string");
      assert.deepEqual(payload.error.issues, []);
      assert.equal(result.stderr.includes(directory), false);
      assert.equal(result.stderr.includes(root), false);
      assert.equal(result.stderr.includes("SUPER_SECRET"), false);
    }
  }
});

test("missing source paths report fixed actionable flags without supplied path details", (t) => {
  const directory = makeFixture(t);
  const physicalDirectory = realpathSync(directory);
  const secret = "SUPER_SECRET_SOURCE_TOKEN_DO_NOT_ECHO";
  const cases = [
    {
      args: fromZmrArgs({ overrides: {
        "--trace": join(physicalDirectory, `${secret}-trace`),
        "--out": "missing-trace-output",
      } }),
      field: "tracePath",
      message: "--trace is unavailable or unreadable",
    },
    {
      args: fromZmrArgs({ overrides: {
        "--app-artifact": join(physicalDirectory, `${secret}-app`),
        "--out": "missing-app-output",
      } }),
      field: "appArtifactPath",
      message: "--app-artifact is unavailable or unreadable",
    },
    {
      args: withOptionValue(
        fromZmrArgs({ overrides: { "--out": "missing-scenario-output" } }),
        "--scenario",
        join(physicalDirectory, `${secret}-scenario`),
      ),
      field: "scenarioPath",
      message: "--scenario is unavailable or unreadable",
    },
  ];

  for (const { args, field, message } of cases) {
    for (const debug of [false, true]) {
      const result = runCli(args, {
        cwd: directory,
        env: { ZENO_EVIDENCE_DEBUG: debug ? "1" : "0" },
      });
      assert.equal(result.status, 1, field);
      assert.equal(result.stdout, "", field);
      const [jsonLine] = result.stderr.split("\n");
      assert.deepEqual(JSON.parse(jsonLine).error, {
        code: "invalid_source_path",
        message,
        issues: [],
      });
      assert.equal(result.stderr.includes(secret), false, field);
      assert.equal(result.stderr.includes(directory), false, field);
      assert.equal(result.stderr.includes(physicalDirectory), false, field);
      assert.equal(result.stderr.includes(root), false, field);
      assert.equal(result.stderr.includes(field), false, field);
      assert.equal(result.stderr.includes(`${field} is unavailable`), false, field);
      assert.equal(result.stderr.includes(`${field} could not be read`), false, field);
    }
  }
});

test("validate usage errors exit 2 and command help exits 0", (t) => {
  const directory = makeFixture(t);
  for (const [args, code] of [
    [["validate"], "missing_manifest"],
    [["validate", "one", "two"], "unexpected_argument"],
    [["validate", "--force"], "unknown_option"],
  ]) {
    const result = runCli(args, { cwd: directory });
    assert.equal(result.status, 2, code);
    assert.equal(result.stdout, "", code);
    assert.equal(parseJsonLine(result.stderr).error.code, code);
  }

  const help = runCli(["validate", "--help"], { cwd: directory });
  assert.equal(help.status, 0);
  assert.equal(help.stderr, "");
  assert.match(help.stdout, /^Usage: zmr-evidence/m);
});

test("ZENO_EVIDENCE_DEBUG=1 is the only mode that emits a stack after the JSON error", (t) => {
  const directory = makeFixture(t);
  const missing = join(directory, "missing", "evidence.json");
  const normal = runCli(["validate", missing], { cwd: directory });
  assert.equal(normal.status, 1);
  parseJsonLine(normal.stderr);

  const debug = runCli(["validate", missing], {
    cwd: directory,
    env: { ZENO_EVIDENCE_DEBUG: "1" },
  });
  assert.equal(debug.status, 1);
  assert.equal(debug.stdout, "");
  const [jsonLine, ...stackLines] = debug.stderr.split("\n");
  assert.equal(JSON.parse(jsonLine).error.code, "invalid_evidence_package");
  assert.match(stackLines.join("\n"), /EvidenceValidationError|at /);
});
