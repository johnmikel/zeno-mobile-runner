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
CREATE_ANDROID_DEMO_APP="${CREATE_ANDROID_DEMO_APP:-$ROOT/scripts/create-android-demo-app.sh}"
ANDROID_PILOT="${ANDROID_PILOT:-$ROOT/scripts/run-android-pilot.sh}"
# shellcheck source=run-evidence.sh
source "$ROOT/scripts/run-evidence.sh"
OUT="/tmp/zmr-android-demo-$(date +%Y%m%d-%H%M%S)"
APP_ID="com.example.mobiletest"
DEVICE="emulator-5554"
AVD=""
RUNS="1"
TRACE_ROOT=""
API="35"
BUILD_TOOLS="35.0.1"
ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-adb}"
EMULATOR="${EMULATOR:-emulator}"
AUTO_BOOT_EMULATOR=1
DRY_RUN=0
DEMO_EMULATOR_HANDLE=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/demo-android-real.sh [options]

Creates a generic public Android demo app, installs it on an Android
emulator/device, and runs the ZMR Android smoke scenario with trace output.

Options:
  --out <dir>               Demo app output directory. Default: /tmp/zmr-android-demo-<timestamp>.
  --app-id <id>             Android application id. Default: com.example.mobiletest.
  --device <serial>         Android device/emulator serial. Default: emulator-5554.
  --avd <name>              AVD to boot when the requested device is not ready.
  --runs <n>                Scenario run count. Default: 1.
  --trace-root <dir>        Trace output directory. Default: <out>/traces/pilot.
  --api <level>             Android platform API level. Default: 35.
  --build-tools <ver>       Android build-tools version. Default: 35.0.1.
  --android-sdk <path>      Android SDK root. Default: ANDROID_HOME or ~/Library/Android/sdk.
  --adb <path>              adb path. Default: adb.
  --emulator <path>         emulator path. Default: emulator.
  --no-auto-boot-emulator   Require an already ready device/emulator.
  --dry-run                 Print commands without executing them.
  -h, --help                Show this help.
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

run_allow_fail() {
  echo "+ $(quote_cmd "$@")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    zmr_evidence_try app.install remove-existing-app runner.unclassified -- "$@" >/dev/null 2>&1 || true
  fi
}

run_background() {
  echo "+ $(quote_cmd "$@") &"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if _zmr_evidence_enabled; then
      zmr_evidence_run_background DEMO_EMULATOR_HANDLE \
        device.acquire boot-android-emulator infra.emulator_provision \
        --expected-stop -- "$@"
    else
      "$@" &
    fi
  fi
}

cleanup_demo_emulator() {
  if [[ -z "$DEMO_EMULATOR_HANDLE" ]]; then
    return 0
  fi
  zmr_evidence_event cleanup started
  zmr_evidence_stop "$DEMO_EMULATOR_HANDLE" cleanup
  zmr_evidence_wait "$DEMO_EMULATOR_HANDLE"
  zmr_evidence_event cleanup passed
}

if _zmr_evidence_enabled; then
  zmr_evidence_register_cleanup cleanup_demo_emulator
fi

device_ready() {
  echo "+ $(quote_cmd "$ADB" -s "$DEVICE" get-state)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 1
  fi
  local state
  if _zmr_evidence_enabled; then
    state=
    zmr_evidence_try_capture state device.preflight android-device-state \
      infra.device_unavailable -- "$ADB" -s "$DEVICE" get-state || true
    state="${state//$'\r'/}"
  else
    state="$("$ADB" -s "$DEVICE" get-state 2>/dev/null | tr -d '\r' || true)"
  fi
  [[ "$state" == "device" ]]
}

ensure_android_device_ready() {
  if device_ready; then
    zmr_evidence_event device.acquire passed '' "Requested Android device is available"
    zmr_evidence_event device.boot passed '' "Requested Android device is ready"
    return 0
  fi

  if [[ "$AUTO_BOOT_EMULATOR" -eq 0 ]]; then
    die "device $DEVICE is not ready and auto boot is disabled"
  fi
  [[ -n "$AVD" ]] || die "device $DEVICE is not ready; pass --avd <name> to boot an emulator or start a device manually"

  echo "+ auto boot Android emulator $AVD when $DEVICE is not ready"
  run_background "$ROOT/scripts/android-emulator.sh" boot --avd "$AVD" --device "$DEVICE"
  run_evidence device.boot wait-android-emulator infra.emulator_provision \
    "$ROOT/scripts/android-emulator.sh" wait-ready --device "$DEVICE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$(require_value "$1" "${2-}")"
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
    --avd)
      AVD="$(require_value "$1" "${2-}")"
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
    --api)
      API="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --build-tools)
      BUILD_TOOLS="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --android-sdk)
      ANDROID_SDK="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --adb)
      ADB="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --emulator)
      EMULATOR="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --no-auto-boot-emulator)
      AUTO_BOOT_EMULATOR=0
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
[[ "$APP_ID" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || die "--app-id must be a Java-style package id"
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || die "--runs must be a positive integer"
[[ "$API" =~ ^[0-9]+$ ]] || die "--api must be an integer"
[[ -n "$BUILD_TOOLS" ]] || die "--build-tools must be non-empty"

if [[ -z "$TRACE_ROOT" ]]; then
  TRACE_ROOT="$OUT/traces/pilot"
fi

APK="$OUT/build/app-debug.apk"
SCENARIO="$OUT/.zmr/android-smoke.json"

echo "Android real demo app: $OUT"
echo "Android real demo traces: $TRACE_ROOT"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: commands will be printed but not executed"
fi

run_evidence app.build create-android-demo config.required_tool_missing "$CREATE_ANDROID_DEMO_APP" \
  --out "$OUT" \
  --app-id "$APP_ID" \
  --api "$API" \
  --build-tools "$BUILD_TOOLS" \
  --android-sdk "$ANDROID_SDK"

ensure_android_device_ready

run_allow_fail "$ADB" -s "$DEVICE" uninstall "$APP_ID"
run_evidence app.install install-android-demo runner.unclassified "$ADB" -s "$DEVICE" install -r "$APK"

echo "+ $(quote_cmd "$ANDROID_PILOT" \
  --app-root "$OUT" \
  --apk "$APK" \
  --scenario "$SCENARIO" \
  --skip-emulator \
  --skip-metro \
  --device "$DEVICE" \
  --app-id "$APP_ID" \
  --adb "$ADB" \
  --runs "$RUNS" \
  --trace-root "$TRACE_ROOT" \
  --min-pass-rate 100 \
  --max-failures 0)"
if [[ "$DRY_RUN" -eq 0 ]]; then
  zmr_evidence_delegate scenario.execute android-pilot runner.unclassified -- \
    "$ANDROID_PILOT" \
    --app-root "$OUT" \
    --apk "$APK" \
    --scenario "$SCENARIO" \
    --skip-emulator \
    --skip-metro \
    --device "$DEVICE" \
    --app-id "$APP_ID" \
    --adb "$ADB" \
    --runs "$RUNS" \
    --trace-root "$TRACE_ROOT" \
    --min-pass-rate 100 \
    --max-failures 0
fi

cat <<EOF

Android real demo complete.
App directory: $OUT
Trace directory: $TRACE_ROOT
EOF
