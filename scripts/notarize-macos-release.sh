#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${ZMR_VERSION:-$(awk -F'"' '/runner_version/ { print $2; exit }' "$ROOT/src/version.zig")}"
RELEASE_BASE_URL="${ZMR_RELEASE_BASE_URL:-https://github.com/johnmikel/zeno-mobile-runner/releases/download/v$VERSION}"
KEYCHAIN_PROFILE=""
APPLE_ID=""
TEAM_ID=""
PASSWORD=""
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/notarize-macos-release.sh [--dist <dir>] [--dry-run]
    --keychain-profile <profile>
    OR --apple-id <email> --team-id <team-id> --password <app-specific-password>

Packages each signed macOS release archive as a temporary zip, submits it to
Apple notarytool with --wait, stores JSON receipts under dist/notarization/,
refreshes RELEASE_MANIFEST.json and SHA256SUMS, and verifies release artifacts.

Run this after scripts/sign-macos-release.sh and before uploading release assets.
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
    --dist)
      DIST="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --keychain-profile)
      KEYCHAIN_PROFILE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --password)
      PASSWORD="$(require_value "$1" "${2-}")"
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

if [[ ! -d "$DIST" ]]; then
  echo "dist directory not found: $DIST" >&2
  exit 1
fi

if [[ -z "$KEYCHAIN_PROFILE" ]]; then
  if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$PASSWORD" ]]; then
    echo "notarization credentials are required" >&2
    usage >&2
    exit 2
  fi
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required to notarize macOS release archives" >&2
    exit 127
  fi
  if ! command -v ditto >/dev/null 2>&1; then
    echo "ditto is required to package macOS release archives for notarization" >&2
    exit 127
  fi
fi

for required in SBOM.spdx.json THIRD_PARTY_NOTICES.md RELEASE_MANIFEST.json; do
  if [[ ! -f "$DIST/$required" ]]; then
    echo "missing release metadata: $required; run scripts/build-release.sh first" >&2
    exit 1
  fi
done

shopt -s nullglob
archives=("$DIST"/*-macos*.tar.gz)
shopt -u nullglob

if [[ "${#archives[@]}" -eq 0 ]]; then
  echo "no macOS release archives found in $DIST" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  for archive in "${archives[@]}"; do
    printf 'would notarize %s\n' "$(basename "$archive")"
  done
  printf 'would notarize macOS archives: %d dist=%s\n' "${#archives[@]}" "$DIST"
  exit 0
fi

mkdir -p "$DIST/notarization"

credential_args=()
if [[ -n "$KEYCHAIN_PROFILE" ]]; then
  credential_args+=(--keychain-profile "$KEYCHAIN_PROFILE")
else
  credential_args+=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD")
fi

for archive in "${archives[@]}"; do
  base="$(basename "$archive" .tar.gz)"
  work="$(mktemp -d)"
  cleanup() {
    rm -rf "$work"
  }
  trap cleanup EXIT

  tar -C "$work" -xzf "$archive"
  if [[ ! -f "$work/$base/zmr" ]]; then
    echo "archive does not contain expected zmr binary: $(basename "$archive")" >&2
    exit 1
  fi

  submission_zip="$work/$base.notary.zip"
  ditto -c -k --keepParent "$work/$base" "$submission_zip"
  receipt="$DIST/notarization/$base.notary.json"
  xcrun notarytool submit "$submission_zip" --wait --output-format json "${credential_args[@]}" > "$receipt"
  rm -rf "$work"
  trap - EXIT
done

(
  cd "$DIST"
  shasum -a 256 ./*.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb notarization/*.notary.json > SHA256SUMS
)

node "$ROOT/scripts/generate-release-manifest.mjs" \
  --dist "$DIST" \
  --version "$VERSION" \
  --out "$DIST/RELEASE_MANIFEST.json"

(
  cd "$DIST"
  shasum -a 256 ./*.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json notarization/*.notary.json > SHA256SUMS
)

"$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" >/dev/null
printf 'notarized macOS archives: %d dist=%s\n' "${#archives[@]}" "$DIST"
