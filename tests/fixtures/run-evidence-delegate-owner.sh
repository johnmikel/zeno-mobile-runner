#!/bin/bash
set -u

export ZMR_RUN_EVIDENCE_ROOT=$1
export ZMR_RUN_EVIDENCE_INDEX=$2
adapter=$3
borrower=$4

source "$adapter" || exit $?
zmr_evidence_delegate scenario.execute nested-pilot runner.unclassified -- \
  /bin/bash "$borrower" "$adapter"
