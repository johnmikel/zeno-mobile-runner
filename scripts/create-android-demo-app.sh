#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=""
APP_ID="com.example.mobiletest"
API="35"
BUILD_TOOLS="35.0.1"
ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/create-android-demo-app.sh --out <dir> [options]

Creates a small public native Android demo app and a matching .zmr smoke
scenario. The generated app is intentionally generic and contains no private
app references. It uses Android SDK command-line tools directly, so it does not
need Gradle or network access.

Options:
  --out <dir>             Output app repository directory. Required.
  --app-id <id>           Android application id. Default: com.example.mobiletest.
  --api <level>           Android platform API level. Default: 35.
  --build-tools <ver>     Android build-tools version. Default: 35.0.1.
  --android-sdk <path>    Android SDK root. Default: ANDROID_HOME or ~/Library/Android/sdk.
  --dry-run               Print commands without executing them.
  -h, --help              Show this help.

After generation:
  adb install -r <dir>/build/app-debug.apk
  zmr run <dir>/.zmr/android-smoke.json --device emulator-5554 --app-id com.example.mobiletest --trace-dir <dir>/traces/android-demo
  zmr run <dir>/.zmr/android-workflow.json --device emulator-5554 --app-id com.example.mobiletest --trace-dir <dir>/traces/android-workflow
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

quote_cmd() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s\n' "${quoted[*]}"
}

run() {
  echo "+ $(quote_cmd "$@")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  echo "+ write $path"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --app-id)
      APP_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --api)
      API="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --build-tools)
      BUILD_TOOLS="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --android-sdk)
      ANDROID_SDK="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

