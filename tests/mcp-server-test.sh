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
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"wait_not_visible","arguments":{"selector":{"text":"Missing toast"},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"wait_any","arguments":{"selectors":[{"text":"Missing toast"},{"text":"Dashboard"}],"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"hide_keyboard","arguments":{}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"erase_text","arguments":{"selector":{"id":"email-login-email-input"},"maxChars":12}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"scroll_until_visible","arguments":{"selector":{"text":"Invite a teammate"},"direction":"down","timeoutMs":1000}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"assert_visible","arguments":{"selector":{"text":"Sample landing."},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"assert_not_visible","arguments":{"selector":{"text":"Missing toast"},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"assert_healthy","arguments":{"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"scenario_validate","arguments":{"path":"examples/demo-fake.json"}}}
JSONL

python3 - "$tmp" <<'PY'
import json
import sys

path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == 13, rows

assert rows[0]["result"]["protocolVersion"] == "2024-11-05"
assert rows[0]["result"]["serverInfo"]["name"] == "zmr"

tool_names = [tool["name"] for tool in rows[1]["result"]["tools"]]
for expected in ["snapshot", "semantic_snapshot", "tap", "type", "press_back", "open_link", "wait_visible", "wait_not_visible", "wait_any", "hide_keyboard", "erase_text", "scroll_until_visible", "assert_visible", "assert_not_visible", "assert_healthy", "scenario_validate", "trace_events", "trace_discover", "trace_export"]:
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

gone_text = rows[4]["result"]["content"][0]["text"]
gone_result = json.loads(gone_text)
assert gone_result == {"visible": False}

any_text = rows[5]["result"]["content"][0]["text"]
any_result = json.loads(any_text)
assert any_result == {"matchedIndex": 1}

for index in [6, 7]:
    action_text = rows[index]["result"]["content"][0]["text"]
    action_result = json.loads(action_text)
    assert action_result == {"ok": True}, action_result

scroll_text = rows[8]["result"]["content"][0]["text"]
scroll_result = json.loads(scroll_text)
assert scroll_result == {"visible": True}

for index in [9, 10, 11]:
    assertion_text = rows[index]["result"]["content"][0]["text"]
    assertion_result = json.loads(assertion_text)
    assert assertion_result == {"ok": True}, assertion_result

validate_text = rows[12]["result"]["content"][0]["text"]
validate_result = json.loads(validate_text)
assert validate_result["ok"] is True
assert validate_result["path"] == "examples/demo-fake.json"
assert validate_result["stepCount"] == 4
PY
