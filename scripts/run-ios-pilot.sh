#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_CWD="$(pwd -P)"
cd "$ROOT"

# shellcheck source=run-evidence.sh
source "$ROOT/scripts/run-evidence.sh"

# Some sandboxed environments do not allow writing to the default temp directory
# (/var/folders, /tmp). Use a repo-local TMPDIR so xcrun/mktemp/heredocs work.
if [[ -z "${TMPDIR:-}" || ! -w "${TMPDIR:-/nonexistent}" ]]; then
  TMPDIR="$ROOT/traces/tmp"
  mkdir -p "$TMPDIR"
  export TMPDIR
fi

APP_ROOT="${APP_ROOT:-}"
APP_PATH="${APP_PATH:-}"
DEVICE="${DEVICE:-booted}"
IOS_DEVICE_TYPE="${IOS_DEVICE_TYPE:-simulator}"
TRACE_ROOT="${TRACE_ROOT:-$CALLER_CWD/traces/ios-app-pilot-$(date +%Y%m%d-%H%M%S)}"
ZMR_BIN="${ZMR_BIN:-$(command -v zmr 2>/dev/null || printf '%s' "$ROOT/zig-out/bin/zmr")}"
XCRUN="${XCRUN:-xcrun}"
APP_ID="${APP_ID:-com.example.mobiletest}"
IOS_SHIM="${IOS_SHIM:-}"
IOS_SHIM_MODE="${IOS_SHIM_MODE:-}"
PREWARM_IOS_SHIM="${PREWARM_IOS_SHIM:-1}"
RUNS="${RUNS:-1}"
MIN_PASS_RATE="${MIN_PASS_RATE:-100}"
MAX_FAILURES="${MAX_FAILURES:-0}"
MAX_MEAN_MS="${MAX_MEAN_MS:-}"
MAX_P95_MS="${MAX_P95_MS:-}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/run-ios-pilot.sh --app-path <Sample.app|Sample.ipa> [options]

Runs a configurable iOS smoke pilot:
  1. build/validate zmr
  2. install a simulator .app or signed physical-device .app/.ipa
  3. launch/open a deep link through examples/ios-smoke.json
  4. capture screenshot/log snapshot artifacts
  5. generate report and normal/redacted .zmrtrace bundles

Options:
  --app-root <dir>     Optional app repo root, used only for output context.
  --app-path <path>    Built simulator .app, or signed physical-device .app/.ipa. Required.
  --device <id>        Simulator UDID/booted or physical device identifier. Default: booted.
  --ios-device-type <simulator|physical>
                       Target type. Default: simulator.
  --app-id <bundle>    Bundle id. Default: com.example.mobiletest.
  --trace-root <dir>   Output directory. Default: traces/ios-app-pilot-<timestamp>.
  --zmr-bin <path>     zmr binary. Default: ZMR_BIN, PATH zmr, then zig-out/bin/zmr.
  --xcrun <path>       xcrun path. Default: xcrun.
  --ios-shim <path>    Optional XCTest shim command for selector hierarchy/actions.
  --ios-shim-mode <disabled|generated|provided>
                       Provenance for evidence runs. Defaults to provided with
                       --ios-shim and disabled without one.
  --skip-shim-prewarm  Do not prewarm the XCTest shim before scenario timing.
  --runs <n>           Run each flow n times. n=1 writes trace bundles; n>1 writes benchmark reports.
  --min-pass-rate <pct>
                       Repeated-run gate minimum. Default: 100.
  --max-failures <n>   Repeated-run gate maximum. Default: 0.
  --max-mean-ms <ms>   Optional repeated-run mean duration maximum.
  --max-p95-ms <ms>    Optional repeated-run p95 duration maximum.
  --dry-run            Print commands without executing them.
  -h, --help           Show this help.

Notes:
  Without --ios-shim, iOS V1 is a simulator smoke path: install, launch,
  deep link, screenshot, logs, and trace export. With --ios-shim, ZMR also
  uses the shim for hierarchy and selector-grade actions. Physical-device
  runs require --ios-device-type physical, a concrete --device identifier from
  `zmr devices`, a signed app artifact, and an app-local XCTest shim for
  selector-grade flows.
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