[[ -n "$OUT" ]] || die "--out is required"
[[ "$APP_ID" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || die "--app-id must be a Java-style package id"
[[ "$API" =~ ^[0-9]+$ ]] || die "--api must be an integer"
[[ -n "$BUILD_TOOLS" ]] || die "--build-tools must be non-empty"

if [[ "$OUT" != /* ]]; then
  OUT="$(pwd -P)/$OUT"
fi

ANDROID_DIR="$OUT/android"
SRC_DIR="$ANDROID_DIR/src/dev/zmr/demo"
RES_DIR="$ANDROID_DIR/res"
BUILD_DIR="$OUT/build"
GEN_DIR="$BUILD_DIR/generated"
CLASSES_DIR="$BUILD_DIR/classes"
DEX_DIR="$BUILD_DIR/dex"
COMPILED_RES="$BUILD_DIR/compiled-res.zip"
UNSIGNED_APK="$BUILD_DIR/app-unsigned.apk"
SIGNED_APK="$BUILD_DIR/app-debug.apk"
KEYSTORE="$BUILD_DIR/debug.keystore"
ANDROID_JAR="$ANDROID_SDK/platforms/android-$API/android.jar"
BUILD_TOOLS_DIR="$ANDROID_SDK/build-tools/$BUILD_TOOLS"
AAPT2="$BUILD_TOOLS_DIR/aapt2"
D8="$BUILD_TOOLS_DIR/d8"
APKSIGNER="$BUILD_TOOLS_DIR/apksigner"
ZMR_BIN="${ZMR_BIN:-}"

echo "Android demo app: $OUT"
echo "Android demo APK: $SIGNED_APK"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: commands will be printed but not executed"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -f "$ANDROID_JAR" ]] || die "android.jar not found: $ANDROID_JAR"
  [[ -x "$AAPT2" ]] || die "aapt2 not found: $AAPT2"
  [[ -x "$D8" ]] || die "d8 not found: $D8"
  [[ -x "$APKSIGNER" ]] || die "apksigner not found: $APKSIGNER"
  command -v javac >/dev/null 2>&1 || die "javac is required"
  command -v keytool >/dev/null 2>&1 || die "keytool is required"
  command -v zip >/dev/null 2>&1 || die "zip is required"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  rm -rf "$BUILD_DIR"
fi
run mkdir -p "$SRC_DIR" "$RES_DIR/values" "$BUILD_DIR" "$GEN_DIR" "$CLASSES_DIR" "$DEX_DIR" "$OUT/.zmr"

write_file "$ANDROID_DIR/AndroidManifest.xml" "$(cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$APP_ID">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="$API" />
  <application android:theme="@style/AppTheme" android:label="ZMR Android Demo" android:allowBackup="false" android:supportsRtl="true">
    <activity android:name="dev.zmr.demo.MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
      </intent-filter>
      <intent-filter>
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="exampleapp" />
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF
)"

write_file "$RES_DIR/values/styles.xml" "$(cat <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
  <style name="AppTheme" parent="android:style/Theme.Material.Light.NoActionBar">
    <item name="android:fontFamily">sans</item>
    <item name="android:windowLightStatusBar">true</item>
    <item name="android:colorAccent">#2563EB</item>
  </style>
</resources>
EOF
)"

write_file "$RES_DIR/values/ids.xml" "$(cat <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
  <item name="demo_title" type="id" />
  <item name="continue_button" type="id" />
  <item name="demo_input" type="id" />
  <item name="demo_status" type="id" />
  <item name="profile_title" type="id" />
  <item name="profile_name_input" type="id" />
  <item name="profile_email_input" type="id" />
  <item name="save_profile_button" type="id" />
  <item name="catalog_title" type="id" />
  <item name="catalog_list" type="id" />
  <item name="catalog_item_trail_lamp" type="id" />
  <item name="catalog_item_river_bottle" type="id" />
  <item name="catalog_item_summit_shell" type="id" />
  <item name="catalog_item_basecamp_roll" type="id" />
  <item name="catalog_item_maple_organizer" type="id" />
  <item name="catalog_item_canyon_sling" type="id" />
  <item name="catalog_item_harbor_tote" type="id" />
  <item name="catalog_item_north_ridge_pack" type="id" />
  <item name="catalog_item_studio_stand" type="id" />
  <item name="detail_title" type="id" />
  <item name="detail_subtitle" type="id" />
  <item name="detail_save_button" type="id" />
  <item name="review_button" type="id" />
  <item name="review_title" type="id" />
  <item name="review_complete" type="id" />
  <item name="review_item" type="id" />
  <item name="workflow_status" type="id" />
</resources>
EOF
)"

write_file "$SRC_DIR/MainActivity.java" "$(cat <<EOF
package dev.zmr.demo;

import android.app.Activity;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.view.Gravity;
import android.view.inputmethod.InputMethodManager;
import android.content.Context;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public class MainActivity extends Activity {
    private LinearLayout root;
    private TextView demoStatus;
    private TextView workflowStatus;
    private String currentStatus = "Ready";
    private CatalogItem selectedItem = new CatalogItem("north_ridge_pack", "North Ridge Pack", "Weatherproof day pack", R.id.catalog_item_north_ridge_pack);

    private static class CatalogItem {
        final String key;
        final String title;
        final String subtitle;
        final int viewId;

        CatalogItem(String key, String title, String subtitle, int viewId) {
            this.key = key;
            this.title = title;
            this.subtitle = subtitle;
            this.viewId = viewId;
        }
    }

    private final CatalogItem[] catalogItems = new CatalogItem[] {
        new CatalogItem("trail_lamp", "Trail Lamp", "Compact campsite light", R.id.catalog_item_trail_lamp),
        new CatalogItem("river_bottle", "River Bottle", "Insulated hydration bottle", R.id.catalog_item_river_bottle),
        new CatalogItem("north_ridge_pack", "North Ridge Pack", "Weatherproof day pack", R.id.catalog_item_north_ridge_pack),
        new CatalogItem("summit_shell", "Summit Shell", "Lightweight rain layer", R.id.catalog_item_summit_shell),
        new CatalogItem("basecamp_roll", "Basecamp Roll", "Modular storage roll", R.id.catalog_item_basecamp_roll),
        new CatalogItem("maple_organizer", "Maple Organizer", "Cable and tool pouch", R.id.catalog_item_maple_organizer),
        new CatalogItem("canyon_sling", "Canyon Sling", "Cross-body field bag", R.id.catalog_item_canyon_sling),
        new CatalogItem("harbor_tote", "Harbor Tote", "Daily carry tote", R.id.catalog_item_harbor_tote),
        new CatalogItem("studio_stand", "Studio Stand", "Fold-flat work stand", R.id.catalog_item_studio_stand)
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        root = new LinearLayout(this);
        setContentView(root);
        showWelcome();

        Uri data = getIntent().getData();
        if (data != null) {
            setStatus("Deep link opened");
        }
    }

    private void resetRoot() {
        root.removeAllViews();
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        int padding = dp(24);
        root.setPadding(padding, padding, padding, padding);
    }

    private TextView title(String text, int id) {
        TextView title = new TextView(this);
        title.setId(id);
        title.setText(text);
        title.setTextSize(24);
        title.setTextColor(Color.rgb(17, 24, 39));
        title.setGravity(Gravity.CENTER);
        return title;
    }

    private EditText input(String hint, int id) {
        EditText input = new EditText(this);
        input.setId(id);
        input.setHint(hint);
        input.setSingleLine(true);
        return input;
    }

    private Button button(String text, int id) {
        Button button = new Button(this);
        button.setId(id);
        button.setText(text);
        button.setAllCaps(false);
        return button;
    }

    private void addStatusViews() {
        demoStatus = new TextView(this);
        demoStatus.setId(R.id.demo_status);
        demoStatus.setText(currentStatus);
        demoStatus.setTextSize(16);
        demoStatus.setGravity(Gravity.CENTER);
        root.addView(demoStatus, new LinearLayout.LayoutParams(-1, -2));

        workflowStatus = new TextView(this);
        workflowStatus.setId(R.id.workflow_status);
        workflowStatus.setText(currentStatus);
        workflowStatus.setTextSize(16);
        workflowStatus.setGravity(Gravity.CENTER);
        root.addView(workflowStatus, new LinearLayout.LayoutParams(-1, -2));
    }

    private void setStatus(String value) {
        currentStatus = value;
        if (demoStatus != null) {
            demoStatus.setText(value);
        }
        if (workflowStatus != null) {
            workflowStatus.setText(value);
        }
    }

    private void showWelcome() {
        resetRoot();
        root.addView(title("ZMR Android Demo", R.id.demo_title), new LinearLayout.LayoutParams(-1, -2));

        Button button = new Button(this);
        button.setId(R.id.continue_button);
        button.setText("Continue");
        root.addView(button, new LinearLayout.LayoutParams(-1, dp(56)));
        addStatusViews();

        button.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                showProfile("Continue tapped");
            }
        });
    }

    private void showProfile(String statusText) {
        currentStatus = statusText;
        resetRoot();
        root.addView(title("Profile", R.id.profile_title), new LinearLayout.LayoutParams(-1, -2));

        final EditText quickInput = input("Type here", R.id.demo_input);
        root.addView(quickInput, new LinearLayout.LayoutParams(-1, dp(56)));

        EditText profileName = input("Name", R.id.profile_name_input);
        root.addView(profileName, new LinearLayout.LayoutParams(-1, dp(56)));

        EditText profileEmail = input("Email", R.id.profile_email_input);
        root.addView(profileEmail, new LinearLayout.LayoutParams(-1, dp(56)));

        Button save = button("Save profile", R.id.save_profile_button);
        root.addView(save, new LinearLayout.LayoutParams(-1, dp(56)));
        addStatusViews();

        quickInput.requestFocus();
        InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) {
            imm.showSoftInput(quickInput, InputMethodManager.SHOW_IMPLICIT);
        }

        save.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) {
                    imm.hideSoftInputFromWindow(view.getWindowToken(), 0);
                }
                showCatalog("Profile saved");
            }
        });
    }

    private void showCatalog(String statusText) {
        currentStatus = statusText;
        resetRoot();
        root.addView(title("Catalog", R.id.catalog_title), new LinearLayout.LayoutParams(-1, -2));

        ScrollView scrollView = new ScrollView(this);
        scrollView.setId(R.id.catalog_list);
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        scrollView.addView(list, new ScrollView.LayoutParams(-1, -2));

        for (final CatalogItem item : catalogItems) {
            Button itemButton = button(item.title, item.viewId);
            itemButton.setContentDescription(item.subtitle);
            list.addView(itemButton, new LinearLayout.LayoutParams(-1, dp(56)));
            itemButton.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View view) {
                    selectedItem = item;
                    showDetail("Selected " + item.title);
                }
            });
        }

        root.addView(scrollView, new LinearLayout.LayoutParams(-1, 0, 1));
        addStatusViews();
    }

    private void showDetail(String statusText) {
        currentStatus = statusText;
        resetRoot();
        root.addView(title(selectedItem.title, R.id.detail_title), new LinearLayout.LayoutParams(-1, -2));

        TextView subtitle = new TextView(this);
        subtitle.setId(R.id.detail_subtitle);
        subtitle.setText(selectedItem.subtitle);
        subtitle.setTextSize(18);
        subtitle.setGravity(Gravity.CENTER);
        root.addView(subtitle, new LinearLayout.LayoutParams(-1, -2));

        Button save = button("Save item", R.id.detail_save_button);
        root.addView(save, new LinearLayout.LayoutParams(-1, dp(56)));

        Button review = button("Review order", R.id.review_button);
        root.addView(review, new LinearLayout.LayoutParams(-1, dp(56)));
        addStatusViews();

        save.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                setStatus("Saved " + selectedItem.title);
            }
        });

        review.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                showReview();
            }
        });
    }

    private void showReview() {
        currentStatus = "Workflow complete";
        resetRoot();
        root.addView(title("Review", R.id.review_title), new LinearLayout.LayoutParams(-1, -2));

        TextView complete = new TextView(this);
        complete.setId(R.id.review_complete);
        complete.setText("Workflow complete");
        complete.setTextSize(20);
        complete.setGravity(Gravity.CENTER);
        root.addView(complete, new LinearLayout.LayoutParams(-1, -2));

        TextView item = new TextView(this);
        item.setId(R.id.review_item);
        item.setText(selectedItem.title);
        item.setTextSize(18);
        item.setGravity(Gravity.CENTER);
        root.addView(item, new LinearLayout.LayoutParams(-1, -2));

        addStatusViews();
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }
}
EOF
)"

write_file "$OUT/.zmr/android-smoke.json" "$(cat <<EOF
{
  "name": "ZMR Android demo smoke",
  "appId": "$APP_ID",
  "steps": [
    { "action": "clearState" },
    { "action": "launch" },
    { "action": "waitVisible", "selector": { "text": "ZMR Android Demo" }, "timeoutMs": 30000 },
    { "action": "tap", "selector": { "resourceId": "$APP_ID:id/continue_button" } },
    { "action": "waitVisible", "selector": { "text": "Continue tapped" }, "timeoutMs": 10000 },
    { "action": "typeText", "selector": { "resourceId": "$APP_ID:id/demo_input" }, "text": "hello from zmr" },
    { "action": "snapshot" }
  ]
}
EOF
)"

write_file "$OUT/.zmr/android-workflow.json" "$(cat <<EOF
{
  "name": "ZMR Android workflow demo",
  "appId": "$APP_ID",
  "steps": [
    { "action": "stop" },
    { "action": "clearState" },
    { "action": "launch" },
    {
      "action": "waitVisible",
      "selector": { "text": "ZMR Android Demo" },
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

run "$AAPT2" compile --dir "$RES_DIR" -o "$COMPILED_RES"
run "$AAPT2" link -o "$UNSIGNED_APK" -I "$ANDROID_JAR" --manifest "$ANDROID_DIR/AndroidManifest.xml" -R "$COMPILED_RES" --java "$GEN_DIR" --custom-package dev.zmr.demo --auto-add-overlay
run javac -source 1.8 -target 1.8 -bootclasspath "$ANDROID_JAR" -d "$CLASSES_DIR" "$GEN_DIR/dev/zmr/demo/R.java" "$SRC_DIR/MainActivity.java"
if [[ "$DRY_RUN" -eq 1 ]]; then
  CLASS_FILES=(
    "$CLASSES_DIR/dev/zmr/demo/R.class"
    "$CLASSES_DIR/dev/zmr/demo/MainActivity.class"
    "$CLASSES_DIR/dev/zmr/demo/MainActivity\$1.class"
  )
else
  CLASS_FILES=()
  while IFS= read -r class_file; do
    CLASS_FILES+=("$class_file")
  done < <(find "$CLASSES_DIR" -name '*.class' -print | sort)
  [[ "${#CLASS_FILES[@]}" -gt 0 ]] || die "no compiled Java classes found in $CLASSES_DIR"
fi

run "$D8" --lib "$ANDROID_JAR" --min-api 23 --output "$DEX_DIR" "${CLASS_FILES[@]}"
run zip -j "$UNSIGNED_APK" "$DEX_DIR/classes.dex"
run keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android -alias zmrdebug -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=ZMR Android Demo,O=ZMR,C=US"
run "$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias zmrdebug --ks-pass pass:android --key-pass pass:android --out "$SIGNED_APK" "$UNSIGNED_APK"
if [[ -z "$ZMR_BIN" ]]; then
  if [[ -x "$ROOT/zig-out/bin/zmr" ]]; then
    ZMR_BIN="$ROOT/zig-out/bin/zmr"
  elif command -v zmr >/dev/null 2>&1; then
    ZMR_BIN="$(command -v zmr)"
  fi
fi

if [[ -n "$ZMR_BIN" ]]; then
  run "$ZMR_BIN" validate "$OUT/.zmr/android-smoke.json"
else
  echo "warning: skipped scenario validation because zmr was not found; run 'zmr validate $OUT/.zmr/android-smoke.json' after installation" >&2
fi

echo "created Android demo app at $OUT"
echo "apk: $SIGNED_APK"
echo "scenario: $OUT/.zmr/android-smoke.json"
