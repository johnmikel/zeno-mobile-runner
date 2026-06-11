#!/usr/bin/env bash
set -euo pipefail

OUT=""
APP_NAME="ZenoExpoDemo"
APP_ID="com.example.mobiletest"
IOS_BUNDLE_ID="com.example.mobiletest"
SCHEME="zenoexpodemo"

usage() {
  cat <<'USAGE'
Usage:
  scripts/create-react-native-expo-demo-app.sh --out <dir> [options]

Creates a small public React Native / Expo demo app and matching ZMR workflow
scenarios. The generated app is intentionally generic and contains no private
app references. Generation does not install dependencies or require network
access.

Options:
  --out <dir>             Output app repository directory. Required.
  --name <name>           Expo app display name. Default: ZenoExpoDemo.
  --app-id <id>           Android application id. Default: com.example.mobiletest.
  --ios-bundle-id <id>    iOS bundle id. Default: com.example.mobiletest.
  --scheme <scheme>       App deep-link scheme. Default: zenoexpodemo.
  -h, --help              Show this help.

After generation:
  cd <dir>
  bun install
  bunx expo start
  zmr run .zmr/react-native-expo-android-workflow.json --device emulator-5554 --app-id com.example.mobiletest --trace-dir traces/zmr-rn-expo-android
  zmr run .zmr/react-native-expo-ios-workflow.json --platform ios --device booted --app-id com.example.mobiletest --trace-dir traces/zmr-rn-expo-ios
USAGE
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

write_file() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --name)
      APP_NAME="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --app-id)
      APP_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --ios-bundle-id)
      IOS_BUNDLE_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --scheme)
      SCHEME="$(require_value "$1" "${2-}")"
      shift 2
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

