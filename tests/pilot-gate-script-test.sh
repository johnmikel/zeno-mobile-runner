#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--android-app-root" "--ios-app-root" "--ios-app-path" "--evidence-out"; do
  set +e
  missing_value_output="$("$ROOT/scripts/pilot-gate.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "pilot gate should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

set +e
missing_output="$("$ROOT/scripts/pilot-gate.sh" --android --ios --dry-run 2>&1)"
missing_status=$?
set -e

if [[ "$missing_status" -eq 0 ]]; then
  echo "expected pilot gate to require app paths for selected platforms" >&2
  exit 1
fi

grep -q 'error: --android-app-root is required when --android is selected' <<< "$missing_output"

set +e
missing_ios_root_output="$("$ROOT/scripts/pilot-gate.sh" --ios --ios-app-path "$TMPDIR/Sample.app" --dry-run 2>&1)"
missing_ios_root_status=$?
set -e
if [[ "$missing_ios_root_status" -eq 0 ]]; then
  echo "expected pilot gate to require iOS app root for selected iOS pilots" >&2
  exit 1
fi
grep -q 'error: --ios-app-root is required when --ios is selected' <<< "$missing_ios_root_output"

PLACEHOLDER_EVIDENCE_OUT="$TMPDIR/placeholder-evidence.jsonl"
placeholder_output="$("$ROOT/scripts/pilot-gate.sh" \
  --android \
  --android-app-root /path/to/mobile-app \
  --trace-root "$TMPDIR/placeholder-pilot" \
  --evidence-out "$PLACEHOLDER_EVIDENCE_OUT" \
  --dry-run 2>&1)"

python3 - "$placeholder_output" "$PLACEHOLDER_EVIDENCE_OUT" <<'PY'
import json
import sys

output, evidence = sys.argv[1:]
rows = [json.loads(line) for line in open(evidence, encoding="utf-8") if line.strip()]

assert "--app-root /path/to/mobile-app" in output
assert "//path/to/mobile-app" not in output
assert rows[0]["androidAppRoot"] == "/path/to/mobile-app"
PY

output="$("$ROOT/scripts/pilot-gate.sh" \
  --android \
  --ios \
  --android-app-root "$TMPDIR/android-app" \
  --android-app-id com.example.android \
  --android-device emulator-5554 \
  --android-apk "$TMPDIR/app-debug.apk" \
  --adb "$TMPDIR/adb" \
  --zmr-bin "$TMPDIR/zmr" \
  --ios-app-root "$TMPDIR/ios-app" \
  --ios-app-id com.example.ios \
  --ios-device booted \
  --ios-device-type physical \
  --ios-app-path "$TMPDIR/Sample.app" \
  --ios-shim "$TMPDIR/ios-shim" \
  --xcrun "$TMPDIR/xcrun" \
  --trace-root "$TMPDIR/pilot-gate" \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --android-max-p95-ms 30000 \
  --ios-max-p95-ms 45000 \
  --dry-run 2>&1)"

python3 - "$output" "$ROOT" "$TMPDIR" <<'PY'
import os
import sys

output = sys.argv[1]
root = os.path.realpath(sys.argv[2])
tmp = os.path.realpath(sys.argv[3])

assert "DRY RUN" in output
assert f"{root}/scripts/run-android-pilot.sh" in output
assert f"--app-root {tmp}/android-app" in output
assert "--app-id com.example.android" in output
assert "--device emulator-5554" in output
assert f"--apk {tmp}/app-debug.apk" in output
assert f"--adb {tmp}/adb" in output
assert f"--zmr-bin {tmp}/zmr" in output
assert f"--trace-root {tmp}/pilot-gate/android" in output
assert "--runs 20" in output
assert "--min-pass-rate 100" in output
assert "--max-failures 0" in output
assert "--max-p95-ms 30000" in output
assert f"{root}/scripts/assert-ios-physical-ready.sh" in output
assert "--device booted" in output
assert f"{root}/scripts/assert-ios-physical-ready.sh --device booted --zmr {tmp}/zmr --xcrun {tmp}/xcrun" in output
assert f"{root}/scripts/run-ios-pilot.sh" in output
assert f"--app-root {tmp}/ios-app" in output
assert f"--app-path {tmp}/Sample.app" in output
assert "--app-id com.example.ios" in output
assert "--device booted" in output
assert "--ios-device-type physical" in output
assert f"--ios-shim {tmp}/ios-shim" in output
assert f"--xcrun {tmp}/xcrun" in output
assert f"--zmr-bin {tmp}/zmr" in output
assert f"--trace-root {tmp}/pilot-gate/ios" in output
assert "--max-p95-ms 45000" in output
PY

EVIDENCE_OUT="$TMPDIR/pilot-evidence.jsonl"
evidence_output="$("$ROOT/scripts/pilot-gate.sh" \
  --android \
  --ios \
  --android-app-root "$TMPDIR/android-app" \
  --android-app-id com.example.android \
  --ios-device-type physical \
  --ios-device physical-device-1 \
  --ios-app-root "$TMPDIR/ios-app" \
  --ios-app-path "$TMPDIR/Sample.ipa" \
  --ios-app-id com.example.ios \
  --ios-shim "$TMPDIR/ios-shim" \
  --zmr-bin "$TMPDIR/zmr" \
  --trace-root "$TMPDIR/evidence-pilot" \
  --evidence-out "$EVIDENCE_OUT" \
  --dry-run 2>&1)"

python3 - "$evidence_output" "$EVIDENCE_OUT" <<'PY'
import json
import os
import sys

