#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--matrix" "--trace-root" "--min-pass-rate" "--max-failures"; do
  set +e
  missing_value_output="$("$ROOT/scripts/device-matrix.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "device-matrix should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

cat > "$TMPDIR/fake-zmr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
platform="android"
ios_device_type=""
device=""
trace_dir=""
scenario=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    run)
      shift
      scenario="${1:-}"
      shift
      ;;
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    --device)
      device="${2:-}"
      shift 2
      ;;
    --ios-device-type)
      ios_device_type="${2:-}"
      shift 2
      ;;
    --trace-dir)
      trace_dir="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$trace_dir"
case "$device" in
  failing-device)
    printf '{"seq":1,"kind":"scenario.end","payload":{"status":"failed","error":"WaitTimeout"}}\n' > "$trace_dir/events.jsonl"
    exit 1
    ;;
  fake-physical-ios-1)
    if [[ "$ios_device_type" != "physical" ]]; then
      echo "physical iOS matrix run missing --ios-device-type physical" >&2
      exit 9
    fi
    printf '{"seq":1,"kind":"scenario.end","payload":{"status":"passed","platform":"%s","scenario":"%s","iosDeviceType":"%s"}}\n' "$platform" "$scenario" "$ios_device_type" > "$trace_dir/events.jsonl"
    ;;
  *)
    printf '{"seq":1,"kind":"scenario.end","payload":{"status":"passed","platform":"%s","scenario":"%s"}}\n' "$platform" "$scenario" > "$trace_dir/events.jsonl"
    ;;
esac
SH
chmod +x "$TMPDIR/fake-zmr"
touch "$TMPDIR/android-smoke.json" "$TMPDIR/ios-smoke.json"

cat > "$TMPDIR/matrix.json" <<JSON
{
  "runs": 2,
  "appId": "com.example.mobiletest",
  "devices": [
    {
      "name": "android-api-35",
      "platform": "android",
      "serial": "emulator-5554",
      "scenario": "$TMPDIR/android-smoke.json",
      "adb": "./tests/fake-adb.sh"
    },
    {
      "name": "ios-18",
      "platform": "ios",
      "serial": "booted",
      "scenario": "$TMPDIR/ios-smoke.json",
      "xcrun": "./tests/fake-xcrun.sh",
      "iosShim": "./tests/fake-ios-shim.sh"
    },
    {
      "name": "ios-physical",
      "platform": "ios",
      "iosDeviceType": "physical",
      "serial": "fake-physical-ios-1",
      "scenario": "$TMPDIR/ios-smoke.json",
      "xcrun": "./tests/fake-xcrun.sh",
      "iosShim": "./tests/fake-ios-shim.sh"
    }
  ]
}
JSON

ZMR_BIN="$TMPDIR/fake-zmr" "$ROOT/scripts/device-matrix.sh" \
  --matrix "$TMPDIR/matrix.json" \
  --trace-root "$TMPDIR/matrix-pass" \
  --min-pass-rate 100 \
  --max-failures 0 > "$TMPDIR/matrix-pass.out"

grep -q 'matrix: runs=6 passRate=100.00% failures=0' "$TMPDIR/matrix-pass.out"
test -f "$TMPDIR/matrix-pass/matrix.jsonl"
test -f "$TMPDIR/matrix-pass/summary.json"

python3 - "$TMPDIR/matrix-pass" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in (root / "matrix.jsonl").read_text().splitlines()]
summary = json.loads((root / "summary.json").read_text())
assert len(rows) == 6
assert {row["deviceName"] for row in rows} == {"android-api-35", "ios-18", "ios-physical"}
assert {row["platform"] for row in rows} == {"android", "ios"}
assert summary["totalRuns"] == 6
assert summary["passed"] == 6
assert summary["failed"] == 0
assert summary["passRate"] == 100.0
PY

