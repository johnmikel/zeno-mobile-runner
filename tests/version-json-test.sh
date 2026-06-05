#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMR="$ROOT/zig-out/bin/zmr"

OUTPUT="$("$ZMR" version --json)"
grep -q '"name":"zmr"' <<< "$OUTPUT"
grep -q '"version":"0.1.4"' <<< "$OUTPUT"
grep -q '"protocolVersion":"2026-04-28"' <<< "$OUTPUT"
grep -q '"minimumCompatibleProtocolVersion":"2026-04-28"' <<< "$OUTPUT"
grep -q '"stability":"dev-preview"' <<< "$OUTPUT"
grep -q '"breakingChangePolicy":"version-and-changelog"' <<< "$OUTPUT"
