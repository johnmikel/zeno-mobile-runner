#!/usr/bin/env node
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function parseArgs(argv) {
  let outDir = path.join(root, "dist");
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--out-dir") {
      outDir = path.resolve(argv[++index] ?? "");
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return { outDir };
}

async function readJson(relativePath) {
  return JSON.parse(await readFile(path.join(root, relativePath), "utf8"));
}

async function readText(relativePath) {
  return readFile(path.join(root, relativePath), "utf8");
}

function extractZigVersion(zon) {
  const match = zon.match(/\.minimum_zig_version\s*=\s*"([^"]+)"/);
  return match?.[1] ?? "UNKNOWN";
}

function spdxPackage({ name, version, supplier, downloadLocation, license, copyrightText, filesAnalyzed = false }) {
  return {
    name,
    SPDXID: `SPDXRef-Package-${name.replace(/[^A-Za-z0-9.-]/g, "-")}`,
    versionInfo: version,
    supplier,
    downloadLocation,
    filesAnalyzed,
    licenseConcluded: license,
    licenseDeclared: license,
    copyrightText,
  };
}

function markdownTable(rows) {
  const header = "| Component | Version | License | Notes |\n| --- | --- | --- | --- |";
  const body = rows.map((row) => `| ${row.component} | ${row.version} | ${row.license} | ${row.notes} |`).join("\n");
  return `${header}\n${body}\n`;
}

const { outDir } = parseArgs(process.argv.slice(2));
const packageJson = await readJson("package.json");
const zon = await readText("build.zig.zon");
const license = await readText("LICENSE");
const zigVersion = extractZigVersion(zon);
const now = new Date().toISOString();
const declaredLicense = packageJson.license ?? "NOASSERTION";

await mkdir(outDir, { recursive: true });

const packages = [
  spdxPackage({
    name: packageJson.name,
    version: packageJson.version,
    supplier: "Organization: Zeno Mobile Runner contributors",
    downloadLocation: "NOASSERTION",
    license: declaredLicense,
    copyrightText: "NOASSERTION",
    filesAnalyzed: false,
  }),
  spdxPackage({
    name: "Zig Standard Library",
    version: zigVersion,
    supplier: "Organization: Zig Software Foundation",
    downloadLocation: "https://ziglang.org/",
    license: "MIT",
    copyrightText: "NOASSERTION",
  }),
  spdxPackage({
    name: "Node.js Standard Library",
    version: packageJson.engines?.node ?? ">=18",
    supplier: "Organization: OpenJS Foundation and Node.js contributors",
    downloadLocation: "https://nodejs.org/",
    license: "MIT",
    copyrightText: "NOASSERTION",
  }),
  spdxPackage({
    name: "Python Standard Library",
    version: "3.x",
    supplier: "Organization: Python Software Foundation",
    downloadLocation: "https://www.python.org/",
    license: "Python-2.0",
    copyrightText: "NOASSERTION",
  }),
];

const relationships = packages.slice(1).map((pkg) => ({
  spdxElementId: "SPDXRef-Package-zeno-mobile-runner",
  relationshipType: "DEPENDS_ON",
  relatedSpdxElement: pkg.SPDXID,
}));

const sbom = {
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: `${packageJson.name}-${packageJson.version}-release-sbom`,
  documentNamespace: `https://zmr.dev/spdx/${packageJson.name}-${packageJson.version}-${now.replace(/[:.]/g, "-")}`,
  creationInfo: {
    created: now,
    creators: ["Tool: scripts/generate-release-metadata.mjs"],
    licenseListVersion: "3.25",
  },
  packages,
  relationships,
};

await writeFile(path.join(outDir, "SBOM.spdx.json"), `${JSON.stringify(sbom, null, 2)}\n`);

const runtimeDeps = Object.entries(packageJson.dependencies ?? {});
const devDeps = Object.entries(packageJson.devDependencies ?? {});
const noticeRows = [
  {
    component: packageJson.name,
    version: packageJson.version,
    license: declaredLicense,
    notes: "Project source and release archives.",
  },
  {
    component: "Zig Standard Library",
    version: zigVersion,
    license: "MIT",
    notes: "Used by the compiled ZMR binary.",
  },
  {
    component: "Node.js Standard Library",
    version: packageJson.engines?.node ?? ">=18",
    license: "MIT",
    notes: "Used by npm wrapper, setup, tests, and reference client scripts.",
  },
  {
    component: "Python Standard Library",
    version: "3.x",
    license: "Python-2.0",
    notes: "Used by the optional Python reference client and local scripts.",
  },
];

let notices = `# Third-Party Notices\n\nGenerated for ${packageJson.name} ${packageJson.version}.\n\n`;
notices += "## Dependency Summary\n\n";
notices += markdownTable(noticeRows);
notices += "\n";
notices += runtimeDeps.length === 0
  ? "No runtime npm dependencies are declared.\n\n"
  : `Runtime npm dependencies:\n\n${runtimeDeps.map(([name, version]) => `- ${name}@${version}`).join("\n")}\n\n`;
notices += devDeps.length === 0
  ? "No development npm dependencies are declared.\n\n"
  : `Development npm dependencies:\n\n${devDeps.map(([name, version]) => `- ${name}@${version}`).join("\n")}\n\n`;
notices += "## Project License\n\n";
notices += "The ZMR source and release package are distributed under the license in `LICENSE`:\n\n";
notices += "```text\n";
notices += license.trim();
notices += "\n```\n";

await writeFile(path.join(outDir, "THIRD_PARTY_NOTICES.md"), notices);

console.log(`wrote ${path.join(outDir, "SBOM.spdx.json")}`);
console.log(`wrote ${path.join(outDir, "THIRD_PARTY_NOTICES.md")}`);
