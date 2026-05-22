#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  test -f "$ROOT/$1"
}

require_grep() {
  local needle="$1"
  local file="$2"
  if ! grep -q -- "$needle" "$ROOT/$file"; then
    echo "missing '$needle' in $file" >&2
    exit 1
  fi
}

require_file README.md
require_file FEATURES.md
require_file SECURITY.md
require_file CONTRIBUTING.md
require_file CHANGELOG.md
require_file clients/README.md
require_file docs/install.md
require_file docs/config.md
require_file docs/protocol.md
require_file docs/demo.md
require_file docs/npm.md
require_file docs/benchmarking.md
require_file docs/troubleshooting.md
require_file docs/publication.md
require_file docs/release-evidence.md
require_file docs/release-candidate.md
require_file docs/release-audit.md
require_file docs/shipping.md
require_file docs/trace-privacy.md
require_file docs/ai-agents.md
require_file docs/clients.md
require_file docs/client-installation.md
require_file docs/dsl.md
require_file docs/market-positioning.md
require_file docs/adr/README.md
require_file schemas/README.md
require_file clients/python/pyproject.toml
require_file clients/swift/Package.swift
require_file clients/swift/Sources/ZMRClient/ZMRClient.swift
require_file clients/kotlin/build.gradle.kts
require_file clients/kotlin/src/main/kotlin/dev/zmr/ZmrClient.kt
require_file skills/zmr-mobile-testing/SKILL.md

require_file .github/ISSUE_TEMPLATE/bug_report.yml
require_file .github/ISSUE_TEMPLATE/feature_request.yml
require_file .github/ISSUE_TEMPLATE/config.yml

require_grep '^# Zig Mobile Runner$' README.md
require_grep 'Agent-native mobile UI automation' README.md
require_grep 'registry package is pending publish' README.md
require_grep 'npm install --save-dev https://github.com/johnmikel/zig-mobile-runner/releases/download/v0.1.0' README.md
require_grep '## Scenario Example' README.md
require_grep 'assertHealthy' README.md
require_grep 'JSON is strict' README.md
require_grep '## Agent And Language Clients' README.md
require_grep 'Rust uses `src/lib.rs`' README.md
require_grep 'physical iOS devices use `devicectl`' README.md
require_grep 'iOS physical device' README.md
require_grep 'zmr validate --json' README.md
require_grep 'zmr devices --json' README.md
require_grep 'zmr schemas --json' README.md
require_grep 'zmr import flow-yaml' README.md
require_grep 'verify-release-artifacts.sh' README.md
require_grep 'zmr-release-readiness' README.md
require_grep 'RELEASE_MANIFEST.json' README.md
require_grep 'release-manifest.schema.json' README.md
require_grep 'release-readiness-output.schema.json' README.md
require_grep 'schemas-output.schema.json' README.md
require_grep 'version-output.schema.json' README.md
require_grep 'capabilities-output.schema.json' README.md
require_grep 'semantic-snapshot.schema.json' README.md
require_grep 'init-output.schema.json' README.md
require_grep 'devices-output.schema.json' README.md
require_grep 'validate-output.schema.json' README.md
require_grep 'run-output.schema.json' README.md
require_grep 'explain-output.schema.json' README.md
require_grep 'docs/adr/' README.md
require_grep 'docs/ai-agents.md' README.md
require_grep 'docs/clients.md' README.md
require_grep 'docs/client-installation.md' README.md
require_grep 'docs/dsl.md' README.md
require_grep 'docs/market-positioning.md' README.md
require_grep 'docs/release-audit.md' README.md
require_grep 'skills/zmr-mobile-testing/SKILL.md' README.md

require_grep 'Agent Interface' FEATURES.md
require_grep 'MCP stdio server' FEATURES.md
require_grep 'zmr-release-readiness' FEATURES.md
require_grep 'Current Limitations' FEATURES.md
require_grep 'npx zmr doctor --strict --json --config .zmr/config.json' README.md
require_grep 'zmr init --app --json --dir . --app-id com.example.mobiletest' README.md
if grep -q 'zmr init --app com.example.mobiletest --json' "$ROOT/README.md"; then
  echo "README should use current zmr init --app --dir/--app-id syntax" >&2
  exit 1
