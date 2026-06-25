# Contributing

ZMR is a Zig-based mobile runner for AI agents, app teams, and deterministic
CI scenarios. Contributions should keep the public surface small, typed,
traceable, and backed by tests or evidence.

## Local Checks

Run focused checks for the files you touched first. Before a PR or release
candidate, run the broader gate:

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

- Keep public behavior in scenario JSON, JSON-RPC, MCP schemas, and documented
  CLI flags.
- Keep platform shims behind adapter boundaries.
- Preserve ADB, UI Automator, `simctl`, and `devicectl` fallback behavior until
  native shims have evidence on the target class.
- Prefer deterministic trace evidence over terminal-only diagnostics.
- Keep product claims tied to [docs/support-matrix.md](docs/support-matrix.md)
  and [docs/production-readiness.md](docs/production-readiness.md).

## Documentation Expectations

- Lead onboarding docs with the user outcome, then give copy-paste commands.
- Keep protocol, schema, ADR, and benchmark docs precise rather than promotional.
- Use app-owned selectors in examples before `stableId` or coordinate fallback.
- Mark unsupported or evidence-needed platforms explicitly.
- Run `bash tests/docs-readiness-test.sh` and
  `bash tests/public-safety-test.sh` before publishing docs.
