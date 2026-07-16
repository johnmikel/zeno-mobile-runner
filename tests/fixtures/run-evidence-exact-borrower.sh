#!/bin/bash
set -u

adapter=$1

source "$adapter" || exit $?
zmr_evidence_finalize_failure app_failure scenario.execute app.assertion_failed \
  "Scenario assertion failed while the driver remained healthy" \
  "Inspect the trace failure and app state" || exit $?
exit 1