fi
require_grep '`94.40%` line coverage' README.md
require_grep 'Physical iOS devices through `xcrun devicectl`' FEATURES.md
require_grep 'Physical iOS devices are supported for local lifecycle' CHANGELOG.md
require_grep 'Screenshot artifacts use the XCTest shim' CHANGELOG.md
require_grep 'Architecture decision records' CHANGELOG.md
require_grep 'AI agent integration guide' CHANGELOG.md
require_grep 'zmr-benchmark-command' CHANGELOG.md
require_grep 'zmr-compare-benchmarks' CHANGELOG.md

require_grep 'JSON is strict' docs/dsl.md
require_grep 'Human-Friendly Layer' docs/dsl.md
require_grep 'Rust has `src/lib.rs`' docs/clients.md
require_grep 'TypeScript' clients/README.md
require_grep 'Python' clients/README.md
require_grep 'Go' clients/README.md
require_grep 'Rust' clients/README.md
require_grep 'Swift' clients/README.md
require_grep 'Kotlin' clients/README.md
require_grep 'Homebrew' docs/client-installation.md
require_grep 'pip install' docs/client-installation.md
require_grep 'go get' docs/client-installation.md
require_grep 'zmr-client' docs/client-installation.md
require_grep 'Market Positioning' docs/market-positioning.md
require_grep 'Detox' docs/market-positioning.md
require_grep 'Maestro' docs/market-positioning.md
require_grep 'GitHub README plus release assets' docs/market-positioning.md

require_grep 'Architecture Decisions' docs/adr/README.md
require_grep 'Agent-Native Runner Boundary' docs/adr/0001-agent-native-runner-boundary.md
require_grep 'App-Local `.zmr/` Contract' docs/adr/0002-app-local-zmr-contract.md
require_grep 'iOS XCTest Shim' docs/adr/0003-ios-simulator-xctest-shim.md
require_grep 'Benchmark Claims And Baseline Collection' docs/adr/0004-benchmark-claims-and-baseline-collection.md

require_grep 'AI Agent Guide' docs/ai-agents.md
require_grep 'runner.capabilities' docs/ai-agents.md
require_grep 'zmr mcp' docs/ai-agents.md
require_grep 'semantic_snapshot' docs/ai-agents.md
require_grep 'trace.export' docs/ai-agents.md
require_grep 'zmr-release-readiness' docs/ai-agents.md
require_grep 'recommendedWording' docs/ai-agents.md
require_grep 'claimLimitations' docs/ai-agents.md
require_grep 'nextSteps\[\]\.covers' docs/ai-agents.md
require_grep 'zmr-mobile-testing' skills/zmr-mobile-testing/SKILL.md
require_grep 'zmr-release-readiness' skills/zmr-mobile-testing/SKILL.md
require_grep '`satisfied`' skills/zmr-mobile-testing/SKILL.md
require_grep '`blocked`' skills/zmr-mobile-testing/SKILL.md
require_grep '`missing`' skills/zmr-mobile-testing/SKILL.md
require_grep '`insufficient`' skills/zmr-mobile-testing/SKILL.md
require_grep 'recommendedWording' skills/zmr-mobile-testing/SKILL.md
require_grep 'claimLimitations' skills/zmr-mobile-testing/SKILL.md

