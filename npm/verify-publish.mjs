#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const exe = process.platform === "win32" ? "zmr.exe" : "zmr";
const hostPrebuild = path.join(root, "prebuilds", `${process.platform}-${process.arch}`, exe);

if (!fs.existsSync(hostPrebuild)) {
  fail(`missing host prebuild for ${process.platform}-${process.arch}: ${hostPrebuild}`);
}

const version = spawnSync(hostPrebuild, ["version", "--json"], { encoding: "utf8" });
if (version.status !== 0) {
  fail(`host prebuild is not runnable: ${hostPrebuild}`);
}

let actual;
try {
  actual = JSON.parse(version.stdout).version;
} catch {
  fail(`host prebuild did not return valid version JSON: ${hostPrebuild}`);
}

if (actual !== pkg.version) {
  fail(`host prebuild reports ${actual}, expected ${pkg.version}: ${hostPrebuild}`);
}

function fail(message) {
  console.error(`zeno-mobile-runner: ${message}`);
  console.error("zeno-mobile-runner: run `npm run pack:npm` before publishing so prebuilds match package.json.");
  process.exit(1);
}
