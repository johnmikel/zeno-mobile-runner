#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DIST="$TMPDIR/dist"
mkdir -p "$DIST/homebrew"

DIST_NO_NPM="$TMPDIR/dist-no-npm"
mkdir -p "$DIST_NO_NPM/homebrew"
printf 'archive bytes\n' > "$DIST_NO_NPM/zmr-0.1.4-aarch64-macos.15.0.tar.gz"
printf '{"spdxVersion":"SPDX-2.3"}\n' > "$DIST_NO_NPM/SBOM.spdx.json"
printf '# Notices\n' > "$DIST_NO_NPM/THIRD_PARTY_NOTICES.md"
printf 'class Zmr < Formula\nend\n' > "$DIST_NO_NPM/homebrew/zmr.rb"
node "$ROOT/scripts/generate-release-manifest.mjs" --dist "$DIST_NO_NPM" --version "0.1.4" --out "$DIST_NO_NPM/RELEASE_MANIFEST.json" >/dev/null
(
  cd "$DIST_NO_NPM"
  shasum -a 256 zmr-0.1.4-aarch64-macos.15.0.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json > SHA256SUMS
)
"$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST_NO_NPM" > "$TMPDIR/verify-no-npm.out"
grep -q 'verified release artifacts' "$TMPDIR/verify-no-npm.out"

printf 'archive bytes\n' > "$DIST/zmr-0.1.4-aarch64-macos.15.0.tar.gz"
printf 'npm package bytes\n' > "$DIST/zeno-mobile-runner-0.1.4.tgz"
printf '{"spdxVersion":"SPDX-2.3"}\n' > "$DIST/SBOM.spdx.json"
printf '# Notices\n' > "$DIST/THIRD_PARTY_NOTICES.md"
printf 'class Zmr < Formula\nend\n' > "$DIST/homebrew/zmr.rb"
node "$ROOT/scripts/generate-release-manifest.mjs" --dist "$DIST" --version "0.1.4" --out "$DIST/RELEASE_MANIFEST.json" >/dev/null

(
  cd "$DIST"
  shasum -a 256 zmr-0.1.4-aarch64-macos.15.0.tar.gz zeno-mobile-runner-0.1.4.tgz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json > SHA256SUMS
)

"$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" > "$TMPDIR/verify.out"
grep -q 'verified release artifacts' "$TMPDIR/verify.out"
grep -q 'archives=1' "$TMPDIR/verify.out"

for args in "--dist"; do
  set +e
  missing_value_output="$("$ROOT/scripts/verify-release-artifacts.sh" $args --help 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "release artifact verification should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

(
  cd "$DIST"
  shasum -a 256 zmr-0.1.4-aarch64-macos.15.0.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json > SHA256SUMS
)
if "$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" > "$TMPDIR/missing-npm-entry.out" 2>&1; then
  echo "expected integrity verification to fail when the npm tarball is absent from SHA256SUMS" >&2
  exit 1
fi
grep -q 'missing checksum entry: zeno-mobile-runner-0.1.4.tgz' "$TMPDIR/missing-npm-entry.out"

(
  cd "$DIST"
  shasum -a 256 zmr-0.1.4-aarch64-macos.15.0.tar.gz zeno-mobile-runner-0.1.4.tgz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json > SHA256SUMS
)

printf 'tampered\n' >> "$DIST/SBOM.spdx.json"
if "$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" > "$TMPDIR/tampered.out" 2>&1; then
  echo "expected integrity verification to fail after tampering" >&2
  exit 1
fi
grep -q 'checksum mismatch' "$TMPDIR/tampered.out"

(
  cd "$DIST"
  shasum -a 256 zmr-0.1.4-aarch64-macos.15.0.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md > SHA256SUMS
)
if "$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" > "$TMPDIR/missing-entry.out" 2>&1; then
  echo "expected integrity verification to fail when required files are absent from SHA256SUMS" >&2
  exit 1
fi
grep -q 'missing checksum entry: homebrew/zmr.rb' "$TMPDIR/missing-entry.out"

(
  cd "$DIST"
  shasum -a 256 zmr-0.1.4-aarch64-macos.15.0.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb > SHA256SUMS
)
if "$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" > "$TMPDIR/missing-manifest-entry.out" 2>&1; then
  echo "expected integrity verification to fail when release manifest is absent from SHA256SUMS" >&2
  exit 1
fi
grep -q 'missing checksum entry: RELEASE_MANIFEST.json' "$TMPDIR/missing-manifest-entry.out"