require_grep 'zmr init --app' docs/install.md
require_grep 'zmr-wizard' docs/install.md
require_grep 'zmr-pilot-gate' docs/install.md
require_grep '--android-device emulator-5554' docs/install.md
require_grep '--ios-device booted' docs/install.md
require_grep '--evidence-out traces/zmr-pilots/evidence.jsonl' docs/install.md
require_grep 'zmr-device-matrix' docs/install.md
require_grep 'zmr-install-ios-shim' docs/install.md
require_grep 'docs/npm.md' docs/install.md
require_grep 'zmr init --app' docs/config.md
require_grep 'zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent' docs/config.md
require_grep 'zmr init --app' docs/demo.md
require_grep 'zmr init --app' docs/npm.md
require_grep 'device-matrix.json' docs/npm.md
require_grep '.zmr/AGENTS.md' docs/npm.md
require_grep '--android-device emulator-5554' docs/npm.md
require_grep '--ios-device booted' docs/npm.md
require_grep '"zmr:mcp": "zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent"' docs/npm.md
require_grep '--zmr-bin ./node_modules/.bin/zmr' docs/npm.md
require_grep 'source checkout, not the app-install npm package' docs/npm.md
require_grep 'zmr-release-readiness' docs/npm.md
require_grep 'missing, insufficient, failed, and planned blockers' docs/npm.md
require_grep 'export ZMR_BIN=' docs/npm.md
require_grep 'reuse it for both' docs/npm.md
require_grep 'Shipped shell helpers' docs/npm.md
require_grep '`PATH` `zmr`' docs/npm.md
require_grep 'Relative app paths passed to pilot wrappers are resolved from the app directory' docs/npm.md
require_grep 'only adds `zmr:readiness` for Android+iOS setups' docs/npm.md
require_grep 'Rerunning `zmr init --app` refreshes generated `.zmr/config.json`' docs/npm.md
require_grep 'Rerunning the wizard refreshes generated `.zmr/config.json`' docs/npm.md
require_grep '`zmr-init` and wizard runs without `--package-json` write direct commands in `.zmr/AGENTS.md`' docs/npm.md
require_grep '`zmr-init` accepts the same platform, shim, and Expo dev-client scaffold flags as the wizard' docs/npm.md
require_grep '`zmr-init` prints direct `Next steps` commands before the package-script snippet' docs/npm.md
require_grep 'npx zmr-init --json' docs/npm.md
require_grep 'npx zmr-wizard --json' docs/npm.md
require_grep 'The JSON form is covered by `schemas/init-output.schema.json`' docs/npm.md
require_grep 'Expo dev-client scenario' docs/npm.md
require_grep 'Wizard runs with `--package-json` write npm script commands in `.zmr/AGENTS.md`' docs/npm.md
require_grep '`--xcrun <path>` when using a custom Xcode toolchain' docs/npm.md
require_grep 'zmr init --json' docs/protocol.md
require_grep '"configPath"' docs/protocol.md
require_grep '"nextCommands"' docs/protocol.md
require_grep '"scriptNames"' docs/protocol.md
require_grep 'androidDevClientScenarioPath' docs/protocol.md
require_grep 'iosDevClientScenarioPath' docs/protocol.md
require_grep 'AGENTS.md' docs/protocol.md
require_grep 'Relative scenario, trace, and shim paths from config resolve against the app' docs/config.md
require_grep 'zmr version --json' docs/protocol.md
require_grep 'zmr mcp' docs/protocol.md
require_grep 'observe.semanticSnapshot' docs/protocol.md
require_grep 'zmr schemas --json' docs/protocol.md
require_grep 'zmr devices --json' docs/protocol.md
require_grep 'Each device includes `ready`' docs/protocol.md
require_grep 'zmr validate <scenario.json> --json' docs/protocol.md
require_grep 'confirm zmr devices --json --platform ios --ios-device-type physical reports ready:true' docs/protocol.md
if grep -q 'xcrun devicectl list devices shows it as connected' "$ROOT/docs/protocol.md"; then
  echo "docs/protocol.md physical iOS doctor examples should use zmr devices, not raw devicectl" >&2
  exit 1
