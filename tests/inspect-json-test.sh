#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ZMR="$ROOT/zig-out/bin/zmr"
test -x "$ZMR"

"$ZMR" init --app --dir "$TMPDIR/app" --app-id com.example.inspect >/dev/null
"$ZMR" inspect --json --dir "$TMPDIR/app" > "$TMPDIR/inspect.json"

grep -q '"ok":true' "$TMPDIR/inspect.json"
grep -q '"schemaVersion":1' "$TMPDIR/inspect.json"
grep -q '"runnerVersion":"0.1.5"' "$TMPDIR/inspect.json"
grep -q '"protocolVersion":"2026-04-28"' "$TMPDIR/inspect.json"
grep -q '"dir":"'"$TMPDIR"'/app"' "$TMPDIR/inspect.json"
grep -q '"configPath":"'"$TMPDIR"'/app/.zmr/config.json"' "$TMPDIR/inspect.json"
grep -q '"configExists":true' "$TMPDIR/inspect.json"
grep -q '"agentInstructionsPath":"'"$TMPDIR"'/app/.zmr/AGENTS.md"' "$TMPDIR/inspect.json"
grep -q '"agentInstructionsExists":true' "$TMPDIR/inspect.json"
grep -q '"name":"android"' "$TMPDIR/inspect.json"
grep -q '"defaultDevice":"emulator-5554"' "$TMPDIR/inspect.json"
grep -q '"smokeScenario":"'"$TMPDIR"'/app/.zmr/android-smoke.json"' "$TMPDIR/inspect.json"
grep -q '"smokeScenarioExists":true' "$TMPDIR/inspect.json"
grep -q '"name":"ios"' "$TMPDIR/inspect.json"
grep -q '"defaultDevice":"booted"' "$TMPDIR/inspect.json"
grep -q '"smokeScenario":"'"$TMPDIR"'/app/.zmr/ios-smoke.json"' "$TMPDIR/inspect.json"
grep -q '"recommendedCommands":\["zmr doctor --strict --json --config '"$TMPDIR"'/app/.zmr/config.json","zmr schemas --json","zmr validate --json '"$TMPDIR"'/app/.zmr/android-smoke.json","zmr validate --json '"$TMPDIR"'/app/.zmr/ios-smoke.json","zmr serve --transport stdio --config '"$TMPDIR"'/app/.zmr/config.json --trace-dir traces/zmr-agent","zmr mcp --config '"$TMPDIR"'/app/.zmr/config.json --trace-dir traces/zmr-agent"\]' "$TMPDIR/inspect.json"
grep -q '"limitations":\["inspect is read-only and does not launch devices","autonomous crawling is not shipped; generate or edit scenarios for human review"\]' "$TMPDIR/inspect.json"

"$ZMR" inspect --json --dir "$TMPDIR/missing" > "$TMPDIR/missing.json"
grep -q '"ok":false' "$TMPDIR/missing.json"
grep -q '"status":"needs-setup"' "$TMPDIR/missing.json"
grep -q '"configExists":false' "$TMPDIR/missing.json"
grep -q '"recommendedCommands":\["zmr init --app --dir '"$TMPDIR"'/missing"\]' "$TMPDIR/missing.json"
