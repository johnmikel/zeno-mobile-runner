// The reporter options live here, apart from the Playwright config, for one
// reason: this file imports nothing from Playwright, so CI can construct the
// real reporter with these exact values and prove they still validate. A demo
// whose options quietly fall behind the reporter's requirements is worse than
// no demo, because it fails for the reader and not for us.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

export function zenoReporterOptions(env = process.env) {
  const configPath = path.join(here, "playwright.config.mjs");
  return {
    outputDir: env.ZMR_WEB_EVIDENCE_OUT ?? "evidence/web",
    projectId: env.ZMR_PROJECT_ID ?? "zeno-demo",
    submitterType: "automation",
    submitterId: "cross-platform-example",
    releaseId: env.ZMR_RELEASE_ID ?? "release-demo",
    commitSha: env.ZMR_COMMIT_SHA ?? "0".repeat(40),
    environment: "staging",
    deploymentId: env.ZMR_DEPLOYMENT_ID ?? "checkout-demo-local",
    runId: env.ZMR_WEB_RUN_ID ?? "web-run-demo",
    browserName: "chromium",
    browserVersion: env.ZMR_BROWSER_VERSION ?? "unknown",
    // Both digests come from bytes that exist rather than being invented: the
    // config is this example's own Playwright config, and the build manifest is
    // the lockfile that determines what actually ran.
    configDigest: `sha256:${createHash("sha256").update(readFileSync(configPath)).digest("hex")}`,
    buildManifestPath: path.join(here, "package-lock.json"),
  };
}
