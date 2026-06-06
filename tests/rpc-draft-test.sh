#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ZMR="$ROOT/zig-out/bin/zmr"
test -x "$ZMR"

TRACE_DIR="$TMPDIR/rpc-trace"
OUT="$TMPDIR/replay.json"

cat <<'JSONL' | "$ZMR" serve \
  --transport stdio \
  --device fake-android-1 \
  --app-id com.example.mobiletest \
  --adb "$ROOT/tests/fake-adb.sh" \
  --trace-dir "$TRACE_DIR" > "$TMPDIR/rpc.out"
{"jsonrpc":"2.0","id":1,"method":"session.create","params":{}}
{"jsonrpc":"2.0","id":2,"method":"app.launch","params":{}}
{"jsonrpc":"2.0","id":3,"method":"app.openLink","params":{"url":"exampleapp://agent-replay"}}
{"jsonrpc":"2.0","id":4,"method":"observe.semanticSnapshot","params":{}}
JSONL

"$ZMR" draft --from-trace "$TRACE_DIR" --out "$OUT" --include-actions --json > "$TMPDIR/draft.json"

python3 - "$TMPDIR/draft.json" "$OUT" "$TRACE_DIR" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
scenario = json.load(open(sys.argv[2], encoding="utf-8"))
trace_dir = sys.argv[3]

assert result["ok"] is True
assert result["traceDir"] == trace_dir
assert result["selectorCount"] >= 1
assert result["stepCount"] >= 4

actions = [step["action"] for step in scenario["steps"]]
assert actions[0:3] == ["launch", "openLink", "snapshot"], actions
assert scenario["steps"][1]["url"] == "exampleapp://agent-replay"
assert any(step["action"] == "assertVisible" for step in scenario["steps"])
PY
