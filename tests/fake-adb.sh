#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-s" ]]; then
  shift 2
fi

# Record every invocation so tests can assert what the runner actually sent.
# The env-var form is kept for callers that want an isolated log; the default
# path exists because nothing can assert argv that is never written down, and
# for a long time nothing did.
_zmr_adb_log="${ZMR_FAKE_ADB_LOG:-zig-cache/fake-adb.log}"
mkdir -p "$(dirname "$_zmr_adb_log")" 2>/dev/null || true
printf '%s\n' "$*" >> "$_zmr_adb_log" 2>/dev/null || true

case "${1:-}" in
  version)
    printf 'Android Debug Bridge version 1.0.41\n'
    ;;
  devices)
    printf 'List of devices attached\nfake-android-1\tdevice\n'
    ;;
  wait-for-device)
    ;;
  exec-out)
    if [[ "${2:-}" == "screencap" ]]; then
      printf '\x89PNG\r\n\x1a\n'
    elif [[ "${2:-}" == "uiautomator" ]]; then
      cat <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="Sample landing." resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,100][640,160]" />
  <node index="1" text="Or sign up via email here" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[120,200][600,260]" />
  <node index="10" text="Already have an account? Sign in" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[120,270][600,330]" />
  <node index="2" text="" resource-id="email-login-email-input" class="android.widget.EditText" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,300][640,360]" />
  <node index="3" text="" resource-id="email-login-password-input" class="android.widget.EditText" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,380][640,440]" />
  <node index="4" text="Sign in" resource-id="email-login-submit-button" class="android.widget.Button" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,470][640,540]" />
  <node index="5" text="Dashboard" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,560][640,620]" />
  <node index="6" text="Account" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[500,1180][700,1260]" />
  <node index="7" text="Your account" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,120][640,180]" />
  <node index="8" text="E2E auth probe" resource-id="e2e-auth-probe-marker" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[120,300][600,360]" />
  <node index="9" text="Invite a teammate" resource-id="invite-card" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[100,600][620,700]" />
</hierarchy>
XML
    else
      echo "unsupported exec-out command: $*" >&2
      exit 2
    fi
    ;;
  logcat)
    printf '04-27 12:00:00.000  1000  1000 I zmr: fake logcat line\n'
    ;;
  pull)
    printf 'FAKE_MP4\n' > "${3:?missing local pull path}"
    ;;
  emu)
    if [[ -n "${ZMR_FAKE_EMULATOR_LOG:-}" ]]; then
      printf 'adb emu %s\n' "${*:2}" >> "$ZMR_FAKE_EMULATOR_LOG"
    fi
    ;;
  shell)
    shift
    case "${1:-}" in
      sh)
        cat <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="Sample landing." resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,100][640,160]" />
  <node index="1" text="Or sign up via email here" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[120,200][600,260]" />
  <node index="10" text="Already have an account? Sign in" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[120,270][600,330]" />
  <node index="2" text="" resource-id="email-login-email-input" class="android.widget.EditText" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,300][640,360]" />
  <node index="3" text="" resource-id="email-login-password-input" class="android.widget.EditText" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,380][640,440]" />
  <node index="4" text="Sign in" resource-id="email-login-submit-button" class="android.widget.Button" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,470][640,540]" />
  <node index="5" text="Dashboard" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,560][640,620]" />
  <node index="6" text="Account" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[500,1180][700,1260]" />
  <node index="7" text="Your account" resource-id="" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[80,120][640,180]" />
  <node index="8" text="E2E auth probe" resource-id="e2e-auth-probe-marker" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[120,300][600,360]" />
  <node index="9" text="Invite a teammate" resource-id="invite-card" class="android.widget.TextView" package="com.example.mobiletest" content-desc="" enabled="true" selected="false" bounds="[100,600][620,700]" />
</hierarchy>
XML
        ;;
      dumpsys)
        printf 'mCurrentFocus=Window{123 u0 com.example.mobiletest/.MainActivity}\n'
        ;;
      getprop)
        printf '1\n'
        ;;
      wm)
        if [[ "${2:-}" == "size" ]]; then
          printf 'Physical size: 720x1280\n'
        elif [[ "${2:-}" == "density" ]]; then
          printf 'Physical density: 420\n'
        else
          echo "unsupported wm command: $*" >&2
          exit 2
        fi
        ;;
      monkey|am|input|pm)
        ;;
      rm)
        ;;
      screenrecord)
        sleep 0.05
        ;;
      *)
        echo "unsupported shell command: $*" >&2
        exit 2
        ;;
    esac
    ;;
  install)
    printf 'Success\n'
    ;;
  *)
    echo "unsupported adb command: $*" >&2
    exit 2
    ;;
esac
