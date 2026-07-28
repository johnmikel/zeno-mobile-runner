# Install

Install ZMR where the mobile app lives. That keeps `.zmr/` config, scenarios,
and trace output next to the app they verify.

**Use the curl installer.** It is the framework-neutral path and works the same
for native Android, native iOS, Flutter, React Native, and Expo repositories. It
installs the native `zmr` binary from the GitHub release archive for your OS and
CPU and verifies it against `SHA256SUMS`.

npm is a convenience path for JavaScript teams that want ZMR pinned in
`package.json` — see [Pinning ZMR in a JavaScript repo](#pinning-zmr-in-a-javascript-repo)
below. It installs the same binary; it is not a different product.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/johnmikel/zeno-mobile-runner/main/install.sh | sh
zmr init --app --app-id com.example.mobiletest
zmr doctor --strict --config .zmr/config.json
```

`zmr doctor` ends with a `next` line naming the exact run command for whichever
platform has a device ready.

## Put zmr on your PATH

The installer defaults to `~/.local/bin`, which is **not** on `PATH` on a stock
macOS install or many Linux setups. When that is the case the installer says so
and prints the line to add, for the shell you are actually using. If you skip it,
the next command fails with `zmr: command not found`.

```bash
# zsh (macOS default)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && exec zsh

# bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && exec bash

# fish
fish_add_path ~/.local/bin
```

Prefer somewhere already on `PATH`? Point the installer at it:

```bash
curl -fsSL https://raw.githubusercontent.com/johnmikel/zeno-mobile-runner/main/install.sh | sh -s -- --install-dir /usr/local/bin
```

## Verify the install

```bash
zmr version --json
```

The reported `version` should match the release you installed. This matters more
than it looks: several ZMR scripts resolve the binary as `ZMR_BIN`, then whatever
`zmr` is on `PATH`, then `zig-out/bin/zmr` — so a stale copy earlier in `PATH`
wins silently. If you have ever installed ZMR more than once, check:

```bash
command -v zmr
which -a zmr 2>/dev/null || type -a zmr
```

## Installer options

The installer defaults to the latest GitHub release. It downloads
`zmr-<version>-<target>.tar.gz` plus `SHA256SUMS`, and refuses to install when
the checksum entry is missing or mismatched.

```bash
./install.sh --version 0.2.18 --dry-run
```

Dry-run output includes `checksum-verification: required`, the selected platform
target, the archive URL, and the checksum URL. Nothing is downloaded.

| Option | Purpose |
| --- | --- |
| `--version <version>` | Install a specific release, with or without a leading `v`. |
| `--install-dir <dir>` | Install somewhere other than `~/.local/bin`. |
| `--base-url <url>` | Fetch assets from a staging bucket when testing a release candidate. |
| `--dry-run` | Print the resolved plan and exit. |

## Upgrade and uninstall

Upgrading is the same command — it overwrites the binary in place:

```bash
curl -fsSL https://raw.githubusercontent.com/johnmikel/zeno-mobile-runner/main/install.sh | sh
zmr version --json
```

Uninstalling is removing the binary. Your app-local `.zmr/` directory and any
`traces/` output are yours and are left alone:

```bash
rm ~/.local/bin/zmr
```

If an app repo installed the iOS XCTest shim, remove `.zmr/ios-shim*` and the
generated UI test target from the Xcode project to fully revert it.

## Homebrew or an existing binary

Homebrew is a native install option once you have a generated formula from the
release artifacts:

```bash
brew install --build-from-source ./dist/homebrew/zmr.rb
zmr version
```

Any existing `zmr` binary works with language clients, MCP configs, and scripts
as long as it matches the protocol version the app repo expects.

## Pinning ZMR in a JavaScript repo

Use npm when the app repo wants ZMR pinned as a dev dependency and the helper
commands available in `node_modules/.bin`:

```bash
npm install --save-dev zeno-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --config .zmr/config.json
```

`zmr-wizard` creates `.zmr/config.json`, Android and iOS smoke scenarios,
`.zmr/device-matrix.json`, `.zmr/AGENTS.md`, and optional package scripts.

The helper commands are the reason most JavaScript teams choose this path:

```bash
npx zmr-install-ios-shim --app-root . --scheme SampleUITests --bundle-id com.example.mobiletest
npx zmr-install-android-shim --app-root . --test-package com.example.mobiletest.test
npx zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix
```

`zmr-install-ios-shim` is not optional for iOS selector work. Without the shim
ZMR cannot read the iOS UI tree, so every `tap`, `type`, and text assertion fails
as `selector not found` — launch and snapshot still work, which is why the smoke
scenario passes and the omission stays invisible until your first real scenario.

See [docs/npm.md](npm.md) for the full binary list, native binary resolution, the
Node API, and the maintainer release process.

## Build from source

```bash
git clone https://github.com/johnmikel/zeno-mobile-runner.git
cd zeno-mobile-runner
zig test src/test_harness.zig -target aarch64-macos.15.0
zig build-exe src/main.zig -target aarch64-macos.15.0 -O ReleaseSafe -femit-bin=zig-out/bin/zmr
./zig-out/bin/zmr version
```

The explicit `-target` form is the supported path used by CI and the release
gates. On hosts where Zig can infer the target and locate the system SDK,
`zig build` also works — but it fails on some beta OS releases where the build
runner itself cannot link libc, and the explicit form does not.

## First run without a device

These prove the binary, schemas, and fake-device demo before any device or
simulator setup:

```bash
zmr version --json
zmr schemas --json
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr validate examples/demo-fake.json
./scripts/demo.sh
```

## Next

- [app-integration.md](app-integration.md): app-side test surface and shims
- [frameworks.md](frameworks.md): React Native, Expo, Flutter, and native apps
- [config.md](config.md): `.zmr/config.json` defaults and CLI precedence
- [troubleshooting.md](troubleshooting.md): when a run fails and you want the cause