fi
require_grep 'zmr explain' docs/troubleshooting.md
require_grep 'pilot wrappers run setup preflights' docs/troubleshooting.md
require_grep 'setup.ios.no_physical_devices' docs/troubleshooting.md
require_grep 'setup.ios.no_ready_physical_devices' docs/troubleshooting.md
require_grep 'disconnected=1, unavailable=1' docs/troubleshooting.md
require_grep 'setup.ios.physical_device_not_ready' docs/troubleshooting.md
require_grep 'state: disconnected' docs/troubleshooting.md
require_grep '1 ready physical iOS device(s); 3 listed' docs/troubleshooting.md
require_grep 'ios-physical-devices' docs/protocol.md
require_grep 'Android App Pilot Command' docs/app-integration.md
require_grep 'Public Android Demo Command' docs/app-integration.md
require_grep 'npx zmr-wizard --app-id com.example.mobiletest --package-json' docs/app-integration.md
require_grep 'npm run zmr:serve' docs/app-integration.md
require_grep 'npm run zmr:mcp' docs/app-integration.md
if [[ "$(grep -c '^## Android Demo Command$' "$ROOT/docs/app-integration.md")" -ne 0 ]]; then
  echo "docs/app-integration.md should distinguish app pilots from public demos" >&2
  exit 1
fi

require_grep 'zmr-device-matrix' docs/benchmarking.md
require_grep 'zmr-benchmark-command' docs/benchmarking.md
require_grep 'zmr-compare-benchmarks' docs/benchmarking.md
require_grep '--evidence-out traces/bench-comparison/evidence.jsonl' docs/benchmarking.md
require_grep '--results traces/bench-comparison/results.jsonl' docs/benchmarking.md
require_grep 'current app directory' docs/benchmarking.md
require_grep '--min-mean-speedup' docs/benchmarking.md
require_grep '`--evidence-out` requires `--min-candidate-pass-rate`' docs/benchmarking.md
require_grep 'zmr-pilot-gate' docs/benchmarking.md
require_grep '--ios-device-type physical' docs/benchmarking.md
require_grep '--ios-device-type physical' docs/shipping.md
require_grep 'Pass `--zmr-bin /path/to/zmr`' docs/shipping.md
require_grep 'matrix.jsonl' docs/benchmarking.md
require_grep 'summary.json' docs/benchmarking.md

require_grep 'verify-release-artifacts.sh' docs/install.md
require_grep 'verify-release-artifacts.sh' docs/shipping.md
require_grep 'RELEASE_MANIFEST.json' docs/install.md
require_grep 'RELEASE_MANIFEST.json' docs/shipping.md
require_grep 'artifact attestation' docs/shipping.md
require_grep 'release-manifest.schema.json' docs/protocol.md
require_grep 'release-readiness-output.schema.json' docs/protocol.md
require_grep '"insufficient":\[' docs/protocol.md
require_grep '"requirement":"Android hardware pilot + iOS simulator hardware pilot","command":"zmr-pilot-gate' docs/protocol.md
require_grep '"requirement":"physical iOS readiness + iOS physical hardware pilot","command":"zmr-pilot-gate' docs/protocol.md
require_grep 'sign-macos-release.sh' docs/install.md
require_grep 'notarize-macos-release.sh' docs/install.md
require_grep 'npm publish' docs/install.md
require_grep 'npm publish' docs/shipping.md
require_grep 'provenance' docs/shipping.md
require_grep 'Public GitHub Publication' docs/publication.md
require_grep './scripts/release-gate.sh' docs/publication.md
require_grep 'tests/public-safety-test.sh' docs/publication.md
require_grep 'npx zmr doctor --strict --json --config .zmr/config.json' docs/publication.md
require_grep 'Do not commit generated traces' docs/publication.md
require_grep 'Release Evidence Checklist' docs/release-evidence.md
require_grep 'Physical iOS pilot is reliable' docs/release-evidence.md
require_grep '`maxFailures <= 0`' docs/release-evidence.md
require_grep '`minMeanSpeedup >= 1.25`' docs/release-evidence.md
require_grep '`minP95Speedup >= 1.25`' docs/release-evidence.md
require_grep 'candidate name evidence' docs/release-evidence.md
require_grep 'baseline name evidence' docs/release-evidence.md
require_grep 'results path evidence' docs/release-evidence.md
require_grep 'measured result evidence' docs/release-evidence.md
require_grep 'Measured result evidence must be structured' docs/release-evidence.md
require_grep 'same benchmark context evidence' docs/release-evidence.md
require_grep '`sameContext: true`' docs/release-evidence.md
require_grep '`candidateRuns >= 20`' docs/release-evidence.md
require_grep '`baselineRuns >= 20`' docs/release-evidence.md
require_grep '`blocked` lists every' docs/release-evidence.md
require_grep 'zmr-compare-benchmarks' docs/release-evidence.md
require_grep 'competitive benchmark comparison' docs/release-evidence.md
require_grep 'Treat missing evidence as not shipped' docs/release-evidence.md
require_grep 'For missing `production` or `market-claim` evidence' docs/release-evidence.md
require_grep 'readiness returns two app-install-safe commands via `zmr-pilot-gate`' docs/release-evidence.md
require_grep 'one grouped' docs/release-evidence.md
require_grep 'app-install-safe commands' docs/release-evidence.md
require_grep 'file-level next step covers both the missing file' docs/release-evidence.md
require_grep 'do not receive duplicate default pilot commands' docs/release-evidence.md
require_grep 'Release Candidate Gate' docs/release-candidate.md
require_grep 'forwards that path to the physical-readiness check' docs/release-candidate.md
require_grep './scripts/release-candidate.sh --mode local' docs/release-candidate.md
require_grep './scripts/release-candidate.sh --mode hardware' docs/release-candidate.md
require_grep 'zmr-release-readiness' docs/release-candidate.md
require_grep 'evidence.jsonl' docs/release-candidate.md
require_grep 'structured app/device provenance' docs/release-candidate.md
require_grep 'structured threshold fields' docs/release-candidate.md
require_grep 'summary.md' docs/release-candidate.md
require_grep 'blocked requirement output' docs/release-candidate.md
require_grep 'physical iOS' docs/release-candidate.md
require_grep 'market-claim' docs/release-candidate.md
require_grep 'Release Completion Audit' docs/release-audit.md
require_grep 'Prompt-to-artifact checklist' docs/release-audit.md
require_grep 'Not production-stable' docs/release-audit.md
require_grep 'App-install package surface' docs/release-audit.md
require_grep 'excludes maintainer-only release tooling' docs/release-audit.md
require_grep 'zmr-release-readiness --target production' docs/release-audit.md
require_grep 'same-device benchmark evidence' docs/release-audit.md
require_grep 'app-build context' docs/release-audit.md

