#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG_TARGET="${ZIG_TARGET:-}"
if [[ -z "$ZIG_TARGET" ]]; then
  if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    ZIG_TARGET="aarch64-macos.15.0"
  else
    ZIG_TARGET="native"
  fi
fi

target_args=()
if [[ "$ZIG_TARGET" != "native" ]]; then
  target_args=(-target "$ZIG_TARGET")
fi

mkdir -p zig-out/bin traces
zig build-exe src/main.zig "${target_args[@]}" -O Debug -femit-bin=zig-out/bin/zmr

echo "== ZMR version =="
./zig-out/bin/zmr version
./zig-out/bin/zmr version --json

echo
echo "== Public schema discovery =="
./zig-out/bin/zmr schemas --json

echo
echo "== Validate demo scenarios =="
./zig-out/bin/zmr validate examples/demo-fake.json
./zig-out/bin/zmr validate examples/demo-failure.json
./zig-out/bin/zmr validate examples/android-app-onboarding.json
./zig-out/bin/zmr validate examples/android-app-referral-deep-link.json
./zig-out/bin/zmr validate examples/android-app-error-state.json
./zig-out/bin/zmr validate examples/android-shim-smoke.json
./zig-out/bin/zmr validate examples/android-workflow.json
./zig-out/bin/zmr validate examples/react-native-expo-workflow.json
./zig-out/bin/zmr validate examples/ios-smoke.json
./zig-out/bin/zmr validate examples/ios-dev-client-open-link.json
./zig-out/bin/zmr validate examples/ios-shim-smoke.json
./zig-out/bin/zmr validate examples/ios-shim-workflow.json

echo
echo "== Validate diagnostics: field and line location =="
INVALID_SCENARIO="traces/demo-invalid-scenario.json"
printf '{\n  "name": "invalid",\n  "steps": "nope"\n}\n' > "$INVALID_SCENARIO"
if ./zig-out/bin/zmr validate "$INVALID_SCENARIO" --json; then
  echo "expected invalid scenario validation to fail" >&2
  exit 1
fi

echo
echo "== Doctor: fake local toolchain =="
./zig-out/bin/zmr doctor --adb ./tests/fake-adb.sh --android-shim ./tests/fake-android-shim.sh --xcrun ./tests/fake-xcrun.sh --ios-shim ./tests/fake-ios-shim.sh

echo
echo "== Doctor: remediation hint JSON =="
DOCTOR_HINT_JSON="$(./zig-out/bin/zmr doctor --json --adb ./tests/fake-adb.sh --android-shim ./definitely-missing-android-shim --xcrun ./tests/fake-xcrun.sh)"
printf '%s\n' "$DOCTOR_HINT_JSON"
case "$DOCTOR_HINT_JSON" in
  *'"name":"android-shim"'*'"errorCode":"setup.android_shim.not_found"'*'"hint":"Run npx zmr-install-android-shim'*)
    ;;
  *)
    echo "expected doctor --json to include android-shim remediation hint" >&2
    exit 1
    ;;
esac

echo
echo "== Doctor: no ready devices diagnostics =="
EMPTY_ADB="traces/demo-fake-adb-empty.sh"
EMPTY_XCRUN="traces/demo-fake-xcrun-empty.sh"
cat > "$EMPTY_ADB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version) printf 'Android Debug Bridge version 1.0.41\n' ;;
  devices) printf 'List of devices attached\n' ;;
  *) exit 2 ;;
esac
SH
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
if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "${1:-}" == "--json-output" ]]; then
      printf '{"result":{"devices":[]}}\n' > "${2:-}"
      exit 0
    fi
    shift
  done
fi
exit 2
SH
chmod +x "$EMPTY_ADB" "$EMPTY_XCRUN"
NO_DEVICE_JSON="$(./zig-out/bin/zmr doctor --json --adb "$EMPTY_ADB" --xcrun "$EMPTY_XCRUN")"
printf '%s\n' "$NO_DEVICE_JSON"
case "$NO_DEVICE_JSON" in
  *'"name":"android-devices"'*'"errorCode":"setup.android.no_devices"'*'"name":"ios-simulators"'*'"errorCode":"setup.ios.no_booted_simulators"'*'"name":"ios-physical-devices"'*'"errorCode":"setup.ios.no_physical_devices"'*)
    ;;
  *)
    echo "expected doctor --json to warn when no Android, iOS simulator, or physical iOS devices are ready" >&2
    exit 1
    ;;
