#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${ZMR_VERSION:-$(awk -F'"' '/runner_version/ { print $2; exit }' "$ROOT/src/version.zig")}"
RELEASE_BASE_URL="${ZMR_RELEASE_BASE_URL:-https://github.com/johnmikel/zeno-mobile-runner/releases/download/v$VERSION}"

if ! command -v zig >/dev/null 2>&1; then
  echo "zig is required" >&2
  exit 127
fi

targets=(
  "aarch64-macos.15.0"
  "x86_64-macos.15.0"
  "x86_64-linux-gnu"
  "aarch64-linux-gnu"
)

rm -rf "$DIST"
mkdir -p "$DIST"

for target in "${targets[@]}"; do
  out_dir="$DIST/zmr-$VERSION-$target"
  mkdir -p "$out_dir"
  zig build-exe "$ROOT/src/main.zig" \
    -target "$target" \
    -O ReleaseSafe \
    -femit-bin="$out_dir/zmr"
  cp "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/SECURITY.md" "$ROOT/CONTRIBUTING.md" "$out_dir/"
  cp -R "$ROOT/docs" "$ROOT/examples" "$ROOT/schemas" "$ROOT/shims" "$ROOT/viewer" "$out_dir/"
  tar -C "$DIST" -czf "$out_dir.tar.gz" "$(basename "$out_dir")"
done

(
  cd "$DIST"
  shasum -a 256 ./*.tar.gz > SHA256SUMS
)

node "$ROOT/scripts/generate-release-metadata.mjs" --out-dir "$DIST"
node "$ROOT/scripts/generate-homebrew-formula.mjs" \
  --version "$VERSION" \
  --checksums "$DIST/SHA256SUMS" \
  --base-url "$RELEASE_BASE_URL" \
  --out "$DIST/homebrew/zmr.rb"
node "$ROOT/scripts/generate-release-manifest.mjs" \
  --dist "$DIST" \
  --version "$VERSION" \
  --out "$DIST/RELEASE_MANIFEST.json"

(
  cd "$DIST"
  shasum -a 256 ./*.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json > SHA256SUMS
)

printf 'Release artifacts written to %s\n' "$DIST"
