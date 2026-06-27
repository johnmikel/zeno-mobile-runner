import {
  agentInstructions,
} from "./agents.mjs";
import { appConfig } from "./app-config.mjs";
import {
  shellQuote,
} from "./commands.mjs";
import {
  deviceMatrix,
  scenarioFiles,
} from "./scenarios.mjs";

export const appScaffoldFiles = [
  "config.json",
  "android-smoke.json",
  "ios-smoke.json",
  "device-matrix.json",
  "AGENTS.md",
];

export const appScriptNames = [
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
];

export {
  agentInstructions,
  nextStepCommands,
} from "./agents.mjs";
export { appConfig } from "./app-config.mjs";
export {
  devClientRunCommand,
  devClientReportCommand,
  matrixCommand,
  pilotGateCommand,
  readinessCommand,
  reliabilityCommand,
  shellJoin,
  shellQuote,
  smokeReportCommand,
  smokeRunCommand,
  validateCommand,
} from "./commands.mjs";
export {
  devClientScenario,
  deviceMatrix,
  scenarioFiles,
  smokeScenario,
} from "./scenarios.mjs";
export {
  applyPackageScripts,
  packageScripts,
} from "./package-scripts.mjs";
export {
  ensureTraceIgnore,
  writeJsonFile,
  writePackageScripts,
  writeScaffoldFiles,
  writeTextFile,
} from "./generated-files.mjs";
export {
  formatWizardCheckResult,
  parseScaffoldArgs,
  readOptionValue,
  wizardChecks,
} from "./setup.mjs";

export function scaffoldPlan(appId, { android = true, ios = true, androidShim = "", iosShim = "", expoDevClientScheme = "", packageScripts = false } = {}) {
  const config = appConfig(appId, { android, ios, androidShim, iosShim, expoDevClientScheme });
  return {
    config,
    files: [
      { kind: "json", path: "config.json", value: config, overwrite: true },
      ...scenarioFiles(appId, { android, ios, expoDevClientScheme }).map((file) => ({
        kind: "json",
        path: file.path,
        value: file.scenario,
        overwrite: false,
      })),
      {
        kind: "json",
        path: "device-matrix.json",
        value: deviceMatrix(appId, android, ios, androidShim, iosShim),
        overwrite: true,
      },
      {
        kind: "text",
        path: "AGENTS.md",
        value: agentInstructions(appId, { android, ios, packageScripts, scripts: config.scripts }),
        overwrite: true,
      },
    ],
  };
}

export function scaffoldFiles(appId, options = {}) {
  return scaffoldPlan(appId, options).files;
}

export function appInitOutput(appRoot, appId, plan, { packageScripts = false } = {}) {
  const filePath = (name) => pathJoin(appRoot, ".zmr", name);
  const configPath = filePath("config.json");
  const generatedPath = (name) => plan.files.some((file) => file.path === name) ? filePath(name) : undefined;
  const androidScenarioPath = generatedPath("android-smoke.json");
  const iosScenarioPath = generatedPath("ios-smoke.json");
  const androidDevClientScenarioPath = generatedPath("android-dev-client-smoke.json");
  const iosDevClientScenarioPath = generatedPath("ios-dev-client-open-link.json");
  const scenarioPaths = plan.files
    .filter((file) => file.kind === "json" && file.path !== "config.json" && file.path !== "device-matrix.json")
    .map((file) => filePath(file.path));
  const scriptNames = appScriptNames.filter((name) => plan.config.scripts[name] != null);
  const doctorCommand = packageScripts ? "npm run zmr:doctor" : `zmr doctor --strict --json --config ${shellQuote(configPath)}`;
  const schemaCommand = packageScripts ? "npm run zmr:schemas" : "zmr schemas --json";
  const validateCommands = packageScripts
    ? ["npm run zmr:validate"]
    : scenarioPaths.map((scenarioPath) => `zmr validate --json ${shellQuote(scenarioPath)}`);
  const smokeCommands = [];
  if (packageScripts) {
    if (androidScenarioPath) smokeCommands.push("npm run zmr:android");
    if (iosScenarioPath) smokeCommands.push("npm run zmr:ios");
  } else {
    if (androidScenarioPath) {
      smokeCommands.push(
        `zmr run ${shellQuote(androidScenarioPath)} --device emulator-5554 --trace-dir ${shellQuote(pathJoin(appRoot, "traces", "zmr-android"))} --ensure-device`,
      );
    }
    if (iosScenarioPath) {
      smokeCommands.push(
        `zmr run ${shellQuote(iosScenarioPath)} --platform ios --device booted --trace-dir ${shellQuote(pathJoin(appRoot, "traces", "zmr-ios"))} --ensure-device`,
      );
    }
  }
  const output = {
    ok: true,
    mode: "app",
    dir: appRoot,
    appId,
    created: plan.files.map((file) => filePath(file.path)),
    configPath,
    deviceMatrixPath: filePath("device-matrix.json"),
    agentInstructionsPath: filePath("AGENTS.md"),
    next: doctorCommand,
    nextCommands: [
      doctorCommand,
      schemaCommand,
      ...validateCommands,
    ],
    smokeCommands,
    scriptCount: scriptNames.length,
    scriptNames,
  };
  if (androidScenarioPath) output.androidScenarioPath = androidScenarioPath;
  if (iosScenarioPath) output.iosScenarioPath = iosScenarioPath;
  if (androidDevClientScenarioPath) output.androidDevClientScenarioPath = androidDevClientScenarioPath;
  if (iosDevClientScenarioPath) output.iosDevClientScenarioPath = iosDevClientScenarioPath;
  return output;
}

function pathJoin(...parts) {
  return parts.join("/").replace(/\/+/g, "/");
}
