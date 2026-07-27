#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output="$("$ROOT/scripts/release-gate.sh" --dry-run 2>&1)"
static_output="$("$ROOT/scripts/release-gate.sh" --phase static --dry-run 2>&1)"
phase_list="$("$ROOT/scripts/release-gate.sh" --list-phases)"

set +e
unknown_phase_output="$("$ROOT/scripts/release-gate.sh" --phase nope --dry-run 2>&1)"
unknown_phase_status=$?
set -e
if [[ "$unknown_phase_status" -ne 2 ]]; then
  echo "release-gate should reject unknown phases with exit 2" >&2
  exit 1
fi
grep -q 'unknown release gate phase: nope' <<< "$unknown_phase_output"

python3 - "$output" "$static_output" "$phase_list" <<'PY'
import sys

output = sys.argv[1]
static_output = sys.argv[2]
phase_list = sys.argv[3].splitlines()

required = [
    "zig fmt --check build.zig src",
    "bash -n install.sh scripts/*.sh scripts/hooks/* tests/*.sh",
    "python3 -m py_compile scripts/*.py",
    "./scripts/verify-release-version.sh",
    "bash tests/benchmark-lab-test.sh",
    "bash tests/benchmark-results-test.sh",
    "bash tests/device-matrix-test.sh",
    "bash tests/android-emulator-script-test.sh",
    "bash tests/android-demo-app-script-test.sh",
    "bash tests/android-real-demo-script-test.sh",
    "bash tests/android-shim-install-script-test.sh",
    "bash tests/android-pilot-script-test.sh",
    "bash tests/pilot-gate-script-test.sh",
    "bash tests/ios-demo-app-script-test.sh",
    "bash tests/ios-real-demo-script-test.sh",
    "bash tests/ios-shim-source-test.sh",
    "bash tests/ios-shim-install-script-test.sh",
    "bash tests/ios-shim-target-helper-test.sh",
    "bash tests/ios-pilot-script-test.sh",
    "bash tests/release-candidate-script-test.sh",
    "bash tests/release-version-test.sh",
    "bash tests/release-readiness-script-test.sh",
    "bash tests/coverage-script-test.sh",
    "bash tests/ci-gate-script-test.sh",
    "bash tests/release-metadata-test.sh",
    "bash tests/release-manifest-test.sh",
    "bash tests/release-integrity-test.sh",
    "bash tests/release-smoke-script-test.sh",
    "bash tests/macos-signing-script-test.sh",
    "bash tests/macos-notarization-script-test.sh",
    "bash tests/homebrew-formula-test.sh",
    "bash tests/install-script-test.sh",
    "bash tests/public-metadata-guard-test.sh",
    "bash tests/docs-readiness-test.sh",
    "bash tests/workflow-readiness-test.sh",
    "bash tests/demo-script-test.sh",
    "bash tests/mcp-server-test.sh",
    "bash tests/rpc-draft-test.sh",
    "node --test tests/npm-package.test.mjs",
    "bash tests/go-client-test.sh",
    "bash tests/rust-client-test.sh",
    "if command -v swift >/dev/null 2>&1; then swift test --package-path clients/swift; else echo 'skip swift test: swift not found'; fi",
    "bash tests/kotlin-client-static-test.sh",
    "if command -v gradle >/dev/null 2>&1; then gradle -p clients/kotlin test; else echo 'skip kotlin test: gradle not found'; fi",
    "bash tests/public-safety-test.sh",
    "node --test tests/viewer-parser.test.mjs",
    "zig test src/test_harness.zig -target aarch64-macos.15.0",
    "zig build-exe src/main.zig -target aarch64-macos.15.0 -O Debug -femit-bin=zig-out/bin/zmr",
    "bash tests/version-json-test.sh",
    "bash tests/schemas-json-test.sh",
    "bash tests/discover-json-test.sh",
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
    "./scripts/build-release.sh",
    "./scripts/verify-release-artifacts.sh",
    "./scripts/release-smoke.sh dist/*.tar.gz",
    "npm pack --dry-run",
]

for command in required:
    assert command in output, command

assert phase_list == [
    "static",
    "platform-scripts",
    "clients",
    "protocol-smoke",
    "release-artifacts",
]
assert "== release gate phase: static ==" in output
assert "== release gate phase: platform-scripts ==" in output
assert "== release gate phase: clients ==" in output
assert "== release gate phase: protocol-smoke ==" in output
assert "== release gate phase: release-artifacts ==" in output

assert "== release gate phase: static ==" in static_output
assert "zig fmt --check build.zig src" in static_output
assert "bash tests/benchmark-lab-test.sh" in static_output
assert "./scripts/demo.sh" not in static_output
assert "./scripts/build-release.sh" not in static_output

assert "External pilot gates not run by default" in output
assert "./scripts/pilot-gate.sh --android --android-app-root /path/to/mobile-app --android-app-id com.example.mobiletest --android-device emulator-5554 --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl" in output
assert "./scripts/pilot-gate.sh --ios --ios-app-root /path/to/mobile-app --ios-app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.mobiletest --ios-device booted --ios-shim /path/to/mobile-app/.zmr/ios-shim --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl" in output
assert "./scripts/pilot-gate.sh --ios --ios-device-type physical --ios-device <physical-device-id> --ios-app-root /path/to/mobile-app --ios-app-path /path/to/mobile-app/build/Release-iphoneos/Sample.ipa --ios-app-id com.example.mobiletest --ios-shim /path/to/mobile-app/.zmr/ios-shim --runs 20 --min-pass-rate 100 --max-failures 0 --evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl" in output
assert "--evidence-out /path/to/mobile-app/traces/zmr-pilots/evidence.jsonl" in output
assert "./scripts/run-android-pilot.sh --app-root /path/to/mobile-app" not in output
assert "./scripts/run-ios-pilot.sh --app-root /path/to/mobile-app" not in output
PY
