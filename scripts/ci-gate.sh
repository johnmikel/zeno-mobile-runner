#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
HOST_ZIG_TARGET=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/ci-gate.sh [--dry-run]

Runs the fast public CI gate for normal pushes and pull requests. Release
artifact packaging remains in scripts/release-gate.sh and the tag workflow.
USAGE
}

run() {
  local command="$1"
  printf '+ %s\n' "$command"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    eval "$command"
  fi
}

detect_host_zig_target() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
      printf '%s\n' "aarch64-macos.15.0"
      ;;
    Darwin-x86_64)
      printf '%s\n' "x86_64-macos.15.0"
      ;;
    Linux-aarch64|Linux-arm64)
      printf '%s\n' "aarch64-linux-gnu"
      ;;
    Linux-x86_64)
      printf '%s\n' "x86_64-linux-gnu"
      ;;
    *)
      printf '%s\n' "aarch64-macos.15.0"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

HOST_ZIG_TARGET="$(detect_host_zig_target)"

run "zig fmt --check build.zig src"
run "bash -n install.sh scripts/*.sh tests/*.sh"
run "python3 -m compileall -q scripts/run_evidence_lib scripts/run_evidence.py"
run "python3 -W error -m unittest tests/run_evidence_test.py"
run "/bin/bash tests/run-evidence-script-test.sh"
run "/bin/bash tests/run-evidence-acceptance-test.sh"
run "npm ci --ignore-scripts"
run "node --test tests/schemas-contract.test.mjs"
run "mkdir -p zig-out/bin"
run "zig build-exe src/main.zig -target $HOST_ZIG_TARGET -O Debug -femit-bin=zig-out/bin/zmr"
run "bash tests/benchmark-lab-test.sh"
run "bash tests/benchmark-results-test.sh"
run "bash tests/device-matrix-test.sh"
run "bash tests/android-emulator-script-test.sh"
run "bash tests/android-shim-install-script-test.sh"
run "bash tests/android-pilot-script-test.sh"
run "bash tests/pilot-gate-script-test.sh"
run "bash tests/ios-demo-app-script-test.sh"
run "bash tests/ios-real-demo-script-test.sh"
run "bash tests/ios-shim-source-test.sh"
run "bash tests/ios-shim-install-script-test.sh"
run "bash tests/ios-shim-target-helper-test.sh"
run "bash tests/ios-pilot-script-test.sh"
run "bash tests/react-native-expo-demo-app-script-test.sh"
run "bash tests/release-candidate-script-test.sh"
run "bash tests/release-readiness-script-test.sh"
run "bash tests/release-gate-script-test.sh"
run "bash tests/ci-gate-script-test.sh"
run "bash tests/release-metadata-test.sh"
run "bash tests/release-manifest-test.sh"
run "bash tests/release-integrity-test.sh"
run "bash tests/macos-signing-script-test.sh"
run "bash tests/macos-notarization-script-test.sh"
run "bash tests/homebrew-formula-test.sh"
run "bash tests/install-script-test.sh"
run "bash tests/public-metadata-guard-test.sh"
run "bash tests/docs-readiness-test.sh"
run "bash tests/workflow-readiness-test.sh"
run "bash tests/demo-script-test.sh"
run "bash tests/mcp-server-test.sh"
run "node --test tests/npm-package.test.mjs"
run "bash tests/go-client-test.sh"
run "bash tests/rust-client-test.sh"
run "if command -v swift >/dev/null 2>&1; then swift test --package-path clients/swift; else echo 'skip swift test: swift not found'; fi"
run "bash tests/kotlin-client-static-test.sh"
run "if command -v gradle >/dev/null 2>&1; then gradle -p clients/kotlin test; else echo 'skip kotlin test: gradle not found'; fi"
run "bash tests/public-safety-test.sh"
run "node --test tests/viewer-parser.test.mjs"
run "zig test src/test_harness.zig -target $HOST_ZIG_TARGET"
run "bash tests/version-json-test.sh"
run "bash tests/schemas-json-test.sh"
run "bash tests/inspect-json-test.sh"
run "bash tests/devices-json-test.sh"
run "bash tests/cli-error-test.sh"
run "bash tests/validate-json-test.sh"
run "bash tests/explain-json-test.sh"
run "bash tests/run-json-test.sh"
run "bash tests/init-app-test.sh"
run "bash tests/import-flow-yaml-test.sh"
run "bash tests/doctor-config-test.sh"
run "bash tests/doctor-strict-test.sh"
run "./zig-out/bin/zmr validate examples/android-app-auth-probe.json"
run "./zig-out/bin/zmr validate examples/ios-smoke.json"
run "./zig-out/bin/zmr doctor --strict --adb ./tests/fake-adb.sh --xcrun ./tests/fake-xcrun.sh"
run "./scripts/demo.sh"
run "./scripts/coverage.sh"
run "npm pack --dry-run"
