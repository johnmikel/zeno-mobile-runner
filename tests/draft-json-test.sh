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
{"schemaVersion":1,"runnerVersion":"0.1.7","protocolVersion":"2026-04-28","scenarioName":"login smoke","appId":"com.example.mobiletest","status":"passed","startedAtMs":1,"endedAtMs":2,"durationMs":1,"failedStepIndex":null,"error":null,"eventsPath":"events.jsonl","artifactsDir":"artifacts","eventCount":3,"snapshotCount":2,"partialFailureCount":0,"reportPath":null}
JSON
cat > "$TRACE_DIR/events.jsonl" <<'JSONL'
{"seq":1,"timestampMs":1,"kind":"scenario.start","payload":{"value":"login smoke"}}
{"seq":2,"timestampMs":2,"kind":"app.launch","payload":{"status":"ok"}}
{"seq":3,"timestampMs":3,"kind":"app.openLink","payload":{"status":"ok","url":"exampleapp://login"}}
{"seq":4,"timestampMs":4,"kind":"wait.visible","payload":{"status":"ok","selector":{"text":"Email"}}}
{"seq":5,"timestampMs":5,"kind":"ui.tap","payload":{"status":"ok","selector":{"text":"Email"}}}
{"seq":6,"timestampMs":6,"kind":"ui.type","payload":{"status":"ok","selector":{"text":"Email"},"text":"agent name"}}
{"seq":7,"timestampMs":7,"kind":"ui.type","payload":{"status":"ok","selector":{"text":"Password"},"text":"[REDACTED:secret]"}}
{"seq":8,"timestampMs":8,"kind":"ui.swipe","payload":{"status":"ok"}}
{"seq":9,"timestampMs":9,"kind":"scenario.end","payload":{"value":"login smoke","status":"passed"}}
JSONL
cat > "$TRACE_DIR/artifacts/snapshot-2.json" <<'JSON'
{
  "id": "snapshot-2",
  "timestampMs": 2,
  "viewport": {"width": 390, "height": 844},
  "activePackage": "com.example.mobiletest",
  "activeActivity": ".MainActivity",
  "focusedNodeId": null,
  "nodes": [
    {
      "id": "primary",
      "role": "button",
      "name": "Continue",
      "selector": {"resourceId": "com.example.mobiletest:id/continue_button", "text": "Continue"},
      "source": {"className": "android.widget.Button", "resourceId": "com.example.mobiletest:id/continue_button", "text": "Continue", "contentDesc": null},
      "bounds": {"x": 16, "y": 720, "width": 358, "height": 48, "centerX": 195, "centerY": 744},
      "enabled": true,
      "visible": true,
      "selected": false,
      "interactive": true,
      "recommendedAction": "tap"
    },
    {
      "id": "title",
      "role": "text",
      "name": "Welcome",
      "selector": {"text": "Welcome"},
      "source": {"className": "android.widget.TextView", "resourceId": null, "text": "Welcome", "contentDesc": null},
      "bounds": {"x": 20, "y": 80, "width": 200, "height": 40, "centerX": 120, "centerY": 100},
      "enabled": true,
      "visible": true,
      "selected": false,
      "interactive": false,
      "recommendedAction": null
    }
  ],
  "summary": {"nodeCount": 2, "interactiveCount": 1, "visibleText": ["Continue", "Welcome"]}
}
JSON

OUT="$TMPDIR/draft.json"
"$ZMR" draft --from-trace "$TRACE_DIR" --out "$OUT" --json > "$TMPDIR/draft-output.json"

python3 - "$TMPDIR/draft-output.json" "$OUT" "$TRACE_DIR" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
scenario = json.load(open(sys.argv[2], encoding="utf-8"))
trace_dir = sys.argv[3]

assert result["ok"] is True
assert result["mode"] == "draft"
assert result["out"] == sys.argv[2]
assert result["traceDir"] == trace_dir
assert result["sourceSnapshot"] == f"{trace_dir}/artifacts/snapshot-2.json"
assert result["selectorCount"] == 2
assert result["stepCount"] == 4
assert result["replay"] == {
    "enabled": False,
    "eventCount": 0,
    "stepCount": 0,
    "skippedEventCount": 0,
}
assert any("human review" in warning for warning in result["warnings"])
assert f"zmr validate --json {sys.argv[2]}" in result["nextCommands"]

assert scenario["name"] == "draft from login smoke"
assert scenario["appId"] == "com.example.mobiletest"
assert [step["action"] for step in scenario["steps"]] == [
    "launch",
    "snapshot",
    "assertVisible",
    "assertVisible",
]
assert scenario["steps"][2]["selector"] == {"resourceId": "com.example.mobiletest:id/continue_button"}
assert scenario["steps"][3]["selector"] == {"text": "Welcome"}
assert not any(step["action"] == "tap" for step in scenario["steps"])
PY

OUT_ACTIONS="$TMPDIR/draft-actions.json"
"$ZMR" draft --from-trace "$TRACE_DIR" --out "$OUT_ACTIONS" --include-actions --json > "$TMPDIR/draft-actions-output.json"

python3 - "$TMPDIR/draft-actions-output.json" "$OUT_ACTIONS" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
scenario = json.load(open(sys.argv[2], encoding="utf-8"))

assert result["ok"] is True
assert result["selectorCount"] == 2
assert result["stepCount"] == 8
assert result["replay"] == {
    "enabled": True,
    "eventCount": 7,
    "stepCount": 5,
    "skippedEventCount": 2,
}
assert "unsupported trace action was skipped: ui.swipe" in result["warnings"]
assert "redacted trace text action was skipped: ui.type" in result["warnings"]

actions = [step["action"] for step in scenario["steps"]]
assert actions == [
    "launch",
    "openLink",
    "waitVisible",
    "tap",
    "typeText",
    "snapshot",
    "assertVisible",
    "assertVisible",
]
assert scenario["steps"][1]["url"] == "exampleapp://login"
assert scenario["steps"][2]["selector"] == {"text": "Email"}
assert scenario["steps"][4]["selector"] == {"text": "Email"}
assert scenario["steps"][4]["text"] == "agent name"
assert "[REDACTED:secret]" not in json.dumps(scenario)
assert not any(step["action"] == "swipe" for step in scenario["steps"])
PY
