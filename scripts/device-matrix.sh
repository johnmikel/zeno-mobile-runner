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
CALLER_CWD="$(pwd -P)"
ZMR_BIN="${ZMR_BIN:-$(command -v zmr 2>/dev/null || printf '%s' "$ROOT/zig-out/bin/zmr")}"
MATRIX=""
TRACE_ROOT="${TRACE_ROOT:-$CALLER_CWD/traces/matrix-$(date +%Y%m%d-%H%M%S)}"
MIN_PASS_RATE="${MIN_PASS_RATE:-}"
MAX_FAILURES="${MAX_FAILURES:-}"
MATRIX_RUN_ID="${ZMR_MATRIX_RUN_ID:-matrix-$(date +%Y%m%d-%H%M%S)}"
MATRIX_EVIDENCE_INDEX="${ZMR_RUN_EVIDENCE_INDEX:-}"
MATRIX_EVIDENCE_PUBLICATION=""
if [[ -n "$MATRIX_EVIDENCE_INDEX" ]]; then
  MATRIX_EVIDENCE_PUBLICATION="$(dirname "$MATRIX_EVIDENCE_INDEX")"
fi

usage() {
  cat <<'USAGE'
Usage:
  scripts/device-matrix.sh --matrix <matrix.json> [--trace-root <dir>] [gate options]

Omit --trace-root to write under traces/matrix-<timestamp> in the caller directory.

Gate options:
  --min-pass-rate <pct>  Minimum total pass rate percentage.
  --max-failures <n>     Maximum total failed matrix runs.

Evidence environment:
  ZMR_RUN_EVIDENCE_INDEX  Enable one durable attempt bundle per matrix row and
                          write the shared attempt index at this path.
  ZMR_MATRIX_RUN_ID       Stable matrix identity. Reusing it creates the next
                          monotonic attempt for each logical row.
  ZMR_CANDIDATE_REVISION  Optional 40-character lowercase candidate revision.
  ZMR_RUNNER_VERSION      Optional runner version used in comparison identity.

When evidence is enabled, set runtimeVersion and appBuildDigest on each device
row when known. Missing values remain explicit and make that row ineligible for
certification without making the diagnostic run unusable.

Matrix format:
  {
    "runs": 2,
    "appId": "com.example.mobiletest",
    "devices": [
      {
        "name": "android-api-35",
        "platform": "android",
        "serial": "emulator-5554",
        "scenario": ".zmr/android-smoke.json",
        "adb": "adb",
        "androidShim": ".zmr/android-shim"
      },
      {
        "name": "ios-18",
        "platform": "ios",
        "iosDeviceType": "simulator",
        "serial": "booted",
        "scenario": ".zmr/ios-smoke.json",
        "xcrun": "xcrun",
        "iosShim": ".zmr/ios-shim",
        "iosShimMode": "provided",
        "runtimeVersion": "18.5",
        "appBuildDigest": "sha256:<64 lowercase hex characters>"
      },
      {
        "name": "ios-physical",
        "platform": "ios",
        "iosDeviceType": "physical",
        "serial": "<physical-device-id>",
        "scenario": ".zmr/ios-smoke.json",
        "xcrun": "xcrun",
        "iosShim": ".zmr/ios-shim"
      }
    ]
  }
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --matrix)
      MATRIX="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --trace-root)
      TRACE_ROOT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --min-pass-rate)
      MIN_PASS_RATE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --max-failures)
      MAX_FAILURES="$(require_value "$1" "${2-}")"
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

if [[ -z "$MATRIX" ]]; then
  echo "error: --matrix is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$MATRIX" ]]; then
  die "matrix file not found: $MATRIX"
fi

if [[ ! -x "$ZMR_BIN" ]]; then
  die "zmr binary is not executable: $ZMR_BIN"
fi

validate_optional_number() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "$name must be a non-negative number" >&2
    exit 2
  fi
}

validate_optional_integer() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer" >&2
    exit 2
  fi
}

validate_optional_number "--min-pass-rate" "$MIN_PASS_RATE"
validate_optional_integer "--max-failures" "$MAX_FAILURES"

if [[ -n "$MATRIX_EVIDENCE_INDEX" ]]; then
  mkdir -p "$MATRIX_EVIDENCE_PUBLICATION/attempts"
  MATRIX_EVIDENCE_PUBLICATION="$(cd "$MATRIX_EVIDENCE_PUBLICATION" && pwd -P)"
  MATRIX_EVIDENCE_INDEX="$MATRIX_EVIDENCE_PUBLICATION/$(basename "$MATRIX_EVIDENCE_INDEX")"
