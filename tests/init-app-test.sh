#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ZMR="$ROOT/zig-out/bin/zmr"
test -x "$ZMR"

"$ZMR" init --app --dir "$TMPDIR/app" --app-id com.example.bootstrap > "$TMPDIR/init.out"

grep -q 'created .*/.zmr/config.json' "$TMPDIR/init.out"
grep -q 'created .*/.zmr/device-matrix.json' "$TMPDIR/init.out"
grep -q 'created .*/.zmr/AGENTS.md' "$TMPDIR/init.out"
grep -q 'next: zmr doctor --strict --json --config .*/.zmr/config.json' "$TMPDIR/init.out"
test -f "$TMPDIR/app/.zmr/config.json"
test -f "$TMPDIR/app/.zmr/android-smoke.json"
test -f "$TMPDIR/app/.zmr/ios-smoke.json"
test -f "$TMPDIR/app/.zmr/device-matrix.json"
test -f "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'traces/' "$TMPDIR/app/.gitignore"
grep -q '"appId": "com.example.bootstrap"' "$TMPDIR/app/.zmr/config.json"
grep -q 'App id: `com.example.bootstrap`' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'semantic_snapshot' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr inspect --json --dir .' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr schemas --json' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr discover --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --validate --json' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr explain traces/zmr-agent --json' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr report traces/zmr-android --out traces/zmr-android/report.html' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.bootstrap --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'traces/zmr-android-reliability/report.html' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr run .zmr/ios-smoke.json --platform ios --device booted --trace-dir traces/zmr-ios' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr report traces/zmr-ios --out traces/zmr-ios/report.html' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.bootstrap --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'traces/zmr-ios-reliability/report.html' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'Do not claim production readiness from smoke runs alone' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q '## App Commands' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q '"validate": "zmr validate --json .zmr/android-smoke.json && zmr validate --json .zmr/ios-smoke.json"' "$TMPDIR/app/.zmr/config.json"
grep -q '"androidReport": "zmr report traces/zmr-android --out traces/zmr-android/report.html"' "$TMPDIR/app/.zmr/config.json"
grep -q '"androidReliability": "export ZMR_BIN=\\"${ZMR_BIN:-zmr}\\"; zmr-benchmark --zmr .zmr/android-smoke.json --device emulator-5554 --app-id com.example.bootstrap --runs 20 --trace-root traces/zmr-android-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 30000 && \\"$ZMR_BIN\\" report traces/zmr-android-reliability --out traces/zmr-android-reliability/report.html"' "$TMPDIR/app/.zmr/config.json"
grep -q '"iosReport": "zmr report traces/zmr-ios --out traces/zmr-ios/report.html"' "$TMPDIR/app/.zmr/config.json"
grep -q '"iosReliability": "export ZMR_BIN=\\"${ZMR_BIN:-zmr}\\"; zmr-benchmark --zmr .zmr/ios-smoke.json --platform ios --device booted --app-id com.example.bootstrap --xcrun xcrun --runs 20 --trace-root traces/zmr-ios-reliability --min-pass-rate 100 --max-failures 0 --max-p95-ms 45000 && \\"$ZMR_BIN\\" report traces/zmr-ios-reliability --out traces/zmr-ios-reliability/report.html"' "$TMPDIR/app/.zmr/config.json"
grep -q '"explain": "zmr explain traces/zmr-agent --json"' "$TMPDIR/app/.zmr/config.json"
grep -q '"exportTrace": "zmr export traces/zmr-agent --out traces/zmr-agent-redacted.zmrtrace --redact"' "$TMPDIR/app/.zmr/config.json"
grep -q 'zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.bootstrap --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.bootstrap --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q 'zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json' "$TMPDIR/app/.zmr/AGENTS.md"
if grep -q 'npm run zmr:' "$TMPDIR/app/.zmr/AGENTS.md"; then
  echo "zmr init --app AGENTS.md should use direct commands, not package scripts" >&2
  exit 1
