#!/bin/bash
set -u

export ZMR_RUN_EVIDENCE_ROOT=$1
export ZMR_RUN_EVIDENCE_INDEX=$2
export ZMR_EVIDENCE_ADAPTER_PATH=$3
export CLEANUP_LOG=$4
export UNSAFE_MARKER=$5
source "$ZMR_EVIDENCE_ADAPTER_PATH"

cleanup_one() {
  printf 'one:%s\n' "$1" >>"$CLEANUP_LOG"
}

cleanup_two() {
  printf 'two:%s\n' "$1" >>"$CLEANUP_LOG"
}

zmr_evidence_register_cleanup cleanup_one "space value"
zmr_evidence_register_cleanup cleanup_two $'line one\nline two'

before=$-
zmr_evidence_run scenario.execute foreground runner.unclassified -- \
  /bin/bash -c 'IFS= read -r value; printf "stdin:%s" "$value"' \
  <<<"inherited value"
after=$-
[ "$before" = "$after" ] || exit 91

captured=unchanged
zmr_evidence_capture captured report.generate stdout-capture runner.report_failed -- \
  /bin/bash -c 'printf "alpha\n\n"'
[ "$captured" = alpha ] || exit 94

status=old-status
zmr_evidence_capture status report.generate collision-safe runner.report_failed -- \
  /bin/bash -c 'printf "collision-safe"'
[ "$status" = collision-safe ] || exit 100

captured_out=old-out
captured_err=old-err
zmr_evidence_capture_both captured_out captured_err report.generate dual-capture runner.report_failed -- \
  /bin/bash -c 'printf "out value\n"; printf "err value\n" >&2'
[ "$captured_out" = "out value" ] || exit 95
[ "$captured_err" = "err value" ] || exit 96

phase=old-phase
name=old-name
zmr_evidence_capture_both phase name report.generate dual-collision runner.report_failed -- \
  /bin/bash -c 'printf "phase-value"; printf "name-value" >&2'
[ "$phase" = phase-value ] || exit 101
[ "$name" = name-value ] || exit 102

if zmr_evidence_capture 'bad-name;touch "$UNSAFE_MARKER"' scenario.execute unsafe runner.unclassified -- \
    /bin/bash -c 'touch "$UNSAFE_MARKER"' 2>/dev/null; then
  exit 97
fi
[ ! -e "$UNSAFE_MARKER" ] || exit 98

phase=
zmr_evidence_run_background phase cleanup background runner.cleanup_failed --expected-stop -- \
  /bin/bash -c 'trap "exit 0" TERM; while :; do sleep 1; done'
handle=$phase
[ -n "$handle" ] || exit 99
zmr_evidence_stop "$handle" expected
zmr_evidence_wait "$handle"

zmr_evidence_event report.generate passed "" "report complete" ""
zmr_evidence_update_context '{"runtimeVersion":"18.5"}'
zmr_evidence_finalize_pass