fi

mkdir -p "$TRACE_ROOT"
ROWS="$TRACE_ROOT/matrix.rows.tsv"
RESULTS="$TRACE_ROOT/matrix.jsonl"
SUMMARY="$TRACE_ROOT/summary.json"
: > "$RESULTS"

python3 - "$MATRIX" > "$ROWS" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    matrix = json.load(fh)

runs = int(matrix.get("runs", 1))
if runs < 1:
    raise SystemExit("matrix.runs must be >= 1")

default_app_id = matrix.get("appId", "")
devices = matrix.get("devices")
if not isinstance(devices, list) or not devices:
    raise SystemExit("matrix.devices must be a non-empty array")

fields = [
    "name",
    "platform",
    "iosDeviceType",
    "serial",
    "scenario",
    "appId",
    "adb",
    "androidShim",
    "xcrun",
    "iosShim",
    "iosShimMode",
    "runtimeVersion",
    "appBuildDigest",
]

for index, device in enumerate(devices):
    if not isinstance(device, dict):
        raise SystemExit(f"matrix.devices[{index}] must be an object")
    row = {}
    row["name"] = device.get("name") or device.get("serial") or f"device-{index + 1}"
    row["platform"] = device.get("platform", "android")
    row["iosDeviceType"] = device.get("iosDeviceType", "")
    row["serial"] = device.get("serial", "")
    row["scenario"] = device.get("scenario", "")
    row["appId"] = device.get("appId", default_app_id)
    row["adb"] = device.get("adb", "")
    row["androidShim"] = device.get("androidShim", "")
    row["xcrun"] = device.get("xcrun", "")
    row["iosShim"] = device.get("iosShim", "")
    row["iosShimMode"] = device.get(
        "iosShimMode", "provided" if row["iosShim"] else "disabled"
    )
    row["runtimeVersion"] = device.get("runtimeVersion", "unknown")
    row["appBuildDigest"] = device.get("appBuildDigest", "")
    if row["platform"] not in {"android", "ios"}:
        raise SystemExit(f"matrix.devices[{index}].platform must be android or ios")
    if row["iosDeviceType"] and row["iosDeviceType"] not in {"simulator", "physical"}:
        raise SystemExit(f"matrix.devices[{index}].iosDeviceType must be simulator or physical")
    if row["iosShimMode"] not in {"disabled", "generated", "provided"}:
        raise SystemExit(f"matrix.devices[{index}].iosShimMode must be disabled, generated, or provided")
    if row["platform"] == "android" and device.get("iosShimMode") is not None:
        raise SystemExit(f"matrix.devices[{index}].iosShimMode is only valid for iOS")
    if row["iosShimMode"] == "disabled" and row["iosShim"]:
        raise SystemExit(f"matrix.devices[{index}] disabled iosShimMode forbids iosShim")
    if row["platform"] == "ios" and row["iosShimMode"] != "disabled" and not row["iosShim"]:
        raise SystemExit(f"matrix.devices[{index}] enabled iosShimMode requires iosShim")
    if not row["serial"]:
        raise SystemExit(f"matrix.devices[{index}].serial is required")
    if not row["scenario"]:
        raise SystemExit(f"matrix.devices[{index}].scenario is required")
    for run in range(1, runs + 1):
        values = [str(run)]
        for field in fields:
            value = str(row[field]).replace("\t", " ")
            values.append(value if value else "__ZMR_EMPTY__")
        print("\t".join(values))
PY

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

decode_matrix_field() {
  if [[ "$1" == "__ZMR_EMPTY__" ]]; then
    printf ''
  else
    printf '%s' "$1"
  fi
}

next_evidence_attempt() {
  local execution_id="$1"
  python3 - "$MATRIX_EVIDENCE_INDEX" "$execution_id" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
execution_id = sys.argv[2]
if not path.exists():
    print(1)
    raise SystemExit
value = json.loads(path.read_text(encoding="utf-8"))
matches = [row for row in value.get("executions", []) if row.get("executionId") == execution_id]
if not matches:
    print(1)
    raise SystemExit
attempts = matches[0].get("attempts", [])
print(max((int(row["attempt"]) for row in attempts), default=0) + 1)
PY
}

