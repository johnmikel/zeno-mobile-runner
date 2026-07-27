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
OUT="/tmp/zmr-demo-video-$(date +%Y%m%d-%H%M%S)"
DEVICE=""
APP_DIR=""
METRO_PORT="8081"
SKIP_BUILD=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/record-demo-video.sh --device <simulator-udid> [options]

Produces the raw footage for the ZMR launch demo from the generated public
React Native / Expo demo app, with no private app references:

  1. Generates the Expo demo app, installs dependencies, builds the iOS dev
     client, and installs the ZMR XCTest shim.
  2. Records segment A: the full iOS workflow scenario passing on a real
     simulator (welcome -> profile -> catalog -> review).
  3. Breaks the app the way real teams do — a copy change ("Profile" ->
     "Your details") — and records segment B: the same scenario failing,
     plus the `zmr explain` diagnosis pointing at the new on-screen text.
  4. Repairs the scenario selector and records segment C: green again.
  5. Exports the redacted trace bundle and HTML report for viewer shots.

Outputs land under --out: segment-*.mp4 simulator recordings, terminal
transcripts for each beat, traces, and a manifest. Compose the final cut with
the storyboard in docs/demo-video-storyboard.md.

Options:
  --device <udid>      Booted (or bootable) iOS simulator UDID. Required.
  --out <dir>          Output directory. Default: /tmp/zmr-demo-video-<ts>.
  --app-dir <dir>      Reuse an already generated+built demo app directory.
  --metro-port <port>  Metro port. Default: 8081.
  --skip-build         Assume the app and shim are already built/installed.
  -h, --help           Show this help.
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
    --device)
      DEVICE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --out)
      OUT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --app-dir)
      APP_DIR="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --metro-port)
      METRO_PORT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
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

[[ -n "$DEVICE" ]] || die "--device is required (xcrun simctl list devices)"
ZMR_BIN="${ZMR_BIN:-$ROOT/zig-out/bin/zmr}"
[[ -x "$ZMR_BIN" ]] || die "zmr binary not found at $ZMR_BIN"
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

mkdir -p "$OUT"
[[ -n "$APP_DIR" ]] || APP_DIR="$OUT/app"

METRO_PID=""
RECORD_PID=""
BOOT_CHECK_N=0
cleanup() {
  if [[ -n "$RECORD_PID" ]] && kill -0 "$RECORD_PID" 2>/dev/null; then
    kill -INT "$RECORD_PID" 2>/dev/null || true
  fi
  if [[ -n "$METRO_PID" ]] && kill -0 "$METRO_PID" 2>/dev/null; then
    kill "$METRO_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log_step() {
  printf '\n== %s ==\n' "$1"
}

record_start() {
  local file="$1"
  xcrun simctl io "$DEVICE" recordVideo --codec h264 --force "$file" &
  RECORD_PID=$!
  sleep 2
}

record_stop() {
  kill -INT "$RECORD_PID" 2>/dev/null || true
  wait "$RECORD_PID" 2>/dev/null || true
  RECORD_PID=""
  sleep 1
}

