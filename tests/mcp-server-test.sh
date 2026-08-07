#!/usr/bin/env bash
# End-to-end MCP exercise against the real binary, over the surface an agent
# actually uses: look at the screen, run a whole scenario, read the verdict.
#
# This replaces a per-action drive (install_app, tap, type, wait_visible, ...)
# because those tools no longer exist: actions are scenario steps now. The
# sequence below IS the agent loop the collapsed surface is built for.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tmp="$(mktemp)"
trace_dir="$(mktemp -d)"
trap 'rm -f "$tmp"; rm -rf "$trace_dir"' EXIT

cat <<'JSONL' | ./zig-out/bin/zmr mcp --device fake-android-1 --app-id com.example.mobiletest --adb ./tests/fake-adb.sh --trace-dir "$trace_dir" > "$tmp"
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"zmr-test","version":"1.0.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"semantic_snapshot","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"semantic_snapshot","arguments":{"compact":true}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"run_scenario","arguments":{"path":"examples/demo-fake.json"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"run_scenario","arguments":{"scenario":{"name":"inline probe","appId":"com.example.mobiletest","steps":[{"action":"launch"},{"action":"assertVisible","selector":{"text":"Sample landing."},"timeoutMs":1000}]}}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_scenario","arguments":{"path":"examples/demo-fake.json","scenario":{"name":"x","steps":[{"action":"launch"}]}}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"scenario_validate","arguments":{"path":"examples/demo-fake.json"}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"trace_explain","arguments":{}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"tap","arguments":{"selector":{"text":"Sample landing."}}}}
JSONL

python3 - "$tmp" <<'PY'
import json
import sys

path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == 10, rows

assert rows[0]["result"]["protocolVersion"] == "2024-11-05"
assert rows[0]["result"]["serverInfo"]["name"] == "zmr"

# The surface is deliberately small. src/mcp_protocol_tests.zig pins the exact
# set; here we assert the shape an agent sees from outside the process.
tool_names = sorted(tool["name"] for tool in rows[1]["result"]["tools"])
assert tool_names == sorted([
    "snapshot", "semantic_snapshot", "run_scenario", "scenario_validate",
    "trace_explain", "trace_discover", "trace_export",
]), tool_names

for gone in ["tap", "type", "swipe", "launch_app", "install_app", "wait_visible", "assert_visible"]:
    assert gone not in tool_names, gone

full = json.loads(rows[2]["result"]["content"][0]["text"])
assert full["activePackage"] == "com.example.mobiletest"
assert any(n["role"] == "button" and n["recommendedAction"] == "tap" for n in full["nodes"])
assert "Sample landing." in full["summary"]["visibleText"]

compact = json.loads(rows[3]["result"]["content"][0]["text"])
assert "uiSchema" in compact and "defaults" in compact["uiSchema"]
# Defaults are omitted from nodes; every emitted node keeps an addressable selector.
assert all("s" in n and "i" in n for n in compact["nodes"]), compact["nodes"][:2]
assert not any(n.get("e") is True for n in compact["nodes"])
compact_len = len(rows[3]["result"]["content"][0]["text"])
full_len = len(rows[2]["result"]["content"][0]["text"])
assert compact_len < full_len, (full_len, compact_len)
print(f"  semantic snapshot over MCP: {full_len} -> {compact_len} bytes "
      f"({100 - round(compact_len * 100 / full_len)}% smaller)")

# A whole scenario in one call, from a path...
by_path = json.loads(rows[4]["result"]["content"][0]["text"])
assert by_path["status"] == "passed", by_path
assert by_path["name"] == "ZMR fake Android auth probe demo"
assert by_path["stepCount"] == 4
assert by_path["traceDir"], by_path
assert by_path["nextCommands"] == ["trace_export"], by_path

# ...and inline, which is the same JSON an agent commits to .zmr/.
inline = json.loads(rows[5]["result"]["content"][0]["text"])
assert inline["status"] == "passed", inline
assert inline["name"] == "inline probe"
assert inline["stepCount"] == 2

# Two sources at once is refused: otherwise the evidence would describe one run
# while the agent reasoned about the other.
assert "error" in rows[6], rows[6]
assert "ConflictingScenarioSources" in json.dumps(rows[6]), rows[6]

validated = json.loads(rows[7]["result"]["content"][0]["text"])
assert validated["ok"] is True
assert validated["stepCount"] == 4

explained = json.loads(rows[8]["result"]["content"][0]["text"])
assert explained["traceDir"] == by_path["traceDir"], (explained, by_path)
assert "nextCommands" in explained

# Per-action tools are gone, and calling one must fail loudly rather than
# silently doing nothing.
assert "error" in rows[9], rows[9]
PY

printf 'mcp server surface verified\n'
