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
WORK="/tmp/zmr-screenshots-$(date +%Y%m%d-%H%M%S)"
ASSETS_DIR="$ROOT/docs/assets"
ANDROID_AVD=""
ANDROID_DEVICE="emulator-5554"
IOS_DEVICE="booted"
SKIP_ANDROID=0
SKIP_IOS=0
SKIP_VIEWER=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/capture-screenshots.sh [options]

Maintainer pipeline that regenerates the public documentation screenshots in
docs/assets/ from real demo-app runs:

  1. Runs scripts/demo-android-real.sh against an Android emulator/device and
     exports a report plus a redacted trace bundle.
  2. Runs scripts/demo-ios-real.sh against an iOS simulator (reports and
     bundles are produced by the pilot itself).
  3. Copies the freshest on-device snapshot screenshots into docs/assets/ and
     downscales them with sips.
  4. Captures the trace viewer and HTML report with a headless Chromium when
     Playwright is available (scripts/capture-viewer-shots.mjs), and prints
     manual instructions otherwise.

Device screenshots and trace bundles never leave /tmp except for the final
downscaled PNGs written to docs/assets/. docs/assets/ is excluded from the npm
package; these images ship only in the git repository.

Options:
  --avd <name>           Android AVD to boot when no device is ready.
  --android-device <id>  Android device serial. Default: emulator-5554.
  --ios-device <udid>    iOS simulator UDID. Default: booted.
  --assets-dir <dir>     Output directory. Default: docs/assets.
  --skip-android         Skip the Android demo run.
  --skip-ios             Skip the iOS demo run.
  --skip-viewer          Skip viewer/report browser captures.
  -h, --help             Show this help.
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
    --avd)
      ANDROID_AVD="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --android-device)
      ANDROID_DEVICE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-device)
      IOS_DEVICE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --assets-dir)
      ASSETS_DIR="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --skip-android)
      SKIP_ANDROID=1
      shift
      ;;
    --skip-ios)
      SKIP_IOS=1
      shift
      ;;
    --skip-viewer)
      SKIP_VIEWER=1
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

ZMR_BIN="${ZMR_BIN:-$ROOT/zig-out/bin/zmr}"
if [[ ! -x "$ZMR_BIN" ]]; then
  die "zmr binary not found at $ZMR_BIN; build it first (see scripts/demo.sh)"
fi

mkdir -p "$ASSETS_DIR" "$WORK"

copy_latest_snapshot() {
  local trace_dir="$1"
  local dest="$2"
  local max_width="$3"
  local latest
  latest="$(ls -t "$trace_dir"/artifacts/snapshot-*.png 2>/dev/null | head -1 || true)"
  if [[ -z "$latest" ]]; then
    echo "warn: no snapshot screenshots in $trace_dir" >&2
    return 1
  fi
  if [[ "$(head -c 8 "$latest" | wc -c | tr -d ' ')" -lt 8 ]]; then
    die "snapshot $latest is not a real PNG; refusing to publish it"
  fi
  cp "$latest" "$dest"
  sips -Z "$max_width" "$dest" >/dev/null
  echo "wrote $dest"
}

ANDROID_TRACE=""
if [[ "$SKIP_ANDROID" -eq 0 ]]; then
  android_args=(
    --out "$WORK/android"
    --device "$ANDROID_DEVICE"
    --trace-root "$WORK/android/traces/pilot"
  )
  if [[ -n "$ANDROID_AVD" ]]; then
    android_args+=(--avd "$ANDROID_AVD")
  fi
  "$ROOT/scripts/demo-android-real.sh" "${android_args[@]}"
  ANDROID_TRACE="$WORK/android/traces/pilot/zmr-1"
  "$ZMR_BIN" report "$ANDROID_TRACE" --out "$ANDROID_TRACE/report.html"
  "$ZMR_BIN" export "$ANDROID_TRACE" --out "$WORK/android-demo-redacted.zmrtrace" --redact
  copy_latest_snapshot "$ANDROID_TRACE" "$ASSETS_DIR/device-android-demo.png" 800
fi

IOS_TRACE=""
if [[ "$SKIP_IOS" -eq 0 ]]; then
  "$ROOT/scripts/demo-ios-real.sh" \
    --out "$WORK/ios" \
    --device "$IOS_DEVICE" \
    --trace-root "$WORK/ios/traces/pilot" \
    --cleanup-build-products
  IOS_TRACE="$WORK/ios/traces/pilot/ios-shim-smoke"
  if [[ ! -d "$IOS_TRACE" ]]; then
    IOS_TRACE="$WORK/ios/traces/pilot/ios-smoke"
  fi
  copy_latest_snapshot "$IOS_TRACE" "$ASSETS_DIR/device-ios-demo.png" 800
fi

if [[ "$SKIP_VIEWER" -eq 0 ]]; then
  bundle=""
  if [[ -f "$WORK/ios/traces/pilot/ios-shim-smoke-redacted.zmrtrace" ]]; then
    bundle="$WORK/ios/traces/pilot/ios-shim-smoke-redacted.zmrtrace"
  elif [[ -f "$WORK/android-demo-redacted.zmrtrace" ]]; then
    bundle="$WORK/android-demo-redacted.zmrtrace"
  fi
  report_html=""
  if [[ -n "$ANDROID_TRACE" && -f "$ANDROID_TRACE/report.html" ]]; then
    report_html="$ANDROID_TRACE/report.html"
  elif [[ -n "$IOS_TRACE" && -f "$IOS_TRACE/report.html" ]]; then
    report_html="$IOS_TRACE/report.html"
  fi
  if command -v npx >/dev/null 2>&1 && [[ -n "$bundle" ]]; then
    node "$ROOT/scripts/capture-viewer-shots.mjs" \
      --viewer "$ROOT/viewer/index.html" \
      --bundle "$bundle" \
      ${report_html:+--report "$report_html"} \
      --out "$ASSETS_DIR" || {
      echo "warn: browser capture failed; capture viewer screenshots manually:" >&2
      echo "  open $ROOT/viewer/index.html and load $bundle" >&2
    }
  else
    echo "manual step: open $ROOT/viewer/index.html, load $bundle, and save:"
    echo "  $ASSETS_DIR/viewer-hero.png (full viewer, 1440x900)"
    echo "  $ASSETS_DIR/viewer-replay.png (replay panel)"
    if [[ -n "$report_html" ]]; then
      echo "  $ASSETS_DIR/report-html.png (open $report_html)"
    fi
  fi
fi

echo "done; working artifacts in $WORK"
