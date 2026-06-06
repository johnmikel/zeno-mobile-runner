#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
TMPDIR="$(cd "$TMPDIR" && pwd -P)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--app-root" "--app-path" "--device" "--ios-device-type" "--app-id" "--trace-root" "--zmr-bin" "--xcrun" "--ios-shim" "--runs" "--min-pass-rate" "--max-failures" "--max-mean-ms" "--max-p95-ms"; do
  set +e
  missing_value_output="$("$ROOT/scripts/run-ios-pilot.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "run-ios-pilot should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

APP_ROOT="$TMPDIR/ios-app"
APP_PATH="$APP_ROOT/build/Debug-iphonesimulator/Sample.app"
mkdir -p "$APP_PATH"
touch "$TMPDIR/DeviceOnly.ipa"
mkdir -p "$TMPDIR/bin"
touch "$TMPDIR/bin/zmr"
chmod +x "$TMPDIR/bin/zmr"

set +e
simulator_ipa_output="$("$ROOT/scripts/run-ios-pilot.sh" \
  --app-root "$APP_ROOT" \
  --app-path "$TMPDIR/DeviceOnly.ipa" \
  --ios-device-type simulator \
  --device fake-ios-1 \
  --trace-root "$TMPDIR/pilot-device-only-ipa" 2>&1)"
simulator_ipa_status=$?
set -e

if [[ "$simulator_ipa_status" -eq 0 ]]; then
  echo "expected iOS pilot preflight to reject a device-only IPA for simulator runs" >&2
  exit 1
fi

grep -q 'setup.ios.simulator_app_required' <<< "$simulator_ipa_output"
grep -q 'simulator runs require an iphonesimulator .app directory' <<< "$simulator_ipa_output"
grep -q -- '--ios-device-type physical' <<< "$simulator_ipa_output"

EMPTY_XCRUN="$TMPDIR/fake-xcrun-empty.sh"
cat > "$EMPTY_XCRUN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'xcrun version 70\n'
  exit 0
fi
if [[ "${1:-}" == "simctl" && "${2:-}" == "list" && "${3:-}" == "devices" && "${4:-}" == "--json" ]]; then
  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[]}}\n'
  exit 0
fi
exit 2
SH
chmod +x "$EMPTY_XCRUN"

set +e
missing_sim_output="$("$ROOT/scripts/run-ios-pilot.sh" \
  --app-root "$APP_ROOT" \
  --app-path "$APP_PATH" \
  --device booted \
  --xcrun "$EMPTY_XCRUN" \
  --trace-root "$TMPDIR/pilot-missing-sim" 2>&1)"
missing_sim_status=$?
set -e

if [[ "$missing_sim_status" -eq 0 ]]; then
  echo "expected iOS pilot preflight to fail when no booted simulator exists" >&2
  exit 1
fi

grep -q 'no booted iOS simulator found' <<< "$missing_sim_output"
grep -q 'setup.ios.no_booted_simulators' <<< "$missing_sim_output"
grep -q 'zmr doctor --json' <<< "$missing_sim_output"

DISCONNECTED_XCRUN="$TMPDIR/fake-xcrun-disconnected-physical.sh"
cat > "$DISCONNECTED_XCRUN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'xcrun version 70\n'
  exit 0
