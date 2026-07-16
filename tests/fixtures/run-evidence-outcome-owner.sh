#!/bin/bash
set -u

export ZMR_RUN_EVIDENCE_ROOT=$1
export ZMR_RUN_EVIDENCE_INDEX=$2
adapter=$3
fake_zmr=$4
export FAKE_ZMR_ARGV_LOG=$5

source "$adapter" || exit $?
zmr_evidence_run_outcome scenario.execute zmr-run generated -- \
  /bin/bash "$fake_zmr" run scenario.json \
  --trace-dir "$ZMR_RUN_EVIDENCE_ROOT/traces/outcome" \
  --ios-shim fake-generated-shim
