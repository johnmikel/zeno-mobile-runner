#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${ZMR_VERSION:-$(awk -F'"' '/runner_version/ { print $2; exit }' "$ROOT/src/version.zig")}"

./scripts/build-release.sh

rm -rf prebuilds
mkdir -p prebuilds

copy_prebuild() {
  local target="$1"
  local npm_platform="$2"
  local npm_arch="$3"
  local src="$ROOT/dist/zmr-$VERSION-$target/zmr"
  local out_dir="$ROOT/prebuilds/$npm_platform-$npm_arch"
  mkdir -p "$out_dir"
  cp "$src" "$out_dir/zmr"
  chmod +x "$out_dir/zmr"
}

copy_prebuild "aarch64-macos.15.0" "darwin" "arm64"
copy_prebuild "x86_64-macos.15.0" "darwin" "x64"
copy_prebuild "aarch64-linux-gnu" "linux" "arm64"
copy_prebuild "x86_64-linux-gnu" "linux" "x64"

node "$ROOT/npm/verify-publish.mjs"
npm pack --pack-destination "$ROOT/dist"

node "$ROOT/scripts/generate-release-manifest.mjs" \
  --dist "$ROOT/dist" \
  --version "$VERSION" \
  --out "$ROOT/dist/RELEASE_MANIFEST.json"

(
  cd "$ROOT/dist"
  shopt -s nullglob
  checksum_files=( ./*.tar.gz ./*.tgz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json )
  shopt -u nullglob
  shasum -a 256 "${checksum_files[@]}" > SHA256SUMS
)

printf 'npm package written to %s\n' "$ROOT/dist"
