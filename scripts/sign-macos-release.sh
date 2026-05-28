#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${ZMR_VERSION:-$(awk -F'"' '/runner_version/ { print $2; exit }' "$ROOT/src/version.zig")}"
RELEASE_BASE_URL="${ZMR_RELEASE_BASE_URL:-https://github.com/johnmikel/zeno-mobile-runner/releases/download/v$VERSION}"
IDENTITY=""
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/sign-macos-release.sh --identity <codesign-identity> [--dist <dir>] [--dry-run]

Signs macOS release archive binaries with hardened runtime, verifies the
signature, rebuilds the affected archives, regenerates checksums, and refreshes
the generated Homebrew formula checksums.

Run this after scripts/build-release.sh and before uploading release assets.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value"
  fi
  printf '%s\n' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      IDENTITY="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --dist)
      DIST="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$IDENTITY" ]]; then
  echo "--identity is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$DIST" ]]; then
  echo "dist directory not found: $DIST" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]] && ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to sign macOS release archives" >&2
  exit 127
fi

shopt -s nullglob
archives=("$DIST"/*-macos*.tar.gz)
shopt -u nullglob

if [[ "${#archives[@]}" -eq 0 ]]; then
  echo "no macOS release archives found in $DIST" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  for archive in "${archives[@]}"; do
    printf 'would sign %s with identity %s\n' "$(basename "$archive")" "$IDENTITY"
  done
  printf 'would sign macOS archives: %d dist=%s\n' "${#archives[@]}" "$DIST"
  exit 0
fi

for required in SBOM.spdx.json THIRD_PARTY_NOTICES.md; do
  if [[ ! -f "$DIST/$required" ]]; then
    echo "missing release metadata: $required; run scripts/build-release.sh first" >&2
    exit 1
  fi
done

for archive in "${archives[@]}"; do
  base="$(basename "$archive" .tar.gz)"
  work="$(mktemp -d)"
  cleanup() {
    rm -rf "$work"
  }
  trap cleanup EXIT

  tar -C "$work" -xzf "$archive"
  binary="$work/$base/zmr"
  if [[ ! -f "$binary" ]]; then
    echo "archive does not contain expected zmr binary: $(basename "$archive")" >&2
    exit 1
  fi

  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$binary"
  codesign --verify --strict --verbose=2 "$binary"
  tar -C "$work" -czf "$archive.tmp" "$base"
  mv "$archive.tmp" "$archive"
  rm -rf "$work"
  trap - EXIT
done

(
  cd "$DIST"
  shasum -a 256 ./*.tar.gz > SHA256SUMS
)

mkdir -p "$DIST/homebrew"
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

"$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" >/dev/null
printf 'signed macOS archives: %d dist=%s\n' "${#archives[@]}" "$DIST"
