#!/bin/bash
set -u

export ZMR_RUN_EVIDENCE_ROOT=$1
export ZMR_RUN_EVIDENCE_INDEX=$2
export ZMR_EVIDENCE_ADAPTER_PATH=$3
source "$ZMR_EVIDENCE_ADAPTER_PATH"

/bin/bash -c '
  source "$ZMR_EVIDENCE_ADAPTER_PATH"
  zmr_evidence_event scenario.execute started "" "borrowed" ""
  zmr_evidence_finalize_failure runner_failure scenario.execute runner.unclassified \
    "borrower failed" "inspect borrower"
'
[ ! -e "$ZMR_RUN_EVIDENCE_ROOT/run-summary.json" ] || exit 81
zmr_evidence_event scenario.execute failed runner.unclassified "owner observed borrower" ""
