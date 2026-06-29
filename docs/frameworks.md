# Framework Guide

ZMR drives the installed mobile app through Android and iOS automation surfaces.
It does not require a React Native, Expo, Flutter, Swift, Kotlin, or Java test
SDK inside the app. The app only needs stable selectors, predictable navigation,
and build artifacts that ZMR can install or launch.

## React Native

Use app-owned selectors for controls that agents need to find repeatedly:

- `testID` for Android resource ids and iOS accessibility identifiers.
- `accessibilityLabel` for user-facing controls that should be visible to
  assistive technology.
- Stable visible text for headings, tabs, and actions that are not localized or
  data-driven.
- Deep links for jumping directly to logged-in, onboarding, or error states.

Keep generated ZMR files under `.zmr/` and initialize ZMR from the app repo:

```bash
zmr init --app --app-id com.example.mobiletest
```

JavaScript teams that want generated package scripts can use
`npx zmr-wizard --app-id com.example.mobiletest --package-json` instead.

To inspect a generated public fixture with a longer workflow, use the npm
helper from a JavaScript toolchain:

```bash
npx zmr-create-react-native-expo-demo-app --out /tmp/zmr-rn-expo-demo
```

That fixture includes `expo-dev-client`, deep-link setup, stable `testID`
values, accessibility labels, and Android/iOS ZMR workflow scenarios under
`.zmr/`.

## Expo

Expo development builds work like React Native apps once they are installed on
an emulator, simulator, or device. `zmr init --app` creates baseline Android
and iOS smoke scenarios. For dev-client flows that need generated open-link
scenarios, use the JavaScript wizard and give ZMR the scheme that opens the
development build:

```bash
npx zmr-wizard \
  --app-id com.example.mobiletest \
  --expo-dev-client-scheme mobiletest \
  --package-json
```

The wizard adds Android and iOS dev-client scenarios that open Metro
before selector assertions run. For CI, prefer a known Metro command, stable
deep link, and a prebuilt development client.

## Flutter

ZMR supports Flutter apps at the Android/iOS app level. It can launch the app,
open deep links, wait for accessibility semantics, tap visible controls, type
text, take screenshots, collect traces, and export redacted artifacts.

ZMR does not inspect Flutter widget trees, read Dart state, or replace Flutter's
own widget/integration test APIs. For reliable ZMR scenarios, expose stable
selectors through Flutter semantics:

```dart
Semantics(
  label: 'email',
  textField: true,
  child: TextField(...),
)
```

Prefer app-owned semantics labels for form fields, primary buttons, tabs, and
important states. Deep links are the cleanest way to skip setup screens and
reach the state an agent needs to inspect. Do not describe ZMR as a Flutter
widget-tree driver.

## Native Android And iOS

Native apps should expose:

- Android `resourceId` values or content descriptions for important controls.
- iOS accessibility identifiers or labels for important controls.
- Deep links for direct navigation into test states.
- Optional Android and iOS/iPadOS shims when native selector actions and
  bounded hierarchy snapshots are needed.

See [app-integration.md](app-integration.md) for the shim setup commands.
