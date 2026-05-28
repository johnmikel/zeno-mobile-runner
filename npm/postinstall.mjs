#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { resolveBinary } from "./index.mjs";

if (resolveBinary()) process.exit(0);
if (process.env.ZMR_SKIP_POSTINSTALL_BUILD === "1") process.exit(0);

const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;
if (!hasZig) {
  console.warn("zeno-mobile-runner: no prebuilt zmr binary found and Zig is not installed.");
  console.warn("zeno-mobile-runner: install a release package with prebuilds, install Zig and run `npm run build:zmr`, or set ZMR_BIN.");
  process.exit(0);
}

const result = spawnSync(process.execPath, [new URL("./build-zmr.mjs", import.meta.url).pathname], {
  stdio: "inherit",
});

if (result.status !== 0) {
  console.warn("zeno-mobile-runner: postinstall build failed; set ZMR_BIN or run `npm run build:zmr` after fixing Zig.");
}
