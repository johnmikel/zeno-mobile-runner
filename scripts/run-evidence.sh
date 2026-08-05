#!/bin/bash

# GNU Bash 3.2 adapter for the durable Python evidence authority.

_ZMR_EVIDENCE_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_ZMR_EVIDENCE_PYTHON=${ZMR_EVIDENCE_PYTHON:-python3}
_ZMR_EVIDENCE_CLI="$_ZMR_EVIDENCE_SCRIPT_DIR/run_evidence.py"
_ZMR_EVIDENCE_ROLE=${_ZMR_EVIDENCE_ROLE:-}
_ZMR_EVIDENCE_INTENT_RECORDED=${_ZMR_EVIDENCE_INTENT_RECORDED:-0}
_ZMR_EVIDENCE_DISPATCHING=0
_ZMR_EVIDENCE_CLEANUPS=()
_ZMR_EVIDENCE_COMMAND_IDS=()
_ZMR_EVIDENCE_COMMAND_PIDS=()
_ZMR_EVIDENCE_COMMAND_PHASES=()
_ZMR_EVIDENCE_COMMAND_NAMES=()
_ZMR_EVIDENCE_COMMAND_FAILURE_CODES=()
_ZMR_EVIDENCE_COMMAND_FAILURE_POLICIES=()

_zmr_evidence_enabled() {
  [ -n "${ZMR_RUN_EVIDENCE_ROOT:-}" ]
}

_zmr_evidence_require_session_pair() {
  if [ -z "${ZMR_EVIDENCE_SESSION_ID:-}" ] || [ -z "${ZMR_EVIDENCE_SESSION_GENERATION:-}" ]; then
    echo "error: evidence session is not attached" >&2
    return 125
  fi
}

_zmr_evidence_valid_destination() {
  case ${1:-} in
    ''|[0-9]*|*[!a-zA-Z0-9_]*|_zmr_*|_ZMR_*) return 1 ;;
    *) return 0 ;;
  esac
}

_zmr_evidence_expect_separator() {
  [ "${1:-}" = "--" ] || {
    echo "error: expected -- before command argv" >&2
    return 2
  }
}

_zmr_evidence_command_id() {
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-id
}

_zmr_evidence_json_field() {
  "$_ZMR_EVIDENCE_PYTHON" -c '
import json,sys
value=json.loads(sys.stdin.read())
field=value[sys.argv[1]]
if field is None:
    raise SystemExit(3)
print(field)
' "$1"
}

_zmr_evidence_failure_classification() {
  "$_ZMR_EVIDENCE_PYTHON" -c '
import sys
from scripts.run_evidence_lib.contracts import ERROR_CLASSIFICATION
try:
    print(ERROR_CLASSIFICATION[sys.argv[1]])
except KeyError:
    raise SystemExit(2)
' "$1"
}

_zmr_evidence_intent_json() {
  "$_ZMR_EVIDENCE_PYTHON" -c '
import json,sys
status,classification,phase,error_code,summary,hint,command_status,source=sys.argv[1:]
value={"status":status,"classification":classification,"phase":phase,
       "commandStatus":None if command_status=="" else int(command_status),
       "source":source}
if status!="passed":
    value.update(errorCode=error_code,summary=summary,hint=hint)
print(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False))
' "$@"
}

_zmr_evidence_record_intent() {
  _zmr_evidence_require_session_pair || return
  local intent
  if ! intent=$(_zmr_evidence_intent_json "$@"); then
    return 125
  fi
  if "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" session-intent \
      --root "$ZMR_RUN_EVIDENCE_ROOT" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" \
      --intent-json "$intent" >/dev/null; then
    _ZMR_EVIDENCE_INTENT_RECORDED=1
    return 0
  fi
  return 125
}

_zmr_evidence_record_command_failure() {
  local phase=$1
  local name=$2
  local failure_code=$3
  local command_status=$4
  local classification
  if ! classification=$(_zmr_evidence_failure_classification "$failure_code"); then
    classification=runner_failure
    failure_code=runner.unclassified
  fi
  zmr_evidence_finalize_failure \
    "$classification" "$phase" "$failure_code" \
    "$name failed with status $command_status" \
    "Inspect the command metadata and bounded logs." \
    "$command_status"
}

