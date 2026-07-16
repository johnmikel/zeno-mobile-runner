#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
TMPDIR="$(cd "$TMPDIR" && pwd -P)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--app-root" "--app-id" "--apk" "--device" "--avd" "--trace-root" "--zmr-bin" "--adb" "--runs" "--min-pass-rate" "--max-failures" "--max-mean-ms" "--max-p95-ms" "--restore-snapshot"; do
  set +e
  missing_value_output="$("$ROOT/scripts/run-android-pilot.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "run-android-pilot should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

APP_ROOT="$TMPDIR/android-app"
mkdir -p "$APP_ROOT/android/app/build/outputs/apk/debug"
touch "$APP_ROOT/.env.test"
touch "$APP_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
mkdir -p "$TMPDIR/bin"
touch "$TMPDIR/bin/zmr"
chmod +x "$TMPDIR/bin/zmr"

EMPTY_ADB="$TMPDIR/fake-adb-empty.sh"
cat > "$EMPTY_ADB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  devices) printf 'List of devices attached\n' ;;
  version) printf 'Android Debug Bridge version 1.0.41\n' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$EMPTY_ADB"

set +e
missing_device_output="$("$ROOT/scripts/run-android-pilot.sh" \
  --skip-emulator \
  --skip-metro \
  --app-root "$APP_ROOT" \
  --adb "$EMPTY_ADB" \
  --device emulator-5554 \
  --trace-root "$TMPDIR/pilot-missing-device" 2>&1)"
missing_device_status=$?
set -e

if [[ "$missing_device_status" -eq 0 ]]; then
  echo "expected Android pilot preflight to fail when the requested device is absent" >&2
  exit 1
fi

grep -q 'no Android device found: emulator-5554' <<< "$missing_device_output"
grep -q 'setup.android.no_devices' <<< "$missing_device_output"
grep -q 'zmr doctor --json' <<< "$missing_device_output"

output="$(PATH="$TMPDIR/bin:$PATH" "$ROOT/scripts/run-android-pilot.sh" \
  --dry-run \
  --skip-emulator \
  --skip-metro \
  --app-root "$APP_ROOT" \
  --app-id com.example.override \
  --device emulator-5554 \
  --trace-root "$TMPDIR/pilot" 2>&1)"

python3 - "$output" "$APP_ROOT" "$TMPDIR/pilot" <<'PY'
import sys

output = sys.argv[1]
app_root = sys.argv[2]
trace_root = sys.argv[3]

assert "DRY RUN" in output
assert "--adb" not in output
assert f"{trace_root.rsplit('/pilot', 1)[0]}/bin/zmr validate examples/android-app-auth-probe.json" in output
assert "zmr validate examples/android-app-auth-probe.json" in output
assert "zmr validate examples/android-app-login-smoke.json" in output
assert f"adb -s emulator-5554 install -r {app_root}/android/app/build/outputs/apk/debug/app-debug.apk" in output
assert "zmr run examples/android-app-auth-probe.json --device emulator-5554" in output
assert "zmr run examples/android-app-login-smoke.json --device emulator-5554" in output
assert "--app-id com.example.override" in output
assert f"--trace-dir {trace_root}/auth" in output
assert f"--trace-dir {trace_root}/login-smoke" in output
assert f"zmr report {trace_root}/auth --out {trace_root}/auth/report.html --junit {trace_root}/auth/junit.xml" in output
assert f"zmr report {trace_root}/login-smoke --out {trace_root}/login-smoke/report.html --junit {trace_root}/login-smoke/junit.xml" in output
assert "zmr export" in output
assert "--redact" in output
assert ".env.test" in output
assert "dotenv" not in output.lower()
PY

APP_CWD="$TMPDIR/app-cwd"
mkdir -p "$APP_CWD/android/app/build/outputs/apk/debug"
touch "$APP_CWD/.env.test" "$APP_CWD/android/app/build/outputs/apk/debug/app-debug.apk"
app_cwd_output="$(cd "$APP_CWD" && PATH="$TMPDIR/bin:$PATH" "$ROOT/scripts/run-android-pilot.sh" \
  --dry-run \
  --skip-emulator \
  --skip-metro \
  --app-root . \
  --apk ./android/app/build/outputs/apk/debug/app-debug.apk \
  --trace-root traces/direct-android-pilot 2>&1)"

python3 - "$app_cwd_output" "$APP_CWD" "$TMPDIR" <<'PY'
import os
import sys

output = sys.argv[1]
app = os.path.realpath(sys.argv[2])
tmp = os.path.realpath(sys.argv[3])

assert f"App test env: {app}/.env.test" in output
assert f"{tmp}/bin/zmr validate examples/android-app-auth-probe.json" in output
assert f"adb -s emulator-5554 install -r {app}/android/app/build/outputs/apk/debug/app-debug.apk" in output
assert f"--trace-dir {app}/traces/direct-android-pilot/auth" in output
PY