esac
if ./zig-out/bin/zmr doctor --strict --json --adb "$EMPTY_ADB" --xcrun "$EMPTY_XCRUN" > traces/demo-doctor-strict.json; then
  echo "expected doctor --strict to fail when setup checks need attention" >&2
  exit 1
fi
grep -q '"ok":false' traces/demo-doctor-strict.json

echo
echo "== Doctor: config field diagnostics =="
DOCTOR_BAD_CONFIG="traces/demo-bad-config.json"
cat > "$DOCTOR_BAD_CONFIG" <<'JSON'
{
  "schemaVersion": 1,
  "scripts": {
    "android": ""
  }
}
JSON
DOCTOR_BAD_CONFIG_JSON="$(./zig-out/bin/zmr doctor --json --config "$DOCTOR_BAD_CONFIG" --adb ./tests/fake-adb.sh --xcrun ./tests/fake-xcrun.sh)"
printf '%s\n' "$DOCTOR_BAD_CONFIG_JSON"
case "$DOCTOR_BAD_CONFIG_JSON" in
  *'"name":"config"'*'"errorCode":"config.empty_string"'*'ConfigFieldMustBeNonEmptyString'*'"fieldPath":"$.scripts.android"'*)
    ;;
  *)
    echo "expected doctor --config to include config fieldPath diagnostics" >&2
    exit 1
    ;;
esac

echo
echo "== Doctor: config smoke scenario checks =="
DOCTOR_CONFIG="traces/demo-doctor-config.json"
DOCTOR_INVALID_SMOKE="traces/demo-invalid-smoke-scenario.json"
printf '{\n  "name": "invalid smoke",\n  "steps": "nope"\n}\n' > "$DOCTOR_INVALID_SMOKE"
cat > "$DOCTOR_CONFIG" <<'JSON'
{
  "schemaVersion": 1,
  "android": {
    "smokeScenario": "traces/demo-invalid-smoke-scenario.json"
  },
  "ios": {
    "smokeScenario": "./definitely-missing-ios-smoke.json"
  },
  "tools": {
    "adbPath": "./tests/fake-adb.sh",
    "xcrunPath": "./tests/fake-xcrun.sh"
  }
}
JSON
DOCTOR_CONFIG_JSON="$(./zig-out/bin/zmr doctor --json --config "$DOCTOR_CONFIG")"
printf '%s\n' "$DOCTOR_CONFIG_JSON"
case "$DOCTOR_CONFIG_JSON" in
  *'"name":"ios-smoke-scenario"'*'"hint":"Run npx zmr-wizard'*'ios.smokeScenario'*)
    ;;
  *)
    echo "expected doctor --config to include ios.smokeScenario remediation hint" >&2
    exit 1
    ;;
esac
case "$DOCTOR_CONFIG_JSON" in
  *'"name":"android-smoke-scenario"'*'scenario.invalid'*'"hint":"Run zmr validate on the configured Android smoke scenario'*)
    ;;
  *)
    echo "expected doctor --config to include android smoke scenario validation hint" >&2
    exit 1
    ;;
esac

echo
echo "== Devices: fake Android =="
./zig-out/bin/zmr devices --adb ./tests/fake-adb.sh
./zig-out/bin/zmr devices --json --adb ./tests/fake-adb.sh

echo
echo "== Devices: fake iOS simulator =="
./zig-out/bin/zmr devices --platform ios --xcrun ./tests/fake-xcrun.sh
./zig-out/bin/zmr devices --json --platform ios --xcrun ./tests/fake-xcrun.sh

echo
echo "== Init an app-local .zmr workspace =="
rm -rf traces/demo-init-app
./zig-out/bin/zmr init --app --json --dir traces/demo-init-app --app-id com.example.demoapp
(
  cd traces/demo-init-app
  "$ROOT/zig-out/bin/zmr" validate .zmr/android-smoke.json
  "$ROOT/zig-out/bin/zmr" validate .zmr/ios-smoke.json
  "$ROOT/zig-out/bin/zmr" doctor --strict --json \
    --config .zmr/config.json \
    --adb "$ROOT/tests/fake-adb.sh" \
    --xcrun "$ROOT/tests/fake-xcrun.sh"
)

