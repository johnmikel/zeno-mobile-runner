import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import url from "node:url";
import {
  agentInstructions,
  applyPackageScripts,
  appConfig,
  devClientReportCommand,
  devClientRunCommand,
  devClientScenario,
  deviceMatrix,
  ensureTraceIgnore,
  formatWizardCheckResult,
  matrixCommand,
  nextStepCommands,
  packageScripts,
  pilotGateCommand,
  readOptionValue,
  readinessCommand,
  reliabilityCommand,
  scenarioFiles,
  scaffoldFiles,
  scaffoldPlan,
  smokeRunCommand,
  smokeScenario,
  wizardChecks,
  writeJsonFile,
  writePackageScripts,
  writeScaffoldFiles,
  writeTextFile,
} from "../npm/scaffold.mjs";

const root = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "..");
const evidenceFixtureRoot = path.join(root, "fixtures", "evidence", "v1");

function requiredConformanceFixturePaths() {
  const evidenceCases = JSON.parse(
    fs.readFileSync(path.join(evidenceFixtureRoot, "cases.json"), "utf8"),
  );
  const requiredPaths = new Set();
  for (const evidenceCase of evidenceCases) {
    if (!["manifest", "package"].includes(evidenceCase.kind)) continue;
    requiredPaths.add(path.posix.join("fixtures/evidence/v1", evidenceCase.input));
    if (evidenceCase.kind !== "package") continue;

    const manifest = JSON.parse(
      fs.readFileSync(path.join(evidenceFixtureRoot, ...evidenceCase.input.split("/")), "utf8"),
    );
    const packageFixtureDirectory = path.posix.dirname(evidenceCase.input);
    for (const item of manifest.items) {
      for (const artifact of item.artifacts) {
        requiredPaths.add(path.posix.join(
          "fixtures/evidence/v1",
          packageFixtureDirectory,
          artifact.path,
        ));
      }
    }
  }
  return [...requiredPaths].sort();
}

function assertConformanceFixturesPublished(publishedPaths) {
  const published = new Set(publishedPaths);
  for (const requiredPath of requiredConformanceFixturePaths()) {
    assert.ok(
      published.has(requiredPath),
      `missing conformance fixture from package: ${requiredPath}`,
    );
  }
}

test("conformance package publication requires referenced artifact bytes", () => {
  const requiredPaths = requiredConformanceFixturePaths();
  const mismatchArtifact = "fixtures/evidence/v1/invalid/artifact-digest-mismatch/artifacts/actual.txt";
  assert.ok(requiredPaths.includes(mismatchArtifact));
  assert.throws(
    () => assertConformanceFixturesPublished(
      requiredPaths.filter((publishedPath) => publishedPath !== mismatchArtifact),
    ),
    /missing conformance fixture from package: .*artifact-digest-mismatch\/artifacts\/actual\.txt/,
  );
});

test("package test script builds zmr before client examples need the binary", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  assert.match(pkg.scripts.test, /^npm run build:zmr && /);
  assert.equal(pkg.dependencies, undefined);
  assert.equal(fs.existsSync(path.join(root, "package-lock.json")), false);
  assert.equal(
    pkg.scripts["test:evidence"],
    "node --test tests/evidence-contract.test.mjs tests/evidence-package.test.mjs tests/evidence-conformance.test.mjs tests/evidence-json-schema-conformance.test.mjs tests/evidence-zmr-adapter.test.mjs tests/evidence-cli.test.mjs tests/evidence-playwright-reporter.test.mjs",
  );
  assert.match(pkg.scripts.test, /^npm run build:zmr && npm run test:evidence && node --test /);
});

