#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

LOCAL_EVIDENCE="$TMPDIR/local-evidence.jsonl"
PROD_EVIDENCE="$TMPDIR/production-evidence.jsonl"
PILOT_EVIDENCE="$TMPDIR/pilot-evidence.jsonl"

for args in "--evidence" "--target" "--run-summary" "--attempt-index" "--certification-min-executions"; do
  set +e
  missing_value_output="$("$ROOT/scripts/release-readiness.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "release-readiness should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

RUN_EVIDENCE_GENERATOR="$ROOT/tests/fixtures/generate-release-run-evidence.py"

assert_blocked_run_evidence() {
  local publication="$1"
  local minimum="${2:-1}"
  local output status
  set +e
  output="$("$ROOT/scripts/release-readiness.sh" \
    --evidence "$LOCAL_EVIDENCE" \
    --run-summary "$publication" \
    --attempt-index "$publication/attempt-index.json" \
    --certification-min-executions "$minimum" \
    --target dev-preview --json 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    echo "release-readiness should block invalid run evidence: $publication" >&2
    exit 1
  }
  python3 - "$output" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
assert value["ok"] is False
assert value["runEvidence"]["certificationReady"] is False
assert value["runEvidence"]["blockingReasons"]
PY
}

for minimum in 0 -1 invalid; do
  set +e
  invalid_minimum_output="$("$ROOT/scripts/release-readiness.sh" \
    --evidence placeholder.jsonl --run-summary placeholder.json \
    --certification-min-executions "$minimum" --json 2>&1)"
  invalid_minimum_status=$?
  set -e
  [[ "$invalid_minimum_status" -eq 2 ]] || {
    echo "release-readiness should reject certification minimum: $minimum" >&2
    exit 1
  }
  grep -q -- '--certification-min-executions must be a positive integer' <<< "$invalid_minimum_output"
done

set +e
orphan_index_output="$("$ROOT/scripts/release-readiness.sh" \
  --evidence placeholder.jsonl --attempt-index placeholder-index.json --json 2>&1)"
orphan_index_status=$?
set -e
[[ "$orphan_index_status" -eq 2 ]] || {
  echo "release-readiness should reject --attempt-index without --run-summary" >&2
  exit 1
}
grep -q -- '--attempt-index requires --run-summary' <<< "$orphan_index_output"

MISSING_EVIDENCE="$TMPDIR/missing-evidence.jsonl"
set +e
missing_evidence_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$MISSING_EVIDENCE" --target production --json 2>&1)"
missing_evidence_status=$?
set -e
if [[ "$missing_evidence_status" -eq 0 ]]; then
  echo "release-readiness should block when json evidence file is missing" >&2
  exit 1
fi
python3 - "$missing_evidence_output" "$MISSING_EVIDENCE" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["target"] == "production"
assert data["status"] == "blocked"
assert data["evidence"] == sys.argv[2]
assert data["evidenceFiles"] == [sys.argv[2]]
assert f"evidence file not found: {sys.argv[2]}" in data["missing"]
assert f"evidence file not found: {sys.argv[2]}" in data["blocked"]
assert data["passed"] == []
assert data["satisfied"] == []
assert "missing evidence" in data["claimLimitations"]
assert data["recommendedWording"].startswith("Do not publish the production claim yet")
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
assert set(next_steps) == {
    f"evidence file not found: {sys.argv[2]}",
    "local release gate + agent workflow smoke",
    "public Android demo",
    "public iOS simulator demo",
}
missing_step = next_steps[f"evidence file not found: {sys.argv[2]}"]
assert missing_step["command"]
assert missing_step["commands"]
assert missing_step["covers"] == [
    f"evidence file not found: {sys.argv[2]}",
    "physical iOS readiness",
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
]
assert f"--evidence-out {sys.argv[2]}" in missing_step["command"]
assert len(missing_step["commands"]) == 2
assert missing_step["commands"][0].startswith("zmr-pilot-gate --android --ios ")
assert missing_step["commands"][1].startswith("zmr-pilot-gate --ios --ios-device-type physical")
assert "--android-app-root /path/to/mobile-app" in missing_step["command"]
assert "--android-app-id <android-app-id>" in missing_step["command"]
assert "--ios-app-root /path/to/mobile-app" in missing_step["command"]
assert "--ios-app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app" in missing_step["command"]
assert "--ios-shim /path/to/mobile-app/.zmr/ios-shim" in missing_step["commands"][0]
assert "--ios-app-path /path/to/mobile-app/build/Release-iphoneos/Sample.ipa" in missing_step["command"]
assert "--ios-app-id <ios-app-id>" in missing_step["command"]
assert "--ios-device <physical-device-id>" in missing_step["command"]
assert not any(command.startswith(("run ", "from ", "fix ", "rerun ", "execute ")) for command in missing_step["commands"])
PY

MISSING_EVIDENCE_WITH_SPACES="$TMPDIR/missing evidence/evidence file.jsonl"
set +e
missing_spaces_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$MISSING_EVIDENCE_WITH_SPACES" --target production --json 2>&1)"
set -e
python3 - "$missing_spaces_output" "$MISSING_EVIDENCE_WITH_SPACES" <<'PY'
import json
import shlex
import sys

data = json.loads(sys.argv[1])
evidence = sys.argv[2]
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
missing_step = next_steps[f"evidence file not found: {evidence}"]
assert set(next_steps) == {
    f"evidence file not found: {evidence}",
    "local release gate + agent workflow smoke",
    "public Android demo",
    "public iOS simulator demo",
}
assert len(missing_step["commands"]) == 2
assert not missing_step["commands"][0].startswith(("run ", "from ", "fix ", "rerun ", "execute "))
for command in missing_step["commands"]:
    parts = shlex.split(command)
    assert parts[-2:] == ["--evidence-out", evidence]
assert missing_step["covers"] == [
    f"evidence file not found: {evidence}",
    "physical iOS readiness",
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
]
PY

DEV_MISSING_EVIDENCE="$TMPDIR/dev-preview-evidence.jsonl"
set +e
dev_missing_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$DEV_MISSING_EVIDENCE" --target dev-preview --json 2>&1)"
dev_missing_status=$?
set -e
if [[ "$dev_missing_status" -eq 0 ]]; then
  echo "dev-preview readiness should block when evidence file is missing" >&2
  exit 1
