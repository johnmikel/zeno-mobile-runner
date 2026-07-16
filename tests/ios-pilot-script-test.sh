#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
TMPDIR="$(cd "$TMPDIR" && pwd -P)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--app-root" "--app-path" "--device" "--ios-device-type" "--app-id" "--trace-root" "--zmr-bin" "--xcrun" "--ios-shim" "--ios-shim-mode" "--runs" "--min-pass-rate" "--max-failures" "--max-mean-ms" "--max-p95-ms"; do
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

EVIDENCE_ZMR="$TMPDIR/evidence-ios-zmr.sh"
cat > "$EVIDENCE_ZMR" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
action=${1:-}
shift || true
case "$action" in
  version) printf 'zmr 1.0.0\n' ;;
  validate) ;;
  devices) printf '%s\n' '{"count":1,"devices":[{"serial":"fake-ios-1","state":"booted"}]}' ;;
  run)
    trace_dir=
    outcome_file=
    shim_mode=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --trace-dir) trace_dir=${2:-}; shift 2 ;;
        --outcome-file) outcome_file=${2:-}; shift 2 ;;
        --ios-shim-mode) shim_mode=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "$trace_dir" && -n "$outcome_file" && "$shim_mode" == provided ]]
    trace_relative=${trace_dir#"$ZMR_RUN_EVIDENCE_ROOT"/}
    [[ "$trace_relative" != "$trace_dir" ]]
    mkdir -p "$trace_dir"
    printf '%s\n' '{"event":"scenario-start"}' > "$trace_dir/trace.jsonl"
    printf '%s\n' "{\"schemaVersion\":1,\"status\":\"passed\",\"failureOwner\":\"none\",\"errorCode\":null,\"phase\":\"complete\",\"summary\":null,\"hint\":null,\"trace\":\"$trace_relative\",\"report\":null,\"childStatus\":0,\"iosShim\":{\"targetKind\":\"simulator\",\"mode\":\"provided\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}" > "$ZMR_RUN_EVIDENCE_ROOT/$outcome_file"
    ;;
  report)
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

EVIDENCE_XCRUN="$TMPDIR/evidence-xcrun.sh"
cat > "$EVIDENCE_XCRUN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'xcrun version 70\n'
fi
exit 0
SH
chmod +x "$EVIDENCE_XCRUN"

EVIDENCE_SHIM="$TMPDIR/evidence-ios-shim.sh"
cat > "$EVIDENCE_SHIM" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
read -r request
[[ "$request" == '{"cmd":"appState"}' ]]
printf '%s\n' '{"ok":true,"state":"running"}'
SH
chmod +x "$EVIDENCE_SHIM"

EVIDENCE_PUBLICATION="$TMPDIR/evidence-ios-pilot"
EVIDENCE_ATTEMPT="$EVIDENCE_PUBLICATION/attempts/ios-pilot-run"
EVIDENCE_INDEX="$EVIDENCE_PUBLICATION/attempt-index.json"
mkdir -p "$EVIDENCE_PUBLICATION/attempts"
python3 "$ROOT/scripts/run_evidence.py" init \
  --root "$EVIDENCE_ATTEMPT" \
  --index "$EVIDENCE_INDEX" \
  --context-json '{"runId":"ios-pilot-run","executionId":"ios-pilot-logical","fixtureId":"ios-pilot","fixtureVersion":"1","candidateRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","scenarioDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","appBuildDigest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","platform":"ios","deviceClass":"ios-simulator","runtimeVersion":"18.5","timingMode":"cold-command","runnerVersion":"1.0.0","protocolVersion":"2026-04-28","attempt":1,"host":{"os":"macos","arch":"arm64","class":"local-test","ci":false},"device":{"requested":"fake-ios-1","resolved":"fake-ios-1"},"toolchain":{"xcode":"16.4","zig":"0.16.0"},"artifacts":{"trace":null,"report":null}}' >/dev/null

ZMR_RUN_EVIDENCE_ROOT="$EVIDENCE_ATTEMPT" \
ZMR_RUN_EVIDENCE_INDEX="$EVIDENCE_INDEX" \
  "$ROOT/scripts/run-ios-pilot.sh" \
  --app-root "$APP_ROOT" \
  --app-path "$APP_PATH" \
  --device fake-ios-1 \
  --ios-device-type simulator \
  --ios-shim "$EVIDENCE_SHIM" \
  --ios-shim-mode provided \
  --zmr-bin "$EVIDENCE_ZMR" \
  --xcrun "$EVIDENCE_XCRUN" \
  --trace-root "$EVIDENCE_ATTEMPT/traces/ios-pilot" >/dev/null

python3 "$ROOT/scripts/run_evidence.py" validate-bundle --root "$EVIDENCE_ATTEMPT" >/dev/null
python3 - "$EVIDENCE_ATTEMPT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in (root / "bootstrap-events.jsonl").read_text().splitlines()]
phases = [event["phase"] for event in events]
expected = ["scenario.validate", "app.install", "shim.build", "shim.start", "shim.prewarm", "scenario.execute", "report.generate", "cleanup"]
position = -1
for phase in expected:
    position = phases.index(phase, position + 1)
summary = json.loads((root / "run-summary.json").read_text())
assert summary["status"] == "passed"
assert summary["artifacts"]["trace"] == "traces/ios-pilot/ios-shim-smoke"
assert summary["artifacts"]["report"] == "traces/ios-pilot/ios-shim-smoke/report.html"
sidecars = list((root / "run-outcomes").glob("*.json"))
assert len(sidecars) == 2
assert all(json.loads(path.read_text())["iosShim"]["mode"] == "provided" for path in sidecars)
PY
