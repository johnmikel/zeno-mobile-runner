#!/usr/bin/env bash
# Repeat one scenario N times against a booted iOS simulator and report whether
# the runner walked an identical path every time.
#
# This answers a narrower question than scripts/benchmark.sh: not "how fast is
# it" but "does it give the same answer twice". The signal that matters is the
# per-run event count. A constant event count across every run means the runner
# took the identical path through the scenario; a varying one means it did not,
# even when every run reports passed.
#
# The app is relaunched between runs. Without that, a scenario containing
# typeText accumulates text in React component state and later runs drift for
# reasons that have nothing to do with the runner.
#
# Usage:
#   scripts/determinism-bench.sh --scenario <scenario.json> [options]
#
#   --scenario <path>    Scenario to repeat. Required.
#   --app-dir <path>     Run zmr with this directory as the working directory,
#                        so a relative iosShimPath in its .zmr/config.json
#                        resolves. Without this an iOS run has no shim, cannot
#                        read the UI tree, and every wait times out.
#   --runs <n>           Run count. Default 20.
#   --device <udid>      Simulator UDID. Default: the booted simulator.
#   --app-id <id>        Bundle id to relaunch between runs. Default: the
#                        scenario's appId.
#   --scheme <scheme>    URL scheme used to re-point an Expo dev client at
#                        Metro. Default: no re-point (plain relaunch).
#   --metro-port <port>  Metro port for the dev-client re-point. Default 8081.
#   --start-metro        Start Metro in --app-dir for the duration of the run and
#                        stop it afterwards. Without this, Metro must already be
#                        running: it has to outlive every run, and a bundler that
#                        dies midway turns the remaining runs into noise.
#   --settle-seconds <n> Seconds to wait after relaunch. Default 20.
#   --warmup-seconds <n> Seconds to wait for the first bundle build. Default 90.
#   --results <path>     JSONL output path. Default traces/determinism/results.jsonl
#   --zmr <path>         zmr binary. Default ./zig-out/bin/zmr.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCENARIO=""
APP_DIR=""
RUNS=20
DEVICE=""
APP_ID=""
SCHEME=""
METRO_PORT=8081
START_METRO=0
SETTLE_SECONDS=20
WARMUP_SECONDS=90
RESULTS=""
ZMR_BIN="$ROOT/zig-out/bin/zmr"

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="${2:-}"; shift 2 ;;
    --app-dir) APP_DIR="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --app-id) APP_ID="${2:-}"; shift 2 ;;
    --scheme) SCHEME="${2:-}"; shift 2 ;;
    --metro-port) METRO_PORT="${2:-}"; shift 2 ;;
    --start-metro) START_METRO=1; shift ;;
    --settle-seconds) SETTLE_SECONDS="${2:-}"; shift 2 ;;
    --warmup-seconds) WARMUP_SECONDS="${2:-}"; shift 2 ;;
    --results) RESULTS="${2:-}"; shift 2 ;;
    --zmr) ZMR_BIN="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[[ -n "$SCENARIO" ]] || die "--scenario is required"
[[ -f "$SCENARIO" ]] || die "scenario not found: $SCENARIO"
[[ -x "$ZMR_BIN" ]] || die "zmr binary is not executable: $ZMR_BIN"
# zmr may run from --app-dir, so every path handed to it must be absolute.
SCENARIO="$(cd "$(dirname "$SCENARIO")" && pwd)/$(basename "$SCENARIO")"
ZMR_BIN="$(cd "$(dirname "$ZMR_BIN")" && pwd)/$(basename "$ZMR_BIN")"
if [[ -n "$APP_DIR" ]]; then
  [[ -d "$APP_DIR" ]] || die "--app-dir not found: $APP_DIR"
  APP_DIR="$(cd "$APP_DIR" && pwd)"
fi
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer"

# A benchmark that silently measures a stale binary certifies the wrong
# artifact. Refuse to run unless the binary matches the tree it lives in.
declared_version="$(sed -n 's/.*runner_version = "\([^"]*\)".*/\1/p' "$ROOT/src/version.zig")"
binary_version="$("$ZMR_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
[[ -n "$declared_version" ]] || die "could not read runner_version from src/version.zig"
if [[ "$declared_version" != "$binary_version" ]]; then
  die "binary is $binary_version but src/version.zig declares $declared_version — rebuild with npm run build:zmr"
fi

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)"
  [[ -n "$DEVICE" ]] || die "no booted simulator found; pass --device <udid>"
fi

if [[ -z "$APP_ID" ]]; then
  APP_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("appId",""))' "$SCENARIO")"
  [[ -n "$APP_ID" ]] || die "scenario has no appId; pass --app-id"
fi

