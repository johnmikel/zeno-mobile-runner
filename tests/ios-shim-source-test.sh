#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/shims/ios/ZMRShim.swift"
UITEST="$ROOT/shims/ios/ZMRShimUITestCase.swift"

grep -q 'let value: String' "$SHIM"
grep -q 'value: elementValue(element)' "$SHIM"
grep -q 'element.value' "$SHIM"
grep -q 'guard element.exists else' "$SHIM"
grep -q '"value": "Continue"' "$ROOT/shims/ios/protocol.md"
grep -q 'hideKeyboard(app: app)' "$UITEST"
grep -q '"Done"' "$UITEST"
grep -q '"done"' "$UITEST"
grep -q '"Return"' "$UITEST"
grep -q 'resolveElement(selector: selector, app: app, preferredTypes: \[\])' "$UITEST"
grep -q 'resolveBroadElement(selector:' "$UITEST"
grep -q 'app.descendants(matching: .any).matching(predicate)' "$UITEST"
