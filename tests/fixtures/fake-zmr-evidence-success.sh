#!/usr/bin/env bash
set -euo pipefail

action=${1:-}
shift || true
case "$action" in
  version)
    printf 'zmr 1.0.0\n'
    ;;
  validate|doctor)
    ;;
  devices)
    printf '%s\n' '{"count":1,"devices":[{"serial":"fake-ios-1","state":"booted"}]}'
    ;;
  run)
    trace_dir=
    outcome_file=
    platform=android
    ios_device_type=simulator
    ios_shim_mode=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --trace-dir) trace_dir=${2:-}; shift 2 ;;
        --outcome-file) outcome_file=${2:-}; shift 2 ;;
        --platform) platform=${2:-}; shift 2 ;;
        --ios-device-type) ios_device_type=${2:-}; shift 2 ;;
        --ios-shim-mode) ios_shim_mode=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "$trace_dir" && -n "$outcome_file" ]]
    trace_relative=${trace_dir#"$ZMR_RUN_EVIDENCE_ROOT"/}
    [[ "$trace_relative" != "$trace_dir" ]]
    mkdir -p "$trace_dir"
    printf '%s\n' '{"event":"scenario-start"}' > "$trace_dir/trace.jsonl"
    ios_shim=null
    if [[ "$platform" == ios ]]; then
      [[ "$ios_shim_mode" == disabled || "$ios_shim_mode" == generated || "$ios_shim_mode" == provided ]]
      target_kind=simulator
      [[ "$ios_device_type" != physical ]] || target_kind=physical
      digest=null
      if [[ "$ios_shim_mode" != disabled ]]; then
        digest='"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
      fi
      ios_shim="{\"targetKind\":\"$target_kind\",\"mode\":\"$ios_shim_mode\",\"digest\":$digest}"
    fi
    printf '%s\n' "{\"schemaVersion\":1,\"status\":\"passed\",\"failureOwner\":\"none\",\"errorCode\":null,\"phase\":\"complete\",\"summary\":null,\"hint\":null,\"trace\":\"$trace_relative\",\"report\":null,\"childStatus\":0,\"iosShim\":$ios_shim}" > "$ZMR_RUN_EVIDENCE_ROOT/$outcome_file"
    ;;
  report)
    shift
    report=
    junit=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --out) report=${2:-}; shift 2 ;;
        --junit) junit=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'report\n' > "$report"
    printf '<testsuite/>\n' > "$junit"
    ;;
  export)
    shift
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --out ]]; then
        printf 'bundle\n' > "${2:?}"
        exit 0
      fi
      shift
    done
    exit 2
    ;;
  *)
    exit 2
    ;;
esac