fi
python3 - "$dev_missing_output" <<'PY'
import json
import shlex
import sys

data = json.loads(sys.argv[1])
assert data["target"] == "dev-preview"
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
missing_step = next(item for key, item in next_steps.items() if key.startswith("evidence file not found: "))
assert len(missing_step["commands"]) == 1
assert missing_step["command"].startswith("./scripts/release-candidate.sh --mode local")
assert "zmr-pilot-gate" not in missing_step["command"]
parts = shlex.split(missing_step["command"])
assert parts[:3] == ["./scripts/release-candidate.sh", "--mode", "local"]
assert "--evidence-dir" in parts
PY

MARKET_MISSING_EVIDENCE="$TMPDIR/market-claim-evidence.jsonl"
set +e
market_missing_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$MARKET_MISSING_EVIDENCE" --target market-claim --json 2>&1)"
market_missing_status=$?
set -e
if [[ "$market_missing_status" -eq 0 ]]; then
  echo "market-claim readiness should block when evidence file is missing" >&2
  exit 1
fi
python3 - "$market_missing_output" "$MARKET_MISSING_EVIDENCE" <<'PY'
import json
import shlex
import sys

data = json.loads(sys.argv[1])
evidence = sys.argv[2]
assert data["target"] == "market-claim"
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
assert set(next_steps) == {
    f"evidence file not found: {evidence}",
    "local release gate + agent workflow smoke",
    "public Android demo",
    "public iOS simulator demo",
}
missing_step = next_steps[f"evidence file not found: {evidence}"]
assert len(missing_step["commands"]) == 5
assert missing_step["commands"][0].startswith("zmr-pilot-gate --android --ios ")
assert "--ios-shim /path/to/mobile-app/.zmr/ios-shim" in missing_step["commands"][0]
assert missing_step["commands"][1].startswith("zmr-pilot-gate --ios --ios-device-type physical")
assert "zmr-benchmark --zmr .zmr/android-smoke.json" in missing_step["commands"][2]
assert "zmr-benchmark-command --tool <baseline-name>" in missing_step["commands"][3]
assert "zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl" in missing_step["commands"][4]
assert missing_step["commands"][4].endswith(f"--evidence-out {evidence}")
parts = shlex.split(missing_step["commands"][4])
assert parts[-2:] == ["--evidence-out", evidence]
assert missing_step["covers"] == [
    f"evidence file not found: {evidence}",
    "physical iOS readiness",
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
    "competitive benchmark comparison",
]
PY

MARKET_STANDARD_EVIDENCE="$TMPDIR/market-standard/evidence.jsonl"
set +e
market_standard_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$MARKET_STANDARD_EVIDENCE" --target market-claim --json 2>&1)"
market_standard_status=$?
set -e
if [[ "$market_standard_status" -eq 0 ]]; then
  echo "market-claim readiness should block when standard evidence file is missing" >&2
  exit 1
fi
python3 - "$market_standard_output" "$MARKET_STANDARD_EVIDENCE" <<'PY'
import json
import shlex
import sys

data = json.loads(sys.argv[1])
evidence = sys.argv[2]
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
assert set(next_steps) == {
    f"evidence file not found: {evidence}",
    "local release gate + agent workflow smoke",
    "public Android demo",
    "public iOS simulator demo",
}
missing_step = next_steps[f"evidence file not found: {evidence}"]
assert len(missing_step["commands"]) == 5
first = shlex.split(missing_step["commands"][0])
assert first[:3] == ["zmr-pilot-gate", "--android", "--ios"]
assert "./scripts/release-candidate.sh" not in missing_step["command"]
assert first[-2:] == ["--evidence-out", evidence]
assert "--ios-shim /path/to/mobile-app/.zmr/ios-shim" in missing_step["commands"][0]
assert missing_step["commands"][1].startswith("zmr-pilot-gate --ios --ios-device-type physical")
assert "zmr-benchmark --zmr .zmr/android-smoke.json" in missing_step["commands"][2]
assert "zmr-benchmark-command --tool <baseline-name>" in missing_step["commands"][3]
assert missing_step["commands"][4].endswith(f"--evidence-out {evidence}")
assert missing_step["covers"] == [
    f"evidence file not found: {evidence}",
    "physical iOS readiness",
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
    "competitive benchmark comparison",
]
PY

INVALID_EVIDENCE="$TMPDIR/invalid-evidence.jsonl"
cat > "$INVALID_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":
JSONL
set +e
invalid_evidence_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$INVALID_EVIDENCE" --target dev-preview --json 2>&1)"
invalid_evidence_status=$?
set -e
if [[ "$invalid_evidence_status" -eq 0 ]]; then
  echo "release-readiness should block when json evidence is malformed" >&2
  exit 1
fi
python3 - "$invalid_evidence_output" "$INVALID_EVIDENCE" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["target"] == "dev-preview"
assert data["status"] == "blocked"
assert data["evidence"] == sys.argv[2]
assert data["evidenceFiles"] == [sys.argv[2]]
invalid = f"invalid evidence JSONL in {sys.argv[2]} at line 4"
assert any(item.startswith(invalid) for item in data["missing"])
assert any(item.startswith(invalid) for item in data["blocked"])
assert "local release gate" in data["passed"]
assert "invalid evidence" in data["claimLimitations"]
assert "missing evidence" not in data["claimLimitations"]
assert "Invalid evidence:" in data["recommendedWording"]
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
invalid_step = next(item for key, item in next_steps.items() if key.startswith(invalid))
assert invalid_step["command"]
assert invalid_step["commands"]
assert sys.argv[2] in invalid_step["command"]
assert not any(command.startswith(("run ", "from ", "fix ", "rerun ", "execute ")) for command in invalid_step["commands"])
PY

INVALID_EVIDENCE_WITH_SPACES="$TMPDIR/invalid evidence/evidence file.jsonl"
mkdir -p "$(dirname "$INVALID_EVIDENCE_WITH_SPACES")"
cat > "$INVALID_EVIDENCE_WITH_SPACES" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":
JSONL
set +e
invalid_spaces_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$INVALID_EVIDENCE_WITH_SPACES" --target dev-preview --json 2>&1)"
set -e
python3 - "$invalid_spaces_output" "$INVALID_EVIDENCE_WITH_SPACES" <<'PY'
import json
import shlex
import sys

