#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_missing_value() {
  local flag="$1"
  set +e
  output="$("$INSTALL" "$flag" --dry-run 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne 2 ]]; then
    echo "install.sh should exit 2 for missing value: $flag" >&2
    exit 1
  fi
  grep -q -- "$flag requires a value" <<< "$output"
}

assert_missing_value --version
assert_missing_value --install-dir
assert_missing_value --base-url

dry_run="$(
  ZMR_INSTALL_UNAME_S=Darwin \
  ZMR_INSTALL_UNAME_M=arm64 \
  "$INSTALL" \
    --version 0.2.8 \
    --base-url https://example.test/zmr/v0.2.8 \
    --install-dir "$TMPDIR/bin" \
    --dry-run
)"
grep -q 'version: 0.2.8' <<< "$dry_run"
grep -q 'target: aarch64-macos.15.0' <<< "$dry_run"
grep -q 'install-dir: '"$TMPDIR"'/bin' <<< "$dry_run"
grep -q 'archive: https://example.test/zmr/v0.2.8/zmr-0.2.8-aarch64-macos.15.0.tar.gz' <<< "$dry_run"
grep -q 'checksums: https://example.test/zmr/v0.2.8/SHA256SUMS' <<< "$dry_run"
grep -q 'checksum-verification: required' <<< "$dry_run"
grep -q 'zmr init --app --app-id <bundle-id>' <<< "$dry_run"
# Human-facing next-steps, so no --json: a first-time reader wants doctor's
# readable table and its trailing `next` line, not a JSON blob. The --json form
# is still correct for the generated package.json scripts and config.scripts,
# which npm-cli/npm-scaffold-helpers assert separately.
grep -q 'zmr doctor --strict --config .zmr/config.json' <<< "$dry_run"

linux_dry_run="$(
  ZMR_INSTALL_UNAME_S=Linux \
  ZMR_INSTALL_UNAME_M=x86_64 \
  "$INSTALL" \
    --version v0.2.8 \
    --base-url https://example.test/zmr/v0.2.8 \
    --dry-run
)"
grep -q 'version: 0.2.8' <<< "$linux_dry_run"
grep -q 'target: x86_64-linux-gnu' <<< "$linux_dry_run"

latest_dry_run="$(
  ZMR_INSTALL_LATEST_VERSION=0.2.9 \
  ZMR_INSTALL_UNAME_S=Linux \
  ZMR_INSTALL_UNAME_M=aarch64 \
  "$INSTALL" \
    --base-url https://example.test/zmr/v0.2.9 \
    --dry-run
)"
grep -q 'version: 0.2.9' <<< "$latest_dry_run"
grep -q 'target: aarch64-linux-gnu' <<< "$latest_dry_run"

if ZMR_INSTALL_UNAME_S=Plan9 ZMR_INSTALL_UNAME_M=x86 "$INSTALL" --version 0.2.8 --dry-run > "$TMPDIR/unsupported.out" 2>&1; then
  echo "install.sh should reject unsupported platforms" >&2
  exit 1
fi
grep -q 'unsupported platform: Plan9-x86' "$TMPDIR/unsupported.out"

DIST="$TMPDIR/dist"
mkdir -p "$DIST/zmr-0.2.8-x86_64-linux-gnu"
cat > "$DIST/zmr-0.2.8-x86_64-linux-gnu/zmr" <<'ZMR'
#!/usr/bin/env sh
echo "zmr test binary"
ZMR
chmod +x "$DIST/zmr-0.2.8-x86_64-linux-gnu/zmr"
tar -C "$DIST" -czf "$DIST/zmr-0.2.8-x86_64-linux-gnu.tar.gz" "zmr-0.2.8-x86_64-linux-gnu"

printf 'not-a-real-checksum  other-file.tar.gz\n' > "$DIST/SHA256SUMS"
if ZMR_INSTALL_UNAME_S=Linux ZMR_INSTALL_UNAME_M=x86_64 "$INSTALL" \
  --version 0.2.8 \
  --base-url "file://$DIST" \
  --install-dir "$TMPDIR/missing-checksum-bin" \
  > "$TMPDIR/missing-checksum.out" 2>&1; then
  echo "install.sh should fail when SHA256SUMS lacks the archive entry" >&2
  exit 1
fi
grep -q 'missing checksum entry for zmr-0.2.8-x86_64-linux-gnu.tar.gz' "$TMPDIR/missing-checksum.out"

(
  cd "$DIST"
  shasum -a 256 zmr-0.2.8-x86_64-linux-gnu.tar.gz > SHA256SUMS
)
ZMR_INSTALL_UNAME_S=Linux ZMR_INSTALL_UNAME_M=x86_64 "$INSTALL" \
  --version 0.2.8 \
  --base-url "file://$DIST" \
  --install-dir "$TMPDIR/bin" \
  > "$TMPDIR/install.out"

test -x "$TMPDIR/bin/zmr"
"$TMPDIR/bin/zmr" > "$TMPDIR/zmr.out"
grep -q 'zmr test binary' "$TMPDIR/zmr.out"
grep -q 'installed zmr to '"$TMPDIR"'/bin/zmr' "$TMPDIR/install.out"
grep -q 'zmr init --app --app-id <bundle-id>' "$TMPDIR/install.out"
