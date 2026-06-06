#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat <<'JSONL' | ./zig-out/bin/zmr mcp --device fake-android-1 --app-id com.example.mobiletest --adb ./tests/fake-adb.sh > "$tmp"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"zmr-test","version":"1.0.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"semantic_snapshot","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"wait_visible","arguments":{"selector":{"text":"Sample landing."},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"scenario_validate","arguments":{"path":"examples/demo-fake.json"}}}
JSONL

python3 - "$tmp" <<'PY'
import json
import sys

path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == 5, rows

assert rows[0]["result"]["protocolVersion"] == "2024-11-05"
assert rows[0]["result"]["serverInfo"]["name"] == "zmr"

tool_names = [tool["name"] for tool in rows[1]["result"]["tools"]]
for expected in ["snapshot", "semantic_snapshot", "tap", "type", "press_back", "open_link", "wait_visible", "scenario_validate", "trace_events", "trace_discover", "trace_export"]:
    assert expected in tool_names, expected

semantic_text = rows[2]["result"]["content"][0]["text"]
semantic_snapshot = json.loads(semantic_text)
assert semantic_snapshot["activePackage"] == "com.example.mobiletest"
assert any(node["role"] == "button" and node["recommendedAction"] == "tap" for node in semantic_snapshot["nodes"])
assert any(node["role"] == "textbox" and node["recommendedAction"] == "type" for node in semantic_snapshot["nodes"])
assert "Sample landing." in semantic_snapshot["summary"]["visibleText"]

wait_text = rows[3]["result"]["content"][0]["text"]
wait_result = json.loads(wait_text)
assert wait_result == {"visible": True}

validate_text = rows[4]["result"]["content"][0]["text"]
validate_result = json.loads(validate_text)
assert validate_result["ok"] is True
assert validate_result["path"] == "examples/demo-fake.json"
assert validate_result["stepCount"] == 4
PY