RESULTS="${RESULTS:-$ROOT/traces/determinism/results.jsonl}"
mkdir -p "$(dirname "$RESULTS")"
RESULTS="$(cd "$(dirname "$RESULTS")" && pwd)/$(basename "$RESULTS")"
: > "$RESULTS"

# Guard against a previous run of this script still driving the same simulator.
# A concurrent run races over the app and shim and produces a fake pass rate.
# Use a pidfile with a liveness check, not pgrep: pgrep -f also matches the
# caffeinate wrapper around this script and would block its own run.
PIDFILE="${TMPDIR:-/tmp}/zmr-determinism-bench.pid"
if [[ -f "$PIDFILE" ]]; then
  old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "another determinism run is live (pid $old_pid); wait for it or kill it"
  fi
fi
echo "$$" > "$PIDFILE"
METRO_PID=""
cleanup() {
  if [[ -n "$METRO_PID" ]]; then
    kill "$METRO_PID" 2>/dev/null || true
    # `expo start` spawns children that keep the port bound after the parent
    # dies, which makes the next run fail on "port already in use".
    sleep 1
    lsof -ti:"$METRO_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}
trap cleanup EXIT

# A dead Metro is the single most misleading failure here: the dev client boots
# to its launcher instead of the app, every wait times out, and the run counts
# vary — which reads as "the runner is flaky" when the bundler was simply down.
# Refuse to produce numbers in that state.
require_metro() {
  [[ -n "$SCHEME" ]] || return 0
  curl -s -m 3 "http://127.0.0.1:${METRO_PORT}/status" 2>/dev/null \
    | grep -q 'packager-status:running' && return 0
  return 1
}

if [[ "$START_METRO" == "1" ]]; then
  [[ -n "$APP_DIR" ]] || die "--start-metro requires --app-dir"
  if lsof -nP -iTCP:"$METRO_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "port $METRO_PORT is already in use; stop the other bundler or drop --start-metro"
  fi
  metro_log="$(dirname "$RESULTS")/metro.log"
  # --dev-client matters: plain `expo start` expects a TTY and exits immediately
  # when detached, which leaves every run failing against a dead bundler.
  ( cd "$APP_DIR" && nohup npx expo start --dev-client --port "$METRO_PORT" \
      > "$metro_log" 2>&1 & echo $! > "$PIDFILE.metro" )
  METRO_PID="$(cat "$PIDFILE.metro" 2>/dev/null || true)"
  rm -f "$PIDFILE.metro"
  echo "starting Metro (pid $METRO_PID, log $metro_log)"
  for _ in $(seq 1 45); do
    require_metro && break
    sleep 2
  done
  require_metro || die "Metro did not become ready; see $metro_log"
elif [[ -n "$SCHEME" ]] && ! require_metro; then
  die "no Metro bundler answering on port $METRO_PORT — pass --start-metro, start it yourself with 'npx expo start --dev-client --port $METRO_PORT' in the app dir, or drop --scheme for a non-dev-client build"
fi

boot_app() {
  xcrun simctl terminate "$DEVICE" "$APP_ID" >/dev/null 2>&1 || true
  # The Expo dev-menu onboarding sheet covers the app on a fresh dev build and
  # breaks selector waits. Mark it finished before launching.
  xcrun simctl spawn "$DEVICE" defaults write "$APP_ID" \
    EXDevMenuIsOnboardingFinished -bool true >/dev/null 2>&1 || true
  xcrun simctl launch "$DEVICE" "$APP_ID" >/dev/null 2>&1 || true
  if [[ -n "$SCHEME" ]]; then
    # An Expo dev client boots to its launcher, not the app, so it has to be
    # re-pointed at Metro. The wait before openurl is load-bearing: sent too
    # early the launcher is not up yet, drops the deep link, and the app sits on
    # "DEVELOPMENT SERVERS" while every selector wait times out.
    sleep 6
    local encoded="http%3A%2F%2F127.0.0.1%3A${METRO_PORT}"
    xcrun simctl openurl "$DEVICE" \
      "${SCHEME}://expo-development-client/?url=${encoded}" >/dev/null 2>&1 || true
  fi
  sleep "${1:-$SETTLE_SECONDS}"
}

echo "determinism bench: $RUNS runs of $(basename "$SCENARIO")"
echo "  zmr      $binary_version ($ZMR_BIN)"
echo "  device   $DEVICE"
echo "  app      $APP_ID"
echo "  cwd      ${APP_DIR:-$PWD}"
echo "  results  $RESULTS"
echo

TRACE_ROOT="$(dirname "$RESULTS")/traces"
mkdir -p "$TRACE_ROOT"

run_zmr() {
  (
    [[ -n "$APP_DIR" ]] && cd "$APP_DIR"
    "$ZMR_BIN" run "$SCENARIO" \
      --device "$DEVICE" \
      --platform ios \
      --ios-device-type simulator \
      --trace-dir "$1" >/dev/null 2>&1
  )
}

# Warm-up boot plus one unmeasured run, not recorded. Two jobs: the dev client
# has to fetch and build the JS bundle the first time it is pointed at Metro,
# and if the environment is broken it is far better to say so once than to emit
# twenty rows of noise that read like a flaky runner.
if [[ -n "$SCHEME" ]]; then
  echo "warm-up boot (first bundle, up to ${WARMUP_SECONDS}s)"
  boot_app "$WARMUP_SECONDS"
  echo "warm-up run (not recorded)"
  if ! run_zmr "$TRACE_ROOT/warmup"; then
    "$ZMR_BIN" explain "$TRACE_ROOT/warmup" 2>&1 | sed 's/^/  /' || true
    die "the warm-up run failed, so the environment is not ready — fix that before trusting any numbers. Common causes: the app is parked on the Expo dev launcher because the re-point did not land, Metro is serving a different project, or the app crashed at launch (check ~/Library/Logs/DiagnosticReports)."
  fi
fi

for run in $(seq 1 "$RUNS"); do
  if ! require_metro; then
    die "Metro stopped answering before run $run — results so far are in $RESULTS, discard them"
  fi
  boot_app

  trace_dir="$TRACE_ROOT/run-$run"
  rm -rf "$trace_dir"

  start_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  command_status=0
  run_zmr "$trace_dir" || command_status=$?
  end_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"

  python3 - "$trace_dir" "$run" "$command_status" "$((end_ms - start_ms))" \
    "$DEVICE" "$SCENARIO" "$binary_version" >> "$RESULTS" <<'PY'
import json, pathlib, sys

trace_dir, run, status, duration_ms, device, scenario, version = sys.argv[1:8]
events_path = pathlib.Path(trace_dir) / "events.jsonl"

event_count = 0
trace_status = None
first_error = None
if events_path.exists():
    with events_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            event_count += 1
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("kind") == "scenario.end":
                payload = event.get("payload") or {}
                trace_status = payload.get("status", trace_status)
            elif event.get("kind") == "step.error" and first_error is None:
                payload = event.get("payload") or {}
                first_error = {
                    "stepIndex": payload.get("stepIndex"),
                    "error": payload.get("error"),
                }

print(json.dumps({
    "tool": "zmr",
    "run": int(run),
    "status": "ok" if int(status) == 0 else "failed",
    "traceStatus": trace_status,
    "durationMs": int(duration_ms),
    "eventCount": event_count,
    "firstError": first_error,
    "device": device,
    "scenario": scenario,
    "zmr": version,
    "platform": "ios",
    "traceDir": trace_dir,
}, separators=(",", ":")))
PY

  python3 - "$RESULTS" "$RUNS" <<'PY'
import json, sys

row = json.loads(open(sys.argv[1], encoding="utf-8").read().strip().splitlines()[-1])
print(f"run {row['run']:>2}/{sys.argv[2]}  {row['status']:>6}  "
      f"{row['durationMs'] / 1000:6.1f}s  events={row['eventCount']}", flush=True)
PY
done

echo
python3 - "$RESULTS" <<'PY'
import json, statistics, sys
from collections import Counter

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
if not rows:
    print("no results")
    raise SystemExit(1)

durations = sorted(row["durationMs"] for row in rows)
passed = [row for row in rows if row["status"] == "ok"]
counts = Counter(row["eventCount"] for row in rows)


def percentile(values, fraction):
    # Nearest-rank percentile, so the reported value is always an observed one.
    index = max(0, min(len(values) - 1, round(fraction * len(values)) - 1))
    return values[index]


print(f"runs            {len(rows)}")
print(f"passed          {len(passed)}/{len(rows)}  ({100.0 * len(passed) / len(rows):.1f}%)")
print(f"min             {durations[0] / 1000:.1f}s")
print(f"median          {statistics.median(durations) / 1000:.1f}s")
print(f"p95             {percentile(durations, 0.95) / 1000:.1f}s")
print(f"max             {durations[-1] / 1000:.1f}s")
print(f"spread          {(durations[-1] - durations[0]) / 1000:.1f}s"
      f"  ({100.0 * (durations[-1] - durations[0]) / durations[0]:.1f}%)")
if len(durations) > 1:
    print(f"stdev           {statistics.stdev(durations) / 1000:.1f}s")
print(f"event counts    {dict(counts)}")
if len(counts) == 1:
    print("verdict         identical path on every run")
else:
    print("verdict         PATH VARIED across runs — not deterministic")
for row in rows:
    if row["status"] != "ok":
        print(f"  run {row['run']} failed: {json.dumps(row['firstError'])}")
PY
