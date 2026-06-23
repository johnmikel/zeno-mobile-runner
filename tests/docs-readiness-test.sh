#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD_PACKAGE_NAME="zig""-mobile-runner"
OLD_PRODUCT_NAME="Zig"" Mobile Runner"

require_file() {
  test -f "$ROOT/$1"
}

require_absent_file() {
  local path="$1"
  if test -e "$ROOT/$path"; then
    echo "internal doc should not exist in the public tree: $path" >&2
    exit 1
  fi
}

require_grep() {
  local needle="$1"
  local file="$2"
  if ! grep -q -- "$needle" "$ROOT/$file"; then
    echo "missing '$needle' in $file" >&2
    exit 1
  fi
}

require_not_grep() {
  local needle="$1"
  local file="$2"
  if grep -q -- "$needle" "$ROOT/$file"; then
    echo "unexpected '$needle' in $file" >&2
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
require_file docs/benchmarks/README.md
require_file docs/benchmarks/benchmark-lab-v1.md
require_file docs/benchmarks/benchmark-lab-v1.json
require_file docs/benchmarks/2026-06-09-android-workflow.md
require_file docs/benchmarks/2026-06-09-android-workflow.results.jsonl
require_file docs/benchmarks/2026-06-09-ios-demo.md
require_file docs/benchmarks/2026-06-09-ios-demo.results.jsonl
baseline_doc="docs/benchmarks/2026-06-09-ios-mae""stro-comparison.md"
baseline_results="docs/benchmarks/2026-06-09-ios-mae""stro-comparison.results.jsonl"
baseline_name="Mae""stro"
baseline_tool="mae""stro"
runner_b_doc="docs/benchmarks/2026-06-09-ios-app""ium-comparison.md"
runner_b_results="docs/benchmarks/2026-06-09-ios-app""ium-comparison.results.jsonl"
runner_b_name="App""ium"
runner_b_tool="app""ium"
workflow_doc="docs/benchmarks/2026-06-09-ios-workflow-comparison.md"
workflow_results="docs/benchmarks/2026-06-09-ios-workflow-comparison.results.jsonl"
det_name="Det""ox"
xctest_doc="docs/benchmarks/2026-06-09-ios-xctest-floor.md"
xctest_results="docs/benchmarks/2026-06-09-ios-xctest-floor.results.jsonl"
framework_status_doc="docs/benchmarks/2026-06-09-framework-baseline-status.md"
require_file "$baseline_doc"
require_file "$baseline_results"
require_file "$runner_b_doc"
require_file "$runner_b_results"
require_file "$workflow_doc"
require_file "$workflow_results"
require_file "$xctest_doc"
require_file "$xctest_results"
require_file "$framework_status_doc"
require_file docs/troubleshooting.md
require_file docs/trace-privacy.md
require_file docs/ai-agents.md
require_file docs/clients.md
require_file docs/client-installation.md
require_file docs/scenario-authoring.md
require_file docs/frameworks.md
require_file docs/expo-smoke.md
require_file docs/production-readiness.md
require_file docs/agent-discovery.md
require_file examples/react-native-expo-workflow.json
require_file scripts/create-react-native-expo-demo-app.sh
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

for internal_doc in \
  docs/publication.md \
  docs/release-audit.md \
  docs/release-candidate.md \
  docs/release-evidence.md \
  docs/release-notes-template.md \
  docs/market-positioning.md \
  docs/roadmap.md \
  docs/shipping.md \
  docs/dsl.md; do
  require_absent_file "$internal_doc"
done

require_grep '^# Zeno Mobile Runner$' README.md
require_grep 'verification loop for AI coding agents' README.md
require_grep 'docs/assets/viewer-hero.png' README.md
require_grep 'docs/assets/device-ios-demo.png' README.md
require_grep 'docs/assets/device-android-demo.png' README.md
require_grep 'docs/assets/cli-run-explain.png' README.md
require_grep 'flowchart LR' README.md
require_grep 'sequenceDiagram' README.md
require_grep 'npm install --save-dev zeno-mobile-runner' README.md
require_grep 'bun add --dev zeno-mobile-runner' README.md
require_grep 'npx zmr-wizard --app-id com.example.mobiletest --package-json' README.md
require_grep 'claude mcp add zmr' README.md
require_grep 'mcpServers' README.md
require_grep '## Why agents need this' README.md
require_grep '## The agent verification loop' README.md
require_grep '## Deterministic scenarios for CI' README.md
require_grep 'clearState' README.md
require_grep 'assertHealthy' README.md
require_grep 'zmr validate --json .zmr/login-smoke.json' README.md
require_grep 'zmr run .zmr/login-smoke.json --json --trace-dir traces/login-smoke' README.md
require_grep 'zmr report traces/login-smoke --out traces/login-smoke/report.html --junit traces/login-smoke/junit.xml' README.md
require_grep 'zmr export traces/login-smoke --out login-smoke-redacted.zmrtrace --redact' README.md
require_grep 'nextCommands' README.md
require_grep 'viewer/index.html?bundle=' README.md
require_grep 'ZMR_IOS_SHIM_BUILD_TIMEOUT_SECONDS' README.md
require_grep 'ZMR_IOS_SHIM_RESPONSE_TIMEOUT_SECONDS' README.md
require_grep 'ZMR_IOS_SHIM_TIMEOUT_MS' README.md
require_grep 'iOS physical device' README.md
require_grep 'devicectl' README.md
require_grep 'Current release: `0.2.14` developer preview' README.md
require_grep 'docs/frameworks.md' README.md
require_grep 'docs/expo-smoke.md' README.md
require_grep 'docs/production-readiness.md' README.md
require_grep 'docs/agent-discovery.md' README.md
require_grep 'docs/scenario-authoring.md' README.md
require_grep 'docs/ai-agents.md' README.md
require_grep 'docs/clients.md' README.md
require_grep 'docs/benchmarking.md' README.md
require_grep 'skills/zmr-mobile-testing/SKILL.md' README.md
require_grep 'semantic_snapshot' README.md
require_grep 'install_app' README.md
require_grep 'launch_app' README.md
require_grep 'stop_app' README.md
require_grep 'clear_state' README.md
require_grep 'erase_text' README.md
require_grep 'hide_keyboard' README.md
require_grep 'swipe' README.md
require_grep 'wait_not_visible' README.md
require_grep 'wait_any' README.md
require_grep 'scroll_until_visible' README.md
require_grep 'assert_visible' README.md
require_grep 'assert_not_visible' README.md
require_grep 'assert_healthy' README.md
require_grep 'trace_explain' README.md
require_grep 'trace_discover' README.md
require_grep 'trace_explore' README.md
require_grep 'trace_export' README.md
require_grep 'scenario_validate' README.md

# Detail moved out of the README must stay in its canonical docs.
require_grep 'zmr explore --from-trace' docs/agent-discovery.md
require_grep 'replay' docs/agent-discovery.md
require_grep 'crawl' docs/agent-discovery.md
require_grep 'zmr:android:reliability' docs/benchmarking.md
require_grep 'zmr:ios:reliability' docs/benchmarking.md
require_grep 'zmr-benchmark-lab' docs/benchmarking.md
require_grep 'zmr-benchmark-command' docs/benchmarking.md
require_grep 'does not inspect Flutter widget trees' docs/frameworks.md
require_grep 'zmr-create-react-native-expo-demo-app' docs/frameworks.md
require_grep 'Expo development builds' docs/frameworks.md
require_grep 'TypeScript and Python are the most common starting points' docs/clients.md
require_grep 'Go, Rust, Swift, and Kotlin clients are reference integrations' docs/clients.md

require_not_grep 'registry package is pending publish' README.md
require_not_grep 'Available after the npm registry package is published' README.md
require_not_grep 'Today, install the release tarball from GitHub' README.md
require_not_grep 'docs/dsl.md' README.md
require_not_grep 'docs/market-positioning.md' README.md
require_not_grep 'docs/release-audit.md' README.md
require_not_grep 'docs/shipping.md' README.md
require_not_grep 'Before publishing' README.md
require_not_grep 'verify-release-artifacts.sh' README.md
require_not_grep 'market-claim' README.md
require_not_grep 'competitive claim' README.md
require_not_grep "$OLD_PACKAGE_NAME" README.md
require_not_grep "$OLD_PRODUCT_NAME" README.md

require_grep 'Agent Interface' FEATURES.md
require_grep 'MCP stdio server' FEATURES.md
require_grep 'waits, assertions, trace polling' FEATURES.md
require_grep 'zmr inspect --json' FEATURES.md
require_grep 'zmr explore --from-trace --goal ... --json' FEATURES.md
require_grep 'zmr discover --from-trace' FEATURES.md
require_grep 'zmr run --discover-out <scenario.json> --json' FEATURES.md
require_grep 'replay` coverage metadata' FEATURES.md
require_grep 'zmr draft --from-trace' FEATURES.md
require_grep 'zmr draft --include-actions' FEATURES.md
require_grep 'Native selector wait traces include timeout context' FEATURES.md
require_grep 'Assertion replay preserves `assertVisible` and `assertNotVisible` selectors' FEATURES.md
require_grep '`assertNoneVisible` selector arrays, and `assertHealthy`' FEATURES.md
require_grep 'zmr report --junit <report.xml>' FEATURES.md
require_grep 'Android and iOS pilot wrappers emit `junit.xml`' FEATURES.md
require_grep 'HTML/JUnit report scripts' FEATURES.md
require_grep 'Benchmark directories can be rendered as both HTML and JUnit XML artifacts' FEATURES.md
require_grep 'CI workflow retains run traces, coverage output, and built runner artifacts' FEATURES.md
require_grep 'agent workflow smoke' FEATURES.md
require_grep 'Current Limitations' FEATURES.md
require_grep 'Current release status is `0.2.14`' FEATURES.md
require_grep 'Physical iOS devices through `xcrun devicectl`' FEATURES.md
require_grep 'Physical iOS devices are supported for local lifecycle' CHANGELOG.md
require_grep 'Screenshot artifacts use the XCTest shim' CHANGELOG.md
require_grep 'zmr report --junit <report.xml>' CHANGELOG.md
require_grep 'generated app report and reliability scripts to write `junit.xml`' CHANGELOG.md
require_grep 'beside `report.html` by default' CHANGELOG.md
require_grep 'Android and iOS pilot wrappers to emit `junit.xml`' CHANGELOG.md
require_grep 'release workflows to retain generated run evidence' CHANGELOG.md
require_grep 'Go `DiscoverTrace()` and `ValidateScenario()` helpers' CHANGELOG.md
require_grep 'Rust `discover_trace()` and `validate_scenario()` helpers' CHANGELOG.md
require_grep 'Swift `discoverTrace()` and `validateScenario()` helpers' CHANGELOG.md
require_grep 'Kotlin `discoverTrace()` and `validateScenario()` helpers' CHANGELOG.md
require_grep 'coordinate-complete `ui.swipe` trace replay' CHANGELOG.md
require_grep 'traced `pressBack` replay parity' CHANGELOG.md
require_grep 'direction and timeout preserving `scrollUntilVisible` trace replay' CHANGELOG.md
require_grep 'MCP `erase_text`, `hide_keyboard`, `wait_not_visible`, `wait_any`, and' CHANGELOG.md
require_grep 'MCP `install_app`, `launch_app`, `stop_app`, `clear_state`, and' CHANGELOG.md
require_grep 'MCP `open_link`, unscoped `type`, and `press_back` trace events' CHANGELOG.md
require_grep 'MCP `trace_events` cursor metadata' CHANGELOG.md
require_grep 'JSON-RPC `trace.explain` and MCP `trace_explain`' CHANGELOG.md
require_grep 'zmr explore --from-trace <trace-dir>' CHANGELOG.md
require_grep 'JSON-RPC `trace.explore` and MCP `trace_explore`' CHANGELOG.md
require_grep 'agent workflow smoke' CHANGELOG.md
require_grep 'TypeScript `exploreTrace()`, Python `explore_trace()`, Go' CHANGELOG.md
require_grep 'TypeScript, Python, Go, Rust, Swift, and Kotlin trace explanation helpers' CHANGELOG.md
require_grep '`trace.discover` records a `trace.discover` event' CHANGELOG.md
require_grep 'selector and timeout preserving wait replay' CHANGELOG.md
require_grep 'timeout context to native selector wait trace events' CHANGELOG.md
require_grep 'replay metadata for successful `assertNoneVisible`' CHANGELOG.md
require_grep 'selector and timeout preserving `assertVisible` and `assertNotVisible`' CHANGELOG.md
require_grep 'assertion intent distinct from waits' CHANGELOG.md
require_grep '0.2.14' CHANGELOG.md

require_grep 'React Native' docs/frameworks.md
require_grep 'Expo' docs/frameworks.md
require_grep 'zmr-create-react-native-expo-demo-app' docs/frameworks.md
require_grep 'Flutter' docs/frameworks.md
require_grep 'Flutter apps at the platform level' docs/frameworks.md
require_grep 'not inspect Flutter widget trees' docs/frameworks.md
require_grep 'accessibilityLabel' docs/frameworks.md
require_grep 'Semantics' docs/frameworks.md
require_grep 'Expo Smoke Test' docs/expo-smoke.md
require_grep 'npm install --save-dev zeno-mobile-runner' docs/expo-smoke.md
require_grep 'zmr report traces/zmr-ios --out traces/zmr-ios/report.html' docs/expo-smoke.md
require_grep '--junit traces/zmr-ios/junit.xml' docs/expo-smoke.md
require_grep 'Production Readiness' docs/production-readiness.md
require_grep 'Product Gates Before 1.0' docs/production-readiness.md
require_grep 'Release supply chain' docs/production-readiness.md
require_grep 'trusted publisher must be configured' docs/production-readiness.md
require_grep 'Agentic Standard' docs/production-readiness.md
require_grep 'agent workflow smoke' docs/production-readiness.md
require_grep 'agent workflow smoke' docs/protocol.md
require_grep 'assertion-grade checks' docs/production-readiness.md
require_grep 'zmr report --junit' docs/production-readiness.md
require_grep 'pilot wrapper run that produced both `report.html` and `junit.xml`' docs/production-readiness.md
require_grep 'CI runs retain `traces/`, `zig-cache/coverage/`, and `zig-out/bin/zmr` for 14' docs/production-readiness.md
require_grep 'workflow artifact for 30 days' docs/production-readiness.md
require_grep 'Do not claim Flutter widget-tree inspection' docs/production-readiness.md
require_grep 'npm login --auth-type=web' docs/npm.md
require_grep 'npm whoami' docs/npm.md
require_grep 'Organization or user: `johnmikel`' docs/npm.md
require_grep 'Workflow filename: `release.yml`' docs/npm.md
require_grep 'Allowed actions: `npm publish`' docs/npm.md
require_grep 'npm trust github zeno-mobile-runner' docs/npm.md
require_grep '--repo johnmikel/zeno-mobile-runner' docs/npm.md
require_grep 'If `npm trust` is not available' docs/npm.md
require_grep 'A failed publish with `E404` for an existing package' docs/npm.md
require_grep 'npm publish ./dist/zeno-mobile-runner-<version>.tgz --access public' docs/npm.md
require_grep 'If npm returns `E403`' docs/npm.md
require_grep 'Agent Discovery' docs/agent-discovery.md
require_grep 'trace-backed, not an unbounded crawler' docs/agent-discovery.md
require_grep 'zmr explore --from-trace traces/zmr-agent' docs/agent-discovery.md
require_grep '--goal "find a stable login smoke"' docs/agent-discovery.md
require_grep 'schemas/explore-output.schema.json' docs/agent-discovery.md
require_grep '`autonomous:false`, `reviewRequired:true`, `guardrails`' docs/agent-discovery.md
require_grep 'trace.discover' docs/agent-discovery.md
require_grep 'trace_discover' docs/agent-discovery.md
require_grep 'trace.explore' docs/agent-discovery.md
require_grep 'trace_explore' docs/agent-discovery.md
require_grep 'scenario.validate' docs/agent-discovery.md
require_grep 'scenario_validate' docs/agent-discovery.md
require_grep 'traced run' docs/agent-discovery.md
require_grep '`nextCommands`; traced run' docs/agent-discovery.md
require_grep '--discover-out .zmr/discovered/replay-smoke.json' docs/agent-discovery.md
require_grep '`replay` coverage metadata' docs/agent-discovery.md
require_grep 'coordinate-complete swipes' docs/agent-discovery.md
require_grep 'selector/timeout-preserving' docs/agent-discovery.md
require_grep 'timed `assertHealthy` checks' docs/agent-discovery.md
require_grep 'zmr discover --from-trace traces/zmr-agent' docs/agent-discovery.md
require_grep 'Treat `zmr discover` output as a starting point' docs/agent-discovery.md
require_grep 'zmr draft --from-trace traces/zmr-agent' docs/agent-discovery.md
require_grep '--include-actions' docs/agent-discovery.md
require_grep 'Treat `zmr draft` output as a starting point' docs/agent-discovery.md
require_grep 'Treat `zmr explore` output as a starting point' docs/agent-discovery.md
require_grep 'human review before committing generated tests' docs/agent-discovery.md
require_grep 'DiscoverTrace' docs/clients.md
require_grep 'ExploreTrace' docs/clients.md
require_grep 'ValidateScenario' docs/clients.md
require_grep 'ExplainTrace' docs/clients.md
require_grep 'discover_trace' docs/clients.md
require_grep 'explore_trace' docs/clients.md
require_grep 'validate_scenario' docs/clients.md
require_grep 'explain_trace' docs/clients.md
require_grep 'discoverTrace' docs/clients.md
require_grep 'exploreTrace' docs/clients.md
require_grep 'validateScenario' docs/clients.md
require_grep 'explainTrace' docs/clients.md
require_grep 'trace.explain' docs/clients.md
require_grep 'explainTrace' clients/README.md
require_grep 'explain_trace' clients/README.md
require_grep 'ExplainTrace' clients/README.md
require_grep 'exploreTrace' clients/README.md
require_grep 'explore_trace' clients/README.md
require_grep 'ExploreTrace' clients/README.md

require_grep 'ZMR scenarios are JSON' docs/scenario-authoring.md
require_grep 'resource ids or accessibility identifiers' docs/scenario-authoring.md
require_grep 'Architecture Decisions' docs/adr/README.md
require_grep 'Agent-Native Runner Boundary' docs/adr/0001-agent-native-runner-boundary.md
require_grep 'App-Local `.zmr/` Contract' docs/adr/0002-app-local-zmr-contract.md
require_grep 'iOS XCTest Shim' docs/adr/0003-ios-simulator-xctest-shim.md
require_grep 'Benchmark Claims And Baseline Collection' docs/adr/0004-benchmark-claims-and-baseline-collection.md

require_grep 'AI Agent Guide' docs/ai-agents.md
require_grep 'runner.capabilities' docs/ai-agents.md
require_grep 'zmr mcp' docs/ai-agents.md
require_grep 'semantic_snapshot' docs/ai-agents.md
require_grep 'install_app' docs/ai-agents.md
require_grep 'launch_app' docs/ai-agents.md
require_grep 'stop_app' docs/ai-agents.md
require_grep 'clear_state' docs/ai-agents.md
require_grep 'erase_text' docs/ai-agents.md
require_grep 'hide_keyboard' docs/ai-agents.md
require_grep 'swipe' docs/ai-agents.md
require_grep 'wait_not_visible' docs/ai-agents.md
require_grep 'wait_any' docs/ai-agents.md
require_grep 'scroll_until_visible' docs/ai-agents.md
require_grep 'assert_visible' docs/ai-agents.md
require_grep 'assert_not_visible' docs/ai-agents.md
require_grep 'assert_healthy' docs/ai-agents.md
require_grep 'scenario.validate' docs/ai-agents.md
require_grep 'scenario_validate' docs/ai-agents.md
require_grep 'trace.explain' docs/ai-agents.md
require_grep 'trace_explain' docs/ai-agents.md
require_grep 'trace.explore' docs/ai-agents.md
require_grep 'trace_explore' docs/ai-agents.md
require_grep 'trace.discover' docs/ai-agents.md
require_grep 'trace_discover' docs/ai-agents.md
require_grep 'trace.export' docs/ai-agents.md
require_grep 'Agent-Led Discovery' docs/ai-agents.md
require_grep 'zmr explore --from-trace <trace-dir>' docs/ai-agents.md
require_grep '`autonomous:false`' docs/ai-agents.md
require_grep '`reviewRequired:true`' docs/ai-agents.md
require_grep '`guardrails`' docs/ai-agents.md
require_grep 'zmr discover --from-trace traces/zmr-agent' docs/ai-agents.md
require_grep '--discover-out .zmr/discovered/<name>.json' docs/ai-agents.md
require_grep '`replay` coverage metadata' docs/ai-agents.md
require_grep 'zmr draft --from-trace traces/zmr-agent' docs/ai-agents.md
require_grep '--include-actions' docs/ai-agents.md
require_grep 'selector and timeout data for `assertVisible` and `assertNotVisible`' docs/ai-agents.md
require_grep 'arrays for `assertNoneVisible`' docs/ai-agents.md
require_grep 'agent-discovery.md' docs/ai-agents.md
require_grep 'zmr-mobile-testing' skills/zmr-mobile-testing/SKILL.md
require_grep 'trace_explore' skills/zmr-mobile-testing/SKILL.md
require_grep 'zmr explore --from-trace traces/zmr-agent' skills/zmr-mobile-testing/SKILL.md
require_grep '`autonomous:false`' skills/zmr-mobile-testing/SKILL.md
require_grep '`reviewRequired:true`' skills/zmr-mobile-testing/SKILL.md
require_grep '`guardrails`' skills/zmr-mobile-testing/SKILL.md

require_grep 'zmr init --app' docs/install.md
require_grep 'zmr-wizard' docs/install.md
require_grep 'zmr-device-matrix' docs/install.md
require_grep 'zmr-install-ios-shim' docs/install.md
require_grep 'docs/npm.md' docs/install.md
require_grep 'npm install --save-dev zeno-mobile-runner' docs/client-installation.md
require_not_grep "$OLD_PACKAGE_NAME" docs/client-installation.md
require_not_grep 'Today, install the GitHub release tarball' docs/client-installation.md
require_not_grep 'After the npm registry package is published' docs/client-installation.md

require_grep 'zmr init --app' docs/config.md
require_grep 'zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent' docs/config.md
require_grep 'zmr init --app' docs/demo.md
require_grep 'zmr init --app' docs/npm.md
require_grep 'device-matrix.json' docs/npm.md
require_grep '.zmr/AGENTS.md' docs/npm.md
require_grep 'Expo dev-client scenario' docs/npm.md
require_grep 'zmr:android:report": "zmr report traces/zmr-android --out traces/zmr-android/report.html --junit traces/zmr-android/junit.xml' docs/npm.md
require_grep 'zmr:ios:reliability": "export ZMR_BIN' docs/npm.md
require_grep 'zmr-create-react-native-expo-demo-app' docs/npm.md
require_grep '--junit traces/zmr-ios-reliability/junit.xml' docs/npm.md
require_grep 'zmr version --json' docs/protocol.md
require_grep 'zmr schemas --json' docs/protocol.md
require_grep 'zmr inspect --json' docs/protocol.md
require_grep 'zmr discover --from-trace <trace-dir> --out <scenario.json> --validate --json' docs/protocol.md
require_grep 'zmr run <scenario.json> --trace-dir <trace-dir> --discover-out' docs/protocol.md
require_grep '"replay":{"enabled":true' docs/protocol.md
require_grep 'zmr draft --from-trace <trace-dir> --out <scenario.json> --json' docs/protocol.md
require_grep 'zmr draft --include-actions' docs/protocol.md
require_grep 'install_app' docs/protocol.md
require_grep 'launch_app' docs/protocol.md
require_grep 'stop_app' docs/protocol.md
require_grep 'clear_state' docs/protocol.md
require_grep 'erase_text' docs/protocol.md
require_grep 'hide_keyboard' docs/protocol.md
require_grep 'swipe' docs/protocol.md
require_grep 'wait_not_visible' docs/protocol.md
require_grep 'wait_any' docs/protocol.md
require_grep 'scroll_until_visible' docs/protocol.md
require_grep 'assert_visible' docs/protocol.md
require_grep 'assert_not_visible' docs/protocol.md
require_grep 'assert_healthy' docs/protocol.md
require_grep 'selector/timeout-preserving `assertVisible` and `assertNotVisible`' docs/protocol.md
require_grep '`assertNoneVisible` selector arrays plus timed `assertHealthy` checks' docs/protocol.md
require_grep 'redacted from the trace are skipped' docs/protocol.md
require_grep 'schemas/discover-output.schema.json' docs/protocol.md
require_grep 'schemas/explore-output.schema.json' docs/protocol.md
require_grep 'zmr explore --from-trace <trace-dir> --out <scenario.json> --goal <goal>' docs/protocol.md
require_grep '"mode":"explore"' docs/protocol.md
require_grep 'schemas/draft-output.schema.json' docs/protocol.md
require_grep 'zmr report <trace-or-benchmark-dir> --out <report.html> --junit <report.xml>' docs/protocol.md
require_grep 'zmr report traces/login-smoke --out traces/login-smoke/report.html --junit traces/login-smoke/junit.xml' docs/protocol.md
require_grep 'HTML and JUnit reports' docs/protocol.md
require_grep 'HTML/JUnit report' docs/ai-agents.md
require_grep 'summaries include HTML/JUnit report output' docs/agent-discovery.md
require_grep 'zmr devices --json' docs/protocol.md
require_grep 'zmr validate <scenario.json> --json' docs/protocol.md
require_grep 'zmr explain' docs/troubleshooting.md
require_grep '--junit traces/zmr-android/junit.xml' docs/troubleshooting.md
require_grep 'Android App Pilot Command' docs/app-integration.md
require_grep 'Public Android Demo Command' docs/app-integration.md
require_grep 'React Native' docs/app-integration.md
require_grep 'Flutter' docs/app-integration.md
require_grep 'zmr-device-matrix' docs/benchmarking.md
require_grep '2026-06-09 iOS simulator demo' docs/benchmarking.md
require_grep '20 ZMR runs and 20 baseline runner' docs/benchmarking.md
require_grep 'richer iOS workflow pack' docs/benchmarking.md
require_grep 'profile entry,' docs/benchmarking.md
require_grep 'catalog item selection, save, review' docs/benchmarking.md
require_grep 'Benchmark Lab v1 is the next public evidence layer' docs/benchmarking.md
require_grep 'zmr-benchmark-lab' docs/benchmarking.md
require_grep 'generated Android workflow now has its first 20-run evidence pack' docs/benchmarking.md
require_grep '--junit traces/bench-<timestamp>/junit.xml' docs/benchmarking.md
require_grep 'pilot wrappers and generated app reliability scripts' docs/benchmarking.md
require_grep 'zmr-benchmark-command' docs/benchmarking.md
require_grep 'zmr-compare-benchmarks' docs/benchmarking.md
require_grep 'generated React Native/Expo fixture is now available' docs/benchmarking.md
require_grep '20 repeated runs of' docs/benchmarks/README.md
require_grep 'Benchmark Lab v1' docs/benchmarks/README.md
require_grep '2026-06-09 Android emulator workflow' docs/benchmarks/README.md
require_grep 'zmr-create-react-native-expo-demo-app' docs/benchmarks/README.md
require_grep 'framework-level evidence' docs/benchmarks/benchmark-lab-v1.md
require_grep 'zmr-benchmark-lab --manifest docs/benchmarks/benchmark-lab-v1.json --format markdown' docs/benchmarks/benchmark-lab-v1.md
require_grep '2026-06-09 Android emulator workflow' docs/benchmarks/benchmark-lab-v1.md
require_grep 'React Native/Expo fixture is available' docs/benchmarks/benchmark-lab-v1.md
require_grep 'examples/react-native-expo-workflow.json' docs/benchmarks/benchmark-lab-v1.md
require_grep '"schemaVersion": 1' docs/benchmarks/benchmark-lab-v1.json
require_grep '"react-native-expo-workflow"' docs/benchmarks/benchmark-lab-v1.json
require_grep '"status": "fixture-available"' docs/benchmarks/benchmark-lab-v1.json
require_grep '"appGenerator": "scripts/create-react-native-expo-demo-app.sh"' docs/benchmarks/benchmark-lab-v1.json
require_grep '"flutter-semantics-workflow"' docs/benchmarks/benchmark-lab-v1.json
require_grep '"status": "done"' docs/benchmarks/benchmark-lab-v1.json
require_grep 'ZMR | 20 | 100.00% | 0 | 44134 ms | 46385 ms' docs/benchmarks/2026-06-09-android-workflow.md
require_grep '"tool":"zmr","run":20,"status":"ok"' docs/benchmarks/2026-06-09-android-workflow.results.jsonl
require_grep '2026-06-09 iOS simulator workflow comparison' docs/benchmarks/README.md
require_grep 'Pass rate | 100.00%' docs/benchmarks/2026-06-09-ios-demo.md
require_grep 'Mean duration | 4192 ms' docs/benchmarks/2026-06-09-ios-demo.md
require_grep 'not a comparison against' docs/benchmarks/2026-06-09-ios-demo.md
require_grep '"run":20' docs/benchmarks/2026-06-09-ios-demo.results.jsonl
require_grep "$baseline_name | 20 | 95.00%" "$baseline_doc"
require_grep 'Mean speedup: 3.39x' "$baseline_doc"
require_grep 'Failed to connect to /127.0.0.1:7001' "$baseline_doc"
require_grep "\"tool\":\"$baseline_tool\",\"run\":8,\"status\":\"failed\"" "$baseline_results"
require_grep "$runner_b_name | 20 | 100.00%" "$runner_b_doc"
require_grep 'Mean speedup: 1.66x' "$runner_b_doc"
require_grep "\"tool\":\"$runner_b_tool\",\"run\":20,\"status\":\"ok\"" "$runner_b_results"
require_grep 'profile form, opens a catalog item, saves it, reviews the order' "$workflow_doc"
require_grep 'ZMR | 20 | 100.00% | 0 | 19539 ms | 22970 ms' "$workflow_doc"
require_grep "$baseline_name | 20 | 100.00% | 0 | 36240 ms | 47502 ms" "$workflow_doc"
require_grep 'Mean speedup: 1.85x' "$workflow_doc"
require_grep 'connect ECONNREFUSED 127.0.0.1:8100' "$workflow_doc"
require_grep '"tool":"zmr","run":20,"status":"ok"' "$workflow_results"
require_grep "\"tool\":\"$baseline_tool\",\"run\":20,\"status\":\"ok\"" "$workflow_results"
require_grep 'Direct XCTest shim floor | 20 | 100.00%' "$xctest_doc"
require_grep 'ZMR is now roughly 2.0x the direct warmed shim mean' "$xctest_doc"
require_grep '"tool":"xctest-shim","run":20,"status":"ok"' "$xctest_results"
require_grep "$det_name" "$framework_status_doc"
require_grep 'Flutter' "$framework_status_doc"
require_grep 'Espresso' "$framework_status_doc"
require_grep 'auth/junit.xml' docs/demo.md
require_grep 'ios-smoke/junit.xml' docs/demo.md
require_grep 'ios-shim-smoke/junit.xml' docs/demo.md
require_grep 'zmr validate examples/ios-shim-workflow.json' docs/demo.md
require_grep 'zmr validate examples/android-workflow.json' docs/demo.md
require_grep 'zmr validate examples/react-native-expo-workflow.json' docs/demo.md
require_grep 'npx zmr-create-react-native-expo-demo-app --out /tmp/zmr-rn-expo-demo' docs/demo.md
require_grep 'explore-output.schema.json' schemas/README.md

require_not_grep 'market-claim' docs/ai-agents.md
require_not_grep 'competitive claim' docs/ai-agents.md
require_not_grep 'maintainer release' docs/npm.md
require_not_grep 'source checkout, not the app-install npm package' docs/npm.md
require_not_grep 'pending publish' docs/install.md
require_not_grep 'Today, install' docs/install.md
require_not_grep "$OLD_PACKAGE_NAME" docs/install.md
require_not_grep 'zig build test' docs/install.md
