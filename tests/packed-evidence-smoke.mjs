import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EXPECTED_NODE = "v18.20.8";
const EXPECTED_NPM = "10.9.8";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    ...options,
  });
  assert.equal(
    result.status,
    0,
    [
      `${command} ${args.join(" ")} failed with status ${result.status}`,
      result.stdout,
      result.stderr,
    ].filter(Boolean).join("\n"),
  );
  return result;
}

function listTree(directory, prefix = "") {
  const entries = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (["node_modules", ".npm-cache"].includes(entry.name)) continue;
    const relative = prefix.length === 0 ? entry.name : `${prefix}/${entry.name}`;
    entries.push(relative);
    if (entry.isDirectory()) entries.push(...listTree(path.join(directory, entry.name), relative));
  }
  return entries;
}

assert.equal(process.version, EXPECTED_NODE, "packed evidence smoke must use the exact Node floor");
const npmVersion = run("npm", ["--version"]).stdout.trim();
assert.equal(npmVersion, EXPECTED_NPM, "packed evidence smoke must use the exact npm floor");

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "zmr-packed-evidence-floor-"));
try {
  const npmEnv = {
    ...process.env,
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD: "1",
    npm_config_cache: path.join(tempRoot, ".npm-cache"),
    npm_config_audit: "false",
    npm_config_fund: "false",
  };
  run("npm", ["pack", "--pack-destination", tempRoot], { cwd: root, env: npmEnv });
  const tarballName = fs.readdirSync(tempRoot).find((name) => name.endsWith(".tgz"));
  assert.ok(tarballName, "npm pack must produce a tarball");
  const tarball = path.join(tempRoot, tarballName);
  const consumer = path.join(tempRoot, "consumer");
  fs.mkdirSync(consumer);
  fs.writeFileSync(path.join(consumer, "package.json"), `${JSON.stringify({
    name: "zmr-packed-evidence-floor",
    private: true,
    type: "module",
  }, null, 2)}\n`);

  run("npm", [
    "install",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    tarball,
    "@playwright/test@1.42.0",
    "typescript@5.4.5",
    "@types/node@18.19.130",
  ], { cwd: consumer, env: npmEnv });

  const binDir = path.join(consumer, "node_modules", ".bin");
  run(path.join(binDir, "zmr-evidence"), ["help"], { cwd: consumer, env: npmEnv });

  fs.writeFileSync(path.join(consumer, "tsconfig.json"), `${JSON.stringify({
    compilerOptions: {
      module: "NodeNext",
      moduleResolution: "NodeNext",
      target: "ES2022",
      lib: ["ES2022", "ESNext.Disposable"],
      types: ["node"],
      noEmit: true,
      strict: true,
      skipLibCheck: false,
    },
    include: ["typecheck.ts"],
  }, null, 2)}\n`);
  fs.writeFileSync(path.join(consumer, "typecheck.ts"), `
import ZenoPlaywrightReporter, {
  type ZenoPlaywrightReporterOptions,
  playwrightJourneyKey,
} from "zeno-mobile-runner/playwright-reporter";

const options: ZenoPlaywrightReporterOptions = {
  outputDir: "evidence",
  projectId: "packed-project",
  submitterType: "automation",
  submitterId: "packed-ci",
  releaseId: "packed-release",
  commitSha: "1111111111111111111111111111111111111111",
  deploymentId: "packed-deployment",
  environment: "test",
  configDigest: "sha256:${"d".repeat(64)}",
  buildManifestDigest: "sha256:${"c".repeat(64)}",
  browserName: "chromium",
  browserVersion: "123.0"
};

const reporter = new ZenoPlaywrightReporter(options);
const key: string = playwrightJourneyKey({
  projectName: "browserless",
  relativeFile: "tests/browserless.spec.mjs",
  titlePath: ["browserless reporter"]
});
void reporter;
void key;
`);
  run(path.join(binDir, "tsc"), ["--project", "tsconfig.json"], {
    cwd: consumer,
    env: npmEnv,
  });

  fs.mkdirSync(path.join(consumer, "tests"));
  fs.writeFileSync(path.join(consumer, "playwright.config.mjs"), `
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  workers: 1,
  projects: [{ name: "browserless" }],
  reporter: [["zeno-mobile-runner/playwright-reporter", {
    outputDir: "evidence",
    projectId: "packed-project",
    submitterType: "automation",
    submitterId: "packed-ci",
    releaseId: "packed-release",
    commitSha: "1111111111111111111111111111111111111111",
    deploymentId: "packed-deployment",
    environment: "test",
    configDigest: "sha256:${"d".repeat(64)}",
    buildManifestDigest: "sha256:${"c".repeat(64)}",
    browserName: "chromium",
    browserVersion: "123.0"
  }]]
});
`);
  fs.writeFileSync(path.join(consumer, "tests", "browserless.spec.mjs"), `
import { expect, test } from "@playwright/test";

test("browserless reporter", {
  annotation: { type: "zeno:journey", description: "packed.browserless" }
}, async () => {
  expect(2 + 2).toBe(4);
});
`);
  const playwrightRun = run(path.join(binDir, "playwright"), [
    "test",
    "--config=playwright.config.mjs",
    "--workers=1",
  ], { cwd: consumer, env: npmEnv });

  const evidencePath = path.join(consumer, "tests", "evidence", "evidence.json");
  assert.equal(
    fs.existsSync(evidencePath),
    true,
    [
      "Playwright must durably publish evidence.json",
      `stdout:\n${playwrightRun.stdout}`,
      `stderr:\n${playwrightRun.stderr}`,
      `consumer tree:\n${listTree(consumer).join("\n")}`,
    ].join("\n"),
  );
  run(path.join(binDir, "zmr-evidence"), ["validate", evidencePath], {
    cwd: consumer,
    env: npmEnv,
  });
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