test("scaffold helpers centralize generated app commands and scenarios", () => {
  const config = appConfig("com.example.demo", {
    android: true,
    ios: true,
    androidShim: "./.zmr/android shim",
    iosShim: "./.zmr/ios shim",
  });
  assert.equal(config.schemaVersion, 1);
  assert.equal(config.appId, "com.example.demo");
  assert.equal(config.android.enabled, true);
  assert.equal(config.ios.enabled, true);
  assert.equal(config.tools.androidShimPath, "./.zmr/android shim");
  assert.equal(config.tools.iosShimPath, "./.zmr/ios shim");
  assert.equal(config.scripts.android, "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --ensure-device --android-shim './.zmr/android shim'");
  assert.equal(config.scripts.readiness, readinessCommand());
  assert.equal(packageScripts(config)["zmr:readiness"], readinessCommand());
  assert.deepEqual(wizardChecks({ android: true, ios: false, nodePath: "/usr/bin/node", zmrPath: "/tmp/zmr" }), [
    { label: "node", command: "/usr/bin/node", args: ["--version"], required: true },
    { label: "zmr", command: "/tmp/zmr", args: ["version"], required: true },
    { label: "adb", command: "adb", args: ["version"], required: false },
    { label: "zig", command: "zig", args: ["version"], required: false },
  ]);
  assert.deepEqual(wizardChecks({ android: false, ios: true, nodePath: "/usr/bin/node", zmrPath: "" }).map((check) => check.label), [
    "node",
    "zmr",
    "xcrun",
    "zig",
  ]);
  assert.equal(formatWizardCheckResult("node", { status: 0, stdout: "v24.6.0\n" }, { required: true }), "node\tok\tv24.6.0");
  assert.equal(formatWizardCheckResult("xcrun", { status: 0, stdout: "", stderr: "xcrun version 70\nextra\n" }, { required: false }), "xcrun\tok\txcrun version 70");
  assert.equal(formatWizardCheckResult("adb", { status: 127, error: { message: "spawn adb ENOENT" } }, { required: false }), "adb\twarning\tspawn adb ENOENT");
  assert.equal(formatWizardCheckResult("zmr", { status: 1 }, { required: true }), "zmr\tmissing\texit 1");
  assert.equal(smokeRunCommand({ platform: "android", androidShim: "./.zmr/android shim" }), config.scripts.android);
  assert.equal(smokeRunCommand({ platform: "ios", iosShim: "./.zmr/ios shim" }), config.scripts.ios);

  const singlePlatformConfig = appConfig("com.example.demo", { android: true, ios: false });
  assert.equal(singlePlatformConfig.scripts.ios, undefined);
  assert.equal(singlePlatformConfig.scripts.readiness, undefined);
  assert.equal(packageScripts(singlePlatformConfig)["zmr:readiness"], undefined);

  const packageJson = applyPackageScripts(
    {
      scripts: {
        test: "vitest",
        "zmr:ios": "stale ios",
        "zmr:ios:report": "stale ios report",
        "zmr:ios:dev-client": "stale ios dev-client",
        "zmr:readiness": "stale readiness",
      },
    },
    singlePlatformConfig,
    { android: true, ios: false },
  );
  assert.equal(packageJson.scripts.test, "vitest");
  assert.equal(packageJson.scripts["zmr:android"], singlePlatformConfig.scripts.android);
  assert.equal(packageJson.scripts["zmr:android:report"], singlePlatformConfig.scripts.androidReport);
  assert.equal(packageJson.scripts["zmr:android:reliability"], singlePlatformConfig.scripts.androidReliability);
  assert.equal(packageJson.scripts["zmr:ios"], undefined);
  assert.equal(packageJson.scripts["zmr:ios:report"], undefined);
  assert.equal(packageJson.scripts["zmr:ios:dev-client"], undefined);
  assert.equal(packageJson.scripts["zmr:readiness"], undefined);

  const devClientConfig = appConfig("com.example.demo", { android: true, ios: true });
  devClientConfig.scripts.androidDevClient = devClientRunCommand({ platform: "android" });
  devClientConfig.scripts.iosDevClient = devClientRunCommand({ platform: "ios" });
  const devClientPackageJson = applyPackageScripts({ name: "demo" }, devClientConfig, { android: true, ios: true });
  assert.equal(devClientPackageJson.name, "demo");
  assert.equal(devClientPackageJson.scripts["zmr:android:dev-client"], devClientConfig.scripts.androidDevClient);
  assert.equal(devClientPackageJson.scripts["zmr:ios:dev-client"], devClientConfig.scripts.iosDevClient);
  assert.equal(devClientPackageJson.scripts["zmr:readiness"], devClientConfig.scripts.readiness);

  const expoConfig = appConfig("com.example.demo", { android: true, ios: true, expoDevClientScheme: "mobiletest" });
  assert.equal(expoConfig.scripts.androidDevClient, devClientRunCommand({ platform: "android" }));
  assert.equal(expoConfig.scripts.androidDevClientReport, devClientReportCommand({ platform: "android" }));
  assert.equal(expoConfig.scripts.iosDevClient, devClientRunCommand({ platform: "ios" }));
  assert.equal(expoConfig.scripts.iosDevClientReport, devClientReportCommand({ platform: "ios" }));
  assert.deepEqual(nextStepCommands(expoConfig, {
    android: true,
    ios: true,
    packageScripts: true,
  }).map((step) => step.command), [
    "npm run zmr:android",
    "npm run zmr:android:report",
    "npm run zmr:android:dev-client",
    "npm run zmr:android:dev-client:report",
    "npm run zmr:android:reliability",
    "npm run zmr:ios",
    "npm run zmr:ios:report",
    "npm run zmr:ios:dev-client",
    "npm run zmr:ios:dev-client:report",
    "npm run zmr:ios:reliability",
    "npm run zmr:matrix",
    "npm run zmr:pilot",
    "npm run zmr:readiness",
    "npm run zmr:serve",
    "npm run zmr:mcp",
    "npm run zmr:explain",
    "npm run zmr:export",
    "npm run zmr:schemas",
    "npm run zmr:validate",
    "npm run zmr:doctor",
  ]);

  const iosExpoConfig = appConfig("com.example.demo", { android: false, ios: true, expoDevClientScheme: "mobiletest" });
  assert.equal(iosExpoConfig.scripts.androidDevClient, undefined);
  assert.equal(iosExpoConfig.scripts.iosDevClient, devClientRunCommand({ platform: "ios" }));
  assert.equal(iosExpoConfig.scripts.iosDevClientReport, devClientReportCommand({ platform: "ios" }));
  assert.deepEqual(nextStepCommands(iosExpoConfig, {
    android: false,
    ios: true,
    packageScripts: false,
  }).map((step) => step.command), [
    iosExpoConfig.scripts.ios,
    iosExpoConfig.scripts.iosReport,
    iosExpoConfig.scripts.iosDevClient,
    iosExpoConfig.scripts.iosDevClientReport,
    iosExpoConfig.scripts.iosReliability,
    iosExpoConfig.scripts.matrix,
    iosExpoConfig.scripts.pilotGate,
    iosExpoConfig.scripts.serve,
    iosExpoConfig.scripts.mcp,
    iosExpoConfig.scripts.explain,
    iosExpoConfig.scripts.exportTrace,
    iosExpoConfig.scripts.schemas,
    iosExpoConfig.scripts.validate,
    iosExpoConfig.scripts.doctor,
  ]);
  assert.equal(readOptionValue(["--dir", "app"], 1, "--dir"), "app");
  assert.throws(() => readOptionValue(["--dir"], 1, "--dir"), /--dir requires a value/);
  assert.throws(() => readOptionValue(["--dir", "--app-id"], 1, "--dir"), /--dir requires a value/);

  assert.equal(
    pilotGateCommand({ android: true, ios: true, appId: "com.example.demo", iosShim: "./.zmr/ios shim" }),
    "zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.demo --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.demo --ios-device booted --ios-shim './.zmr/ios shim' --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
  );
  assert.equal(
    reliabilityCommand({
      scenario: ".zmr/ios-smoke.json",
      platform: "ios",
      device: "booted",
      appId: "com.example.demo",
      xcrun: "xcrun",
      iosShim: "./.zmr/ios shim",
      traceRoot: "traces/zmr-ios-reliability",
      maxP95Ms: 45000,
    }),
    'export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.demo --xcrun xcrun --ios-shim \'./.zmr/ios shim\' --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && "$ZMR_BIN" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html --junit traces/zmr-ios-reliability/junit.xml',
  );
  assert.equal(matrixCommand(), "ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0");
  assert.equal(readinessCommand(), "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json");
  assert.deepEqual(smokeScenario("Android smoke", "com.example.demo").steps, [
    { action: "launch" },
    { action: "assertHealthy" },
    { action: "snapshot" },
  ]);
  const devClient = devClientScenario("iOS Expo dev-client open-link smoke", "com.example.demo", "mobiletest", "http://127.0.0.1:8081");
  assert.equal(devClient.steps[1].url, "exp+mobiletest://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081");
  // Waiting for the launcher's persistent marker to be GONE proves the deep
  // link navigated; transient loading overlays and launcher-ambiguous tokens
  // ("Home", "Continue", "Sign in") previously produced false greens or false
  // timeouts. "evelopment servers" covers both case-sensitive spellings.
  assert.deepEqual(devClient.steps[2], {
    action: "waitNotVisible",
    selector: { textContains: "evelopment servers" },
    timeoutMs: 120000,
  });
  assert.deepEqual(devClient.steps[3], {
    action: "assertNoneVisible",
    selectors: [
      { textContains: "Unable to load" },
      { textContains: "There was a problem loading" },
    ],
  });
  assert.deepEqual(devClient.steps.map((step) => step.action), [
    "stop",
    "openLink",
    "waitNotVisible",
    "assertNoneVisible",
    "assertHealthy",
    "snapshot",
  ]);
  assert.equal(devClientRunCommand({ platform: "android" }), "zmr run .zmr/android-dev-client-smoke.json --device emulator-5554 --trace-dir traces/zmr-android-dev-client --ensure-device");
  assert.equal(devClientRunCommand({ platform: "ios" }), "zmr run .zmr/ios-dev-client-open-link.json --platform ios --device booted --trace-dir traces/zmr-ios-dev-client --ensure-device");
  assert.deepEqual(scenarioFiles("com.example.demo", { android: true, ios: true }).map((file) => file.path), [
    "android-smoke.json",
    "ios-smoke.json",
  ]);
  const expoScenarioFiles = scenarioFiles("com.example.demo", {
    android: true,
    ios: true,
    expoDevClientScheme: "mobiletest",
  });
  assert.deepEqual(expoScenarioFiles.map((file) => file.path), [
    "android-smoke.json",
    "ios-smoke.json",
    "android-dev-client-smoke.json",
    "ios-dev-client-open-link.json",
  ]);
  assert.equal(expoScenarioFiles[2].scenario.steps[1].url, "exp+mobiletest://expo-development-client/?url=http%3A%2F%2F10.0.2.2%3A8081");
  assert.equal(expoScenarioFiles[3].scenario.steps[1].url, "exp+mobiletest://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081");
  assert.deepEqual(scenarioFiles("com.example.demo", { android: false, ios: true }).map((file) => file.path), [
    "ios-smoke.json",
  ]);
  const scaffold = scaffoldFiles("com.example.demo", {
    android: true,
    ios: true,
    androidShim: "./.zmr/android shim",
    iosShim: "./.zmr/ios shim",
    expoDevClientScheme: "mobiletest",
    packageScripts: true,
  });
  assert.deepEqual(scaffold.map((file) => [file.kind, file.path, file.overwrite]), [
    ["json", "config.json", true],
    ["json", "android-smoke.json", false],
    ["json", "ios-smoke.json", false],
    ["json", "android-dev-client-smoke.json", false],
    ["json", "ios-dev-client-open-link.json", false],
    ["json", "device-matrix.json", true],
    ["text", "AGENTS.md", true],
  ]);
  const scaffoldConfig = scaffold.find((file) => file.path === "config.json").value;
  assert.equal(scaffoldConfig.scripts.androidDevClient, devClientRunCommand({ platform: "android" }));
  assert.match(scaffold.find((file) => file.path === "AGENTS.md").value, /npm run zmr:android:dev-client/);
  assert.match(scaffold.find((file) => file.path === "AGENTS.md").value, /zmr explore --from-trace traces\/zmr-agent/);
  assert.match(scaffold.find((file) => file.path === "AGENTS.md").value, /--goal "find a stable login smoke"/);
  assert.equal(scaffold.find((file) => file.path === "device-matrix.json").value.devices[0].androidShim, "./.zmr/android shim");
  const plan = scaffoldPlan("com.example.demo", { android: true, ios: false, androidShim: "./.zmr/android shim" });
  assert.equal(plan.config.appId, "com.example.demo");
  assert.equal(plan.config.android.enabled, true);
  assert.equal(plan.config.ios.enabled, false);
  assert.equal(plan.files.find((file) => file.path === "config.json").value, plan.config);
  assert.deepEqual(plan.files.map((file) => file.path), [
    "config.json",
    "android-smoke.json",
    "device-matrix.json",
    "AGENTS.md",
  ]);
  assert.deepEqual(deviceMatrix("com.example.demo", true, false).devices.map((device) => device.name), ["android-emulator"]);

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-trace-ignore-test-"));
  try {
    assert.equal(ensureTraceIgnore(tmp, { cwd: tmp }), ".gitignore");
    assert.match(fs.readFileSync(path.join(tmp, ".gitignore"), "utf8"), /# ZMR local run artifacts\ntraces\/\n$/);
    assert.equal(ensureTraceIgnore(tmp, { cwd: tmp }), null);
    assert.deepEqual(writeJsonFile(path.join(tmp, "config.json"), { ok: true }, { cwd: tmp }), {
      path: "config.json",
      status: "created",
    });
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(tmp, "config.json"), "utf8")), { ok: true });
    assert.equal(writeJsonFile(path.join(tmp, "config.json"), { ok: false }, { cwd: tmp }), null);
    assert.deepEqual(writeJsonFile(path.join(tmp, "config.json"), { ok: false }, { overwrite: true, cwd: tmp }), {
      path: "config.json",
      status: "updated",
    });
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(tmp, "config.json"), "utf8")), { ok: false });
    assert.deepEqual(writeTextFile(path.join(tmp, "AGENTS.md"), "hello\n", { cwd: tmp }), {
      path: "AGENTS.md",
      status: "created",
    });
    assert.equal(writeTextFile(path.join(tmp, "AGENTS.md"), "ignored\n", { cwd: tmp }), null);
    assert.deepEqual(writeScaffoldFiles(tmp, [
      { kind: "json", path: "generated/config.json", value: { ok: true }, overwrite: true },
      { kind: "text", path: "generated/AGENTS.md", value: "agent notes\n", overwrite: true },
    ], { cwd: tmp }), [
      { path: "generated/config.json", status: "created" },
      { path: "generated/AGENTS.md", status: "created" },
    ]);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(tmp, "generated", "config.json"), "utf8")), { ok: true });
    assert.equal(fs.readFileSync(path.join(tmp, "generated", "AGENTS.md"), "utf8"), "agent notes\n");
    assert.deepEqual(writeScaffoldFiles(tmp, [
      { kind: "json", path: "generated/config.json", value: { ok: false }, overwrite: false },
      { kind: "text", path: "generated/AGENTS.md", value: "ignored\n", overwrite: false },
    ], { cwd: tmp }), []);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(tmp, "generated", "config.json"), "utf8")), { ok: true });
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({
      name: "demo",
      scripts: {
        test: "vitest",
        "zmr:ios": "stale ios",
        "zmr:readiness": "stale readiness",
      },
    }, null, 2));
    assert.deepEqual(writePackageScripts(tmp, singlePlatformConfig, { android: true, ios: false, cwd: tmp }), {
      path: "package.json",
      status: "updated",
    });
    const patchedPackage = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(patchedPackage.name, "demo");
    assert.equal(patchedPackage.scripts.test, "vitest");
    assert.equal(patchedPackage.scripts["zmr:android"], singlePlatformConfig.scripts.android);
    assert.equal(patchedPackage.scripts["zmr:ios"], undefined);
    assert.equal(patchedPackage.scripts["zmr:readiness"], undefined);

    const newPackageRoot = path.join(tmp, "new-package");
    assert.deepEqual(writePackageScripts(newPackageRoot, singlePlatformConfig, { android: true, ios: false, cwd: tmp }), {
      path: "new-package/package.json",
      status: "created",
    });
    const createdPackage = JSON.parse(fs.readFileSync(path.join(newPackageRoot, "package.json"), "utf8"));
    assert.equal(createdPackage.scripts["zmr:doctor"], singlePlatformConfig.scripts.doctor);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("setup helper module exposes CLI bootstrap utilities", async () => {
  const setup = await import(url.pathToFileURL(path.join(root, "npm", "setup.mjs")));

  assert.equal(setup.readOptionValue(["--dir", "app"], 1, "--dir"), "app");
  assert.equal(setup.formatWizardCheckResult("zmr", { status: 1 }, { required: true }), "zmr\tmissing\texit 1");
  assert.deepEqual(setup.wizardChecks({ android: false, ios: true, nodePath: "/node", zmrPath: "/zmr" }).map((check) => check.label), [
    "node",
    "zmr",
    "xcrun",
    "zig",
  ]);
});

