#!/usr/bin/env node
// Maintainer helper: captures the static trace viewer and an HTML report with
// headless Chromium for the public docs/assets/ screenshots. Requires
// Playwright (`npm exec --yes playwright install chromium` on first use).
// Invoked by scripts/capture-screenshots.sh; both files are excluded from the
// published npm package.

import { parseArgs } from "node:util";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const { values } = parseArgs({
  options: {
    viewer: { type: "string" },
    bundle: { type: "string" },
    report: { type: "string" },
    out: { type: "string" },
  },
});

if (!values.viewer || !values.bundle || !values.out) {
  console.error(
    "usage: capture-viewer-shots.mjs --viewer viewer/index.html --bundle trace.zmrtrace [--report report.html] --out docs/assets",
  );
  process.exit(2);
}

let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  console.error(
    "error: playwright is not installed; run `npm exec --yes playwright install chromium` or capture manually",
  );
  process.exit(3);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

await page.goto(pathToFileURL(resolve(values.viewer)).href);
await page.setInputFiles("#bundleInput", resolve(values.bundle));
await page.waitForSelector("#viewerGrid:not([hidden])", { timeout: 30_000 });

const screenshotRow = page
  .locator(".event-row", { hasText: "observe.snapshot" })
  .first();
if (await screenshotRow.count()) {
  await screenshotRow.click();
}
await page.waitForTimeout(500);

await page.screenshot({
  path: resolve(values.out, "viewer-hero.png"),
  fullPage: false,
});

const replayPanel = page.locator(".replay-panel").first();
if (await replayPanel.count()) {
  await replayPanel.screenshot({
    path: resolve(values.out, "viewer-replay.png"),
  });
}

if (values.report) {
  await page.goto(pathToFileURL(resolve(values.report)).href);
  await page.waitForTimeout(500);
  await page.screenshot({
    path: resolve(values.out, "report-html.png"),
    fullPage: false,
  });
}

await browser.close();
console.log(`wrote viewer screenshots to ${values.out}`);
