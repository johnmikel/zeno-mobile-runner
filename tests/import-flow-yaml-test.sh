#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ZMR="$ROOT/zig-out/bin/zmr"
test -x "$ZMR"

mkdir -p "$TMPDIR/.zmr"

cat > "$TMPDIR/flow.yaml" <<'YAML'
appId: com.example.imported
name: Imported login smoke
---
- launchApp
- tapOn: "Sign in"
- inputText: "agent@example.com"
- hideKeyboard
- assertVisible:
    id: dashboard-title
- assertNotVisible: "Invalid password"
- openLink: "example://referral/demo"
- back
- scrollUntilVisible:
    element:
      text: "Invite a teammate"
    direction: DOWN
    timeout: 7000
- takeScreenshot: "after-login"
YAML

"$ZMR" import flow-yaml "$TMPDIR/flow.yaml" --out "$TMPDIR/.zmr/imported.json" --json > "$TMPDIR/import.json"

grep -q '"ok":true' "$TMPDIR/import.json"
grep -q '"format":"flow-yaml"' "$TMPDIR/import.json"
grep -q '"out":"'"$TMPDIR"'/.zmr/imported.json"' "$TMPDIR/import.json"
grep -q '"stepCount":10' "$TMPDIR/import.json"
grep -q '"nextCommands":\["zmr validate --json '"$TMPDIR"'/.zmr/imported.json","zmr run '"$TMPDIR"'/.zmr/imported.json --json --trace-dir traces/zmr-run"\]' "$TMPDIR/import.json"

"$ZMR" import maestro "$TMPDIR/flow.yaml" --out "$TMPDIR/.zmr/imported-maestro.json" --json > "$TMPDIR/import-maestro.json"
grep -q '"format":"maestro"' "$TMPDIR/import-maestro.json"
grep -q '"compatibility":{"source":"maestro-yaml","native":"zmr-json"' "$TMPDIR/import-maestro.json"
grep -q '"reviewRequired":true' "$TMPDIR/import-maestro.json"
grep -q '"unsupportedCommandPolicy":"fail-fast"' "$TMPDIR/import-maestro.json"
"$ZMR" validate "$TMPDIR/.zmr/imported-maestro.json"

"$ZMR" import flow-yaml "$TMPDIR/flow.yaml" --out "$TMPDIR/.zmr/imported flow.json" --json > "$TMPDIR/import-space.json"
if ! grep -q "\"nextCommands\":\[\"zmr validate --json '$TMPDIR/.zmr/imported flow.json'\",\"zmr run '$TMPDIR/.zmr/imported flow.json' --json --trace-dir traces/zmr-run\"\]" "$TMPDIR/import-space.json"; then
  echo "import --json should include shell-quoted validate and run handoffs" >&2
  cat "$TMPDIR/import-space.json" >&2
  exit 1
fi

"$ZMR" validate "$TMPDIR/.zmr/imported.json"

"$ZMR" import flow-yaml "$TMPDIR/flow.yaml" --out "$TMPDIR/.zmr/imported flow.json" --force > "$TMPDIR/import-plain.out"
grep -q "wrote $TMPDIR/.zmr/imported flow.json" "$TMPDIR/import-plain.out"
if ! grep -q "next: zmr validate '$TMPDIR/.zmr/imported flow.json'" "$TMPDIR/import-plain.out"; then
  echo "plain import should print an executable next validation command" >&2
  cat "$TMPDIR/import-plain.out" >&2
  exit 1
fi
"$ZMR" validate "$TMPDIR/.zmr/imported flow.json"

python3 - "$TMPDIR/.zmr/imported.json" <<'PY'
import json
import sys

scenario = json.load(open(sys.argv[1]))
assert scenario["name"] == "Imported login smoke"
assert scenario["appId"] == "com.example.imported"
assert [step["action"] for step in scenario["steps"]] == [
    "launch",
    "tap",
    "typeText",
    "hideKeyboard",
    "assertVisible",
    "assertNotVisible",
    "openLink",
    "pressBack",
    "scrollUntilVisible",
    "snapshot",
]
assert scenario["steps"][1]["selector"] == {"text": "Sign in"}
assert scenario["steps"][2]["text"] == "agent@example.com"
assert scenario["steps"][4]["selector"] == {"id": "dashboard-title"}
assert scenario["steps"][8]["selector"] == {"text": "Invite a teammate"}
assert scenario["steps"][8]["direction"] == "down"
assert scenario["steps"][8]["timeoutMs"] == 7000
PY

if "$ZMR" import flow-yaml "$TMPDIR/flow.yaml" --out "$TMPDIR/.zmr/imported.json" > "$TMPDIR/import-again.out" 2>&1; then
  echo "expected import to protect an existing output file without --force" >&2
  exit 1
fi

"$ZMR" import flow-yaml "$TMPDIR/flow.yaml" --out "$TMPDIR/.zmr/imported.json" --force > "$TMPDIR/import-force.out"
grep -q 'wrote .*/.zmr/imported.json' "$TMPDIR/import-force.out"
