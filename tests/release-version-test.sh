#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_VERSION="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$ROOT/package.json")"
SOURCE_VERSION="$(awk -F'"' '/runner_version/ { print $2; exit }' "$ROOT/src/version.zig")"

"$ROOT/scripts/verify-release-version.sh" > /dev/null
ZMR_VERSION="$PACKAGE_VERSION" "$ROOT/scripts/verify-release-version.sh" > /dev/null

if [[ "$PACKAGE_VERSION" != "$SOURCE_VERSION" ]]; then
  echo "test setup requires package.json and src/version.zig to start in sync" >&2
  exit 1
fi

set +e
mismatch_output="$(ZMR_VERSION="999.999.999" "$ROOT/scripts/verify-release-version.sh" 2>&1)"
mismatch_status=$?
set -e
if [[ "$mismatch_status" -eq 0 ]]; then
  echo "expected verify-release-version to fail when ZMR_VERSION does not match source/package versions" >&2
  exit 1
fi
grep -q "ZMR_VERSION 999.999.999 does not match package.json version $PACKAGE_VERSION" <<< "$mismatch_output"
grep -q "ZMR_VERSION 999.999.999 does not match src/version.zig runner_version $SOURCE_VERSION" <<< "$mismatch_output"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cp "$ROOT/package.json" "$TMPDIR/package.json"
cp "$ROOT/src/version.zig" "$TMPDIR/version.zig"

node - "$TMPDIR/package.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
pkg.version = "123.123.123";
fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
NODE

set +e
package_mismatch_output="$("$ROOT/scripts/verify-release-version.sh" --package "$TMPDIR/package.json" --source "$TMPDIR/version.zig" 2>&1)"
package_mismatch_status=$?
set -e
if [[ "$package_mismatch_status" -eq 0 ]]; then
  echo "expected verify-release-version to fail when package.json and src/version.zig differ" >&2
  exit 1
fi
grep -q "package.json version 123.123.123 does not match src/version.zig runner_version $SOURCE_VERSION" <<< "$package_mismatch_output"

# build.zig.zon drifted unnoticed for 11 releases; the manifest is now part of
# the same check.
sed 's/^\([[:space:]]*\)\.version = "[^"]*"/\1.version = "9.9.9"/' "$ROOT/build.zig.zon" > "$TMPDIR/build.zig.zon"
set +e
manifest_mismatch_output="$("$ROOT/scripts/verify-release-version.sh" --manifest "$TMPDIR/build.zig.zon" 2>&1)"
manifest_mismatch_status=$?
set -e
if [[ "$manifest_mismatch_status" -eq 0 ]]; then
  echo "expected verify-release-version to fail when build.zig.zon disagrees with package.json" >&2
  exit 1
fi
grep -q "build.zig.zon version 9.9.9 does not match package.json version $PACKAGE_VERSION" <<< "$manifest_mismatch_output"