run_scenario() {
  local label="$1"
  local expect="$2"
  set +e
  "$ZMR_BIN" run .zmr/react-native-expo-ios-workflow.json \
    --platform ios \
    --device "$DEVICE" \
    --app-id com.example.mobiletest \
    --ios-shim ./.zmr/ios-shim \
    --trace-dir "$OUT/trace-$label" \
    --json > "$OUT/terminal-$label.json" 2>&1
  local status=$?
  set -e
  if [[ "$expect" == "pass" && "$status" -ne 0 ]]; then
    die "expected $label run to pass; see $OUT/terminal-$label.json"
  fi
  if [[ "$expect" == "fail" && "$status" -eq 0 ]]; then
    die "expected $label run to fail; see $OUT/terminal-$label.json"
  fi
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log_step "Generate demo app"
  "$ROOT/scripts/create-react-native-expo-demo-app.sh" --out "$APP_DIR"

  log_step "Install dependencies"
  (cd "$APP_DIR" && npm install)

  log_step "Build iOS dev client"
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  (cd "$APP_DIR" && npx expo run:ios --device "$DEVICE" --no-bundler)

  log_step "Install ZMR XCTest shim"
  (cd "$APP_DIR" && "$ROOT/scripts/install-ios-shim.sh" \
    --app-root . \
    --scheme ZenoExpoDemoUITests \
    --bundle-id com.example.mobiletest \
    --app-target ZenoExpoDemo \
    --workspace ios/ZenoExpoDemo.xcworkspace \
    --device "$DEVICE" \
    --patch-xcodeproj)
fi

cd "$APP_DIR"

# The run below deliberately breaks App.tsx (Profile -> Your details) and then
# repairs the scenario selector to match, and neither is reverted at the end.
# Re-running against a reused --app-dir therefore starts from the *repaired*
# state, where the "break" step is a no-op and segment B passes when it must
# fail. Restore both to pristine first so the recorder is re-runnable.
log_step "Restore pristine demo state"
perl -0pi -e 's/(testID="profile_title"[^>]*>\s*\n\s*)Your details/${1}Profile/' App.tsx
grep -q "Profile" App.tsx || die "failed to restore the Profile heading in App.tsx"
python3 - "$PWD/.zmr/react-native-expo-ios-workflow.json" <<'PY'
import json, sys
path = sys.argv[1]
scenario = json.load(open(path))
for step in scenario["steps"]:
    selector = step.get("selector") or {}
    if selector.get("text") == "Your details":
        selector["text"] = "Profile"
json.dump(scenario, open(path, "w"), indent=2)
PY

log_step "Start Metro on port $METRO_PORT"
if lsof -nP -iTCP:"$METRO_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "port $METRO_PORT is already in use; stop the other bundler first"
fi
nohup npx expo start --dev-client --port "$METRO_PORT" > "$OUT/metro.log" 2>&1 &
METRO_PID=$!
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:$METRO_PORT/status"; then break; fi
  sleep 2
done

# A dev client boots to the Expo dev launcher ("DEVELOPMENT SERVERS"), not to
# the app: nothing loads the JS bundle until we point it at Metro explicitly.
# Without this the first scenario step deep-links into a launcher that has no
# bundle to route to, and the run dies on a wait timeout at step 1.
DEMO_SCHEME="$(sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([a-z0-9][a-z0-9+.-]*\):\/\/.*/\1/p' \
  .zmr/react-native-expo-ios-workflow.json | head -1)"
[[ -n "$DEMO_SCHEME" ]] || die "could not derive the demo deep-link scheme from the iOS scenario"

# The scenario's own deep link uses the app scheme (zenoexpodemo://), but the
# expo-dev-client launcher registers a *separate* scheme (exp+zenoexpodemo://)
# and only routes ?url= re-points sent to that one. Sending the launcher URL to
# the bare app scheme opens the app and is silently ignored, so the dev client
# keeps whatever server it last knew — port 8081 from `expo run:ios`, which
# makes --metro-port a no-op and loads a foreign bundle if anything else is
# serving there. Derive the launcher scheme explicitly.
case "$DEMO_SCHEME" in
  exp+*) DEV_CLIENT_SCHEME="$DEMO_SCHEME" ;;
  *) DEV_CLIENT_SCHEME="exp+$DEMO_SCHEME" ;;
esac

cat > "$OUT/.boot-check.json" <<'JSON'
{
  "name": "ZMR demo boot check",
  "appId": "com.example.mobiletest",
  "steps": [
    { "action": "waitVisible", "selector": { "text": "Zeno Expo Demo" }, "timeoutMs": 30000 }
  ]
}
JSON

