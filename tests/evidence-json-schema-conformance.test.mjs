import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { validateEvidenceManifest } from "../npm/evidence/contract.mjs";

const execFileAsync = promisify(execFile);
const fixturesUrl = new URL("../fixtures/evidence/v1/", import.meta.url);
const catalog = JSON.parse(await readFile(new URL("cases.json", fixturesUrl), "utf8"));
const schema = JSON.parse(
  await readFile(new URL("../schemas/evidence-v1.schema.json", import.meta.url), "utf8"),
);

function uniqueIssueCodes(issues) {
  return [...new Set(issues.map(({ code }) => code))].sort();
}

test("public fixtures conform independently through Draft 2020-12 and runtime validation", {
  timeout: 120_000,
}, async () => {
  const consumer = await mkdtemp(join(tmpdir(), "zmr-evidence-ajv-"));
  try {
    const packagePath = join(consumer, "package.json");
    await writeFile(packagePath, JSON.stringify({ private: true }), "utf8");
    await execFileAsync(
      "npm",
      [
        "install",
        "--ignore-scripts",
        "--no-save",
        "--no-package-lock",
        "ajv@8.20.0",
        "ajv-formats@3.0.1",
      ],
      {
        cwd: consumer,
        env: {
          ...process.env,
          npm_config_audit: "false",
          npm_config_fund: "false",
          npm_config_update_notifier: "false",
        },
      },
    );

    const consumerRequire = createRequire(packagePath);
    const Ajv2020 = consumerRequire("ajv/dist/2020").default;
    const addFormats = consumerRequire("ajv-formats");
    const ajv = new Ajv2020({ allErrors: true, strict: false });
    addFormats(ajv);
    const validateSchema = ajv.compile(schema);

    const manifestCases = catalog.filter(({ kind }) => kind === "manifest" || kind === "package");
    for (const entry of manifestCases) {
      const manifest = JSON.parse(await readFile(new URL(entry.input, fixturesUrl), "utf8"));
      const schemaValid = validateSchema(manifest);
      assert.equal(
        schemaValid,
        entry.expectedSchemaValid,
        `${entry.id} schema errors: ${JSON.stringify(validateSchema.errors)}`,
      );

      const semantic = validateEvidenceManifest(manifest);
      assert.equal(
        semantic.ok,
        entry.expectedSemanticValid,
        `${entry.id} semantic errors: ${JSON.stringify(semantic.issues)}`,
      );
      if (!entry.expectedSemanticValid) {
        assert.deepEqual(
          uniqueIssueCodes(semantic.issues),
          entry.expectedIssueCodes,
          `${entry.id} semantic issue codes`,
        );
      }
    }
  } finally {
    await rm(consumer, { recursive: true, force: true });
  }
});
