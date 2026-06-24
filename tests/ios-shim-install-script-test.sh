#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--app-root" "--scheme" "--bundle-id" "--app-target" "--test-target" "--test-bundle-id" "--workspace" "--project" "--derived-data-path" "--device" "--device-type" "--configuration" "--deployment-target"; do
  set +e
  missing_value_output="$("$ROOT/scripts/install-ios-shim.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "install-ios-shim should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

mkdir -p "$TMPDIR/app/.zmr"
cat > "$TMPDIR/app/.zmr/config.json" <<'JSON'
{
  "schemaVersion": 1,
  "appId": "com.example.mobiletest",
  "ios": {
    "enabled": true,
    "defaultDevice": "booted",
    "smokeScenario": ".zmr/ios-smoke.json",
    "traceDir": "traces/zmr-ios"
  },
  "scripts": {
    "ios": "zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios"
  }
}
JSON

"$ROOT/scripts/install-ios-shim.sh" \
  --app-root "$TMPDIR/app" \
  --scheme SampleUITests \
  --app-target SampleApp \
  --project ios/Sample.xcodeproj \
  --derived-data-path ios/build/ZMRDerivedData \
  --bundle-id com.example.mobiletest \
  --test-bundle-id com.example.mobiletest.zmr-uitests \
  --deployment-target 16.0 \
  --device booted

test -x "$TMPDIR/app/.zmr/ios-shim"
test -f "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
test -f "$TMPDIR/app/.zmr/ZMRShimUITests-Info.plist"
bash -n "$TMPDIR/app/.zmr/ios-shim"
ruby -rjson -e '
  config = JSON.parse(File.read(ARGV.fetch(0)))
  abort "missing tools.iosShimPath" unless config.dig("tools", "iosShimPath") == "./.zmr/ios-shim"
  abort "lost appId" unless config["appId"] == "com.example.mobiletest"
' "$TMPDIR/app/.zmr/config.json"

grep -q 'xcodebuild test' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'cd "'"$TMPDIR/app"'"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'destination_spec' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'platform_name="iOS Simulator"' "$TMPDIR/app/.zmr/ios-shim"
grep -q -- '-project "ios/Sample.xcodeproj"' "$TMPDIR/app/.zmr/ios-shim"
grep -q -- '-derivedDataPath "ios/build/ZMRDerivedData"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ZMR_SHIM_REQUEST_FILE' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ZMR_SHIM_RESPONSE_FILE' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ZMR_IOS_SHIM_ONESHOT' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'xcodebuild.oneshot.log.XXXXXX' "$TMPDIR/app/.zmr/ios-shim"
if grep -q 'xcodebuild.oneshot.XXXXXX.log' "$TMPDIR/app/.zmr/ios-shim"; then
  echo "ios-shim should use a mktemp template with XXXXXX at the end" >&2
  exit 1
fi
grep -q 'ios-shim-state' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'PID_FILE="$STATE_DIR/xcodebuild.pid"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'READY_FILE="$SERVER_DIR/ready"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'DESTINATION_ID_FILE="$STATE_DIR/destination.id"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'BUILD_READY_FILE="$STATE_DIR/build-for-testing.ready"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ZMR_IOS_SHIM_FORCE_REBUILD' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'request-$REQUEST_ID.json' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'response-$REQUEST_ID.json' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'rm -f "$request_file" "$response_file"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ZMR_SHIM_MODE="server"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ZMR_SHIM_SERVER_DIR="$SERVER_DIR"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ZMR_IOS_SHIM_BUILD_TIMEOUT_SECONDS:-5400' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'run_xcodebuild_with_timeout "iOS shim build-for-testing"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'timed out waiting for $label after' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'xcodebuild build-for-testing' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'nohup xcodebuild test-without-building' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'rm -f "$APP_ROOT/.zmr/ios-shim-state/destination.id"' "$ROOT/scripts/install-ios-shim.sh"
grep -q 'rm -rf "$APP_ROOT/.zmr/ios-shim-state/server"' "$ROOT/scripts/install-ios-shim.sh"
grep -q 'xcrun simctl list devices available' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'ps -p "$pid" -o command=' "$TMPDIR/app/.zmr/ios-shim"
grep -q '\[\[ "$command" == \*xcodebuild\* && "$command" == \*"SampleUITests"\* \]\]' "$TMPDIR/app/.zmr/ios-shim"
if grep -q '\[\[ "$command" == \*xcodebuild\* && "$command" == \*ZMRShimUITests\* \]\]' "$TMPDIR/app/.zmr/ios-shim"; then
  echo "ios-shim process liveness check should use the generated test target name" >&2
  exit 1