_zmr_evidence_attach_new_owner() {
  local fifo_base=${TMPDIR:-/tmp}/zmr-evidence-claim.$$.${RANDOM:-0}
  local fifo=$fifo_base.fifo
  local claim_pid claim_json claim_status old_umask fields
  old_umask=$(umask)
  umask 077
  if ! mkfifo "$fifo"; then
    umask "$old_umask"
    return 125
  fi
  umask "$old_umask"
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" session-claim \
    --root "$ZMR_RUN_EVIDENCE_ROOT" --owner-pid "$$" >"$fifo" &
  claim_pid=$!
  claim_json=
  IFS= read -r claim_json <"$fifo"
  if wait "$claim_pid"; then claim_status=0; else claim_status=$?; fi
  rm -f "$fifo"
  [ "$claim_status" -eq 0 ] && [ -n "$claim_json" ] || return 125
  if ! fields=$(printf '%s' "$claim_json" | "$_ZMR_EVIDENCE_PYTHON" -c '
import json,sys
value=json.load(sys.stdin)
session=value["sessionId"]
generation=value["generation"]
if not isinstance(session,str) or len(session)!=32 or not isinstance(generation,int):
    raise SystemExit(2)
print(session, generation)
'); then
    return 125
  fi
  set -- $fields
  [ "$#" -eq 2 ] || return 125
  ZMR_EVIDENCE_SESSION_ID=$1
  ZMR_EVIDENCE_SESSION_GENERATION=$2
  export ZMR_EVIDENCE_SESSION_ID ZMR_EVIDENCE_SESSION_GENERATION
  _ZMR_EVIDENCE_ROLE=owner
}

_zmr_evidence_attach_inherited() {
  _zmr_evidence_require_session_pair || return
  if ! "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" session-status \
      --root "$ZMR_RUN_EVIDENCE_ROOT" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" >/dev/null; then
    return 125
  fi
  if [ "$_ZMR_EVIDENCE_ROLE" != owner ]; then
    _ZMR_EVIDENCE_ROLE=borrower
  fi
}

_zmr_evidence_install_traps() {
  trap '_zmr_evidence_signal_dispatch INT' INT
  trap '_zmr_evidence_signal_dispatch TERM' TERM
  trap '_zmr_evidence_exit_dispatch "$?"' EXIT
}

_zmr_evidence_attach() {
  _zmr_evidence_enabled || return 0
  local canonical_root
  if ! canonical_root=$(CDPATH= cd -- "$ZMR_RUN_EVIDENCE_ROOT" && pwd -P); then
    return 125
  fi
  ZMR_RUN_EVIDENCE_ROOT=$canonical_root
  export ZMR_RUN_EVIDENCE_ROOT
  if [ -n "${ZMR_EVIDENCE_SESSION_ID:-}" ] || [ -n "${ZMR_EVIDENCE_SESSION_GENERATION:-}" ]; then
    _zmr_evidence_attach_inherited || return
  else
    _zmr_evidence_attach_new_owner || return
  fi
  _zmr_evidence_install_traps
}

zmr_evidence_register_cleanup() {
  [ "$#" -ge 1 ] || return 2
  local callback=$1 encoded= piece argument
  shift
  if ! declare -F "$callback" >/dev/null 2>&1; then
    echo "error: cleanup callback is not a shell function: $callback" >&2
    return 2
  fi
  printf -v piece '%q' "$callback"
  encoded=$piece
  for argument in "$@"; do
    printf -v piece '%q' "$argument"
    encoded="$encoded $piece"
  done
  _ZMR_EVIDENCE_CLEANUPS[${#_ZMR_EVIDENCE_CLEANUPS[@]}]=$encoded
}

_zmr_evidence_run_cleanups() {
  local index status=0
  index=${#_ZMR_EVIDENCE_CLEANUPS[@]}
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    if eval "${_ZMR_EVIDENCE_CLEANUPS[$index]}"; then
      :
    else
      status=$?
    fi
  done
  _ZMR_EVIDENCE_CLEANUPS=()
  return "$status"
}

zmr_evidence_event() {
  [ "$#" -ge 2 ] || return 2
  local phase=$1 status=$2 error_code=${3:-} summary=${4:-} artifact=${5:-}
  shift 2
  _zmr_evidence_enabled || return 0
  local args
  args=(event --root "$ZMR_RUN_EVIDENCE_ROOT" --phase "$phase" --status "$status"
    --session-id "$ZMR_EVIDENCE_SESSION_ID"
    --generation "$ZMR_EVIDENCE_SESSION_GENERATION")
  [ -z "$error_code" ] || args+=(--error-code "$error_code")
  [ -z "$summary" ] || args+=(--summary "$summary")
  [ -z "$artifact" ] || args+=(--artifact "$artifact")
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" "${args[@]}" >/dev/null
}

_zmr_evidence_supervise() {
  local mode=$1 failure_policy=$2 stop_policy=$3 stdin_policy=$4
  local phase=$5 name=$6 failure_code=$7 command_id=$8
  shift 8
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-supervise \
    --root "$ZMR_RUN_EVIDENCE_ROOT" \
    --command-id "$command_id" \
    --session-id "$ZMR_EVIDENCE_SESSION_ID" \
    --generation "$ZMR_EVIDENCE_SESSION_GENERATION" \
    --phase "$phase" --name "$name" --failure-code "$failure_code" \
    --failure-policy "$failure_policy" --stop-policy "$stop_policy" \
    --mode "$mode" --stdin-policy "$stdin_policy" -- "$@"
}

_zmr_evidence_run_policy() {
  local failure_policy=$1
  shift
  [ "$#" -ge 5 ] || return 2
  local phase=$1 name=$2 failure_code=$3 separator=$4 command_id status
  shift 4
  _zmr_evidence_expect_separator "$separator" || return
  [ "$#" -gt 0 ] || return 2
  if ! _zmr_evidence_enabled; then
    "$@"
    return $?
  fi
  _zmr_evidence_require_session_pair || return
  if ! command_id=$(_zmr_evidence_command_id); then return 125; fi
  if _zmr_evidence_supervise foreground "$failure_policy" none inherit \
      "$phase" "$name" "$failure_code" "$command_id" "$@"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ] && [ "$failure_policy" = terminal ]; then
    _zmr_evidence_record_command_failure "$phase" "$name" "$failure_code" "$status" || status=125
  fi
  return "$status"
}

zmr_evidence_run() {
  _zmr_evidence_run_policy terminal "$@"
}

zmr_evidence_try() {
  _zmr_evidence_run_policy handled "$@"
}

zmr_evidence_run_outcome() {
  [ "$#" -ge 5 ] || return 2
  local phase=$1 name=$2 ios_shim_mode=$3 separator=$4
  shift 4
  _zmr_evidence_expect_separator "$separator" || return
  [ "$#" -gt 0 ] || return 2
  case $ios_shim_mode in
    none|disabled|generated|provided) ;;
    *)
      echo "error: invalid iOS shim provenance mode" >&2
      return 2
      ;;
  esac
  if ! _zmr_evidence_enabled; then
    "$@"
    return $?
  fi
  _zmr_evidence_require_session_pair || return
  local command_id outcome_path status consumed consumed_status
  if ! command_id=$(_zmr_evidence_command_id); then return 125; fi
  outcome_path=run-outcomes/$command_id.json
  if [ "$ios_shim_mode" = none ]; then
    if _zmr_evidence_supervise foreground handled none inherit \
        "$phase" "$name" runner.unclassified "$command_id" \
        "$@" --outcome-file "$outcome_path"; then
      status=0
    else
      status=$?
    fi
  else
    if _zmr_evidence_supervise foreground handled none inherit \
        "$phase" "$name" runner.unclassified "$command_id" \
        "$@" --outcome-file "$outcome_path" \
        --ios-shim-mode "$ios_shim_mode"; then
      status=0
    else
      status=$?
    fi
  fi
  if ! consumed=$("$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" consume-outcome \
      --root "$ZMR_RUN_EVIDENCE_ROOT" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --path "$outcome_path"); then
    _ZMR_EVIDENCE_INTENT_RECORDED=1
    return 125
  fi
  if ! consumed_status=$(printf '%s' "$consumed" | _zmr_evidence_json_field status); then
    zmr_evidence_finalize_failure runner_failure scenario.execute runner.evidence_invalid \
      "Structured run outcome evidence is invalid" \
      "Inspect the bounded run-outcome sidecar and command binding" || :
    _ZMR_EVIDENCE_INTENT_RECORDED=1
    return 125
  fi
  case $consumed_status in
    passed) ;;
    failed|cancelled) _ZMR_EVIDENCE_INTENT_RECORDED=1 ;;
    *)
      zmr_evidence_finalize_failure runner_failure scenario.execute runner.evidence_invalid \
        "Structured run outcome evidence is invalid" \
        "Inspect the bounded run-outcome sidecar and command binding" || :
      _ZMR_EVIDENCE_INTENT_RECORDED=1
      return 125
      ;;
  esac
  return "$status"
}