resolve_path_from_cwd() {
  local value="$1"
  local absolute dir base probe suffix
  if [[ -z "$value" ]]; then
    printf '\n'
    return 0
  fi
  if [[ "$value" == /* ]]; then
    absolute="$value"
  else
    absolute="$CALLER_CWD/$value"
  fi
  if [[ -d "$absolute" ]]; then
    cd "$absolute" && pwd -P
    return 0
  fi
  if [[ -e "$absolute" ]]; then
    dir="$(dirname "$absolute")"
    base="$(basename "$absolute")"
    printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
    return 0
  fi
  dir="$(dirname "$absolute")"
  base="$(basename "$absolute")"
  if [[ -d "$dir" ]]; then
    printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
    return 0
  fi
  probe="$absolute"
  suffix=""
  while [[ "$probe" != "/" && ! -e "$probe" ]]; do
    suffix="/$(basename "$probe")$suffix"
    probe="$(dirname "$probe")"
  done
  if [[ -d "$probe" ]]; then
    printf '%s%s\n' "$(cd "$probe" && pwd -P)" "$suffix"
    return 0
  fi
  while [[ "$absolute" == *"/./"* ]]; do
    absolute="${absolute//\/.\//\/}"
  done
  printf '%s\n' "$absolute"
}

resolve_command_path_from_cwd() {
  local value="$1"
  if [[ -z "$value" || "$value" != */* ]]; then
    printf '%s\n' "$value"
  else
    resolve_path_from_cwd "$value"
  fi
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

run_zmr_report() {
  local trace_dir="$1"
  run_evidence report.generate zmr-report runner.report_failed \
    "$ZMR_BIN" report "$trace_dir" --out "$trace_dir/report.html" --junit "$trace_dir/junit.xml"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    zmr_evidence_register_artifact report "$trace_dir/report.html"
  fi
}

run_ios_benchmark() {
  local command
  command=("$ROOT/scripts/benchmark.sh" "$@")
  echo "+ $(quote_cmd "${command[@]}")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    zmr_evidence_delegate scenario.execute ios-benchmark runner.unclassified -- \
      env ZMR_BIN="$ZMR_BIN" "${command[@]}"
  fi
}

is_retryable_simctl_text() {
  local text="$1"
  [[ "$text" == *"CoreSimulatorService connection became invalid"* ]] ||
    [[ "$text" == *"Failed to initialize simulator device set"* ]] ||
    [[ "$text" == *"simdiskimaged"* ]] ||
    [[ "$text" == *"Connection refused"* ]]
}

run_ios_install() {
  if [[ "$IOS_DEVICE_TYPE" == "physical" ]]; then
    run_evidence app.install install-ios-app runner.unclassified \
      "$XCRUN" devicectl device install app --device "$DEVICE" "$APP_PATH"
    return 0
  fi

  echo "+ $(quote_cmd "$XCRUN" simctl install "$DEVICE" "$APP_PATH")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  local attempt status err_file err_text install_stdout
  err_file="$(mktemp)"
  for attempt in 1 2 3 4 5 6; do
    : > "$err_file"
    if _zmr_evidence_enabled; then
      install_stdout=
      err_text=
      set +e
      zmr_evidence_try_capture_both install_stdout err_text \
        app.install install-ios-app runner.unclassified -- \
        "$XCRUN" simctl install "$DEVICE" "$APP_PATH"
      status=$?
      set -e
      [[ -z "$install_stdout" ]] || printf '%s\n' "$install_stdout"
      printf '%s' "$err_text" >"$err_file"
    else
      set +e
      "$XCRUN" simctl install "$DEVICE" "$APP_PATH" 2>"$err_file"
      status=$?
      set -e
    fi
    if [[ "$status" -eq 0 ]]; then
      rm -f "$err_file"
      return 0
    fi
    err_text="$(cat "$err_file")"
    if [[ "$attempt" == "6" ]] || ! is_retryable_simctl_text "$err_text"; then
      cat "$err_file" >&2
      rm -f "$err_file"
      zmr_evidence_finalize_failure runner_failure app.install runner.unclassified \
        "iOS app installation failed" \
        "Inspect the bounded install command logs." "$status"
      return "$status"
    fi
    echo "warning: simctl install hit a transient CoreSimulator error; retrying ($attempt/6)" >&2
    sleep 0.5
  done
}

prewarm_ios_shim() {
  if [[ -z "$IOS_SHIM" || "$PREWARM_IOS_SHIM" -eq 0 ]]; then
    return 0
  fi

  echo "+ printf '{\"cmd\":\"appState\"}\\n' | $(printf '%q' "$IOS_SHIM")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  zmr_evidence_event shim.build passed '' "iOS shim command is available"
  zmr_evidence_event shim.start started
  if ! printf '{"cmd":"appState"}\n' | zmr_evidence_run \
      shim.prewarm ios-shim-prewarm runner.ios_shim.readiness_timeout -- \
      "$IOS_SHIM" >/dev/null; then
    echo "error: iOS XCTest shim prewarm failed" >&2
    echo "hint: run the printed appState command directly, inspect .zmr/ios-shim-state/xcodebuild.build.log, and rerun with ZMR_IOS_SHIM_FORCE_REBUILD=1 after changing Xcode targets." >&2
    exit 1
  fi
  zmr_evidence_event shim.start passed
}

cleanup_evidence() {
  zmr_evidence_event cleanup started
  zmr_evidence_event cleanup passed
}

if _zmr_evidence_enabled; then
  zmr_evidence_register_cleanup cleanup_evidence
fi

physical_device_state_from_json() {
  local devices_json="$1"
  local serial="$2"
  local state
  for state in connected available disconnected unavailable paired; do
    if [[ "$devices_json" == *'"serial":"'"$serial"'","state":"'"$state"'"'* ]]; then
      printf '%s\n' "$state"
      return 0
    fi
  done
  printf 'unknown\n'
}

preflight_ios_device() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  local devices_json
  devices_json="$("$ZMR_BIN" devices --json --platform ios --ios-device-type "$IOS_DEVICE_TYPE" --xcrun "$XCRUN" 2>/dev/null || true)"
  if [[ "$IOS_DEVICE_TYPE" == "physical" ]]; then
    if [[ "$DEVICE" == "booted" ]]; then
      echo "error: --device must be a physical iOS identifier when --ios-device-type physical is used" >&2
      echo "errorCode: setup.ios.physical_device_required" >&2
      zmr_evidence_finalize_failure configuration_failure device.preflight \
        config.device_selection \
        "A physical iOS device identifier is required" \
        "Select a connected physical device identifier." 2
      exit 2
    fi
    if [[ "$devices_json" != *'"serial":"'"$DEVICE"'"'* ]]; then
      echo "error: physical iOS device not found: $DEVICE" >&2
      echo "errorCode: setup.ios.physical_device_not_found" >&2
      echo "hint: connect and trust the device, enable Developer Mode, then run zmr devices --json --platform ios --ios-device-type physical --xcrun $(printf '%q' "$XCRUN")." >&2
      zmr_evidence_finalize_failure infrastructure_failure device.preflight \
        infra.device_unavailable \
        "The requested physical iOS device was not found" \
        "Connect, trust, and enable Developer Mode on the device." 2
      exit 2
    fi
    if [[ "$devices_json" != *'"serial":"'"$DEVICE"'","state":"connected"'* && "$devices_json" != *'"serial":"'"$DEVICE"'","state":"available"'* ]]; then
      local device_state
      device_state="$(physical_device_state_from_json "$devices_json" "$DEVICE")"
      echo "error: physical iOS device is not ready: $DEVICE" >&2
      echo "state: $device_state" >&2
      echo "errorCode: setup.ios.physical_device_not_ready" >&2
      echo "hint: connect and trust the device, enable Developer Mode, confirm zmr devices reports state connected or available, then retry." >&2
      zmr_evidence_finalize_failure infrastructure_failure device.preflight \
        infra.device_unavailable \
        "The requested physical iOS device is not ready" \
        "Reconnect and prepare the device, then retry." 2
      exit 2
    fi
    return 0
  fi
  if [[ "$DEVICE" == "booted" ]]; then
    if [[ "$devices_json" == *'"count":0'* || -z "$devices_json" ]]; then
      if simctl_has_booted_device ""; then
        return 0
      fi
      if [[ -z "$devices_json" ]]; then
        echo "warning: could not verify booted iOS simulator during preflight; continuing to simctl install" >&2
        return 0
      fi
      echo "error: no booted iOS simulator found" >&2
      echo "errorCode: setup.ios.no_booted_simulators" >&2
      echo "hint: boot a simulator, then run zmr doctor --json --xcrun $(printf '%q' "$XCRUN")." >&2
      "$ZMR_BIN" doctor --json --xcrun "$XCRUN" >&2 || true
      zmr_evidence_finalize_failure infrastructure_failure device.preflight \
        infra.simulator_provision \
        "No booted iOS simulator is available" \
        "Boot a compatible simulator, then retry." 2
      exit 2
    fi
    return 0
  fi

  if [[ "$devices_json" != *'"serial":"'"$DEVICE"'"'* ]]; then
    if simctl_has_booted_device "$DEVICE"; then
      return 0
    fi
    if [[ -z "$devices_json" ]]; then
      echo "warning: could not verify iOS simulator during preflight; continuing to simctl install" >&2
      return 0
    fi
    echo "error: iOS simulator not found or not booted: $DEVICE" >&2
    echo "errorCode: setup.ios.no_booted_simulators" >&2
    echo "hint: boot the requested simulator, then run zmr doctor --json --xcrun $(printf '%q' "$XCRUN")." >&2
    "$ZMR_BIN" doctor --json --xcrun "$XCRUN" >&2 || true
    zmr_evidence_finalize_failure infrastructure_failure device.preflight \
      infra.simulator_provision \
      "The requested iOS simulator is unavailable" \
      "Boot the requested simulator, then retry." 2
    exit 2
  fi
}

