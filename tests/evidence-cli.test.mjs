import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
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
