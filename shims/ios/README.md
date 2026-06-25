# ZMR iOS Shim

This directory contains the app-local XCTest/XCUIAutomation shim scaffold used
for selector-grade iOS and iPadOS automation.

The public ZMR API remains scenario JSON, JSON-RPC, MCP tools, and CLI flags.
The shim protocol is an internal local transport between the Zig runner and an
app-local UI test runner.

Current status:

- Zig-side command and snapshot mapping are covered in `src/ios_shim.zig`.
- `src/ios.zig` can run a configured shim command with one JSON request on
  stdin and one JSON response on stdout.
- `scripts/install-ios-shim.sh` writes an app-local `.zmr/ios-shim` command and
  copies the XCTest source files into the app repo for inclusion in a UI test
  target.
- The generated command caches `xcodebuild build-for-testing` output and runs
  selector commands through `test-without-building`, exchanging per-command
  files under `.zmr/ios-shim-state/`. Set `ZMR_IOS_SHIM_FORCE_REBUILD=1` to
  refresh the cached test bundle, or `ZMR_IOS_SHIM_ONESHOT=1` to force the
  slower one-command XCTest fallback for debugging. When configured with a
  ZMR-owned derived data path ending in `ZMRDerivedData`, the command removes
  only stale shim target products and intermediates before a needed
  `build-for-testing` refresh, preserves app and Pods build outputs, and
  refuses to delete arbitrary shared DerivedData paths.
- The iOS adapter still uses `xcrun simctl` for simulator install, launch,
  terminate, open link, screenshots, and logs. It uses `xcrun devicectl` for
  physical-device lifecycle where Apple exposes a supported local command, and
  uses the XCTest shim for physical-device screenshot artifacts.
- `.zmr/ensure-ios-shim-target.sh` can create or update the UI test target for
  common Xcode project/workspace layouts through the Ruby `xcodeproj` gem.
  Users can still add the generated Swift files manually when their project
  layout needs custom handling.
- ZMR uses the shim as a native selector fast path for single-field tap, type,
  erase-text, and wait/assert queries. Compound selectors stay on the portable
  Zig observe-and-match path.
- Snapshot capture is intentionally bounded to common XCTest element families
  and at most 256 nodes. This keeps traces fast and predictable for large
  React Native, SwiftUI, and UIKit trees while preserving the controls agents
  normally need for follow-up actions.

Support target:

- iOS simulators for full local artifacts: lifecycle, screenshots, logs,
  selector actions, native selector waits, and bounded snapshots.
- Physical iOS devices for lifecycle and selector-grade XCTest automation,
  subject to local signing, provisioning, Developer Mode, and Apple
  `devicectl` availability. Screenshots use the XCTest shim; log artifact
  capture remains simulator-first.
- XCTest/XCUIAutomation snapshots mapped into `UiNode`.
- Selector actions: tap, type, erase text, hide keyboard, swipe, and home/back
  equivalent navigation.
- Clear state means best-effort app uninstall by bundle id.