echo
echo "== Import a mobile-flow YAML scenario =="
cat > traces/demo-flow-yaml-flow.yaml <<'YAML'
appId: com.example.demoapp
name: Imported demo smoke
---
- launchApp
- tapOn: "Sign in"
- inputText: "agent@example.com"
- hideKeyboard
- assertVisible:
    id: dashboard-title
- takeScreenshot: "after-import"
YAML
./zig-out/bin/zmr import maestro traces/demo-flow-yaml-flow.yaml --out traces/demo-imported-flow.json --json
./zig-out/bin/zmr validate traces/demo-imported-flow.json

rm -rf traces/demo-fake-android traces/demo-config-redaction traces/demo-failure traces/demo-device-matrix traces/demo-android-shim traces/demo-fake-ios traces/demo-ios-shim traces/demo-rpc-session traces/demo-typescript-client traces/demo-python-client traces/demo-swift-client traces/demo-kotlin-client traces/demo-go-client traces/demo-rust-client traces/demo-fake-android.zmrtrace traces/demo-fake-android-redacted.zmrtrace
rm -rf traces/demo-android-shim.zmrtrace traces/demo-android-shim-redacted.zmrtrace traces/demo-fake-ios.zmrtrace traces/demo-fake-ios-redacted.zmrtrace traces/demo-ios-shim.zmrtrace traces/demo-ios-shim-redacted.zmrtrace traces/demo-rpc-session-redacted.zmrtrace traces/demo-typescript-client-redacted.zmrtrace traces/demo-python-client-redacted.zmrtrace traces/demo-swift-client-redacted.zmrtrace traces/demo-kotlin-client-redacted.zmrtrace traces/demo-go-client-redacted.zmrtrace traces/demo-rust-client-redacted.zmrtrace
rm -f traces/demo-redaction-config.json traces/demo-doctor-config.json traces/demo-bad-config.json traces/demo-doctor-strict.json traces/demo-invalid-smoke-scenario.json traces/demo-device-matrix.json traces/demo-fake-adb-empty.sh traces/demo-fake-xcrun-empty.sh traces/demo-flow-yaml-flow.yaml traces/demo-imported-flow.json

echo
echo "== Run fake Android auth probe =="
./zig-out/bin/zmr run examples/demo-fake.json \
  --device fake-android-1 \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-fake-android \
  --json
tail -n 5 traces/demo-fake-android/events.jsonl

echo
echo "== Export fake Android trace bundle =="
./zig-out/bin/zmr export traces/demo-fake-android --out traces/demo-fake-android.zmrtrace
./zig-out/bin/zmr export traces/demo-fake-android --out traces/demo-fake-android-redacted.zmrtrace --redact

echo
echo "== Run fake Android/iOS device matrix =="
cat > traces/demo-device-matrix.json <<'JSON'
{
  "runs": 1,
  "appId": "com.example.mobiletest",
  "devices": [
    {
      "name": "android-fake",
      "platform": "android",
      "serial": "fake-android-1",
      "scenario": "examples/demo-fake.json",
      "adb": "./tests/fake-adb.sh"
    },
    {
      "name": "ios-simulator-fake",
      "platform": "ios",
      "iosDeviceType": "simulator",
      "serial": "fake-ios-1",
      "scenario": "examples/ios-smoke.json",
      "xcrun": "./tests/fake-xcrun.sh",
      "iosShim": "./tests/fake-ios-shim.sh"
    },
    {
      "name": "ios-physical-fake",
      "platform": "ios",
      "iosDeviceType": "physical",
      "serial": "fake-physical-ios-1",
      "scenario": "examples/ios-shim-smoke.json",
      "xcrun": "./tests/fake-xcrun.sh",
      "iosShim": "./tests/fake-ios-shim.sh"
    }
  ]
}
JSON
./scripts/device-matrix.sh \
  --matrix traces/demo-device-matrix.json \
  --trace-root traces/demo-device-matrix \
  --min-pass-rate 100 \
  --max-failures 0
cat traces/demo-device-matrix/summary.json

