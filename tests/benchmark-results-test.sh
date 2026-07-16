#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--zmr" "--device" "--runs" "--trace-root" "--results" "--platform" "--app-id" "--adb" "--android-shim" "--xcrun" "--ios-shim" "--ios-shim-mode" "--ios-device-type" "--app-build" "--min-pass-rate" "--max-failures" "--max-mean-ms" "--max-p95-ms"; do
  set +e
  missing_value_output="$("$ROOT/scripts/benchmark.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "benchmark.sh should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

for args in "--tool" "--runs" "--trace-root" "--results" "--cwd" "--platform" "--device" "--app-id" "--scenario" "--app-build" "--min-pass-rate" "--max-failures" "--max-mean-ms" "--max-p95-ms"; do
  set +e
  missing_value_output="$("$ROOT/scripts/benchmark-command.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "benchmark-command.sh should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

"$ROOT/scripts/compare-benchmarks.py" --help > "$TMPDIR/compare-help.out"
grep -q -- '--evidence-out requires --min-candidate-pass-rate' "$TMPDIR/compare-help.out"
grep -q -- '--max-candidate-failures, --min-mean-speedup, and --min-p95-speedup' "$TMPDIR/compare-help.out"

TRACE_DIR="$TMPDIR/zmr-1"
mkdir -p "$TRACE_DIR"

cat > "$TRACE_DIR/events.jsonl" <<'JSONL'
{"seq":1,"kind":"step.error","payload":{"index":12,"error":"WaitTimeout"}}
{"seq":2,"kind":"scenario.end","payload":{"value":"flow","status":"failed","failedStepIndex":12,"error":"WaitTimeout"}}
JSONL

row="$("$ROOT/scripts/benchmark_result_row.py" \
  --tool zmr \
  --run 1 \
  --command-status 1 \
  --duration-ms 1234 \
  --trace-dir "$TRACE_DIR" \
  --platform android \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --scenario .zmr/android-smoke.json \
  --app-build debug-20260518)"

python3 - "$row" "$TRACE_DIR" <<'PY'
import json
import sys

row = json.loads(sys.argv[1])
trace_dir = sys.argv[2]

assert row["tool"] == "zmr"
assert row["run"] == 1
assert row["status"] == "failed"
assert row["durationMs"] == 1234
assert row["traceDir"] == trace_dir
assert row["traceStatus"] == "failed"
assert row["traceError"] == "WaitTimeout"
assert row["failedStepIndex"] == 12
assert row["platform"] == "android"
assert row["device"] == "emulator-5554"
assert row["appId"] == "com.example.mobiletest"
assert row["scenario"] == ".zmr/android-smoke.json"
assert row["appBuild"] == "debug-20260518"
PY

cat > "$TMPDIR/results.jsonl" <<'JSONL'
{"tool":"zmr","run":1,"status":"ok","durationMs":1000,"traceStatus":"passed","traceDir":"run-1"}
{"tool":"zmr","run":2,"status":"failed","durationMs":1200,"traceStatus":"failed","traceError":"WaitTimeout","traceDir":"run-2"}
{"tool":"zmr","run":3,"status":"ok","durationMs":900,"traceStatus":"passed","traceDir":"run-3"}
JSONL

if "$ROOT/scripts/benchmark_gate.py" --results "$TMPDIR/results.jsonl" --min-pass-rate 100 --max-failures 0 > "$TMPDIR/pass-rate.out" 2>&1; then
  echo "benchmark gate should fail when pass rate is below the configured minimum" >&2
  exit 1
fi
grep -q 'passRate' "$TMPDIR/pass-rate.out"
grep -q 'failures=1' "$TMPDIR/pass-rate.out"

cat > "$TMPDIR/slow-results.jsonl" <<'JSONL'
{"tool":"zmr","run":1,"status":"ok","durationMs":1000,"traceStatus":"passed","traceDir":"run-1"}
{"tool":"zmr","run":2,"status":"ok","durationMs":5000,"traceStatus":"passed","traceDir":"run-2"}
{"tool":"zmr","run":3,"status":"ok","durationMs":900,"traceStatus":"passed","traceDir":"run-3"}
JSONL

