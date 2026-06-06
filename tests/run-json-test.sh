#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMR="$ROOT/zig-out/bin/zmr"
PASS_TRACE="$ROOT/traces/test-run-json pass"
DISCOVER_TRACE="$ROOT/traces/test-run-json-discover"
FAIL_TRACE="$ROOT/traces/test-run-json-fail"
PARTIAL_TRACE="$ROOT/traces/test-run-json-partial-ios"
OMIT_BUNDLE="$ROOT/traces/test-run-json-omit-screenshots.zmrtrace"
TMPDIR="$(mktemp -d)"
DISCOVER_OUT="$TMPDIR/discovered run.json"
trap 'rm -rf "$TMPDIR"' EXIT

rm -rf "$PASS_TRACE" "$DISCOVER_TRACE" "$FAIL_TRACE" "$PARTIAL_TRACE"
rm -f "$OMIT_BUNDLE"

PASS_OUTPUT="$("$ZMR" run "$ROOT/examples/demo-fake.json" \
  --device fake-android-1 \
  --adb "$ROOT/tests/fake-adb.sh" \
  --trace-dir "$PASS_TRACE" \
  --json)"
grep -q '"ok":true' <<< "$PASS_OUTPUT"
grep -q '"status":"passed"' <<< "$PASS_OUTPUT"
grep -q '"scenario":"ZMR fake Android auth probe demo"' <<< "$PASS_OUTPUT"
grep -q '"appId":"com.example.mobiletest"' <<< "$PASS_OUTPUT"
grep -q '"traceDir":' <<< "$PASS_OUTPUT"
grep -q '"eventsPath":"events.jsonl"' <<< "$PASS_OUTPUT"
grep -q '"eventCount":' <<< "$PASS_OUTPUT"
grep -q '"snapshotCount":' <<< "$PASS_OUTPUT"
if ! grep -q "\"nextCommands\":\[\"zmr report '$PASS_TRACE' --out '$PASS_TRACE/report.html'\",\"zmr explain '$PASS_TRACE' --json\",\"zmr discover --from-trace '$PASS_TRACE' --out .zmr/discovered/replay-smoke.json --include-actions --validate --force --json\",\"zmr export '$PASS_TRACE' --out '$PASS_TRACE.zmrtrace' --redact\"\]" <<< "$PASS_OUTPUT"; then
  echo "run --json should include executable trace and discovery follow-up commands" >&2
  echo "$PASS_OUTPUT" >&2
  exit 1
fi

DISCOVER_OUTPUT="$("$ZMR" run "$ROOT/examples/demo-fake.json" \
  --device fake-android-1 \
  --adb "$ROOT/tests/fake-adb.sh" \
  --trace-dir "$DISCOVER_TRACE" \
  --discover-out "$DISCOVER_OUT" \
  --json)"
grep -q '"ok":true' <<< "$DISCOVER_OUTPUT"
grep -q '"discovery":{"ok":true,"mode":"discover"' <<< "$DISCOVER_OUTPUT"
grep -q "\"out\":\"$DISCOVER_OUT\"" <<< "$DISCOVER_OUTPUT"
grep -q '"validated":true' <<< "$DISCOVER_OUTPUT"
grep -q '"validation":{"ok":true' <<< "$DISCOVER_OUTPUT"
test -f "$DISCOVER_OUT"
grep -q '"action":"openLink","url":"exampleapp://e2e-auth?probe=1"' "$DISCOVER_OUT"
grep -q '"action":"assertVisible","selector":{"text":"Sample landing."}' "$DISCOVER_OUT"

"$ZMR" export "$PASS_TRACE" --out "$OMIT_BUNDLE" --redact --omit-screenshots
if tar -tf "$OMIT_BUNDLE" | grep -q '[.]png$'; then
  echo "redacted export with --omit-screenshots should not include PNG screenshots" >&2
  exit 1
fi
tar -xOf "$OMIT_BUNDLE" trace.json | grep -q '"screenshots":"omitted"'
tar -xOf "$OMIT_BUNDLE" trace.json | grep -q '"screenshotsOmitted":true'
tar -xOf "$OMIT_BUNDLE" trace.json | grep -q '"screenshotsRedacted":false'