data = json.loads(sys.argv[1])
evidence = sys.argv[2]
invalid_step = next(
    item for item in data["nextSteps"]
    if item["requirement"].startswith(f"invalid evidence JSONL in {evidence} at line ")
)
assert len(invalid_step["commands"]) == 1
assert not invalid_step["commands"][0].startswith(("run ", "from ", "fix ", "rerun ", "execute "))
parts = shlex.split(invalid_step["commands"][0])
assert parts == ["zmr-release-readiness", "--evidence", evidence, "--target", "dev-preview", "--json"]
PY

cat > "$LOCAL_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
JSONL

dev_json="$("$ROOT/scripts/release-readiness.sh" --evidence "$LOCAL_EVIDENCE" --target dev-preview --json)"
python3 - "$dev_json" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is True
assert data["target"] == "dev-preview"
assert data["status"] == "ready"
assert data["missing"] == []
assert data["blocked"] == []
assert data["satisfied"] == ["local release gate", "public Android demo", "public iOS simulator demo"]
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["local release gate"]["status"] == "satisfied"
assert requirements["local release gate"]["evidenceName"] == "local release gate"
assert requirements["public Android demo"]["status"] == "satisfied"
assert requirements["public iOS simulator demo"]["status"] == "satisfied"
assert data["recommendedWording"].startswith("ZMR is ready to publish as a public developer preview")
assert "Do not describe it as production-stable" in data["recommendedWording"]
assert "production-stable" in data["claimLimitations"]
assert "competitive leadership" in data["claimLimitations"]
PY

python3 - "$ROOT/schemas/release-readiness-output.schema.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    schema = json.load(handle)

requirement_item = schema["properties"]["requirements"]["items"]
conditionals = requirement_item.get("allOf", [])
assert any(
    item.get("if", {}).get("properties", {}).get("status", {}).get("const") == "satisfied"
    and "evidenceName" in item.get("then", {}).get("required", [])
    for item in conditionals
), "release-readiness schema must require evidenceName for satisfied requirements"
assert any(
    "reason" in item.get("then", {}).get("required", [])
    and "missing" in item.get("if", {}).get("properties", {}).get("status", {}).get("enum", [])
    and "insufficient" in item.get("if", {}).get("properties", {}).get("status", {}).get("enum", [])
    for item in conditionals
), "release-readiness schema must require reason for blocked requirement statuses"
next_step_item = schema["properties"]["nextSteps"]["items"]
assert next_step_item["required"] == ["requirement", "command", "commands", "covers"]
assert next_step_item["properties"]["covers"]["minItems"] == 1
run_evidence = schema["properties"]["runEvidence"]
assert run_evidence["additionalProperties"] is False
assert set(run_evidence["required"]) == {
    "attempts",
    "logicalExecutions",
    "eligibleLogicalExecutions",
    "firstAttemptPassRate",
    "eventualPassRate",
    "classificationCounts",
    "certificationMinimum",
    "certificationReady",
    "cohorts",
    "blockingReasons",
    "diagnostics",
}
PY

ROW_BLOCKED_EVIDENCE="$TMPDIR/row-blocked-evidence.jsonl"
cat > "$ROW_BLOCKED_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"public Android emulator demo","status":"failed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public Android emulator demo","status":"failed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"iOS physical hardware pilot","status":"planned","durationMs":0,"command":"./scripts/run-ios-pilot.sh --ios-device-type physical"}
{"name":"iOS physical hardware pilot","status":"planned","durationMs":0,"command":"./scripts/run-ios-pilot.sh --ios-device-type physical"}
JSONL
set +e
row_blocked_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$ROW_BLOCKED_EVIDENCE" --target dev-preview --json 2>&1)"
row_blocked_status=$?
set -e
if [[ "$row_blocked_status" -eq 0 ]]; then
  echo "dev-preview readiness should block when evidence contains failed or planned rows" >&2
  exit 1
fi
python3 - "$row_blocked_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["target"] == "dev-preview"
assert data["status"] == "blocked"
assert data["satisfied"] == ["local release gate", "public Android demo", "public iOS simulator demo"]
assert data["missing"] == []
assert data["failed"] == ["public Android emulator demo"]
assert data["planned"] == ["iOS physical hardware pilot"]
assert "failed evidence: public Android emulator demo" in data["blocked"]
assert "planned evidence: iOS physical hardware pilot" in data["blocked"]
assert data["blocked"].count("failed evidence: public Android emulator demo") == 1
assert data["blocked"].count("planned evidence: iOS physical hardware pilot") == 1
assert "Missing evidence: none" not in data["recommendedWording"]
assert "Failed evidence: public Android emulator demo" in data["recommendedWording"]
assert "Planned evidence is not proof: iOS physical hardware pilot" in data["recommendedWording"]
assert "missing evidence" not in data["claimLimitations"]
assert "failed evidence" in data["claimLimitations"]
assert "planned evidence is not proof" in data["claimLimitations"]
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
assert next_steps["failed evidence: public Android emulator demo"]["command"] == "./scripts/demo-android-real.sh --runs 5"
assert next_steps["failed evidence: public Android emulator demo"]["commands"] == ["./scripts/demo-android-real.sh --runs 5"]
assert next_steps["planned evidence: iOS physical hardware pilot"]["command"] == "./scripts/run-ios-pilot.sh --ios-device-type physical"
assert next_steps["planned evidence: iOS physical hardware pilot"]["commands"] == ["./scripts/run-ios-pilot.sh --ios-device-type physical"]
PY

set +e
prod_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$LOCAL_EVIDENCE" --target production --json 2>&1)"
prod_status=$?
set -e
if [[ "$prod_status" -eq 0 ]]; then
  echo "production readiness should fail without hardware pilot evidence" >&2
  exit 1
