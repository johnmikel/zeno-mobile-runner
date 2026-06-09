#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--out" "--name" "--app-id" "--ios-bundle-id" "--scheme"; do
  set +e
  missing_value_output="$("$ROOT/scripts/create-react-native-expo-demo-app.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "create-react-native-expo-demo-app should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

"$ROOT/scripts/create-react-native-expo-demo-app.sh" \
  --out "$TMPDIR/rn-expo-demo" \
  --name ZenoExpoDemo \
  --app-id com.example.mobiletest \
  --ios-bundle-id com.example.mobiletest \
  --scheme zenoexpodemo

test -f "$TMPDIR/rn-expo-demo/package.json"
test -f "$TMPDIR/rn-expo-demo/app.json"
test -f "$TMPDIR/rn-expo-demo/App.tsx"
test -f "$TMPDIR/rn-expo-demo/tsconfig.json"
test -f "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-workflow.json"
test -f "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-android-workflow.json"
test -f "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-ios-workflow.json"

grep -q '"expo"' "$TMPDIR/rn-expo-demo/package.json"
grep -q '"expo-dev-client": "~55.0.0"' "$TMPDIR/rn-expo-demo/package.json"
grep -q '"start": "expo start"' "$TMPDIR/rn-expo-demo/package.json"
grep -q '"react-native"' "$TMPDIR/rn-expo-demo/package.json"
grep -q '"scheme": "zenoexpodemo"' "$TMPDIR/rn-expo-demo/app.json"
grep -q '"package": "com.example.mobiletest"' "$TMPDIR/rn-expo-demo/app.json"
grep -q '"bundleIdentifier": "com.example.mobiletest"' "$TMPDIR/rn-expo-demo/app.json"
grep -q 'Linking.addEventListener' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID="profile_name_input"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID="profile_email_input"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID="catalog_list"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'id: "north_ridge_pack"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID={`catalog_item_${item.id}`}' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID="detail_save_button"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID="review_button"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID="workflow_status"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'testID="continue_button"' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'accessibilityLabel={testID}' "$TMPDIR/rn-expo-demo/App.tsx"
grep -q 'accessibilityLabel={`catalog_item_${item.id}`}' "$TMPDIR/rn-expo-demo/App.tsx"

"$ROOT/zig-out/bin/zmr" validate "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-workflow.json"
"$ROOT/zig-out/bin/zmr" validate "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-android-workflow.json"
"$ROOT/zig-out/bin/zmr" validate "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-ios-workflow.json"

python3 - "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-workflow.json" "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-android-workflow.json" "$TMPDIR/rn-expo-demo/.zmr/react-native-expo-ios-workflow.json" <<'PY'
import json
import sys

generic = json.load(open(sys.argv[1], encoding="utf-8"))
android = json.load(open(sys.argv[2], encoding="utf-8"))
ios = json.load(open(sys.argv[3], encoding="utf-8"))

assert generic["name"] == "ZMR React Native Expo workflow demo"
assert generic["appId"] == "com.example.mobiletest"
assert generic["steps"][0]["action"] == "openLink"
assert generic["steps"][0]["url"] == "zenoexpodemo://benchmark"
assert any(step["action"] == "scrollUntilVisible" for step in generic["steps"])
assert any(
    step.get("selector", {}).get("contentDesc") == "catalog_item_north_ridge_pack"
    for step in generic["steps"]
)
assert any(
    step.get("selector", {}).get("text") == "Workflow complete"
    for step in generic["steps"]
)

assert any(
    step.get("selector", {}).get("resourceId") == "com.example.mobiletest:id/catalog_item_north_ridge_pack"
    for step in android["steps"]
)
assert any(
    step.get("selector", {}).get("resourceId") == "workflow_status"
    for step in ios["steps"]
)
PY
