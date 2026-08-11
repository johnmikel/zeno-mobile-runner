// Guards the worked example in examples/cross-platform-evidence against drift.
//
// The example is a claim — "one evidence contract covers a web suite and a
// mobile suite" — and a claim that stops running is worse than no claim. Both
// halves of it depend on option sets that live in another file: the reporter's
// required options and the CLI's required flags. Neither is visible from the
// example, so both can grow without anyone touching it. These tests fail when
// that happens, without needing Playwright, a browser, or a device.
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import ZenoPlaywrightReporter from "../npm/evidence/playwright-reporter.mjs";
import { zenoReporterOptions } from "../examples/cross-platform-evidence/zeno-reporter-options.mjs";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const exampleDir = path.join(repositoryRoot, "examples", "cross-platform-evidence");

test("the example's reporter options satisfy the reporter's own validation", async (t) => {
  const rootDir = await mkdtemp(path.join(os.tmpdir(), "zmr-xp-example-"));
  t.after(async () => {
    await rm(rootDir, { recursive: true, force: true });
  });

  const options = zenoReporterOptions({ ZMR_WEB_EVIDENCE_OUT: path.join(rootDir, "web") });
  const reporter = new ZenoPlaywrightReporter(options);

  // The reporter records option failures rather than throwing, so an example
  // missing a newly-required option would otherwise look fine right up until a
  // reader ran it and got an unexplained failure.
  assert.equal(
    reporter.fatalError,
    null,
    `example reporter options rejected: ${reporter.fatalError?.message ?? ""}`,
  );
});

test("the example passes every flag the evidence CLI requires", async () => {
  const cliSource = await readFile(path.join(repositoryRoot, "npm", "evidence-cli.mjs"), "utf8");
  const block = /const REQUIRED_FROM_ZMR_OPTIONS = \[([^\]]*)\]/.exec(cliSource);
  assert.ok(block, "could not read REQUIRED_FROM_ZMR_OPTIONS from the evidence CLI");
  const required = [...block[1].matchAll(/"(--[a-z-]+)"/g)].map((match) => match[1]);
  assert.ok(required.includes("--trace"), "flag extraction produced an implausible list");

  const demo = await readFile(path.join(exampleDir, "run-demo.sh"), "utf8");
  const fromZmr = demo.slice(demo.indexOf("from-zmr"));
  for (const flag of required) {
    assert.ok(
      new RegExp(`\\s${flag}\\s`).test(fromZmr),
      `run-demo.sh must pass ${flag} to from-zmr`,
    );
  }
});

test("the example ships every file its runner copies into the consumer project", async () => {
  const demo = await readFile(path.join(exampleDir, "run-demo.sh"), "utf8");
  const copied = [...demo.matchAll(/cross-platform-evidence\/([\w.-]+)/g)].map((m) => m[1]);
  assert.ok(copied.length >= 4, "expected the runner to copy the example's source files");
  for (const name of new Set(copied)) {
    await assert.doesNotReject(
      readFile(path.join(exampleDir, name)),
      `run-demo.sh references examples/cross-platform-evidence/${name}, which is missing`,
    );
  }
});