# Relaunch the app from scratch and re-point it at Metro. Run before every
# segment, not just the first: the scenario types into the profile form on each
# passing run and React keeps that text in component state, so recording A and C
# against one live app appends the second run's input to the first
# ("RileyRiley saved North Ridge Pack"). That is the cosmetic defect the
# storyboard's production notes call out, and it made the 21 Jul segment C
# unusable for the cut.
boot_app() {
  xcrun simctl terminate "$DEVICE" com.example.mobiletest 2>/dev/null || true
  # The Expo dev-menu onboarding sheet covers the app on the first dev-build
  # launch and breaks selector waits; mark onboarding finished before launching.
  xcrun simctl spawn "$DEVICE" defaults write com.example.mobiletest EXDevMenuIsOnboardingFinished -bool true 2>/dev/null || true
  xcrun simctl launch "$DEVICE" com.example.mobiletest
  sleep 6
  xcrun simctl openurl "$DEVICE" \
    "$DEV_CLIENT_SCHEME://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A$METRO_PORT"
  sleep 20
  # Fail loudly rather than recording a redbox: if the re-point did not land,
  # the app is showing the dev-launcher error or a foreign bundle, not the demo.
  BOOT_CHECK_N=$((BOOT_CHECK_N + 1))
  if ! "$ZMR_BIN" run "$OUT/.boot-check.json" \
    --platform ios --device "$DEVICE" --app-id com.example.mobiletest \
    --ios-shim ./.zmr/ios-shim --trace-dir "$OUT/trace-boot-check-$BOOT_CHECK_N" --json \
    > "$OUT/terminal-boot-check-$BOOT_CHECK_N.json" 2>&1; then
    die "app did not reach the welcome screen after re-pointing at 127.0.0.1:$METRO_PORT; see $OUT/terminal-boot-check-$BOOT_CHECK_N.json"
  fi
}

log_step "Warm the app (first bundle load)"
boot_app

log_step "Warm the ZMR shim (first use pays xcodebuild build-for-testing)"
printf '{"cmd":"appState"}\n' | ./.zmr/ios-shim > /dev/null

log_step "Segment A: passing workflow run"
record_start "$OUT/segment-a-pass.mp4"
run_scenario "a-pass" "pass"
record_stop

log_step "Break the app: rename the Profile heading"
perl -0pi -e 's/(testID="profile_title"[^>]*>\s*\n\s*)Profile/${1}Your details/' App.tsx
grep -q "Your details" App.tsx || die "failed to apply the demo copy change"
sleep 6  # let Metro hot-reload the change
boot_app  # fresh state, and picks up the renamed heading from a clean bundle

log_step "Segment B: failing run + diagnosis"
record_start "$OUT/segment-b-fail.mp4"
run_scenario "b-fail" "fail"
record_stop
"$ZMR_BIN" explain "$OUT/trace-b-fail" > "$OUT/terminal-b-explain.txt" 2>&1 || true
"$ZMR_BIN" explain "$OUT/trace-b-fail" --json > "$OUT/terminal-b-explain.json" 2>&1 || true

log_step "Repair the scenario selector"
python3 - "$PWD/.zmr/react-native-expo-ios-workflow.json" <<'PY'
import json, sys
path = sys.argv[1]
scenario = json.load(open(path))
for step in scenario["steps"]:
    selector = step.get("selector") or {}
    if selector.get("text") == "Profile":
        selector["text"] = "Your details"
json.dump(scenario, open(path, "w"), indent=2)
PY
"$ZMR_BIN" validate .zmr/react-native-expo-ios-workflow.json
boot_app  # critical: without this C types over A's input and reads "RileyRiley"

log_step "Segment C: green again"
record_start "$OUT/segment-c-pass.mp4"
run_scenario "c-pass" "pass"
record_stop

log_step "Evidence exports"
"$ZMR_BIN" report "$OUT/trace-c-pass" --out "$OUT/report.html" --junit "$OUT/junit.xml"
"$ZMR_BIN" export "$OUT/trace-c-pass" --out "$OUT/workflow-pass.zmrtrace" --redact
"$ZMR_BIN" export "$OUT/trace-b-fail" --out "$OUT/workflow-fail.zmrtrace" --redact

log_step "Done"
ls -la "$OUT"/segment-*.mp4
echo "assets: $OUT"
echo "compose with docs/demo-video-storyboard.md"
