#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
HOST_ZIG_TARGET=""
LIST_PHASES=0
SELECTED_PHASES=()
PHASES=(
  static
  platform-scripts
  clients
  protocol-smoke
  release-artifacts
)

usage() {
  cat <<'USAGE'
Usage:
  scripts/release-gate.sh [--dry-run] [--phase <name>]
  scripts/release-gate.sh --list-phases

Runs the local V1 dev-preview release gate. Real Android/iOS pilot runs still
require app builds and devices, so this script prints those commands as the
final external gate.
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

list_phases() {
  printf '%s\n' "${PHASES[@]}"
}

is_known_phase() {
  local requested="$1"
  local phase
  for phase in "${PHASES[@]}"; do
    if [[ "$phase" == "$requested" ]]; then
      return 0
    fi
  done
  return 1
}

require_phase_value() {
  local value="${1-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "error: --phase requires a value" >&2
    exit 2
  fi
  if ! is_known_phase "$value"; then
    echo "error: unknown release gate phase: $value" >&2
    list_phases >&2
    exit 2
  fi
  printf '%s\n' "$value"
}

phase_header() {
  local phase="$1"
  printf '== release gate phase: %s ==\n' "$phase"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --phase)
      SELECTED_PHASES+=("$(require_phase_value "${2-}")")
      shift 2
      ;;
    --list-phases)
      LIST_PHASES=1
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

if [[ "$LIST_PHASES" -eq 1 ]]; then
  list_phases
  exit 0
fi

if [[ "${#SELECTED_PHASES[@]}" -eq 0 ]]; then
  SELECTED_PHASES=("${PHASES[@]}")
fi

HOST_ZIG_TARGET="$(detect_host_zig_target)"

run_static_phase() {
  phase_header static
  run "zig fmt --check build.zig src"
  run "bash -n install.sh scripts/*.sh tests/*.sh"
  run "python3 -m py_compile scripts/*.py"
  run "python3 -W error -m unittest tests/run_evidence_test.py"
  run "/bin/bash tests/run-evidence-script-test.sh"
  run "/bin/bash tests/run-evidence-acceptance-test.sh"
  run "./scripts/verify-release-version.sh"
  run "mkdir -p zig-out/bin"
  run "zig build-exe src/main.zig -target $HOST_ZIG_TARGET -O Debug -femit-bin=zig-out/bin/zmr"
  run "bash tests/benchmark-lab-test.sh"
  run "bash tests/benchmark-results-test.sh"
  run "bash tests/device-matrix-test.sh"
  run "bash tests/android-emulator-script-test.sh"
  run "bash tests/release-candidate-script-test.sh"
  run "bash tests/release-version-test.sh"
  run "bash tests/release-readiness-script-test.sh"
  run "bash tests/coverage-script-test.sh"
  run "bash tests/release-gate-script-test.sh"
  run "bash tests/ci-gate-script-test.sh"
  run "bash tests/release-metadata-test.sh"
  run "bash tests/release-manifest-test.sh"
  run "bash tests/release-integrity-test.sh"
  run "bash tests/release-smoke-script-test.sh"
  run "bash tests/macos-signing-script-test.sh"
  run "bash tests/macos-notarization-script-test.sh"
  run "bash tests/homebrew-formula-test.sh"
  run "bash tests/install-script-test.sh"
  run "bash tests/public-metadata-guard-test.sh"
  run "bash tests/docs-readiness-test.sh"
  run "bash tests/workflow-readiness-test.sh"
  run "bash tests/demo-script-test.sh"
  run "bash tests/mcp-server-test.sh"
  run "bash tests/rpc-draft-test.sh"
}

run_platform_scripts_phase() {
  phase_header platform-scripts
  run "bash tests/android-demo-app-script-test.sh"
  run "bash tests/android-real-demo-script-test.sh"
  run "bash tests/android-shim-install-script-test.sh"
  run "bash tests/android-pilot-script-test.sh"
  run "bash tests/pilot-gate-script-test.sh"
  run "bash tests/ios-demo-app-script-test.sh"
  run "bash tests/ios-real-demo-script-test.sh"
  run "bash tests/ios-shim-source-test.sh"
  run "bash tests/ios-shim-install-script-test.sh"
  run "bash tests/ios-shim-target-helper-test.sh"
  run "bash tests/ios-pilot-script-test.sh"
}

run_clients_phase() {
  phase_header clients
  run "node --test tests/npm-package.test.mjs"
  run "bash tests/go-client-test.sh"
  run "bash tests/rust-client-test.sh"
  run "if command -v swift >/dev/null 2>&1; then swift test --package-path clients/swift; else echo 'skip swift test: swift not found'; fi"
  run "bash tests/kotlin-client-static-test.sh"
  run "if command -v gradle >/dev/null 2>&1; then gradle -p clients/kotlin test; else echo 'skip kotlin test: gradle not found'; fi"
}

run_protocol_smoke_phase() {
  phase_header protocol-smoke
  run "bash tests/public-safety-test.sh"
  run "node --test tests/viewer-parser.test.mjs"
  run "zig test src/test_harness.zig -target $HOST_ZIG_TARGET"
  run "zig build-exe src/main.zig -target $HOST_ZIG_TARGET -O Debug -femit-bin=zig-out/bin/zmr"
  run "bash tests/version-json-test.sh"
  run "bash tests/schemas-json-test.sh"
  run "bash tests/discover-json-test.sh"
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
}

run_release_artifacts_phase() {
  phase_header release-artifacts
  run "./scripts/build-release.sh"
  run "./scripts/verify-release-artifacts.sh"
  run "./scripts/release-smoke.sh dist/*.tar.gz"
  run "npm pack --dry-run"

  cat <<'EOF'

External pilot gates not run by default:
+ ./scripts/pilot-gate.sh --android --android-app-root /path/to/mobile-app --android-app-id com.example.mobiletest --android-device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl
+ ./scripts/pilot-gate.sh --ios --ios-app-root /path/to/mobile-app --ios-app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.mobiletest --ios-device booted --ios-shim /path/to/mobile-app/.zmr/ios-shim --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl
+ ./scripts/pilot-gate.sh --ios --ios-device-type physical --ios-device <physical-device-id> --ios-app-root /path/to/mobile-app --ios-app-path /path/to/mobile-app/build/Release-iphoneos/Sample.ipa --ios-app-id com.example.mobiletest --ios-shim /path/to/mobile-app/.zmr/ios-shim --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl
EOF
}

for phase in "${SELECTED_PHASES[@]}"; do
  case "$phase" in
    static)
      run_static_phase
      ;;
    platform-scripts)
      run_platform_scripts_phase
      ;;
    clients)
      run_clients_phase
      ;;
    protocol-smoke)
      run_protocol_smoke_phase
      ;;
    release-artifacts)
      run_release_artifacts_phase
      ;;
  esac
done