if grep -q 'zmr doctor --config again' "$ROOT/docs/protocol.md"; then
  echo "docs/protocol.md should recommend strict JSON doctor remediation" >&2
  exit 1
fi

if grep -q 'npx zmr doctor --config .zmr/config.json' "$ROOT/docs/publication.md"; then
  echo "docs/publication.md should use strict JSON doctor in app smoke commands" >&2
  exit 1
fi
require_grep 'docs/release-evidence.md' docs/shipping.md
require_grep 'zmr-release-readiness' docs/shipping.md
require_grep 'zmr-pilot-gate --android --ios --android-app-root /path/to/mobile-app --android-app-id com.example.mobiletest --android-device emulator-5554 --ios-app-root /path/to/mobile-app --ios-app-path /path/to/mobile-app/build/Debug-iphonesimulator/Sample.app --ios-app-id com.example.mobiletest --ios-device booted' docs/shipping.md
require_grep 'zmr-pilot-gate --ios --ios-device-type physical --ios-device <physical-device-id> --ios-app-root /path/to/mobile-app --ios-app-path /path/to/mobile-app/build/Release-iphoneos/Sample.ipa' docs/shipping.md
if grep -q './scripts/run-android-pilot.sh --app-root /path/to/mobile-app' "$ROOT/docs/shipping.md"; then
  echo "docs/shipping.md release acceptance should use zmr-pilot-gate for Android evidence" >&2
  exit 1
fi
if grep -q './scripts/run-ios-pilot.sh --app-root /path/to/mobile-app' "$ROOT/docs/shipping.md"; then
  echo "docs/shipping.md release acceptance should use zmr-pilot-gate for iOS evidence" >&2
  exit 1
