#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
require_grep 'npm install --save-dev zeno-mobile-runner' README.md
require_grep 'React Native, Expo, and Flutter' README.md
require_grep 'Flutter apps at the Android and iOS app level' README.md
require_grep 'not a Flutter widget-tree driver' README.md
require_grep 'Expo development builds' README.md
require_grep '## Scenario Example' README.md
require_grep 'assertHealthy' README.md
require_grep 'zmr validate --json' README.md
require_grep 'zmr devices --json' README.md
require_grep 'zmr schemas --json' README.md
require_grep 'zmr inspect --json' README.md
require_grep 'zmr explore --from-trace traces/zmr-agent --out .zmr/discovered/login-smoke.json --goal "find a stable login smoke" --include-actions --validate --json' README.md
require_grep '--discover-out .zmr/discovered/login-smoke.json' README.md
require_grep 'zmr report traces/login-smoke --out traces/login-smoke/report.html --junit traces/login-smoke/junit.xml' README.md
require_grep 'The generated report handoff writes `report.html` and' README.md
require_grep '`junit.xml` beside the trace for CI artifact collection' README.md
require_grep 'zmr discover --from-trace traces/zmr-agent' README.md
require_grep 'zmr discover --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --validate --json' README.md
require_grep 'zmr draft --from-trace traces/zmr-agent' README.md
require_grep 'zmr draft --from-trace traces/zmr-agent --out .zmr/discovered/replay-smoke.json --include-actions --json' README.md
require_grep 'It does not crawl the app' README.md
require_grep 'Unsupported or underspecified events are' README.md
require_grep 'skipped with warnings instead of guessed' README.md
require_grep 'redacted from the trace are also skipped' README.md
require_grep 'timed `assertHealthy` checks' README.md
require_grep 'selector/timeout-preserving `assertVisible` and' README.md
require_grep 'Native selector wait traces include timeout context' README.md
require_grep 'zmr export traces/login-smoke --out traces/login-smoke-redacted.zmrtrace --redact' README.md
require_grep 'For traced runs, `zmr run --json` returns executable `nextCommands`' README.md
require_grep 'When an agent should produce the reviewable scenario in the same command' README.md
require_grep 'zmr discover --from-trace' README.md
require_grep 'discovery.replay' README.md
require_grep '## Optional Protocol Clients' README.md
require_grep 'TypeScript and Python are the most common starting points' README.md
require_grep 'Go, Rust, Swift, and Kotlin clients are reference integrations' README.md
require_grep 'Go and Rust' README.md
require_grep 'scenario validation helpers for' README.md
require_grep 'Swift and Kotlin include lightweight discovery and' README.md
require_grep 'physical iOS devices use `devicectl`' README.md
require_grep 'iOS physical device' README.md
require_grep 'Current release: `0.1.7` developer preview' README.md
require_grep 'docs/frameworks.md' README.md
require_grep 'docs/expo-smoke.md' README.md
require_grep 'docs/production-readiness.md' README.md
require_grep 'docs/agent-discovery.md' README.md
require_grep '`zmr explore` is not an autonomous crawler' README.md
require_grep '`autonomous:false`, `reviewRequired:true`, `guardrails`' README.md
require_grep 'docs/scenario-authoring.md' README.md
require_grep 'docs/ai-agents.md' README.md
require_grep 'docs/clients.md' README.md
require_grep 'skills/zmr-mobile-testing/SKILL.md' README.md
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
require_not_grep 'zig-mobile-runner' README.md
require_not_grep 'Zig Mobile Runner' README.md

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
require_grep 'Current Limitations' FEATURES.md
require_grep 'Current release status is `0.1.7`' FEATURES.md
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
require_grep 'TypeScript `exploreTrace()`, Python `explore_trace()`, Go' CHANGELOG.md
require_grep 'TypeScript, Python, Go, Rust, Swift, and Kotlin trace explanation helpers' CHANGELOG.md
require_grep '`trace.discover` records a `trace.discover` event' CHANGELOG.md
require_grep 'selector and timeout preserving wait replay' CHANGELOG.md
require_grep 'timeout context to native selector wait trace events' CHANGELOG.md
require_grep 'replay metadata for successful `assertNoneVisible`' CHANGELOG.md
require_grep 'selector and timeout preserving `assertVisible` and `assertNotVisible`' CHANGELOG.md
require_grep 'assertion intent distinct from waits' CHANGELOG.md
require_grep '0.1.7' CHANGELOG.md

require_grep 'React Native' docs/frameworks.md
require_grep 'Expo' docs/frameworks.md
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
require_grep 'assertion-grade checks' docs/production-readiness.md
require_grep 'zmr report --junit' docs/production-readiness.md
require_grep 'pilot wrapper run that produced both `report.html` and `junit.xml`' docs/production-readiness.md
require_grep 'CI runs retain `traces/`, `zig-cache/coverage/`, and `zig-out/bin/zmr` for 14' docs/production-readiness.md
require_grep 'workflow artifact for 30 days' docs/production-readiness.md
require_grep 'Do not claim Flutter widget-tree inspection' docs/production-readiness.md
require_grep 'npm login --auth-type=web' docs/npm.md
require_grep 'npm whoami' docs/npm.md
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
require_not_grep 'zig-mobile-runner' docs/client-installation.md
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
require_grep '--junit traces/bench-<timestamp>/junit.xml' docs/benchmarking.md
require_grep 'pilot wrappers and generated app reliability scripts' docs/benchmarking.md
require_grep 'zmr-benchmark-command' docs/benchmarking.md
require_grep 'zmr-compare-benchmarks' docs/benchmarking.md
require_grep 'auth/junit.xml' docs/demo.md
require_grep 'ios-smoke/junit.xml' docs/demo.md
require_grep 'ios-shim-smoke/junit.xml' docs/demo.md
require_grep 'explore-output.schema.json' schemas/README.md

require_not_grep 'market-claim' docs/ai-agents.md
require_not_grep 'competitive claim' docs/ai-agents.md
require_not_grep 'maintainer release' docs/npm.md
require_not_grep 'source checkout, not the app-install npm package' docs/npm.md
require_not_grep 'pending publish' docs/install.md
require_not_grep 'Today, install' docs/install.md
require_not_grep 'zig-mobile-runner' docs/install.md
