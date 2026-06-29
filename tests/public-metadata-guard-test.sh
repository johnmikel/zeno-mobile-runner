#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/public-metadata-guard.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

"$GUARD" --repo "$ROOT" > "$TMPDIR/current.out"
grep -q 'public metadata verified' "$TMPDIR/current.out"

repo="$TMPDIR/repo"
git init -q "$repo"
git -C "$repo" config user.name "Test User"
git -C "$repo" config user.email "test@example.com"
printf '# Clean\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m "Initial clean commit"
git -C "$repo" tag v0.1.0
"$GUARD" --repo "$repo" > "$TMPDIR/clean.out"
grep -q 'public metadata verified' "$TMPDIR/clean.out"

printf '# Agent-specific public doc\n' > "$repo/README.md"
printf 'claude mcp add zmr\n' >> "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m "Add agent-specific docs"
if "$GUARD" --repo "$repo" > "$TMPDIR/doc-bad.out" 2>&1; then
  echo "expected public metadata guard to reject agent-specific public docs" >&2
  exit 1
fi
grep -q 'denied public metadata string in file contents: README.md' "$TMPDIR/doc-bad.out"

git -C "$repo" checkout -q HEAD~1
git -C "$repo" branch -f main HEAD
git -C "$repo" checkout -q main
git -C "$repo" tag -f v0.1.0 >/dev/null
git -C "$repo" commit --allow-empty -q -m $'Bad trailer\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
if "$GUARD" --repo "$repo" > "$TMPDIR/commit-bad.out" 2>&1; then
  echo "expected public metadata guard to reject public branch commit metadata" >&2
  exit 1
fi
grep -q 'denied public metadata string in commit metadata: refs/heads/main' "$TMPDIR/commit-bad.out"

git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" tag -f v0.1.1 -m $'Bad tag\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
if "$GUARD" --repo "$repo" > "$TMPDIR/tag-bad.out" 2>&1; then
  echo "expected public metadata guard to reject tag metadata" >&2
  exit 1
fi
grep -q 'denied public metadata string in tag metadata: refs/tags/v0.1.1' "$TMPDIR/tag-bad.out"

git -C "$repo" tag -d v0.1.1 >/dev/null
git -C "$repo" update-ref refs/backup/bad HEAD
"$GUARD" --repo "$repo" > "$TMPDIR/backup-ignored.out"
grep -q 'public metadata verified' "$TMPDIR/backup-ignored.out"
