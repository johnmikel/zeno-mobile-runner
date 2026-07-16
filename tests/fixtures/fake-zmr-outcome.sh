#!/bin/bash
set -u

outcome_file=
trace_dir=
shim_mode=
printf '%s\n' "$*" >"${FAKE_ZMR_ARGV_LOG:?}"
while [ "$#" -gt 0 ]; do
  case $1 in
    --outcome-file) outcome_file=${2:-}; shift 2 ;;
    --trace-dir) trace_dir=${2:-}; shift 2 ;;
    --ios-shim-mode) shim_mode=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$outcome_file" ] || exit 91
[ -n "$trace_dir" ] || exit 92
[ "$shim_mode" = generated ] || exit 93
case $trace_dir in
  "$ZMR_RUN_EVIDENCE_ROOT"/*) trace_relative=${trace_dir#"$ZMR_RUN_EVIDENCE_ROOT"/} ;;
  *) exit 94 ;;
esac
mkdir -p "$trace_dir"
printf '%s\n' '{"event":"scenario-start"}' >"$trace_dir/trace.jsonl"
if [ "${FAKE_ZMR_OUTCOME_MODE:-valid}" = invalid ]; then
  printf '%s\n' '{"schemaVersion":1,"status":"passed","unexpected":true}' >"$ZMR_RUN_EVIDENCE_ROOT/$outcome_file"
  exit 0
fi
printf '%s\n' "{\"schemaVersion\":1,\"status\":\"passed\",\"failureOwner\":\"none\",\"errorCode\":null,\"phase\":\"complete\",\"summary\":null,\"hint\":null,\"trace\":\"$trace_relative\",\"report\":null,\"childStatus\":0,\"iosShim\":{\"targetKind\":\"simulator\",\"mode\":\"generated\",\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}" >"$ZMR_RUN_EVIDENCE_ROOT/$outcome_file"
