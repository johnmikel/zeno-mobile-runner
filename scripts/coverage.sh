#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/zig-cache/coverage"
BIN="$OUT/zmr-tests"
MIN_COVERAGE="${MIN_COVERAGE:-90}"
KCOV_TIMEOUT_SECONDS="${ZMR_KCOV_TIMEOUT_SECONDS:-300}"

should_skip_kcov_on_hosted_macos() {
  [[ "${GITHUB_ACTIONS:-}" == "true" && "${RUNNER_OS:-}" == "macOS" && "${ZMR_FORCE_KCOV:-}" != "1" ]]
}

if ! command -v zig >/dev/null 2>&1; then
  echo "zig is required" >&2
  exit 127
fi

if ! should_skip_kcov_on_hosted_macos && ! command -v kcov >/dev/null 2>&1; then
  echo "kcov is required for coverage reports" >&2
  exit 127
fi

[[ "$KCOV_TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$KCOV_TIMEOUT_SECONDS" -ge 1 ]] || {
  echo "ZMR_KCOV_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
}

if [[ -z "${ZIG_TARGET:-}" ]]; then
  if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    ZIG_TARGET="aarch64-macos.15.0"
  else
    ZIG_TARGET="native"
  fi
fi

target_args=()
if [[ "$ZIG_TARGET" != "native" ]]; then
  target_args=(-target "$ZIG_TARGET")
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# The suite touches libc (std.c.chmod in the iOS shim tests), so the test
# binary must link it. Harmless on macOS, required on Linux.
if [[ "$ZIG_TARGET" == "native" ]]; then
  zig test "$ROOT/src/test_harness.zig" -lc --test-no-exec -femit-bin="$BIN"
else
  zig test "$ROOT/src/test_harness.zig" "${target_args[@]}" -lc --test-no-exec -femit-bin="$BIN"
fi


if should_skip_kcov_on_hosted_macos; then
  "$BIN"
  echo "Coverage: skipped on GitHub Actions macOS because kcov can hang while tracing child device-tool processes."
  echo "Coverage gate: run ./scripts/coverage.sh locally, or set ZMR_FORCE_KCOV=1 to force kcov on hosted macOS."
  exit 0
fi

run_kcov_with_timeout() {
  local kcov_stdout="$OUT/kcov.stdout"
  local kcov_stderr="$OUT/kcov.stderr"
  kcov --include-path="$ROOT/src" "$OUT/kcov" "$BIN" >"$kcov_stdout" 2>"$kcov_stderr" &
  local kcov_pid="$!"
  (
    sleep "$KCOV_TIMEOUT_SECONDS"
    if kill -0 "$kcov_pid" 2>/dev/null; then
      echo "kcov timed out after $KCOV_TIMEOUT_SECONDS second(s). Set ZMR_KCOV_TIMEOUT_SECONDS to adjust the limit." >&2
      pkill -TERM -P "$kcov_pid" 2>/dev/null || true
      kill -TERM "$kcov_pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$kcov_pid" 2>/dev/null || true
      kill -KILL "$kcov_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid="$!"
  local status=0
  wait "$kcov_pid" || status="$?"
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  cat "$kcov_stdout"
  cat "$kcov_stderr" >&2
  return "$status"
}

run_kcov_with_timeout

report_json="$(find "$OUT/kcov" -path '*/zmr-tests.*/coverage.json' -print -quit)"
if [[ -z "$report_json" ]]; then
  echo "coverage.json was not generated" >&2
  exit 1
fi

coverage="$(awk -F'"' '/^  "percent_covered"/ { print $4; exit }' "$report_json")"
covered_lines="$(awk -F'[: ,]+' '/^  "covered_lines"/ { print $3; exit }' "$report_json")"
total_lines="$(awk -F'[: ,]+' '/^  "total_lines"/ { print $3; exit }' "$report_json")"

printf 'Coverage: %s%% (%s/%s lines)\n' "$coverage" "$covered_lines" "$total_lines"
printf 'Report: %s\n' "$report_json"

awk -v actual="$coverage" -v minimum="$MIN_COVERAGE" 'BEGIN { exit (actual + 0 >= minimum + 0) ? 0 : 1 }' || {
  printf 'Coverage gate failed: %s%% < %s%%\n' "$coverage" "$MIN_COVERAGE" >&2
  exit 1
}
