# Contributing

ZMR is a Zig-based mobile test runner for external agents and local test files.
Keep changes small, typed, traceable, and covered by tests.

## Local Checks

Run the focused checks for your change first, then run the release gate before a
PR:

```bash
zig fmt --check build.zig src
bash -n scripts/*.sh tests/*.sh
bash tests/benchmark-results-test.sh
bash tests/android-emulator-script-test.sh
bash tests/android-pilot-script-test.sh
bash tests/ios-pilot-script-test.sh
bash tests/release-metadata-test.sh
bash tests/homebrew-formula-test.sh
node --test tests/viewer-parser.test.mjs tests/npm-package.test.mjs
bash tests/public-safety-test.sh
zig test src/main.zig -target aarch64-macos.15.0
./scripts/coverage.sh
./scripts/build-release.sh
./scripts/release-smoke.sh dist/*.tar.gz
npm pack --dry-run
```

## Test Expectations

- Keep Zig coverage at or above 90%.
- Add fake-device or fake-shim tests before emulator/simulator-only tests.
- Public examples must use generic app ids and fake data.
- Do not commit raw traces, private app identifiers, tokens, or screenshots.

## Design Expectations

- Keep the public interface in scenario files, JSON-RPC, and documented CLI
  flags.
- Keep platform shims behind adapter boundaries.
- Preserve ADB/simctl fallback behavior until native shims are proven stable.
- Prefer deterministic trace evidence over terminal-only diagnostics.
