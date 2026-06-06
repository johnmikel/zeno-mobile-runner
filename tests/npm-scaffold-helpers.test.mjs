import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import url from "node:url";

const root = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "..");

test("command helper module owns generated command strings", async () => {
  const commands = await import(url.pathToFileURL(path.join(root, "npm", "commands.mjs")));

  assert.equal(commands.shellQuote("plain/path"), "plain/path");
  assert.equal(commands.shellQuote("path with spaces"), "'path with spaces'");
  assert.equal(commands.smokeRunCommand({ platform: "android", androidShim: "./.zmr/android shim" }), "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --android-shim './.zmr/android shim'");
  assert.equal(commands.smokeReportCommand({ platform: "android" }), "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml");
  assert.equal(commands.smokeReportCommand({ platform: "ios" }), "zmr report traces/zmr-ios --out traces/zmr-ios/report.html --junit traces/zmr-ios/junit.xml");
  assert.equal(commands.devClientReportCommand({ platform: "android" }), "zmr report traces/zmr-android-dev-client --out traces/zmr-android-dev-client/report.html --junit traces/zmr-android-dev-client/junit.xml");
  assert.equal(commands.devClientReportCommand({ platform: "ios" }), "zmr report traces/zmr-ios-dev-client --out traces/zmr-ios-dev-client/report.html --junit traces/zmr-ios-dev-client/junit.xml");
  assert.equal(
    commands.validateCommand({ android: true, ios: true, expoDevClientScheme: "mobiletest" }),
    "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json && zmr validate --json .zmr/android-dev-client-smoke.json && zmr validate --json .zmr/ios-dev-client-open-link.json",
  );
  assert.equal(
    commands.pilotGateCommand({ android: true, ios: true, appId: "com.example.demo", iosShim: "./.zmr/ios shim" }),
    "zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.demo --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.demo --ios-device booted --ios-shim './.zmr/ios shim' --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl",
  );
  assert.equal(commands.reliabilityCommand({
    scenario: ".zmr/android-smoke.json",
    device: "emulator-5554",
    appId: "com.example.demo",
    traceRoot: "traces/zmr-android-reliability",
    maxP95Ms: 30000,
  }), 'export ZMR_BIN="${ZMR_BIN:-zmr}"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.demo --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && "$ZMR_BIN" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html --junit traces/zmr-android-reliability/junit.xml');
});

test("scenario helper module owns generated scenarios and matrix data", async () => {
  const scenarios = await import(url.pathToFileURL(path.join(root, "npm", "scenarios.mjs")));

  assert.deepEqual(scenarios.deviceMatrix("com.example.demo", true, false, "./.zmr/android shim").devices, [
    {
      name: "android-emulator",
      platform: "android",
      serial: "emulator-5554",
      scenario: ".zmr/android-smoke.json",
      adb: "adb",
      androidShim: "./.zmr/android shim",
    },
  ]);
  assert.deepEqual(scenarios.smokeScenario("Android smoke", "com.example.demo").steps, [
    { action: "launch" },
    { action: "assertHealthy" },
    { action: "snapshot" },
  ]);
  assert.deepEqual(scenarios.scenarioFiles("com.example.demo", {
    android: true,
    ios: true,
    expoDevClientScheme: "mobiletest",
  }).map((file) => file.path), [
    "android-smoke.json",
    "ios-smoke.json",
    "android-dev-client-smoke.json",
    "ios-dev-client-open-link.json",
  ]);
  assert.equal(
    scenarios.devClientScenario("iOS Expo dev-client open-link smoke", "com.example.demo", "mobiletest", "http://127.0.0.1:8081").steps[1].url,
    "exp+mobiletest://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081",
  );
});

