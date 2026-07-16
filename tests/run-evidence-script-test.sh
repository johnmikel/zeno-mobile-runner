#!/bin/bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ADAPTER="$ROOT/scripts/run-evidence.sh"
PYTHON=${PYTHON:-python3}
EVIDENCE="$ROOT/scripts/run_evidence.py"
TMP_ROOT=${TMPDIR:-/tmp}/zmr-run-evidence-script-test.$$
PASS_COUNT=0

cleanup_test_root() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_test_root EXIT INT TERM
mkdir -p "$TMP_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$1], got [$2]: $3"
}

assert_file_contains() {
  grep -F -- "$2" "$1" >/dev/null 2>&1 || fail "$1 does not contain [$2]"
}

context_json() {
  run_id=$1
  printf '%s' "{\"runId\":\"$run_id\",\"executionId\":\"execution-$run_id\",\"fixtureId\":\"fixture-ios\",\"fixtureVersion\":\"1\",\"candidateRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"scenarioDigest\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"appBuildDigest\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"platform\":\"ios\",\"deviceClass\":\"ios-simulator\",\"runtimeVersion\":\"18.5\",\"timingMode\":\"cold-command\",\"runnerVersion\":\"0.2.17\",\"protocolVersion\":\"2026-04-28\",\"attempt\":1,\"host\":{\"os\":\"macos\",\"arch\":\"arm64\",\"class\":\"local-test\",\"ci\":false},\"device\":{\"requested\":\"booted\",\"resolved\":\"simulator-udid\"},\"toolchain\":{\"xcode\":\"16.4\",\"zig\":\"0.16.0\"},\"artifacts\":{\"trace\":null,\"report\":null}}"
}

new_attempt() {
  case_name=$1
  run_id=$2
  publication="$TMP_ROOT/$case_name"
  attempt="$publication/attempts/$run_id"
  index="$publication/attempt-index.json"
  mkdir -p "$publication/attempts"
  "$PYTHON" "$EVIDENCE" init \
    --root "$attempt" \
    --index "$index" \
    --context-json "$(context_json "$run_id")" >/dev/null || return
  printf '%s\n%s\n' "$attempt" "$index"
}

summary_field() {
  "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "$1" "$2"
}

test_bash_32_syntax() {
  /bin/bash -n "$ADAPTER" || fail "adapter does not parse with system Bash"
  if grep -E '(^|[^[:alnum:]_])(declare -A|local -n|mapfile|readarray|wait -n|&>>)' "$ADAPTER" >/dev/null 2>&1; then
    fail "adapter contains a Bash 4-only construct"
  fi
  pass
}

test_wrapper_success_and_failure() {
  publication="$TMP_ROOT/wrapper-success"
  attempt="$publication/attempts/wrapper-success"
  index="$publication/attempt-index.json"
  mkdir -p "$publication/attempts"
  output=$(/bin/bash "$ADAPTER" \
    --root "$attempt" \
    --index "$index" \
    --context-json "$(context_json wrapper-success)" \
    --phase scenario.execute \
    --failure-classification runner_failure \
    --failure-code runner.unclassified \
    --failure-hint "inspect wrapper logs" \
    -- /bin/bash -c 'printf "wrapper output"') || fail "successful wrapper failed"
  assert_eq "wrapper output" "$output" "wrapper stdout"
  assert_eq "passed" "$(summary_field "$attempt/run-summary.json" status)" "wrapper status"
  [ ! -e "$attempt/.evidence-control" ] || fail "wrapper left private control state"
  "$PYTHON" "$EVIDENCE" validate-bundle --root "$attempt" >/dev/null || fail "wrapper bundle invalid"

  publication="$TMP_ROOT/wrapper-failure"
  attempt="$publication/attempts/wrapper-failure"
  index="$publication/attempt-index.json"
  mkdir -p "$publication/attempts"
  if /bin/bash "$ADAPTER" \
    --root "$attempt" \
    --index "$index" \
    --context-json "$(context_json wrapper-failure)" \
    --phase scenario.execute \
    --failure-classification runner_failure \
    --failure-code runner.unclassified \
    --failure-hint "inspect wrapper failure" \
    -- /bin/bash -c 'exit 7'; then
    fail "failing wrapper returned success"
  else
    status=$?
  fi
  assert_eq 7 "$status" "wrapper shell status"
  assert_eq failed "$(summary_field "$attempt/run-summary.json" status)" "failed wrapper summary"
  assert_eq runner.unclassified "$(summary_field "$attempt/run-summary.json" errorCode)" "failed wrapper code"
  pass
}

test_sourced_commands_capture_background_and_cleanup() {
  paths=$(new_attempt sourced sourced-run) || fail "could not initialize sourced attempt"
  attempt=$(printf '%s\n' "$paths" | sed -n '1p')
  index=$(printf '%s\n' "$paths" | sed -n '2p')
  owner="$ROOT/tests/fixtures/run-evidence-sourced-owner.sh"
  cleanup_log="$TMP_ROOT/sourced-cleanup.log"
  marker="$TMP_ROOT/unsafe-destination-ran"

  output=$(/bin/bash "$owner" "$attempt" "$index" "$ADAPTER" "$cleanup_log" "$marker") || fail "sourced owner failed"
  assert_eq "stdin:inherited value" "$output" "foreground stdin/stdout"
  assert_eq passed "$(summary_field "$attempt/run-summary.json" status)" "sourced summary"
  first=$(sed -n '1p' "$cleanup_log")
  assert_eq "two:line one" "$first" "LIFO cleanup first callback"
  assert_file_contains "$cleanup_log" "line two"
  assert_file_contains "$cleanup_log" "one:space value"
  "$PYTHON" "$EVIDENCE" validate-bundle --root "$attempt" >/dev/null || fail "sourced bundle invalid"
  pass
}