simctl_has_booted_device() {
  local wanted="${1:-}"
  local booted_text
  local attempt
  for attempt in 1 2 3 4 5 6; do
    booted_text="$("$XCRUN" simctl list devices booted 2>/dev/null || true)"
    if [[ -n "$booted_text" ]]; then
      if [[ -z "$wanted" && "$booted_text" == *"(Booted)"* ]]; then
        return 0
      fi
      if [[ -n "$wanted" && "$booted_text" == *"$wanted"* && "$booted_text" == *"(Booted)"* ]]; then
        return 0
      fi
    fi
    sleep 0.5
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-root)
      APP_ROOT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --app-path)
      APP_PATH="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --device)
      DEVICE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-device-type)
      IOS_DEVICE_TYPE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --app-id)
      APP_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --trace-root)
      TRACE_ROOT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --zmr-bin)
      ZMR_BIN="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --xcrun)
      XCRUN="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-shim)
      IOS_SHIM="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-shim-mode)
      IOS_SHIM_MODE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --skip-shim-prewarm)
      PREWARM_IOS_SHIM=0
      shift
      ;;
    --runs)
      RUNS="$(require_value "$1" "${2-}")"
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
    --max-mean-ms)
      MAX_MEAN_MS="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --max-p95-ms)
      MAX_P95_MS="$(require_value "$1" "${2-}")"
      shift 2
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

