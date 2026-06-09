#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'xcrun version 70\n'
  exit 0
fi

if [[ "${1:-}" == "devicectl" ]]; then
  shift
  json_output=""
  filtered=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json-output)
        json_output="${2:-}"
        shift 2
        ;;
      --quiet)
        shift
        ;;
      *)
        filtered+=("$1")
        shift
        ;;
    esac
  done
  set -- "${filtered[@]}"
  case "${1:-}" in
    list)
      if [[ "${2:-}" == "devices" && -n "$json_output" ]]; then
        cat > "$json_output" <<'JSON'
{"result":{"devices":[{"identifier":"fake-physical-ios-1","connectionProperties":{"pairingState":"paired","tunnelState":"connected"},"deviceProperties":{"name":"Fake iPhone"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"fake-hardware-udid-1"}}]}}
JSON
      else
        echo "unsupported devicectl list command: $*" >&2
        exit 2
      fi
      ;;
    device)
      case "${2:-}" in
        install)
          [[ "${3:-}" == "app" && "${4:-}" == "--device" && "${5:-}" == "fake-physical-ios-1" && "${6:-}" == "/tmp/Sample.app" ]] || {
            echo "unsupported devicectl install command: $*" >&2
            exit 2
          }
          ;;
        process)
          if [[ "${3:-}" == "launch" && "${4:-}" == "--device" && "${5:-}" == "fake-physical-ios-1" ]]; then
            exit 0
          fi
          if [[ "${3:-}" == "terminate" && "${4:-}" == "--device" && "${5:-}" == "fake-physical-ios-1" && "${6:-}" == "--pid" ]]; then
            exit 0
          fi
          echo "unsupported devicectl process command: $*" >&2
          exit 2
          ;;
        info)
          if [[ "${3:-}" == "processes" && "${4:-}" == "--device" && "${5:-}" == "fake-physical-ios-1" && -n "$json_output" ]]; then
            cat > "$json_output" <<'JSON'
{"result":{"processes":[{"processIdentifier":12345,"bundleIdentifier":"com.example.mobiletest"}]}}
JSON
            exit 0
          fi
          echo "unsupported devicectl info command: $*" >&2
          exit 2
          ;;
        uninstall)
          [[ "${3:-}" == "app" && "${4:-}" == "--device" && "${5:-}" == "fake-physical-ios-1" && "${6:-}" == "com.example.mobiletest" ]] || {
            echo "unsupported devicectl uninstall command: $*" >&2
            exit 2
          }
          ;;
        *)
          echo "unsupported devicectl device command: $*" >&2
          exit 2
          ;;
      esac
      ;;
    *)
      echo "unsupported devicectl command: $*" >&2
      exit 2
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" != "simctl" ]]; then
  echo "expected simctl or devicectl command: $*" >&2
  exit 2
fi
shift

case "${1:-}" in
  list)
    if [[ "${2:-}" == "devices" && "${3:-}" == "--json" ]]; then
      cat <<'JSON'
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {
        "name": "iPhone 16",
        "udid": "fake-ios-1",
        "state": "Booted",
        "isAvailable": true
      },
      {
        "name": "iPhone 15",
        "udid": "fake-ios-2",
        "state": "Shutdown",
        "isAvailable": true
      }
    ]
  }
}
JSON
    else
      echo "unsupported simctl list command: $*" >&2
      exit 2
    fi
    ;;
  install)
    [[ "${2:-}" == "fake-ios-1" && "${3:-}" == "/tmp/Sample.app" ]] || {
      echo "unsupported simctl install command: $*" >&2
      exit 2
    }
    ;;
  launch)
    [[ "${2:-}" == "fake-ios-1" && "${3:-}" == "com.example.mobiletest" ]] || {
      echo "unsupported simctl launch command: $*" >&2
      exit 2
    }
    printf 'com.example.mobiletest: 12345\n'
    ;;
  terminate)
    [[ "${2:-}" == "fake-ios-1" && "${3:-}" == "com.example.mobiletest" ]] || {
      echo "unsupported simctl terminate command: $*" >&2
      exit 2
    }
    ;;
  uninstall)
    [[ "${2:-}" == "fake-ios-1" && "${3:-}" == "com.example.mobiletest" ]] || {
      echo "unsupported simctl uninstall command: $*" >&2
      exit 2
    }
    ;;
  openurl)
    [[ "${2:-}" == "fake-ios-1" && ( "${3:-}" == "exampleapp:///e2e-auth?probe=1" || "${3:-}" == "https://example.com/e2e-auth?probe=1" ) ]] || {
      echo "unsupported simctl openurl command: $*" >&2
      exit 2
    }
    ;;
  io)
    if [[ "${2:-}" == "fake-ios-1" && "${3:-}" == "screenshot" && "${4:-}" != "" && "${4:-}" != "-" ]]; then
      printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0DIHDR\x00\x00\x00\x02\x00\x00\x00\x03' > "$4"
    else
      echo "unsupported simctl io command: $*" >&2
      exit 2
    fi
    ;;
  spawn)
    if [[ "${2:-}" == "fake-ios-1" && "${3:-}" == "log" && "${4:-}" == "show" ]]; then
      printf '2026-04-28 09:00:00.000000+0100 fake-ios-1 zmr fake simulator log line\n'
    else
      echo "unsupported simctl spawn command: $*" >&2
      exit 2
    fi
    ;;
  *)
    echo "unsupported simctl command: $*" >&2
    exit 2
    ;;
esac
