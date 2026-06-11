#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DIST="$TMPDIR/dist"
mkdir -p "$DIST/homebrew" "$TMPDIR/bin"

cat > "$TMPDIR/bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ZMR_FAKE_CODESIGN_LOG"
if [[ "$*" == *"--verify"* ]]; then
  exit 0
fi
target="${@: -1}"
printf '\nsigned-by-fake-codesign\n' >> "$target"
SH
chmod +x "$TMPDIR/bin/codesign"

make_archive() {
  local target="$1"
  local dir="$DIST/zmr-0.2.1-$target"
  mkdir -p "$dir"
  printf 'binary for %s\n' "$target" > "$dir/zmr"
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

(
  cd "$DIST"
  shasum -a 256 ./*.tar.gz SBOM.spdx.json THIRD_PARTY_NOTICES.md homebrew/zmr.rb > SHA256SUMS
)

ZMR_FAKE_CODESIGN_LOG="$TMPDIR/codesign.log" \
PATH="$TMPDIR/bin:$PATH" \
  "$ROOT/scripts/sign-macos-release.sh" --dist "$DIST" --identity "Developer ID Application: Example" > "$TMPDIR/sign.out"

grep -q 'signed macOS archives: 2' "$TMPDIR/sign.out"
grep -q -- '--options runtime' "$TMPDIR/codesign.log"
grep -q 'Developer ID Application: Example' "$TMPDIR/codesign.log"
grep -q 'aarch64-macos.15.0' "$TMPDIR/codesign.log"
grep -q 'x86_64-macos.15.0' "$TMPDIR/codesign.log"
if grep -q 'x86_64-linux-gnu' "$TMPDIR/codesign.log"; then
  echo "linux archive should not be signed by macOS signing helper" >&2
  exit 1
fi

mkdir -p "$TMPDIR/extract"
tar -C "$TMPDIR/extract" -xzf "$DIST/zmr-0.2.1-aarch64-macos.15.0.tar.gz"
grep -q 'signed-by-fake-codesign' "$TMPDIR/extract/zmr-0.2.1-aarch64-macos.15.0/zmr"

"$ROOT/scripts/verify-release-artifacts.sh" --dist "$DIST" > "$TMPDIR/verify.out"
grep -q 'verified release artifacts' "$TMPDIR/verify.out"

rm -f "$TMPDIR/codesign.log"
ZMR_FAKE_CODESIGN_LOG="$TMPDIR/codesign.log" \
PATH="$TMPDIR/bin:$PATH" \
  "$ROOT/scripts/sign-macos-release.sh" --dist "$DIST" --identity "Developer ID Application: Example" --dry-run > "$TMPDIR/dry-run.out"
grep -q 'would sign macOS archives: 2' "$TMPDIR/dry-run.out"
if [[ -e "$TMPDIR/codesign.log" ]]; then
  echo "dry run should not invoke codesign" >&2
  exit 1
fi

if "$ROOT/scripts/sign-macos-release.sh" --dist "$DIST" > "$TMPDIR/missing-identity.out" 2>&1; then
  echo "expected signing helper to require --identity" >&2
  exit 1
fi
grep -q -- '--identity is required' "$TMPDIR/missing-identity.out"

for args in "--dist" "--identity"; do
  set +e
  missing_value_output="$("$ROOT/scripts/sign-macos-release.sh" $args --dry-run 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "macOS signing helper should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done