set +e
FAIL_OUTPUT="$("$ZMR" run "$ROOT/examples/demo-failure.json" \
  --device fake-android-1 \
  --adb "$ROOT/tests/fake-adb.sh" \
  --trace-dir "$FAIL_TRACE" \
  --json 2> "$FAIL_TRACE.expected-error.log")"
FAIL_STATUS=$?
set -e

if [[ "$FAIL_STATUS" -eq 0 ]]; then
  echo "expected failing scenario to keep non-zero exit status" >&2
  exit 1
fi
grep -q '"ok":false' <<< "$FAIL_OUTPUT"
grep -q '"status":"failed"' <<< "$FAIL_OUTPUT"
grep -q '"failedStepIndex":1' <<< "$FAIL_OUTPUT"
grep -q '"error":"WaitTimeout"' <<< "$FAIL_OUTPUT"
grep -q '"traceDir":' <<< "$FAIL_OUTPUT"

PARTIAL_SCENARIO="$TMPDIR/ios-partial-snapshot.json"
PARTIAL_SHIM="$TMPDIR/ios-shim-snapshot-fail.sh"
cat > "$PARTIAL_SCENARIO" <<'JSON'
{
  "name": "iOS partial snapshot smoke",
  "appId": "com.example.mobiletest",
  "steps": [{ "action": "snapshot" }]
}
JSON
cat > "$PARTIAL_SHIM" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
request="$(cat)"
case "$request" in
  *'"cmd":"snapshot"'*)
    echo "accessibility hierarchy unavailable" >&2
    exit 7
    ;;
  *) printf '{"status":"ok"}\n' ;;
esac
SH
chmod +x "$PARTIAL_SHIM"

PARTIAL_OUTPUT="$("$ZMR" run "$PARTIAL_SCENARIO" \
  --platform ios \
  --device fake-ios-1 \
  --xcrun "$ROOT/tests/fake-xcrun.sh" \
  --ios-shim "$PARTIAL_SHIM" \
  --trace-dir "$PARTIAL_TRACE" \
  --json)"
grep -q '"ok":false' <<< "$PARTIAL_OUTPUT"
grep -q '"status":"partial"' <<< "$PARTIAL_OUTPUT"
grep -q '"partialFailureCount":1' <<< "$PARTIAL_OUTPUT"
grep -q '"partialFailure":{"kind":"observe.snapshot.semanticExtraction","status":"failed","artifactStatus":"captured","semanticStatus":"failed"' <<< "$PARTIAL_OUTPUT"
grep -q '"source":"ios-xctest-shim"' <<< "$PARTIAL_OUTPUT"
grep -q '"snapshotCount":1' <<< "$PARTIAL_OUTPUT"
test -f "$PARTIAL_TRACE/artifacts/snapshot-1.png"

PARTIAL_EXPLAIN="$("$ZMR" explain --json "$PARTIAL_TRACE")"
grep -q '"status":"partial"' <<< "$PARTIAL_EXPLAIN"
grep -q '"diagnostic":{"kind":"observe.snapshot.semanticExtraction","status":"failed","artifactStatus":"captured","semanticStatus":"failed"' <<< "$PARTIAL_EXPLAIN"
grep -q '"source":"ios-xctest-shim"' <<< "$PARTIAL_EXPLAIN"

APP_ROOT="$TMPDIR/app"
mkdir -p "$APP_ROOT/.zmr"
printf '{\n  "name": "Config relative run smoke",\n  "appId": "com.example.mobiletest",\n  "steps": [{ "action": "snapshot" }]\n}\n' > "$APP_ROOT/.zmr/android-smoke.json"
printf '{\n  "schemaVersion": 1,\n  "appId": "com.example.mobiletest",\n  "android": {\n    "smokeScenario": ".zmr/android-smoke.json",\n    "traceDir": "traces/zmr-android"\n  }\n}\n' > "$APP_ROOT/.zmr/config.json"

CONFIG_OUTPUT="$("$ZMR" run \
  --config "$APP_ROOT/.zmr/config.json" \
  --device fake-android-1 \
  --adb "$ROOT/tests/fake-adb.sh" \
  --json)"

grep -q '"ok":true' <<< "$CONFIG_OUTPUT"
grep -q '"scenario":"Config relative run smoke"' <<< "$CONFIG_OUTPUT"
grep -q "$APP_ROOT/traces/zmr-android" <<< "$CONFIG_OUTPUT"
test -f "$APP_ROOT/traces/zmr-android/trace.json"