fi
grep -q '< /dev/null' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'tail -120 "$LOG_FILE"' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'SampleUITests' "$TMPDIR/app/.zmr/ios-shim"
grep -q 'com.example.mobiletest' "$TMPDIR/app/.zmr/ios-shim"
test -x "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
test -f "$TMPDIR/app/.zmr/ensure-ios-shim-target.rb"
bash -n "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
ruby -c "$TMPDIR/app/.zmr/ensure-ios-shim-target.rb" >/dev/null
grep -q 'PROJECT=ios/Sample.xcodeproj' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q 'APP_TARGET=SampleApp' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q 'TEST_TARGET=SampleUITests' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q 'SCHEME=SampleUITests' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q 'BUNDLE_ID=com.example.mobiletest' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q 'TEST_BUNDLE_ID=com.example.mobiletest.zmr-uitests' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q 'DEPLOYMENT_TARGET=16.0' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q -- '--project "$PROJECT"' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q -- '--app-target "$APP_TARGET"' "$TMPDIR/app/.zmr/ensure-ios-shim-target.sh"
grep -q 'xcodeproj' "$TMPDIR/app/.zmr/ios-shim.README.md"
grep -q 'ensure-ios-shim-target.sh' "$TMPDIR/app/.zmr/ios-shim.README.md"
grep -q 'testRunZMRCommand' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'XCUIApplication' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'InfoDictionaryKey' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'runServer' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'process(requestAt requestFile:' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'ZMR_SHIM_MODE' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'ZMR_SHIM_SERVER_DIR' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'resolveElement(selector:' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'preferredTypes: \[.textField, .secureTextField, .textView\]' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'matches(selector:' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'command.selector' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'selector.unsupported' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'commandRequiresForeground' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'ensureAppForeground' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'app.activate()' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q '.runningForeground' "$TMPDIR/app/.zmr/ZMRShimUITestCase.swift"
grep -q 'ZMR_SHIM_REQUEST_FILE' "$TMPDIR/app/.zmr/ZMRShimUITests-Info.plist"
grep -q 'ZMR_SHIM_MODE' "$TMPDIR/app/.zmr/ZMRShimUITests-Info.plist"
grep -q 'ZMR_SHIM_SERVER_DIR' "$TMPDIR/app/.zmr/ZMRShimUITests-Info.plist"

mkdir -p "$TMPDIR/fake-bin" "$TMPDIR/app/ios/build/ZMRDerivedData"
touch "$TMPDIR/app/ios/build/ZMRDerivedData/stale.txt"

cat > "$TMPDIR/fake-bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "simctl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
  case "${4:-}" in
    booted|available)
      echo "    iPhone 15 (11111111-1111-1111-1111-111111111111) (Booted)"
      exit 0
      ;;
  esac
fi

echo "unexpected xcrun args: $*" >&2
exit 2
SH
chmod +x "$TMPDIR/fake-bin/xcrun"

cat > "$TMPDIR/fake-bin/xcodebuild" <<SH
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$*" >> "$TMPDIR/xcodebuild.log"

if [[ "\$*" == *"build-for-testing"* ]]; then
  if [[ -e "$TMPDIR/app/ios/build/ZMRDerivedData/stale.txt" ]]; then
    echo "stale derived data was not cleaned before build-for-testing" >&2
    exit 42
  fi
  exit 0
fi

if [[ "\$*" == *"test-without-building"* ]]; then
  server_dir=""
  for arg in "\$@"; do
    case "\$arg" in
      ZMR_SHIM_SERVER_DIR=*)
        server_dir="\${arg#ZMR_SHIM_SERVER_DIR=}"
        ;;
    esac
  done
  if [[ -z "\$server_dir" ]]; then
    echo "missing ZMR_SHIM_SERVER_DIR" >&2
    exit 2
  fi
  touch "\$server_dir/ready"
  deadline=\$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    for request_file in "\$server_dir"/request-*.json; do
      [[ -e "\$request_file" ]] || continue
      request_id="\${request_file##*/request-}"
      request_id="\${request_id%.json}"
      response_file="\$server_dir/response-\$request_id.json"
      printf '{"status":"ok","state":"runningForeground"}\n' > "\$response_file"
      while [[ -f "\$response_file" && SECONDS -lt deadline ]]; do
        sleep 0.05
      done
      exit 0
    done
    sleep 0.05
  done
  echo "timed out waiting for generated shim request" >&2
  exit 1
fi

echo "unexpected xcodebuild args: \$*" >&2
exit 2
SH
chmod +x "$TMPDIR/fake-bin/xcodebuild"

printf '{"cmd":"appState"}\n' | PATH="$TMPDIR/fake-bin:$PATH" "$TMPDIR/app/.zmr/ios-shim" > "$TMPDIR/derived-data-response.json"
grep -q '"status":"ok"' "$TMPDIR/derived-data-response.json"
test ! -e "$TMPDIR/app/ios/build/ZMRDerivedData/stale.txt"
grep -q -- '-derivedDataPath ios/build/ZMRDerivedData' "$TMPDIR/xcodebuild.log"

"$ROOT/scripts/install-ios-shim.sh" \
  --app-root "$TMPDIR/shared-derived-data-app" \
  --scheme SampleUITests \
  --app-target SampleApp \
  --project ios/Sample.xcodeproj \
  --derived-data-path ios/build \
  --bundle-id com.example.mobiletest \
  --device booted

mkdir -p "$TMPDIR/shared-derived-data-app/ios/build"
touch "$TMPDIR/shared-derived-data-app/ios/build/stale.txt"
printf '{"cmd":"appState"}\n' | PATH="$TMPDIR/fake-bin:$PATH" "$TMPDIR/shared-derived-data-app/.zmr/ios-shim" > "$TMPDIR/shared-derived-data-response.json" 2> "$TMPDIR/shared-derived-data-stderr.txt"
grep -q '"status":"ok"' "$TMPDIR/shared-derived-data-response.json"
grep -q 'refusing to delete non-ZMR derived data path: ios/build' "$TMPDIR/shared-derived-data-stderr.txt"
test -e "$TMPDIR/shared-derived-data-app/ios/build/stale.txt"

"$ROOT/scripts/install-ios-shim.sh" \
  --app-root "$TMPDIR/physical-app" \
  --scheme SampleUITests \
  --project ios/Sample.xcodeproj \
  --bundle-id com.example.mobiletest \
  --device fake-physical-ios-1 \
  --device-type physical

bash -n "$TMPDIR/physical-app/.zmr/ios-shim"
grep -q 'platform_name="iOS"' "$TMPDIR/physical-app/.zmr/ios-shim"
grep -q 'local destination_id="fake-physical-ios-1"' "$TMPDIR/physical-app/.zmr/ios-shim"