output = sys.argv[1]
evidence_out = os.path.realpath(sys.argv[2])

assert f"pilot evidence: {evidence_out}" in output
rows = [json.loads(line) for line in open(evidence_out, encoding="utf-8") if line.strip()]
assert [row["name"] for row in rows] == [
    "Android hardware pilot",
    "physical iOS readiness",
    "iOS physical hardware pilot",
]
assert all(row["status"] == "planned" for row in rows)
assert rows[0]["mode"] == "pilot-gate"
assert rows[0]["runs"] == 20
assert rows[0]["minPassRate"] == 100
assert rows[0]["maxFailures"] == 0
assert rows[0]["androidAppId"] == "com.example.android"
assert rows[0]["androidAppRoot"].endswith("/android-app")
assert rows[0]["androidDeviceId"] == "emulator-5554"
assert rows[0]["traceRoot"].endswith("/evidence-pilot/android")
assert rows[1]["command"].endswith(f"assert-ios-physical-ready.sh --device physical-device-1 --zmr {os.path.realpath(os.path.join(os.path.dirname(evidence_out), 'zmr'))}")
assert rows[1]["iosDeviceId"] == "physical-device-1"
assert rows[2]["runs"] == 20
assert rows[2]["minPassRate"] == 100
assert rows[2]["maxFailures"] == 0
assert rows[2]["iosAppId"] == "com.example.ios"
assert rows[2]["iosAppRoot"].endswith("/ios-app")
assert rows[2]["iosAppPath"].endswith("/Sample.ipa")
assert rows[2]["iosDeviceId"] == "physical-device-1"
assert rows[2]["traceRoot"].endswith("/evidence-pilot/ios")
PY

SIM_EVIDENCE_OUT="$TMPDIR/simulator-pilot-evidence.jsonl"
sim_evidence_output="$("$ROOT/scripts/pilot-gate.sh" \
  --ios \
  --ios-device booted \
  --ios-app-root "$TMPDIR/ios-app" \
  --ios-app-path "$TMPDIR/Simulator.app" \
  --ios-app-id com.example.ios \
  --trace-root "$TMPDIR/simulator-evidence-pilot" \
  --evidence-out "$SIM_EVIDENCE_OUT" \
  --dry-run 2>&1)"

python3 - "$sim_evidence_output" "$SIM_EVIDENCE_OUT" <<'PY'
import json
import os
import sys

output = sys.argv[1]
evidence_out = os.path.realpath(sys.argv[2])

assert f"pilot evidence: {evidence_out}" in output
rows = [json.loads(line) for line in open(evidence_out, encoding="utf-8") if line.strip()]
assert [row["name"] for row in rows] == ["iOS simulator hardware pilot"]
assert rows[0]["status"] == "planned"
assert rows[0]["iosAppId"] == "com.example.ios"
assert rows[0]["iosAppRoot"].endswith("/ios-app")
assert rows[0]["iosAppPath"].endswith("/Simulator.app")
assert rows[0]["iosDeviceId"] == "booted"
assert rows[0]["traceRoot"].endswith("/simulator-evidence-pilot/ios")
PY

android_only="$("$ROOT/scripts/pilot-gate.sh" \
  --android \
  --android-app-root "$TMPDIR/android-app" \
  --skip-emulator \
  --skip-metro \
  --trace-root "$TMPDIR/android-only" \
  --dry-run 2>&1)"

python3 - "$android_only" "$ROOT" "$TMPDIR" <<'PY'
import os
import sys

output = sys.argv[1]
root = os.path.realpath(sys.argv[2])
tmp = os.path.realpath(sys.argv[3])

assert f"{root}/scripts/run-android-pilot.sh" in output
assert f"{root}/scripts/run-ios-pilot.sh" not in output
assert "--skip-emulator" in output
assert "--skip-metro" in output
assert f"--trace-root {tmp}/android-only/android" in output
PY

APP_CWD="$TMPDIR/app-cwd"
mkdir -p "$APP_CWD/bin" "$APP_CWD/.zmr" "$APP_CWD/build"
touch "$APP_CWD/bin/zmr"
chmod +x "$APP_CWD/bin/zmr"

app_cwd_output="$(cd "$APP_CWD" && PATH="$APP_CWD/bin:$PATH" "$ROOT/scripts/pilot-gate.sh" \
  --android \
  --ios \
  --android-app-root . \
  --android-apk ./build/app-debug.apk \
  --adb ./bin/adb \
  --ios-app-root . \
  --ios-app-path ./build/Sample.app \
  --ios-shim ./.zmr/ios-shim \
  --xcrun ./bin/xcrun \
  --trace-root traces/pilot \
  --dry-run 2>&1)"

python3 - "$app_cwd_output" "$ROOT" "$APP_CWD" <<'PY'
import os
import sys

output = sys.argv[1]
root = os.path.realpath(sys.argv[2])
app = os.path.realpath(sys.argv[3])

assert f"{root}/scripts/run-android-pilot.sh" in output
assert f"{root}/scripts/run-ios-pilot.sh" in output
assert f"--app-root {app}" in output
assert f"--apk {app}/build/app-debug.apk" in output
assert f"--adb {app}/bin/adb" in output
assert f"--app-path {app}/build/Sample.app" in output
assert f"--ios-shim {app}/.zmr/ios-shim" in output
assert f"--xcrun {app}/bin/xcrun" in output
assert f"--zmr-bin {app}/bin/zmr" in output
assert f"--trace-root {app}/traces/pilot/android" in output
assert f"--trace-root {app}/traces/pilot/ios" in output
PY
