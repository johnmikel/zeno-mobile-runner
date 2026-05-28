#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

node scripts/generate-release-metadata.mjs --out-dir "$tmp"

test -s "$tmp/SBOM.spdx.json"
test -s "$tmp/THIRD_PARTY_NOTICES.md"

node - "$tmp/SBOM.spdx.json" <<'NODE'
const fs = require("node:fs");
const path = process.argv[2];
const sbom = JSON.parse(fs.readFileSync(path, "utf8"));
if (sbom.spdxVersion !== "SPDX-2.3") throw new Error("unexpected SPDX version");
if (!Array.isArray(sbom.packages)) throw new Error("packages missing");
const names = new Set(sbom.packages.map((pkg) => pkg.name));
for (const required of ["zeno-mobile-runner", "Zig Standard Library", "Node.js Standard Library"]) {
  if (!names.has(required)) throw new Error(`missing package ${required}`);
}
NODE

grep -F -q "No runtime npm dependencies" "$tmp/THIRD_PARTY_NOTICES.md"
grep -F -q "Zig Standard Library" "$tmp/THIRD_PARTY_NOTICES.md"