if "$ROOT/scripts/benchmark_gate.py" --results "$TMPDIR/slow-results.jsonl" --min-pass-rate 100 --max-failures 0 --max-p95-ms 1000 > "$TMPDIR/p95.out" 2>&1; then
  echo "benchmark gate should fail when p95 exceeds the configured maximum" >&2
  exit 1
fi
grep -q 'p95Ms' "$TMPDIR/p95.out"

cat > "$TMPDIR/passing-results.jsonl" <<'JSONL'
{"tool":"zmr","run":1,"status":"ok","durationMs":1000,"traceStatus":"passed","traceDir":"run-1"}
{"tool":"zmr","run":2,"status":"ok","durationMs":1200,"traceStatus":"passed","traceDir":"run-2"}
JSONL

"$ROOT/scripts/benchmark_gate.py" --results "$TMPDIR/passing-results.jsonl" --min-pass-rate 100 --max-failures 0 --max-p95-ms 2000 > "$TMPDIR/passing.out"
grep -q 'zmr: runs=2 passRate=100.00% failures=0' "$TMPDIR/passing.out"

cat > "$TMPDIR/fake-zmr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
trace_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
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
case "$trace_dir" in
  *zmr-2)
    printf '%s\n' '{"seq":1,"kind":"scenario.end","payload":{"status":"failed","error":"WaitTimeout"}}' > "$trace_dir/events.jsonl"
    exit 1
    ;;
  *)
    printf '%s\n' '{"seq":1,"kind":"scenario.end","payload":{"status":"passed"}}' > "$trace_dir/events.jsonl"
    ;;
esac
SH
chmod +x "$TMPDIR/fake-zmr"
touch "$TMPDIR/scenario.json"

APP_BENCH_DIR="$TMPDIR/app-benchmark-defaults"
mkdir -p "$APP_BENCH_DIR"
APP_BENCH_DIR="$(cd "$APP_BENCH_DIR" && pwd -P)"
touch "$APP_BENCH_DIR/scenario.json"
pushd "$APP_BENCH_DIR" >/dev/null
ZMR_BIN="$TMPDIR/fake-zmr" "$ROOT/scripts/benchmark.sh" --zmr scenario.json --device fake-device --runs 1 > "$TMPDIR/bench-default.out"
popd >/dev/null
grep -q "results=$APP_BENCH_DIR/traces/bench-" "$TMPDIR/bench-default.out"
if grep -q "results=$ROOT/traces/bench-" "$TMPDIR/bench-default.out"; then
  echo "benchmark.sh should default trace output to the caller app directory, not the package root" >&2
  exit 1
fi

APP_COMMAND_DIR="$TMPDIR/app-command-defaults"
mkdir -p "$APP_COMMAND_DIR"
APP_COMMAND_DIR="$(cd "$APP_COMMAND_DIR" && pwd -P)"
pushd "$APP_COMMAND_DIR" >/dev/null
"$ROOT/scripts/benchmark-command.sh" --tool baseline --runs 1 -- /usr/bin/true > "$TMPDIR/bench-command-default.out"
popd >/dev/null
grep -q "Benchmark command output: $APP_COMMAND_DIR/traces/bench-command-" "$TMPDIR/bench-command-default.out"
if grep -q "Benchmark command output: $ROOT/traces/bench-command-" "$TMPDIR/bench-command-default.out"; then
  echo "benchmark-command.sh should default trace output to the caller app directory, not the package root" >&2
  exit 1
fi

if ZMR_BIN="$TMPDIR/fake-zmr" "$ROOT/scripts/benchmark.sh" --zmr "$TMPDIR/scenario.json" --device fake-device --runs 2 --trace-root "$TMPDIR/bench-fail" --min-pass-rate 100 --max-failures 0 > "$TMPDIR/bench-fail.out" 2>&1; then
  echo "benchmark.sh should fail when benchmark_gate.py rejects results" >&2
  exit 1
fi
grep -q 'passRate=50.00%' "$TMPDIR/bench-fail.out"
grep -q 'failures=1' "$TMPDIR/bench-fail.out"

ZMR_BIN="$TMPDIR/fake-zmr" "$ROOT/scripts/benchmark.sh" --zmr "$TMPDIR/scenario.json" --device fake-device --runs 2 --trace-root "$TMPDIR/bench-pass" --min-pass-rate 50 --max-failures 1 > "$TMPDIR/bench-pass.out"
grep -q 'passRate=50.00%' "$TMPDIR/bench-pass.out"

