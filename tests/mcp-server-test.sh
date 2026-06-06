#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tmp="$(mktemp)"
trace_dir="$(mktemp -d)"
trap 'rm -f "$tmp"; rm -rf "$trace_dir"' EXIT

cat <<'JSONL' | ./zig-out/bin/zmr mcp --device fake-android-1 --app-id com.example.mobiletest --adb ./tests/fake-adb.sh --trace-dir "$trace_dir" > "$tmp"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"zmr-test","version":"1.0.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"install_app","arguments":{"path":"examples/demo-fake.json"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"clear_state","arguments":{}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"launch_app","arguments":{}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"open_link","arguments":{"url":"exampleapp://mcp-trace"}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"type","arguments":{"text":"mcp unscoped text"}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"press_back","arguments":{}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"semantic_snapshot","arguments":{}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"wait_visible","arguments":{"selector":{"text":"Sample landing."},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"wait_not_visible","arguments":{"selector":{"text":"Missing toast"},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"wait_any","arguments":{"selectors":[{"text":"Missing toast"},{"text":"Dashboard"}],"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"swipe","arguments":{"x1":500,"y1":900,"x2":500,"y2":300,"durationMs":250}}}
{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"hide_keyboard","arguments":{}}}
{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"erase_text","arguments":{"selector":{"id":"email-login-email-input"},"maxChars":12}}}
{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"scroll_until_visible","arguments":{"selector":{"text":"Invite a teammate"},"direction":"down","timeoutMs":1000}}}
{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"assert_visible","arguments":{"selector":{"text":"Sample landing."},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"assert_not_visible","arguments":{"selector":{"text":"Missing toast"},"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"assert_healthy","arguments":{"timeoutMs":1000}}}
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"scenario_validate","arguments":{"path":"examples/demo-fake.json"}}}
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"stop_app","arguments":{}}}
{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"trace_events","arguments":{"afterSeq":0,"limit":100}}}
{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"trace_explain","arguments":{}}}
JSONL

python3 - "$tmp" <<'PY'
import json
import sys

path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == 23, rows

assert rows[0]["result"]["protocolVersion"] == "2024-11-05"
assert rows[0]["result"]["serverInfo"]["name"] == "zmr"

tool_names = [tool["name"] for tool in rows[1]["result"]["tools"]]
for expected in ["snapshot", "semantic_snapshot", "install_app", "launch_app", "stop_app", "clear_state", "tap", "type", "press_back", "open_link", "swipe", "wait_visible", "wait_not_visible", "wait_any", "hide_keyboard", "erase_text", "scroll_until_visible", "assert_visible", "assert_not_visible", "assert_healthy", "scenario_validate", "trace_events", "trace_explain", "trace_discover", "trace_export"]:
    assert expected in tool_names, expected

for index in [2, 3, 4, 5, 6, 7]:
    lifecycle_text = rows[index]["result"]["content"][0]["text"]
    lifecycle_result = json.loads(lifecycle_text)
    assert lifecycle_result == {"ok": True}, lifecycle_result

semantic_text = rows[8]["result"]["content"][0]["text"]
semantic_snapshot = json.loads(semantic_text)
assert semantic_snapshot["activePackage"] == "com.example.mobiletest"
assert any(node["role"] == "button" and node["recommendedAction"] == "tap" for node in semantic_snapshot["nodes"])
assert any(node["role"] == "textbox" and node["recommendedAction"] == "type" for node in semantic_snapshot["nodes"])
assert "Sample landing." in semantic_snapshot["summary"]["visibleText"]

wait_text = rows[9]["result"]["content"][0]["text"]
wait_result = json.loads(wait_text)
assert wait_result == {"visible": True}

gone_text = rows[10]["result"]["content"][0]["text"]
gone_result = json.loads(gone_text)
assert gone_result == {"visible": False}

any_text = rows[11]["result"]["content"][0]["text"]
any_result = json.loads(any_text)
assert any_result == {"matchedIndex": 1}

for index in [12, 13, 14]:
    action_text = rows[index]["result"]["content"][0]["text"]
    action_result = json.loads(action_text)
    assert action_result == {"ok": True}, action_result

scroll_text = rows[15]["result"]["content"][0]["text"]
scroll_result = json.loads(scroll_text)
assert scroll_result == {"visible": True}

for index in [16, 17, 18]:
    assertion_text = rows[index]["result"]["content"][0]["text"]
    assertion_result = json.loads(assertion_text)
    assert assertion_result == {"ok": True}, assertion_result

validate_text = rows[19]["result"]["content"][0]["text"]
validate_result = json.loads(validate_text)
assert validate_result["ok"] is True
assert validate_result["path"] == "examples/demo-fake.json"
assert validate_result["stepCount"] == 4

stop_text = rows[20]["result"]["content"][0]["text"]
stop_result = json.loads(stop_text)
assert stop_result == {"ok": True}, stop_result

trace_text = rows[21]["result"]["content"][0]["text"]
trace_result = json.loads(trace_text)
events = trace_result["events"]
assert any(event["kind"] == "app.openLink" and event["payload"]["url"] == "exampleapp://mcp-trace" for event in events)
assert any(event["kind"] == "ui.type" and event["payload"]["text"] == "mcp unscoped text" for event in events)
assert any(event["kind"] == "ui.pressBack" and event["payload"]["status"] == "ok" for event in events)

explain_text = rows[22]["result"]["content"][0]["text"]
explain_result = json.loads(explain_text)
assert explain_result["traceDir"] == trace_result["traceDir"]
assert explain_result["scenario"] == "mcp session"
assert explain_result["status"] == "running"
assert "nextCommands" in explain_result
PY