fi
require_grep 'zmr-release-readiness' docs/release-evidence.md
require_grep 'recommendedWording' docs/release-evidence.md
require_grep 'claimLimitations' docs/release-evidence.md
require_grep '`passed` lists raw evidence row names' docs/release-evidence.md
require_grep '`missing` lists' docs/release-evidence.md
require_grep '`insufficient` lists passed evidence rows' docs/release-evidence.md
require_grep '`satisfied` lists validated requirement names' docs/release-evidence.md
require_grep '`failed evidence:` and `planned evidence:` blockers' docs/release-evidence.md
require_grep '`nextSteps` is the shortest executable remediation' docs/release-evidence.md
require_grep 'one step can cover multiple blocked requirements' docs/release-evidence.md
require_grep 'Each `nextSteps` item includes `covers`' docs/release-evidence.md
require_grep 'reuse the recorded evidence command' docs/release-evidence.md
require_grep 'Repeated failed or planned rows are reported once per evidence name' docs/release-evidence.md
require_grep 'Malformed evidence JSONL is reported as `invalid evidence`' docs/release-evidence.md
require_grep 'structured `commands` array' docs/release-evidence.md
require_grep 'Malformed evidence JSONL still returns blocked JSON when `--json` is set' docs/release-evidence.md
require_grep 'Android hardware pilot row requires Android device evidence' docs/release-evidence.md
require_grep 'app root evidence' docs/release-evidence.md
require_grep 'app artifact evidence' docs/release-evidence.md
require_grep 'iOS simulator hardware pilot row requires iOS simulator device evidence' docs/release-evidence.md
require_grep 'physical device evidence' docs/release-evidence.md
require_grep 'not `booted`' docs/release-evidence.md
require_grep 'zmr-pilot-gate --android --ios --android-app-root . --android-app-id <android-app-id> --android-device <android-device-id> --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app --ios-app-id <ios-app-id> --ios-device booted' docs/release-evidence.md
require_grep 'zmr-pilot-gate --ios --ios-device-type physical --ios-device <physical-device-id> --ios-app-root . --ios-app-path ./build/Release-iphoneos/Sample.ipa --ios-app-id <ios-app-id>' docs/release-evidence.md
require_grep '--android-device <android-device-id>' docs/release-evidence.md
require_grep 'same benchmark context' docs/benchmarking.md
require_grep '--app-build <build-id-or-artifact>' docs/benchmarking.md
require_grep 'at least 20 candidate rows' docs/benchmarking.md
require_grep 'physical-device pilot row also requires physical device evidence' docs/release-evidence.md
require_grep '`iosDeviceId`, `deviceId`, `device`, `--ios-device`, or a concrete `--device` flag' docs/release-evidence.md
require_grep 'zmr-pilot-gate --ios --ios-device-type physical --ios-device <physical-device-id>' docs/release-evidence.md
require_grep 'Pilot threshold evidence must be structured JSON fields' docs/release-evidence.md
require_grep 'command flags do not count for actual pilot outcomes' docs/release-evidence.md

if grep -Eq 'zmr-pilot-gate[^`]*--ios-device-type physical[^`]*--device <physical-device-id>' "$ROOT/docs/release-evidence.md" "$ROOT/docs/benchmarking.md" "$ROOT/docs/shipping.md"; then
  echo "zmr-pilot-gate physical iOS docs must use --ios-device, not --device" >&2
  exit 1
fi

