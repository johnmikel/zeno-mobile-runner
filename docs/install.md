# Install

ZMR is at present distributed as local release archives built by `scripts/build-release.sh`.

## Build From Source

```bash
git clone <repo-url> zig-mobile-runner
cd zig-mobile-runner
zig test src/main.zig -target aarch64-macos.15.0
zig build-exe src/main.zig -target aarch64-macos.15.0 -O ReleaseSafe -femit-bin=zig-out/bin/zmr
./zig-out/bin/zmr version
```

On this macOS 26 host, Zig `0.15.2` at present needs the explicit `aarch64-macos.15.0` target. Normal Zig environments can also use:

```bash
zig build test
zig build
```

## Local Release Archive

```bash
./scripts/build-release.sh
tar -xzf dist/zmr-0.1.0-aarch64-macos.15.0.tar.gz -C /tmp
/tmp/zmr-0.1.0-aarch64-macos.15.0/zmr version
```

Verify checksums:

```bash
cd dist
shasum -a 256 -c SHA256SUMS
```

Maintainers can run the stricter release verifier after building:

```bash
./scripts/verify-release-artifacts.sh
```

It verifies each checksum entry and requires the archives, SBOM, notices,
Homebrew formula, and `RELEASE_MANIFEST.json` to be present in `SHA256SUMS`.
It also checks that manifest artifact sizes and SHA-256 digests match the files
in `dist/`.

Maintainers publishing macOS archives can sign and notarize them after building
and before uploading release assets:

```bash
./scripts/sign-macos-release.sh --identity "Developer ID Application: Example"
./scripts/notarize-macos-release.sh --keychain-profile "zmr-notary"
./scripts/verify-release-artifacts.sh
```

The signing helper extracts each macOS tarball, signs the `zmr` binary with
hardened runtime, verifies the signature, rebuilds the tarball, refreshes the
Homebrew formula checksums, and regenerates `SHA256SUMS`. Use `--dry-run` to
inspect which archives would be signed.

The notarization helper packages each signed macOS archive for `xcrun
notarytool submit --wait`, writes JSON receipts under `dist/notarization/`,
refreshes `RELEASE_MANIFEST.json`, and regenerates `SHA256SUMS`. It accepts
either `--keychain-profile <profile>` or explicit `--apple-id`, `--team-id`,
and `--password` credentials.

Release metadata is written alongside the archives:

- `SBOM.spdx.json`: SPDX 2.3 software bill of materials for the release.
- `THIRD_PARTY_NOTICES.md`: dependency and license report.
- `homebrew/zmr.rb`: generated Homebrew formula with per-platform archive
  URLs and SHA-256 checksums.
- `RELEASE_MANIFEST.json`: machine-readable release artifact inventory with
  paths, types, sizes, and SHA-256 digests.
- `zig-mobile-runner-*.tgz`: npm package tarball when `npm run pack:npm` has
  been run.
- `notarization/*.notary.json`: optional Apple notarization receipts when
  `scripts/notarize-macos-release.sh` has been run.

All release metadata files and generated package tarballs are included in
`SHA256SUMS`.

## npm Package

`npm run pack:npm` builds release archives, copies the platform binaries into
`prebuilds/`, writes `dist/zig-mobile-runner-*.tgz`, and refreshes
`RELEASE_MANIFEST.json` plus `SHA256SUMS` so the tarball is covered by the same
integrity checks as native archives. The tagged release workflow uploads that
tarball with the GitHub release assets, includes it in artifact attestation, and
runs:

```bash
npm publish dist/zig-mobile-runner-*.tgz --provenance --access public
```

The publish step is skipped unless `NPM_TOKEN` is configured for the repository.

## Homebrew Formula

`scripts/build-release.sh` generates a formula under `dist/homebrew/zmr.rb`.
Tagged releases upload that file with the release assets. For a local release
build:

```bash
brew install --build-from-source ./dist/homebrew/zmr.rb
zmr version
```

For an external tap, copy the generated formula into the tap after confirming
the `url` values point at the final GitHub release asset location.

## First Run

```bash
zmr doctor
zmr init zmr-scenario.json --app-id com.example.mobiletest
zmr init --app --json --dir . --app-id com.example.mobiletest
zmr doctor --strict --json --config .zmr/config.json
zmr validate examples/demo-fake.json
./scripts/demo.sh
```

## npm Install

Inside a mobile app repo:

```bash
npm install --save-dev zig-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
npx zmr-device-matrix --matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix
```