test_borrower_defers_without_finalizing() {
  paths=$(new_attempt borrower borrower-run) || fail "could not initialize borrower attempt"
  attempt=$(printf '%s\n' "$paths" | sed -n '1p')
  index=$(printf '%s\n' "$paths" | sed -n '2p')
  owner="$ROOT/tests/fixtures/run-evidence-borrower-owner.sh"
  /bin/bash "$owner" "$attempt" "$index" "$ADAPTER" || fail "borrower owner flow failed"
  assert_eq failed "$(summary_field "$attempt/run-summary.json" status)" "borrower deferred summary"
  assert_eq runner.unclassified "$(summary_field "$attempt/run-summary.json" errorCode)" "borrower error code"
  pass
}

test_structured_run_outcome_is_supervised_consumed_and_finalized() {
  paths=$(new_attempt outcome outcome-run) || fail "could not initialize outcome attempt"
  attempt=$(printf '%s\n' "$paths" | sed -n '1p')
  index=$(printf '%s\n' "$paths" | sed -n '2p')
  owner="$ROOT/tests/fixtures/run-evidence-outcome-owner.sh"
  fake_zmr="$ROOT/tests/fixtures/fake-zmr-outcome.sh"
  argv_log="$TMP_ROOT/outcome-argv.log"

  /bin/bash "$owner" "$attempt" "$index" "$ADAPTER" "$fake_zmr" "$argv_log" || \
    fail "structured outcome owner failed"
  assert_file_contains "$argv_log" "--outcome-file run-outcomes/"
  assert_file_contains "$argv_log" "--ios-shim-mode generated"
  assert_eq passed "$(summary_field "$attempt/run-summary.json" status)" "outcome summary"
  assert_eq traces/outcome "$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifacts"]["trace"])' "$attempt/run-context.json")" "outcome trace"
  outcome_count=$(find "$attempt/run-outcomes" -type f -name '*.json' | wc -l | tr -d ' ')
  assert_eq 1 "$outcome_count" "retained outcome count"
  "$PYTHON" "$EVIDENCE" validate-bundle --root "$attempt" >/dev/null || fail "outcome bundle invalid"
  pass
}

test_invalid_run_outcome_has_one_stable_owner_and_publishable_bundle() {
  paths=$(new_attempt outcome-invalid outcome-invalid-run) || fail "could not initialize invalid outcome attempt"
  attempt=$(printf '%s\n' "$paths" | sed -n '1p')
  index=$(printf '%s\n' "$paths" | sed -n '2p')
  owner="$ROOT/tests/fixtures/run-evidence-outcome-owner.sh"
  fake_zmr="$ROOT/tests/fixtures/fake-zmr-outcome.sh"
  argv_log="$TMP_ROOT/outcome-invalid-argv.log"

  if FAKE_ZMR_OUTCOME_MODE=invalid /bin/bash "$owner" "$attempt" "$index" "$ADAPTER" "$fake_zmr" "$argv_log"; then
    fail "invalid structured outcome returned success"
  else
    status=$?
  fi
  assert_eq 125 "$status" "invalid outcome shell status"
  assert_eq failed "$(summary_field "$attempt/run-summary.json" status)" "invalid outcome summary status"
  assert_eq runner.evidence_invalid "$(summary_field "$attempt/run-summary.json" errorCode)" "invalid outcome summary code"
  outcome_count=$(find "$attempt/run-outcomes" -type f -name '*.json' | wc -l | tr -d ' ')
  assert_eq 0 "$outcome_count" "invalid sidecar quarantine"
  "$PYTHON" "$EVIDENCE" validate-bundle --root "$attempt" >/dev/null || fail "invalid outcome fallback bundle invalid"
  pass
}

test_delegate_preserves_borrower_terminal_owner() {
  paths=$(new_attempt delegate delegate-run) || fail "could not initialize delegate attempt"
  attempt=$(printf '%s\n' "$paths" | sed -n '1p')
  index=$(printf '%s\n' "$paths" | sed -n '2p')
  owner="$ROOT/tests/fixtures/run-evidence-delegate-owner.sh"
  borrower="$ROOT/tests/fixtures/run-evidence-exact-borrower.sh"

  if /bin/bash "$owner" "$attempt" "$index" "$ADAPTER" "$borrower"; then
    fail "failing delegate returned success"
  else
    status=$?
  fi
  assert_eq 1 "$status" "delegate shell status"
  assert_eq app_failure "$(summary_field "$attempt/run-summary.json" classification)" "delegate classification"
  assert_eq app.assertion_failed "$(summary_field "$attempt/run-summary.json" errorCode)" "delegate error code"
  "$PYTHON" "$EVIDENCE" validate-bundle --root "$attempt" >/dev/null || fail "delegate bundle invalid"
  pass
}

test_bash_32_syntax
test_wrapper_success_and_failure
test_sourced_commands_capture_background_and_cleanup
test_borrower_defers_without_finalizing
test_structured_run_outcome_is_supervised_consumed_and_finalized
test_invalid_run_outcome_has_one_stable_owner_and_publishable_bundle
test_delegate_preserves_borrower_terminal_owner

echo "PASS: $PASS_COUNT run-evidence Bash adapter groups"
