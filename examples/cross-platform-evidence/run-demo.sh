#!/usr/bin/env bash
# One merge gate over a mobile suite and a web suite, proving the claim rather
# than asserting it:
#
#   1. run a real Playwright suite (Zeno attached only as a reporter)
#   2. run a real ZMR mobile scenario
#   3. validate BOTH evidence packages with the same command
#   4. change one byte in one artifact and watch validation reject it
#
# Nothing here is a fixture. Both packages come from runs that actually
# happened, and step 4 is what makes them worth more than screenshots.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${ZMR_DEMO_OUT:-$ROOT/zig-cache/cross-platform-evidence}"
EVIDENCE_CLI="$ROOT/npm/evidence-cli.mjs"

# Only the parent is created. Both writers refuse to overwrite an existing
# package directory, which is the correct behaviour for tamper-evident output.
rm -rf "$OUT"
mkdir -p "$OUT"

say() { printf '\n=== %s ===\n' "$1"; }

say "1/4  web: a real Playwright run, Zeno attached as a reporter"
consumer="$OUT/consumer"
mkdir -p "$consumer"
cat > "$consumer/package.json" <<'JSON'
{ "name": "zmr-cross-platform-demo", "private": true, "type": "module" }
JSON
# Browsers are already present on a machine that has run Playwright; skip the
# download so the demo does not pull hundreds of megabytes.
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --prefix "$consumer" --silent \
  --no-audit --no-fund "@playwright/test@${ZMR_DEMO_PLAYWRIGHT_VERSION:-1.58.2}" >/dev/null
cp "$ROOT/examples/cross-platform-evidence/checkout.html" \
   "$ROOT/examples/cross-platform-evidence/checkout.spec.mjs" \
   "$ROOT/examples/cross-platform-evidence/zeno-reporter-options.mjs" \
   "$ROOT/examples/cross-platform-evidence/playwright.config.mjs" "$consumer/"

ZMR_REPORTER_PATH="$ROOT/npm/evidence/playwright-reporter.mjs" \
ZMR_WEB_EVIDENCE_OUT="$OUT/web" \
ZMR_BROWSER_VERSION="$(npx --prefix "$consumer" playwright --version 2>/dev/null | awk '{print $2}')" \
  npx --prefix "$consumer" playwright test --config "$consumer/playwright.config.mjs"

say "2/4  mobile: a real ZMR scenario, converted to the same evidence format"
"$ROOT/zig-out/bin/zmr" run "$ROOT/examples/demo-fake.json" \
  --device fake-android-1 --adb "$ROOT/tests/fake-adb.sh" \
  --trace-dir "$OUT/trace" --json >/dev/null

# The mobile target fingerprint is computed over the bytes of the app under test.
# This demo drives a fake device, so there is no real APK; the stand-in below is a
# real file whose real digest is hashed. Point --app-artifact at your actual
# .apk/.ipa and the same command produces evidence about your actual build.
printf 'zmr cross-platform demo: stand-in for an .apk/.ipa\n' > "$OUT/app-under-test.stub"

node "$EVIDENCE_CLI" from-zmr \
  --trace "$OUT/trace" \
  --scenario "$ROOT/examples/demo-fake.json" \
  --project-id "${ZMR_PROJECT_ID:-zeno-demo}" \
  --submitter-type automation \
  --submitter-id cross-platform-example \
  --release-id "${ZMR_RELEASE_ID:-release-demo}" \
  --commit-sha "${ZMR_COMMIT_SHA:-0000000000000000000000000000000000000000}" \
  --surface android \
  --app-artifact "$OUT/app-under-test.stub" \
  --app-id com.example.mobiletest \
  --app-version 1.0.0 \
  --build-number 1 \
  --environment staging \
  --journey-id checkout \
  --item-id checkout-mobile \
  --run-id "${ZMR_MOBILE_RUN_ID:-mobile-run-demo}" \
  --device-name fake-android-1 \
  --os-name android \
  --os-version 14 \
  --out "$OUT/mobile" >/dev/null

say "3/4  one gate over both: same command, same contract"
# The point of this loop is that it has no branch on platform. A merge gate is
# one command per package, and it does not care which suite produced it.
web_manifest="$(find "$OUT/web" -maxdepth 3 -name evidence.json | head -1)"
mobile_manifest="$(find "$OUT/mobile" -maxdepth 3 -name evidence.json | head -1)"
for manifest in "$web_manifest" "$mobile_manifest"; do
  [[ -n "$manifest" ]] || { echo "an evidence package is missing" >&2; exit 1; }
  node "$EVIDENCE_CLI" validate "$manifest" >/dev/null
  printf '  ok  %s\n' "${manifest#"$OUT"/}"
done

say "4/4  tamper check: change one byte and the package stops validating"
victim="$(find "$(dirname "$web_manifest")" -type f ! -name evidence.json | head -1)"
[[ -n "$victim" ]] || { echo "no artifact to tamper with" >&2; exit 1; }
printf 'x' >> "$victim"
if node "$EVIDENCE_CLI" validate "$web_manifest" >/dev/null 2>&1; then
  echo "FAILED: a tampered package still validated" >&2
  exit 1
fi
printf '  rejected after a 1-byte change to %s\n' "$(basename "$victim")"

printf '\nBoth suites, one evidence contract, verifiable by anyone who has the bytes.\n'
printf 'Packages under: %s\n' "$OUT"
