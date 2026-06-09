#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--out" "--app-id" "--api" "--build-tools" "--android-sdk"; do
  set +e
  missing_value_output="$("$ROOT/scripts/create-android-demo-app.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "create-android-demo-app should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

output="$("$ROOT/scripts/create-android-demo-app.sh" \
  --dry-run \
  --out "$TMPDIR/android-demo" \
  --app-id com.example.mobiletest \
  --api 35 \
  --build-tools 35.0.1 2>&1)"

python3 - "$output" "$TMPDIR" <<'PY'
import sys

output = sys.argv[1]
tmp = sys.argv[2]

required = [
    "DRY RUN",
    f"Android demo app: {tmp}/android-demo",
    "Android demo APK:",
    "AndroidManifest.xml",
    "MainActivity.java",
    "aapt2 compile",
    "aapt2 link",
    "javac",
    "d8",
    "apksigner sign",
    ".zmr/android-smoke.json",
    ".zmr/android-workflow.json",
]

for needle in required:
    assert needle in output, needle
PY

if command -v javac >/dev/null 2>&1 && [[ -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}" ]]; then
  "$ROOT/scripts/create-android-demo-app.sh" \
    --out "$TMPDIR/android-demo-real" \
    --app-id com.example.mobiletest \
    --api 35 \
    --build-tools 35.0.1
  "$ROOT/scripts/create-android-demo-app.sh" \
    --out "$TMPDIR/android-demo-real" \
    --app-id com.example.mobiletest \
    --api 35 \
    --build-tools 35.0.1 >/dev/null

  test -f "$TMPDIR/android-demo-real/android/AndroidManifest.xml"
  test -f "$TMPDIR/android-demo-real/android/src/dev/zmr/demo/MainActivity.java"
  test -f "$TMPDIR/android-demo-real/build/app-debug.apk"
  test -f "$TMPDIR/android-demo-real/.zmr/android-smoke.json"
  test -f "$TMPDIR/android-demo-real/.zmr/android-workflow.json"

  "$ROOT/zig-out/bin/zmr" validate "$TMPDIR/android-demo-real/.zmr/android-smoke.json"
  "$ROOT/zig-out/bin/zmr" validate "$TMPDIR/android-demo-real/.zmr/android-workflow.json"
  grep -q 'profile_name_input' "$TMPDIR/android-demo-real/android/res/values/ids.xml"
  grep -q 'profile_email_input' "$TMPDIR/android-demo-real/android/res/values/ids.xml"
  grep -q 'catalog_list' "$TMPDIR/android-demo-real/android/res/values/ids.xml"
  grep -q 'catalog_item_north_ridge_pack' "$TMPDIR/android-demo-real/android/res/values/ids.xml"
  grep -q 'detail_save_button' "$TMPDIR/android-demo-real/android/res/values/ids.xml"
  grep -q 'review_button' "$TMPDIR/android-demo-real/android/res/values/ids.xml"
  grep -q 'workflow_status' "$TMPDIR/android-demo-real/android/res/values/ids.xml"
  python3 - "$TMPDIR/android-demo-real/.zmr/android-smoke.json" <<'PY'
import json
import sys

scenario = json.load(open(sys.argv[1], encoding="utf-8"))
assert scenario["steps"][1]["action"] == "waitVisible"
assert scenario["steps"][1]["timeoutMs"] == 30000
tap = scenario["steps"][2]
assert tap["action"] == "tap"
assert tap["selector"]["resourceId"] == "com.example.mobiletest:id/continue_button"
assert scenario["steps"][3]["timeoutMs"] == 10000
assert scenario["steps"][4]["selector"]["resourceId"] == "com.example.mobiletest:id/demo_input"
PY
  python3 - "$TMPDIR/android-demo-real/.zmr/android-workflow.json" <<'PY'
import json
import sys

scenario = json.load(open(sys.argv[1], encoding="utf-8"))
assert scenario["name"] == "ZMR Android workflow demo"
actions = [step["action"] for step in scenario["steps"]]
assert "scrollUntilVisible" in actions
assert "assertVisible" in actions
assert scenario["steps"][-1]["action"] == "snapshot"
assert any(
    step.get("selector", {}).get("resourceId") == "com.example.mobiletest:id/catalog_item_north_ridge_pack"
    for step in scenario["steps"]
)
assert any(
    step.get("selector", {}).get("resourceId") == "com.example.mobiletest:id/workflow_status"
    and step["selector"].get("text") == "Workflow complete"
    for step in scenario["steps"]
)
PY
  apk_listing="$(unzip -l "$TMPDIR/android-demo-real/build/app-debug.apk")"
  grep -q 'classes.dex' <<< "$apk_listing"
fi
