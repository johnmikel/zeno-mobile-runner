import {
  devClientReportCommand,
  devClientRunCommand,
  matrixCommand,
  pilotGateCommand,
  readinessCommand,
  reliabilityCommand,
  smokeReportCommand,
  smokeRunCommand,
  validateCommand,
} from "./commands.mjs";

export function appConfig(appId, { android = true, ios = true, androidShim = "", iosShim = "", expoDevClientScheme = "" } = {}) {
  const androidCommand = smokeRunCommand({ platform: "android", androidShim });
  const iosCommand = smokeRunCommand({ platform: "ios", iosShim });
  const scripts = {
    doctor: "zmr doctor --strict --json --config .zmr/config.json",
    schemas: "zmr schemas --json",
    validate: validateCommand({ android, ios, expoDevClientScheme }),
    matrix: matrixCommand(),
    pilotGate: pilotGateCommand({ android, ios, appId, iosShim }),
    serve: "zmr serve --transport stdio --config .zmr/config.json --trace-dir traces/zmr-agent",
    mcp: "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent",
    explain: "zmr explain traces/zmr-agent --json",
    exportTrace: "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact",
  };
  if (android) {
    scripts.android = androidCommand;
    scripts.androidReport = smokeReportCommand({ platform: "android" });
    scripts.androidReliability = reliabilityCommand({
      scenario: ".zmr/android-smoke.json",
      device: "emulator-5554",
      appId,
      androidShim,
      traceRoot: "traces/zmr-android-reliability",
      maxP95Ms: 30000,
    });
  }
  if (ios) {
    scripts.ios = iosCommand;
    scripts.iosReport = smokeReportCommand({ platform: "ios" });
    scripts.iosReliability = reliabilityCommand({
      scenario: ".zmr/ios-smoke.json",
      platform: "ios",
      device: "booted",
      appId,
      xcrun: "xcrun",
      iosShim,
      traceRoot: "traces/zmr-ios-reliability",
      maxP95Ms: 45000,
    });
  }
  if (expoDevClientScheme) {
    if (android) {
      scripts.androidDevClient = devClientRunCommand({ platform: "android" });
      scripts.androidDevClientReport = devClientReportCommand({ platform: "android" });
    }
    if (ios) {
      scripts.iosDevClient = devClientRunCommand({ platform: "ios" });
      scripts.iosDevClientReport = devClientReportCommand({ platform: "ios" });
    }
  }
  if (android && ios) {
    scripts.readiness = readinessCommand();
  }
  const config = {
    schemaVersion: 1,
    appId,
    android: {
      enabled: android,
      defaultDevice: "emulator-5554",
      smokeScenario: ".zmr/android-smoke.json",
      traceDir: "traces/zmr-android",
      ensureDevice: true,
    },
    ios: {
      enabled: ios,
      defaultDevice: "booted",
      smokeScenario: ".zmr/ios-smoke.json",
      traceDir: "traces/zmr-ios",
      ensureDevice: true,
    },
    artifacts: {
      screenshots: true,
      hierarchy: true,
      logs: true,
      screenRecording: false,
    },
    scripts,
  };
  if (androidShim || iosShim) {
    config.tools = {};
    if (androidShim) config.tools.androidShimPath = androidShim;
    if (iosShim) config.tools.iosShimPath = iosShim;
  }
  return config;
}
