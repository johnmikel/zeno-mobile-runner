#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DIST="$TMPDIR/dist"
mkdir -p "$DIST/homebrew" "$TMPDIR/bin"

cat > "$TMPDIR/bin/ditto" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ZMR_FAKE_DITTO_LOG"
out="${@: -1}"
printf 'fake notarization zip\n' > "$out"
SH
chmod +x "$TMPDIR/bin/ditto"

cat > "$TMPDIR/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ZMR_FAKE_XCRUN_LOG"
if [[ "$*" != *"notarytool submit"* ]]; then
  echo "unexpected xcrun command: $*" >&2
  exit 1
fi
printf '{"id":"fake-submission","status":"Accepted"}\n'
SH
chmod +x "$TMPDIR/bin/xcrun"

make_archive() {
  local target="$1"
  local dir="$DIST/zmr-0.1.6-$target"
  mkdir -p "$dir"
  printf 'signed binary for %s\n' "$target" > "$dir/zmr"
  tar -C "$DIST" -czf "$dir.tar.gz" "$(basename "$dir")"
  rm -rf "$dir"
}

make_archive "aarch64-macos.15.0"
make_archive "x86_64-macos.15.0"
make_archive "x86_64-linux-gnu"
make_archive "aarch64-linux-gnu"
printf '{"spdxVersion":"SPDX-2.3"}\n' > "$DIST/SBOM.spdx.json"
printf '# Notices\n' > "$DIST/THIRD_PARTY_NOTICES.md"
printf 'class Zmr < Formula\nend\n' > "$DIST/homebrew/zmr.rb"
node "$ROOT/scripts/generate-release-manifest.mjs" --dist "$DIST" --version "0.1.6" --out "$DIST/RELEASE_MANIFEST.json" >/dev/null
(
  cd "$DIST"
  shasum -a 256 ./*.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb RELEASE_MANIFEST.json > SHA256SUMS
)

ZMR_FAKE_DITTO_LOG="$TMPDIR/ditto.log" \
ZMR_FAKE_XCRUN_LOG="$TMPDIR/xcrun.log" \
PATH="$TMPDIR/bin:$PATH" \
  "$ROOT/scripts/notarize-macos-release.sh" --dist "$DIST" --keychain-profile "zmr-notary" > "$TMPDIR/notarize.out"

grep -q 'notarized macOS archives: 2' "$TMPDIR/notarize.out"
grep -q 'notarytool submit' "$TMPDIR/xcrun.log"
grep -q -- '--keychain-profile zmr-notary' "$TMPDIR/xcrun.log"
grep -q -- '--wait' "$TMPDIR/xcrun.log"
grep -q -- '--output-format json' "$TMPDIR/xcrun.log"
grep -q 'aarch64-macos.15.0' "$TMPDIR/xcrun.log"
grep -q 'x86_64-macos.15.0' "$TMPDIR/xcrun.log"
if grep -q 'linux-gnu' "$TMPDIR/xcrun.log"; then
  echo "linux archive should not be submitted for notarization" >&2
  exit 1
fi

test -s "$DIST/notarization/zmr-0.1.6-aarch64-macos.15.0.notary.json"
grep -q '"status":"Accepted"' "$DIST/notarization/zmr-0.1.6-aarch64-macos.15.0.notary.json"
node - "$DIST/RELEASE_MANIFEST.json" <<'NODE'
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const paths = new Set(manifest.artifacts.map((artifact) => artifact.path));
if (!paths.has("notarization/zmr-0.1.6-aarch64-macos.15.0.notary.json")) {
  throw new Error("release manifest should include notarization receipt");
}
NODE
"$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" > "$TMPDIR/verify.out"
grep -q 'verified release artifacts' "$TMPDIR/verify.out"
grep -q 'notarization/zmr-0.1.6-aarch64-macos.15.0.notary.json' "$DIST/SHA256SUMS"

rm -f "$TMPDIR/xcrun.log" "$TMPDIR/ditto.log"
ZMR_FAKE_DITTO_LOG="$TMPDIR/ditto.log" \
ZMR_FAKE_XCRUN_LOG="$TMPDIR/xcrun.log" \
PATH="$TMPDIR/bin:$PATH" \
  "$ROOT/scripts/notarize-macos-release.sh" --dist "$DIST" --keychain-profile "zmr-notary" --dry-run > "$TMPDIR/dry-run.out"
grep -q 'would notarize macOS archives: 2' "$TMPDIR/dry-run.out"
if [[ -e "$TMPDIR/xcrun.log" || -e "$TMPDIR/ditto.log" ]]; then
  echo "dry run should not invoke xcrun or ditto" >&2
  exit 1
fi

if "$ROOT/scripts/notarize-macos-release.sh" --dist "$DIST" > "$TMPDIR/missing-credentials.out" 2>&1; then
  echo "expected notarization helper to require credentials" >&2
  exit 1
fi
grep -q 'notarization credentials are required' "$TMPDIR/missing-credentials.out"

for args in "--dist" "--keychain-profile" "--apple-id" "--team-id" "--password"; do
  set +e
  missing_value_output="$("$ROOT/scripts/notarize-macos-release.sh" $args --dry-run 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "macOS notarization helper should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done
