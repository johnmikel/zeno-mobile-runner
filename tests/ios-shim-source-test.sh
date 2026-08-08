#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/shims/ios/ZMRShim.swift"
UITEST="$ROOT/shims/ios/ZMRShimUITestCase.swift"

grep -q 'let value: String' "$SHIM"
grep -q 'struct ZMRShimViewport' "$SHIM"
grep -q 'static func viewport(app: XCUIApplication)' "$SHIM"
grep -q 'value: elementValue(snapshot)' "$SHIM"
grep -q 'snapshot.value' "$SHIM"
grep -q 'guard let captured = try? element.snapshot() else' "$SHIM"
grep -q '"value": "Continue"' "$ROOT/shims/ios/protocol.md"
grep -q '"viewport": { "width": 390, "height": 844 }' "$ROOT/shims/ios/protocol.md"
grep -q 'hideKeyboard(app: app)' "$UITEST"
grep -q '"viewport": ZMRShim.viewport(app: app).json' "$UITEST"
grep -q 'case "viewport"' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "viewport command must not enumerate snapshot nodes" unless source.match?(/case "viewport":\s*return \[\s*"status": "ok",\s*"viewport": ZMRShim\.viewport\(app: app\)\.json\s*\]/m)' "$UITEST"
grep -q '"Done"' "$UITEST"
grep -q '"done"' "$UITEST"
grep -q '"Return"' "$UITEST"
grep -q 'resolveFastElement(selector: selector, app: app, preferredTypes: \[\])' "$UITEST"
grep -q 'resolveBroadElement(selector:' "$UITEST"
grep -q 'allDescendantQueries(app: app, type: .any).map { $0.matching(predicate) }' "$UITEST"
grep -q 'app.windows.descendants(matching: type)' "$SHIM"
grep -q '.other' "$SHIM"
grep -q 'identifier != %@' "$SHIM"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "snapshotQueries needs explicit default return" unless source.match?(/if type == \.other \{.*?return \[.*?\}\s*return \[/m)' "$SHIM"
grep -q 'app.windows.descendants(matching: type)' "$UITEST"
grep -q 'commandRequiresForeground' "$UITEST"
grep -q 'ensureAppForeground' "$UITEST"
grep -q 'app.activate()' "$UITEST"
grep -q '.runningForeground' "$UITEST"
grep -q 'acceptExpoDevClientDeepLink(' "$UITEST"
grep -q 'openedURL: command.url' "$UITEST"
grep -q 'Deep link received:' "$UITEST"
grep -q 'isExpoDevClientDeepLinkTarget(label:' "$UITEST"
grep -q 'label.contains("://")' "$UITEST"
grep -q 'resumeExpoDevClientHome(app: app)' "$UITEST"
grep -q 'Development servers' "$UITEST"
grep -q 'isExpoDevClientProjectTarget(label:' "$UITEST"
grep -q 'tapFirstMatchingExpoCandidate' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "Expo candidate queries must include targeted staticText fallback" unless source.include?("queries: [app.buttons, app.cells, app.staticTexts]")' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "Expo candidate helper must scan bounded matches, not only firstMatch" unless source.include?("for candidateIndex in 0..<6") && source.include?("matching.element(boundBy: candidateIndex)")' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "Expo candidate helper must be able to tap matched visible element frames when XCTest reports them as non-hittable" unless source.include?("tapMatchedExpoCandidate(element: element, app: app)") && source.include?("let visibleFrame = element.frame.intersection(app.frame)") && source.include?("app.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedY)).tap()")' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "Expo candidate fallback must still prefer direct hittable element taps before frame-based coordinate taps" unless source.match?(/if element\.isHittable \{.*?element\.coordinate\(withNormalizedOffset: CGVector\(dx: 0\.5, dy: 0\.5\)\)\.tap\(\).*?return true.*?let visibleFrame = element\.frame\.intersection\(app\.frame\)/m)' "$UITEST"
grep -q 'expoDevClientFallback' "$SHIM"
grep -q 'waitForExpoDevClientRecovery(' "$UITEST"
grep -q 'expoDevClientRecoveryTimeout' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "Expo fallback must not report coordinate taps as accepted without observing a launcher state" if source.include?("tapExpoDevClientDeepLinkCoordinateFallback") || source.include?("CGVector(dx: 0.5, dy: 0.6)")' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); fallback = source.index("if expoDevClientFallback,"); recovery = source.index("waitForExpoDevClientRecovery("); abort "Expo fallback must use a bounded recovery loop for custom non-dev-client URLs" unless fallback && recovery && fallback < recovery' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); body = source[/private func waitForExpoDevClientRecovery\(.*?\) -> \(accepted: Bool, label: String\) \{(.*?)\n    \}/m, 1] || ""; abort "Expo recovery loop must poll until a deadline" unless body.include?("let deadline = Date().addingTimeInterval(expoDevClientRecoveryTimeout)") && body.include?("while Date() < deadline") && body.include?("Thread.sleep(forTimeInterval: 0.2)")' "$UITEST"
ruby -e 'source = File.read(ARGV.fetch(0)); abort "Expo fallback must still be gated by custom non-dev-client URLs" unless source.include?("isCustomSchemeURL(openedURL)") && source.include?("!isExpoDevClientURL(openedURL)")' "$UITEST"
if grep -q 'app.staticTexts.allElementsBoundByIndex' "$UITEST"; then
  echo "Expo dev-client helpers must not enumerate staticTexts by index; it can crash XCTest when the screen mutates" >&2
  exit 1
fi
# Same failure mode, other file. The snapshot walker binds element proxies with
# allElementsBoundByIndex, so reading an attribute off the live XCUIElement
# afterwards re-resolves the query; if the screen mutated in between, XCUITest
# raises "Failed to get matching snapshot: No matches found for Element at
# index N". That is an XCTest failure rather than a Swift error, so it cannot be
# caught at the call site -- it fails the test case and takes the shim server
# down mid-session. Read attributes from the atomic capture instead.
if grep -vE '^[[:space:]]*//' "$SHIM" | grep -qE 'element\.(label|value|frame|identifier|isEnabled|isSelected|exists)\b'; then
  echo "ZMRShim must read attributes from an atomic element snapshot, not a live XCUIElement; live reads re-resolve the query and crash XCTest when the screen mutates" >&2
  exit 1
fi

# The Swift shim and the Zig parser are two halves of one wire format, in two
# languages, with nothing but discipline holding them together. They drifted:
# the parser read value, checked and focused; the serializer emitted none of
# them. `value` was worse than missing — the struct populated it and the docs
# specified it, so everything looked right except the bytes on the wire, and
# every test fixture supplied the field the product never sent.
#
# This asserts the contract directly: every node field the parser reads must be
# emitted by the serializer.
python3 - "$ROOT/src/ios_shim.zig" "$UITEST" <<'PY'
import re
import sys

parser_src = open(sys.argv[1], encoding="utf-8").read()
swift_src = open(sys.argv[2], encoding="utf-8").read()

# Fields the Zig parser reads off a node object.
body = parser_src[parser_src.index("for (nodes_value.array.items)"):]
body = body[: body.index("return .{")]
read = set(re.findall(r'(?:nonEmptyF|f)ieldString\(object, "([a-zA-Z]+)"\)', body))
read |= set(re.findall(r'boolField\(object, "([a-zA-Z]+)"', body))
read |= set(re.findall(r'object\.get\("([a-zA-Z]+)"\)', body))

# Keys the Swift serializer actually puts on the wire.
block = swift_src[swift_src.index("private extension ZMRShimNode"):]
block = block[: block.index("\n}", block.index("var json"))]
emitted = set(re.findall(r'"([a-zA-Z]+)"\s*:', block))

missing = sorted(read - emitted)
if missing:
    print(f"parser reads node fields the shim never sends: {', '.join(missing)}", file=sys.stderr)
    print(f"  parser reads:   {', '.join(sorted(read))}", file=sys.stderr)
    print(f"  shim emits:     {', '.join(sorted(emitted))}", file=sys.stderr)
    raise SystemExit(1)
print(f"ios shim wire contract: {len(read)} node fields, all emitted")
PY
