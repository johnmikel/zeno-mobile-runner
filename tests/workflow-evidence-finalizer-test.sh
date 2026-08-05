#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINALIZER="$ROOT/scripts/finalize-workflow-evidence.sh"
EVIDENCE="$ROOT/scripts/run_evidence.py"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

context_json() {
  local run_id="$1"
  printf '%s' "{\"runId\":\"$run_id\",\"executionId\":\"execution-$run_id\",\"fixtureId\":\"workflow-ios\",\"fixtureVersion\":\"1\",\"candidateRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"scenarioDigest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"appBuildDigest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"platform\":\"ios\",\"deviceClass\":\"ios-simulator\",\"runtimeVersion\":\"18.5\",\"timingMode\":\"cold-command\",\"runnerVersion\":\"1.0.0\",\"protocolVersion\":\"2026-04-28\",\"attempt\":1,\"host\":{\"os\":\"macos\",\"arch\":\"arm64\",\"class\":\"github-macos-15-arm64\",\"ci\":true},\"device\":{\"requested\":\"booted\",\"resolved\":\"simulator-udid\"},\"toolchain\":{\"xcode\":\"16.4\",\"zig\":\"0.16.0\"},\"artifacts\":{\"trace\":null,\"report\":null}}"
}

new_attempt() {
  local name="$1"
  publication="$TMP_ROOT/$name"
  attempt="$publication/attempts/$name"
  index="$publication/attempt-index.json"
  mkdir -p "$publication/attempts"
  python3 "$EVIDENCE" init --root "$attempt" --index "$index" \
    --context-json "$(context_json "$name")" >/dev/null
}

summary_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "$1" "$2"
}

assert_bundle() {
  python3 "$EVIDENCE" validate-bundle --root "$attempt" >/dev/null
}

assert_supersession_crash_recovers() {
  local stage="$1" position="$2" case_name="crash-$1-${2#-}"
  new_attempt "$case_name"
  python3 "$EVIDENCE" finalize --root "$attempt" --status passed >/dev/null

  set +e
  python3 - "$ROOT" "$attempt" "$index" "$stage" "$position" <<'PY'
import os
import sys
from pathlib import Path

repository, root, index, stage, position = sys.argv[1:]
sys.path.insert(0, str(Path(repository) / "scripts"))
import finalize_workflow_evidence as finalizer
import run_evidence_lib.journal as journal

if stage == "before_unlink":
    def crash_before_unlink(operation, phase, _destination):
        if operation == "journal" and phase == "before_unlink":
            os._exit(73)
    journal._safe_io_owner._rooted_io_checkpoint = crash_before_unlink
else:
    def crash_transaction(actual_stage, actual_position):
        if actual_stage == stage and actual_position == int(position):
            os._exit(73)
    journal._transaction_checkpoint = crash_transaction

finalizer.run(
    Path(root),
    Path(index),
    [
        finalizer.StepOutcome(
            "smoke", "failure", "scenario.execute", "runner.unclassified"
        )
    ],
)
PY
  crash_status=$?
  set -e
  [[ "$crash_status" -eq 73 ]] || {
    echo "supersession did not crash at $stage/$position" >&2
    exit 1
  }

  set +e
  "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:failure:scenario.execute:runner.unclassified >/dev/null
  retry_status=$?
  set -e
  [[ "$retry_status" -eq 1 ]] || {
    echo "supersession retry failed at $stage/$position: $retry_status" >&2
    exit 1
  }
  assert_bundle
  python3 - "$publication" "$attempt" <<'PY'
import json
import pathlib
import sys

publication = pathlib.Path(sys.argv[1])
attempt = pathlib.Path(sys.argv[2])
metadata = [
    json.load(open(path, encoding="utf-8"))
    for path in (attempt / "commands").glob("*.json")
]
assert [item["name"] for item in metadata].count("smoke") == 1
summary = json.load(open(attempt / "run-summary.json", encoding="utf-8"))
events = [
    json.loads(line)
    for line in open(attempt / "bootstrap-events.jsonl", encoding="utf-8")
    if line.strip()
]
matching = [
    event
    for event in events
    if event.get("phase") == summary["phase"]
    and event.get("status") == summary["status"]
    and event.get("errorCode") == summary["errorCode"]
    and event.get("summary") == summary["summary"]
]
assert len(matching) == 1
transaction_root = publication / ".transactions"
assert not transaction_root.exists() or not list(transaction_root.glob("*.json"))
PY
}