[[ -n "$APP_PATH" ]] || die "--app-path is required"
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || die "--runs must be a positive integer"
[[ "$IOS_DEVICE_TYPE" == "simulator" || "$IOS_DEVICE_TYPE" == "physical" ]] || die "--ios-device-type must be simulator or physical"
[[ "$MIN_PASS_RATE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--min-pass-rate must be a non-negative number"
[[ "$MAX_FAILURES" =~ ^[0-9]+$ ]] || die "--max-failures must be a non-negative integer"
[[ -z "$MAX_MEAN_MS" || "$MAX_MEAN_MS" =~ ^[0-9]+$ ]] || die "--max-mean-ms must be a non-negative integer"
[[ -z "$MAX_P95_MS" || "$MAX_P95_MS" =~ ^[0-9]+$ ]] || die "--max-p95-ms must be a non-negative integer"

APP_PATH="$(resolve_path_from_cwd "$APP_PATH")"
TRACE_ROOT="$(resolve_path_from_cwd "$TRACE_ROOT")"
ZMR_BIN="$(resolve_command_path_from_cwd "$ZMR_BIN")"
XCRUN="$(resolve_command_path_from_cwd "$XCRUN")"
if [[ -n "$APP_ROOT" ]]; then
  APP_ROOT="$(resolve_path_from_cwd "$APP_ROOT")"
fi
if [[ -n "$IOS_SHIM" ]]; then
  IOS_SHIM="$(resolve_command_path_from_cwd "$IOS_SHIM")"
fi
if [[ -z "$IOS_SHIM_MODE" ]]; then
  if [[ -n "$IOS_SHIM" ]]; then
    IOS_SHIM_MODE=provided
  else
    IOS_SHIM_MODE=disabled
  fi
fi
case "$IOS_SHIM_MODE" in
  disabled)
    if [[ -n "$IOS_SHIM" ]]; then
      zmr_evidence_finalize_failure configuration_failure invocation config.invalid \
        "Disabled iOS shim mode contradicts the shim path" \
        "Remove the shim path or select generated/provided mode." 2
      die "disabled --ios-shim-mode forbids --ios-shim"
    fi
    ;;
  generated|provided)
    if [[ -z "$IOS_SHIM" ]]; then
      zmr_evidence_finalize_failure configuration_failure invocation config.invalid \
        "Enabled iOS shim mode requires a shim path" \
        "Provide --ios-shim or select disabled mode." 2
      die "--ios-shim-mode $IOS_SHIM_MODE requires --ios-shim"
    fi
    ;;
  *) die "--ios-shim-mode must be disabled, generated, or provided" ;;
