#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DIST="$TMPDIR/dist"
mkdir -p "$DIST/homebrew"

printf 'mac archive bytes\n' > "$DIST/zmr-0.1.2-aarch64-macos.15.0.tar.gz"
printf 'linux archive bytes\n' > "$DIST/zmr-0.1.2-x86_64-linux-gnu.tar.gz"
printf 'npm package bytes\n' > "$DIST/zeno-mobile-runner-0.1.2.tgz"
printf '{"spdxVersion":"SPDX-2.3"}\n' > "$DIST/SBOM.spdx.json"
printf '# Notices\n' > "$DIST/THIRD_PARTY_NOTICES.md"
printf 'class Zmr < Formula\nend\n' > "$DIST/homebrew/zmr.rb"

node "$ROOT/scripts/generate-release-manifest.mjs" \
  --dist "$DIST" \
  --version "0.1.2" \
  --out "$DIST/RELEASE_MANIFEST.json"

node - "$DIST" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const dist = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(path.join(dist, "RELEASE_MANIFEST.json"), "utf8"));
if (manifest.schemaVersion !== 1) throw new Error("unexpected schemaVersion");
if (manifest.name !== "zeno-mobile-runner") throw new Error("unexpected name");
if (manifest.version !== "0.1.2") throw new Error("unexpected version");
if (!manifest.generatedAt || Number.isNaN(Date.parse(manifest.generatedAt))) throw new Error("generatedAt missing");
if (!Array.isArray(manifest.artifacts)) throw new Error("artifacts missing");

const byPath = new Map(manifest.artifacts.map((artifact) => [artifact.path, artifact]));
for (const required of [
  "zmr-0.1.2-aarch64-macos.15.0.tar.gz",
  "zmr-0.1.2-x86_64-linux-gnu.tar.gz",
  "zeno-mobile-runner-0.1.2.tgz",
  "SBOM.spdx.json",
  "THIRD_PARTY_NOTICES.md",
  "homebrew/zmr.rb",
]) {
  const artifact = byPath.get(required);
  if (!artifact) throw new Error(`missing artifact ${required}`);
  const bytes = fs.readFileSync(path.join(dist, required));
  const sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
  if (artifact.sha256 !== sha256) throw new Error(`checksum mismatch for ${required}`);
  if (artifact.sizeBytes !== bytes.length) throw new Error(`size mismatch for ${required}`);
}

if (byPath.get("zmr-0.1.2-aarch64-macos.15.0.tar.gz").type !== "archive") throw new Error("archive type missing");
if (byPath.get("zmr-0.1.2-aarch64-macos.15.0.tar.gz").platform !== "macos") throw new Error("platform missing");
if (byPath.get("zmr-0.1.2-aarch64-macos.15.0.tar.gz").arch !== "aarch64") throw new Error("arch missing");
if (byPath.get("zeno-mobile-runner-0.1.2.tgz").type !== "npm-package") throw new Error("npm package type missing");
if (byPath.get("SBOM.spdx.json").type !== "sbom") throw new Error("sbom type missing");
if (byPath.get("THIRD_PARTY_NOTICES.md").type !== "notices") throw new Error("notices type missing");
if (byPath.get("homebrew/zmr.rb").type !== "homebrew-formula") throw new Error("formula type missing");
NODE

rm "$DIST/THIRD_PARTY_NOTICES.md"
if node "$ROOT/scripts/generate-release-manifest.mjs" --dist "$DIST" --version "0.1.2" --out "$DIST/RELEASE_MANIFEST.json" > "$TMPDIR/missing.out" 2>&1; then
  echo "expected release manifest generation to fail when required metadata is missing" >&2
  exit 1
fi
grep -q 'missing release artifact: THIRD_PARTY_NOTICES.md' "$TMPDIR/missing.out"
