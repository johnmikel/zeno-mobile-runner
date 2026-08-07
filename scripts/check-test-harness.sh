#!/usr/bin/env bash
# Fail when a src/*_tests.zig file is not wired into src/test_harness.zig.
#
# Why this exists: the harness is a hand-maintained registry, and `zig build
# test` roots at it. A new test file that nobody adds here compiles fine, is
# never run, and looks exactly like a passing suite. That is the same
# false-green shape as the build.zig wiring bug, so it gets a guard.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$ROOT/src/test_harness.zig"

[[ -f "$HARNESS" ]] || {
  echo "test harness not found: $HARNESS" >&2
  exit 1
}

status=0
for path in "$ROOT"/src/*_tests.zig; do
  name="$(basename "$path" .zig)"
  # Must be imported AND referenced in the test block; an unreferenced import
  # does not pull the file's tests into the binary.
  if ! grep -q "@import(\"${name}.zig\")" "$HARNESS"; then
    echo "test file not imported by src/test_harness.zig: src/${name}.zig" >&2
    status=1
    continue
  fi
  if ! grep -qE "^[[:space:]]*_ = ${name};" "$HARNESS"; then
    echo "test file imported but never referenced in the test block: src/${name}.zig" >&2
    status=1
  fi
done

if [[ "$status" -ne 0 ]]; then
  echo >&2
  echo "  Add the missing entries to src/test_harness.zig, or those tests never run." >&2
  exit 1
fi

count="$(find "$ROOT/src" -name '*_tests.zig' -type f | wc -l | tr -d ' ')"
printf 'test harness registers all %s test files\n' "$count"
