// The only Zeno-specific line in a Playwright project is the reporter entry.
// Everything else is an ordinary Playwright config, which is the point: Zeno
// attaches to the run you already have rather than replacing your driver.
import { defineConfig } from "@playwright/test";

import { zenoReporterOptions } from "./zeno-reporter-options.mjs";

// Defaults to the published package. The example's own script points this at a
// local checkout so the demo can run against unreleased changes.
const zenoReporter =
  process.env.ZMR_REPORTER_PATH ?? "zeno-mobile-runner/playwright-reporter";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.mjs",
  reporter: [
    ["list"],
    [zenoReporter, zenoReporterOptions()],
  ],
  // Ordinary Playwright artifact settings. Zeno does not ask for anything
  // special here — whatever your suite already captures is what gets hashed
  // into the bundle, which is why adopting this costs no test changes.
  use: { headless: true, screenshot: "on", trace: "on" },
});
