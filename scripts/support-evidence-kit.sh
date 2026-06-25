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

OUT=""
APP_ID="${APP_ID:-com.example.mobiletest}"
ANDROID_SCENARIO="${ANDROID_SCENARIO:-.zmr/android-smoke.json}"
IOS_SCENARIO="${IOS_SCENARIO:-.zmr/ios-smoke.json}"
ANDROID_APP_ROOT="${ANDROID_APP_ROOT:-.}"
IOS_APP_ROOT="${IOS_APP_ROOT:-.}"
IOS_APP_PATH="${IOS_APP_PATH:-build/Debug-iphonesimulator/App.app}"
ANDROID_APK="${ANDROID_APK:-android/app/build/outputs/apk/debug/app-debug.apk}"
ANDROID_SHIM="${ANDROID_SHIM:-.zmr/android-shim}"
IOS_SHIM="${IOS_SHIM:-.zmr/ios-shim}"
ADB="${ADB:-adb}"
XCRUN="${XCRUN:-xcrun}"
ZMR_BIN="${ZMR_BIN:-zmr}"
RUNS="${RUNS:-20}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/support-evidence-kit.sh --out <dir> [options]

Generates an app-team support evidence kit for Android, iPhone, and iPad claims.
The generated kit uses existing ZMR commands:
  - zmr-device-matrix for multi-target repeated-run evidence
  - zmr-pilot-gate for platform-specific pilot artifacts and evidence JSONL

Options:
  --out <dir>                 Output directory. Required.
  --app-id <bundle>           App id/bundle id used by generated examples.
  --android-scenario <path>   Android scenario for matrix evidence.
  --ios-scenario <path>       iOS/iPadOS scenario for matrix evidence.
  --android-app-root <dir>    Android app root for pilot-gate commands.
  --ios-app-root <dir>        iOS app root for pilot-gate commands.
  --ios-app-path <path>       iOS simulator .app or signed physical .app/.ipa.
  --android-apk <path>        Android APK path for pilot-gate commands.
  --android-shim <path>       Android shim path for matrix evidence.
  --ios-shim <path>           iOS XCTest shim path for matrix and pilot evidence.
  --adb <path>                adb command/path.
  --xcrun <path>              xcrun command/path.
  --zmr-bin <path>            zmr command/path.
  --runs <n>                  Repeated-run evidence count. Default: 20.
  -h, --help                  Show this help.
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
  printf '%s' "${quoted[*]}"
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
    --android-scenario)
      ANDROID_SCENARIO="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-scenario)
      IOS_SCENARIO="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --android-app-root)
      ANDROID_APP_ROOT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-app-root)
      IOS_APP_ROOT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-app-path)
      IOS_APP_PATH="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --android-apk)
      ANDROID_APK="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --android-shim)
      ANDROID_SHIM="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-shim)
      IOS_SHIM="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --adb)
      ADB="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --xcrun)
      XCRUN="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --zmr-bin)
      ZMR_BIN="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --runs)
      RUNS="$(require_value "$1" "${2-}")"
      shift 2
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

[[ -n "$OUT" ]] || die "--out is required"
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || die "--runs must be a positive integer"

mkdir -p "$OUT"

python3 - "$OUT/device-matrix.template.json" "$RUNS" "$APP_ID" "$ANDROID_SCENARIO" "$IOS_SCENARIO" "$ADB" "$ANDROID_SHIM" "$XCRUN" "$IOS_SHIM" <<'PY'
import json
import sys

out, runs, app_id, android_scenario, ios_scenario, adb, android_shim, xcrun, ios_shim = sys.argv[1:10]