APP_MATRIX_DIR="$TMPDIR/app-matrix-defaults"
mkdir -p "$APP_MATRIX_DIR"
APP_MATRIX_DIR="$(cd "$APP_MATRIX_DIR" && pwd -P)"
cat > "$APP_MATRIX_DIR/matrix.json" <<JSON
{
  "runs": 1,
  "devices": [
    {
      "name": "app-default-device",
      "platform": "android",
      "serial": "emulator-5554",
      "scenario": "$TMPDIR/android-smoke.json"
    }
  ]
}
JSON
pushd "$APP_MATRIX_DIR" >/dev/null
ZMR_BIN="$TMPDIR/fake-zmr" "$ROOT/scripts/device-matrix.sh" --matrix matrix.json > "$TMPDIR/matrix-default.out"
popd >/dev/null
matrix_summaries=("$APP_MATRIX_DIR"/traces/matrix-*/summary.json)
if [[ ! -f "${matrix_summaries[0]}" ]]; then
  echo "device-matrix.sh should default trace output to the caller app directory, not the package root" >&2
  exit 1
fi

cat > "$TMPDIR/matrix-fail.json" <<JSON
{
  "runs": 1,
  "devices": [
    {
      "name": "bad-device",
      "platform": "android",
      "serial": "failing-device",
      "scenario": "$TMPDIR/android-smoke.json"
    },
    {
      "name": "good-device",
      "platform": "android",
      "serial": "emulator-5554",
      "scenario": "$TMPDIR/android-smoke.json"
    }
  ]
}
JSON

if ZMR_BIN="$TMPDIR/fake-zmr" "$ROOT/scripts/device-matrix.sh" \
  --matrix "$TMPDIR/matrix-fail.json" \
  --trace-root "$TMPDIR/matrix-fail" \
  --min-pass-rate 100 \
  --max-failures 0 > "$TMPDIR/matrix-fail.out" 2>&1; then
  echo "device matrix should fail when thresholds reject results" >&2
  exit 1
fi
grep -q 'matrix gate failed' "$TMPDIR/matrix-fail.out"
grep -q 'passRate=50.00%' "$TMPDIR/matrix-fail.out"

EVIDENCE_PUBLICATION="$TMPDIR/matrix-evidence"
EVIDENCE_INDEX="$EVIDENCE_PUBLICATION/attempt-index.json"
mkdir -p "$EVIDENCE_PUBLICATION"
cat > "$TMPDIR/matrix-evidence.json" <<JSON
{
  "runs": 1,
  "devices": [
    {
      "name": "android-api-35",
      "platform": "android",
      "runtimeVersion": "35",
      "serial": "emulator-5554",
      "scenario": "$TMPDIR/android-smoke.json"
    }
  ]
}
JSON

for retry in 1 2; do
  ZMR_BIN="$ROOT/tests/fixtures/fake-zmr-evidence-success.sh" \
  ZMR_RUN_EVIDENCE_ROOT="$EVIDENCE_PUBLICATION" \
  ZMR_RUN_EVIDENCE_INDEX="$EVIDENCE_INDEX" \
  ZMR_MATRIX_RUN_ID="release-candidate" \
    "$ROOT/scripts/device-matrix.sh" \
    --matrix "$TMPDIR/matrix-evidence.json" \
    --trace-root "$TMPDIR/matrix-evidence-results" \
    --min-pass-rate 100 \
    --max-failures 0 >/dev/null
done

python3 - "$EVIDENCE_PUBLICATION" "$ROOT" <<'PY'
import json
import pathlib
import subprocess
import sys

publication = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
index = json.loads((publication / "attempt-index.json").read_text())
assert len(index["executions"]) == 1
execution = index["executions"][0]
assert execution["executionId"] == "release-candidate-android-api-35-logical-1"
assert [row["attempt"] for row in execution["attempts"]] == [1, 2]
run_ids = [row["runId"] for row in execution["attempts"]]
assert len(set(run_ids)) == 2
assert run_ids == [
    "release-candidate-android-api-35-logical-1-attempt-1",
    "release-candidate-android-api-35-logical-1-attempt-2",
]
for run_id in run_ids:
    attempt = publication / "attempts" / run_id
    context = json.loads((attempt / "run-context.json").read_text())
    summary = json.loads((attempt / "run-summary.json").read_text())
    assert context["executionId"] == execution["executionId"]
    assert context["runId"] == run_id
    assert summary["status"] == "passed"
    assert list((attempt / "run-outcomes").glob("*.json"))
    subprocess.run(
        [sys.executable, str(root / "scripts/run_evidence.py"), "validate-bundle", "--root", str(attempt)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
PY