fi
python3 - "$prod_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["target"] == "production"
assert data["status"] == "blocked"
assert data["satisfied"] == ["local release gate", "public Android demo", "public iOS simulator demo", "agent workflow smoke"]
assert data["recommendedWording"].startswith("Do not publish the production claim yet")
assert "Android hardware pilot" in data["recommendedWording"]
assert "missing evidence" in data["claimLimitations"]
missing = "\n".join(data["missing"])
assert "Android hardware pilot" in missing
assert "iOS simulator hardware pilot" in missing
assert "iOS physical hardware pilot" in missing
assert "Android hardware pilot" in data["blocked"]
assert "iOS simulator hardware pilot" in data["blocked"]
assert "iOS physical hardware pilot" in data["blocked"]
assert "local release gate" not in data["blocked"]
next_steps = {step["requirement"]: step for step in data["nextSteps"]}
assert set(next_steps) == {
    "Android hardware pilot + iOS simulator hardware pilot",
    "physical iOS readiness + iOS physical hardware pilot",
}
sim_step = next_steps["Android hardware pilot + iOS simulator hardware pilot"]
assert sim_step["covers"] == ["Android hardware pilot", "iOS simulator hardware pilot"]
assert sim_step["command"].startswith("zmr-pilot-gate --android --ios")
assert "--android-app-id <android-app-id>" in sim_step["command"]
assert "--ios-app-id <ios-app-id>" in sim_step["command"]
assert "--evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl" in sim_step["command"]
physical_step = next_steps["physical iOS readiness + iOS physical hardware pilot"]
assert physical_step["covers"] == ["physical iOS readiness", "iOS physical hardware pilot"]
assert physical_step["command"].startswith("zmr-pilot-gate --ios --ios-device-type physical")
assert "--ios-device <physical-device-id>" in physical_step["command"]
assert "--ios-app-id <ios-app-id>" in physical_step["command"]
assert "--evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl" in physical_step["command"]
PY

COMMAND_ONLY_THRESHOLD_EVIDENCE="$TMPDIR/command-only-threshold-evidence.jsonl"
cat > "$COMMAND_ONLY_THRESHOLD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0"}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0"}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0"}
JSONL

set +e
command_only_threshold_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$COMMAND_ONLY_THRESHOLD_EVIDENCE" --target production --json 2>&1)"
command_only_threshold_status=$?
set -e
if [[ "$command_only_threshold_status" -eq 0 ]]; then
  echo "production readiness should fail when pilot thresholds are only command flags" >&2
  exit 1
fi
python3 - "$command_only_threshold_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["missing"] == []
assert data["insufficient"] == [
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
]
assert "missing evidence" not in data["claimLimitations"]
assert "insufficient evidence" in data["claimLimitations"]
assert "Insufficient evidence: Android hardware pilot, iOS simulator hardware pilot, iOS physical hardware pilot" in data["recommendedWording"]
requirements = {item["name"]: item for item in data["requirements"]}
for name in [
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
]:
    assert requirements[name]["status"] == "insufficient"
    assert "structured runs evidence present" in requirements[name]["reason"]
    assert "structured minPassRate evidence present" in requirements[name]["reason"]
    assert "structured maxFailures evidence present" in requirements[name]["reason"]
PY

cat > "$PROD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

"$ROOT/scripts/release-readiness.sh" --evidence "$PROD_EVIDENCE" --target production --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["ok"] is True; assert "agent workflow smoke" in data["satisfied"]'

IOS_DEVICE_FLAG_PROD_EVIDENCE="$TMPDIR/ios-device-flag-production-evidence.jsonl"
cat > "$IOS_DEVICE_FLAG_PROD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"zmr-pilot-gate --ios --ios-device-type physical --ios-device ios-ready --ios-app-root /tmp/zmr-app --ios-app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --ios-app-id com.example.demo --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

"$ROOT/scripts/release-readiness.sh" --evidence "$IOS_DEVICE_FLAG_PROD_EVIDENCE" --target production --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["ok"] is True; assert "agent workflow smoke" in data["satisfied"]'

AGENTLESS_PROD_EVIDENCE="$TMPDIR/agentless-production-evidence.jsonl"
cat > "$AGENTLESS_PROD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"echo local gate passed"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
agentless_prod_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$AGENTLESS_PROD_EVIDENCE" --target production --json 2>&1)"
agentless_prod_status=$?
set -e
if [[ "$agentless_prod_status" -eq 0 ]]; then
  echo "production readiness should fail when local evidence does not prove the agent workflow smoke" >&2
  exit 1
fi
python3 - "$agentless_prod_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["missing"] == []
assert data["insufficient"] == ["agent workflow smoke"]
assert "insufficient evidence" in data["claimLimitations"]
assert "Insufficient evidence: agent workflow smoke" in data["recommendedWording"]
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["agent workflow smoke"]["status"] == "insufficient"
assert "release-gate.sh or structured agentWorkflow evidence" in requirements["agent workflow smoke"]["reason"]
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
assert next_steps["agent workflow smoke"]["commands"] == ["./scripts/release-gate.sh"]
assert next_steps["agent workflow smoke"]["covers"] == ["agent workflow smoke"]
PY

STRUCTURED_AGENT_PROD_EVIDENCE="$TMPDIR/structured-agent-production-evidence.jsonl"
cat > "$STRUCTURED_AGENT_PROD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"echo local gate passed"}
{"name":"agent workflow smoke","status":"passed","durationMs":1000,"command":"zmr mcp + zmr serve smoke","agentWorkflow":true,"mcp":true,"jsonRpc":true,"semanticSnapshot":true,"typedActions":true,"traceEvents":true,"traceExplain":true,"traceExplore":true,"traceDiscover":true,"scenarioValidation":true,"redactedExport":true}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

"$ROOT/scripts/release-readiness.sh" --evidence "$STRUCTURED_AGENT_PROD_EVIDENCE" --target production --json | python3 -c 'import json,sys; data=json.load(sys.stdin); requirements={item["name"]: item for item in data["requirements"]}; assert data["ok"] is True; assert requirements["agent workflow smoke"]["status"] == "satisfied"; assert requirements["agent workflow smoke"]["evidenceName"] == "agent workflow smoke"'

NO_APP_ARTIFACT_PROD_EVIDENCE="$TMPDIR/no-app-artifact-production-evidence.jsonl"
cat > "$NO_APP_ARTIFACT_PROD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
no_app_artifact_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_APP_ARTIFACT_PROD_EVIDENCE" --target production --json 2>&1)"
no_app_artifact_status=$?
set -e
if [[ "$no_app_artifact_status" -eq 0 ]]; then
  echo "production readiness should fail when hardware pilot rows omit app root/artifact evidence" >&2
  exit 1