matrix = {
    "runs": int(runs),
    "appId": app_id,
    "devices": [
        {
            "name": "android-emulator",
            "evidenceTarget": "Android emulator",
            "deviceClass": "emulator",
            "platform": "android",
            "serial": "emulator-5554",
            "scenario": android_scenario,
            "adb": adb,
            "androidShim": android_shim,
        },
        {
            "name": "android-physical",
            "evidenceTarget": "Android physical",
            "deviceClass": "physical",
            "platform": "android",
            "serial": "<android-device-serial>",
            "scenario": android_scenario,
            "adb": adb,
            "androidShim": android_shim,
        },
        {
            "name": "iphone-simulator",
            "evidenceTarget": "iPhone simulator",
            "deviceClass": "simulator",
            "platform": "ios",
            "iosDeviceType": "simulator",
            "serial": "booted",
            "scenario": ios_scenario,
            "xcrun": xcrun,
            "iosShim": ios_shim,
        },
        {
            "name": "ipad-simulator",
            "evidenceTarget": "iPad simulator",
            "deviceClass": "simulator",
            "platform": "ios",
            "iosDeviceType": "simulator",
            "serial": "<ipad-simulator-udid-or-booted>",
            "scenario": ios_scenario,
            "xcrun": xcrun,
            "iosShim": ios_shim,
        },
        {
            "name": "iphone-physical",
            "evidenceTarget": "iPhone physical",
            "deviceClass": "physical",
            "platform": "ios",
            "iosDeviceType": "physical",
            "serial": "<iphone-device-id>",
            "scenario": ios_scenario,
            "xcrun": xcrun,
            "iosShim": ios_shim,
        },
        {
            "name": "ipad-physical",
            "evidenceTarget": "iPad physical",
            "deviceClass": "physical",
            "platform": "ios",
            "iosDeviceType": "physical",
            "serial": "<ipad-device-id>",
            "scenario": ios_scenario,
            "xcrun": xcrun,
            "iosShim": ios_shim,
        },
    ],
}

with open(out, "w", encoding="utf-8") as fh:
    json.dump(matrix, fh, indent=2)
    fh.write("\n")
PY

ANDROID_APP_ROOT_Q="$(quote_cmd "$ANDROID_APP_ROOT")"
ANDROID_APK_Q="$(quote_cmd "$ANDROID_APK")"
IOS_APP_ROOT_Q="$(quote_cmd "$IOS_APP_ROOT")"
IOS_APP_PATH_Q="$(quote_cmd "$IOS_APP_PATH")"
ANDROID_SCENARIO_Q="$(quote_cmd "$ANDROID_SCENARIO")"
IOS_SCENARIO_Q="$(quote_cmd "$IOS_SCENARIO")"
APP_ID_Q="$(quote_cmd "$APP_ID")"
ZMR_BIN_Q="$(quote_cmd "$ZMR_BIN")"
ADB_Q="$(quote_cmd "$ADB")"
XCRUN_Q="$(quote_cmd "$XCRUN")"
IOS_SHIM_Q="$(quote_cmd "$IOS_SHIM")"

cat > "$OUT/pilot-commands.md" <<EOF
# Support Evidence Commands