[[ -n "$OUT" ]] || die "--out is required"
[[ "$APP_NAME" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "--name must start with a letter and contain only letters, numbers, underscores, or hyphens"
[[ "$APP_ID" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || die "--app-id must be a Java-style package id"
[[ "$IOS_BUNDLE_ID" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_-]*)+$ ]] || die "--ios-bundle-id must be a bundle identifier"
[[ "$SCHEME" =~ ^[a-z][a-z0-9+.-]*$ ]] || die "--scheme must be a lower-case URL scheme"

if [[ "$OUT" != /* ]]; then
  OUT="$(pwd -P)/$OUT"
fi

PACKAGE_NAME="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -cd 'a-z0-9-')"
[[ -n "$PACKAGE_NAME" ]] || PACKAGE_NAME="zeno-expo-demo"

mkdir -p "$OUT/.zmr"

write_file "$OUT/package.json" "$(cat <<EOF
{
  "private": true,
  "name": "$PACKAGE_NAME",
  "version": "0.0.0",
  "main": "index.js",
  "scripts": {
    "start": "expo start",
    "android": "expo run:android",
    "ios": "expo run:ios",
    "zmr:android": "zmr run .zmr/react-native-expo-android-workflow.json --device emulator-5554 --app-id $APP_ID --trace-dir traces/zmr-rn-expo-android",
    "zmr:ios": "zmr run .zmr/react-native-expo-ios-workflow.json --platform ios --device booted --app-id $IOS_BUNDLE_ID --trace-dir traces/zmr-rn-expo-ios"
  },
  "dependencies": {
    "expo": "~55.0.0",
    "expo-dev-client": "~55.0.0",
    "react": "^19.2.0",
    "react-native": "~0.83.0"
  },
  "devDependencies": {
    "@types/react": "^19.1.1",
    "typescript": "^5.9.0"
  }
}
EOF
)"

write_file "$OUT/app.json" "$(cat <<EOF
{
  "expo": {
    "name": "$APP_NAME",
    "slug": "$PACKAGE_NAME",
    "scheme": "$SCHEME",
    "version": "0.0.0",
    "orientation": "portrait",
    "userInterfaceStyle": "automatic",
    "ios": {
      "bundleIdentifier": "$IOS_BUNDLE_ID"
    },
    "android": {
      "package": "$APP_ID"
    }
  }
}
EOF
)"

write_file "$OUT/index.js" "$(cat <<'EOF'
import { registerRootComponent } from "expo";

import App from "./App";

registerRootComponent(App);
EOF
)"

write_file "$OUT/tsconfig.json" "$(cat <<'EOF'
{
  "extends": "expo/tsconfig.base",
  "compilerOptions": {
    "strict": true
  }
}
EOF
)"

write_file "$OUT/App.tsx" "$(cat <<EOF
import React, { useEffect, useMemo, useState } from "react";
import {
  Linking,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

type Screen = "welcome" | "profile" | "catalog" | "detail" | "review";

type CatalogItem = {
  id: string;
  title: string;
  subtitle: string;
};

const catalogItems: CatalogItem[] = [
  { id: "trail_lamp", title: "Trail Lamp", subtitle: "Compact campsite light" },
  { id: "river_bottle", title: "River Bottle", subtitle: "Insulated hydration bottle" },
  { id: "summit_shell", title: "Summit Shell", subtitle: "Lightweight rain layer" },
  { id: "basecamp_roll", title: "Basecamp Roll", subtitle: "Modular storage roll" },
  { id: "maple_organizer", title: "Maple Organizer", subtitle: "Cable and tool pouch" },
  { id: "canyon_sling", title: "Canyon Sling", subtitle: "Cross-body field bag" },
  { id: "harbor_tote", title: "Harbor Tote", subtitle: "Daily carry tote" },
  { id: "north_ridge_pack", title: "North Ridge Pack", subtitle: "Weatherproof day pack" },
  { id: "studio_stand", title: "Studio Stand", subtitle: "Fold-flat work stand" },
];

const defaultItem = catalogItems.find((item) => item.id === "north_ridge_pack") ?? catalogItems[0];

export default function App() {
  const [screen, setScreen] = useState<Screen>("welcome");
  const [status, setStatus] = useState("Ready");
  const [profileName, setProfileName] = useState("");
  const [profileEmail, setProfileEmail] = useState("");
  const [selectedItem, setSelectedItem] = useState<CatalogItem>(defaultItem);

  useEffect(() => {
    const openBenchmark = (url: string | null) => {
      if (!url || !url.startsWith("$SCHEME://")) return;
      setScreen("welcome");
      setStatus("Deep link opened");
    };

    Linking.getInitialURL().then(openBenchmark).catch(() => undefined);
    const subscription = Linking.addEventListener("url", (event) => openBenchmark(event.url));
    return () => subscription.remove();
  }, []);

  const savedStatus = useMemo(() => \`Saved \${selectedItem.title}\`, [selectedItem.title]);

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.shell}>
        {screen === "welcome" ? (
          <View style={styles.centered}>
            <Text style={styles.title} testID="demo_title">
              Zeno Expo Demo
            </Text>
            <Text style={styles.copy}>A generated React Native and Expo workflow surface.</Text>
            <PrimaryButton
              label="Continue"
              testID="continue_button"
              onPress={() => {
                setStatus("Continue tapped");
                setScreen("profile");
              }}
            />
          </View>
        ) : null}

        {screen === "profile" ? (
          <View style={styles.form}>
            <Text style={styles.heading} testID="profile_title">
              Profile
            </Text>
            <TextInput
              value={profileName}
              onChangeText={setProfileName}
              placeholder="Name"
              autoCapitalize="none"
              autoCorrect={false}
              style={styles.input}
              testID="profile_name_input"
             
            />
            <TextInput
              value={profileEmail}
              onChangeText={setProfileEmail}
              placeholder="Email"
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="email-address"
              style={styles.input}
              testID="profile_email_input"
             
            />
            <PrimaryButton
              label="Save profile"
              testID="save_profile_button"
              onPress={() => {
                setStatus("Profile saved");
                setScreen("catalog");
              }}
            />
          </View>
        ) : null}

        {screen === "catalog" ? (
          <View style={styles.flex}>
            <Text style={styles.heading} testID="catalog_title">
              Catalog
            </Text>
            <ScrollView
              style={styles.list}
              contentContainerStyle={styles.listContent}
              testID="catalog_list"
             
            >
              {catalogItems.map((item) => (
                <Pressable
                  key={item.id}
                  testID={\`catalog_item_\${item.id}\`}
                  accessibilityRole="button"
                  style={styles.row}
                  onPress={() => {
                    setSelectedItem(item);
                    setStatus(\`Selected \${item.title}\`);
                    setScreen("detail");
                  }}
                >
                  <Text style={styles.rowTitle}>{item.title}</Text>
                  <Text style={styles.rowCopy}>{item.subtitle}</Text>
                </Pressable>
              ))}
            </ScrollView>
          </View>
        ) : null}

        {screen === "detail" ? (
          <View style={styles.form}>
            <Text style={styles.heading} testID="detail_title">
              {selectedItem.title}
            </Text>
            <Text style={styles.copy} testID="detail_subtitle">
              {selectedItem.subtitle}
            </Text>
            <PrimaryButton
              label="Save item"
              testID="detail_save_button"
              onPress={() => {
                setStatus(savedStatus);
                setScreen("review");
              }}
            />
          </View>
        ) : null}

        {screen === "review" ? (
          <View style={styles.form}>
            <Text style={styles.heading} testID="review_title">
              Review
            </Text>
            <Text style={styles.copy} testID="review_summary">
              {profileName || "Riley"} saved {selectedItem.title}
            </Text>
            <PrimaryButton
              label="Complete review"
              testID="review_button"
              onPress={() => setStatus("Workflow complete")}
            />
          </View>
        ) : null}

        <Text style={styles.status} testID="workflow_status">
          {status}
        </Text>
      </View>
    </SafeAreaView>
  );
}

function PrimaryButton({
  label,
  testID,
  onPress,
}: {
  label: string;
  testID: string;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      testID={testID}
      onPress={onPress}
      style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}
    >
      <Text style={styles.buttonText}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: "#F8FAFC",
  },
  shell: {
    flex: 1,
    padding: 20,
    gap: 16,
  },
  flex: {
    flex: 1,
  },
  centered: {
    flex: 1,
    justifyContent: "center",
    gap: 18,
  },
  form: {
    flex: 1,
    justifyContent: "center",
    gap: 14,
  },
  title: {
    color: "#111827",
    fontSize: 34,
    fontWeight: "700",
  },
  heading: {
    color: "#111827",
    fontSize: 28,
    fontWeight: "700",
  },
  copy: {
    color: "#475569",
    fontSize: 16,
    lineHeight: 22,
  },
  input: {
    minHeight: 52,
    borderWidth: 1,
    borderColor: "#CBD5E1",
    borderRadius: 8,
    paddingHorizontal: 14,
    backgroundColor: "#FFFFFF",
    color: "#111827",
    fontSize: 16,
  },
  button: {
    minHeight: 52,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: 8,
    backgroundColor: "#2563EB",
    paddingHorizontal: 18,
  },
  buttonPressed: {
    backgroundColor: "#1D4ED8",
  },
  buttonText: {
    color: "#FFFFFF",
    fontSize: 16,
    fontWeight: "700",
  },
  list: {
    flex: 1,
    marginTop: 14,
  },
  listContent: {
    gap: 10,
    paddingBottom: 24,
  },
  row: {
    borderWidth: 1,
    borderColor: "#CBD5E1",
    borderRadius: 8,
    backgroundColor: "#FFFFFF",
    padding: 16,
    gap: 6,
  },
  rowTitle: {
    color: "#111827",
    fontSize: 18,
    fontWeight: "700",
  },
  rowCopy: {
    color: "#64748B",
    fontSize: 14,
  },
  status: {
    color: "#334155",
    fontSize: 14,
    textAlign: "center",
  },
});
EOF
)"

write_file "$OUT/.zmr/react-native-expo-workflow.json" "$(cat <<EOF
{
  "name": "ZMR React Native Expo workflow demo",
  "appId": "$APP_ID",
  "steps": [
    { "action": "openLink", "url": "$SCHEME://benchmark" },
    {
      "action": "waitVisible",
      "selector": { "text": "Zeno Expo Demo" },
      "timeoutMs": 30000
    },
    {
      "action": "tap",
      "selector": { "contentDesc": "continue_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Profile" },
      "timeoutMs": 10000
    },
    {
      "action": "typeText",
      "selector": { "contentDesc": "profile_name_input" },
      "text": "Riley"
    },
    {
      "action": "typeText",
      "selector": { "contentDesc": "profile_email_input" },
      "text": "riley@example.test"
    },
    { "action": "hideKeyboard" },
    {
      "action": "tap",
      "selector": { "contentDesc": "save_profile_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Catalog" },
      "timeoutMs": 10000
    },
    {
      "action": "scrollUntilVisible",
      "selector": { "contentDesc": "catalog_item_north_ridge_pack" },
      "direction": "down",
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "contentDesc": "catalog_item_north_ridge_pack" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "North Ridge Pack" },
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "contentDesc": "detail_save_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Saved North Ridge Pack" },
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "contentDesc": "review_button" }
    },
    {
      "action": "assertVisible",
      "selector": { "text": "Workflow complete" },
      "timeoutMs": 10000
    },
    { "action": "snapshot" }
  ]
}
EOF
)"

write_file "$OUT/.zmr/react-native-expo-android-workflow.json" "$(cat <<EOF
{
  "name": "ZMR React Native Expo Android workflow demo",
  "appId": "$APP_ID",
  "steps": [
    { "action": "openLink", "url": "$SCHEME://benchmark" },
    {
      "action": "waitVisible",
      "selector": { "text": "Zeno Expo Demo" },
      "timeoutMs": 30000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "$APP_ID:id/continue_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Profile" },
      "timeoutMs": 10000
    },
    {
      "action": "typeText",
      "selector": { "resourceId": "$APP_ID:id/profile_name_input" },
      "text": "Riley"
    },
    {
      "action": "typeText",
      "selector": { "resourceId": "$APP_ID:id/profile_email_input" },
      "text": "riley@example.test"
    },
    { "action": "hideKeyboard" },
    {
      "action": "tap",
      "selector": { "resourceId": "$APP_ID:id/save_profile_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Catalog" },
      "timeoutMs": 10000
    },
    {
      "action": "scrollUntilVisible",
      "selector": { "resourceId": "$APP_ID:id/catalog_item_north_ridge_pack" },
      "direction": "down",
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "$APP_ID:id/catalog_item_north_ridge_pack" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "North Ridge Pack" },
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "$APP_ID:id/detail_save_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Saved North Ridge Pack" },
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "$APP_ID:id/review_button" }
    },
    {
      "action": "assertVisible",
      "selector": {
        "resourceId": "$APP_ID:id/workflow_status",
        "text": "Workflow complete"
      },
      "timeoutMs": 10000
    },
    { "action": "snapshot" }
  ]
}
EOF
)"

write_file "$OUT/.zmr/react-native-expo-ios-workflow.json" "$(cat <<EOF
{
  "name": "ZMR React Native Expo iOS workflow demo",
  "appId": "$IOS_BUNDLE_ID",
  "steps": [
    { "action": "openLink", "url": "$SCHEME://benchmark" },
    {
      "action": "waitVisible",
      "selector": { "text": "Zeno Expo Demo" },
      "timeoutMs": 30000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "continue_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Profile" },
      "timeoutMs": 10000
    },
    {
      "action": "typeText",
      "selector": { "resourceId": "profile_name_input" },
      "text": "Riley"
    },
    {
      "action": "typeText",
      "selector": { "resourceId": "profile_email_input" },
      "text": "riley@example.test"
    },
    { "action": "hideKeyboard" },
    {
      "action": "tap",
      "selector": { "resourceId": "save_profile_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Catalog" },
      "timeoutMs": 10000
    },
    {
      "action": "scrollUntilVisible",
      "selector": { "resourceId": "catalog_item_north_ridge_pack" },
      "direction": "down",
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "catalog_item_north_ridge_pack" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "North Ridge Pack" },
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "detail_save_button" }
    },
    {
      "action": "waitVisible",
      "selector": { "text": "Saved North Ridge Pack" },
      "timeoutMs": 10000
    },
    {
      "action": "tap",
      "selector": { "resourceId": "review_button" }
    },
    {
      "action": "assertVisible",
      "selector": {
        "resourceId": "workflow_status",
        "text": "Workflow complete"
      },
      "timeoutMs": 10000
    },
    { "action": "snapshot" }
  ]
}
EOF
)"

echo "React Native / Expo demo app: $OUT"
echo "Deep link scheme: $SCHEME"
echo "ZMR scenarios:"
echo "  $OUT/.zmr/react-native-expo-workflow.json"
echo "  $OUT/.zmr/react-native-expo-android-workflow.json"
echo "  $OUT/.zmr/react-native-expo-ios-workflow.json"
