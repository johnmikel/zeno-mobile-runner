#!/bin/sh
if [ -z "${ZMR_BASH_BOOTSTRAP:-}" ]; then
  ZMR_BASH_BOOTSTRAP=1
  export ZMR_BASH_BOOTSTRAP
  SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
  if [ -z "${TMPDIR:-}" ] || [ ! -w "${TMPDIR:-/nonexistent}" ]; then
    TMPDIR="$ROOT/traces/tmp"
  fi
  mkdir -p "$TMPDIR"
  export TMPDIR
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

CALLER_CWD="$(pwd -P)"
# Some sandboxed environments do not allow writing to the default temp directory
# (/var/folders, /tmp). Use a caller-local TMPDIR so heredocs/mktemp work.
if [[ -z "${TMPDIR:-}" || ! -w "${TMPDIR:-/nonexistent}" ]]; then
  TMPDIR="$CALLER_CWD/traces/tmp"
  mkdir -p "$TMPDIR"
  export TMPDIR
fi

EVIDENCE_FILES=()
RUN_SUMMARIES=()
ATTEMPT_INDEX=""
CERTIFICATION_MIN_EXECUTIONS=""
TARGET="dev-preview"
JSON=0

usage() {
  printf '%s\n' 'Usage:'
  printf '%s\n' '  scripts/release-readiness.sh --evidence <evidence.jsonl> [--evidence <more.jsonl> ...] [--run-summary <file-or-publication-dir> ...] [--attempt-index <file>] [--certification-min-executions <n>] [--target dev-preview|production|market-claim] [--json]'
  printf '%s\n' ''
  printf '%s\n' 'Reads one or more release/pilot evidence JSONL files and reports whether the'
  printf '%s\n' 'requested release claim is supported by concrete passed evidence.'
  printf '%s\n' 'Run summaries add retry-aware certification evidence; their default minimum is 300 logical executions.'
  printf '%s\n' ''
  printf '%s\n' 'Targets:'
  printf '%s\n' '  dev-preview   Requires local release gate plus public Android and iOS demos.'
  printf '%s\n' '  production    Requires dev-preview evidence plus repeated real app/device pilots.'
  printf '%s\n' '  market-claim  Requires production evidence plus same-device/app/build benchmark comparison.'
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value"
  fi
  printf '%s\n' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence)
      EVIDENCE_FILES+=("$(require_value "$1" "${2-}")")
      shift 2
      ;;
    --run-summary)
      RUN_SUMMARIES+=("$(require_value "$1" "${2-}")")
      shift 2
      ;;
    --attempt-index)
      ATTEMPT_INDEX="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --certification-min-executions)
      CERTIFICATION_MIN_EXECUTIONS="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --target)
      TARGET="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --json)
      JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "${#EVIDENCE_FILES[@]}" -gt 0 ]] || die "--evidence is required"
for evidence_file in "${EVIDENCE_FILES[@]}"; do
  [[ -n "$evidence_file" ]] || die "--evidence requires a path"
  if [[ ! -f "$evidence_file" && "$JSON" -eq 0 ]]; then
    die "evidence file not found: $evidence_file"
  fi
done
if [[ -n "$ATTEMPT_INDEX" && "${#RUN_SUMMARIES[@]}" -eq 0 ]]; then
  die "--attempt-index requires --run-summary"
fi
if [[ -n "$CERTIFICATION_MIN_EXECUTIONS" ]]; then
  [[ "$CERTIFICATION_MIN_EXECUTIONS" =~ ^[1-9][0-9]*$ ]] || die "--certification-min-executions must be a positive integer"
  [[ "${#RUN_SUMMARIES[@]}" -gt 0 ]] || die "--certification-min-executions requires --run-summary"
elif [[ "${#RUN_SUMMARIES[@]}" -gt 0 ]]; then
  CERTIFICATION_MIN_EXECUTIONS=300
fi
[[ "$TARGET" == "dev-preview" || "$TARGET" == "production" || "$TARGET" == "market-claim" ]] || die "--target must be dev-preview, production, or market-claim"

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHON_ARGS=(--target "$TARGET")
[[ "$JSON" -eq 0 ]] || PYTHON_ARGS+=(--json)
for evidence_file in "${EVIDENCE_FILES[@]}"; do
  PYTHON_ARGS+=(--evidence "$evidence_file")
done
if [[ "${#RUN_SUMMARIES[@]}" -gt 0 ]]; then
  for run_summary in "${RUN_SUMMARIES[@]}"; do
    PYTHON_ARGS+=(--run-summary "$run_summary")
  done
fi
[[ -z "$ATTEMPT_INDEX" ]] || PYTHON_ARGS+=(--attempt-index "$ATTEMPT_INDEX")
[[ -z "$CERTIFICATION_MIN_EXECUTIONS" ]] || PYTHON_ARGS+=(--certification-min-executions "$CERTIFICATION_MIN_EXECUTIONS")
python3 "$SCRIPT_DIR/release-readiness.py" "${PYTHON_ARGS[@]}"
