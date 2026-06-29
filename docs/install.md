# Install

Install ZMR where the mobile app lives. That keeps `.zmr/` config, scenarios,
generated package scripts, and trace output next to the app they verify.

Use the curl installer for the framework-neutral path. It installs the native
`zmr` binary from the GitHub release archive for your OS and CPU, verifies the
archive against `SHA256SUMS`, and leaves app setup to `zmr init --app`. npm
remains the convenience path for JavaScript teams that want package scripts and
helper bins in `node_modules/.bin`.

## Curl Install

Recommended path for native Android, native iOS, Flutter, React Native, Expo,
and mixed mobile repositories:

```bash
curl -fsSL https://raw.githubusercontent.com/johnmikel/zeno-mobile-runner/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
zmr init --app --app-id com.example.mobiletest
zmr doctor --strict --json --config .zmr/config.json
```

The installer defaults to the latest GitHub release. It downloads
`zmr-<version>-<target>.tar.gz` plus `SHA256SUMS` from the release, and refuses
to install when the archive checksum entry is missing or mismatched:

```bash
./install.sh --version 0.2.16 --dry-run
```

Dry-run output includes `checksum-verification: required`, the selected
platform target, the archive URL, and the checksum URL. Use
`--install-dir <dir>` to install somewhere other than `~/.local/bin`, or
`--base-url <url>` when testing release candidates from a staging bucket.

The native binary works the same way regardless of app framework:

```bash
zmr validate .zmr/android-smoke.json
zmr run .zmr/android-smoke.json --device emulator-5554 --trace-dir traces/zmr-android --ensure-device
zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
```

## JavaScript Teams

Use npm when the app repo wants ZMR pinned as a dev dependency, generated npm
scripts, and the helper commands such as `zmr-wizard`,
`zmr-install-android-shim`, `zmr-install-ios-shim`, and `zmr-device-matrix`:

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

Homebrew remains a native install option once you have a generated formula from
the release artifacts:

```bash
brew install --build-from-source ./dist/homebrew/zmr.rb
zmr version
```

Any existing `zmr` binary can also be used by language clients, MCP configs, or
scripts as long as it matches the protocol version expected by the app repo.

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