test("package exposes zmr bin and public files for npm publishing", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));

  assert.equal(pkg.name, "zeno-mobile-runner");
  assert.equal(pkg.description, "Agent-native mobile app test runner for React Native, Expo, Flutter, and native Android/iOS.");
  assert.equal(pkg.repository.type, "git");
  assert.match(pkg.repository.url, /^git\+https:\/\/github\.com\/johnmikel\/zeno-mobile-runner\.git$/);
  assert.match(pkg.homepage, /^https:\/\/github\.com\/johnmikel\/zeno-mobile-runner#readme$/);
  assert.match(pkg.bugs.url, /^https:\/\/github\.com\/johnmikel\/zeno-mobile-runner\/issues$/);
  assert.equal(pkg.bin.zmr, "npm/zmr.mjs");
  assert.equal(pkg.bin["zmr-evidence"], "npm/evidence-cli.mjs");
  assert.equal(pkg.bin["zmr-benchmark"], "scripts/benchmark.sh");
  assert.equal(pkg.bin["zmr-benchmark-lab"], "scripts/benchmark-lab.py");
  assert.equal(pkg.bin["zmr-benchmark-command"], "scripts/benchmark-command.sh");
  assert.equal(pkg.bin["zmr-compare-benchmarks"], "scripts/compare-benchmarks.py");
  assert.equal(pkg.bin["zmr-device-matrix"], "scripts/device-matrix.sh");
  assert.equal(pkg.bin["zmr-pilot-gate"], "scripts/pilot-gate.sh");
  assert.equal(pkg.bin["zmr-assert-ios-physical-ready"], "scripts/assert-ios-physical-ready.sh");
  assert.equal(pkg.bin["zmr-install-android-shim"], "scripts/install-android-shim.sh");
  assert.equal(pkg.bin["zmr-install-ios-shim"], "scripts/install-ios-shim.sh");
  assert.equal(pkg.bin["zmr-release-readiness"], "scripts/release-readiness.sh");
  assert.equal(pkg.bin["zmr-create-android-demo-app"], "scripts/create-android-demo-app.sh");
  assert.equal(pkg.bin["zmr-create-ios-demo-app"], "scripts/create-ios-demo-app.sh");
  assert.equal(pkg.bin["zmr-create-react-native-expo-demo-app"], "scripts/create-react-native-expo-demo-app.sh");
  assert.equal(pkg.bin["zmr-demo-android"], "scripts/demo-android-real.sh");
  assert.equal(pkg.bin["zmr-demo-ios"], "scripts/demo-ios-real.sh");
  assert.equal(Object.hasOwn(pkg.bin, "zmr-release-candidate"), false);
  assert.equal(pkg.main, "npm/index.mjs");
  assert.ok(pkg.keywords.includes("react-native"));
  assert.ok(pkg.keywords.includes("flutter"));
  assert.ok(pkg.keywords.includes("expo"));
  assert.ok(pkg.keywords.includes("mobile-automation"));
  assert.ok(pkg.keywords.includes("ai-testing"));
  assert.equal(pkg.keywords.includes("zig"), false);
  assert.ok(pkg.files.includes("npm/"));
  assert.ok(pkg.files.includes("fixtures/evidence/"));
  assert.ok(pkg.files.includes("clients/README.md"));
  assert.ok(pkg.files.includes("clients/typescript/"));
  assert.ok(pkg.files.includes("clients/python/zmr_client.py"));
  assert.ok(pkg.files.includes("clients/python/pyproject.toml"));
  assert.ok(pkg.files.includes("clients/go/"));
  assert.ok(pkg.files.includes("clients/rust/Cargo.toml"));
  assert.ok(pkg.files.includes("clients/rust/src/"));
  assert.ok(pkg.files.includes("clients/rust/examples/"));
  assert.ok(pkg.files.includes("clients/swift/Package.swift"));
  assert.ok(pkg.files.includes("clients/swift/Sources/"));
  assert.ok(pkg.files.includes("clients/kotlin/build.gradle.kts"));
  assert.ok(pkg.files.includes("clients/kotlin/src/"));
  assert.ok(pkg.files.includes("src/"));
  assert.ok(pkg.files.includes("examples/"));
  assert.ok(pkg.files.includes("skills/"));
  assert.ok(pkg.files.includes("shims/"));
  assert.ok(pkg.files.includes("FEATURES.md"));
  assert.equal(pkg.scripts.prepublishOnly, "node npm/verify-publish.mjs");
  assert.equal(pkg.scripts["zmr:demo"], "node npm/zmr.mjs validate examples/demo-fake.json");
  assert.deepEqual(pkg.exports, {
    ".": "./npm/index.mjs",
    "./playwright-reporter": {
      types: "./npm/evidence/playwright-reporter.d.ts",
      import: "./npm/evidence/playwright-reporter.mjs",
      default: "./npm/evidence/playwright-reporter.mjs",
    },
    "./evidence": "./npm/evidence/contract.mjs",
    "./schemas/*": "./schemas/*",
    "./*": "./*",
  });
  assert.deepEqual(pkg.peerDependencies, { "@playwright/test": ">=1.42.0" });
  assert.deepEqual(pkg.peerDependenciesMeta, { "@playwright/test": { optional: true } });
  assert.equal(pkg.dependencies, undefined);
  assert.equal(fs.existsSync(path.join(root, "package-lock.json")), false);
  assert.equal(fs.existsSync(path.join(root, "npm", "evidence", "playwright-reporter.d.ts")), true);
  assert.equal(fs.existsSync(path.join(root, "examples", "playwright-zeno-reporter.config.ts")), true);
  assert.equal(fs.existsSync(path.join(root, "examples", "playwright-zeno-journey.spec.ts")), true);
});

