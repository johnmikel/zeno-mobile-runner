#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE" ]]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  if [[ "$SOURCE" != /* ]]; then
    SOURCE="$SOURCE_DIR/$SOURCE"
  fi
done

ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"
CREATE_IOS_DEMO_APP="${CREATE_IOS_DEMO_APP:-$ROOT/scripts/create-ios-demo-app.sh}"
IOS_PILOT="${IOS_PILOT:-$ROOT/scripts/run-ios-pilot.sh}"
# shellcheck source=run-evidence.sh
source "$ROOT/scripts/run-evidence.sh"
OUT="/tmp/zmr-ios-demo-$(date +%Y%m%d-%H%M%S)"
APP_NAME="ZMRDemo"
APP_ID="com.example.mobiletest"
DEVICE="booted"
DEPLOYMENT_TARGET="16.0"
RUNS="1"
TRACE_ROOT=""
XCRUN="${XCRUN:-xcrun}"
AUTO_BOOT_SIMULATOR=1
CLEANUP_BUILD_PRODUCTS=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/demo-ios-real.sh [options]

Creates a generic public iOS simulator demo app, builds it, and runs the real
ZMR iOS pilot with the generated XCTest shim.

Options:
  --out <dir>                  Demo app output directory. Default: /tmp/zmr-ios-demo-<timestamp>.
  --name <name>                App target name. Default: ZMRDemo.
  --app-id <id>                App bundle id. Default: com.example.mobiletest.
  --device <udid|booted>       Simulator target. Default: booted.
  --deployment-target <ver>    iOS deployment target. Default: 16.0.
  --runs <n>                   Pilot run count. Default: 1.
  --trace-root <dir>           Trace output directory. Default: <out>/traces/pilot.
  --xcrun <path>               xcrun path. Default: xcrun.
  --no-auto-boot-simulator     Require an already booted simulator.
  --cleanup-build-products     Remove generated DerivedData after pilot traces are written.
  --dry-run                    Print commands without executing them.
  -h, --help                   Show this help.
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

quote_cmd() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s\n' "${quoted[*]}"
}

