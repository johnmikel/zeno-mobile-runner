#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { resolveBinary } from "./index.mjs";

const pkg = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const binary = resolveBinary();

if (binary && binaryMatchesPackageVersion(binary, pkg.version)) process.exit(0);
if (binary && process.env.ZMR_BIN) {
  console.warn(`zeno-mobile-runner: ZMR_BIN points to a zmr binary that does not report package version ${pkg.version}: ${binary}`);
  process.exit(0);
}
if (process.env.ZMR_SKIP_POSTINSTALL_BUILD === "1") process.exit(0);

const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;
if (!hasZig) {
  if (binary) {
    console.warn(`zeno-mobile-runner: prebuilt zmr binary does not report package version ${pkg.version}: ${binary}`);
  } else {
    console.warn("zeno-mobile-runner: no prebuilt zmr binary found and Zig is not installed.");
  }
  console.warn("zeno-mobile-runner: install a release package with prebuilds, install Zig and run `npm run build:zmr`, or set ZMR_BIN.");
  process.exit(0);
}

const result = spawnSync(process.execPath, [new URL("./build-zmr.mjs", import.meta.url).pathname], {
  stdio: "inherit",
  env: {
    ...process.env,
    ...(binary ? { ZMR_BUILD_OUT: binary } : {}),
  },
});

if (result.status !== 0) {
  console.warn("zeno-mobile-runner: postinstall build failed; set ZMR_BIN or run `npm run build:zmr` after fixing Zig.");
}

function binaryMatchesPackageVersion(binaryPath, expectedVersion) {
  const result = spawnSync(binaryPath, ["version", "--json"], { encoding: "utf8" });
  if (result.status !== 0) return false;
  try {
    return JSON.parse(result.stdout).version === expectedVersion;
  } catch {
    return false;
  }
}