echo
echo "== Run config-driven trace redaction demo =="
cat > traces/demo-redaction-config.json <<'JSON'
{
  "schemaVersion": 1,
  "redaction": {
    "denylistResourceIds": ["password-input"],
    "allowlistResourceIds": ["e2e-auth-probe-marker"]
  }
}
JSON
./zig-out/bin/zmr run examples/demo-fake.json \
  --config traces/demo-redaction-config.json \
  --device fake-android-1 \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-config-redaction
grep -R -F -q '"resourceId":"[REDACTED:resourceId]"' traces/demo-config-redaction/artifacts

echo
echo "== Explain a fake failing trace =="
mkdir -p traces/demo-failure
if ./zig-out/bin/zmr run examples/demo-failure.json \
  --device fake-android-1 \
  --adb ./tests/fake-adb.sh \
  --trace-dir traces/demo-failure \
  --json \
  2> traces/demo-failure/expected-error.log; then
  echo "expected demo failure scenario to fail" >&2
  exit 1
fi
./zig-out/bin/zmr explain traces/demo-failure
./zig-out/bin/zmr explain traces/demo-failure --json

echo
echo "== Run fake JSON-RPC agent session with live trace export =="
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"session.create","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"runner.capabilities","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"app.openLink","params":{"url":"exampleapp://e2e-auth?probe=1"}}' \
  '{"jsonrpc":"2.0","id":4,"method":"observe.snapshot","params":{}}' \
  '{"jsonrpc":"2.0","id":5,"method":"trace.events","params":{"afterSeq":0,"limit":20}}' \
  '{"jsonrpc":"2.0","id":6,"method":"trace.export","params":{"out":"traces/demo-rpc-session-redacted.zmrtrace","redact":true}}' \
  | ./zig-out/bin/zmr serve \
      --transport stdio \
      --device fake-android-1 \
      --app-id com.example.mobiletest \
      --adb ./tests/fake-adb.sh \
      --trace-dir traces/demo-rpc-session
tail -n 5 traces/demo-rpc-session/events.jsonl

echo
echo "== Run TypeScript reference client against zmr serve fake-device backend =="
node clients/typescript/examples/fake-session.mjs
tail -n 5 traces/demo-typescript-client/events.jsonl

echo
echo "== Run Python reference client against zmr serve fake-device backend =="
python3 clients/python/examples/fake_session.py
tail -n 5 traces/demo-python-client/events.jsonl

echo
echo "== Run Swift reference client against zmr serve fake-device backend =="
(
  cd clients/swift
  swift run ZMRFakeSession \
    --zmr "$ROOT/zig-out/bin/zmr" \
    --adb "$ROOT/tests/fake-adb.sh" \
    --trace-dir "$ROOT/traces/demo-swift-client" \
    --trace-out "$ROOT/traces/demo-swift-client-redacted.zmrtrace"
)

echo
echo "== Run Kotlin reference client against zmr serve fake-device backend =="
if command -v gradle >/dev/null 2>&1; then
  gradle -p clients/kotlin runFakeSession \
    -Pzmr="$ROOT/zig-out/bin/zmr" \
    -Padb="$ROOT/tests/fake-adb.sh" \
    -PtraceDir="$ROOT/traces/demo-kotlin-client" \
    -PtraceOut="$ROOT/traces/demo-kotlin-client-redacted.zmrtrace"
else
  echo "skip kotlin demo: gradle not found"
fi

echo
echo "== Run Go reference client against zmr serve fake-device backend =="
(
  cd clients/go
  go run ./examples/fake-session \
    --zmr "$ROOT/zig-out/bin/zmr" \
    --adb "$ROOT/tests/fake-adb.sh" \
    --trace-dir "$ROOT/traces/demo-go-client" \
    --trace-out "$ROOT/traces/demo-go-client-redacted.zmrtrace"
)

echo
echo "== Run Rust reference client against zmr serve fake-device backend =="
cargo run --quiet \
  --manifest-path clients/rust/Cargo.toml \
  --example fake_session \
  -- \
  --zmr "$ROOT/zig-out/bin/zmr" \
  --adb "$ROOT/tests/fake-adb.sh" \
  --trace-dir "$ROOT/traces/demo-rust-client" \
  --trace-out "$ROOT/traces/demo-rust-client-redacted.zmrtrace"