CUSTOM_ADB="$TMPDIR/custom-adb.sh"
touch "$CUSTOM_ADB"
chmod +x "$CUSTOM_ADB"

custom_adb_output="$("$ROOT/scripts/run-android-pilot.sh" \
  --dry-run \
  --skip-emulator \
  --skip-metro \
  --app-root "$APP_ROOT" \
  --adb "$CUSTOM_ADB" \
  --device emulator-5554 \
  --trace-root "$TMPDIR/pilot-custom-adb" 2>&1)"

python3 - "$custom_adb_output" "$CUSTOM_ADB" <<'PY'
import sys

output = sys.argv[1]
custom_adb = sys.argv[2]

assert f"{custom_adb} -s emulator-5554 install -r" in output
assert f"zmr run examples/android-app-auth-probe.json --device emulator-5554 --app-id com.example.mobiletest --trace-dir" in output
assert f"--adb {custom_adb}" in output
assert f"zmr run examples/android-app-login-smoke.json --device emulator-5554 --app-id com.example.mobiletest --trace-dir" in output
PY

ANDROID_HOME="$TMPDIR/android-sdk"
mkdir -p "$ANDROID_HOME/emulator"
touch "$ANDROID_HOME/emulator/emulator"
chmod +x "$ANDROID_HOME/emulator/emulator"

lifecycle_output="$(ANDROID_HOME="$ANDROID_HOME" "$ROOT/scripts/run-android-pilot.sh" \
  --dry-run \
  --skip-metro \
  --reset-emulator \
  --restore-snapshot zmr-clean \
  --screen-record \
  --avd Small_Phone \
  --app-root "$APP_ROOT" \
  --device emulator-5554 \
  --trace-root "$TMPDIR/pilot-lifecycle" 2>&1)"

python3 - "$lifecycle_output" "$ANDROID_HOME" <<'PY'
import sys

output = sys.argv[1]
android_home = sys.argv[2]

assert "adb -s emulator-5554 emu kill" in output
assert f"{android_home}/emulator/emulator -avd Small_Phone" in output
assert "-snapshot zmr-clean" in output
assert "-no-snapshot-save" in output
assert "wait for adb device emulator-5554" in output
assert "wait for Android boot completion on emulator-5554" in output
assert "adb -s emulator-5554 shell rm -f /sdcard/zmr-pilot-screenrecord.mp4" in output
assert "adb -s emulator-5554 shell screenrecord /sdcard/zmr-pilot-screenrecord.mp4" in output
assert "adb -s emulator-5554 pull /sdcard/zmr-pilot-screenrecord.mp4" in output
assert "screenrecord.mp4" in output
PY

benchmark_output="$("$ROOT/scripts/run-android-pilot.sh" \
  --dry-run \
  --skip-emulator \
  --skip-metro \
  --app-root "$APP_ROOT" \
  --app-id com.example.override \
  --device emulator-5554 \
  --trace-root "$TMPDIR/pilot-benchmark" \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --max-p95-ms 30000 2>&1)"

python3 - "$benchmark_output" "$TMPDIR/pilot-benchmark" <<'PY'
import sys

output = sys.argv[1]
trace_root = sys.argv[2]

assert "benchmark.sh --zmr examples/android-app-auth-probe.json" in output
assert "benchmark.sh --zmr examples/android-app-login-smoke.json" in output
assert "--runs 20" in output
assert "--app-id com.example.override" in output
assert "--min-pass-rate 100" in output
assert "--max-failures 0" in output
assert "--max-p95-ms 30000" in output
assert f"--trace-root {trace_root}/bench-auth" in output
assert f"--trace-root {trace_root}/bench-login-smoke" in output
assert f"zmr report {trace_root}/bench-auth --out {trace_root}/bench-auth/report.html --junit {trace_root}/bench-auth/junit.xml" in output
assert f"zmr report {trace_root}/bench-login-smoke --out {trace_root}/bench-login-smoke/report.html --junit {trace_root}/bench-login-smoke/junit.xml" in output
assert "Benchmark reports:" in output
assert "bench-auth/report.html" in output
assert "bench-auth/junit.xml" in output
assert "bench-login-smoke/report.html" in output
assert "bench-login-smoke/junit.xml" in output
assert "Shareable bundles:" not in output
PY

custom_adb_benchmark_output="$("$ROOT/scripts/run-android-pilot.sh" \
  --dry-run \
  --skip-emulator \
  --skip-metro \
  --app-root "$APP_ROOT" \
  --adb "$CUSTOM_ADB" \
  --device emulator-5554 \
  --trace-root "$TMPDIR/pilot-custom-adb-benchmark" \
  --runs 2 2>&1)"

python3 - "$custom_adb_benchmark_output" "$CUSTOM_ADB" <<'PY'
import sys

output = sys.argv[1]
custom_adb = sys.argv[2]

assert "benchmark.sh --zmr examples/android-app-auth-probe.json" in output
assert "benchmark.sh --zmr examples/android-app-login-smoke.json" in output
assert f"--adb {custom_adb}" in output
PY

