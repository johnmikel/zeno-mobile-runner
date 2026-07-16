#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ADAPTER="$ROOT/scripts/run-evidence.sh"
EVIDENCE="$ROOT/scripts/run_evidence.py"
PYTHON=${PYTHON:-python3}
TMP_ROOT=${TMPDIR:-/tmp}/zmr-run-evidence-acceptance.$$
SECRET_VALUE=acceptance-secret-value

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM
mkdir -p "$TMP_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

context_json() {
  local run_id=$1
  printf '%s' "{\"runId\":\"$run_id\",\"executionId\":\"execution-$run_id\",\"fixtureId\":\"fixture-ios\",\"fixtureVersion\":\"1\",\"candidateRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"scenarioDigest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"appBuildDigest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"platform\":\"ios\",\"deviceClass\":\"ios-simulator\",\"runtimeVersion\":\"18.5\",\"timingMode\":\"cold-command\",\"runnerVersion\":\"0.2.17\",\"protocolVersion\":\"2026-04-28\",\"attempt\":1,\"host\":{\"os\":\"macos\",\"arch\":\"arm64\",\"class\":\"acceptance\",\"ci\":false},\"device\":{\"requested\":\"booted\",\"resolved\":\"simulator-udid\"},\"toolchain\":{\"xcode\":\"16.4\",\"zig\":\"0.16.0\"},\"artifacts\":{\"trace\":null,\"report\":null}}"
}

assert_attempt() {
  local attempt=$1 phase=$2 code=$3 classification=$4 shell_status=$5
  "$PYTHON" - "$attempt" "$phase" "$code" "$classification" "$shell_status" "$SECRET_VALUE" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
phase, code, classification = sys.argv[2:5]
shell_status = int(sys.argv[5])
secret = sys.argv[6].encode()
summaries = list(root.glob("run-summary*.json"))
assert [path.name for path in summaries] == ["run-summary.json"], summaries
summary = json.loads(summaries[0].read_text(encoding="utf-8"))
assert summary["status"] == "failed", summary
assert summary["phase"] == phase, summary
assert summary["errorCode"] == code, summary
assert summary["classification"] == classification, summary
assert summary["commandStatus"] == shell_status, summary

events = [
    json.loads(line)
    for line in (root / "bootstrap-events.jsonl").read_text(encoding="utf-8").splitlines()
    if line
]
assert [event["seq"] for event in events] == list(range(1, len(events) + 1))
assert events[-2]["status"] == "failed", events
assert events[-2]["phase"] == phase, events
assert events[-2]["errorCode"] == code, events
assert events[-1]["phase"] == phase, events
assert events[-1]["status"] == "failed", events
assert events[-1]["errorCode"] == code, events

metadata_paths = sorted((root / "commands").glob("*.json"))
assert len(metadata_paths) == 1, metadata_paths
metadata = json.loads(metadata_paths[0].read_text(encoding="utf-8"))
assert metadata["configuredFailureCode"] == code
assert metadata["termination"]["shellVisibleStatus"] == shell_status
for stream_name in ("stdout", "stderr"):
    stream = metadata[stream_name]
    path = root / stream["path"]
    content = path.read_bytes()
    assert len(content) == stream["storedBytes"]
    assert len(content) <= 10 * 1024 * 1024
    assert secret not in content
    assert str(root).encode() not in content
assert not (root / ".evidence-control").exists()
assert not (root / ".evidence-control.retiring").exists()
PY
  "$PYTHON" "$EVIDENCE" validate --summary "$attempt/run-summary.json" >/dev/null
  "$PYTHON" "$EVIDENCE" validate-bundle --root "$attempt" >/dev/null
}

ROWS=(
  "device-acquire|device.acquire|infra.simulator_provision|infrastructure_failure"
  "app-install|app.install|config.app_artifact_missing|configuration_failure"
  "shim-build|shim.build|runner.ios_shim.build_failed|runner_failure"
  "shim-ready|shim.prewarm|runner.ios_shim.readiness_timeout|runner_failure"
  "scenario|scenario.execute|app.assertion_failed|app_failure"
  "report|report.generate|runner.report_failed|runner_failure"
  "unsupported-device|device.acquire|config.unsupported_capability|configuration_failure"
  "unknown-failure|scenario.execute|runner.unclassified|runner_failure"
)

for row in "${ROWS[@]}"; do
  IFS='|' read -r run_id phase code classification <<<"$row"
  publication="$TMP_ROOT/$run_id"
  attempt="$publication/attempts/$run_id"
  index="$publication/attempt-index.json"
  mkdir -p "$publication/attempts"
  set +e
  output=$(API_TOKEN="$SECRET_VALUE" /bin/bash "$ADAPTER" \
    --root "$attempt" \
    --index "$index" \
    --context-json "$(context_json "$run_id")" \
    --phase "$phase" \
    --failure-classification "$classification" \
    --failure-code "$code" \
    --failure-hint "Inspect bounded command evidence." \
    -- /bin/bash -c 'printf "stdout:%s:%s" "$API_TOKEN" "$1"; printf "stderr:%s:%s" "$API_TOKEN" "$1" >&2; exit 17' _ "$attempt/private-input" \
    2>&1)
  status=$?
  set -e
  [ "$status" -eq 17 ] || fail "$run_id returned $status instead of 17: $output"
  case $output in
    *"$SECRET_VALUE"*|*"$attempt"*) fail "$run_id replay leaked sensitive content" ;;
  esac
  assert_attempt "$attempt" "$phase" "$code" "$classification" 17
done

# These focused process cases cover boundaries that require real process groups,
# crash recovery, or takeover rather than a fake failing command.
"$PYTHON" -W error -m unittest \
  tests.run_evidence_cases.command_supervisor.CommandSupervisorTests.test_owner_sigterm_persists_cancel_before_forwarding_to_group \
  tests.run_evidence_cases.command_supervisor.CommandSupervisorTests.test_expected_stop_is_write_ahead_and_maps_to_shell_success \
  tests.run_evidence_cases.command_supervisor.CommandSupervisorTests.test_kill_escalation_is_write_ahead_cleanup_failure \
  tests.run_evidence_cases.command_supervisor.CommandSupervisorTests.test_lost_supervisor_recovery_stops_group_and_materializes_once \
  tests.run_evidence_cases.session.SessionAuthorityTests.test_orphan_takeover_increments_generation_and_stales_old_authority \
  tests.run_evidence_cases.commands.CommandCaptureTests.test_compatibility_capture_overflow_fails_fast_and_retires_session \
  tests.run_evidence_cases.lifecycle.LifecycleTests.test_invalid_candidate_is_preserved_and_schema_valid_fallback_is_terminal \
  >/dev/null

echo "PASS: ${#ROWS[@]} command boundaries, evidence invalidation, and durable process controls"
