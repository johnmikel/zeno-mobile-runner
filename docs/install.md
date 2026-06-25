# Install

Install ZMR where the mobile app lives. That keeps `.zmr/` config, scenarios,
generated package scripts, and trace output next to the app they verify.

Use npm for most app teams, Homebrew or a prebuilt binary for non-JavaScript
teams, and source builds when developing ZMR itself.

## npm Install

Recommended path for app repositories:

```bash
npm install --save-dev zeno-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
```

The wizard creates `.zmr/config.json`, Android and iOS smoke scenarios,
`.zmr/device-matrix.json`, `.zmr/AGENTS.md`, and optional package scripts. Run
the generated validation before touching a device:

```bash
npm run zmr:validate
```

Common app-local commands:

```bash
npx zmr-wizard --app-id com.example.mobiletest --android --ios --package-json
npx zmr-install-android-shim --app-root . --test-package com.example.mobiletest.test
npx zmr-install-ios-shim --app-root . --scheme SampleUITests --bundle-id com.example.mobiletest
npx zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix
npm run zmr:serve
npm run zmr:mcp
```

See [docs/npm.md](npm.md) for the full npm binary list, binary resolution, and
app-local `.zmr/` setup.

## Homebrew Or Existing Binary

Teams that do not use JavaScript can install or build the `zmr` executable once,
then point any language client, MCP config, or script at that binary:

```bash
brew install --build-from-source ./dist/homebrew/zmr.rb
zmr version
```

## Build From Source

```bash
git clone https://github.com/johnmikel/zeno-mobile-runner.git
cd zeno-mobile-runner
zig test src/test_harness.zig -target aarch64-macos.15.0
zig build-exe src/main.zig -target aarch64-macos.15.0 -O ReleaseSafe -femit-bin=zig-out/bin/zmr
./zig-out/bin/zmr version
```

On hosts where Zig can infer the target and locate the system SDK, `zig build`
can also build the binary. The explicit target form above is the supported
verification path used by CI and release gates.

## First Run Without A Device

These commands prove the binary, schemas, and fake-device demo before device
or simulator setup enters the loop:

```bash
zmr version --json
zmr schemas --json
zmr init zmr-scenario.json --app-id com.example.mobiletest
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr validate examples/demo-fake.json
./scripts/demo.sh
```

## App Codebase Integration

ZMR runs outside the app process and points at app build artifacts. For a real
app pilot, pass the app root, app id, target device, and optional shim paths:

```bash
npx zmr-pilot-gate \
  --android \
  --ios \
  --android-app-root . \
  --android-app-id com.example.mobiletest \
  --android-device emulator-5554 \
  --ios-app-root . \
  --ios-app-path ./build/Debug-iphonesimulator/Sample.app \
  --ios-app-id com.example.mobiletest \
  --ios-device booted \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --evidence-out traces/zmr-pilots/evidence.jsonl
```

Next:

- [app-integration.md](app-integration.md): app-side test surface and shims
- [frameworks.md](frameworks.md): React Native, Expo, Flutter, and native apps
- [config.md](config.md): `.zmr/config.json` defaults and CLI precedence
