#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output="$("$ROOT/scripts/ci-gate.sh" --dry-run 2>&1)"

python3 - "$output" <<'PY'
import sys

output = sys.argv[1]

required = [
    "zig fmt --check build.zig src",
    "bash -n install.sh scripts/*.sh tests/*.sh",
    "python3 -m py_compile scripts/*.py",
    "zig build-exe src/main.zig -target aarch64-macos.15.0 -O Debug -femit-bin=zig-out/bin/zmr",
    "bash tests/benchmark-lab-test.sh",
    "bash tests/benchmark-results-test.sh",
    "bash tests/device-matrix-test.sh",
    "bash tests/android-emulator-script-test.sh",
    "bash tests/android-shim-install-script-test.sh",
    "bash tests/android-pilot-script-test.sh",
    "bash tests/pilot-gate-script-test.sh",
    "bash tests/ios-demo-app-script-test.sh",
    "bash tests/ios-real-demo-script-test.sh",
    "bash tests/ios-shim-source-test.sh",
    "bash tests/ios-shim-install-script-test.sh",
    "bash tests/ios-shim-target-helper-test.sh",
    "bash tests/ios-pilot-script-test.sh",
    "bash tests/react-native-expo-demo-app-script-test.sh",
    "bash tests/release-gate-script-test.sh",
    "bash tests/release-candidate-script-test.sh",
    "bash tests/release-readiness-script-test.sh",
    "bash tests/ci-gate-script-test.sh",
    "bash tests/release-metadata-test.sh",
    "bash tests/release-manifest-test.sh",
    "bash tests/release-integrity-test.sh",
    "bash tests/macos-signing-script-test.sh",
    "bash tests/macos-notarization-script-test.sh",
    "bash tests/homebrew-formula-test.sh",
    "bash tests/install-script-test.sh",
    "bash tests/public-metadata-guard-test.sh",
    "bash tests/docs-readiness-test.sh",
    "bash tests/workflow-readiness-test.sh",
    "bash tests/demo-script-test.sh",
    "bash tests/mcp-server-test.sh",
    "node --test tests/npm-package.test.mjs",
    "bash tests/go-client-test.sh",
    "bash tests/rust-client-test.sh",
    "if command -v swift >/dev/null 2>&1; then swift test --package-path clients/swift; else echo 'skip swift test: swift not found'; fi",
    "bash tests/kotlin-client-static-test.sh",
    "if command -v gradle >/dev/null 2>&1; then gradle -p clients/kotlin test; else echo 'skip kotlin test: gradle not found'; fi",
    "bash tests/public-safety-test.sh",
    "node --test tests/viewer-parser.test.mjs",
    "zig test src/test_harness.zig -target aarch64-macos.15.0",
    "bash tests/version-json-test.sh",
    "bash tests/schemas-json-test.sh",
    "bash tests/inspect-json-test.sh",
    "bash tests/devices-json-test.sh",
    "bash tests/cli-error-test.sh",
    "bash tests/validate-json-test.sh",
    "bash tests/explain-json-test.sh",
    "bash tests/run-json-test.sh",
    "bash tests/init-app-test.sh",
    "bash tests/import-flow-yaml-test.sh",
    "bash tests/doctor-config-test.sh",
    "bash tests/doctor-strict-test.sh",
    "./zig-out/bin/zmr validate examples/android-app-auth-probe.json",
    "./zig-out/bin/zmr validate examples/ios-smoke.json",
    "./zig-out/bin/zmr doctor --strict --adb ./tests/fake-adb.sh --xcrun ./tests/fake-xcrun.sh",
    "./scripts/demo.sh",
    "./scripts/coverage.sh",
    "npm run test:evidence",
    "npm pack --dry-run",
]

for command in required:
    assert command in output, command

assert output.index("npm run test:evidence") < output.index("npm pack --dry-run")

for delegated_evidence_test in [
    "node --test tests/evidence-contract.test.mjs",
    "node --test tests/evidence-package.test.mjs",
    "node --test tests/evidence-conformance.test.mjs",
    "node --test tests/evidence-json-schema-conformance.test.mjs",
    "node --test tests/evidence-zmr-adapter.test.mjs",
    "node --test tests/evidence-cli.test.mjs",
    "node --test tests/evidence-playwright-reporter.test.mjs",
]:
    assert delegated_evidence_test not in output, delegated_evidence_test

for heavy_release_command in [
    "./scripts/build-release.sh",
    "./scripts/verify-release-artifacts.sh",
    "./scripts/release-smoke.sh dist/*.tar.gz",
]:
    assert heavy_release_command not in output, heavy_release_command
PY