run() {
  echo "+ $(quote_cmd "$@")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

run_evidence() {
  local phase="$1"
  local name="$2"
  local failure_code="$3"
  shift 3
  echo "+ $(quote_cmd "$@")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    zmr_evidence_run "$phase" "$name" "$failure_code" -- "$@"
  fi
}

available_ios_simulators() {
  "$XCRUN" simctl list devices available --json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable", True) and device.get("state") in ("Shutdown", "Booted"):
            udid = device.get("udid")
            if udid:
                print(udid)
'
}

simulator_is_booted() {
  local wanted="${1:-}"
  local booted_text
  booted_text="$("$XCRUN" simctl list devices booted 2>/dev/null || true)"
  if [[ -z "$wanted" || "$wanted" == "booted" ]]; then
    [[ "$booted_text" == *"(Booted)"* ]]
    return
  fi
  [[ "$booted_text" == *"$wanted"* && "$booted_text" == *"(Booted)"* ]]
}

ensure_ios_simulator_ready() {
  if [[ "$AUTO_BOOT_SIMULATOR" -eq 0 ]]; then
    return 0
  fi

  run_evidence device.preflight list-ios-simulators infra.simulator_provision "$XCRUN" simctl list devices booted
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$DEVICE" == "booted" ]]; then
      echo "+ auto boot first available iOS simulator when no simulator is booted"
      echo "+ try available iOS simulators until one boots"
    else
      echo "+ auto boot iOS simulator $DEVICE when it is not booted"
    fi
    run_evidence device.boot wait-ios-simulator infra.simulator_provision "$XCRUN" simctl bootstatus "$DEVICE" -b
    return 0
  fi

  if simulator_is_booted "$DEVICE"; then
    zmr_evidence_event device.acquire passed '' "Requested iOS simulator is already booted"
    run_evidence device.boot wait-ios-simulator infra.simulator_provision "$XCRUN" simctl bootstatus "$DEVICE" -b
    return 0
  fi

  local boot_target="$DEVICE"
  if [[ "$DEVICE" == "booted" ]]; then
    local candidates=()
    local listed_candidate
    while IFS= read -r listed_candidate; do
      [[ -n "$listed_candidate" ]] && candidates+=("$listed_candidate")
    done < <(available_ios_simulators)
    if [[ "${#candidates[@]}" -eq 0 ]]; then
      die "no available iOS simulator found to boot"
    fi
    local candidate status
    for candidate in "${candidates[@]}"; do
      echo "+ $(quote_cmd "$XCRUN" simctl boot "$candidate")"
      set +e
      "$XCRUN" simctl boot "$candidate"
      status=$?
      set -e
      if [[ "$status" -eq 0 ]]; then
        run_evidence device.boot wait-ios-simulator infra.simulator_provision "$XCRUN" simctl bootstatus "$candidate" -b
        return 0
      fi
      echo "warning: failed to boot iOS simulator $candidate; trying next available simulator" >&2
    done
    die "no available iOS simulator could be booted"
  fi

  run_evidence device.acquire boot-ios-simulator infra.simulator_provision "$XCRUN" simctl boot "$boot_target"
  run_evidence device.boot wait-ios-simulator infra.simulator_provision "$XCRUN" simctl bootstatus "$boot_target" -b
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --name)
      APP_NAME="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --app-id)
      APP_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --device)
      DEVICE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --deployment-target)
      DEPLOYMENT_TARGET="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --runs)
      RUNS="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --trace-root)
      TRACE_ROOT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --xcrun)
      XCRUN="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --no-auto-boot-simulator)
      AUTO_BOOT_SIMULATOR=0
      shift
      ;;
    --cleanup-build-products)
      CLEANUP_BUILD_PRODUCTS=1
      shift
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
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$OUT" ]] || die "--out must not be empty"
[[ "$APP_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--name must be a valid Swift identifier"
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || die "--runs must be a positive integer"

if [[ -z "$TRACE_ROOT" ]]; then
  TRACE_ROOT="$OUT/traces/pilot"
fi

PROJECT_PATH="$OUT/ios/$APP_NAME.xcodeproj"
DERIVED_DATA="$OUT/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$APP_NAME.app"
IOS_SHIM="$OUT/.zmr/ios-shim"

echo "iOS real demo app: $OUT"
echo "iOS real demo traces: $TRACE_ROOT"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: commands will be printed but not executed"
fi

run_evidence app.build create-ios-demo config.required_tool_missing "$CREATE_IOS_DEMO_APP" \
  --out "$OUT" \
  --name "$APP_NAME" \
  --bundle-id "$APP_ID" \
  --deployment-target "$DEPLOYMENT_TARGET"

run_evidence app.build build-ios-demo runner.unclassified xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$APP_NAME" \
  -destination "generic/platform=iOS Simulator" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build

zmr_evidence_update_artifact_identity \
  "$ROOT/examples/ios-smoke.json" "$APP_PATH" \
  "$ROOT/examples/ios-shim-smoke.json"

ensure_ios_simulator_ready
zmr_evidence_update_device_identity "$DEVICE" ""

echo "+ $(quote_cmd "$IOS_PILOT" \
  --app-root "$OUT" \
  --app-path "$APP_PATH" \
  --device "$DEVICE" \
  --app-id "$APP_ID" \
  --xcrun "$XCRUN" \
  --ios-shim "$IOS_SHIM" \
  --ios-shim-mode generated \
  --runs "$RUNS" \
  --trace-root "$TRACE_ROOT")"
if [[ "$DRY_RUN" -eq 0 ]]; then
  zmr_evidence_delegate scenario.execute ios-pilot runner.unclassified -- \
    "$IOS_PILOT" \
    --app-root "$OUT" \
    --app-path "$APP_PATH" \
    --device "$DEVICE" \
    --app-id "$APP_ID" \
    --xcrun "$XCRUN" \
    --ios-shim "$IOS_SHIM" \
    --ios-shim-mode generated \
    --runs "$RUNS" \
    --trace-root "$TRACE_ROOT"
fi

if [[ "$CLEANUP_BUILD_PRODUCTS" -eq 1 ]]; then
  run_evidence cleanup remove-derived-data runner.cleanup_failed rm -rf "$DERIVED_DATA"
fi

cat <<EOF

iOS real demo complete.
App directory: $OUT
Trace directory: $TRACE_ROOT
EOF