test("npm package excludes internal tests caches traces and build outputs", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-pack-surface-test-"));
  let result;
  try {
    result = spawnSync("npm", ["pack", "--dry-run", "--json"], {
      cwd: root,
      env: { ...process.env, npm_config_cache: path.join(tmp, ".npm-cache") },
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  const [pack] = JSON.parse(result.stdout);
  const paths = pack.files.map((file) => file.path);
  const forbidden = [
    /^tests\//,
    /^traces\//,
    /^dist\//,
    /^zig-cache\//,
    /^zig-out\//,
    /^\.zig-cache\//,
    /^scripts\/__pycache__\//,
    /^scripts\/_cod[e]x_write_test\.txt$/,
    /^scripts\/python_redirect_test\.txt$/,
    /^scripts\/verify-release-version\.sh$/,
    /^tests\/__pycache__\//,
    /(^|\/)__pycache__\//,
    /\.pyc$/,
    /^src\/.*_tests\.zig$/,
    /^clients\/go\/.*_test\.go$/,
    /^clients\/kotlin\/src\/test\//,
    /^clients\/swift\/Tests\//,
    /^docs\/publication\.md$/,
    /^docs\/release-audit\.md$/,
    /^docs\/release-candidate\.md$/,
    /^docs\/release-evidence\.md$/,
    /^docs\/release-notes-template\.md$/,
    /^docs\/market-positioning\.md$/,
    /^docs\/roadmap\.md$/,
    /^docs\/shipping\.md$/,
    /^docs\/dsl\.md$/,
  ];

  for (const filePath of paths) {
    for (const pattern of forbidden) {
      assert.doesNotMatch(filePath, pattern, `unexpected package file: ${filePath}`);
    }
  }

  assert.ok(paths.includes("src/main.zig"));
  assert.ok(paths.includes("npm/evidence-cli.mjs"));
  assert.ok(paths.includes("npm/evidence/contract.mjs"));
  assert.ok(paths.includes("npm/evidence/playwright-reporter.mjs"));
  assert.ok(paths.includes("npm/evidence/playwright-reporter.d.ts"));
  assert.ok(paths.includes("schemas/evidence-v1.schema.json"));
  assert.ok(paths.includes("fixtures/evidence/v1/README.md"));
  assert.ok(paths.includes("fixtures/evidence/v1/cases.json"));
  assertConformanceFixturesPublished(paths);
  assert.ok(paths.includes("examples/playwright-zeno-reporter.config.ts"));
  assert.ok(paths.includes("examples/playwright-zeno-journey.spec.ts"));
  assert.ok(paths.includes("docs/evidence-contract.md"));
  assert.ok(paths.includes("docs/frameworks.md"));
  assert.ok(paths.includes("docs/expo-smoke.md"));
  assert.ok(paths.includes("docs/production-readiness.md"));
  assert.ok(paths.includes("docs/agent-discovery.md"));
  assert.ok(paths.includes("docs/scenario-authoring.md"));
  assert.ok(paths.includes("clients/go/zmr/client.go"));
  assert.ok(paths.includes("clients/kotlin/src/main/kotlin/dev/zmr/ZmrClient.kt"));
  assert.ok(paths.includes("clients/swift/Sources/ZMRClient/ZMRClient.swift"));
});

test("packed Playwright reporter package preserves root, subpath, and wildcard imports", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-playwright-pack-import-"));
  try {
    const npmEnv = {
      ...process.env,
      npm_config_cache: path.join(tmp, ".npm-cache"),
      npm_config_audit: "false",
      npm_config_fund: "false",
    };
    const pack = spawnSync("npm", ["pack", "--pack-destination", tmp], {
      cwd: root,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(pack.status, 0, pack.stderr);
    const tarball = fs.readdirSync(tmp).find((name) => name.endsWith(".tgz"));
    assert.ok(tarball);
    const appDir = path.join(tmp, "consumer");
    fs.mkdirSync(appDir);
    fs.writeFileSync(path.join(appDir, "package.json"), JSON.stringify({
      name: "zmr-playwright-import-smoke",
      private: true,
      type: "module",
    }));
    const install = spawnSync("npm", [
      "install",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      path.join(tmp, tarball),
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(install.status, 0, install.stderr);
    const importSmoke = spawnSync(process.execPath, [
      "--input-type=module",
      "--eval",
      [
        "await import('zeno-mobile-runner')",
        "const reporter = await import('zeno-mobile-runner/playwright-reporter')",
        "if (typeof reporter.default !== 'function') throw new Error('missing reporter')",
        "await import('zeno-mobile-runner/evidence')",
        "await import('zeno-mobile-runner/npm/evidence/canonical-json.mjs')",
      ].join(";"),
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(importSmoke.status, 0, importSmoke.stderr);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("npm prebuild packer respects release version overrides", () => {
  const script = fs.readFileSync(path.join(root, "scripts", "build-npm-package.sh"), "utf8");

  assert.match(script, /VERSION="\$\{ZMR_VERSION:-/);
  assert.match(script, /zmr-\$VERSION-\$target\/zmr/);
});

test("shipped language-client package metadata matches the runner prerelease", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const typescriptPkg = JSON.parse(fs.readFileSync(path.join(root, "clients", "typescript", "package.json"), "utf8"));
  const rustManifest = fs.readFileSync(path.join(root, "clients", "rust", "Cargo.toml"), "utf8");
  const pythonManifest = fs.readFileSync(path.join(root, "clients", "python", "pyproject.toml"), "utf8");
  const kotlinBuild = fs.readFileSync(path.join(root, "clients", "kotlin", "build.gradle.kts"), "utf8");
  const features = fs.readFileSync(path.join(root, "FEATURES.md"), "utf8");

  assert.equal(typescriptPkg.version, pkg.version);
  assert.match(rustManifest, new RegExp(`^version = "${pkg.version}"$`, "m"));
  assert.match(pythonManifest, new RegExp(`^version = "${pkg.version.replaceAll(".", "\\.")}\\.dev1"$`, "m"));
  assert.match(kotlinBuild, new RegExp(`^version = "${pkg.version}"$`, "m"));
  // Guard against docs drifting to an ambiguous "0.2.17-dev" without the numeric suffix.
  assert.doesNotMatch(features, /0\.1\.1-dev(?!\.\d)/);
  assert.match(features, new RegExp(pkg.version.replaceAll(".", "\\.")));
});

test("node API resolves environment binary and runs zmr", async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-npm-test-"));
  const fakeBin = path.join(tmp, "zmr");
  fs.writeFileSync(fakeBin, "#!/usr/bin/env sh\nprintf 'fake-zmr %s\\n' \"$*\"\n");
  fs.chmodSync(fakeBin, 0o755);

  const previous = process.env.ZMR_BIN;
  process.env.ZMR_BIN = fakeBin;
  try {
    const api = await import(url.pathToFileURL(path.join(root, "npm/index.mjs")));
    assert.equal(api.resolveBinary(), fakeBin);
    const result = spawnSync(process.execPath, [path.join(root, "npm/zmr.mjs"), "version"], {
      env: { ...process.env, ZMR_BIN: fakeBin },
      encoding: "utf8",
    });
    assert.equal(result.status, 0);
    assert.match(result.stdout, /fake-zmr version/);
  } finally {
    if (previous == null) delete process.env.ZMR_BIN;
    else process.env.ZMR_BIN = previous;
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("packed npm package postinstall builds a runnable zmr binary", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-packed-postinstall-test-"));
  const npmEnv = { ...process.env, npm_config_cache: path.join(tmp, ".npm-cache") };
  try {
    const pack = spawnSync("npm", ["pack", "--pack-destination", tmp], {
      cwd: root,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(pack.status, 0, pack.stderr);
    const tarball = fs.readdirSync(tmp).find((name) => name.endsWith(".tgz"));
    assert.ok(tarball, "npm pack should create a tarball");

    const appDir = path.join(tmp, "app");
    fs.mkdirSync(appDir);
    fs.writeFileSync(path.join(appDir, "package.json"), JSON.stringify({ private: true }, null, 2));
    const install = spawnSync("npm", ["install", path.join(tmp, tarball)], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(install.status, 0, install.stderr + install.stdout);

    const version = spawnSync("npx", ["zmr", "version", "--json"], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(version.status, 0, version.stderr + version.stdout);
    assert.equal(JSON.parse(version.stdout).version, "0.2.17");
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("agent instruction fallback commands respect selected platforms", () => {
  const iosOnly = agentInstructions("com.example.demo", { android: false, ios: true });
  assert.match(iosOnly, /## App Commands/);
  assert.match(iosOnly, /zmr inspect --json --dir \./);
  assert.match(iosOnly, /zmr explore --from-trace traces\/zmr-agent --out \.zmr\/discovered\/login-smoke\.json --goal "find a stable login smoke" --include-actions --validate --json/);
  assert.match(iosOnly, /autonomous:false/);
  assert.match(iosOnly, /reviewRequired:true/);
  assert.match(iosOnly, /zmr run \.zmr\/ios-smoke\.json --platform ios --device booted --trace-dir traces\/zmr-ios/);
  assert.match(iosOnly, /zmr-pilot-gate --ios --ios-app-root \. --ios-app-path \.\/build\/Debug-iphonesimulator\/Sample\.app --ios-app-id com\.example\.demo --ios-device booted/);
  assert.doesNotMatch(iosOnly, /--android/);
  assert.doesNotMatch(iosOnly, /android-smoke/);
  assert.doesNotMatch(iosOnly, /zmr-release-readiness --evidence traces\/zmr-pilots\/evidence\.jsonl --target production --json/);

  const androidOnly = agentInstructions("com.example.demo", { android: true, ios: false });
  assert.match(androidOnly, /zmr-pilot-gate --android --android-app-root \. --android-app-id com\.example\.demo --android-device emulator-5554/);
  assert.doesNotMatch(androidOnly, /--ios/);
  assert.doesNotMatch(androidOnly, /ios-smoke/);
});

test("packed npm package installs in a temp app and drives zmr through .zmr", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-packed-install-test-"));
  const npmEnv = { ...process.env, npm_config_cache: path.join(tmp, ".npm-cache") };
  try {
    const pack = spawnSync("npm", ["pack", "--pack-destination", tmp], {
      cwd: root,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(pack.status, 0, pack.stderr);
    const tarball = fs.readdirSync(tmp).find((name) => name.endsWith(".tgz"));
    assert.ok(tarball, "npm pack should create a tarball");
    const tarList = spawnSync("tar", ["-tf", path.join(tmp, tarball)], { encoding: "utf8" });
    assert.equal(tarList.status, 0, tarList.stderr);
    assert.match(tarList.stdout, /package\/scripts\/benchmark_gate\.py/);
    assert.match(tarList.stdout, /package\/scripts\/benchmark-command\.sh/);
    assert.match(tarList.stdout, /package\/scripts\/pilot-gate\.sh/);
    assert.match(tarList.stdout, /package\/scripts\/release-readiness\.sh/);
    assert.doesNotMatch(tarList.stdout, /package\/scripts\/release-candidate\.sh/);
    assert.doesNotMatch(tarList.stdout, /package\/scripts\/release-gate\.sh/);
    assert.doesNotMatch(tarList.stdout, /package\/scripts\/build-release\.sh/);
    assert.doesNotMatch(tarList.stdout, /package\/scripts\/verify-release-artifacts\.sh/);
    assert.doesNotMatch(tarList.stdout, /package\/scripts\/sign-macos-release\.sh/);
    assert.doesNotMatch(tarList.stdout, /package\/scripts\/notarize-macos-release\.sh/);
    assert.match(tarList.stdout, /package\/schemas\/release-manifest\.schema\.json/);
    assert.match(tarList.stdout, /package\/schemas\/inspect-output\.schema\.json/);
    assert.match(tarList.stdout, /package\/schemas\/discover-output\.schema\.json/);
    assert.match(tarList.stdout, /package\/schemas\/explore-output\.schema\.json/);
    assert.match(tarList.stdout, /package\/schemas\/draft-output\.schema\.json/);
    assert.match(tarList.stdout, /package\/clients\/README\.md/);
    assert.match(tarList.stdout, /package\/skills\/zmr-mobile-testing\/SKILL\.md/);
    assert.match(tarList.stdout, new RegExp("package/docs/benchmarks/2026-06-09-ios-app" + "ium-comparison.md"));
    assert.match(tarList.stdout, new RegExp("package/docs/benchmarks/2026-06-09-ios-app" + "ium-comparison.results.jsonl"));
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/2026-06-09-ios-workflow-comparison\.md/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/2026-06-09-ios-workflow-comparison\.results\.jsonl/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/2026-06-09-android-workflow\.md/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/2026-06-09-android-workflow\.results\.jsonl/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/benchmark-lab-v1\.md/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/benchmark-lab-v1\.json/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/2026-06-09-ios-xctest-floor\.md/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/2026-06-09-ios-xctest-floor\.results\.jsonl/);
    assert.match(tarList.stdout, /package\/docs\/benchmarks\/2026-06-09-framework-baseline-status\.md/);
    assert.match(tarList.stdout, /package\/scripts\/create-react-native-expo-demo-app\.sh/);
    assert.match(tarList.stdout, /package\/examples\/ios-shim-workflow\.json/);
    assert.match(tarList.stdout, /package\/examples\/android-workflow\.json/);
    assert.match(tarList.stdout, /package\/examples\/react-native-expo-workflow\.json/);
    assert.doesNotMatch(tarList.stdout, /__pycache__|\.pyc/);

    const appDir = path.join(tmp, "app");
    fs.mkdirSync(appDir);
    fs.writeFileSync(path.join(appDir, "package.json"), JSON.stringify({ private: true }, null, 2));
    const install = spawnSync("npm", ["install", "--ignore-scripts", path.join(tmp, tarball)], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(install.status, 0, install.stderr);

    const fakeBin = path.join(tmp, "zmr");
    fs.writeFileSync(fakeBin, [
      "#!/usr/bin/env sh",
      "if [ \"$1\" = \"devices\" ]; then",
      "  printf '{\"platform\":\"ios\",\"count\":1,\"devices\":[{\"serial\":\"ios-ready\",\"state\":\"connected\",\"ready\":true}]}'",
      "  exit 0",
      "fi",
      "if [ \"$1\" = \"run\" ]; then",
      "  trace_dir=\"\"",
      "  while [ \"$#\" -gt 0 ]; do",
      "    if [ \"$1\" = \"--trace-dir\" ]; then",
      "      trace_dir=\"$2\"",
      "      break",
      "    fi",
      "    shift",
      "  done",
      "  if [ -n \"$trace_dir\" ]; then",
      "    mkdir -p \"$trace_dir\"",
      "    printf '%s\\n' '{\"kind\":\"scenario.end\",\"payload\":{\"status\":\"passed\"}}' > \"$trace_dir/events.jsonl\"",
      "  fi",
      "  exit 0",
      "fi",
      "printf 'fake-zmr %s\\n' \"$*\"",
      "",
    ].join("\n"));
    fs.chmodSync(fakeBin, 0o755);

    const wizard = spawnSync("npx", [
      "zmr-wizard",
      "--yes",
      "--dir",
      appDir,
      "--app-id",
      "com.example.demo",
      "--android",
      "--ios",
    ], {
      cwd: appDir,
      env: { ...npmEnv, ZMR_BIN: fakeBin, PATH: `${tmp}${path.delimiter}${process.env.PATH}` },
      encoding: "utf8",
    });
    assert.equal(wizard.status, 0, wizard.stderr);
    assert.ok(fs.existsSync(path.join(appDir, ".zmr", "config.json")));
    assert.ok(fs.existsSync(path.join(appDir, ".zmr", "android-smoke.json")));

    const validate = spawnSync("npx", ["zmr", "validate", "node_modules/zeno-mobile-runner/examples/demo-fake.json"], {
      cwd: appDir,
      env: { ...npmEnv, ZMR_BIN: fakeBin },
      encoding: "utf8",
    });
    assert.equal(validate.status, 0, validate.stderr);
    assert.match(validate.stdout, /fake-zmr validate/);

    const physicalReady = spawnSync("npx", [
      "zmr-assert-ios-physical-ready",
      "--device",
      "ios-ready",
    ], {
      cwd: appDir,
      env: { ...npmEnv, ZMR_BIN: fakeBin },
      encoding: "utf8",
    });
    assert.equal(physicalReady.status, 0, physicalReady.stderr);
    assert.match(physicalReady.stdout, /physical iOS device ready: ios-ready/);

    const benchmark = spawnSync("npx", [
      "zmr-benchmark",
      "--zmr",
      "node_modules/zeno-mobile-runner/examples/demo-fake.json",
      "--device",
      "fake-android-1",
      "--runs",
      "1",
      "--trace-root",
      "traces/bench",
      "--min-pass-rate",
      "100",
      "--max-failures",
      "0",
    ], {
      cwd: appDir,
      env: { ...npmEnv, ZMR_BIN: fakeBin },
      encoding: "utf8",
    });
    assert.equal(benchmark.status, 0, benchmark.stderr);
    assert.match(benchmark.stdout, /zmr: runs=1 failures=0/);
    assert.ok(fs.existsSync(path.join(appDir, "traces", "bench", "results.jsonl")));

    fs.writeFileSync(path.join(appDir, ".zmr", "packed-device-matrix.json"), JSON.stringify({
      runs: 1,
      appId: "com.example.demo",
      devices: [
        {
          name: "fake-android",
          platform: "android",
          serial: "fake-android-1",
          scenario: "node_modules/zeno-mobile-runner/examples/demo-fake.json",
        },
      ],
    }, null, 2));
    const matrix = spawnSync("npx", [
      "zmr-device-matrix",
      "--matrix",
      ".zmr/packed-device-matrix.json",
      "--trace-root",
      "traces/matrix",
      "--min-pass-rate",
      "100",
      "--max-failures",
      "0",
    ], {
      cwd: appDir,
      env: { ...npmEnv, ZMR_BIN: fakeBin },
      encoding: "utf8",
    });
    assert.equal(matrix.status, 0, matrix.stderr);
    assert.match(matrix.stdout, /matrix: runs=1 passRate=100\.00% failures=0/);
    assert.ok(fs.existsSync(path.join(appDir, "traces", "matrix", "summary.json")));

    const commandBenchmark = spawnSync("npx", [
      "zmr-benchmark-command",
      "--tool",
      "baseline",
      "--runs",
      "1",
      "--trace-root",
      "traces/command-bench",
      "--min-pass-rate",
      "100",
      "--max-failures",
      "0",
      "--",
      process.execPath,
      "-e",
      "process.exit(0)",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(commandBenchmark.status, 0, commandBenchmark.stderr);
    assert.match(commandBenchmark.stdout, /baseline: runs=1 failures=0/);
    assert.ok(fs.existsSync(path.join(appDir, "traces", "command-bench", "results.jsonl")));

    const benchmarkLab = spawnSync("npx", [
      "zmr-benchmark-lab",
      "--manifest",
      "node_modules/zeno-mobile-runner/docs/benchmarks/benchmark-lab-v1.json",
      "--format",
      "json",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(benchmarkLab.status, 0, benchmarkLab.stderr);
    assert.match(benchmarkLab.stdout, /"name":"Benchmark Lab v1"/);
    assert.match(benchmarkLab.stdout, /"fixtureCount":4/);

    const androidShimInstall = spawnSync("npx", [
      "zmr-install-android-shim",
      "--app-root",
      appDir,
      "--test-package",
      "com.example.demo.test",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(androidShimInstall.status, 0, androidShimInstall.stderr);
    assert.ok(fs.existsSync(path.join(appDir, ".zmr", "android-shim")));
    assert.ok(fs.existsSync(path.join(appDir, ".zmr", "ZMRShimInstrumentedTest.java")));

    const iosShimInstall = spawnSync("npx", [
      "zmr-install-ios-shim",
      "--app-root",
      appDir,
      "--scheme",
      "SampleZMRUITests",
      "--bundle-id",
      "com.example.demo",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(iosShimInstall.status, 0, iosShimInstall.stderr);
    assert.ok(fs.existsSync(path.join(appDir, ".zmr", "ios-shim")));
    assert.ok(fs.existsSync(path.join(appDir, ".zmr", "ZMRShimUITestCase.swift")));
    assert.ok(fs.existsSync(path.join(appDir, ".zmr", "shims", "ios", "ZMRShim.swift")));

    const hasXcodeproj = spawnSync("ruby", ["-e", "require \"xcodeproj\""], { encoding: "utf8" }).status === 0;
    if (hasXcodeproj) {
      const iosDemoDir = path.join(appDir, "tmp-ios-demo");
      const createIosDemo = spawnSync("npx", [
        "zmr-create-ios-demo-app",
        "--out",
        iosDemoDir,
        "--name",
        "ZMRPackedDemo",
        "--bundle-id",
        "com.example.packed",
      ], {
        cwd: appDir,
        env: npmEnv,
        encoding: "utf8",
      });
      assert.equal(createIosDemo.status, 0, createIosDemo.stderr);
      assert.ok(fs.existsSync(path.join(iosDemoDir, ".zmr", "ios-shim")));
      assert.ok(fs.existsSync(path.join(iosDemoDir, ".zmr", "ios-smoke.json")));
      assert.ok(fs.existsSync(path.join(iosDemoDir, ".zmr", "ios-shim-smoke.json")));
    }

    const rnExpoDir = path.join(appDir, "tmp-rn-expo-demo");
    const createRnExpoDemo = spawnSync("npx", [
      "zmr-create-react-native-expo-demo-app",
      "--out",
      rnExpoDir,
      "--name",
      "ZenoPackedExpoDemo",
      "--app-id",
      "com.example.packed",
      "--ios-bundle-id",
      "com.example.packed",
      "--scheme",
      "zenopackedexpo",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(createRnExpoDemo.status, 0, createRnExpoDemo.stderr);
    assert.ok(fs.existsSync(path.join(rnExpoDir, "App.tsx")));
    assert.ok(fs.existsSync(path.join(rnExpoDir, ".zmr", "react-native-expo-workflow.json")));
    assert.ok(fs.existsSync(path.join(rnExpoDir, ".zmr", "react-native-expo-android-workflow.json")));
    assert.ok(fs.existsSync(path.join(rnExpoDir, ".zmr", "react-native-expo-ios-workflow.json")));

    const packageDir = fs.realpathSync(path.join(appDir, "node_modules", "zeno-mobile-runner"));
    const androidDemo = spawnSync("npx", [
      "zmr-demo-android",
      "--out",
      path.join(appDir, "tmp-android-demo"),
      "--avd",
      "ZMRTest",
      "--dry-run",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(androidDemo.status, 0, androidDemo.stderr);
    assert.match(androidDemo.stdout, new RegExp(`${packageDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/scripts/create-android-demo-app\\.sh`));
    assert.match(androidDemo.stdout, new RegExp(`${packageDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/scripts/benchmark\\.sh`));

    const iosDemo = spawnSync("npx", [
      "zmr-demo-ios",
      "--out",
      path.join(appDir, "tmp-ios-real-demo"),
      "--dry-run",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(iosDemo.status, 0, iosDemo.stderr);
    assert.match(iosDemo.stdout, new RegExp(`${packageDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/scripts/create-ios-demo-app\\.sh`));
    assert.match(iosDemo.stdout, new RegExp(`${packageDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/scripts/run-ios-pilot\\.sh`));

    const pilotGate = spawnSync("npx", [
      "zmr-pilot-gate",
      "--android",
      "--ios",
      "--android-app-root",
      ".",
      "--android-app-id",
      "com.example.android",
      "--ios-app-root",
      ".",
      "--ios-app-path",
      "./build/Sample.app",
      "--ios-app-id",
      "com.example.ios",
      "--ios-shim",
      "./.zmr/ios-shim",
      "--trace-root",
      "traces/pilot",
      "--dry-run",
    ], {
      cwd: appDir,
      env: npmEnv,
      encoding: "utf8",
    });
    assert.equal(pilotGate.status, 0, pilotGate.stderr);
    const realAppDir = fs.realpathSync(appDir);
    assert.match(pilotGate.stdout, /DRY RUN/);
    assert.match(pilotGate.stdout, /scripts\/run-android-pilot\.sh/);
    assert.match(pilotGate.stdout, /scripts\/run-ios-pilot\.sh/);
    assert.match(pilotGate.stdout, new RegExp(`--app-root ${realAppDir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
    assert.match(pilotGate.stdout, /--app-id com\.example\.android/);
    assert.match(pilotGate.stdout, /--app-id com\.example\.ios/);
    assert.match(pilotGate.stdout, new RegExp(`--app-path ${path.join(realAppDir, "build", "Sample.app").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
    assert.match(pilotGate.stdout, new RegExp(`--ios-shim ${path.join(realAppDir, ".zmr", "ios-shim").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
    assert.match(pilotGate.stdout, new RegExp(`--trace-root ${path.join(realAppDir, "traces", "pilot", "android").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