fi
if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "${1:-}" == "--json-output" ]]; then
      cat > "${2:-}" <<'JSON'
{"result":{"devices":[{"identifier":"disconnected-physical-ios-1","connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"disconnected-physical-ios-1"}}]}}
JSON
      exit 0
    fi
    shift
  done
fi
if [[ "${1:-}" == "devicectl" && "${2:-}" == "device" && "${3:-}" == "install" ]]; then
  echo "install should not be reached for a disconnected physical device" >&2
  exit 2
fi
exit 2
SH
chmod +x "$DISCONNECTED_XCRUN"
touch "$TMPDIR/Physical.ipa"

set +e
disconnected_physical_output="$("$ROOT/scripts/run-ios-pilot.sh" \
  --app-path "$TMPDIR/Physical.ipa" \
  --ios-device-type physical \
  --device disconnected-physical-ios-1 \
  --app-id com.example.physical \
  --xcrun "$DISCONNECTED_XCRUN" \
  --trace-root "$TMPDIR/pilot-disconnected-physical" 2>&1)"
disconnected_physical_status=$?
set -e

if [[ "$disconnected_physical_status" -eq 0 ]]; then
  echo "expected iOS physical pilot preflight to fail when the requested device is disconnected" >&2
  exit 1
fi
grep -q 'physical iOS device is not ready: disconnected-physical-ios-1' <<< "$disconnected_physical_output"
grep -q 'state: disconnected' <<< "$disconnected_physical_output"
grep -q 'setup.ios.physical_device_not_ready' <<< "$disconnected_physical_output"
if grep -q 'install should not be reached' <<< "$disconnected_physical_output"; then
  echo "physical pilot attempted install before rejecting disconnected device" >&2
  exit 1
fi

output="$(PATH="$TMPDIR/bin:$PATH" "$ROOT/scripts/run-ios-pilot.sh" \
  --dry-run \
  --app-root "$APP_ROOT" \
  --app-path "$APP_PATH" \
  --device fake-ios-1 \
  --ios-shim ./tests/fake-ios-shim.sh \
  --trace-root "$TMPDIR/pilot" 2>&1)"

python3 - "$output" "$APP_PATH" "$TMPDIR/pilot" "$ROOT" <<'PY'
import os
import sys

output = sys.argv[1]
app_path = sys.argv[2]
trace_root = sys.argv[3]
root = os.path.realpath(sys.argv[4])
ios_shim = f"{root}/tests/fake-ios-shim.sh"

assert "DRY RUN" in output
assert f"{trace_root.rsplit('/pilot', 1)[0]}/bin/zmr validate examples/ios-smoke.json" in output
assert "zmr validate examples/ios-smoke.json" in output
assert "zmr validate examples/ios-shim-smoke.json" in output
assert f"xcrun simctl install fake-ios-1 {app_path}" in output
assert f"""printf '{{"cmd":"appState"}}\\n' | {ios_shim}""" in output
assert "zmr run examples/ios-smoke.json --platform ios --ios-device-type simulator --device fake-ios-1" in output
assert "zmr run examples/ios-shim-smoke.json --platform ios --ios-device-type simulator --device fake-ios-1" in output
assert f"--ios-shim {ios_shim}" in output
assert f"--trace-dir {trace_root}/ios-smoke" in output
assert f"--trace-dir {trace_root}/ios-shim-smoke" in output
assert f"zmr report {trace_root}/ios-smoke --out {trace_root}/ios-smoke/report.html --junit {trace_root}/ios-smoke/junit.xml" in output
assert f"zmr report {trace_root}/ios-shim-smoke --out {trace_root}/ios-shim-smoke/report.html --junit {trace_root}/ios-shim-smoke/junit.xml" in output
assert "zmr export" in output
assert "ios-shim-smoke-redacted.zmrtrace" in output
assert "--redact" in output
PY

APP_CWD="$TMPDIR/app-cwd"
mkdir -p "$APP_CWD/build/Debug-iphonesimulator/Sample.app" "$APP_CWD/.zmr"
touch "$APP_CWD/.zmr/ios-shim"
app_cwd_output="$(cd "$APP_CWD" && PATH="$TMPDIR/bin:$PATH" "$ROOT/scripts/run-ios-pilot.sh" \
  --dry-run \
  --app-root . \
  --app-path ./build/Debug-iphonesimulator/Sample.app \
  --device fake-ios-1 \
  --ios-shim ./.zmr/ios-shim \
  --trace-root traces/direct-ios-pilot 2>&1)"

python3 - "$app_cwd_output" "$APP_CWD" "$TMPDIR" <<'PY'
import os
import sys

output = sys.argv[1]
app = os.path.realpath(sys.argv[2])
tmp = os.path.realpath(sys.argv[3])

assert f"App root: {app}" in output
assert f"{tmp}/bin/zmr validate examples/ios-smoke.json" in output
assert f"xcrun simctl install fake-ios-1 {app}/build/Debug-iphonesimulator/Sample.app" in output
assert f"--ios-shim {app}/.zmr/ios-shim" in output
assert f"--trace-dir {app}/traces/direct-ios-pilot/ios-smoke" in output
PY

benchmark_output="$("$ROOT/scripts/run-ios-pilot.sh" \
  --dry-run \
  --app-root "$APP_ROOT" \
  --app-path "$APP_PATH" \
  --device fake-ios-1 \
  --app-id com.example.override \
  --xcrun ./tests/fake-xcrun.sh \
  --ios-shim ./tests/fake-ios-shim.sh \
  --trace-root "$TMPDIR/pilot-benchmark" \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --max-p95-ms 45000 2>&1)"

python3 - "$benchmark_output" "$APP_PATH" "$TMPDIR/pilot-benchmark" "$ROOT" <<'PY'
import os
import sys

output = sys.argv[1]
app_path = sys.argv[2]
trace_root = sys.argv[3]
root = os.path.realpath(sys.argv[4])
xcrun = f"{root}/tests/fake-xcrun.sh"
ios_shim = f"{root}/tests/fake-ios-shim.sh"

assert f"{xcrun} simctl install fake-ios-1 {app_path}" in output
assert f"""printf '{{"cmd":"appState"}}\\n' | {ios_shim}""" in output
assert "benchmark.sh --zmr examples/ios-smoke.json" in output
assert "benchmark.sh --zmr examples/ios-shim-smoke.json" in output
assert "--platform ios" in output
assert "--ios-device-type simulator" in output
assert "--app-id com.example.override" in output
assert f"--xcrun {xcrun}" in output
assert f"--ios-shim {ios_shim}" in output
assert "--runs 20" in output
assert "--min-pass-rate 100" in output
assert "--max-failures 0" in output
assert "--max-p95-ms 45000" in output
assert f"--trace-root {trace_root}/ios-smoke-benchmark" in output
assert f"--trace-root {trace_root}/ios-shim-smoke-benchmark" in output
assert "Benchmark reports:" in output
assert "ios-smoke-benchmark/report.html" in output
assert "ios-shim-smoke-benchmark/report.html" in output
assert "ios-smoke-benchmark/junit.xml" in output
assert "ios-shim-smoke-benchmark/junit.xml" in output
assert f"zmr report {trace_root}/ios-smoke-benchmark --out {trace_root}/ios-smoke-benchmark/report.html --junit {trace_root}/ios-smoke-benchmark/junit.xml" in output
assert f"zmr report {trace_root}/ios-shim-smoke-benchmark --out {trace_root}/ios-shim-smoke-benchmark/report.html --junit {trace_root}/ios-shim-smoke-benchmark/junit.xml" in output
assert "Shareable bundle:" not in output
PY

skip_prewarm_output="$("$ROOT/scripts/run-ios-pilot.sh" \
  --dry-run \
  --app-root "$APP_ROOT" \
  --app-path "$APP_PATH" \
  --device fake-ios-1 \
  --ios-shim ./tests/fake-ios-shim.sh \
  --skip-shim-prewarm \
  --trace-root "$TMPDIR/pilot-skip-prewarm" 2>&1)"

python3 - "$skip_prewarm_output" <<'PY'
import sys

output = sys.argv[1]

assert "zmr validate examples/ios-shim-smoke.json" in output
assert """printf '{"cmd":"appState"}\\n' | ./tests/fake-ios-shim.sh""" not in output
assert "zmr run examples/ios-shim-smoke.json" in output
PY

physical_output="$("$ROOT/scripts/run-ios-pilot.sh" \
  --dry-run \
  --app-path "$TMPDIR/Sample.ipa" \
  --ios-device-type physical \
  --device fake-physical-ios-1 \
  --app-id com.example.physical \
  --xcrun ./tests/fake-xcrun.sh \
  --ios-shim ./tests/fake-ios-shim.sh \
  --trace-root "$TMPDIR/pilot-physical" 2>&1)"

python3 - "$physical_output" "$TMPDIR/Sample.ipa" "$TMPDIR/pilot-physical" "$ROOT" <<'PY'
import os
import sys

output = sys.argv[1]
app_path = sys.argv[2]
trace_root = sys.argv[3]
root = os.path.realpath(sys.argv[4])
xcrun = f"{root}/tests/fake-xcrun.sh"
ios_shim = f"{root}/tests/fake-ios-shim.sh"

assert f"{xcrun} devicectl device install app --device fake-physical-ios-1 {app_path}" in output
assert "simctl install" not in output
assert "zmr run examples/ios-smoke.json --platform ios --ios-device-type physical --device fake-physical-ios-1" in output
assert "zmr run examples/ios-shim-smoke.json --platform ios --ios-device-type physical --device fake-physical-ios-1" in output
assert "--app-id com.example.physical" in output
assert f"--ios-shim {ios_shim}" in output
assert f"--trace-dir {trace_root}/ios-smoke" in output
assert f"zmr report {trace_root}/ios-smoke --out {trace_root}/ios-smoke/report.html --junit {trace_root}/ios-smoke/junit.xml" in output
assert f"zmr report {trace_root}/ios-shim-smoke --out {trace_root}/ios-shim-smoke/report.html --junit {trace_root}/ios-shim-smoke/junit.xml" in output
PY