test("scaffold helper module owns init JSON metadata", async () => {
  const scaffold = await import(url.pathToFileURL(path.join(root, "npm", "scaffold.mjs")));
  const appRoot = "/tmp/mobile-app";
  const plan = scaffold.scaffoldPlan("com.example.demo");

  assert.deepEqual(scaffold.appScaffoldFiles, [
    "config.json",
    "android-smoke.json",
    "ios-smoke.json",
    "device-matrix.json",
    "AGENTS.md",
  ]);
  assert.deepEqual(scaffold.appScriptNames, [
    "doctor",
    "schemas",
    "validate",
    "android",
    "androidReport",
    "androidDevClient",
    "androidDevClientReport",
    "androidReliability",
    "ios",
    "iosReport",
    "iosDevClient",
    "iosDevClientReport",
    "iosReliability",
    "matrix",
    "pilotGate",
    "readiness",
    "serve",
    "mcp",
    "explain",
    "exportTrace",
  ]);

  assert.deepEqual(scaffold.appInitOutput(appRoot, "com.example.demo", plan), {
    ok: true,
    mode: "app",
    dir: appRoot,
    appId: "com.example.demo",
    created: [
      "/tmp/mobile-app/.zmr/config.json",
      "/tmp/mobile-app/.zmr/android-smoke.json",
      "/tmp/mobile-app/.zmr/ios-smoke.json",
      "/tmp/mobile-app/.zmr/device-matrix.json",
      "/tmp/mobile-app/.zmr/AGENTS.md",
    ],
    configPath: "/tmp/mobile-app/.zmr/config.json",
    androidScenarioPath: "/tmp/mobile-app/.zmr/android-smoke.json",
    iosScenarioPath: "/tmp/mobile-app/.zmr/ios-smoke.json",
    deviceMatrixPath: "/tmp/mobile-app/.zmr/device-matrix.json",
    agentInstructionsPath: "/tmp/mobile-app/.zmr/AGENTS.md",
    next: "zmr doctor --strict --json --config /tmp/mobile-app/.zmr/config.json",
	    nextCommands: [
	      "zmr doctor --strict --json --config /tmp/mobile-app/.zmr/config.json",
	      "zmr schemas --json",
	      "zmr validate --json /tmp/mobile-app/.zmr/android-smoke.json",
	      "zmr validate --json /tmp/mobile-app/.zmr/ios-smoke.json",
	    ],
	    smokeCommands: [
	      "zmr run /tmp/mobile-app/.zmr/android-smoke.json --device emulator-5554 --trace-dir /tmp/mobile-app/traces/zmr-android",
	      "zmr run /tmp/mobile-app/.zmr/ios-smoke.json --platform ios --device booted --trace-dir /tmp/mobile-app/traces/zmr-ios",
	    ],
	    scriptCount: 16,
	    scriptNames: [
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
    ],
  });
});

test("scaffold init JSON metadata only advertises generated platform scenarios", async () => {
  const scaffold = await import(url.pathToFileURL(path.join(root, "npm", "scaffold.mjs")));
  const appRoot = "/tmp/mobile-app";
  const plan = scaffold.scaffoldPlan("com.example.demo", { android: false, ios: true });
  const output = scaffold.appInitOutput(appRoot, "com.example.demo", plan);

  assert.deepEqual(output.created, [
    "/tmp/mobile-app/.zmr/config.json",
    "/tmp/mobile-app/.zmr/ios-smoke.json",
    "/tmp/mobile-app/.zmr/device-matrix.json",
    "/tmp/mobile-app/.zmr/AGENTS.md",
  ]);
  assert.equal(output.androidScenarioPath, undefined);
  assert.equal(output.iosScenarioPath, "/tmp/mobile-app/.zmr/ios-smoke.json");
  assert.deepEqual(output.nextCommands, [
    "zmr doctor --strict --json --config /tmp/mobile-app/.zmr/config.json",
    "zmr schemas --json",
    "zmr validate --json /tmp/mobile-app/.zmr/ios-smoke.json",
  ]);
  assert.deepEqual(output.smokeCommands, [
    "zmr run /tmp/mobile-app/.zmr/ios-smoke.json --platform ios --device booted --trace-dir /tmp/mobile-app/traces/zmr-ios",
  ]);
  assert.deepEqual(output.scriptNames, [
    "doctor",
    "schemas",
    "validate",
    "ios",
    "iosReport",
    "iosReliability",
    "matrix",
    "pilotGate",
    "serve",
    "mcp",
    "explain",
    "exportTrace",
  ]);
});