esac

if [[ "$DRY_RUN" -eq 0 ]]; then
  if [[ "$IOS_DEVICE_TYPE" == "physical" ]]; then
    if [[ ! -e "$APP_PATH" ]]; then
      zmr_evidence_finalize_failure configuration_failure app.install \
        config.app_artifact_missing \
        "The iOS physical app artifact is missing" \
        "Build or provide a signed app artifact, then retry." 2
      die "iOS physical app artifact not found: $APP_PATH"
    fi
  else
    if [[ "${APP_PATH##*.}" == "ipa" ]]; then
      die "setup.ios.simulator_app_required: simulator runs require an iphonesimulator .app directory, but got an .ipa. Use a simulator-compatible .app build, or run a device IPA with --ios-device-type physical."
    fi
    if [[ ! -d "$APP_PATH" ]]; then
      zmr_evidence_finalize_failure configuration_failure app.install \
        config.app_artifact_missing \
        "The iOS simulator app artifact is missing" \
        "Build an iphonesimulator .app directory, then retry." 2
      die "setup.ios.simulator_app_required: simulator runs require an iphonesimulator .app directory: $APP_PATH"
    fi
  fi
  if [[ -n "$APP_ROOT" ]]; then
    [[ -d "$APP_ROOT" ]] || die "app repo not found: $APP_ROOT"
  fi
fi

echo "iOS pilot output: $TRACE_ROOT"
if [[ -n "$APP_ROOT" ]]; then
  echo "App root: $APP_ROOT"
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: commands will be printed but not executed"
fi

run_evidence evidence.init prepare-output runner.unclassified mkdir -p "$TRACE_ROOT" "$(dirname "$ZMR_BIN")"

if [[ ! -x "$ZMR_BIN" ]]; then
  target_args=()
  if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    target_args=(-target aarch64-macos.15.0)
  fi
  run_evidence app.build build-zmr runner.unclassified zig build-exe src/main.zig "${target_args[@]}" -O Debug -femit-bin="$ZMR_BIN"
fi

run_evidence invocation zmr-version runner.unclassified "$ZMR_BIN" version
run_evidence scenario.validate validate-ios-smoke config.invalid "$ZMR_BIN" validate examples/ios-smoke.json
if [[ -n "$IOS_SHIM" ]]; then
  run_evidence scenario.validate validate-ios-shim-smoke config.invalid "$ZMR_BIN" validate examples/ios-shim-smoke.json
fi
preflight_ios_device
run_ios_install
prewarm_ios_shim

if [[ "$RUNS" -eq 1 ]]; then
  TRACE_DIR="$TRACE_ROOT/ios-smoke"
  run rm -rf "$TRACE_DIR"
  if [[ -n "$IOS_SHIM" ]]; then
    command=("$ZMR_BIN" run examples/ios-smoke.json --platform ios --ios-device-type "$IOS_DEVICE_TYPE" --device "$DEVICE" --app-id "$APP_ID" --xcrun "$XCRUN" --ios-shim "$IOS_SHIM" --trace-dir "$TRACE_DIR")
  else
    command=("$ZMR_BIN" run examples/ios-smoke.json --platform ios --ios-device-type "$IOS_DEVICE_TYPE" --device "$DEVICE" --app-id "$APP_ID" --xcrun "$XCRUN" --trace-dir "$TRACE_DIR")
  fi
  echo "+ $(quote_cmd "${command[@]}")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    zmr_evidence_run_outcome scenario.execute zmr-run "$IOS_SHIM_MODE" -- "${command[@]}"
  fi
  run_zmr_report "$TRACE_DIR"
  run "$ZMR_BIN" export "$TRACE_DIR" --out "$TRACE_ROOT/ios-smoke.zmrtrace"
  run "$ZMR_BIN" export "$TRACE_DIR" --out "$TRACE_ROOT/ios-smoke-redacted.zmrtrace" --redact

  if [[ -n "$IOS_SHIM" ]]; then
    SHIM_TRACE_DIR="$TRACE_ROOT/ios-shim-smoke"
    run rm -rf "$SHIM_TRACE_DIR"
    command=("$ZMR_BIN" run examples/ios-shim-smoke.json --platform ios --ios-device-type "$IOS_DEVICE_TYPE" --device "$DEVICE" --app-id "$APP_ID" --xcrun "$XCRUN" --ios-shim "$IOS_SHIM" --trace-dir "$SHIM_TRACE_DIR")
    echo "+ $(quote_cmd "${command[@]}")"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      zmr_evidence_run_outcome scenario.execute zmr-run "$IOS_SHIM_MODE" -- "${command[@]}"
    fi
    run_zmr_report "$SHIM_TRACE_DIR"
    run "$ZMR_BIN" export "$SHIM_TRACE_DIR" --out "$TRACE_ROOT/ios-shim-smoke.zmrtrace"
    run "$ZMR_BIN" export "$SHIM_TRACE_DIR" --out "$TRACE_ROOT/ios-shim-smoke-redacted.zmrtrace" --redact
  fi