EVIDENCE_ZMR="$TMPDIR/evidence-zmr.sh"
cat > "$EVIDENCE_ZMR" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
action=${1:-}
shift || true
case "$action" in
  version) printf 'zmr 1.0.0\n' ;;
  validate) ;;
  run)
    trace_dir=
    outcome_file=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --trace-dir) trace_dir=${2:-}; shift 2 ;;
        --outcome-file) outcome_file=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "$trace_dir" && -n "$outcome_file" ]]
    trace_relative=${trace_dir#"$ZMR_RUN_EVIDENCE_ROOT"/}
    [[ "$trace_relative" != "$trace_dir" ]]
    mkdir -p "$trace_dir"
    printf '%s\n' '{"event":"scenario-start"}' > "$trace_dir/trace.jsonl"
    printf '%s\n' "{\"schemaVersion\":1,\"status\":\"passed\",\"failureOwner\":\"none\",\"errorCode\":null,\"phase\":\"complete\",\"summary\":null,\"hint\":null,\"trace\":\"$trace_relative\",\"report\":null,\"childStatus\":0,\"iosShim\":null}" > "$ZMR_RUN_EVIDENCE_ROOT/$outcome_file"
    ;;
  report)
    trace_dir=${1:?}
    shift
    report=
    junit=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --out) report=${2:-}; shift 2 ;;
        --junit) junit=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'report\n' > "$report"
    printf '<testsuite/>\n' > "$junit"
    ;;
  export)
    shift
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --out ]]; then
        printf 'bundle\n' > "${2:?}"
        exit 0
      fi
      shift
    done
    exit 2
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$EVIDENCE_ZMR"

EVIDENCE_ADB="$TMPDIR/evidence-adb.sh"
cat > "$EVIDENCE_ADB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == devices ]]; then
  printf 'List of devices attached\nemulator-5554\tdevice\n'
  exit 0
fi
if [[ "${1:-}" == -s && "${3:-}" == shell && "${4:-}" == getprop ]]; then
  printf '1\n'
fi
exit 0
SH
chmod +x "$EVIDENCE_ADB"

EVIDENCE_PUBLICATION="$TMPDIR/evidence-android-pilot"
EVIDENCE_ATTEMPT="$EVIDENCE_PUBLICATION/attempts/android-pilot-run"
EVIDENCE_INDEX="$EVIDENCE_PUBLICATION/attempt-index.json"
mkdir -p "$EVIDENCE_PUBLICATION/attempts"
python3 "$ROOT/scripts/run_evidence.py" init \
  --root "$EVIDENCE_ATTEMPT" \
  --index "$EVIDENCE_INDEX" \
  --context-json '{"runId":"android-pilot-run","executionId":"android-pilot-logical","fixtureId":"android-pilot","fixtureVersion":"1","candidateRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","scenarioDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","appBuildDigest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","platform":"android","deviceClass":"android-emulator","runtimeVersion":"35","timingMode":"cold-command","runnerVersion":"1.0.0","protocolVersion":"2026-04-28","attempt":1,"host":{"os":"macos","arch":"arm64","class":"local-test","ci":false},"device":{"requested":"emulator-5554","resolved":"emulator-5554"},"toolchain":{"xcode":null,"zig":"0.16.0"},"artifacts":{"trace":null,"report":null}}' >/dev/null

touch "$TMPDIR/android-smoke-evidence.json"
ZMR_RUN_EVIDENCE_ROOT="$EVIDENCE_ATTEMPT" \
ZMR_RUN_EVIDENCE_INDEX="$EVIDENCE_INDEX" \
  "$ROOT/scripts/run-android-pilot.sh" \
  --skip-emulator \
  --skip-metro \
  --app-root "$APP_ROOT" \
  --scenario "$TMPDIR/android-smoke-evidence.json" \
  --zmr-bin "$EVIDENCE_ZMR" \
  --adb "$EVIDENCE_ADB" \
  --device emulator-5554 \
  --trace-root "$EVIDENCE_ATTEMPT/traces/android-pilot" >/dev/null

python3 "$ROOT/scripts/run_evidence.py" validate-bundle --root "$EVIDENCE_ATTEMPT" >/dev/null
python3 - "$EVIDENCE_ATTEMPT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in (root / "bootstrap-events.jsonl").read_text().splitlines()]
phases = [event["phase"] for event in events]
expected = ["scenario.validate", "app.install", "scenario.execute", "report.generate", "cleanup"]
position = -1
for phase in expected:
    position = phases.index(phase, position + 1)
summary = json.loads((root / "run-summary.json").read_text())
assert summary["status"] == "passed"
assert summary["artifacts"]["trace"] == "traces/android-pilot/scenario"
assert summary["artifacts"]["report"] == "traces/android-pilot/scenario/report.html"
assert list((root / "run-outcomes").glob("*.json"))
PY
