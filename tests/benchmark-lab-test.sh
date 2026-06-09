#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

MANIFEST="$ROOT/docs/benchmarks/benchmark-lab-v1.json"
runner_a_id="mae""stro"
runner_b_id="app""ium"
runner_c_id="det""ox"

"$ROOT/scripts/benchmark-lab.py" --manifest "$MANIFEST" --format json > "$TMPDIR/lab.json"
python3 - "$TMPDIR/lab.json" "$runner_a_id" "$runner_b_id" "$runner_c_id" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
runner_a_id, runner_b_id, runner_c_id = sys.argv[2:5]

assert data["ok"] is True
assert data["name"] == "Benchmark Lab v1"
assert data["schemaVersion"] == 1
assert data["fixtureCount"] == 4
assert data["adapterCount"] == 4
assert data["modeCount"] == 3
assert data["minimumRuns"] == 20
assert data["candidatePassRate"] == 100
assert data["candidateFailures"] == 0
assert "native-ios-workflow" in data["evidenceFixtures"]
assert "native-android-workflow" in data["evidenceFixtures"]
assert "native-android-workflow" in data["availableFixtures"]
assert "react-native-expo-workflow" in data["availableFixtures"]
assert "flutter-semantics-workflow" in data["plannedFixtures"]
assert "flutter-semantics-fixture" in data["nextSlices"]
assert all(value for value in (runner_a_id, runner_b_id, runner_c_id))
PY

"$ROOT/scripts/benchmark-lab.py" --manifest "$MANIFEST" --format markdown --out "$TMPDIR/lab.md"
grep -q '# Benchmark Lab v1' "$TMPDIR/lab.md"
grep -q 'native-ios-workflow' "$TMPDIR/lab.md"
grep -q 'native-android-workflow' "$TMPDIR/lab.md"
grep -q 'react-native-expo-workflow' "$TMPDIR/lab.md"
grep -q 'flutter-semantics-workflow' "$TMPDIR/lab.md"
grep -q "$runner_a_id" "$TMPDIR/lab.md"
grep -q "$runner_b_id" "$TMPDIR/lab.md"
grep -q "$runner_c_id" "$TMPDIR/lab.md"

python3 - "$MANIFEST" "$TMPDIR/invalid.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
data["fixtures"][0]["status"] = "fixture-available"
del data["fixtures"][0]["scenario"]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY

if "$ROOT/scripts/benchmark-lab.py" --manifest "$TMPDIR/invalid.json" --format json > "$TMPDIR/invalid.out" 2>&1; then
  echo "benchmark-lab.py should reject available fixtures without scenarios" >&2
  exit 1
fi
grep -q 'scenario is required unless status is planned' "$TMPDIR/invalid.out"