fi
grep -q '"action": "assertHealthy"' "$TMPDIR/app/.zmr/android-smoke.json"
grep -q '"action": "assertHealthy"' "$TMPDIR/app/.zmr/ios-smoke.json"
grep -q '"doctor": "zmr doctor --strict --json --config .zmr/config.json"' "$TMPDIR/app/.zmr/config.json"
grep -q '"schemas": "zmr schemas --json"' "$TMPDIR/app/.zmr/config.json"
grep -q -- '--android-app-id com.example.bootstrap' "$TMPDIR/app/.zmr/config.json"
grep -q -- '--android-device emulator-5554' "$TMPDIR/app/.zmr/config.json"
grep -q -- '--ios-app-id com.example.bootstrap' "$TMPDIR/app/.zmr/config.json"
grep -q -- '--ios-device booted' "$TMPDIR/app/.zmr/config.json"
grep -q '"readiness": "zmr-release-readiness --evidence traces/zmr-pilots/evidence.jsonl --target production --json"' "$TMPDIR/app/.zmr/config.json"
grep -q '"matrix": "ZMR_BIN=${ZMR_BIN:-zmr} zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --min-pass-rate 100 --max-failures 0"' "$TMPDIR/app/.zmr/config.json"
grep -q '"iosDeviceType": "simulator"' "$TMPDIR/app/.zmr/device-matrix.json"

"$ZMR" init --app --dir "$TMPDIR/space app" --app-id com.example.space > "$TMPDIR/init-space.out"
if ! grep -q "next: zmr doctor --strict --json --config '$TMPDIR/space app/.zmr/config.json'" "$TMPDIR/init-space.out"; then
  echo "init --app should shell quote next config path when --dir contains spaces" >&2
  cat "$TMPDIR/init-space.out" >&2
  exit 1
fi

"$ZMR" init --app --json --dir "$TMPDIR/json-app" --app-id com.example.json > "$TMPDIR/init.json"
grep -q '"ok":true' "$TMPDIR/init.json"
grep -q '"mode":"app"' "$TMPDIR/init.json"
grep -q '"appId":"com.example.json"' "$TMPDIR/init.json"
grep -q '"created":\[' "$TMPDIR/init.json"
grep -q '.zmr/AGENTS.md' "$TMPDIR/init.json"
grep -q '"configPath":"'"$TMPDIR"'/json-app/.zmr/config.json"' "$TMPDIR/init.json"
grep -q '"androidScenarioPath":"'"$TMPDIR"'/json-app/.zmr/android-smoke.json"' "$TMPDIR/init.json"
grep -q '"iosScenarioPath":"'"$TMPDIR"'/json-app/.zmr/ios-smoke.json"' "$TMPDIR/init.json"
grep -q '"deviceMatrixPath":"'"$TMPDIR"'/json-app/.zmr/device-matrix.json"' "$TMPDIR/init.json"
grep -q '"agentInstructionsPath":"'"$TMPDIR"'/json-app/.zmr/AGENTS.md"' "$TMPDIR/init.json"
grep -q '"next":"zmr doctor --strict --json --config '"$TMPDIR"'/json-app/.zmr/config.json"' "$TMPDIR/init.json"
grep -q '"nextCommands":\["zmr doctor --strict --json --config '"$TMPDIR"'/json-app/.zmr/config.json","zmr schemas --json","zmr validate --json '"$TMPDIR"'/json-app/.zmr/android-smoke.json","zmr validate --json '"$TMPDIR"'/json-app/.zmr/ios-smoke.json"\]' "$TMPDIR/init.json"
grep -q '"smokeCommands":\["zmr run '"$TMPDIR"'/json-app/.zmr/android-smoke.json --device emulator-5554 --trace-dir '"$TMPDIR"'/json-app/traces/zmr-android","zmr run '"$TMPDIR"'/json-app/.zmr/ios-smoke.json --platform ios --device booted --trace-dir '"$TMPDIR"'/json-app/traces/zmr-ios"\]' "$TMPDIR/init.json"
grep -q '"scriptCount":16' "$TMPDIR/init.json"
grep -q '"scriptNames":\["doctor","schemas","validate","android","androidReport","androidReliability","ios","iosReport","iosReliability","matrix","pilotGate","readiness","serve","mcp","explain","exportTrace"\]' "$TMPDIR/init.json"
test -f "$TMPDIR/json-app/.zmr/config.json"
test -f "$TMPDIR/json-app/.zmr/device-matrix.json"
test -f "$TMPDIR/json-app/.zmr/AGENTS.md"

