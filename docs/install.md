# Install

Most mobile app teams should install ZMR from npm inside the app repository.
That keeps `.zmr/` config, scenarios, generated package scripts, and traces with
the app they belong to.

## npm Install

```bash
npm install --save-dev zeno-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
```

The wizard creates `.zmr/config.json`, Android and iOS smoke scenarios,
`.zmr/device-matrix.json`, and `.zmr/AGENTS.md`. Run the generated validation
before touching a device:

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

Teams that do not use JavaScript can install or build the `zmr` executable once
and point any language client or script at it:

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

On macOS hosts where Zig can infer the target, `zig build test` and `zig build`
are also valid.

## First Run Without A Device

```bash
zmr version --json
zmr schemas --json
zmr init zmr-scenario.json --app-id com.example.mobiletest
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr validate examples/demo-fake.json
./scripts/demo.sh
```

## App Codebase Integration

ZMR runs outside the app process and points at app build artifacts. For real app
pilots, pass the app root, app id, target device, and optional shim paths:

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

See [app-integration.md](app-integration.md), [frameworks.md](frameworks.md),
and [config.md](config.md) for framework guidance, shim setup, `.zmr/config.json`
defaults, and CLI override precedence.
