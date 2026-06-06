import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import url from "node:url";

const root = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "..");

test("init command creates app-local scenario and npm script snippets", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-test-"));
  try {
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);

    const scenario = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "android-smoke.json"), "utf8"));
    assert.equal(scenario.appId, "com.example.demo");
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "ios-smoke.json")));
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "device-matrix.json")));
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "AGENTS.md")));
    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    const matrix = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "device-matrix.json"), "utf8"));
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    assert.equal(config.schemaVersion, 1);
    assert.equal(config.appId, "com.example.demo");
    assert.equal(config.android.smokeScenario, ".zmr/android-smoke.json");
    assert.equal(config.ios.smokeScenario, ".zmr/ios-smoke.json");
    assert.equal(config.scripts.doctor, "zmr doctor --strict --json --config .zmr/config.json");
    assert.equal(config.scripts.schemas, "zmr schemas --json");
    assert.equal(matrix.appId, "com.example.demo");
    assert.deepEqual(matrix.devices.map((device) => device.name), ["android-emulator", "ios-simulator"]);
    assert.equal(matrix.devices[1].iosDeviceType, "simulator");
    assert.match(agentInstructions, /# ZMR Agent Instructions/);
    assert.match(agentInstructions, /App id: `com\.example\.demo`/);
    assert.match(agentInstructions, /zmr inspect --json --dir \./);
    assert.match(agentInstructions, /zmr doctor --strict --json --config \.zmr\/config\.json/);
    assert.match(agentInstructions, /zmr schemas --json/);
    assert.match(agentInstructions, /zmr run \.zmr\/android-smoke\.json --device emulator-5554 --trace-dir traces\/zmr-android/);
    assert.match(agentInstructions, /zmr run \.zmr\/ios-smoke\.json --platform ios --device booted --trace-dir traces\/zmr-ios/);
    assert.match(agentInstructions, /zmr explain traces\/zmr-agent --json/);
    assert.match(agentInstructions, /zmr export traces\/zmr-agent --out traces\/zmr-agent-redacted\.zmrtrace --redact/);
    assert.match(agentInstructions, /zmr-release-readiness --evidence traces\/zmr-pilots\/evidence\.jsonl --target production --json/);
    assert.match(agentInstructions, /Use `recommendedWording` and keep `claimLimitations` intact/);
    assert.match(agentInstructions, /When readiness is blocked, follow `nextSteps\[\]\.commands` in order/);
    assert.match(agentInstructions, /Use `nextSteps\[\]\.covers` to map each command back to the blocked requirements it resolves/);
    assert.match(agentInstructions, /Use `satisfied` for proven requirements; do not infer readiness from raw `passed` evidence/);
    assert.match(agentInstructions, /Do not claim production readiness from smoke runs alone/);
    assert.match(agentInstructions, /zmr mcp --config \.zmr\/config\.json --trace-dir traces\/zmr-agent/);
    assert.match(agentInstructions, /Use `semantic_snapshot` before choosing tap or type actions/);
    assert.match(agentInstructions, /zmr explore --from-trace traces\/zmr-agent --out \.zmr\/discovered\/login-smoke\.json --goal "find a stable login smoke" --include-actions --validate --json/);
    assert.match(agentInstructions, /Prefer `zmr explore` for CLI agent loops/);
    assert.match(agentInstructions, /`autonomous:false`, `reviewRequired:true`, `guardrails`/);
    assert.match(agentInstructions, /zmr discover --from-trace traces\/zmr-agent --out \.zmr\/discovered\/replay-smoke\.json --include-actions --validate --json/);
    assert.match(agentInstructions, /Treat discover output as a lower-level reviewable starting point/);
    assert.match(agentInstructions, /zmr draft --from-trace traces\/zmr-agent --out \.zmr\/discovered\/surface-smoke\.json --json/);
    assert.match(agentInstructions, /Treat draft output as a reviewable starting point/);
    assert.match(agentInstructions, /## App Commands/);
    assert.match(agentInstructions, /zmr-benchmark --zmr \.zmr\/android-smoke\.json --device emulator-5554 --app-id com\.example\.demo/);
    assert.match(agentInstructions, /zmr-benchmark --zmr \.zmr\/ios-smoke\.json --platform ios --device booted --app-id com\.example\.demo/);
    assert.match(agentInstructions, /zmr-device-matrix --matrix \.zmr\/device-matrix\.json --trace-root traces\/zmr-matrix/);
    assert.match(agentInstructions, /zmr-pilot-gate --android --ios --android-app-root \. --android-app-id com\.example\.demo/);
    assert.doesNotMatch(agentInstructions, /npm run zmr:/);
    assert.equal(config.artifacts.screenshots, true);
    assert.equal(config.artifacts.hierarchy, true);
    assert.equal(config.artifacts.logs, true);
    assert.equal(config.artifacts.screenRecording, false);
    assert.equal(config.scripts.android, "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android");
    assert.match(config.scripts.androidReliability, /export ZMR_BIN=/);
    assert.match(config.scripts.androidReliability, /"\$ZMR_BIN" report traces\/zmr-android-reliability/);
    assert.doesNotMatch(config.scripts.androidReliability, /&& zmr report/);
    assert.equal(
      config.scripts.androidReliability,
      'export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.demo --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && "$ZMR_BIN" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml',
    );
    assert.match(config.scripts.iosReliability, /"\$ZMR_BIN" report traces\/zmr-ios-reliability/);
    assert.doesNotMatch(config.scripts.iosReliability, /&& zmr report/);
    assert.equal(
      config.scripts.iosReliability,
      'export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.demo --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && "$ZMR_BIN" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml',
    );
    assert.equal(
      config.scripts.pilotGate,
      "zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.demo --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.demo --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
    );
    assert.equal(
      config.scripts.readiness,
      "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json",
    );
    assert.equal(
      config.scripts.matrix,
      "ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0",
    );
    assert.equal(config.scripts.serve, "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent");
    assert.equal(config.scripts.mcp, "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent");
    assert.match(fs.readFileSync(path.join(tmp, ".gitignore"), "utf8"), /^traces\/$/m);
    assert.match(result.stdout, /zmr:android/);
    assert.match(result.stdout, /zmr:ios/);
    assert.match(result.stdout, /zmr:android:reliability/);
    assert.match(result.stdout, /zmr:ios:reliability/);
    assert.match(result.stdout, /zmr:matrix/);
    assert.match(result.stdout, /zmr:pilot/);
    assert.match(result.stdout, /zmr:readiness/);
    assert.match(result.stdout, /zmr:schemas/);
    assert.match(result.stdout, /zmr:serve/);
    assert.match(result.stdout, /zmr:mcp/);
    assert.match(result.stdout, /Next steps/);
    assert.match(result.stdout, /zmr doctor --strict --json --config \.zmr\/config\.json/);
    assert.match(result.stdout, /created \.zmr/);
    assert.doesNotMatch(result.stdout, /zmr-init-test-/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init command can patch package scripts non-interactively", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-package-json-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ scripts: { test: "vitest" } }, null, 2));
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--package-json",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);

    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts.test, "vitest");
    assert.equal(pkg.scripts["zmr:android"], "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android");
    assert.equal(pkg.scripts["zmr:android:reliability"].includes("--app-id com.example.demo"), true);
    assert.equal(pkg.scripts["zmr:explain"], "zmr explain traces/zmr-agent --json");
    assert.equal(pkg.scripts["zmr:export"], "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact");
    assert.equal(pkg.scripts["zmr:ios"], undefined);
    assert.equal(pkg.scripts["zmr:readiness"], undefined);
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    assert.match(agentInstructions, /## App Scripts/);
    assert.match(agentInstructions, /npm run zmr:android/);
    assert.match(agentInstructions, /npm run zmr:explain/);
    assert.match(result.stdout, /updated package\.json/);
    assert.match(result.stdout, /npm run zmr:android/);
    assert.doesNotMatch(result.stdout, /npm run zmr:ios/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init command emits native-compatible app JSON metadata", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-json-test-"));
  try {
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--json",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");

    const output = JSON.parse(result.stdout);
    assert.equal(output.ok, true);
    assert.equal(output.mode, "app");
    assert.equal(output.dir, tmp);
    assert.equal(output.appId, "com.example.demo");
    assert.deepEqual(output.created, [
      path.join(tmp, ".zmr", "config.json"),
      path.join(tmp, ".zmr", "android-smoke.json"),
      path.join(tmp, ".zmr", "ios-smoke.json"),
      path.join(tmp, ".zmr", "device-matrix.json"),
      path.join(tmp, ".zmr", "AGENTS.md"),
    ]);
    assert.equal(output.configPath, path.join(tmp, ".zmr", "config.json"));
    assert.equal(output.androidScenarioPath, path.join(tmp, ".zmr", "android-smoke.json"));
    assert.equal(output.iosScenarioPath, path.join(tmp, ".zmr", "ios-smoke.json"));
    assert.equal(output.deviceMatrixPath, path.join(tmp, ".zmr", "device-matrix.json"));
    assert.equal(output.agentInstructionsPath, path.join(tmp, ".zmr", "AGENTS.md"));
    assert.equal(output.next, `zmr doctor --strict --json --config ${path.join(tmp, ".zmr", "config.json")}`);
    assert.deepEqual(output.nextCommands, [
      `zmr doctor --strict --json --config ${path.join(tmp, ".zmr", "config.json")}`,
      "zmr schemas --json",
      `zmr validate --json ${path.join(tmp, ".zmr", "android-smoke.json")}`,
      `zmr validate --json ${path.join(tmp, ".zmr", "ios-smoke.json")}`,
    ]);
    assert.equal(output.scriptCount, 16);
    assert.deepEqual(output.scriptNames, [
      "doctor",
      "schemas",
      "validate",
      "android",
      "androidReport",
      "androidReliability",
      "ios",
      "iosReport",
      "iosReliability",
      "matrix",
      "pilotGate",
      "readiness",
      "serve",
      "mcp",
      "explain",
      "exportTrace",
    ]);
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "config.json")));
    assert.doesNotMatch(result.stdout, /Next steps|created \.zmr/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init command JSON metadata only points at selected platform scenarios", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-json-ios-test-"));
  try {
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--ios",
      "--json",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);

    const output = JSON.parse(result.stdout);
    assert.equal(output.androidScenarioPath, undefined);
    assert.equal(output.iosScenarioPath, path.join(tmp, ".zmr", "ios-smoke.json"));
    assert.deepEqual(output.created, [
      path.join(tmp, ".zmr", "config.json"),
      path.join(tmp, ".zmr", "ios-smoke.json"),
      path.join(tmp, ".zmr", "device-matrix.json"),
      path.join(tmp, ".zmr", "AGENTS.md"),
    ]);
    assert.deepEqual(output.nextCommands, [
      `zmr doctor --strict --json --config ${path.join(tmp, ".zmr", "config.json")}`,
      "zmr schemas --json",
      `zmr validate --json ${path.join(tmp, ".zmr", "ios-smoke.json")}`,
    ]);
    assert.equal(fs.existsSync(path.join(tmp, ".zmr", "android-smoke.json")), false);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init command JSON metadata uses npm scripts when package-json is patched", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-json-package-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ private: true }, null, 2));
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--package-json",
      "--json",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);

    const output = JSON.parse(result.stdout);
    assert.equal(output.next, "npm run zmr:doctor");
    assert.deepEqual(output.nextCommands, [
      "npm run zmr:doctor",
      "npm run zmr:schemas",
      "npm run zmr:validate",
    ]);
    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts["zmr:doctor"], "zmr doctor --strict --json --config .zmr/config.json");
    assert.doesNotMatch(result.stdout, /updated package\.json|Next steps/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init rerun refreshes generated config and matrix without overwriting scenarios", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-rerun-test-"));
  try {
    const first = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.one",
    ], { encoding: "utf8" });
    assert.equal(first.status, 0, first.stderr);

    const scenarioPath = path.join(tmp, ".zmr", "android-smoke.json");
    const scenario = JSON.parse(fs.readFileSync(scenarioPath, "utf8"));
    scenario.name = "Custom Android smoke";
    fs.writeFileSync(scenarioPath, `${JSON.stringify(scenario, null, 2)}\n`);

    const second = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.two",
    ], { encoding: "utf8" });
    assert.equal(second.status, 0, second.stderr);

    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    const matrix = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "device-matrix.json"), "utf8"));
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    const preservedScenario = JSON.parse(fs.readFileSync(scenarioPath, "utf8"));
    assert.equal(config.appId, "com.example.two");
    assert.equal(matrix.appId, "com.example.two");
    assert.match(agentInstructions, /App id: `com\.example\.two`/);
    assert.equal(config.scripts.androidReliability.includes("--app-id com.example.two"), true);
    assert.equal(config.scripts.pilotGate.includes("--android-app-id com.example.two"), true);
    assert.equal(preservedScenario.name, "Custom Android smoke");
    assert.equal(preservedScenario.appId, "com.example.one");
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init command can target selected platforms and Expo dev-client scenarios", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-selected-platform-test-"));
  try {
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--ios",
      "--ios-shim",
      "./.zmr/ios-shim",
      "--expo-dev-client-scheme",
      "mobiletest",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);

    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    assert.equal(config.android.enabled, false);
    assert.equal(config.ios.enabled, true);
    assert.equal(config.tools.iosShimPath, "./.zmr/ios-shim");
    assert.equal(config.scripts.android, undefined);
    assert.equal(config.scripts.iosDevClient, "zmr run .zmr/ios-dev-client-open-link.json --platform ios --device booted --trace-dir traces/zmr-ios-dev-client");
    assert.equal(config.scripts.readiness, undefined);
    assert.equal(fs.existsSync(path.join(tmp, ".zmr", "android-smoke.json")), false);
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "ios-smoke.json")));
    const devClient = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "ios-dev-client-open-link.json"), "utf8"));
    assert.equal(devClient.steps[1].url, "exp+mobiletest://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081");
    const matrix = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "device-matrix.json"), "utf8"));
    assert.deepEqual(matrix.devices.map((device) => device.name), ["ios-simulator"]);
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    assert.match(agentInstructions, /zmr run \.zmr\/ios-dev-client-open-link\.json --platform ios --device booted --trace-dir traces\/zmr-ios-dev-client/);
    assert.doesNotMatch(agentInstructions, /android-smoke/);
    assert.match(result.stdout, /Next steps/);
    assert.match(result.stdout, /zmr run \.zmr\/ios-dev-client-open-link\.json --platform ios --device booted --trace-dir traces\/zmr-ios-dev-client/);
    assert.doesNotMatch(result.stdout, /zmr:readiness/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init command JSON metadata includes Expo dev-client scenario paths", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-init-json-expo-test-"));
  try {
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
      "--expo-dev-client-scheme",
      "mobiletest",
      "--json",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);

    const output = JSON.parse(result.stdout);
    assert.equal(output.androidDevClientScenarioPath, path.join(tmp, ".zmr", "android-dev-client-smoke.json"));
    assert.equal(output.iosDevClientScenarioPath, path.join(tmp, ".zmr", "ios-dev-client-open-link.json"));
    assert.deepEqual(output.nextCommands, [
      `zmr doctor --strict --json --config ${path.join(tmp, ".zmr", "config.json")}`,
      "zmr schemas --json",
      `zmr validate --json ${path.join(tmp, ".zmr", "android-smoke.json")}`,
      `zmr validate --json ${path.join(tmp, ".zmr", "ios-smoke.json")}`,
      `zmr validate --json ${path.join(tmp, ".zmr", "android-dev-client-smoke.json")}`,
      `zmr validate --json ${path.join(tmp, ".zmr", "ios-dev-client-open-link.json")}`,
    ]);
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "android-dev-client-smoke.json")));
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "ios-dev-client-open-link.json")));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("init command JSON next commands quote app paths with spaces", () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "zmr init json space test-"));
  const tmp = path.join(tmpRoot, "mobile app");
  fs.mkdirSync(tmp);
  try {
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/init-app.mjs"),
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--json",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);

    const output = JSON.parse(result.stdout);
    assert.equal(output.configPath, path.join(tmp, ".zmr", "config.json"));
    assert.equal(output.next, `zmr doctor --strict --json --config '${path.join(tmp, ".zmr", "config.json")}'`);
    assert.deepEqual(output.nextCommands, [
      `zmr doctor --strict --json --config '${path.join(tmp, ".zmr", "config.json")}'`,
      "zmr schemas --json",
      `zmr validate --json '${path.join(tmp, ".zmr", "android-smoke.json")}'`,
      `zmr validate --json '${path.join(tmp, ".zmr", "ios-smoke.json")}'`,
    ]);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("init and wizard reject options with missing values cleanly", () => {
  for (const [script, args, flag] of [
    ["npm/init-app.mjs", ["--dir"], "--dir"],
    ["npm/init-app.mjs", ["--app-id"], "--app-id"],
    ["npm/init-app.mjs", ["--android-shim"], "--android-shim"],
    ["npm/init-app.mjs", ["--ios-shim"], "--ios-shim"],
    ["npm/init-app.mjs", ["--expo-dev-client-scheme"], "--expo-dev-client-scheme"],
    ["npm/wizard.mjs", ["--yes", "--dir"], "--dir"],
    ["npm/wizard.mjs", ["--yes", "--app-id"], "--app-id"],
    ["npm/wizard.mjs", ["--yes", "--android-shim"], "--android-shim"],
    ["npm/wizard.mjs", ["--yes", "--ios-shim"], "--ios-shim"],
    ["npm/wizard.mjs", ["--yes", "--expo-dev-client-scheme"], "--expo-dev-client-scheme"],
  ]) {
    const result = spawnSync(process.execPath, [path.join(root, script), ...args], { encoding: "utf8" });
    assert.equal(result.status, 2, `${script} ${args.join(" ")}`);
    assert.match(result.stderr, new RegExp(`${flag} requires a value`));
    assert.doesNotMatch(result.stderr, /TypeError|Warning: Detected unsettled top-level await|at file:/);
  }
});

test("wizard checks necessities, scaffolds scenarios, and patches package scripts", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ scripts: {} }, null, 2));
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /ZMR setup wizard/);
    assert.match(result.stdout, /zmr\s+ok/);
    assert.match(result.stdout, /Next steps/);
    assert.match(result.stdout, /created \.zmr\/config\.json/);
    assert.match(result.stdout, /created \.zmr\/android-smoke\.json/);
    assert.match(result.stdout, /updated package\.json/);
    assert.doesNotMatch(result.stdout, /zmr-wizard-test-/);

    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts["zmr:doctor"], "zmr doctor --strict --json --config .zmr/config.json");
    assert.equal(pkg.scripts["zmr:schemas"], "zmr schemas --json");
    assert.equal(pkg.scripts["zmr:android"], "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android");
    assert.equal(pkg.scripts["zmr:ios"], "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios");
    assert.equal(pkg.scripts["zmr:matrix"], "ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0");

    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    const matrix = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "device-matrix.json"), "utf8"));
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    assert.equal(config.appId, "com.example.demo");
    assert.equal(config.artifacts.screenshots, true);
    assert.equal(config.artifacts.screenRecording, false);
    assert.equal(config.scripts.schemas, "zmr schemas --json");
    assert.equal(config.scripts.serve, "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent");
    assert.equal(config.scripts.mcp, "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent");
    assert.equal(
      config.scripts.pilotGate,
      "zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.demo --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.demo --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
    );
    assert.equal(config.scripts.readiness, "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json");
    assert.equal(pkg.scripts["zmr:android:reliability"], config.scripts.androidReliability);
    assert.equal(pkg.scripts["zmr:ios:reliability"], config.scripts.iosReliability);
    assert.equal(pkg.scripts["zmr:matrix"], config.scripts.matrix);
    assert.equal(pkg.scripts["zmr:pilot"], config.scripts.pilotGate);
    assert.equal(pkg.scripts["zmr:readiness"], config.scripts.readiness);
    assert.equal(pkg.scripts["zmr:schemas"], config.scripts.schemas);
    assert.equal(pkg.scripts["zmr:validate"], config.scripts.validate);
    assert.equal(pkg.scripts["zmr:serve"], config.scripts.serve);
    assert.equal(pkg.scripts["zmr:mcp"], config.scripts.mcp);
    assert.match(agentInstructions, /App id: `com\.example\.demo`/);
    assert.match(agentInstructions, /npm run zmr:doctor/);
    assert.match(agentInstructions, /npm run zmr:schemas/);
    assert.match(agentInstructions, /npm run zmr:validate/);
    assert.match(agentInstructions, /npm run zmr:serve/);
    assert.match(agentInstructions, /npm run zmr:mcp/);
    assert.match(agentInstructions, /npm run zmr:explain/);
    assert.match(agentInstructions, /npm run zmr:export/);
    assert.match(agentInstructions, /Use `recommendedWording` and keep `claimLimitations` intact/);
    assert.match(agentInstructions, /When readiness is blocked, follow `nextSteps\[\]\.commands` in order/);
    assert.match(agentInstructions, /Use `nextSteps\[\]\.covers` to map each command back to the blocked requirements it resolves/);
    assert.match(agentInstructions, /Use `satisfied` for proven requirements; do not infer readiness from raw `passed` evidence/);
    assert.match(agentInstructions, /npm run zmr:android/);
    assert.match(agentInstructions, /npm run zmr:android:reliability/);
    assert.match(agentInstructions, /npm run zmr:ios/);
    assert.match(agentInstructions, /npm run zmr:ios:reliability/);
    assert.match(agentInstructions, /npm run zmr:matrix/);
    assert.match(agentInstructions, /npm run zmr:pilot/);
    assert.match(agentInstructions, /npm run zmr:readiness/);
    assert.match(agentInstructions, /zmr discover --from-trace traces\/zmr-agent --out \.zmr\/discovered\/replay-smoke\.json --include-actions --validate --json/);
    assert.doesNotMatch(agentInstructions, /zmr run \.zmr\/android-smoke\.json --device emulator-5554/);
    assert.doesNotMatch(agentInstructions, /zmr explain traces\/zmr-agent --json/);
    assert.match(fs.readFileSync(path.join(tmp, ".gitignore"), "utf8"), /^traces\/$/m);
    assert.equal(matrix.appId, "com.example.demo");
    assert.deepEqual(matrix.devices.map((device) => device.name), ["android-emulator", "ios-simulator"]);

    const scenario = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "android-smoke.json"), "utf8"));
    assert.equal(scenario.appId, "com.example.demo");
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard without package-json emits direct agent commands and next steps", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-direct-test-"));
  try {
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(path.join(tmp, "package.json")), false);
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    assert.match(agentInstructions, /## App Commands/);
    assert.match(agentInstructions, /zmr-benchmark --zmr \.zmr\/android-smoke\.json --device emulator-5554 --app-id com\.example\.demo/);
    assert.match(agentInstructions, /zmr-benchmark --zmr \.zmr\/ios-smoke\.json --platform ios --device booted --app-id com\.example\.demo/);
    assert.match(agentInstructions, /zmr-pilot-gate --android --ios --android-app-root \. --android-app-id com\.example\.demo/);
    assert.match(agentInstructions, /zmr discover --from-trace traces\/zmr-agent --out \.zmr\/discovered\/replay-smoke\.json --include-actions --validate --json/);
    assert.doesNotMatch(agentInstructions, /npm run zmr:/);
    assert.match(result.stdout, /zmr run \.zmr\/android-smoke\.json --device emulator-5554 --trace-dir traces\/zmr-android/);
    assert.match(result.stdout, /zmr run \.zmr\/ios-smoke\.json --platform ios --device booted --trace-dir traces\/zmr-ios/);
    assert.match(result.stdout, /zmr-release-readiness --evidence traces\/zmr-pilots\/evidence\.jsonl --target production --json/);
    assert.doesNotMatch(result.stdout, /npm run zmr:/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard can emit init JSON metadata without interactive output", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-json-test-"));
  try {
    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--json",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
    ], { encoding: "utf8" });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");
    const output = JSON.parse(result.stdout);
    assert.equal(output.ok, true);
    assert.equal(output.mode, "app");
    assert.equal(output.configPath, path.join(tmp, ".zmr", "config.json"));
    assert.equal(output.next, `zmr doctor --strict --json --config ${path.join(tmp, ".zmr", "config.json")}`);
    assert.equal(output.scriptCount, 16);
    assert.deepEqual(output.nextCommands, [
      `zmr doctor --strict --json --config ${path.join(tmp, ".zmr", "config.json")}`,
      "zmr schemas --json",
      `zmr validate --json ${path.join(tmp, ".zmr", "android-smoke.json")}`,
      `zmr validate --json ${path.join(tmp, ".zmr", "ios-smoke.json")}`,
    ]);
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "AGENTS.md")));
    assert.doesNotMatch(result.stdout, /ZMR setup wizard|Checking necessities|Next steps/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard can configure an iOS shim path for selector-grade simulator runs", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-ios-shim-test-"));
  try {
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--ios",
      "--ios-shim",
      "./.zmr/ios-shim",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    assert.equal(config.tools.iosShimPath, "./.zmr/ios-shim");
    assert.equal(config.scripts.android, undefined);
    assert.equal(config.scripts.androidReliability, undefined);
    assert.equal(config.scripts.androidDevClient, undefined);
    assert.equal(config.scripts.ios, "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios --ios-shim ./.zmr/ios-shim");
    assert.equal(
      config.scripts.iosReliability,
      'export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.demo --xcrun xcrun --ios-shim ./.zmr/ios-shim --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && "$ZMR_BIN" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml',
    );
    assert.equal(
      config.scripts.pilotGate,
      "zmr-pilot-gate --ios --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.demo --ios-device booted --ios-shim ./.zmr/ios-shim --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
    );
    assert.equal(config.scripts.readiness, undefined);

    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts["zmr:ios"], config.scripts.ios);
    assert.equal(pkg.scripts["zmr:ios:reliability"], config.scripts.iosReliability);
    assert.equal(pkg.scripts["zmr:pilot"], config.scripts.pilotGate);
    assert.equal(pkg.scripts["zmr:readiness"], undefined);
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    assert.doesNotMatch(agentInstructions, /zmr-release-readiness --evidence traces\/zmr-pilots\/evidence\.jsonl --target production --json/);
    assert.doesNotMatch(agentInstructions, /npm run zmr:readiness/);
    assert.doesNotMatch(result.stdout, /zmr:readiness/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard quotes shim paths with spaces in generated package scripts", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-shim-space-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ scripts: {} }, null, 2));
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--android-shim",
      "./.zmr/android shim",
      "--ios",
      "--ios-shim",
      "./.zmr/ios shim",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(config.tools.androidShimPath, "./.zmr/android shim");
    assert.equal(config.tools.iosShimPath, "./.zmr/ios shim");
    assert.equal(config.scripts.android, "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --android-shim './.zmr/android shim'");
    assert.equal(config.scripts.ios, "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios --ios-shim './.zmr/ios shim'");
    assert.match(config.scripts.androidReliability, /--android-shim '\.\/\.zmr\/android shim'/);
    assert.match(config.scripts.iosReliability, /--ios-shim '\.\/\.zmr\/ios shim'/);
    assert.match(config.scripts.pilotGate, /--ios-shim '\.\/\.zmr\/ios shim'/);
    assert.equal(pkg.scripts["zmr:android"], config.scripts.android);
    assert.equal(pkg.scripts["zmr:ios"], config.scripts.ios);
    assert.equal(pkg.scripts["zmr:pilot"], config.scripts.pilotGate);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard can scaffold Expo dev-client open-link scenarios", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-expo-dev-client-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ scripts: {} }, null, 2));
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
      "--expo-dev-client-scheme",
      "mobiletest",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    const androidScenario = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "android-dev-client-smoke.json"), "utf8"));
    const iosScenario = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "ios-dev-client-open-link.json"), "utf8"));
    assert.equal(androidScenario.appId, "com.example.demo");
    assert.equal(iosScenario.appId, "com.example.demo");
    assert.equal(androidScenario.steps[1].url, "exp+mobiletest://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A8081");
    assert.equal(iosScenario.steps[1].url, "exp+mobiletest://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081");
    assert.equal(iosScenario.steps[2].action, "waitAny");

    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    assert.equal(config.scripts.androidDevClient, "zmr run .zmr/android-dev-client-smoke.json --device emulator-5554 --trace-dir traces/zmr-android-dev-client");
    assert.equal(config.scripts.androidDevClientReport, "zmr report traces/zmr-android-dev-client --out traces/zmr-android-dev-client/report.html --junit traces/zmr-android-dev-client/junit.xml");
    assert.equal(config.scripts.iosDevClient, "zmr run .zmr/ios-dev-client-open-link.json --platform ios --device booted --trace-dir traces/zmr-ios-dev-client");
    assert.equal(config.scripts.iosDevClientReport, "zmr report traces/zmr-ios-dev-client --out traces/zmr-ios-dev-client/report.html --junit traces/zmr-ios-dev-client/junit.xml");

    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts["zmr:android:dev-client"], config.scripts.androidDevClient);
    assert.equal(pkg.scripts["zmr:android:dev-client:report"], config.scripts.androidDevClientReport);
    assert.equal(pkg.scripts["zmr:ios:dev-client"], config.scripts.iosDevClient);
    assert.equal(pkg.scripts["zmr:ios:dev-client:report"], config.scripts.iosDevClientReport);
    assert.match(result.stdout, /zmr:android:dev-client/);
    assert.match(result.stdout, /zmr:android:dev-client:report/);
    assert.match(result.stdout, /zmr:ios:dev-client/);
    assert.match(result.stdout, /zmr:ios:dev-client:report/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard can configure an Android shim path for native instrumentation runs", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-android-shim-test-"));
  try {
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--android-shim",
      "./.zmr/android-shim",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    assert.equal(config.tools.androidShimPath, "./.zmr/android-shim");
    assert.equal(config.scripts.android, "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --android-shim ./.zmr/android-shim");
    assert.equal(
      config.scripts.androidReliability,
      'export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.demo --android-shim ./.zmr/android-shim --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && "$ZMR_BIN" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml',
    );
    assert.equal(
      config.scripts.pilotGate,
      "zmr-pilot-gate --android --android-app-root . --android-app-id com.example.demo --android-device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
    );
    assert.equal(config.scripts.ios, undefined);
    assert.equal(config.scripts.iosReliability, undefined);
    assert.equal(config.scripts.iosDevClient, undefined);
    assert.equal(config.scripts.readiness, undefined);

    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts["zmr:android"], config.scripts.android);
    assert.equal(pkg.scripts["zmr:android:reliability"], config.scripts.androidReliability);
    assert.equal(pkg.scripts["zmr:pilot"], config.scripts.pilotGate);
    assert.equal(pkg.scripts["zmr:readiness"], undefined);
    const agentInstructions = fs.readFileSync(path.join(tmp, ".zmr", "AGENTS.md"), "utf8");
    assert.doesNotMatch(agentInstructions, /zmr-release-readiness --evidence traces\/zmr-pilots\/evidence\.jsonl --target production --json/);
    assert.doesNotMatch(agentInstructions, /npm run zmr:readiness/);
    assert.doesNotMatch(result.stdout, /zmr:readiness/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard removes stale readiness script for single-platform setup", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-stale-readiness-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({
      scripts: {
        "zmr:ios": "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios",
        "zmr:ios:reliability": 'export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.demo --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && "$ZMR_BIN" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml',
        "zmr:ios:dev-client": "zmr run .zmr/ios-dev-client-open-link.json --platform ios --device booted --trace-dir traces/zmr-ios-dev-client",
        "zmr:readiness": "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json",
        "custom:test": "echo keep",
      },
    }, null, 2));
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts["zmr:ios"], undefined);
    assert.equal(pkg.scripts["zmr:ios:reliability"], undefined);
    assert.equal(pkg.scripts["zmr:ios:dev-client"], undefined);
    assert.equal(pkg.scripts["zmr:readiness"], undefined);
    assert.equal(pkg.scripts["custom:test"], "echo keep");
    assert.equal(pkg.scripts["zmr:pilot"], "zmr-pilot-gate --android --android-app-root . --android-app-id com.example.demo --android-device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl");
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard rerun refreshes generated config and matrix for selected platforms", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-rerun-config-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ scripts: {} }, null, 2));
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const first = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });
    assert.equal(first.status, 0, first.stderr);

    const second = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });
    assert.equal(second.status, 0, second.stderr);

    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    const matrix = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "device-matrix.json"), "utf8"));
    assert.equal(config.android.enabled, true);
    assert.equal(config.ios.enabled, false);
    assert.equal(config.scripts.android, "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android");
    assert.equal(config.scripts.ios, undefined);
    assert.equal(config.scripts.readiness, undefined);
    assert.deepEqual(matrix.devices.map((device) => device.name), ["android-emulator"]);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard rerun removes stale Expo dev-client scripts when scheme is omitted", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-rerun-expo-test-"));
  try {
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ scripts: {} }, null, 2));
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const first = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
      "--expo-dev-client-scheme",
      "mobiletest",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });
    assert.equal(first.status, 0, first.stderr);

    const second = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
      "--package-json",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });
    assert.equal(second.status, 0, second.stderr);

    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(config.scripts.androidDevClient, undefined);
    assert.equal(config.scripts.androidDevClientReport, undefined);
    assert.equal(config.scripts.iosDevClient, undefined);
    assert.equal(config.scripts.iosDevClientReport, undefined);
    assert.equal(pkg.scripts["zmr:android:dev-client"], undefined);
    assert.equal(pkg.scripts["zmr:android:dev-client:report"], undefined);
    assert.equal(pkg.scripts["zmr:ios:dev-client"], undefined);
    assert.equal(pkg.scripts["zmr:ios:dev-client:report"], undefined);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("wizard is tool agnostic and keeps ZMR state under .zmr", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-wizard-agnostic-test-"));
  try {
    fs.mkdirSync(path.join(tmp, `.${"maes"}tro`));
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({
      scripts: { e2e: `${"de"}tox test` },
      devDependencies: { [`${"de"}tox`]: "^20.0.0" },
    }, null, 2));
    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'zmr 0.0.0 test\\n'\n");
    fs.chmodSync(fakeBin, 0o755);

    const result = spawnSync(process.execPath, [
      path.join(root, "npm/wizard.mjs"),
      "--yes",
      "--dir",
      tmp,
      "--app-id",
      "com.example.demo",
    ], {
      env: { ...process.env, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });

    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /Detected existing mobile test setup/);
    assert.doesNotMatch(result.stdout, /migration path/i);

    const config = JSON.parse(fs.readFileSync(path.join(tmp, ".zmr", "config.json"), "utf8"));
    assert.equal(config.appId, "com.example.demo");
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "android-smoke.json")));
    assert.ok(fs.existsSync(path.join(tmp, ".zmr", "ios-smoke.json")));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
