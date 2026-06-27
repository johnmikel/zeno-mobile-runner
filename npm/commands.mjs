export function smokeRunCommand({ platform, androidShim = "", iosShim = "" }) {
  if (platform === "android") {
    const args = ["zmr", "run", ".zmr/android-smoke.json", "--device", "emulator-5554", "--trace-dir", "traces/zmr-android", "--ensure-device"];
    if (androidShim) args.push("--android-shim", androidShim);
    return shellJoin(args);
  }
  if (platform === "ios") {
    const args = ["zmr", "run", ".zmr/ios-smoke.json", "--platform", "ios", "--device", "booted", "--trace-dir", "traces/zmr-ios", "--ensure-device"];
    if (iosShim) args.push("--ios-shim", iosShim);
    return shellJoin(args);
  }
  throw new Error(`unsupported smoke run platform: ${platform}`);
}

export function smokeReportCommand({ platform }) {
  if (platform === "android") return reportCommand("zmr", "traces/zmr-android");
  if (platform === "ios") return reportCommand("zmr", "traces/zmr-ios");
  throw new Error(`unsupported smoke report platform: ${platform}`);
}

export function validateCommand({ android = true, ios = true, expoDevClientScheme = "" } = {}) {
  const scenarios = [];
  if (android) scenarios.push(".zmr/android-smoke.json");
  if (ios) scenarios.push(".zmr/ios-smoke.json");
  if (expoDevClientScheme && android) scenarios.push(".zmr/android-dev-client-smoke.json");
  if (expoDevClientScheme && ios) scenarios.push(".zmr/ios-dev-client-open-link.json");
  return scenarios.map((scenario) => shellJoin(["zmr", "validate", "--json", scenario])).join(" && ");
}

export function pilotGateCommand({ android, ios, appId, iosShim = "" }) {
  const args = ["zmr-pilot-gate"];
  if (android) args.push("--android");
  if (ios) args.push("--ios");
  if (android) args.push("--android-app-root", ".", "--android-app-id", appId, "--android-device", "emulator-5554");
  if (ios) {
    args.push("--ios-app-root", ".", "--ios-app-path", "./build/Debug-iphonesimulator/Sample.app", "--ios-app-id", appId, "--ios-device", "booted");
    if (iosShim) args.push("--ios-shim", iosShim);
  }
  args.push("--runs", "20", "--min-pass-rate", "100", "--max-failures", "0", "--evidence-out", "traces/zmr-pilots/evidence.jsonl");
  return shellJoin(args);
}

export function matrixCommand() {
  return "ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0";
}

export function readinessCommand() {
  return "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json";
}

export function reliabilityCommand({ scenario, platform = "", device, appId, xcrun = "", androidShim = "", iosShim = "", traceRoot, maxP95Ms }) {
  const args = [
    "zmr-benchmark",
    "--zmr",
    scenario,
  ];
  if (platform) args.push("--platform", platform);
  args.push("--device", device, "--app-id", appId);
  if (xcrun) args.push("--xcrun", xcrun);
  if (androidShim) args.push("--android-shim", androidShim);
  if (iosShim) args.push("--ios-shim", iosShim);
  args.push(
    "--runs",
    "20",
    "--trace-root",
    traceRoot,
    "--min-pass-rate",
    "100",
    "--max-failures",
    "0",
    "--max-p95-ms",
    String(maxP95Ms),
  );
  return `export ZMR_BIN="\${ZMR_BIN:-zmr}"; ${shellJoin(args)} && ${reportCommand('"$ZMR_BIN"', traceRoot)}`;
}

export function devClientRunCommand({ platform }) {
  if (platform === "android") {
    return "zmr run .zmr/android-dev-client-smoke.json --device emulator-5554 --trace-dir traces/zmr-android-dev-client --ensure-device";
  }
  if (platform === "ios") {
    return "zmr run .zmr/ios-dev-client-open-link.json --platform ios --device booted --trace-dir traces/zmr-ios-dev-client --ensure-device";
  }
  throw new Error(`unsupported dev-client platform: ${platform}`);
}

export function devClientReportCommand({ platform }) {
  if (platform === "android") return reportCommand("zmr", "traces/zmr-android-dev-client");
  if (platform === "ios") return reportCommand("zmr", "traces/zmr-ios-dev-client");
  throw new Error(`unsupported dev-client report platform: ${platform}`);
}

function reportCommand(bin, traceRoot) {
  return `${bin} report ${shellQuote(traceRoot)} --out ${shellQuote(`${traceRoot}/report.html`)} --junit ${shellQuote(`${traceRoot}/junit.xml`)}`;
}

export function shellJoin(args) {
  return args.map((arg, index) => {
    if (index === 0 && /^[A-Za-z_][A-Za-z0-9_]*=/.test(arg)) return arg;
    return shellQuote(arg);
  }).join(" ");
}

export function shellQuote(value) {
  const text = String(value);
  if (/^[A-Za-z0-9_./:=@%+,-]+$/.test(text)) return text;
  return `'${text.replaceAll("'", "'\\''")}'`;
}
