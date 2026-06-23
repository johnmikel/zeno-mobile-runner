#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMR="$ROOT/zig-out/bin/zmr"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

VALID_OUTPUT="$("$ZMR" validate "$ROOT/examples/demo-fake.json" --json)"
grep -q '"ok":true' <<< "$VALID_OUTPUT"
grep -q '"path":"'"$ROOT"'/examples/demo-fake.json"' <<< "$VALID_OUTPUT"
grep -q '"name":"ZMR fake Android auth probe demo"' <<< "$VALID_OUTPUT"
if ! grep -q '"appId":"com.example.mobiletest"' <<< "$VALID_OUTPUT"; then
  echo "validate --json should include appId for valid scenarios" >&2
  echo "$VALID_OUTPUT" >&2
  exit 1
fi
grep -q '"stepCount":4' <<< "$VALID_OUTPUT"
grep -q '"nextCommands":\["zmr run '"$ROOT"'/examples/demo-fake.json --json --trace-dir traces/zmr-run"\]' <<< "$VALID_OUTPUT"

mkdir -p "$TMPDIR/agent handoff"
cat > "$TMPDIR/agent handoff/login smoke.json" <<'JSON'
{
  "name": "login smoke",
  "appId": "com.example.mobiletest",
  "steps": [
    { "action": "assertHealthy", "timeoutMs": 0 }
  ]
}
JSON

HANDOFF_OUTPUT="$("$ZMR" validate "$TMPDIR/agent handoff/login smoke.json" --json)"
if ! grep -q "\"nextCommands\":\[\"zmr run '$TMPDIR/agent handoff/login smoke.json' --json --trace-dir traces/zmr-run\"\]" <<< "$HANDOFF_OUTPUT"; then
  echo "validate --json should include a shell-quoted run handoff for paths with spaces" >&2
  echo "$HANDOFF_OUTPUT" >&2
  exit 1
fi

cat > "$TMPDIR/assert-none-visible.json" <<'JSON'
{
  "name": "guard app errors",
  "steps": [
    {
      "action": "assertNoneVisible",
      "selectors": [
        { "textContains": "Uncaught Error" },
        { "textContains": "Application has crashed" }
      ],
      "timeoutMs": 0
    }
  ]
}
JSON

ASSERT_NONE_OUTPUT="$("$ZMR" validate "$TMPDIR/assert-none-visible.json" --json)"
grep -q '"ok":true' <<< "$ASSERT_NONE_OUTPUT"
grep -q '"name":"guard app errors"' <<< "$ASSERT_NONE_OUTPUT"

cat > "$TMPDIR/assert-healthy.json" <<'JSON'
{
  "name": "guard app health",
  "steps": [
    { "action": "assertHealthy", "timeoutMs": 0 }
  ]
}
JSON

ASSERT_HEALTHY_OUTPUT="$("$ZMR" validate "$TMPDIR/assert-healthy.json" --json)"
grep -q '"ok":true' <<< "$ASSERT_HEALTHY_OUTPUT"
grep -q '"name":"guard app health"' <<< "$ASSERT_HEALTHY_OUTPUT"

cat > "$TMPDIR/set-location.json" <<'JSON'
{
  "name": "set simulator location",
  "steps": [
    { "action": "setLocation", "latitude": 51.5074, "longitude": -0.1278 }
  ]
}
JSON

SET_LOCATION_OUTPUT="$("$ZMR" validate "$TMPDIR/set-location.json" --json)"
grep -q '"ok":true' <<< "$SET_LOCATION_OUTPUT"
grep -q '"name":"set simulator location"' <<< "$SET_LOCATION_OUTPUT"

cat > "$TMPDIR/set-location-bad-latitude.json" <<'JSON'
{
  "name": "bad simulator location",
  "steps": [
    { "action": "setLocation", "latitude": "London", "longitude": -0.1278 }
  ]
}
JSON

set +e
SET_LOCATION_BAD_LATITUDE_OUTPUT="$("$ZMR" validate "$TMPDIR/set-location-bad-latitude.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a non-numeric setLocation latitude" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$SET_LOCATION_BAD_LATITUDE_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$SET_LOCATION_BAD_LATITUDE_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$SET_LOCATION_BAD_LATITUDE_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].latitude"' <<< "$SET_LOCATION_BAD_LATITUDE_OUTPUT"

cat > "$TMPDIR/set-location-out-of-range.json" <<'JSON'
{
  "name": "bad simulator location",
  "steps": [
    { "action": "setLocation", "latitude": 91, "longitude": -0.1278 }
  ]
}
JSON

set +e
SET_LOCATION_OUT_OF_RANGE_OUTPUT="$("$ZMR" validate "$TMPDIR/set-location-out-of-range.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for an out-of-range setLocation latitude" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$SET_LOCATION_OUT_OF_RANGE_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$SET_LOCATION_OUT_OF_RANGE_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$SET_LOCATION_OUT_OF_RANGE_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].latitude"' <<< "$SET_LOCATION_OUT_OF_RANGE_OUTPUT"

cat > "$TMPDIR/bad.json" <<'JSON'
{"name":"bad"}
JSON

set +e
INVALID_OUTPUT="$("$ZMR" validate "$TMPDIR/bad.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for invalid scenario" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$INVALID_OUTPUT"
grep -q '"path":"'"$TMPDIR"'/bad.json"' <<< "$INVALID_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$INVALID_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$INVALID_OUTPUT"
grep -q '"fieldPath":"$.steps"' <<< "$INVALID_OUTPUT"

cat > "$TMPDIR/missing-selector.json" <<'JSON'
{"name":"bad","steps":[{"action":"tap"}]}
JSON

