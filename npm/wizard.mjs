#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { resolveBinary } from "./index.mjs";
import {
  appInitOutput,
  ensureTraceIgnore,
  formatWizardCheckResult,
  nextStepCommands,
  parseScaffoldArgs,
  scaffoldPlan,
  writePackageScripts,
  writeScaffoldFiles,
  wizardChecks,
} from "./scaffold.mjs";

const options = parseArgs(process.argv.slice(2));

if (!options.json) {
  console.log("ZMR setup wizard");
  console.log("================");
}

if (!options.yes && !options.json && input.isTTY) {
  await promptForMissingOptions(options);
}

const appRoot = path.resolve(options.dir);

if (!options.json) {
  console.log("");
  console.log("Checking necessities");
  for (const checkSpec of wizardChecks({
    android: options.android,
    ios: options.ios,
    nodePath: process.execPath,
    zmrPath: resolveBinary() ?? "zmr",
  })) {
    check(checkSpec.label, checkSpec.command, checkSpec.args, { required: checkSpec.required });
  }
}

const plan = scaffoldPlan(options.appId, {
  android: options.android,
  ios: options.ios,
  androidShim: options.androidShim,
  iosShim: options.iosShim,
  expoDevClientScheme: options.expoDevClientScheme,
  packageScripts: options.packageJson,
});
const { config, files } = plan;
for (const result of writeScaffoldFiles(path.join(appRoot, ".zmr"), files, { cwd: appRoot })) {
  if (!options.json) console.log(`${result.status} ${result.path}`);
}
const ignoredPath = ensureTraceIgnore(appRoot, { cwd: appRoot });
if (ignoredPath && !options.json) console.log(`updated ${ignoredPath}`);
if (options.packageJson) patchPackageJson(appRoot, options.android, options.ios);

if (options.json) {
  process.stdout.write(`${JSON.stringify(appInitOutput(appRoot, options.appId, plan, { packageScripts: options.packageJson }))}\n`);
} else {
  console.log("");
  console.log("Next steps");
  printNextSteps(config.scripts, options);
}

function parseArgs(args) {
  try {
    const parsed = parseScaffoldArgs(args, { wizard: true });
    if (parsed.help) {
      usage();
      process.exit(0);
    }
    return parsed;
  } catch (error) {
    console.error(error.message);
    usage();
    process.exit(2);
  }
}

async function promptForMissingOptions(parsed) {
  const rl = readline.createInterface({ input, output });
  try {
    parsed.appId = (await rl.question(`App id [${parsed.appId}]: `)).trim() || parsed.appId;
    const patch = (await rl.question("Patch package.json scripts? [Y/n]: ")).trim().toLowerCase();
    parsed.packageJson = patch === "" || patch === "y" || patch === "yes";
  } finally {
    rl.close();
  }
}

function usage() {
  console.log("Usage: zmr-wizard [--dir <app-root>] [--app-id <id>] [--android] [--android-shim <path>] [--ios] [--ios-shim <path>] [--expo-dev-client-scheme <scheme>] [--package-json] [--yes] [--json]");
}

function printNextSteps(scripts, parsed) {
  for (const step of nextStepCommands({ scripts }, {
    android: parsed.android,
    ios: parsed.ios,
    packageScripts: parsed.packageJson,
  })) {
    console.log(`  ${step.command}`);
  }
}

function check(label, command, args, opts = {}) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  console.log(`  ${formatWizardCheckResult(label, result, opts)}`);
}

function patchPackageJson(root, android, ios) {
  const result = writePackageScripts(root, config, { android, ios, cwd: root });
  if (result && !options.json) console.log(`${result.status} ${result.path}`);
}