echo
echo "== Run fake Android shim selector demo =="
./zig-out/bin/zmr run examples/android-shim-smoke.json \
  --device fake-android-1 \
  --adb ./tests/fake-adb.sh \
  --android-shim ./tests/fake-android-shim.sh \
  --trace-dir traces/demo-android-shim
tail -n 5 traces/demo-android-shim/events.jsonl

echo
echo "== Export fake Android shim trace bundle =="
./zig-out/bin/zmr export traces/demo-android-shim --out traces/demo-android-shim.zmrtrace
./zig-out/bin/zmr export traces/demo-android-shim --out traces/demo-android-shim-redacted.zmrtrace --redact

echo
echo "== Run fake iOS simulator smoke =="
./zig-out/bin/zmr run examples/ios-smoke.json \
  --platform ios \
  --device fake-ios-1 \
  --xcrun ./tests/fake-xcrun.sh \
  --ios-shim ./tests/fake-ios-shim.sh \
  --trace-dir traces/demo-fake-ios
tail -n 5 traces/demo-fake-ios/events.jsonl

echo
echo "== Export fake iOS simulator trace bundle =="
./zig-out/bin/zmr export traces/demo-fake-ios --out traces/demo-fake-ios.zmrtrace
./zig-out/bin/zmr export traces/demo-fake-ios --out traces/demo-fake-ios-redacted.zmrtrace --redact

echo
echo "== Run fake iOS shim selector demo =="
./zig-out/bin/zmr run examples/ios-shim-smoke.json \
  --platform ios \
  --device fake-ios-1 \
  --xcrun ./tests/fake-xcrun.sh \
  --ios-shim ./tests/fake-ios-shim.sh \
  --trace-dir traces/demo-ios-shim
tail -n 5 traces/demo-ios-shim/events.jsonl

echo
echo "== Export fake iOS shim trace bundle =="
./zig-out/bin/zmr export traces/demo-ios-shim --out traces/demo-ios-shim.zmrtrace
./zig-out/bin/zmr export traces/demo-ios-shim --out traces/demo-ios-shim-redacted.zmrtrace --redact

echo
echo "Demo traces:"
echo "  $ROOT/traces/demo-fake-android"
echo "  $ROOT/traces/demo-init-app"
echo "  $ROOT/traces/demo-failure"
echo "  $ROOT/traces/demo-device-matrix"
echo "  $ROOT/traces/demo-android-shim"
echo "  $ROOT/traces/demo-fake-ios"
echo "  $ROOT/traces/demo-ios-shim"
echo "  $ROOT/traces/demo-rpc-session"
echo "  $ROOT/traces/demo-typescript-client"
echo "  $ROOT/traces/demo-python-client"
echo "  $ROOT/traces/demo-swift-client"
echo "  $ROOT/traces/demo-kotlin-client"
echo "  $ROOT/traces/demo-go-client"
echo "  $ROOT/traces/demo-rust-client"
echo "  $ROOT/traces/demo-fake-android.zmrtrace"
echo "  $ROOT/traces/demo-fake-android-redacted.zmrtrace"
echo "  $ROOT/traces/demo-android-shim.zmrtrace"
echo "  $ROOT/traces/demo-android-shim-redacted.zmrtrace"
echo "  $ROOT/traces/demo-fake-ios.zmrtrace"
echo "  $ROOT/traces/demo-fake-ios-redacted.zmrtrace"
echo "  $ROOT/traces/demo-ios-shim.zmrtrace"
echo "  $ROOT/traces/demo-ios-shim-redacted.zmrtrace"
echo "  $ROOT/traces/demo-rpc-session-redacted.zmrtrace"
echo "  $ROOT/traces/demo-typescript-client-redacted.zmrtrace"
echo "  $ROOT/traces/demo-python-client-redacted.zmrtrace"
echo "  $ROOT/traces/demo-swift-client-redacted.zmrtrace"
echo "  $ROOT/traces/demo-kotlin-client-redacted.zmrtrace"
echo "  $ROOT/traces/demo-go-client-redacted.zmrtrace"
echo "  $ROOT/traces/demo-rust-client-redacted.zmrtrace"
echo "  $ROOT/viewer/index.html"
