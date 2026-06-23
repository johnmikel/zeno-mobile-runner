#!/usr/bin/env bash
set -euo pipefail

request="$(cat)"

case "$request" in
  *'"cmd":"appState"'*)
    printf '{"status":"ok","state":4}\n'
    ;;
  *'"cmd":"snapshot"'*)
    cat <<'JSON'
{"status":"ok","nodes":[{"id":"continue-button","type":"XCUIElementTypeButton","label":"Continue","value":"Continue","identifier":"continue_button","bounds":{"x":0,"y":0,"width":1,"height":1},"enabled":true,"visible":true,"selected":false}]}
JSON
    ;;
  *'"cmd":"viewport"'*)
    printf '{"status":"ok","viewport":{"width":390,"height":844}}\n'
    ;;
  *'"cmd":"query"'*)
    printf '{"status":"ok","exists":true}\n'
    ;;
  *'"cmd":"screenshot"'*)
    printf '{"status":"ok","format":"png","base64":"iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"}\n'
    ;;
  *'"cmd":"tap"'*|*'"cmd":"type"'*|*'"cmd":"eraseText"'*|*'"cmd":"hideKeyboard"'*|*'"cmd":"swipe"'*|*'"cmd":"pressBack"'*|*'"cmd":"settle"'*|*'"cmd":"acceptSystemAlert"'*)
    printf '{"status":"ok"}\n'
    ;;
  *)
    printf '{"status":"error","message":"unsupported command"}\n'
    exit 3
    ;;
esac
