#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

OUT="$TMPDIR/support-evidence"

"$ROOT/scripts/support-evidence-kit.sh" \
  --out "$OUT" \
  --app-id com.example.product \
  --android-scenario .zmr/android-smoke.json \
  --ios-scenario .zmr/ios-smoke.json \
  --android-app-root /apps/mobile \
  --ios-app-root /apps/mobile-ios \
  --ios-app-path build/Debug-iphonesimulator/Product.app \
  --android-apk android/app/build/outputs/apk/debug/app-debug.apk \
  --zmr-bin ./node_modules/.bin/zmr > "$TMPDIR/output.txt"

grep -q "support evidence kit" "$TMPDIR/output.txt"
grep -q "$OUT/device-matrix.template.json" "$TMPDIR/output.txt"

test -f "$OUT/device-matrix.template.json"
test -f "$OUT/pilot-commands.md"
test -f "$OUT/support-claim-checklist.md"
test -f "$OUT/README.md"

python3 - "$OUT/device-matrix.template.json" <<'PY'
import json
import sys

matrix = json.load(open(sys.argv[1], encoding="utf-8"))
devices = matrix["devices"]
by_name = {device["name"]: device for device in devices}

assert matrix["runs"] == 20
assert matrix["appId"] == "com.example.product"
assert list(by_name) == [
    "android-emulator",
    "android-physical",
    "iphone-simulator",
    "ipad-simulator",
    "iphone-physical",
    "ipad-physical",
]
assert by_name["android-emulator"]["platform"] == "android"
assert by_name["android-emulator"]["serial"] == "emulator-5554"
assert by_name["android-physical"]["platform"] == "android"
assert by_name["android-physical"]["serial"] == "<android-device-serial>"
assert by_name["iphone-simulator"]["platform"] == "ios"
assert by_name["iphone-simulator"]["iosDeviceType"] == "simulator"
assert by_name["iphone-simulator"]["serial"] == "booted"
assert by_name["ipad-simulator"]["platform"] == "ios"
assert by_name["ipad-simulator"]["iosDeviceType"] == "simulator"
assert by_name["ipad-simulator"]["serial"] == "<ipad-simulator-udid-or-booted>"
assert by_name["iphone-physical"]["iosDeviceType"] == "physical"
assert by_name["iphone-physical"]["serial"] == "<iphone-device-id>"
assert by_name["ipad-physical"]["iosDeviceType"] == "physical"
assert by_name["ipad-physical"]["serial"] == "<ipad-device-id>"
assert by_name["ipad-simulator"]["evidenceTarget"] == "iPad simulator"
assert by_name["ipad-physical"]["evidenceTarget"] == "iPad physical"
assert all(device["scenario"] in {".zmr/android-smoke.json", ".zmr/ios-smoke.json"} for device in devices)
PY

grep -q "zmr-device-matrix --matrix device-matrix.template.json" "$OUT/pilot-commands.md"
grep -q "zmr-pilot-gate" "$OUT/pilot-commands.md"
grep -q -- "--runs 20" "$OUT/pilot-commands.md"
grep -q -- "--min-pass-rate 100" "$OUT/pilot-commands.md"
grep -q -- "--max-failures 0" "$OUT/pilot-commands.md"
grep -q -- "--ios-device-type physical" "$OUT/pilot-commands.md"
grep -q -- "--ios-device-type simulator" "$OUT/pilot-commands.md"
grep -q "iPad simulator" "$OUT/pilot-commands.md"
grep -q "iPad physical" "$OUT/pilot-commands.md"
grep -q "redacted" "$OUT/pilot-commands.md"

grep -q "zero failures" "$OUT/support-claim-checklist.md"
grep -q "redacted .zmrtrace" "$OUT/support-claim-checklist.md"
grep -q "iPad evidence stays separate from iPhone evidence" "$OUT/support-claim-checklist.md"
grep -q "support matrix" "$OUT/support-claim-checklist.md"

grep -q "AI-agent-first support evidence" "$OUT/README.md"
grep -q "device-matrix.template.json" "$OUT/README.md"
grep -q "pilot-commands.md" "$OUT/README.md"