_zmr_evidence_decode_capture() {
  local command_id=$1 stream=$2
  "$_ZMR_EVIDENCE_PYTHON" -c '
import sys
from scripts.run_evidence_lib.command_supervisor import decode_capture_envelope
value=decode_capture_envelope(sys.stdin.buffer.read(), expected_command_id=sys.argv[1])
content=value[sys.argv[2]]
if content is None:
    raise SystemExit(4)
sys.stdout.buffer.write(content)
' "$command_id" "$stream"
}

_zmr_evidence_capture_one_policy() {
  local _zmr_failure_policy=$1
  shift
  local _zmr_destination=$1 _zmr_phase=$2 _zmr_name=$3 _zmr_failure_code=$4 _zmr_separator=$5
  shift 5
  _zmr_evidence_valid_destination "$_zmr_destination" || {
    echo "error: unsafe capture destination" >&2
    return 2
  }
  _zmr_evidence_expect_separator "$_zmr_separator" || return
  [ "$#" -gt 0 ] || return 2
  if ! _zmr_evidence_enabled; then
    local _zmr_disabled_value _zmr_disabled_status
    if _zmr_disabled_value=$("$@"); then _zmr_disabled_status=0; else _zmr_disabled_status=$?; fi
    printf -v "$_zmr_destination" '%s' "$_zmr_disabled_value"
    return "$_zmr_disabled_status"
  fi
  local _zmr_command_id _zmr_envelope _zmr_decoded _zmr_status _zmr_decode_status _zmr_had_xtrace=0
  if ! _zmr_command_id=$(_zmr_evidence_command_id); then return 125; fi
  case $- in *x*) _zmr_had_xtrace=1; set +x ;; esac
  if _zmr_envelope=$("$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-supervise \
      --root "$ZMR_RUN_EVIDENCE_ROOT" --command-id "$_zmr_command_id" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" \
      --phase "$_zmr_phase" --name "$_zmr_name" --failure-code "$_zmr_failure_code" \
      --failure-policy "$_zmr_failure_policy" --stop-policy none \
      --mode capture-stdout --stdin-policy inherit --capture-fd 3 \
      -- "$@" 3>&1); then
    _zmr_status=0
  else
    _zmr_status=$?
  fi
  _zmr_decoded=
  if _zmr_decoded=$(printf '%s' "$_zmr_envelope" | _zmr_evidence_decode_capture "$_zmr_command_id" stdout); then
    _zmr_decode_status=0
  else
    _zmr_decode_status=$?
  fi
  unset _zmr_envelope
  if [ "$_zmr_decode_status" -eq 0 ]; then
    printf -v "$_zmr_destination" '%s' "$_zmr_decoded"
  else
    _zmr_status=125
  fi
  unset _zmr_decoded
  [ "$_zmr_had_xtrace" -eq 0 ] || set -x
  if [ "$_zmr_status" -ne 0 ] && [ "$_zmr_failure_policy" = terminal ]; then
    if [ "$_zmr_decode_status" -eq 0 ]; then
      _zmr_evidence_record_command_failure "$_zmr_phase" "$_zmr_name" "$_zmr_failure_code" "$_zmr_status" || _zmr_status=125
    else
      _zmr_evidence_record_command_failure "$_zmr_phase" "$_zmr_name" runner.capture_failed 125 || _zmr_status=125
    fi
  fi
  return "$_zmr_status"
}