test("scaffold init JSON metadata includes Expo dev-client script names", async () => {
  const scaffold = await import(url.pathToFileURL(path.join(root, "npm", "scaffold.mjs")));
  const plan = scaffold.scaffoldPlan("com.example.demo", { expoDevClientScheme: "mobiletest" });
  const output = scaffold.appInitOutput("/tmp/mobile-app", "com.example.demo", plan);

  assert.equal(output.androidDevClientScenarioPath, "/tmp/mobile-app/.zmr/android-dev-client-smoke.json");
  assert.equal(output.iosDevClientScenarioPath, "/tmp/mobile-app/.zmr/ios-dev-client-open-link.json");
  assert.equal(output.scriptCount, 20);
  assert.deepEqual(output.scriptNames, [
    "doctor",
    "schemas",
    "validate",
    "android",
    "androidReport",
    "androidDevClient",
    "androidDevClientReport",
    "androidReliability",
    "ios",
    "iosReport",
    "iosDevClient",
    "iosDevClientReport",
    "iosReliability",
    "matrix",
    "pilotGate",
    "readiness",
    "serve",
    "mcp",
    "explain",
    "exportTrace",
  ]);
  assert.deepEqual(output.nextCommands, [
    "zmr doctor --strict --json --config /tmp/mobile-app/.zmr/config.json",
    "zmr schemas --json",
    "zmr validate --json /tmp/mobile-app/.zmr/android-smoke.json",
    "zmr validate --json /tmp/mobile-app/.zmr/ios-smoke.json",
    "zmr validate --json /tmp/mobile-app/.zmr/android-dev-client-smoke.json",
    "zmr validate --json /tmp/mobile-app/.zmr/ios-dev-client-open-link.json",
  ]);
  assert.deepEqual(output.smokeCommands, [
    "zmr run /tmp/mobile-app/.zmr/android-smoke.json --device emulator-5554 --trace-dir /tmp/mobile-app/traces/zmr-android",
    "zmr run /tmp/mobile-app/.zmr/ios-smoke.json --platform ios --device booted --trace-dir /tmp/mobile-app/traces/zmr-ios",
  ]);
});

test("scaffold init JSON metadata follows package script mode", async () => {
  const scaffold = await import(url.pathToFileURL(path.join(root, "npm", "scaffold.mjs")));
  const plan = scaffold.scaffoldPlan("com.example.demo", { packageScripts: true });
  const output = scaffold.appInitOutput("/tmp/mobile-app", "com.example.demo", plan, { packageScripts: true });

  assert.equal(output.next, "npm run zmr:doctor");
  assert.deepEqual(output.nextCommands, [
    "npm run zmr:doctor",
    "npm run zmr:schemas",
    "npm run zmr:validate",
  ]);
  assert.deepEqual(output.smokeCommands, [
    "npm run zmr:android",
    "npm run zmr:ios",
  ]);
});

test("scaffold init JSON next commands shell quote app paths", async () => {
  const scaffold = await import(url.pathToFileURL(path.join(root, "npm", "scaffold.mjs")));
  const plan = scaffold.scaffoldPlan("com.example.demo");
  const output = scaffold.appInitOutput("/tmp/mobile app", "com.example.demo", plan);

  assert.equal(output.configPath, "/tmp/mobile app/.zmr/config.json");
  assert.equal(output.next, "zmr doctor --strict --json --config '/tmp/mobile app/.zmr/config.json'");
  assert.deepEqual(output.nextCommands, [
    "zmr doctor --strict --json --config '/tmp/mobile app/.zmr/config.json'",
    "zmr schemas --json",
    "zmr validate --json '/tmp/mobile app/.zmr/android-smoke.json'",
    "zmr validate --json '/tmp/mobile app/.zmr/ios-smoke.json'",
  ]);
});

