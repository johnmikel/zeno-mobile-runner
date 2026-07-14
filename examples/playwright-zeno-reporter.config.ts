import { defineConfig } from "@playwright/test";

// ZENO_CONFIG_DIGEST must cover an allowlisted, non-secret configuration
// document. Never digest or publish raw environment secrets.
export default defineConfig({
  reporter: [
    ["zeno-mobile-runner/playwright-reporter", {
      outputDir: "zeno-evidence/web",
      projectId: process.env.ZENO_PROJECT_ID!,
      submitterType: "automation",
      submitterId: process.env.ZENO_SUBMITTER_ID!,
      releaseId: process.env.ZENO_RELEASE_ID!,
      commitSha: process.env.GITHUB_SHA!,
      deploymentId: process.env.ZENO_DEPLOYMENT_ID!,
      environment: "staging",
      buildManifestPath: "dist/manifest.json",
      configDigest: process.env.ZENO_CONFIG_DIGEST!,
      browserName: "chromium",
      browserVersion: process.env.ZENO_BROWSER_VERSION!,
    }],
  ],
});