matrix_context_json() {
  local run_id="$1" execution_id="$2" attempt="$3" safe_name="$4"
  local platform="$5" ios_device_type="$6" serial="$7" scenario="$8"
  local runtime_version="$9" app_build_digest="${10}"
  python3 - "$run_id" "$execution_id" "$attempt" "$safe_name" \
    "$platform" "$ios_device_type" "$serial" "$scenario" \
    "$runtime_version" "$app_build_digest" <<'PY'
import hashlib
import json
import os
import pathlib
import platform as host_platform
import re
import sys

(run_id, execution_id, attempt, safe_name, platform, ios_device_type,
 serial, scenario, runtime_version, app_build_digest) = sys.argv[1:]
scenario_path = pathlib.Path(scenario)
scenario_digest = None
if scenario_path.is_file():
    scenario_digest = "sha256:" + hashlib.sha256(scenario_path.read_bytes()).hexdigest()
if not re.fullmatch(r"sha256:[0-9a-f]{64}", app_build_digest):
    app_build_digest = None
candidate = os.environ.get("ZMR_CANDIDATE_REVISION")
if not candidate or not re.fullmatch(r"[0-9a-f]{40}", candidate):
    candidate = None
device_class = "android-device"
if platform == "android" and serial.startswith("emulator-"):
    device_class = "android-emulator"
elif platform == "ios":
    device_class = "ios-physical" if ios_device_type == "physical" else "ios-simulator"
runner_version = os.environ.get("ZMR_RUNNER_VERSION", "unknown")
context = {
    "runId": run_id,
    "executionId": execution_id,
    "fixtureId": "matrix-" + safe_name,
    "fixtureVersion": "1",
    "candidateRevision": candidate,
    "scenarioDigest": scenario_digest,
    "appBuildDigest": app_build_digest,
    "platform": platform,
    "deviceClass": device_class,
    "runtimeVersion": runtime_version or "unknown",
    "timingMode": "cold-command",
    "runnerVersion": runner_version,
    "protocolVersion": "2026-04-28",
    "attempt": int(attempt),
    "host": {
        "os": host_platform.system().lower() or "unknown",
        "arch": host_platform.machine().lower() or "unknown",
        "class": "device-matrix",
        "ci": os.environ.get("CI", "").lower() in {"1", "true", "yes"},
    },
    "device": {"requested": serial, "resolved": serial},
    "toolchain": {"zmr": runner_version},
    "artifacts": {"trace": None, "report": None},
}
print(json.dumps(context, sort_keys=True, separators=(",", ":")))
PY
}

run_evidence_matrix_row() {
  local attempt_root="$1" ios_shim_mode="$2"
  shift 2
  ZMR_RUN_EVIDENCE_ROOT="$attempt_root" \
  ZMR_RUN_EVIDENCE_INDEX="$MATRIX_EVIDENCE_INDEX" \
  ZMR_EVIDENCE_SESSION_ID= \
  ZMR_EVIDENCE_SESSION_GENERATION= \
    /bin/bash -c '
adapter=$1
mode=$2
shift 2
source "$adapter" || exit $?
zmr_evidence_run_outcome scenario.execute matrix-zmr-run "$mode" -- "$@"
' matrix-evidence-row "$ROOT/scripts/run-evidence.sh" "$ios_shim_mode" "$@"
}

