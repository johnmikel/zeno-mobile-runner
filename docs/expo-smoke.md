# Expo Smoke Test

This is the quickest public smoke path for an Expo app. It proves that the npm
package installs, the wizard scaffolds a scenario, ZMR can launch an iOS app,
and the runner can produce screenshots, traces, HTML reports, JUnit XML, and
redacted trace bundles.

Run the flow below on a local iOS simulator before treating a specific app build
as validated.

```bash
npx create-expo-app@latest /tmp/zmr-expo-smoke --template blank --yes
cd /tmp/zmr-expo-smoke
npm install --save-dev zeno-mobile-runner

npx zmr-wizard --yes --dir . \
  --app-id com.example.zenoexposmoke \
  --ios \
  --package-json
```

Boot a simulator, then build and launch the app:

```bash
xcrun simctl boot <simulator-udid>
npx expo run:ios --device <simulator-name>
```

Run the generated ZMR scenario:

```bash
npx zmr run .zmr/ios-smoke.json \
  --platform ios \
  --device booted \
  --trace-dir traces/zmr-ios \
  --json

npx zmr report traces/zmr-ios --out traces/zmr-ios/report.html --junit traces/zmr-ios/junit.xml
npx zmr export traces/zmr-ios --out traces/zmr-ios-redacted.zmrtrace --redact
```

Expected result shape:

```json
{
  "ok": true,
  "status": "passed",
  "scenario": "iOS smoke",
  "appId": "com.example.zenoexposmoke",
  "traceDir": "traces/zmr-ios",
  "eventCount": 8,
  "snapshotCount": 2,
  "partialFailureCount": 0
}
```

This smoke validates the platform-level loop: app launch, health check,
screenshot capture, trace collection, HTML/JUnit report generation, and
redacted export. For selector-grade React Native or Expo assertions on iOS, add
the XCTest shim described in [app integration](app-integration.md).

Android follows the same pattern with a connected emulator or device:

```bash
npx zmr-wizard --yes --dir . \
  --app-id com.example.zenoexposmoke \
  --android \
  --package-json

npx zmr run .zmr/android-smoke.json \
  --platform android \
  --device emulator-5554 \
  --trace-dir traces/zmr-android \
  --json
```

Do not commit traces, screenshots, bundle identifiers, private app names, or
credentials from a real product app. Use `zmr export --redact`, and add
`--omit-screenshots` when visual artifacts may contain sensitive data.