python3 - "$TMPDIR/compare-results.jsonl" <<'PY'
import json
import sys

context = {
    "platform": "android",
    "device": "emulator-5554",
    "appId": "com.example.mobiletest",
    "scenario": ".zmr/login.json",
    "appBuild": "debug-20260518",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for run in range(1, 21):
        handle.write(json.dumps({
            "tool": "zmr",
            "run": run,
            "status": "ok",
            "durationMs": 800 if run % 2 else 1000,
            "traceStatus": "passed",
            "traceDir": f"zmr-{run}",
            **context,
        }, separators=(",", ":")) + "\n")
    for run in range(1, 21):
        failed = run == 20
        handle.write(json.dumps({
            "tool": "baseline",
            "run": run,
            "status": "failed" if failed else "ok",
            "durationMs": 2000 if failed else 1600,
            "traceStatus": "failed" if failed else "passed",
            "traceDir": f"baseline-{run}",
            **context,
        }, separators=(",", ":")) + "\n")
PY

"$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/compare-results.jsonl" \
  --candidate zmr \
  --baseline baseline \
  --format json > "$TMPDIR/compare.json"
python3 - "$TMPDIR/compare.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["candidate"]["tool"] == "zmr"
assert data["candidate"]["passRate"] == 100.0
assert data["candidate"]["runs"] == 20
assert data["baseline"]["runs"] == 20
assert data["baseline"]["failures"] == 1
assert data["meanSpeedup"] > 1.7
assert data["meanDeltaPct"] < 0
PY

"$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/compare-results.jsonl" \
  --candidate zmr \
  --baseline baseline \
  --format markdown \
  --out "$TMPDIR/compare.md"
grep -q '# Benchmark Comparison' "$TMPDIR/compare.md"
grep -q 'Mean speedup' "$TMPDIR/compare.md"
grep -q 'candidate vs baseline' "$TMPDIR/compare.md"

if "$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/compare-results.jsonl" \
  --candidate zmr \
  --baseline baseline \
  --evidence-out "$TMPDIR/weak-market-evidence.jsonl" > "$TMPDIR/weak-market-evidence.out" 2>&1; then
  echo "compare-benchmarks.py should require market gates when writing evidence" >&2
  exit 1
fi
grep -q -- '--min-candidate-pass-rate is required with --evidence-out' "$TMPDIR/weak-market-evidence.out"
grep -q -- '--max-candidate-failures is required with --evidence-out' "$TMPDIR/weak-market-evidence.out"
grep -q -- '--min-mean-speedup is required with --evidence-out' "$TMPDIR/weak-market-evidence.out"
grep -q -- '--min-p95-speedup is required with --evidence-out' "$TMPDIR/weak-market-evidence.out"

"$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/compare-results.jsonl" \
  --candidate zmr \
  --baseline baseline \
  --min-candidate-pass-rate 100 \
  --max-candidate-failures 0 \
  --min-mean-speedup 1.5 \
  --min-p95-speedup 1.5 \
  --format json \
  --evidence-out "$TMPDIR/market-evidence.jsonl" > "$TMPDIR/compare-gate-pass.json"

python3 - "$TMPDIR/market-evidence.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 1
row = rows[0]
assert row["name"] == "competitive benchmark comparison"
assert row["status"] == "passed"
assert row["candidate"] == "zmr"
assert row["baseline"] == "baseline"
assert row["minCandidatePassRate"] == 100
assert row["maxCandidateFailures"] == 0
assert row["minMeanSpeedup"] == 1.5
assert row["minP95Speedup"] == 1.5
assert row["candidateRuns"] == 20
assert row["baselineRuns"] == 20
assert row["meanSpeedup"] > 1.7
assert row["p95Speedup"] > 1.5
assert row["sameContext"] is True
assert row["context"] == {
    "platform": "android",
    "device": "emulator-5554",
    "appId": "com.example.mobiletest",
    "scenario": ".zmr/login.json",
    "appBuild": "debug-20260518",
}
assert "compare-benchmarks.py" in row["command"]
PY

cat > "$TMPDIR/mismatched-context-results.jsonl" <<'JSONL'
{"tool":"zmr","run":1,"status":"ok","durationMs":800,"traceStatus":"passed","traceDir":"zmr-1","platform":"android","device":"emulator-5554","appId":"com.example.mobiletest","scenario":".zmr/login.json","appBuild":"debug-20260518"}
{"tool":"baseline","run":1,"status":"ok","durationMs":1600,"traceStatus":"passed","traceDir":"baseline-1","platform":"android","device":"emulator-5556","appId":"com.example.mobiletest","scenario":".zmr/login.json","appBuild":"debug-20260518"}
JSONL

if "$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/mismatched-context-results.jsonl" \
  --candidate zmr \
  --baseline baseline \
  --min-candidate-pass-rate 100 \
  --max-candidate-failures 0 \
  --min-mean-speedup 1.25 \
  --min-p95-speedup 1.25 \
  --evidence-out "$TMPDIR/mismatched-market-evidence.jsonl" > "$TMPDIR/mismatched-compare.out" 2>&1; then
  echo "compare-benchmarks.py should fail market evidence when benchmark context does not match" >&2
  exit 1
fi
grep -q 'same benchmark context' "$TMPDIR/mismatched-compare.out"

cat > "$TMPDIR/low-sample-results.jsonl" <<'JSONL'
{"tool":"zmr","run":1,"status":"ok","durationMs":800,"traceStatus":"passed","traceDir":"zmr-1","platform":"android","device":"emulator-5554","appId":"com.example.mobiletest","scenario":".zmr/login.json","appBuild":"debug-20260518"}
{"tool":"baseline","run":1,"status":"ok","durationMs":1600,"traceStatus":"passed","traceDir":"baseline-1","platform":"android","device":"emulator-5554","appId":"com.example.mobiletest","scenario":".zmr/login.json","appBuild":"debug-20260518"}
JSONL

if "$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/low-sample-results.jsonl" \
  --candidate zmr \
  --baseline baseline \
  --min-candidate-pass-rate 100 \
  --max-candidate-failures 0 \
  --min-mean-speedup 1.25 \
  --min-p95-speedup 1.25 \
  --evidence-out "$TMPDIR/low-sample-market-evidence.jsonl" > "$TMPDIR/low-sample-compare.out" 2>&1; then
  echo "compare-benchmarks.py should fail market evidence when sample counts are too low" >&2
  exit 1
fi
grep -q 'candidateRuns 1 below minimum 20' "$TMPDIR/low-sample-compare.out"
grep -q 'baselineRuns 1 below minimum 20' "$TMPDIR/low-sample-compare.out"

if "$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/compare-results.jsonl" \
  --candidate zmr \
  --baseline baseline \
  --min-mean-speedup 3.0 > "$TMPDIR/compare-mean-gate.out" 2>&1; then
  echo "compare-benchmarks.py should fail when mean speedup is below the configured minimum" >&2
  exit 1
fi
grep -q 'meanSpeedup' "$TMPDIR/compare-mean-gate.out"
grep -q 'below minimum 3.00x' "$TMPDIR/compare-mean-gate.out"

if "$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/compare-results.jsonl" \
  --candidate baseline \
  --baseline zmr \
  --min-candidate-pass-rate 100 > "$TMPDIR/compare-pass-rate-gate.out" 2>&1; then
  echo "compare-benchmarks.py should fail when candidate pass rate is below the configured minimum" >&2
  exit 1
fi
grep -q 'candidate passRate' "$TMPDIR/compare-pass-rate-gate.out"
grep -q 'below minimum 100.00%' "$TMPDIR/compare-pass-rate-gate.out"

if "$ROOT/scripts/compare-benchmarks.py" --results "$TMPDIR/compare-results.jsonl" --baseline missing > "$TMPDIR/compare-missing.out" 2>&1; then
  echo "compare-benchmarks.py should fail when a requested baseline is missing" >&2
  exit 1
fi
grep -q 'missing benchmark rows for: missing' "$TMPDIR/compare-missing.out"

cat > "$TMPDIR/fake-zmr-ios" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
for required in \
  " --platform ios " \
  " --ios-device-type physical " \
  " --app-id com.example.mobiletest " \
  " --xcrun ./tests/fake-xcrun.sh " \
  " --ios-shim ./tests/fake-ios-shim.sh "
do
  if [[ "$args" != *"$required"* ]]; then
    echo "missing forwarded argument: $required" >&2
    exit 64
  fi
done
trace_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
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
printf '%s\n' '{"seq":1,"kind":"scenario.end","payload":{"status":"passed"}}' > "$trace_dir/events.jsonl"
SH
chmod +x "$TMPDIR/fake-zmr-ios"

ZMR_BIN="$TMPDIR/fake-zmr-ios" "$ROOT/scripts/benchmark.sh" \
  --zmr "$TMPDIR/scenario.json" \
  --device fake-ios-1 \
  --runs 1 \
  --trace-root "$TMPDIR/bench-ios" \
  --platform ios \
  --ios-device-type physical \
  --app-id com.example.mobiletest \
  --xcrun ./tests/fake-xcrun.sh \
  --ios-shim ./tests/fake-ios-shim.sh \
  --min-pass-rate 100 \
  --max-failures 0 > "$TMPDIR/bench-ios.out"
grep -q 'passRate=100.00%' "$TMPDIR/bench-ios.out"

mkdir -p "$TMPDIR/path-bin"
cat > "$TMPDIR/path-bin/zmr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
trace_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
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
printf '%s\n' '{"seq":1,"kind":"scenario.end","payload":{"status":"passed"}}' > "$trace_dir/events.jsonl"
SH
chmod +x "$TMPDIR/path-bin/zmr"

PATH="$TMPDIR/path-bin:$PATH" "$ROOT/scripts/benchmark.sh" \
  --zmr "$TMPDIR/scenario.json" \
  --device fake-device \
  --runs 1 \
  --trace-root "$TMPDIR/bench-path-bin" \
  --min-pass-rate 100 \
  --max-failures 0 > "$TMPDIR/bench-path-bin.out"
grep -q 'passRate=100.00%' "$TMPDIR/bench-path-bin.out"

cat > "$TMPDIR/shared-results.jsonl" <<'JSONL'
{"tool":"existing","run":1,"status":"ok","durationMs":1,"traceDir":"existing-1"}
JSONL

PATH="$TMPDIR/path-bin:$PATH" "$ROOT/scripts/benchmark.sh" \
  --zmr "$TMPDIR/scenario.json" \
  --device fake-device \
  --runs 1 \
  --trace-root "$TMPDIR/bench-shared-zmr" \
  --results "$TMPDIR/shared-results.jsonl" \
  --min-pass-rate 100 \
  --max-failures 0 > "$TMPDIR/bench-shared-zmr.out"

python3 - "$TMPDIR/shared-results.jsonl" "$TMPDIR/bench-shared-zmr" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [row["tool"] for row in rows] == ["existing", "zmr"]
assert rows[1]["traceDir"] == f"{sys.argv[2]}/zmr-1"
PY

PATH="$TMPDIR/path-bin:$PATH" "$ROOT/scripts/benchmark.sh" \
  --zmr "$TMPDIR/scenario.json" \
  --device fake-device \
  --runs 1 \
  --trace-root "$TMPDIR/bench-replace-zmr" \
  --results "$TMPDIR/shared-results.jsonl" \
  --replace \
  --min-pass-rate 100 \
  --max-failures 0 > "$TMPDIR/bench-replace-zmr.out"

python3 - "$TMPDIR/shared-results.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [row["tool"] for row in rows] == ["zmr"]
PY

cat > "$TMPDIR/fake-baseline.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'baseline ok\n'
SH
chmod +x "$TMPDIR/fake-baseline.sh"

"$ROOT/scripts/benchmark-command.sh" \
  --tool runner-a \
  --runs 2 \
  --trace-root "$TMPDIR/runner-a-bench" \
  --results "$TMPDIR/combined-results.jsonl" \
  --replace \
  --platform android \
  --device emulator-5554 \
  --app-id com.example.mobiletest \
  --scenario .baseline/login.yaml \
  --app-build debug-20260518 \
  --min-pass-rate 100 \
  --max-failures 0 \
  -- "$TMPDIR/fake-baseline.sh" > "$TMPDIR/runner-a-bench.out"
grep -q 'runner-a: runs=2 failures=0' "$TMPDIR/runner-a-bench.out"
grep -q 'runner-a: runs=2 passRate=100.00% failures=0' "$TMPDIR/runner-a-bench.out"
test -f "$TMPDIR/runner-a-bench/runner-a-1/stdout.log"
grep -q 'baseline ok' "$TMPDIR/runner-a-bench/runner-a-1/stdout.log"

python3 - "$TMPDIR/combined-results.jsonl" "$TMPDIR/runner-a-bench" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [row["tool"] for row in rows] == ["runner-a", "runner-a"]
assert all(row["status"] == "ok" for row in rows)
assert rows[0]["traceDir"] == f"{sys.argv[2]}/runner-a-1"
assert rows[0]["platform"] == "android"
assert rows[0]["device"] == "emulator-5554"
assert rows[0]["appId"] == "com.example.mobiletest"
assert rows[0]["scenario"] == ".baseline/login.yaml"
assert rows[0]["appBuild"] == "debug-20260518"
PY

cat >> "$TMPDIR/combined-results.jsonl" <<'JSONL'
{"tool":"zmr","run":1,"status":"ok","durationMs":10,"traceStatus":"passed","traceDir":"zmr-1"}
JSONL
"$ROOT/scripts/compare-benchmarks.py" \
  --results "$TMPDIR/combined-results.jsonl" \
  --candidate zmr \
  --baseline runner-a \
  --format markdown > "$TMPDIR/combined-compare.md"
grep -q '| runner-a | 2 | 100.00%' "$TMPDIR/combined-compare.md"

cat > "$TMPDIR/fake-baseline-fail.sh" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$TMPDIR/fake-baseline-fail.sh"
if "$ROOT/scripts/benchmark-command.sh" \
  --tool runner-b \
  --runs 1 \
  --trace-root "$TMPDIR/runner-b-bench" \
  --min-pass-rate 100 \
  --max-failures 0 \
  -- "$TMPDIR/fake-baseline-fail.sh" > "$TMPDIR/runner-b-bench.out" 2>&1; then
  echo "benchmark-command.sh should fail when gate rejects baseline results" >&2
  exit 1
fi
grep -q 'runner-b: runs=1 passRate=0.00% failures=1' "$TMPDIR/runner-b-bench.out"

EVIDENCE_PUBLICATION="$TMPDIR/benchmark-evidence"
EVIDENCE_ATTEMPT="$EVIDENCE_PUBLICATION/attempts/benchmark-run"
EVIDENCE_INDEX="$EVIDENCE_PUBLICATION/attempt-index.json"
mkdir -p "$EVIDENCE_PUBLICATION/attempts"
printf '{}\n' > "$TMPDIR/evidence-scenario.json"
python3 "$ROOT/scripts/run_evidence.py" init \
  --root "$EVIDENCE_ATTEMPT" \
  --index "$EVIDENCE_INDEX" \
  --context-json '{"runId":"benchmark-run","executionId":"benchmark-logical","fixtureId":"benchmark-android","fixtureVersion":"1","candidateRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","scenarioDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","appBuildDigest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","platform":"android","deviceClass":"android-emulator","runtimeVersion":"35","timingMode":"cold-command","runnerVersion":"1.0.0","protocolVersion":"2026-04-28","attempt":1,"host":{"os":"macos","arch":"arm64","class":"local-test","ci":false},"device":{"requested":"emulator-5554","resolved":"emulator-5554"},"toolchain":{"xcode":null,"zig":"0.16.0"},"artifacts":{"trace":null,"report":null}}' >/dev/null

ZMR_BIN="$ROOT/tests/fixtures/fake-zmr-evidence-success.sh" \
ZMR_RUN_EVIDENCE_ROOT="$EVIDENCE_ATTEMPT" \
ZMR_RUN_EVIDENCE_INDEX="$EVIDENCE_INDEX" \
  "$ROOT/scripts/benchmark.sh" \
  --zmr "$TMPDIR/evidence-scenario.json" \
  --device emulator-5554 \
  --platform android \
  --runs 2 \
  --trace-root "$EVIDENCE_ATTEMPT/traces/benchmark" \
  --min-pass-rate 100 \
  --max-failures 0 >/dev/null

python3 "$ROOT/scripts/run_evidence.py" validate-bundle --root "$EVIDENCE_ATTEMPT" >/dev/null
python3 - "$EVIDENCE_ATTEMPT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
summary = json.loads((root / "run-summary.json").read_text())
assert summary["status"] == "passed"
assert summary["artifacts"]["trace"] == "traces/benchmark/zmr-2"
assert len(list((root / "run-outcomes").glob("*.json"))) == 2
PY