else
  benchmark_gate_args=(--min-pass-rate "$MIN_PASS_RATE" --max-failures "$MAX_FAILURES")
  if [[ -n "$MAX_MEAN_MS" ]]; then
    benchmark_gate_args+=(--max-mean-ms "$MAX_MEAN_MS")
  fi
  if [[ -n "$MAX_P95_MS" ]]; then
    benchmark_gate_args+=(--max-p95-ms "$MAX_P95_MS")
  fi

  if [[ -n "$IOS_SHIM" ]]; then
    run_ios_benchmark --zmr examples/ios-smoke.json --device "$DEVICE" --platform ios --ios-device-type "$IOS_DEVICE_TYPE" --app-id "$APP_ID" --xcrun "$XCRUN" --ios-shim "$IOS_SHIM" --ios-shim-mode "$IOS_SHIM_MODE" --runs "$RUNS" --trace-root "$TRACE_ROOT/ios-smoke-benchmark" "${benchmark_gate_args[@]}"
  else
    run_ios_benchmark --zmr examples/ios-smoke.json --device "$DEVICE" --platform ios --ios-device-type "$IOS_DEVICE_TYPE" --app-id "$APP_ID" --xcrun "$XCRUN" --ios-shim-mode "$IOS_SHIM_MODE" --runs "$RUNS" --trace-root "$TRACE_ROOT/ios-smoke-benchmark" "${benchmark_gate_args[@]}"
  fi
  run_zmr_report "$TRACE_ROOT/ios-smoke-benchmark"

  if [[ -n "$IOS_SHIM" ]]; then
    run_ios_benchmark --zmr examples/ios-shim-smoke.json --device "$DEVICE" --platform ios --ios-device-type "$IOS_DEVICE_TYPE" --app-id "$APP_ID" --xcrun "$XCRUN" --ios-shim "$IOS_SHIM" --ios-shim-mode "$IOS_SHIM_MODE" --runs "$RUNS" --trace-root "$TRACE_ROOT/ios-shim-smoke-benchmark" "${benchmark_gate_args[@]}"
    run_zmr_report "$TRACE_ROOT/ios-shim-smoke-benchmark"
  fi
fi

echo
echo "iOS pilot complete."
echo "Output directory: $TRACE_ROOT"
if [[ "$RUNS" -eq 1 ]]; then
  echo "Shareable bundle:"
  echo "  $TRACE_ROOT/ios-smoke-redacted.zmrtrace"
  if [[ -n "$IOS_SHIM" ]]; then
    echo "  $TRACE_ROOT/ios-shim-smoke-redacted.zmrtrace"
  fi
else
  echo "Benchmark reports:"
  echo "  $TRACE_ROOT/ios-smoke-benchmark/report.html"
  echo "  $TRACE_ROOT/ios-smoke-benchmark/junit.xml"
  if [[ -n "$IOS_SHIM" ]]; then
    echo "  $TRACE_ROOT/ios-shim-smoke-benchmark/report.html"
    echo "  $TRACE_ROOT/ios-shim-smoke-benchmark/junit.xml"
  fi
fi
echo "Viewer:"
echo "  $ROOT/viewer/index.html"
