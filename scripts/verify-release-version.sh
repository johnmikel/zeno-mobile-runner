#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/package.json"
SOURCE="$ROOT/src/version.zig"
MANIFEST="$ROOT/build.zig.zon"
EXPECTED="${ZMR_VERSION:-}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/verify-release-version.sh [--package package.json] [--source src/version.zig] [--manifest build.zig.zon] [--expected version]

Verifies that package.json, src/version.zig, build.zig.zon, and the optional
release version all describe the same ZMR runner version.
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --package)
      if [[ -z "${2:-}" ]]; then
        echo "--package requires a value" >&2
        exit 2
      fi
      PACKAGE="$2"
      shift 2
      ;;
    --source)
      if [[ -z "${2:-}" ]]; then
        echo "--source requires a value" >&2
        exit 2
      fi
      SOURCE="$2"
      shift 2
      ;;
    --manifest)
      if [[ -z "${2:-}" ]]; then
        echo "--manifest requires a value" >&2
        exit 2
      fi
      MANIFEST="$2"
      shift 2
      ;;
    --expected)
      if [[ -z "${2:-}" ]]; then
        echo "--expected requires a value" >&2
        exit 2
      fi
      EXPECTED="$2"
      shift 2
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

package_version="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$PACKAGE")"
source_version="$(awk -F'"' '/runner_version/ { print $2; exit }' "$SOURCE")"
manifest_version="$(awk -F'"' '/^[[:space:]]*\.version[[:space:]]*=/ { print $2; exit }' "$MANIFEST")"

status=0
if [[ -z "$package_version" ]]; then
  echo "package.json version is empty: $PACKAGE" >&2
  status=1
fi
if [[ -z "$source_version" ]]; then
  echo "src/version.zig runner_version is empty: $SOURCE" >&2
  status=1
fi
if [[ -z "$manifest_version" ]]; then
  echo "build.zig.zon version is empty: $MANIFEST" >&2
  status=1
fi
if [[ -n "$package_version" && -n "$manifest_version" && "$package_version" != "$manifest_version" ]]; then
  echo "build.zig.zon version $manifest_version does not match package.json version $package_version" >&2
  status=1
fi
if [[ -n "$package_version" && -n "$source_version" && "$package_version" != "$source_version" ]]; then
  echo "package.json version $package_version does not match src/version.zig runner_version $source_version" >&2
  status=1
fi
if [[ -n "$EXPECTED" && "$EXPECTED" != "$package_version" ]]; then
  echo "ZMR_VERSION $EXPECTED does not match package.json version $package_version" >&2
  status=1
fi
if [[ -n "$EXPECTED" && "$EXPECTED" != "$source_version" ]]; then
  echo "ZMR_VERSION $EXPECTED does not match src/version.zig runner_version $source_version" >&2
  status=1
fi

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

printf 'release version verified: %s\n' "$package_version"