while IFS=$'\t' read -r run device_name platform ios_device_type serial scenario app_id adb android_shim xcrun ios_shim ios_shim_mode runtime_version app_build_digest; do
  device_name="$(decode_matrix_field "$device_name")"
  platform="$(decode_matrix_field "$platform")"
  ios_device_type="$(decode_matrix_field "$ios_device_type")"
  serial="$(decode_matrix_field "$serial")"
  scenario="$(decode_matrix_field "$scenario")"
  app_id="$(decode_matrix_field "$app_id")"
  adb="$(decode_matrix_field "$adb")"
  android_shim="$(decode_matrix_field "$android_shim")"
  xcrun="$(decode_matrix_field "$xcrun")"
  ios_shim="$(decode_matrix_field "$ios_shim")"
  ios_shim_mode="$(decode_matrix_field "$ios_shim_mode")"
  runtime_version="$(decode_matrix_field "$runtime_version")"
  app_build_digest="$(decode_matrix_field "$app_build_digest")"

  safe_name="$(slugify "$device_name")"
  if [[ -z "$safe_name" ]]; then
    safe_name="device"
  fi
  evidence_attempt_root=""
  if [[ -n "$MATRIX_EVIDENCE_INDEX" ]]; then
    safe_matrix_id="$(slugify "$MATRIX_RUN_ID")"
    [[ -n "$safe_matrix_id" ]] || safe_matrix_id=matrix
    execution_id="$safe_matrix_id-$safe_name-logical-$run"
    attempt_number="$(next_evidence_attempt "$execution_id")"
    evidence_run_id="$execution_id-attempt-$attempt_number"
    evidence_attempt_root="$MATRIX_EVIDENCE_PUBLICATION/attempts/$evidence_run_id"
    context_json="$(matrix_context_json \
      "$evidence_run_id" "$execution_id" "$attempt_number" "$safe_name" \
      "$platform" "$ios_device_type" "$serial" "$scenario" \
      "$runtime_version" "$app_build_digest")"
    python3 "$ROOT/scripts/run_evidence.py" init \
      --root "$evidence_attempt_root" \
      --index "$MATRIX_EVIDENCE_INDEX" \
      --context-json "$context_json" >/dev/null
    trace_dir="$evidence_attempt_root/traces/$safe_name-run-$run"
  else
    trace_dir="$TRACE_ROOT/$safe_name-run-$run"
    mkdir -p "$trace_dir"
  fi

  zmr_args=(run "$scenario" --platform "$platform" --device "$serial" --trace-dir "$trace_dir")
  if [[ -n "$ios_device_type" ]]; then
    zmr_args+=(--ios-device-type "$ios_device_type")
  fi
  if [[ -n "$app_id" ]]; then
    zmr_args+=(--app-id "$app_id")
  fi
  if [[ -n "$adb" ]]; then
    zmr_args+=(--adb "$adb")
  fi
  if [[ -n "$android_shim" ]]; then
    zmr_args+=(--android-shim "$android_shim")
  fi
  if [[ -n "$xcrun" ]]; then
    zmr_args+=(--xcrun "$xcrun")
  fi
  if [[ -n "$ios_shim" ]]; then
    zmr_args+=(--ios-shim "$ios_shim")
  fi

  command_status=0
  start_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  if [[ -n "$evidence_attempt_root" ]]; then
    outcome_mode=none
    [[ "$platform" != ios ]] || outcome_mode="$ios_shim_mode"
    run_evidence_matrix_row "$evidence_attempt_root" "$outcome_mode" \
      "$ZMR_BIN" "${zmr_args[@]}" || command_status=$?
  else
    "$ZMR_BIN" "${zmr_args[@]}" || command_status=$?
  fi
  end_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  duration_ms=$((end_ms - start_ms))

  row="$("$ROOT/scripts/benchmark_result_row.py" \
    --tool zmr \
    --run "$run" \
    --command-status "$command_status" \
    --duration-ms "$duration_ms" \
    --trace-dir "$trace_dir")"
  python3 - "$row" "$device_name" "$platform" "$serial" "$scenario" <<'PY' >> "$RESULTS"
import json
import sys

row = json.loads(sys.argv[1])
row["deviceName"] = sys.argv[2]
row["platform"] = sys.argv[3]
row["serial"] = sys.argv[4]
row["scenario"] = sys.argv[5]
print(json.dumps(row, separators=(",", ":")))
PY
done < "$ROWS"

python3 - "$RESULTS" "$SUMMARY" <<'PY'
import json
import statistics
import sys

results_path = sys.argv[1]
summary_path = sys.argv[2]
rows = []
with open(results_path, "r", encoding="utf-8") as fh:
    rows = [json.loads(line) for line in fh if line.strip()]

total = len(rows)
failed = sum(1 for row in rows if row.get("status") != "ok" or row.get("traceStatus") == "failed")
passed = total - failed
durations = [int(row.get("durationMs", 0)) for row in rows]
pass_rate = (passed / total * 100.0) if total else 0.0
summary = {
    "totalRuns": total,
    "passed": passed,
    "failed": failed,
    "passRate": round(pass_rate, 2),
    "meanMs": round(statistics.mean(durations), 2) if durations else 0,
    "resultsPath": "matrix.jsonl",
}
with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, separators=(",", ":"))
    fh.write("\n")
print(f"matrix: runs={total} passRate={pass_rate:.2f}% failures={failed}")
PY

gate_failed=0
python3 - "$SUMMARY" "$MIN_PASS_RATE" "$MAX_FAILURES" <<'PY' || gate_failed=$?
import json
import sys

summary_path, min_pass_rate, max_failures = sys.argv[1:4]
with open(summary_path, "r", encoding="utf-8") as fh:
    summary = json.load(fh)

failed = False
if min_pass_rate and summary["passRate"] < float(min_pass_rate):
    print(f"matrix gate failed: passRate={summary['passRate']:.2f}% < {float(min_pass_rate):.2f}%")
    failed = True
if max_failures and summary["failed"] > int(max_failures):
    print(f"matrix gate failed: failures={summary['failed']} > {int(max_failures)}")
    failed = True
raise SystemExit(1 if failed else 0)
PY

if [[ "$gate_failed" -ne 0 ]]; then
  exit "$gate_failed"
fi