zmr_evidence_capture() {
  [ "$#" -ge 6 ] || return 2
  _zmr_evidence_capture_one_policy terminal "$@"
}

zmr_evidence_try_capture() {
  [ "$#" -ge 6 ] || return 2
  _zmr_evidence_capture_one_policy handled "$@"
}

_zmr_evidence_capture_both_policy() {
  local _zmr_failure_policy=$1
  shift
  [ "$#" -ge 7 ] || return 2
  local _zmr_stdout_destination=$1 _zmr_stderr_destination=$2 _zmr_phase=$3 _zmr_name=$4 _zmr_failure_code=$5 _zmr_separator=$6
  shift 6
  _zmr_evidence_valid_destination "$_zmr_stdout_destination" || return 2
  _zmr_evidence_valid_destination "$_zmr_stderr_destination" || return 2
  [ "$_zmr_stdout_destination" != "$_zmr_stderr_destination" ] || return 2
  _zmr_evidence_expect_separator "$_zmr_separator" || return
  [ "$#" -gt 0 ] || return 2
  if ! _zmr_evidence_enabled; then
    echo "error: dual capture requires an evidence session" >&2
    return 125
  fi
  local _zmr_command_id _zmr_envelope _zmr_stdout_value _zmr_stderr_value _zmr_status _zmr_stdout_status _zmr_stderr_status _zmr_had_xtrace=0
  if ! _zmr_command_id=$(_zmr_evidence_command_id); then return 125; fi
  case $- in *x*) _zmr_had_xtrace=1; set +x ;; esac
  if _zmr_envelope=$("$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-supervise \
      --root "$ZMR_RUN_EVIDENCE_ROOT" --command-id "$_zmr_command_id" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" \
      --phase "$_zmr_phase" --name "$_zmr_name" --failure-code "$_zmr_failure_code" \
      --failure-policy "$_zmr_failure_policy" --stop-policy none \
      --mode capture-both --stdin-policy inherit --capture-fd 3 \
      -- "$@" 3>&1); then _zmr_status=0; else _zmr_status=$?; fi
  _zmr_stdout_value=
  _zmr_stderr_value=
  if _zmr_stdout_value=$(printf '%s' "$_zmr_envelope" | _zmr_evidence_decode_capture "$_zmr_command_id" stdout); then _zmr_stdout_status=0; else _zmr_stdout_status=$?; fi
  if _zmr_stderr_value=$(printf '%s' "$_zmr_envelope" | _zmr_evidence_decode_capture "$_zmr_command_id" stderr); then _zmr_stderr_status=0; else _zmr_stderr_status=$?; fi
  unset _zmr_envelope
  if [ "$_zmr_stdout_status" -eq 0 ] && [ "$_zmr_stderr_status" -eq 0 ]; then
    printf -v "$_zmr_stdout_destination" '%s' "$_zmr_stdout_value"
    printf -v "$_zmr_stderr_destination" '%s' "$_zmr_stderr_value"
  else
    _zmr_status=125
  fi
  unset _zmr_stdout_value _zmr_stderr_value
  [ "$_zmr_had_xtrace" -eq 0 ] || set -x
  if [ "$_zmr_status" -ne 0 ] && [ "$_zmr_failure_policy" = terminal ]; then
    if [ "$_zmr_stdout_status" -eq 0 ] && [ "$_zmr_stderr_status" -eq 0 ]; then
      _zmr_evidence_record_command_failure "$_zmr_phase" "$_zmr_name" "$_zmr_failure_code" "$_zmr_status" || _zmr_status=125
    else
      _zmr_evidence_record_command_failure "$_zmr_phase" "$_zmr_name" runner.capture_failed 125 || _zmr_status=125
    fi
  fi
  return "$_zmr_status"
}