Run these commands from this directory after replacing placeholder device ids in
\`device-matrix.template.json\`.

## Matrix Gate

\`\`\`bash
zmr-device-matrix --matrix device-matrix.template.json --trace-root traces/support-matrix --min-pass-rate 100 --max-failures 0
\`\`\`

Use this as the broad evidence pass. It keeps Android, iPhone, and iPad rows in
one result set while preserving separate target names for review.

## Android Pilot Gate

\`\`\`bash
zmr-pilot-gate --android --android-app-root $ANDROID_APP_ROOT_Q --android-apk $ANDROID_APK_Q --android-app-id $APP_ID_Q --android-scenario $ANDROID_SCENARIO_Q --adb $ADB_Q --zmr-bin $ZMR_BIN_Q --trace-root traces/android-pilot --evidence-out traces/android-pilot/evidence.jsonl --runs $RUNS --min-pass-rate 100 --max-failures 0
\`\`\`

## iPhone Simulator Pilot Gate

\`\`\`bash
zmr-pilot-gate --ios --ios-device-type simulator --ios-device booted --ios-app-root $IOS_APP_ROOT_Q --ios-app-path $IOS_APP_PATH_Q --ios-app-id $APP_ID_Q --ios-shim $IOS_SHIM_Q --xcrun $XCRUN_Q --zmr-bin $ZMR_BIN_Q --trace-root traces/iphone-simulator-pilot --evidence-out traces/iphone-simulator-pilot/evidence.jsonl --runs $RUNS --min-pass-rate 100 --max-failures 0
\`\`\`

## iPad simulator Pilot Gate

\`\`\`bash
zmr-pilot-gate --ios --ios-device-type simulator --ios-device <ipad-simulator-udid-or-booted> --ios-app-root $IOS_APP_ROOT_Q --ios-app-path $IOS_APP_PATH_Q --ios-app-id $APP_ID_Q --ios-shim $IOS_SHIM_Q --xcrun $XCRUN_Q --zmr-bin $ZMR_BIN_Q --trace-root traces/ipad-simulator-pilot --evidence-out traces/ipad-simulator-pilot/evidence.jsonl --runs $RUNS --min-pass-rate 100 --max-failures 0
\`\`\`

## iPhone Physical Pilot Gate

\`\`\`bash
zmr-pilot-gate --ios --ios-device-type physical --ios-device <iphone-device-id> --ios-app-root $IOS_APP_ROOT_Q --ios-app-path <signed-iphone-app-or-ipa> --ios-app-id $APP_ID_Q --ios-shim $IOS_SHIM_Q --xcrun $XCRUN_Q --zmr-bin $ZMR_BIN_Q --trace-root traces/iphone-physical-pilot --evidence-out traces/iphone-physical-pilot/evidence.jsonl --runs $RUNS --min-pass-rate 100 --max-failures 0
\`\`\`

## iPad physical Pilot Gate

\`\`\`bash
zmr-pilot-gate --ios --ios-device-type physical --ios-device <ipad-device-id> --ios-app-root $IOS_APP_ROOT_Q --ios-app-path <signed-ipad-app-or-ipa> --ios-app-id $APP_ID_Q --ios-shim $IOS_SHIM_Q --xcrun $XCRUN_Q --zmr-bin $ZMR_BIN_Q --trace-root traces/ipad-physical-pilot --evidence-out traces/ipad-physical-pilot/evidence.jsonl --runs $RUNS --min-pass-rate 100 --max-failures 0
\`\`\`

Share redacted trace bundles, reports, JUnit output, and evidence JSONL. Keep raw
logs local unless your app team has reviewed them for secrets and customer data.
EOF

cat > "$OUT/support-claim-checklist.md" <<'EOF'
# Support Claim Checklist

Use this before changing public support claims.

- [ ] Every claimed target has a 20-run gate with zero failures.
- [ ] Pass rate is 100% and `maxFailures` is 0.
- [ ] redacted .zmrtrace bundles exist for each claimed target.
- [ ] HTML report and JUnit output exist for each target.
- [ ] iPad evidence stays separate from iPhone evidence.
- [ ] Physical iPhone and iPad runs name the exact trusted device ids used.
- [ ] Scenario selectors prefer app-owned ids/accessibility identifiers over snapshot-only `stableId` values.
- [ ] The support matrix entry matches the evidence target and does not overclaim tvOS, watchOS, or cloud farms.
- [ ] Evidence JSONL is attached to release readiness or the relevant product review.
EOF

cat > "$OUT/README.md" <<EOF
# ZMR Support Evidence Kit

This directory is an AI-agent-first support evidence workspace for proving ZMR
claims before they are published.

Generated files:

- \`device-matrix.template.json\`: Android, iPhone, and iPad matrix template for \`zmr-device-matrix\`.
- \`pilot-commands.md\`: copy-ready commands for \`zmr-pilot-gate\` and repeated-run evidence.
- \`support-claim-checklist.md\`: product review checklist for support matrix updates.

Recommended flow:

1. Replace placeholder serials in \`device-matrix.template.json\`.
2. Confirm app-owned selectors in $ANDROID_SCENARIO_Q and $IOS_SCENARIO_Q.
3. Run the matrix command in \`pilot-commands.md\`.
4. Run the target-specific pilot gate commands for claims you plan to publish.
5. Attach redacted bundles, reports, JUnit output, and evidence JSONL to the release or product review.
6. Update the public support matrix only for targets with passing evidence.
EOF

echo "wrote support evidence kit:"
echo "  $OUT/device-matrix.template.json"
echo "  $OUT/pilot-commands.md"
echo "  $OUT/support-claim-checklist.md"
echo "  $OUT/README.md"
echo
echo "Next:"
echo "  cd $(quote_cmd "$OUT")"
echo "  edit device-matrix.template.json"
echo "  zmr-device-matrix --matrix device-matrix.template.json --trace-root traces/support-matrix --min-pass-rate 100 --max-failures 0"
