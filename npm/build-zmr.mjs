#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = process.env.ZMR_BUILD_OUT || path.join(root, "zig-out", "bin", process.platform === "win32" ? "zmr.exe" : "zmr");
fs.mkdirSync(path.dirname(out), { recursive: true });

const args = ["build-exe", "src/main.zig", "-O", "ReleaseSafe", `-femit-bin=${out}`];
if (process.platform === "darwin" && process.arch === "arm64") {
  args.splice(2, 0, "-target", "aarch64-macos.15.0");
}

const result = spawnSync("zig", args, { cwd: root, stdio: "inherit" });
if (result.error) {
  console.error(result.error.message);
  process.exit(127);
}
process.exit(result.status ?? 1);