zmr_evidence_capture_both() {
  [ "$#" -ge 7 ] || return 2
  _zmr_evidence_capture_both_policy terminal "$@"
}

zmr_evidence_try_capture_both() {
  [ "$#" -ge 7 ] || return 2
  _zmr_evidence_capture_both_policy handled "$@"
}

_zmr_evidence_register_background() {
  local command_id=$1 pid=$2 phase=$3 name=$4 failure_code=$5 failure_policy=$6
  local index=${#_ZMR_EVIDENCE_COMMAND_IDS[@]}
  _ZMR_EVIDENCE_COMMAND_IDS[$index]=$command_id
  _ZMR_EVIDENCE_COMMAND_PIDS[$index]=$pid
  _ZMR_EVIDENCE_COMMAND_PHASES[$index]=$phase
  _ZMR_EVIDENCE_COMMAND_NAMES[$index]=$name
  _ZMR_EVIDENCE_COMMAND_FAILURE_CODES[$index]=$failure_code
  _ZMR_EVIDENCE_COMMAND_FAILURE_POLICIES[$index]=$failure_policy
}

_zmr_evidence_background_index() {
  local wanted=$1 index=0
  while [ "$index" -lt "${#_ZMR_EVIDENCE_COMMAND_IDS[@]}" ]; do
    if [ "${_ZMR_EVIDENCE_COMMAND_IDS[$index]}" = "$wanted" ]; then
      printf '%s\n' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

zmr_evidence_run_background() {
  [ "$#" -ge 7 ] || return 2
  local _zmr_destination=$1 _zmr_phase=$2 _zmr_name=$3 _zmr_failure_code=$4
  shift 4
  _zmr_evidence_valid_destination "$_zmr_destination" || return 2
  local _zmr_stop_policy=none
  if [ "${1:-}" = --expected-stop ]; then
    _zmr_stop_policy=expected-term
    shift
  fi
  _zmr_evidence_expect_separator "${1:-}" || return
  shift
  [ "$#" -gt 0 ] || return 2
  if ! _zmr_evidence_enabled; then
    "$@" &
    printf -v "$_zmr_destination" '%s' "$!"
    return 0
  fi
  local _zmr_command_id _zmr_supervisor_pid _zmr_status_json _zmr_stage _zmr_attempts=0
  if ! _zmr_command_id=$(_zmr_evidence_command_id); then return 125; fi
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-supervise \
    --root "$ZMR_RUN_EVIDENCE_ROOT" --command-id "$_zmr_command_id" \
    --session-id "$ZMR_EVIDENCE_SESSION_ID" \
    --generation "$ZMR_EVIDENCE_SESSION_GENERATION" \
    --phase "$_zmr_phase" --name "$_zmr_name" --failure-code "$_zmr_failure_code" \
    --failure-policy terminal --stop-policy "$_zmr_stop_policy" \
    --mode background --stdin-policy devnull -- "$@" &
  _zmr_supervisor_pid=$!
  _zmr_evidence_register_background "$_zmr_command_id" "$_zmr_supervisor_pid" "$_zmr_phase" "$_zmr_name" "$_zmr_failure_code" terminal
  while [ "$_zmr_attempts" -lt 100 ]; do
    _zmr_status_json=
    if _zmr_status_json=$("$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-status \
        --root "$ZMR_RUN_EVIDENCE_ROOT" --command-id "$_zmr_command_id" \
        --session-id "$ZMR_EVIDENCE_SESSION_ID" \
        --generation "$ZMR_EVIDENCE_SESSION_GENERATION" 2>/dev/null); then
      if _zmr_stage=$(printf '%s' "$_zmr_status_json" | _zmr_evidence_json_field stage); then
        case $_zmr_stage in
          running|stop_requested|committed)
            printf -v "$_zmr_destination" '%s' "$_zmr_command_id"
            return 0
            ;;
        esac
      fi
    fi
    _zmr_attempts=$((_zmr_attempts + 1))
    sleep 0.05
  done
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-recover \
    --root "$ZMR_RUN_EVIDENCE_ROOT" \
    --session-id "$ZMR_EVIDENCE_SESSION_ID" \
    --generation "$ZMR_EVIDENCE_SESSION_GENERATION" --cancel-live >/dev/null 2>&1 || :
  return 125
}

zmr_evidence_wait() {
  [ "$#" -eq 1 ] || return 2
  local command_id=$1 status_json shell_status index
  if ! _zmr_evidence_enabled; then
    wait "$command_id"
    return $?
  fi
  if ! status_json=$("$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-status \
      --root "$ZMR_RUN_EVIDENCE_ROOT" --command-id "$command_id" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" --wait); then
    return 125
  fi
  if ! shell_status=$(printf '%s' "$status_json" | _zmr_evidence_json_field shellStatus); then
    return 125
  fi
  if index=$(_zmr_evidence_background_index "$command_id"); then
    wait "${_ZMR_EVIDENCE_COMMAND_PIDS[$index]}" 2>/dev/null || :
    if [ "$shell_status" -ne 0 ] && [ "${_ZMR_EVIDENCE_COMMAND_FAILURE_POLICIES[$index]}" = terminal ]; then
      _zmr_evidence_record_command_failure \
        "${_ZMR_EVIDENCE_COMMAND_PHASES[$index]}" \
        "${_ZMR_EVIDENCE_COMMAND_NAMES[$index]}" \
        "${_ZMR_EVIDENCE_COMMAND_FAILURE_CODES[$index]}" \
        "$shell_status" || shell_status=125
    fi
  fi
  return "$shell_status"
}

zmr_evidence_stop() {
  [ "$#" -eq 2 ] || return 2
  local command_id=$1 kind=$2
  if ! _zmr_evidence_enabled; then
    kill -TERM "$command_id"
    return $?
  fi
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-stop \
    --root "$ZMR_RUN_EVIDENCE_ROOT" --command-id "$command_id" \
    --session-id "$ZMR_EVIDENCE_SESSION_ID" \
    --generation "$ZMR_EVIDENCE_SESSION_GENERATION" \
    --kind "$kind" >/dev/null
}

zmr_evidence_delegate() {
  _zmr_evidence_run_policy handled "$@"
}

zmr_evidence_update_context() {
  [ "$#" -eq 1 ] || return 2
  _zmr_evidence_enabled || return 0
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" context \
    --root "$ZMR_RUN_EVIDENCE_ROOT" --set-json "$1" \
    --session-id "$ZMR_EVIDENCE_SESSION_ID" \
    --generation "$ZMR_EVIDENCE_SESSION_GENERATION" >/dev/null
}

zmr_evidence_update_artifact_identity() {
  [ "$#" -ge 2 ] || return 2
  _zmr_evidence_enabled || return 0
  local scenario_path=$1 app_path=$2 patch
  shift 2
  if ! patch=$("$_ZMR_EVIDENCE_PYTHON" - "$app_path" "$scenario_path" "$@" <<'PY'
import hashlib
import json
import os
import stat
import sys


def feed(handle, value):
    encoded = value if isinstance(value, bytes) else value.encode("utf-8")
    handle.update(str(len(encoded)).encode("ascii"))
    handle.update(b":")
    handle.update(encoded)


def digest(path_text):
    path = os.path.abspath(path_text)
    metadata = os.lstat(path)
    handle = hashlib.sha256()
    if stat.S_ISREG(metadata.st_mode):
        handle.update(b"zmr-file-v1\0")
        with open(path, "rb") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                handle.update(chunk)
        return "sha256:" + handle.hexdigest()
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError("artifact identity input must be a file or directory")
    handle.update(b"zmr-tree-v1\0")
    for current, directories, files in os.walk(path, followlinks=False):
        directories.sort()
        files.sort()
        for name in directories + files:
            candidate = os.path.join(current, name)
            relative = os.path.relpath(candidate, path).replace(os.sep, "/")
            item = os.lstat(candidate)
            if stat.S_ISLNK(item.st_mode):
                handle.update(b"L")
                feed(handle, relative)
                feed(handle, os.readlink(candidate))
            elif stat.S_ISDIR(item.st_mode):
                handle.update(b"D")
                feed(handle, relative)
            elif stat.S_ISREG(item.st_mode):
                handle.update(b"F")
                feed(handle, relative)
                feed(handle, str(item.st_size))
                with open(candidate, "rb") as source:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        handle.update(chunk)
            else:
                raise ValueError("artifact tree contains an unsupported entry")
    return "sha256:" + handle.hexdigest()


def scenario_manifest(paths):
    entries = []
    labels = set()
    for path in paths:
        label = os.path.basename(os.path.normpath(path))
        if not label or label in labels:
            raise ValueError("scenario manifest labels must be unique basenames")
        labels.add(label)
        entries.append((label, digest(path)))
    handle = hashlib.sha256()
    handle.update(b"zmr-scenario-manifest-v1\0")
    for label, value in sorted(entries):
        feed(handle, label)
        feed(handle, value)
    return "sha256:" + handle.hexdigest()


print(json.dumps({
    "scenarioDigest": scenario_manifest(sys.argv[2:]),
    "appBuildDigest": digest(sys.argv[1]),
}, sort_keys=True, separators=(",", ":")))
PY
  ); then
    return 125
  fi
  zmr_evidence_update_context "$patch"
}

zmr_evidence_update_device_identity() {
  [ "$#" -eq 2 ] || return 2
  _zmr_evidence_enabled || return 0
  local resolved=$1 runtime_version=$2 patch
  if ! patch=$("$_ZMR_EVIDENCE_PYTHON" -c '
import json,sys
resolved,runtime=sys.argv[1:]
if not resolved:
    raise SystemExit(2)
patch={"device":{"resolved":resolved}}
if runtime:
    patch["runtimeVersion"]=runtime
print(json.dumps(patch,sort_keys=True,separators=(",",":")))
' "$resolved" "$runtime_version"); then
    return 125
  fi
  zmr_evidence_update_context "$patch"
}

zmr_evidence_register_artifact() {
  [ "$#" -eq 2 ] || return 2
  local field=$1 absolute_path=$2 relative patch
  _zmr_evidence_enabled || return 0
  case $field in trace|report) ;; *) return 2 ;; esac
  case $absolute_path in
    "$ZMR_RUN_EVIDENCE_ROOT"/*)
      relative=${absolute_path#"$ZMR_RUN_EVIDENCE_ROOT"/}
      ;;
    *)
      echo "error: evidence artifact is outside the attempt root" >&2
      return 125
      ;;
  esac
  if ! patch=$("$_ZMR_EVIDENCE_PYTHON" -c '
import json,sys
print(json.dumps({"artifacts":{sys.argv[1]:sys.argv[2]}},sort_keys=True,separators=(",",":")))
' "$field" "$relative"); then
    return 125
  fi
  zmr_evidence_update_context "$patch"
}

zmr_evidence_finalize_pass() {
  _zmr_evidence_enabled || return 0
  _zmr_evidence_record_intent passed passed evidence.finalize '' '' '' '' shell-adapter
}

zmr_evidence_finalize_failure() {
  [ "$#" -ge 5 ] || return 2
  local classification=$1 phase=$2 error_code=$3 summary=$4 hint=$5 command_status=${6:-} status=${7:-failed}
  _zmr_evidence_enabled || return 0
  _zmr_evidence_record_intent "$status" "$classification" "$phase" "$error_code" "$summary" "$hint" "$command_status" shell-adapter
}

_zmr_evidence_signal_dispatch() {
  local signal_name=$1
  trap - INT TERM
  if _zmr_evidence_enabled; then
    _zmr_evidence_record_intent cancelled cancelled cleanup run.cancelled \
      "Evidence owner received $signal_name" \
      "Inspect command evidence and retry the attempt." 130 shell-signal || :
    "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-recover \
      --root "$ZMR_RUN_EVIDENCE_ROOT" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" --cancel-live >/dev/null 2>&1 || :
  fi
  exit 130
}

_zmr_evidence_owner_finalize() {
  local original_status=$1 final_status=$1 cleanup_status=0
  if [ "$_ZMR_EVIDENCE_INTENT_RECORDED" -eq 0 ]; then
    if [ "$original_status" -eq 0 ]; then
      zmr_evidence_finalize_pass || final_status=125
    else
      zmr_evidence_finalize_failure runner_failure cleanup runner.unclassified \
        "Evidence owner exited with status $original_status" \
        "Inspect the owner shell and command evidence." "$original_status" || final_status=125
    fi
  fi
  if _zmr_evidence_run_cleanups; then :; else cleanup_status=$?; fi
  if [ "$cleanup_status" -ne 0 ]; then
    zmr_evidence_finalize_failure runner_failure cleanup runner.cleanup_failed \
      "Evidence cleanup failed with status $cleanup_status" \
      "Inspect the registered cleanup callback." "$cleanup_status" || :
    final_status=125
  fi
  if ! "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" session-close \
      --root "$ZMR_RUN_EVIDENCE_ROOT" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" >/dev/null; then
    return 125
  fi
  if ! "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" command-recover \
      --root "$ZMR_RUN_EVIDENCE_ROOT" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" --cancel-live >/dev/null; then
    return 125
  fi
  if ! "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" session-finalize \
      --root "$ZMR_RUN_EVIDENCE_ROOT" \
      --session-id "$ZMR_EVIDENCE_SESSION_ID" \
      --generation "$ZMR_EVIDENCE_SESSION_GENERATION" >/dev/null; then
    return 125
  fi
  if ! "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" validate-bundle \
      --root "$ZMR_RUN_EVIDENCE_ROOT" >/dev/null; then
    return 125
  fi
  return "$final_status"
}

_zmr_evidence_borrower_finalize() {
  local original_status=$1 cleanup_status=0
  if _zmr_evidence_run_cleanups; then :; else cleanup_status=$?; fi
  if [ "$cleanup_status" -ne 0 ]; then
    zmr_evidence_finalize_failure runner_failure cleanup runner.cleanup_failed \
      "Borrower cleanup failed with status $cleanup_status" \
      "Inspect the borrower cleanup callback." "$cleanup_status" || return 125
  elif [ "$original_status" -ne 0 ] && [ "$_ZMR_EVIDENCE_INTENT_RECORDED" -eq 0 ]; then
    zmr_evidence_finalize_failure runner_failure cleanup runner.unclassified \
      "Evidence borrower exited with status $original_status" \
      "Inspect the borrower shell and command evidence." "$original_status" || return 125
  fi
  return "$original_status"
}

_zmr_evidence_exit_dispatch() {
  local original_status=$1 final_status
  [ "$_ZMR_EVIDENCE_DISPATCHING" -eq 0 ] || return
  _ZMR_EVIDENCE_DISPATCHING=1
  trap - EXIT INT TERM
  if ! _zmr_evidence_enabled; then
    exit "$original_status"
  fi
  if [ "$_ZMR_EVIDENCE_ROLE" = owner ]; then
    if _zmr_evidence_owner_finalize "$original_status"; then final_status=0; else final_status=$?; fi
    if [ "$original_status" -ne 0 ] && [ "$final_status" -ne 125 ]; then
      final_status=$original_status
    fi
  else
    if _zmr_evidence_borrower_finalize "$original_status"; then final_status=0; else final_status=$?; fi
    if [ "$original_status" -ne 0 ] && [ "$final_status" -ne 125 ]; then
      final_status=$original_status
    fi
  fi
  exit "$final_status"
}

_zmr_evidence_wrapper_usage() {
  echo "usage: run-evidence.sh --root DIR --index FILE --context-json JSON --phase PHASE --failure-classification CLASS --failure-code CODE --failure-hint TEXT -- COMMAND [ARG ...]" >&2
  return 2
}

_zmr_evidence_wrapper_main() {
  local root= index= context_json= phase= failure_classification= failure_code= failure_hint=
  while [ "$#" -gt 0 ]; do
    case $1 in
      --root) [ "$#" -ge 2 ] || return 2; root=$2; shift 2 ;;
      --index) [ "$#" -ge 2 ] || return 2; index=$2; shift 2 ;;
      --context-json) [ "$#" -ge 2 ] || return 2; context_json=$2; shift 2 ;;
      --phase) [ "$#" -ge 2 ] || return 2; phase=$2; shift 2 ;;
      --failure-classification) [ "$#" -ge 2 ] || return 2; failure_classification=$2; shift 2 ;;
      --failure-code) [ "$#" -ge 2 ] || return 2; failure_code=$2; shift 2 ;;
      --failure-hint) [ "$#" -ge 2 ] || return 2; failure_hint=$2; shift 2 ;;
      --) shift; break ;;
      *) _zmr_evidence_wrapper_usage; return ;;
    esac
  done
  [ -n "$root" ] && [ -n "$index" ] && [ -n "$context_json" ] && \
    [ -n "$phase" ] && [ -n "$failure_classification" ] && \
    [ -n "$failure_code" ] && [ -n "$failure_hint" ] && [ "$#" -gt 0 ] || {
      _zmr_evidence_wrapper_usage
      return
    }
  "$_ZMR_EVIDENCE_PYTHON" "$_ZMR_EVIDENCE_CLI" init \
    --root "$root" --index "$index" --context-json "$context_json" >/dev/null || return 125
  ZMR_RUN_EVIDENCE_ROOT=$root
  ZMR_RUN_EVIDENCE_INDEX=$index
  export ZMR_RUN_EVIDENCE_ROOT ZMR_RUN_EVIDENCE_INDEX
  _zmr_evidence_attach || return 125
  local command_id status
  if ! command_id=$(_zmr_evidence_command_id); then return 125; fi
  if _zmr_evidence_supervise foreground terminal none inherit \
      "$phase" wrapper-command "$failure_code" "$command_id" "$@"; then
    status=0
    zmr_evidence_finalize_pass || status=125
  else
    status=$?
    zmr_evidence_finalize_failure "$failure_classification" "$phase" "$failure_code" \
      "Wrapper command failed with status $status" "$failure_hint" "$status" || status=125
  fi
  return "$status"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _zmr_evidence_wrapper_main "$@"
  exit $?
else
  if _zmr_evidence_enabled; then
    _zmr_evidence_attach || return $?
  fi
fi