assert_failed_step() {
  local name="$1" phase="$2" code="$3" classification="$4"
  new_attempt "$name"
  if "$FINALIZER" --root "$attempt" --index "$index" \
      --step "$name:failure:$phase:$code"; then
    echo "workflow finalizer should return nonzero for $name" >&2
    exit 1
  fi
  [[ "$(summary_field "$attempt/run-summary.json" classification)" == "$classification" ]]
  [[ "$(summary_field "$attempt/run-summary.json" errorCode)" == "$code" ]]
  grep -q 'synthetic external command record' "$attempt"/commands/*.stdout.log
  assert_bundle
}

[[ -x "$FINALIZER" ]] || {
  echo "workflow evidence finalizer is missing or not executable" >&2
  exit 1
}

assert_failed_step setup-java invocation infra.network infrastructure_failure
assert_failed_step missing-zig invocation config.required_tool_missing configuration_failure
assert_failed_step android-emulator device.acquire infra.emulator_provision infrastructure_failure
assert_failed_step ios-simulator device.acquire infra.simulator_provision infrastructure_failure

new_attempt already-recorded-action
python3 "$EVIDENCE" external --root "$attempt" \
  --phase invocation --name setup-java --outcome failure \
  --failure-code infra.network \
  --remediation 'Inspect the hosted action log' >/dev/null 2>&1 || true
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step setup-java:failure:invocation:infra.network; then
  echo "pre-recorded failed action should remain nonzero" >&2
  exit 1
fi
test "$(find "$attempt/commands" -name '*.json' -type f | wc -l | tr -d ' ')" -eq 1
assert_bundle

new_attempt existing-specific
python3 "$EVIDENCE" external --root "$attempt" \
  --phase scenario.execute --name smoke --outcome failure \
  --failure-code app.assertion_failed \
  --remediation 'Scenario assertion failed while the driver remained healthy' >/dev/null 2>&1 || true
python3 "$EVIDENCE" finalize --root "$attempt" --status failed \
  --classification app_failure --phase scenario.execute \
  --error-code app.assertion_failed \
  --summary 'Scenario assertion failed while the driver remained healthy' \
  --hint 'Inspect the trace failure and app state' >/dev/null
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:failure:scenario.execute:runner.unclassified; then
  echo "existing app failure should remain a nonzero terminal result" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == app.assertion_failed ]]
assert_bundle

new_attempt corrupted-durable-bundle
python3 "$EVIDENCE" external --root "$attempt" \
  --phase scenario.execute --name smoke --outcome failure \
  --failure-code app.assertion_failed \
  --remediation 'Scenario assertion failed while the driver remained healthy' >/dev/null 2>&1 || true
python3 "$EVIDENCE" finalize --root "$attempt" --status failed \
  --classification app_failure --phase scenario.execute \
  --error-code app.assertion_failed \
  --summary 'Scenario assertion failed while the driver remained healthy' \
  --hint 'Inspect the trace failure and app state' >/dev/null
rm "$attempt"/commands/*.stdout.log
set +e
"$FINALIZER" --root "$attempt" --index "$index" \
  --step smoke:failure:scenario.execute:runner.unclassified >/dev/null 2>&1
corrupted_status=$?
set -e
[[ "$corrupted_status" -eq 2 ]]
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == app.assertion_failed ]]

new_attempt passed-smoke-action-failed
python3 "$EVIDENCE" finalize --root "$attempt" --status passed >/dev/null
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:failure:scenario.execute:runner.unclassified; then
  echo "a failed hosted smoke action must override its passed inner summary" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == runner.unclassified ]]
grep -q 'synthetic external command record' "$attempt"/commands/*.stdout.log
assert_bundle

for boundary in \
  prepared:-1 \
  target:0 \
  target:1 \
  target:2 \
  target:3 \
  target:4 \
  target:5 \
  before_unlink:-1 \
  committed:-1; do
  assert_supersession_crash_recovers "${boundary%%:*}" "${boundary#*:}"
done

new_attempt hostile-supersession-wal
python3 "$EVIDENCE" finalize --root "$attempt" --status passed >/dev/null
set +e
python3 - "$ROOT" "$attempt" "$index" <<'PY'
import os
import sys
from pathlib import Path

repository, root, index = sys.argv[1:]
sys.path.insert(0, str(Path(repository) / "scripts"))
import finalize_workflow_evidence as finalizer
import run_evidence_lib.journal as journal

def crash_transaction(stage, position):
    if stage == "prepared" and position == -1:
        os._exit(73)

journal._transaction_checkpoint = crash_transaction
finalizer.run(
    Path(root),
    Path(index),
    [
        finalizer.StepOutcome(
            "smoke", "failure", "scenario.execute", "runner.unclassified"
        )
    ],
)
PY
hostile_prepare_status=$?
set -e
[[ "$hostile_prepare_status" -eq 73 ]]
python3 - "$ROOT" "$publication" <<'PY'
import base64
import copy
import hashlib
import json
import sys
from pathlib import Path

repository, publication = sys.argv[1:]
sys.path.insert(0, str(Path(repository) / "scripts"))
from run_evidence_lib import journal, safe_io
from run_evidence_lib.contracts import validate_summary

publication = Path(publication)
journal_path = next((publication / ".transactions").glob("*.json"))
original = json.load(open(journal_path, encoding="utf-8"))


def content(target):
    return base64.b64decode(target["contentBase64"], validate=True)


def json_value(target):
    return json.loads(content(target))


def json_bytes(value):
    return (
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def replace(target, encoded):
    target["contentBase64"] = base64.b64encode(encoded).decode("ascii")
    target["sha256"] = "sha256:" + hashlib.sha256(encoded).hexdigest()


def target(candidate, suffix):
    return next(item for item in candidate["targets"] if item["path"].endswith(suffix))


def mutate_terminal(label, mutation):
    candidate = copy.deepcopy(original)
    summary_target = target(candidate, "/run-summary.json")
    events_target = target(candidate, "/bootstrap-events.jsonl")
    receipt_target = target(candidate, "/finalize-receipt.json")
    summary = json_value(summary_target)
    events = [json.loads(line) for line in content(events_target).splitlines()]
    mutation(summary, events[-1])
    errors = validate_summary(summary)
    assert not errors, (label, errors)
    summary_content = json_bytes(summary)
    replace(summary_target, summary_content)
    replace(events_target, b"".join(json_bytes(event) for event in events))
    receipt = json_value(receipt_target)
    receipt["resultSha256"] = "sha256:" + hashlib.sha256(summary_content).hexdigest()
    replace(receipt_target, json_bytes(receipt))
    assert_rejected(label, candidate)


def assert_rejected(label, candidate):
    try:
        with safe_io._rooted_io(publication, mutation=False):
            journal._validate_transaction_journal(publication, candidate)
    except ValueError as exc:
        assert "disagrees with superseding terminal" in str(exc), (label, exc)
        return
    raise AssertionError(f"hostile {label} WAL was accepted")


mutate_terminal(
    "phase mismatch",
    lambda summary, event: (summary.update(phase="cleanup"), event.update(phase="cleanup")),
)
mutate_terminal(
    "code mismatch",
    lambda summary, event: (
        summary.update(errorCode="runner.cleanup_failed"),
        event.update(errorCode="runner.cleanup_failed"),
    ),
)
mutate_terminal(
    "outcome mismatch",
    lambda summary, event: (
        summary.update(
            status="cancelled",
            classification="cancelled",
            errorCode="run.cancelled",
            summary="Hosted workflow step smoke was cancelled",
            hint="Retry the workflow when capacity is available",
        ),
        event.update(
            status="cancelled",
            errorCode="run.cancelled",
            summary="Hosted workflow step smoke was cancelled",
        ),
    ),
)

renamed = copy.deepcopy(original)
metadata_target = next(
    item
    for item in renamed["targets"]
    if "/commands/" in item["path"] and item["path"].endswith(".json")
)
events_target = target(renamed, "/bootstrap-events.jsonl")
metadata = json_value(metadata_target)
events = [json.loads(line) for line in content(events_target).splitlines()]
old_stem = Path(metadata_target["path"]).stem
new_stem = old_stem[:7] + "other"
for item in renamed["targets"]:
    item["path"] = item["path"].replace(old_stem, new_stem)
metadata["name"] = "other"
for stream_name in ("stdout", "stderr"):
    metadata[stream_name]["path"] = metadata[stream_name]["path"].replace(
        old_stem, new_stem
    )
replace(metadata_target, json_bytes(metadata))
for event in events:
    for field in ("command", "artifact"):
        if field in event:
            event[field] = event[field].replace(old_stem, new_stem)
replace(events_target, b"".join(json_bytes(event) for event in events))
assert_rejected("command name mismatch", renamed)
PY

new_attempt cleanup-overrides-existing-app-failure
python3 "$EVIDENCE" external --root "$attempt" \
  --phase scenario.execute --name smoke --outcome failure \
  --failure-code app.assertion_failed \
  --remediation 'Scenario assertion failed while the driver remained healthy' >/dev/null 2>&1 || true
python3 "$EVIDENCE" finalize --root "$attempt" --status failed \
  --classification app_failure --phase scenario.execute \
  --error-code app.assertion_failed \
  --summary 'Scenario assertion failed while the driver remained healthy' \
  --hint 'Inspect the trace failure and app state' >/dev/null
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step cleanup:failure:cleanup:runner.cleanup_failed; then
  echo "cleanup failure must override an earlier app failure" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == runner.cleanup_failed ]]
assert_bundle

assert_failed_step smoke-without-summary scenario.execute runner.unclassified runner_failure

new_attempt invalid-summary
python3 - "$attempt/run-summary.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"schemaVersion": 1, "status": "passed", "unexpected": True}, handle)
PY
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:success:scenario.execute:runner.unclassified; then
  echo "invalid existing summary should remain nonzero" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == runner.evidence_invalid ]]
test -f "$attempt/run-summary.invalid.json"
test -f "$attempt/run-summary.invalid.errors.json"
python3 - "$attempt/run-summary.invalid.json" <<'PY'
import json
import sys

candidate = json.load(open(sys.argv[1], encoding="utf-8"))
assert candidate == {"schemaVersion": 1, "status": "passed", "unexpected": True}
PY
assert_bundle

new_attempt uncommitted-valid-summary
python3 "$EVIDENCE" finalize --root "$attempt" --status passed >/dev/null
rm "$attempt/finalize-receipt.json"
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:success:scenario.execute:runner.unclassified; then
  echo "valid summary without a durable receipt should be evidence-invalid" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == runner.evidence_invalid ]]
python3 - "$attempt/run-summary.invalid.json" <<'PY'
import json
import sys

candidate = json.load(open(sys.argv[1], encoding="utf-8"))
assert candidate["uncommittedTerminalSummary"]["status"] == "passed"
PY
assert_bundle

new_attempt malformed-summary
printf '{invalid-json' > "$attempt/run-summary.json"
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:success:scenario.execute:runner.unclassified; then
  echo "malformed existing summary should remain nonzero" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == runner.evidence_invalid ]]
python3 - "$attempt/run-summary.invalid.json" <<'PY'
import json
import sys

candidate = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(candidate) == {"invalidJsonSha256"}
assert candidate["invalidJsonSha256"].startswith("sha256:")
PY
assert_bundle

new_attempt oversized-summary
python3 - "$attempt/run-summary.json" <<'PY'
import sys

with open(sys.argv[1], "wb") as handle:
    handle.write(b"{" + b" " * (2 * 1024 * 1024 + 1))
PY
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:success:scenario.execute:runner.unclassified; then
  echo "oversized existing summary should remain nonzero" >&2
  exit 1
fi
python3 - "$attempt/run-summary.invalid.json" <<'PY'
import json
import sys

candidate = json.load(open(sys.argv[1], encoding="utf-8"))
assert candidate["invalidJsonSizeBytes"] > candidate["structuredJsonLimitBytes"]
PY
assert_bundle

new_attempt missing-summary-after-success
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step smoke:success:scenario.execute:runner.unclassified; then
  echo "successful workflow without a terminal summary should be evidence-invalid" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == runner.evidence_invalid ]]
assert_bundle

new_attempt cancelled
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step setup:cancelled:invocation:infra.network; then
  echo "cancelled workflow should return nonzero" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" status)" == cancelled ]]
[[ "$(summary_field "$attempt/run-summary.json" classification)" == cancelled ]]
assert_bundle

new_attempt cleanup-overrides-cancel
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step setup:cancelled:invocation:run.cancelled \
    --step cleanup:failure:cleanup:runner.cleanup_failed; then
  echo "cleanup failure should return nonzero" >&2
  exit 1
fi
[[ "$(summary_field "$attempt/run-summary.json" errorCode)" == runner.cleanup_failed ]]
[[ "$(summary_field "$attempt/run-summary.json" classification)" == runner_failure ]]
assert_bundle

new_attempt duplicate-mapping
if "$FINALIZER" --root "$attempt" --index "$index" \
    --step setup:success:invocation:runner.unclassified \
    --step setup:failure:invocation:runner.unclassified; then
  echo "duplicate workflow step mappings must fail" >&2
  exit 1
fi
test ! -e "$attempt/run-summary.json"

EMPTY_ROOT="$TMP_ROOT/nonempty-but-uninitialized"
mkdir -p "$EMPTY_ROOT"
python3 - "$EMPTY_ROOT/marker.json" <<'PY'
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"nonempty": True}, handle)
PY
if "$FINALIZER" --root "$EMPTY_ROOT" --index "$TMP_ROOT/missing-index.json" \
    --step smoke:success:scenario.execute:runner.unclassified; then
  echo "merely nonempty evidence root must not pass" >&2
  exit 1
fi

echo "PASS: workflow evidence finalizer"