fi
python3 - "$no_app_artifact_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["Android hardware pilot"]["status"] == "insufficient"
assert "app root evidence present" in requirements["Android hardware pilot"]["reason"]
assert requirements["iOS simulator hardware pilot"]["status"] == "insufficient"
assert "app artifact evidence present" in requirements["iOS simulator hardware pilot"]["reason"]
assert requirements["iOS physical hardware pilot"]["status"] == "insufficient"
assert "app artifact evidence present" in requirements["iOS physical hardware pilot"]["reason"]
PY

NO_PHYSICAL_DEVICE_EVIDENCE="$TMPDIR/no-physical-device-evidence.jsonl"
cat > "$NO_PHYSICAL_DEVICE_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
no_physical_device_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_PHYSICAL_DEVICE_EVIDENCE" --target production --json 2>&1)"
no_physical_device_status=$?
set -e
if [[ "$no_physical_device_status" -eq 0 ]]; then
  echo "production readiness should fail when physical iOS readiness omits device evidence" >&2
  exit 1
fi
python3 - "$no_physical_device_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert "physical iOS readiness" in data["passed"]
assert "physical iOS readiness" not in data["satisfied"]
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["physical iOS readiness"]["status"] == "insufficient"
assert "device" in requirements["physical iOS readiness"]["reason"]
PY

BOOTED_PHYSICAL_DEVICE_EVIDENCE="$TMPDIR/booted-physical-device-evidence.jsonl"
cat > "$BOOTED_PHYSICAL_DEVICE_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device booted"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
booted_physical_device_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$BOOTED_PHYSICAL_DEVICE_EVIDENCE" --target production --json 2>&1)"
booted_physical_device_status=$?
set -e
if [[ "$booted_physical_device_status" -eq 0 ]]; then
  echo "production readiness should fail when physical iOS readiness uses booted as the device" >&2
  exit 1
fi
python3 - "$booted_physical_device_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["physical iOS readiness"]["status"] == "insufficient"
assert "physical device identifier" in requirements["physical iOS readiness"]["reason"]
PY

NO_IOS_PHYSICAL_PILOT_DEVICE_EVIDENCE="$TMPDIR/no-ios-physical-pilot-device-evidence.jsonl"
cat > "$NO_IOS_PHYSICAL_PILOT_DEVICE_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
no_ios_physical_pilot_device_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_IOS_PHYSICAL_PILOT_DEVICE_EVIDENCE" --target production --json 2>&1)"
no_ios_physical_pilot_device_status=$?
set -e
if [[ "$no_ios_physical_pilot_device_status" -eq 0 ]]; then
  echo "production readiness should fail when iOS physical hardware pilot omits device evidence" >&2
  exit 1
fi
python3 - "$no_ios_physical_pilot_device_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["iOS physical hardware pilot"]["status"] == "insufficient"
assert "physical device identifier" in requirements["iOS physical hardware pilot"]["reason"]
PY

NO_APP_ID_PROD_EVIDENCE="$TMPDIR/no-app-id-production-evidence.jsonl"
cat > "$NO_APP_ID_PROD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
no_app_id_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_APP_ID_PROD_EVIDENCE" --target production --json 2>&1)"
no_app_id_status=$?
set -e
if [[ "$no_app_id_status" -eq 0 ]]; then
  echo "production readiness should fail when hardware pilot rows omit app id evidence" >&2
  exit 1
fi
python3 - "$no_app_id_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert "Android hardware pilot" in data["passed"]
assert "Android hardware pilot" not in data["satisfied"]
requirements = {item["name"]: item for item in data["requirements"]}
for name in [
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
]:
    assert requirements[name]["status"] == "insufficient"
    assert "appId" in requirements[name]["reason"]
PY

NO_ANDROID_DEVICE_EVIDENCE="$TMPDIR/no-android-device-evidence.jsonl"
cat > "$NO_ANDROID_DEVICE_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
no_android_device_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_ANDROID_DEVICE_EVIDENCE" --target production --json 2>&1)"
no_android_device_status=$?
set -e
if [[ "$no_android_device_status" -eq 0 ]]; then
  echo "production readiness should fail when Android hardware pilot omits device evidence" >&2
  exit 1
fi
python3 - "$no_android_device_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["Android hardware pilot"]["status"] == "insufficient"
assert "Android device identifier" in requirements["Android hardware pilot"]["reason"]
PY

NO_IOS_SIMULATOR_DEVICE_EVIDENCE="$TMPDIR/no-ios-simulator-device-evidence.jsonl"
cat > "$NO_IOS_SIMULATOR_DEVICE_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

set +e
no_ios_simulator_device_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_IOS_SIMULATOR_DEVICE_EVIDENCE" --target production --json 2>&1)"
no_ios_simulator_device_status=$?
set -e
if [[ "$no_ios_simulator_device_status" -eq 0 ]]; then
  echo "production readiness should fail when iOS simulator hardware pilot omits device evidence" >&2
  exit 1
fi
python3 - "$no_ios_simulator_device_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["iOS simulator hardware pilot"]["status"] == "insufficient"
assert "iOS simulator device identifier" in requirements["iOS simulator hardware pilot"]["reason"]
PY

WEAK_PROD_EVIDENCE="$TMPDIR/weak-production-evidence.jsonl"
cat > "$WEAK_PROD_EVIDENCE" <<'JSONL'
{"name":"local release gate","status":"passed","durationMs":1000,"command":"./scripts/release-gate.sh"}
{"name":"public Android emulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-android-real.sh --runs 5"}
{"name":"public iOS simulator demo","status":"passed","durationMs":1000,"command":"./scripts/demo-ios-real.sh --runs 5"}
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 1 --min-pass-rate 100 --max-failures 0","runs":1,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 99 --max-failures 0","runs":20,"minPassRate":99,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 1","runs":20,"minPassRate":100,"maxFailures":1}
JSONL

set +e
weak_prod_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$WEAK_PROD_EVIDENCE" --target production --json 2>&1)"
weak_prod_status=$?
set -e
if [[ "$weak_prod_status" -eq 0 ]]; then
  echo "production readiness should fail when hardware pilot rows do not prove the minimum thresholds" >&2
  exit 1
