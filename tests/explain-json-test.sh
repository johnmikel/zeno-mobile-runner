#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMR="$ROOT/zig-out/bin/zmr"
TRACE_DIR="$ROOT/traces/test-explain-json trace"

rm -rf "$TRACE_DIR"
mkdir -p "$TRACE_DIR"

if "$ZMR" run "$ROOT/examples/demo-failure.json" \
  --device fake-android-1 \
  --adb "$ROOT/tests/fake-adb.sh" \
  --trace-dir "$TRACE_DIR" \
  2> "$TRACE_DIR/expected-error.log"; then
  echo "expected demo failure scenario to fail" >&2
  exit 1
fi

OUTPUT="$("$ZMR" explain "$TRACE_DIR" --json)"
grep -q '"ok":true' <<< "$OUTPUT"
if ! grep -q '"traceDir":"'"$TRACE_DIR"'"' <<< "$OUTPUT"; then
  echo "explain --json should include traceDir" >&2
  echo "$OUTPUT" >&2
  exit 1
fi
grep -q '"scenario":"ZMR fake failure explanation demo"' <<< "$OUTPUT"
grep -q '"status":"failed"' <<< "$OUTPUT"
grep -q '"appId":"com.example.mobiletest"' <<< "$OUTPUT"
grep -q '"failedStepIndex":1' <<< "$OUTPUT"
grep -q '"error":"WaitTimeout"' <<< "$OUTPUT"
grep -q '"diagnostic":{"kind":"wait.visible","status":"timeout"' <<< "$OUTPUT"
grep -q '"snapshotId":"snapshot-1"' <<< "$OUTPUT"
grep -q '"activePackage":"com.example.mobiletest"' <<< "$OUTPUT"
grep -q '"visibleTexts":' <<< "$OUTPUT"
grep -q '"nearestTextMatches":' <<< "$OUTPUT"
grep -q '"lastEvent":"scenario.end"' <<< "$OUTPUT"
if ! grep -q "\"nextCommands\":\[\"zmr report '$TRACE_DIR' --out '$TRACE_DIR/report.html' --junit '$TRACE_DIR/junit.xml'\",\"zmr export '$TRACE_DIR' --out '$TRACE_DIR.zmrtrace' --redact\"\]" <<< "$OUTPUT"; then
  echo "explain --json should include executable trace follow-up commands" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

PREFIX_OUTPUT="$("$ZMR" explain --json "$TRACE_DIR")"
grep -q '"ok":true' <<< "$PREFIX_OUTPUT"
grep -q '"error":"WaitTimeout"' <<< "$PREFIX_OUTPUT"