The npm package exposes the app-facing CLI wrapper, setup wizard, benchmark
helpers, matrix runner, pilot gate, shim installers, public demo generators,
release-readiness checker, schemas, examples, reference clients, and the
packaged agent skill. Common app-local commands are:

```bash
npx zmr-wizard --app-id com.example.mobiletest --android --ios --package-json
npx zmr-install-android-shim --app-root . --test-package com.example.mobiletest.test
npx zmr-install-ios-shim --app-root . --scheme SampleUITests --bundle-id com.example.mobiletest
npm run zmr:serve
npm run zmr:mcp
npx zmr-pilot-gate --android --ios --android-app-root . --android-app-id com.example.mobiletest --android-device emulator-5554 --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.mobiletest --ios-device booted --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out traces/zmr-pilots/evidence.jsonl
```

See [docs/npm.md](npm.md) for the full npm binary list, binary resolution,
app-local `.zmr/` setup, and package publishing details.
See [config.md](config.md) for `.zmr/config.json` defaults and CLI override precedence.

## App Codebase Integration

Use the runner from a separate checkout and point it at app build artifacts:

```bash
/path/to/zig-mobile-runner/scripts/run-android-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-id com.example.mobiletest \
  --device emulator-5554

/path/to/zig-mobile-runner/scripts/run-ios-pilot.sh \
  --app-root /path/to/mobile-app \
  --app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app \
  --app-id com.example.mobiletest \
  --device booted
```

See [app-integration.md](app-integration.md) for the expected app-side test surface.

## Android Requirements

- Android SDK platform tools with `adb` on `PATH`.
- A booted emulator or connected device for real Android runs.
- Test app installed with the expected app id, for example `com.example.mobiletest`.

## iOS Requirements

- Xcode command line tools with `xcrun` on `PATH`.
- A booted simulator for real simulator runs, or a paired physical device
  identifier from `zmr devices --json --platform ios --ios-device-type physical`
  for physical-device lifecycle and selector runs.
- `zmr doctor --json` reports simulator readiness as `ios-simulators` and
  paired-device readiness as `ios-physical-devices`, so setup scripts can fail
  fast before install or XCTest work starts.
- A simulator-built `iphonesimulator` `.app` for simulator launch/open-link
  smoke scenarios. A signed device `.ipa` is not simulator-compatible; run it
  with `--ios-device-type physical` and a real physical device identifier.
- Physical-device installs require a signed `.app` or `.ipa` accepted by
  `xcrun devicectl`.
- Optional app-provided XCTest/XCUIAutomation shim command for hierarchy,
  selector actions, and native selector waits. Pass it with `--ios-shim <path>`
  or set `tools.iosShimPath` in `.zmr/config.json`.

To scaffold the shim command and XCTest source into an app repo:

```bash
npx zmr-install-ios-shim \
  --app-root . \
  --scheme SampleUITests \
  --test-target SampleUITests \
  --workspace ios/Sample.xcworkspace \
  --app-target SampleApp \
  --derived-data-path ios/build/ZMRDerivedData \
  --bundle-id com.example.mobiletest \
  --patch-xcodeproj
```

Run `.zmr/ensure-ios-shim-target.sh` to create/update the UI test target, add
the generated Swift files, configure `.zmr/ZMRShimUITests-Info.plist`, and write
a shared scheme. The helper uses the Ruby `xcodeproj` gem. For workspace input,
it resolves the referenced `.xcodeproj` automatically when there is one project,
or when exactly one project contains `--app-target`, or when `--bundle-id` disambiguates
matching app targets. Use `--project ios/Sample.xcodeproj`
instead of `--workspace` for still-ambiguous multi-project workspaces or
project-only apps.

The installer also patches or creates `.zmr/config.json` with
`tools.iosShimPath: "./.zmr/ios-shim"`, so `zmr run`, `zmr serve`, and
`zmr doctor` can discover the shim from app-local config without repeating the
flag on every command.

The generated `.zmr/ios-shim` caches `build-for-testing` output under
`.zmr/ios-shim-state/` and uses `test-without-building` for selector commands.
Set `ZMR_IOS_SHIM_FORCE_REBUILD=1` after app-side target changes, or
`ZMR_IOS_SHIM_ONESHOT=1` for the slower one-command-per-XCTest fallback when
debugging Xcode wiring.

For reliable real simulator and physical-device runs, execute ZMR from a normal
terminal or CI worker with access to Xcode, CoreSimulator, and device caches.
Restricted sandboxes can block Xcode log/cache access and make `xcodebuild` or
`simctl` report misleading setup errors.