fi
python3 - "$weak_prod_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["missing"] == []
assert data["insufficient"] == [
    "Android hardware pilot",
    "iOS simulator hardware pilot",
    "iOS physical hardware pilot",
]
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["Android hardware pilot"]["status"] == "insufficient"
assert "runs >= 20" in requirements["Android hardware pilot"]["reason"]
assert requirements["iOS simulator hardware pilot"]["status"] == "insufficient"
assert "minPassRate >= 100" in requirements["iOS simulator hardware pilot"]["reason"]
assert requirements["iOS physical hardware pilot"]["status"] == "insufficient"
assert "maxFailures <= 0" in requirements["iOS physical hardware pilot"]["reason"]
PY

cat > "$PILOT_EVIDENCE" <<'JSONL'
{"name":"physical iOS readiness","status":"passed","durationMs":1000,"command":"./scripts/assert-ios-physical-ready.sh --device ios-ready"}
{"name":"Android hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-android-pilot.sh --app-root /tmp/zmr-app --app-id com.example.demo --device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS simulator hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Debug-iphonesimulator/Sample.app --app-id com.example.demo --device booted --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
{"name":"iOS physical hardware pilot","status":"passed","durationMs":1000,"command":"./scripts/run-ios-pilot.sh --app-root /tmp/zmr-app --app-path /tmp/zmr-app/build/Release-iphoneos/Sample.ipa --app-id com.example.demo --ios-device-type physical --device ios-ready --runs 20 --min-pass-rate 100 --max-failures 0","runs":20,"minPassRate":100,"maxFailures":0}
JSONL

multi_json="$("$ROOT/scripts/release-readiness.sh" \
  --evidence "$LOCAL_EVIDENCE" \
  --evidence "$PILOT_EVIDENCE" \
  --target production \
  --json)"
python3 - "$LOCAL_EVIDENCE" "$PILOT_EVIDENCE" "$multi_json" <<'PY'
import json
import sys

data = json.loads(sys.argv[3])
assert data["ok"] is True
assert data["target"] == "production"
assert data["evidence"] == sys.argv[1]
assert data["evidenceFiles"] == [sys.argv[1], sys.argv[2]]
PY

set +e
market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$PROD_EVIDENCE" --target market-claim --json 2>&1)"
market_status=$?
set -e
if [[ "$market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail without benchmark comparison evidence" >&2
  exit 1
fi
python3 - "$market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["target"] == "market-claim"
assert any("competitive benchmark comparison" in item for item in data["missing"])
assert data["recommendedWording"].startswith("Do not publish the market claim yet")
assert "market-claim claim" not in data["recommendedWording"]
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
for step in data["nextSteps"]:
    assert "commands" in step
    assert step["commands"]
    assert step["command"] == " && ".join(step["commands"])
    assert "covers" in step
    assert step["covers"]
benchmark_command = next_steps["competitive benchmark comparison"]["command"]
benchmark_commands = next_steps["competitive benchmark comparison"]["commands"]
assert len(benchmark_commands) == 3
assert benchmark_commands[0].startswith("zmr-benchmark --zmr .zmr/android-smoke.json")
assert benchmark_commands[1].startswith("zmr-benchmark-command --tool <baseline-name>")
assert benchmark_commands[2].startswith("zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl")
assert benchmark_command == " && ".join(benchmark_commands)
assert benchmark_command.startswith("zmr-benchmark --zmr .zmr/android-smoke.json")
assert "zmr-benchmark-command --tool <baseline-name>" in benchmark_command
assert "zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl" in benchmark_command
assert "--runs 20" in benchmark_command
assert "--platform <platform>" in benchmark_command
assert "--device <device-id>" in benchmark_command
assert "--app-id <app-id>" in benchmark_command
assert "--app-build <build-id-or-artifact>" in benchmark_command
assert "--results traces/bench-comparison/results.jsonl" in benchmark_command
assert "--min-candidate-pass-rate 100" in benchmark_command
assert "--max-candidate-failures 0" in benchmark_command
assert "--min-mean-speedup 1.25" in benchmark_command
assert "--min-p95-speedup 1.25" in benchmark_command
assert "--evidence-out traces/bench-comparison/evidence.jsonl" in benchmark_command
assert "--input" not in benchmark_command
PY

WEAK_MARKET_EVIDENCE="$TMPDIR/weak-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$WEAK_MARKET_EVIDENCE"
cat >> "$WEAK_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --candidate zmr --baseline baseline --min-candidate-pass-rate 99 --max-candidate-failures 1 --min-mean-speedup 1.1 --min-p95-speedup 1.1"}
JSONL

set +e
weak_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$WEAK_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
weak_market_status=$?
set -e
if [[ "$weak_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark comparison evidence does not prove competitive thresholds" >&2
  exit 1
fi
python3 - "$weak_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["missing"] == []
assert data["insufficient"] == ["competitive benchmark comparison"]
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
reason = requirements["competitive benchmark comparison"]["reason"]
assert "minCandidatePassRate >= 100" in reason
assert "maxCandidateFailures <= 0" in reason
assert "minMeanSpeedup >= 1.25" in reason
assert "minP95Speedup >= 1.25" in reason
PY

NO_BASELINE_MARKET_EVIDENCE="$TMPDIR/no-baseline-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$NO_BASELINE_MARKET_EVIDENCE"
cat >> "$NO_BASELINE_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --candidate zmr --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25"}
JSONL

set +e
no_baseline_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_BASELINE_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
no_baseline_market_status=$?
set -e
if [[ "$no_baseline_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark comparison evidence omits baseline" >&2
  exit 1
fi
python3 - "$no_baseline_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
assert "baseline name present" in requirements["competitive benchmark comparison"]["reason"]
PY

NO_CANDIDATE_MARKET_EVIDENCE="$TMPDIR/no-candidate-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$NO_CANDIDATE_MARKET_EVIDENCE"
cat >> "$NO_CANDIDATE_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25"}
JSONL

set +e
no_candidate_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_CANDIDATE_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
no_candidate_market_status=$?
set -e
if [[ "$no_candidate_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark comparison evidence omits candidate" >&2
  exit 1
fi
python3 - "$no_candidate_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
assert "candidate name present" in requirements["competitive benchmark comparison"]["reason"]
PY

NO_RESULTS_MARKET_EVIDENCE="$TMPDIR/no-results-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$NO_RESULTS_MARKET_EVIDENCE"
cat >> "$NO_RESULTS_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --candidate zmr --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25"}
JSONL

set +e
no_results_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_RESULTS_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
no_results_market_status=$?
set -e
if [[ "$no_results_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark comparison evidence omits results path" >&2
  exit 1
fi
python3 - "$no_results_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
assert "results path present" in requirements["competitive benchmark comparison"]["reason"]
PY

NO_MEASURED_MARKET_EVIDENCE="$TMPDIR/no-measured-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$NO_MEASURED_MARKET_EVIDENCE"
cat >> "$NO_MEASURED_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --candidate zmr --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25"}
JSONL

set +e
no_measured_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_MEASURED_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
no_measured_market_status=$?
set -e
if [[ "$no_measured_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark comparison evidence omits measured results" >&2
  exit 1
fi
python3 - "$no_measured_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
reason = requirements["competitive benchmark comparison"]["reason"]
assert "candidatePassRate >= minCandidatePassRate" in reason
assert "candidateFailures <= maxCandidateFailures" in reason
assert "meanSpeedup >= minMeanSpeedup" in reason
assert "p95Speedup >= minP95Speedup" in reason
PY

FLAG_ONLY_MEASURED_MARKET_EVIDENCE="$TMPDIR/flag-only-measured-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$FLAG_ONLY_MEASURED_MARKET_EVIDENCE"
cat >> "$FLAG_ONLY_MEASURED_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --candidate zmr --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25 --candidate-pass-rate 100 --candidate-failures 0 --mean-speedup 1.25 --p95-speedup 1.25"}
JSONL

set +e
flag_only_measured_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$FLAG_ONLY_MEASURED_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
flag_only_measured_market_status=$?
set -e
if [[ "$flag_only_measured_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark measured results only appear as command flags" >&2
  exit 1
fi
python3 - "$flag_only_measured_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
reason = requirements["competitive benchmark comparison"]["reason"]
assert "candidatePassRate >= minCandidatePassRate" in reason
assert "candidateFailures <= maxCandidateFailures" in reason
assert "meanSpeedup >= minMeanSpeedup" in reason
assert "p95Speedup >= minP95Speedup" in reason
next_steps = {item["requirement"]: item for item in data["nextSteps"]}
benchmark_command = next_steps["competitive benchmark comparison"]["command"]
assert benchmark_command.startswith("zmr-benchmark --zmr .zmr/android-smoke.json")
assert "zmr-benchmark-command --tool <baseline-name>" in benchmark_command
assert "zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl" in benchmark_command
assert "--runs 20" in benchmark_command
assert "--app-build <build-id-or-artifact>" in benchmark_command
assert "--evidence-out traces/bench-comparison/evidence.jsonl" in benchmark_command
PY

NO_CONTEXT_MARKET_EVIDENCE="$TMPDIR/no-context-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$NO_CONTEXT_MARKET_EVIDENCE"
cat >> "$NO_CONTEXT_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --candidate zmr --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25","candidatePassRate":100,"candidateFailures":0,"candidateRuns":20,"baselineRuns":20,"meanSpeedup":1.25,"p95Speedup":1.25}
JSONL

set +e
no_context_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$NO_CONTEXT_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
no_context_market_status=$?
set -e
if [[ "$no_context_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark comparison evidence lacks same-context proof" >&2
  exit 1
fi
python3 - "$no_context_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
reason = requirements["competitive benchmark comparison"]["reason"]
assert "same benchmark context evidence present" in reason
PY

LOW_SAMPLE_MARKET_EVIDENCE="$TMPDIR/low-sample-market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$LOW_SAMPLE_MARKET_EVIDENCE"
cat >> "$LOW_SAMPLE_MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --candidate zmr --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25","candidatePassRate":100,"candidateFailures":0,"candidateRuns":2,"baselineRuns":20,"meanSpeedup":1.25,"p95Speedup":1.25,"sameContext":true,"context":{"platform":"android","device":"emulator-5554","appId":"com.example.mobiletest","scenario":".zmr/login.json","appBuild":"debug-20260518"}}
JSONL

set +e
low_sample_market_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$LOW_SAMPLE_MARKET_EVIDENCE" --target market-claim --json 2>&1)"
low_sample_market_status=$?
set -e
if [[ "$low_sample_market_status" -eq 0 ]]; then
  echo "market-claim readiness should fail when benchmark comparison evidence uses too few samples" >&2
  exit 1
fi
python3 - "$low_sample_market_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
requirements = {item["name"]: item for item in data["requirements"]}
assert requirements["competitive benchmark comparison"]["status"] == "insufficient"
reason = requirements["competitive benchmark comparison"]["reason"]
assert "candidateRuns >= 20" in reason
PY

MARKET_EVIDENCE="$TMPDIR/market-evidence.jsonl"
cat "$PROD_EVIDENCE" > "$MARKET_EVIDENCE"
cat >> "$MARKET_EVIDENCE" <<'JSONL'
{"name":"competitive benchmark comparison","status":"passed","durationMs":1000,"command":"./scripts/compare-benchmarks.py --results traces/bench-comparison/results.jsonl --candidate zmr --baseline baseline --min-candidate-pass-rate 100 --max-candidate-failures 0 --min-mean-speedup 1.25 --min-p95-speedup 1.25","candidatePassRate":100,"candidateFailures":0,"candidateRuns":20,"baselineRuns":20,"meanSpeedup":1.25,"p95Speedup":1.25,"sameContext":true,"context":{"platform":"android","device":"emulator-5554","appId":"com.example.mobiletest","scenario":".zmr/login.json","appBuild":"debug-20260518"}}
JSONL

"$ROOT/scripts/release-readiness.sh" --evidence "$MARKET_EVIDENCE" --target market-claim --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["ok"] is True; requirements={item["name"]: item for item in data["requirements"]}; assert requirements["competitive benchmark comparison"]["status"] == "satisfied"'

blocked_text_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$FLAG_ONLY_MEASURED_MARKET_EVIDENCE" --target market-claim 2>&1 || true)"
grep -q 'Blocked requirements' <<< "$blocked_text_output"
grep -q 'competitive benchmark comparison: insufficient' <<< "$blocked_text_output"
grep -q 'candidatePassRate >= minCandidatePassRate' <<< "$blocked_text_output"
grep -q 'Next steps' <<< "$blocked_text_output"
grep -q 'zmr-compare-benchmarks --results traces/bench-comparison/results.jsonl' <<< "$blocked_text_output"

text_output="$("$ROOT/scripts/release-readiness.sh" --evidence "$LOCAL_EVIDENCE" --target production 2>&1 || true)"
grep -q 'ZMR release readiness: blocked' <<< "$text_output"
grep -q 'Satisfied requirements' <<< "$text_output"
grep -q -- '- local release gate' <<< "$text_output"
grep -q -- '- public Android demo' <<< "$text_output"
grep -q -- '- public iOS simulator demo' <<< "$text_output"
grep -q 'Missing evidence' <<< "$text_output"

RUN_READY="$TMPDIR/run-evidence-ready"
python3 "$RUN_EVIDENCE_GENERATOR" "$RUN_READY" ready
run_ready_output="$("$ROOT/scripts/release-readiness.sh" \
  --evidence "$LOCAL_EVIDENCE" \
  --run-summary "$RUN_READY" \
  --attempt-index "$RUN_READY/attempt-index.json" \
  --certification-min-executions 2 \
  --target dev-preview --json)"
python3 - "$run_ready_output" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
assert value["ok"] is True
run = value["runEvidence"]
assert run["attempts"] == 3
assert run["logicalExecutions"] == 2
assert run["eligibleLogicalExecutions"] == 2
assert run["firstAttemptPassRate"] == 50.0
assert run["eventualPassRate"] == 100.0
assert run["classificationCounts"] == {
    "passed": 2,
    "runner_failure": 0,
    "app_failure": 1,
    "infrastructure_failure": 0,
    "configuration_failure": 0,
    "cancelled": 0,
}
assert run["certificationMinimum"] == 2
assert run["certificationReady"] is True
assert run["blockingReasons"] == []
assert run["diagnostics"] == []
assert len(run["cohorts"]) == 1
assert run["cohorts"][0]["candidateRevision"] == "a" * 40
assert run["cohorts"][0]["comparabilityKey"].startswith("sha256:")
PY
node --input-type=module - "$ROOT/schemas/release-readiness-output.schema.json" "$run_ready_output" <<'NODE'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";

const schema = JSON.parse(readFileSync(process.argv[2], "utf8"));
const value = JSON.parse(process.argv[3]);
const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);
assert.equal(validate(value), true, JSON.stringify(validate.errors, null, 2));
NODE

RUN_RUNNER="$TMPDIR/run-evidence-runner"
python3 "$RUN_EVIDENCE_GENERATOR" "$RUN_RUNNER" runner
assert_blocked_run_evidence "$RUN_RUNNER" 2
runner_output="$("$ROOT/scripts/release-readiness.sh" \
  --evidence "$LOCAL_EVIDENCE" --run-summary "$RUN_RUNNER" \
  --attempt-index "$RUN_RUNNER/attempt-index.json" \
  --certification-min-executions 2 --target dev-preview --json 2>/dev/null || true)"
python3 - "$runner_output" <<'PY'
import json
import sys

run = json.loads(sys.argv[1])["runEvidence"]
assert run["eventualPassRate"] == 100.0
assert run["classificationCounts"]["runner_failure"] == 1
assert "runner failure occurred in certification cohort" in run["blockingReasons"]
PY

RUN_MINIMUM_299="$TMPDIR/run-evidence-minimum-299"
RUN_MINIMUM_300="$TMPDIR/run-evidence-minimum-300"
python3 "$RUN_EVIDENCE_GENERATOR" "$RUN_MINIMUM_299" minimum 299
python3 "$RUN_EVIDENCE_GENERATOR" "$RUN_MINIMUM_300" minimum 300
assert_blocked_run_evidence "$RUN_MINIMUM_299" 300
minimum_300_output="$("$ROOT/scripts/release-readiness.sh" \
  --evidence "$LOCAL_EVIDENCE" --run-summary "$RUN_MINIMUM_300" \
  --attempt-index "$RUN_MINIMUM_300/attempt-index.json" \
  --target dev-preview --json)"
python3 - "$minimum_300_output" <<'PY'
import json
import sys

run = json.loads(sys.argv[1])["runEvidence"]
assert run["logicalExecutions"] == 300
assert run["eligibleLogicalExecutions"] == 300
assert run["certificationMinimum"] == 300
assert run["certificationReady"] is True
PY

for mode in mismatched-key incomplete mixed; do
  publication="$TMPDIR/run-evidence-$mode"
  python3 "$RUN_EVIDENCE_GENERATOR" "$publication" "$mode"
  assert_blocked_run_evidence "$publication" 1
done

mixed_output="$("$ROOT/scripts/release-readiness.sh" \
  --evidence "$LOCAL_EVIDENCE" --run-summary "$TMPDIR/run-evidence-mixed" \
  --attempt-index "$TMPDIR/run-evidence-mixed/attempt-index.json" \
  --certification-min-executions 1 --target dev-preview --json 2>/dev/null || true)"
python3 - "$mixed_output" <<'PY'
import json
import sys

run = json.loads(sys.argv[1])["runEvidence"]
assert len(run["cohorts"]) == 2
assert "certification evidence spans multiple candidate revisions or comparability keys" in run["blockingReasons"]
PY

for mode in duplicate-run-id missing-attempt-one nonmonotonic-attempts changed-retry-identity path-escape indexed-missing-summary unindexed-summary; do
  publication="$TMPDIR/run-evidence-$mode"
  python3 "$RUN_EVIDENCE_GENERATOR" "$publication" "$mode"
  assert_blocked_run_evidence "$publication" 1
done

RUN_DIRECT="$TMPDIR/run-evidence-direct"
python3 "$RUN_EVIDENCE_GENERATOR" "$RUN_DIRECT" ready
direct_output="$("$ROOT/scripts/release-readiness.sh" \
  --evidence "$LOCAL_EVIDENCE" \
  --run-summary "$RUN_DIRECT/attempts/logical-1-attempt-1/run-summary.json" \
  --run-summary "$RUN_DIRECT/attempts/logical-1-attempt-2/run-summary.json" \
  --run-summary "$RUN_DIRECT/attempts/logical-2-attempt-1/run-summary.json" \
  --certification-min-executions 2 --target dev-preview --json)"
python3 - "$direct_output" <<'PY'
import json
import sys

run = json.loads(sys.argv[1])["runEvidence"]
assert run["attempts"] == 3
assert run["logicalExecutions"] == 2
assert run["certificationReady"] is True
PY