set +e
MISSING_SELECTOR_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-selector.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing selector" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_SELECTOR_OUTPUT"
grep -q '"errorCode":"selector.invalid"' <<< "$MISSING_SELECTOR_OUTPUT"
grep -q '"message":"selector is invalid"' <<< "$MISSING_SELECTOR_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].selector"' <<< "$MISSING_SELECTOR_OUTPUT"

cat > "$TMPDIR/unknown-action.json" <<'JSON'
{"name":"bad","steps":[{"action":"tapp"}]}
JSON

set +e
UNKNOWN_ACTION_OUTPUT="$("$ZMR" validate "$TMPDIR/unknown-action.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for an unknown action" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$UNKNOWN_ACTION_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$UNKNOWN_ACTION_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$UNKNOWN_ACTION_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].action"' <<< "$UNKNOWN_ACTION_OUTPUT"
grep -q '"line":1' <<< "$UNKNOWN_ACTION_OUTPUT"
grep -q '"column":25' <<< "$UNKNOWN_ACTION_OUTPUT"

cat > "$TMPDIR/unknown-direction.json" <<'JSON'
{"name":"bad","steps":[{"action":"scrollUntilVisible","selector":{"text":"Dashboard"},"direction":"sideways"}]}
JSON

set +e
UNKNOWN_DIRECTION_OUTPUT="$("$ZMR" validate "$TMPDIR/unknown-direction.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for an unknown scroll direction" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$UNKNOWN_DIRECTION_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$UNKNOWN_DIRECTION_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$UNKNOWN_DIRECTION_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].direction"' <<< "$UNKNOWN_DIRECTION_OUTPUT"
grep -q '"line":1' <<< "$UNKNOWN_DIRECTION_OUTPUT"

cat > "$TMPDIR/missing-url.json" <<'JSON'
{"name":"bad","steps":[{"action":"openLink"}]}
JSON

set +e
MISSING_URL_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-url.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing openLink url" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_URL_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_URL_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_URL_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].url"' <<< "$MISSING_URL_OUTPUT"

cat > "$TMPDIR/missing-text.json" <<'JSON'
{"name":"bad","steps":[{"action":"typeText","selector":{"resourceId":"email-input"}}]}
JSON

set +e
MISSING_TEXT_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-text.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing typeText text value" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_TEXT_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_TEXT_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_TEXT_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].text"' <<< "$MISSING_TEXT_OUTPUT"

cat > "$TMPDIR/missing-x1.json" <<'JSON'
{"name":"bad","steps":[{"action":"swipe","y1":1,"x2":2,"y2":3}]}
JSON

set +e
MISSING_X1_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-x1.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing swipe x1 value" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_X1_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_X1_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_X1_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].x1"' <<< "$MISSING_X1_OUTPUT"

cat > "$TMPDIR/missing-y1.json" <<'JSON'
{"name":"bad","steps":[{"action":"swipe","x1":1,"x2":2,"y2":3}]}
JSON

set +e
MISSING_Y1_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-y1.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing swipe y1 value" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_Y1_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_Y1_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_Y1_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].y1"' <<< "$MISSING_Y1_OUTPUT"

cat > "$TMPDIR/missing-x2.json" <<'JSON'
{"name":"bad","steps":[{"action":"swipe","x1":1,"y1":2,"y2":3}]}
JSON

set +e
MISSING_X2_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-x2.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing swipe x2 value" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_X2_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_X2_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_X2_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].x2"' <<< "$MISSING_X2_OUTPUT"

cat > "$TMPDIR/missing-y2.json" <<'JSON'
{"name":"bad","steps":[{"action":"swipe","x1":1,"y1":2,"x2":3}]}
JSON

set +e
MISSING_Y2_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-y2.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing swipe y2 value" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_Y2_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_Y2_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_Y2_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].y2"' <<< "$MISSING_Y2_OUTPUT"

cat > "$TMPDIR/missing-latitude.json" <<'JSON'
{"name":"bad","steps":[{"action":"setLocation","longitude":-0.1278}]}
JSON

set +e
MISSING_LATITUDE_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-latitude.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing setLocation latitude value" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_LATITUDE_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_LATITUDE_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_LATITUDE_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].latitude"' <<< "$MISSING_LATITUDE_OUTPUT"

cat > "$TMPDIR/missing-longitude.json" <<'JSON'
{"name":"bad","steps":[{"action":"setLocation","latitude":51.5074}]}
JSON

set +e
MISSING_LONGITUDE_OUTPUT="$("$ZMR" validate "$TMPDIR/missing-longitude.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for a missing setLocation longitude value" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MISSING_LONGITUDE_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MISSING_LONGITUDE_OUTPUT"
grep -q '"message":"scenario is invalid"' <<< "$MISSING_LONGITUDE_OUTPUT"
grep -q '"fieldPath":"$.steps\[\].longitude"' <<< "$MISSING_LONGITUDE_OUTPUT"

printf '{"name":"bad","steps":[' > "$TMPDIR/malformed.json"

set +e
MALFORMED_OUTPUT="$("$ZMR" validate "$TMPDIR/malformed.json" --json)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected validate --json to exit non-zero for malformed scenario JSON" >&2
  exit 1
fi

grep -q '"ok":false' <<< "$MALFORMED_OUTPUT"
grep -q '"errorCode":"scenario.invalid"' <<< "$MALFORMED_OUTPUT"
grep -q '"message":"malformed scenario json"' <<< "$MALFORMED_OUTPUT"
grep -q '"line":1' <<< "$MALFORMED_OUTPUT"
grep -q '"column":24' <<< "$MALFORMED_OUTPUT"

test -f "$ROOT/schemas/validate-output.schema.json"
