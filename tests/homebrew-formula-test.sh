#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/SHA256SUMS" <<'EOF'
1111111111111111111111111111111111111111111111111111111111111111  zmr-0.1.2-aarch64-macos.15.0.tar.gz
2222222222222222222222222222222222222222222222222222222222222222  zmr-0.1.2-x86_64-macos.15.0.tar.gz
3333333333333333333333333333333333333333333333333333333333333333  zmr-0.1.2-aarch64-linux-gnu.tar.gz
4444444444444444444444444444444444444444444444444444444444444444  zmr-0.1.2-x86_64-linux-gnu.tar.gz
EOF

node scripts/generate-homebrew-formula.mjs \
  --version 0.1.2 \
  --checksums "$tmp/SHA256SUMS" \
  --base-url https://github.com/example/zeno-mobile-runner/releases/download/v0.1.2 \
  --out "$tmp/zmr.rb"

test -s "$tmp/zmr.rb"
grep -F -q 'class Zmr < Formula' "$tmp/zmr.rb"
grep -F -q 'desc "Agent-native mobile app test runner for React Native, Expo, Flutter, Android, and iOS"' "$tmp/zmr.rb"
grep -F -q 'url "https://github.com/example/zeno-mobile-runner/releases/download/v0.1.2/zmr-0.1.2-aarch64-macos.15.0.tar.gz"' "$tmp/zmr.rb"
grep -F -q 'sha256 "1111111111111111111111111111111111111111111111111111111111111111"' "$tmp/zmr.rb"
grep -F -q 'url "https://github.com/example/zeno-mobile-runner/releases/download/v0.1.2/zmr-0.1.2-x86_64-linux-gnu.tar.gz"' "$tmp/zmr.rb"
grep -F -q 'sha256 "4444444444444444444444444444444444444444444444444444444444444444"' "$tmp/zmr.rb"
grep -F -q 'bin.install "zmr"' "$tmp/zmr.rb"
grep -F -q 'system "#{bin}/zmr", "version"' "$tmp/zmr.rb"