require_grep 'schemas-output.schema.json' schemas/README.md
require_grep 'release-readiness-output.schema.json' schemas/README.md
require_grep 'version-output.schema.json' schemas/README.md
require_grep 'capabilities-output.schema.json' schemas/README.md
require_grep 'semantic-snapshot.schema.json' schemas/README.md
require_grep 'init-output.schema.json' schemas/README.md
require_grep 'import-output.schema.json' schemas/README.md
require_grep 'devices-output.schema.json' schemas/README.md
require_grep 'validate-output.schema.json' schemas/README.md
require_grep '"schemas"' schemas/schemas-output.schema.json
require_grep '"protocolVersion"' schemas/version-output.schema.json
require_grep '"platformSupport"' schemas/capabilities-output.schema.json
require_grep '"physicalDevices"' schemas/capabilities-output.schema.json
require_grep '"recommendedAction"' schemas/semantic-snapshot.schema.json
require_grep '"mode"' schemas/init-output.schema.json
require_grep '"configPath"' schemas/init-output.schema.json
require_grep '"androidScenarioPath"' schemas/init-output.schema.json
require_grep '"iosScenarioPath"' schemas/init-output.schema.json
require_grep '"androidDevClientScenarioPath"' schemas/init-output.schema.json
require_grep '"iosDevClientScenarioPath"' schemas/init-output.schema.json
require_grep '"deviceMatrixPath"' schemas/init-output.schema.json
require_grep '"agentInstructionsPath"' schemas/init-output.schema.json
require_grep '"nextCommands"' schemas/init-output.schema.json
require_grep '"scriptNames"' schemas/init-output.schema.json
require_grep '"format"' schemas/import-output.schema.json
require_grep '"platform"' schemas/devices-output.schema.json
require_grep '"ready"' schemas/devices-output.schema.json
require_grep '"readyCount"' schemas/doctor-output.schema.json
require_grep '"scriptCount"' schemas/doctor-output.schema.json
require_grep '"scriptNames"' schemas/doctor-output.schema.json
require_grep '"stepCount"' schemas/validate-output.schema.json
require_grep '"failedStepIndex"' schemas/run-output.schema.json
require_grep '"diagnostic"' schemas/explain-output.schema.json
require_grep '"missing"' schemas/release-readiness-output.schema.json
require_grep '"insufficient"' schemas/release-readiness-output.schema.json
require_grep '"blocked"' schemas/release-readiness-output.schema.json
require_grep '"requirements"' schemas/release-readiness-output.schema.json
require_grep '"nextSteps"' schemas/release-readiness-output.schema.json
require_grep 'Shortest executable remediation plan' schemas/release-readiness-output.schema.json
require_grep '"commands"' schemas/release-readiness-output.schema.json
require_grep '"covers"' schemas/release-readiness-output.schema.json
require_grep '"required": \["ok", "target", "status", "evidence", "evidenceFiles", "passed", "satisfied", "failed", "planned", "missing", "insufficient", "blocked", "requirements", "nextSteps", "recommendedWording", "claimLimitations"\]' schemas/release-readiness-output.schema.json
require_grep '"required": \["requirement", "command", "commands", "covers"\]' schemas/release-readiness-output.schema.json
require_grep '"command": { "type": "string", "minLength": 1 }' schemas/release-readiness-output.schema.json
require_grep '"commands": {' schemas/release-readiness-output.schema.json
require_grep '"covers":\[' docs/protocol.md
require_grep '"minItems": 1' schemas/release-readiness-output.schema.json
require_grep '"commands":\[' docs/protocol.md
require_grep '"recommendedWording"' schemas/release-readiness-output.schema.json
require_grep '"claimLimitations"' schemas/release-readiness-output.schema.json
require_grep 'The JSON output includes a `requirements` array' docs/release-evidence.md

if grep -q 'iOS simulator support is a preview' "$ROOT/README.md" "$ROOT/docs/install.md" "$ROOT/docs/shipping.md" "$ROOT/docs/protocol.md"; then
  echo "iOS simulator support should not be documented as preview" >&2
  exit 1
fi

if grep -q 'iOS simulator support remains preview' "$ROOT/CHANGELOG.md"; then
  echo "changelog still lists iOS simulator support as preview" >&2
  exit 1
fi

if grep -q 'screenshot/log capture' "$ROOT/README.md" "$ROOT/FEATURES.md" "$ROOT/CHANGELOG.md" "$ROOT/docs/shipping.md" "$ROOT/docs/protocol.md" "$ROOT/docs/app-integration.md" "$ROOT/shims/ios/README.md"; then
  echo "physical iOS screenshots should be documented as shim-supported, with only log capture limited" >&2
  exit 1
fi

if grep -q -- '--server tests/fake-json-rpc-server' "$ROOT/README.md" "$ROOT/docs"/*.md "$ROOT/clients"/*/README.md; then
  echo "language client docs should run examples through zmr serve, not the fake JSON-RPC server directly" >&2
  exit 1
fi
