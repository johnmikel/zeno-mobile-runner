#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$ROOT/clients/kotlin/src/main/kotlin/dev/zmr/ZmrClient.kt"
TEST="$ROOT/clients/kotlin/src/test/kotlin/dev/zmr/ZmrClientTest.kt"
README="$ROOT/clients/kotlin/README.md"

require_grep() {
  local needle="$1"
  local file="$2"
  if ! grep -q -- "$needle" "$file"; then
    echo "missing '$needle' in ${file#$ROOT/}" >&2
    exit 1
  fi
}

test -f "$CLIENT"
test -f "$TEST"
test -f "$README"

require_grep 'data class TraceDiscoverOptions' "$CLIENT"
require_grep 'fun validateScenario(path: String): String' "$CLIENT"
require_grep 'call("scenario.validate"' "$CLIENT"
require_grep 'fun explainTrace(): String' "$CLIENT"
require_grep 'call("trace.explain"' "$CLIENT"
require_grep 'fun discoverTrace(out: String, options: TraceDiscoverOptions = TraceDiscoverOptions()): String' "$CLIENT"
require_grep 'call("trace.discover"' "$CLIENT"
require_grep 'fun exploreTrace(out: String, goal: String, options: TraceDiscoverOptions = TraceDiscoverOptions()): String' "$CLIENT"
require_grep 'call("trace.explore"' "$CLIENT"
require_grep 'includeActions' "$CLIENT"
require_grep 'appId' "$CLIENT"
require_grep 'escapeJson' "$CLIENT"
require_grep 'hasTopLevelKey(response, "error")' "$CLIENT"
require_grep 'private fun hasTopLevelKey' "$CLIENT"

require_grep 'client.discoverTrace' "$TEST"
require_grep 'client.exploreTrace' "$TEST"
require_grep 'client.explainTrace' "$TEST"
require_grep 'TraceDiscoverOptions' "$TEST"
require_grep 'client.validateScenario' "$TEST"
require_grep '".zmr/discovered/kotlin-client.json"' "$TEST"

require_grep 'discoverTrace' "$README"
require_grep 'exploreTrace' "$README"
require_grep 'validateScenario' "$README"
require_grep 'explainTrace' "$README"
