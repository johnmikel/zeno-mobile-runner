#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ZMR="$ROOT/zig-out/bin/zmr"
test -x "$ZMR"

TRACE_DIR="$TMPDIR/trace"
mkdir -p "$TRACE_DIR/artifacts"
cat > "$TRACE_DIR/trace.json" <<'JSON'
{"schemaVersion":1,"runnerVersion":"0.2.8","protocolVersion":"2026-04-28","scenarioName":"agent discovery","appId":"com.example.mobiletest","status":"passed","startedAtMs":1,"endedAtMs":2,"durationMs":1,"failedStepIndex":null,"error":null,"eventsPath":"events.jsonl","artifactsDir":"artifacts","eventCount":3,"snapshotCount":1,"partialFailureCount":0,"reportPath":null}
JSON
cat > "$TRACE_DIR/events.jsonl" <<'JSONL'
{"seq":1,"timestampMs":1,"kind":"app.launch","payload":{"status":"ok"}}
{"seq":2,"timestampMs":2,"kind":"app.openLink","payload":{"status":"ok","url":"exampleapp://discover"}}
JSONL
cat > "$TRACE_DIR/artifacts/snapshot-1.json" <<'JSON'
{
  "id": "snapshot-1",
  "timestampMs": 2,
  "viewport": {"width": 390, "height": 844},
  "activePackage": "com.example.mobiletest",
  "activeActivity": ".MainActivity",
  "focusedNodeId": null,
  "nodes": [
    {
      "stableId": "rid:welcome-title:0",
      "className": "android.widget.TextView",
      "resourceId": "welcome-title",
      "text": "Welcome",
      "contentDesc": null,
      "bounds": {"x": 20, "y": 80, "width": 200, "height": 40},
      "enabled": true,
      "visible": true,
      "selected": false
    }
  ]
}
JSON

OUT="$TMPDIR/discovered.json"
"$ZMR" discover --from-trace "$TRACE_DIR" --out "$OUT" --include-actions --validate --json > "$TMPDIR/discover-output.json"

python3 - "$TMPDIR/discover-output.json" "$OUT" "$TRACE_DIR" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
scenario = json.load(open(sys.argv[2], encoding="utf-8"))
trace_dir = sys.argv[3]

assert result["ok"] is True
assert result["mode"] == "discover"
assert result["traceDir"] == trace_dir
assert result["out"] == sys.argv[2]
assert result["validated"] is True
assert result["validation"]["ok"] is True
assert result["validation"]["path"] == sys.argv[2]
assert result["validation"]["stepCount"] == len(scenario["steps"])
assert result["selectorCount"] == 1
assert result["stepCount"] >= 4
assert any("human review" in warning for warning in result["warnings"])
assert f"zmr validate --json {sys.argv[2]}" in result["nextCommands"]

actions = [step["action"] for step in scenario["steps"]]
assert actions[0:3] == ["launch", "openLink", "snapshot"], actions
assert scenario["steps"][1]["url"] == "exampleapp://discover"
assert scenario["steps"][-1]["selector"] == {"resourceId": "welcome-title"}
PY