test("agent helper module owns generated AI-agent quick-start instructions", async () => {
  const agents = await import(url.pathToFileURL(path.join(root, "npm", "agents.mjs")));
  const config = {
    scripts: {
      android: "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android",
      androidReport: "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml",
      androidReliability: "zmr-benchmark --zmr .zmr/android-smoke.json",
      matrix: "zmr-device-matrix --matrix .zmr/device-matrix.json",
      pilotGate: "zmr-pilot-gate --android",
      serve: "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent",
      mcp: "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent",
      explain: "zmr explain traces/zmr-agent --json",
      exportTrace: "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact",
      schemas: "zmr schemas --json",
      validate: "zmr validate --json .zmr/android-smoke.json",
      doctor: "zmr doctor --strict --json --config .zmr/config.json",
    },
  };

  assert.deepEqual(agents.nextStepCommands(config, {
    android: true,
    ios: false,
    packageScripts: true,
  }).map((step) => step.command), [
    "npm run zmr:android",
    "npm run zmr:android:report",
    "npm run zmr:android:reliability",
    "npm run zmr:matrix",
    "npm run zmr:pilot",
    "npm run zmr:serve",
    "npm run zmr:mcp",
    "npm run zmr:explain",
    "npm run zmr:export",
    "npm run zmr:schemas",
    "npm run zmr:validate",
    "npm run zmr:doctor",
  ]);

  const instructions = agents.agentInstructions("com.example.demo", {
    android: true,
    ios: false,
    packageScripts: true,
    scripts: config.scripts,
  });
  assert.match(instructions, /# ZMR Agent Instructions/);
  assert.match(instructions, /App id: `com\.example\.demo`/);
  assert.match(instructions, /## App Scripts/);
  assert.match(instructions, /npm run zmr:doctor/);
  assert.match(instructions, /npm run zmr:schemas/);
  assert.match(instructions, /npm run zmr:validate/);
  assert.match(instructions, /npm run zmr:android/);
  assert.match(instructions, /npm run zmr:serve/);
  assert.match(instructions, /npm run zmr:mcp/);
  assert.match(instructions, /npm run zmr:explain/);
  assert.match(instructions, /npm run zmr:export/);
  assert.doesNotMatch(instructions, /zmr validate --json \.zmr\/android-smoke\.json/);
  assert.doesNotMatch(instructions, /zmr run \.zmr\/android-smoke\.json --device emulator-5554/);
  assert.doesNotMatch(instructions, /zmr explain traces\/zmr-agent --json/);
  assert.match(instructions, /Use `semantic_snapshot` before choosing tap or type actions/);
  assert.match(instructions, /zmr explore --from-trace traces\/zmr-agent --out \.zmr\/discovered\/login-smoke\.json --goal "find a stable login smoke" --include-actions --validate --json/);
  assert.match(instructions, /Prefer `zmr explore` for CLI agent loops/);
  assert.match(instructions, /`autonomous:false`, `reviewRequired:true`, `guardrails`/);
  assert.match(instructions, /zmr discover --from-trace traces\/zmr-agent --out \.zmr\/discovered\/replay-smoke\.json --include-actions --validate --json/);
  assert.match(instructions, /Treat discover output as a lower-level reviewable starting point/);
  assert.match(instructions, /zmr draft --from-trace traces\/zmr-agent --out \.zmr\/discovered\/surface-smoke\.json --json/);
  assert.match(instructions, /Treat draft output as a reviewable starting point/);
  assert.match(instructions, /Do not claim production readiness from a single-platform setup/);
  assert.doesNotMatch(instructions, /npm run zmr:readiness/);
});

test("package script helper module owns package.json script mapping", async () => {
  const packageScriptHelpers = await import(url.pathToFileURL(path.join(root, "npm", "package-scripts.mjs")));
  const config = {
    scripts: {
      doctor: "zmr doctor --strict --json --config .zmr/config.json",
      schemas: "zmr schemas --json",
      validate: "zmr validate --json .zmr/android-smoke.json",
      android: "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android",
      androidReport: "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml",
      androidReliability: "zmr-benchmark --zmr .zmr/android-smoke.json",
      pilotGate: "zmr-pilot-gate --android",
      serve: "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent",
      mcp: "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent",
      explain: "zmr explain traces/zmr-agent --json",
      exportTrace: "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact",
    },
  };

  assert.deepEqual(packageScriptHelpers.packageScripts(config), {
    "zmr:doctor": config.scripts.doctor,
    "zmr:schemas": config.scripts.schemas,
    "zmr:validate": config.scripts.validate,
    "zmr:android": config.scripts.android,
    "zmr:android:report": config.scripts.androidReport,
    "zmr:android:dev-client": undefined,
    "zmr:android:dev-client:report": undefined,
    "zmr:android:reliability": config.scripts.androidReliability,
    "zmr:ios": undefined,
    "zmr:ios:report": undefined,
    "zmr:ios:dev-client": undefined,
    "zmr:ios:dev-client:report": undefined,
    "zmr:ios:reliability": undefined,
    "zmr:matrix": undefined,
    "zmr:pilot": config.scripts.pilotGate,
    "zmr:readiness": undefined,
    "zmr:serve": config.scripts.serve,
    "zmr:mcp": config.scripts.mcp,
    "zmr:explain": config.scripts.explain,
    "zmr:export": config.scripts.exportTrace,
  });

  const pkg = packageScriptHelpers.applyPackageScripts({
    scripts: {
      test: "vitest",
      "zmr:ios": "stale ios",
      "zmr:readiness": "stale readiness",
    },
  }, config, { android: true, ios: false });

  assert.equal(pkg.scripts.test, "vitest");
  assert.equal(pkg.scripts["zmr:android"], config.scripts.android);
  assert.equal(pkg.scripts["zmr:ios"], undefined);
  assert.equal(pkg.scripts["zmr:readiness"], undefined);
});

test("app config helper module owns generated .zmr config data", async () => {
  const configHelpers = await import(url.pathToFileURL(path.join(root, "npm", "app-config.mjs")));
  const config = configHelpers.appConfig("com.example.demo", {
    android: true,
    ios: true,
    androidShim: "./.zmr/android shim",
    iosShim: "./.zmr/ios shim",
    expoDevClientScheme: "mobiletest",
  });

  assert.equal(config.schemaVersion, 1);
  assert.equal(config.appId, "com.example.demo");
  assert.equal(config.android.enabled, true);
  assert.equal(config.ios.enabled, true);
  assert.equal(config.tools.androidShimPath, "./.zmr/android shim");
  assert.equal(config.tools.iosShimPath, "./.zmr/ios shim");
  assert.equal(config.scripts.android, "zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --android-shim './.zmr/android shim'");
  assert.equal(config.scripts.androidReport, "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml");
  assert.equal(config.scripts.ios, "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios --ios-shim './.zmr/ios shim'");
  assert.equal(config.scripts.iosReport, "zmr report traces/zmr-ios --out traces/zmr-ios/report.html --junit traces/zmr-ios/junit.xml");
  assert.equal(config.scripts.androidDevClient, "zmr run .zmr/android-dev-client-smoke.json --device emulator-5554 --trace-dir traces/zmr-android-dev-client");
  assert.equal(config.scripts.androidDevClientReport, "zmr report traces/zmr-android-dev-client --out traces/zmr-android-dev-client/report.html --junit traces/zmr-android-dev-client/junit.xml");
  assert.equal(config.scripts.iosDevClient, "zmr run .zmr/ios-dev-client-open-link.json --platform ios --device booted --trace-dir traces/zmr-ios-dev-client");
  assert.equal(config.scripts.iosDevClientReport, "zmr report traces/zmr-ios-dev-client --out traces/zmr-ios-dev-client/report.html --junit traces/zmr-ios-dev-client/junit.xml");
  assert.equal(config.scripts.validate, "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json && zmr validate --json .zmr/android-dev-client-smoke.json && zmr validate --json .zmr/ios-dev-client-open-link.json");
  assert.equal(config.scripts.explain, "zmr explain traces/zmr-agent --json");
  assert.equal(config.scripts.exportTrace, "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact");
  assert.equal(config.scripts.readiness, "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json");

  const androidOnly = configHelpers.appConfig("com.example.demo", { android: true, ios: false });
  assert.equal(androidOnly.scripts.ios, undefined);
  assert.equal(androidOnly.scripts.readiness, undefined);
});

test("generated file helper module owns scaffold file writes", async () => {
  const files = await import(url.pathToFileURL(path.join(root, "npm", "generated-files.mjs")));
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-generated-files-module-test-"));
  try {
    assert.equal(files.ensureTraceIgnore(tmp, { cwd: tmp }), ".gitignore");
    assert.equal(files.ensureTraceIgnore(tmp, { cwd: tmp }), null);
    assert.deepEqual(files.writeJsonFile(path.join(tmp, "config.json"), { ok: true }, { cwd: tmp }), {
      path: "config.json",
      status: "created",
    });
    assert.equal(files.writeJsonFile(path.join(tmp, "config.json"), { ok: false }, { cwd: tmp }), null);
    assert.deepEqual(files.writeTextFile(path.join(tmp, "AGENTS.md"), "hello\n", { cwd: tmp }), {
      path: "AGENTS.md",
      status: "created",
    });
    assert.deepEqual(files.writeScaffoldFiles(tmp, [
      { kind: "json", path: "nested/config.json", value: { ok: true }, overwrite: true },
      { kind: "text", path: "nested/AGENTS.md", value: "agent notes\n", overwrite: true },
    ], { cwd: tmp }), [
      { path: "nested/config.json", status: "created" },
      { path: "nested/AGENTS.md", status: "created" },
    ]);

    const config = {
      scripts: {
        doctor: "zmr doctor",
        schemas: "zmr schemas --json",
        validate: "zmr validate --json .zmr/android-smoke.json",
        android: "zmr run .zmr/android-smoke.json",
        androidReport: "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml",
        androidReliability: "zmr-benchmark --zmr .zmr/android-smoke.json",
        pilotGate: "zmr-pilot-gate --android",
        serve: "zmr serve",
        mcp: "zmr mcp",
        explain: "zmr explain traces/zmr-agent --json",
        exportTrace: "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact",
      },
    };
    assert.deepEqual(files.writePackageScripts(tmp, config, { android: true, ios: false, cwd: tmp }), {
      path: "package.json",
      status: "created",
    });
    const pkg = JSON.parse(fs.readFileSync(path.join(tmp, "package.json"), "utf8"));
    assert.equal(pkg.scripts["zmr:android"], config.scripts.android);
    assert.equal(pkg.scripts["zmr:ios"], undefined);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("setup helper module owns common scaffold option parsing", async () => {
  const setup = await import(url.pathToFileURL(path.join(root, "npm", "setup.mjs")));

  assert.deepEqual(setup.parseScaffoldArgs([
    "--dir",
    "/tmp/mobile app",
    "--app-id",
    "com.example.demo",
    "--ios",
    "--ios-shim",
    "./.zmr/ios shim",
    "--expo-dev-client-scheme",
    "mobiletest",
  ]), {
    dir: "/tmp/mobile app",
    appId: "com.example.demo",
    android: false,
    androidShim: "",
    ios: true,
    iosShim: "./.zmr/ios shim",
    expoDevClientScheme: "mobiletest",
    json: false,
  });

  assert.deepEqual(setup.parseScaffoldArgs([], { wizard: true }), {
    dir: process.cwd(),
    appId: "com.example.mobiletest",
    android: true,
    androidShim: "",
    ios: true,
    iosShim: "",
    expoDevClientScheme: "",
    packageJson: false,
    yes: false,
    json: false,
  });

  assert.deepEqual(setup.parseScaffoldArgs(["--android", "--package-json", "-y", "--json"], { wizard: true }), {
    dir: process.cwd(),
    appId: "com.example.mobiletest",
    android: true,
    androidShim: "",
    ios: false,
    iosShim: "",
    expoDevClientScheme: "",
    packageJson: true,
    yes: true,
    json: true,
  });

  assert.deepEqual(setup.parseScaffoldArgs(["--ios", "--package-json"], { packageJson: true }), {
    dir: process.cwd(),
    appId: "com.example.mobiletest",
    android: false,
    androidShim: "",
    ios: true,
    iosShim: "",
    expoDevClientScheme: "",
    packageJson: true,
    json: false,
  });

  assert.deepEqual(setup.parseScaffoldArgs(["--help"]), { help: true });
  assert.throws(() => setup.parseScaffoldArgs(["--dir"]), /--dir requires a value/);
  assert.throws(() => setup.parseScaffoldArgs(["--package-json"]), /unknown argument: --package-json/);
});