"$ZMR" init "$TMPDIR/single-scenario.json" --app-id com.example.single --json > "$TMPDIR/init-scenario.json"
grep -q '"ok":true' "$TMPDIR/init-scenario.json"
grep -q '"mode":"scenario"' "$TMPDIR/init-scenario.json"
grep -q '"created":\["'"$TMPDIR"'/single-scenario.json"\]' "$TMPDIR/init-scenario.json"
grep -q '"nextCommands":\["zmr validate --json '"$TMPDIR"'/single-scenario.json","zmr run '"$TMPDIR"'/single-scenario.json --json --trace-dir traces/zmr-run"\]' "$TMPDIR/init-scenario.json"
grep -q '"action": "assertHealthy"' "$TMPDIR/single-scenario.json"
"$ZMR" validate "$TMPDIR/single-scenario.json"

"$ZMR" init "$TMPDIR/json scenario.json" --app-id com.example.jsonscenario --json > "$TMPDIR/init-space-scenario.json"
if ! grep -q "\"nextCommands\":\[\"zmr validate --json '$TMPDIR/json scenario.json'\",\"zmr run '$TMPDIR/json scenario.json' --json --trace-dir traces/zmr-run\"\]" "$TMPDIR/init-space-scenario.json"; then
  echo "scenario init --json should include shell-quoted validate and run handoffs" >&2
  cat "$TMPDIR/init-space-scenario.json" >&2
  exit 1
fi

"$ZMR" init "$TMPDIR/plain scenario.json" --app-id com.example.plain > "$TMPDIR/init-plain-scenario.out"
grep -q "created $TMPDIR/plain scenario.json" "$TMPDIR/init-plain-scenario.out"
if ! grep -q "next: zmr validate '$TMPDIR/plain scenario.json'" "$TMPDIR/init-plain-scenario.out"; then
  echo "plain init should print an executable next validation command" >&2
  cat "$TMPDIR/init-plain-scenario.out" >&2
  exit 1
fi

(
  cd "$TMPDIR/app"
  "$ZMR" validate .zmr/android-smoke.json
  "$ZMR" validate .zmr/ios-smoke.json
  "$ZMR" doctor --strict --json \
    --config .zmr/config.json \
    --adb "$ROOT/tests/fake-adb.sh" \
    --xcrun "$ROOT/tests/fake-xcrun.sh" > "$TMPDIR/doctor.json"
)

grep -q '"ok":true' "$TMPDIR/doctor.json"
grep -q '"name":"android-smoke-scenario"' "$TMPDIR/doctor.json"
grep -q '"name":"ios-smoke-scenario"' "$TMPDIR/doctor.json"
grep -q '"name":"config"' "$TMPDIR/doctor.json"
grep -q '"scriptCount":16' "$TMPDIR/doctor.json"
grep -q '"scriptNames":\["doctor","schemas","validate","android","androidReport","androidReliability","ios","iosReport","iosReliability","matrix","pilotGate","readiness","serve","mcp","explain","exportTrace"\]' "$TMPDIR/doctor.json"

python3 - <<PY
from pathlib import Path
path = Path("$TMPDIR/app/.zmr/android-smoke.json")
text = path.read_text()
path.write_text(text.replace("Android smoke", "Custom Android smoke"))
PY

"$ZMR" init --app --dir "$TMPDIR/app" --app-id com.example.other > "$TMPDIR/init-again.out"
grep -q '"appId": "com.example.other"' "$TMPDIR/app/.zmr/config.json"
grep -q '"appId": "com.example.other"' "$TMPDIR/app/.zmr/device-matrix.json"
grep -q 'App id: `com.example.other`' "$TMPDIR/app/.zmr/AGENTS.md"
grep -q '"name": "Custom Android smoke"' "$TMPDIR/app/.zmr/android-smoke.json"
grep -q '"appId": "com.example.bootstrap"' "$TMPDIR/app/.zmr/android-smoke.json"

"$ZMR" init --app --dir "$TMPDIR/app" --app-id com.example.other --force > "$TMPDIR/init-force.out"
grep -q '"appId": "com.example.other"' "$TMPDIR/app/.zmr/config.json"
grep -q '"name": "Android smoke"' "$TMPDIR/app/.zmr/android-smoke.json"
