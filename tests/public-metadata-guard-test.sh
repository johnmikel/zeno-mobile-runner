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

# A trailer on a local branch that is neither checked out nor on origin passes
# the default scan (that is the pre-push hole) but must fail via --scan-ref.
git -C "$repo" branch sidework
git -C "$repo" checkout -q sidework
git -C "$repo" commit --allow-empty -q -m $'Bad side trailer\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
side_bad_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q main
"$GUARD" --repo "$repo" > "$TMPDIR/side-default.out"
grep -q 'public metadata verified' "$TMPDIR/side-default.out"
if "$GUARD" --repo "$repo" --scan-ref refs/heads/sidework > "$TMPDIR/side-ref.out" 2>&1; then
  echo "expected --scan-ref to reject a local branch carrying a trailer" >&2
  exit 1
fi
grep -q 'denied public metadata string in commit metadata: refs/heads/sidework' "$TMPDIR/side-ref.out"
if "$GUARD" --repo "$repo" --scan-ref "$side_bad_sha" > "$TMPDIR/side-sha.out" 2>&1; then
  echo "expected --scan-ref to reject a raw sha carrying a trailer" >&2
  exit 1
fi
grep -q "denied public metadata string in commit metadata: $side_bad_sha" "$TMPDIR/side-sha.out"

# --scan-ref must also read annotated tag objects, which git log peels away.
# Delete the tag ref first so only the sha-based scan can see the tag object
# (a ref'd tag is already covered by the default refs/tags scan).
git -C "$repo" tag -a side-tag -m $'Bad tag\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>' main
side_tag_sha="$(git -C "$repo" rev-parse side-tag)"
git -C "$repo" tag -d side-tag >/dev/null
if "$GUARD" --repo "$repo" --scan-ref "$side_tag_sha" > "$TMPDIR/side-tag.out" 2>&1; then
  echo "expected --scan-ref to reject an annotated tag carrying a trailer" >&2
  exit 1
fi
grep -q "denied public metadata string in tag metadata: $side_tag_sha" "$TMPDIR/side-tag.out"

# The pre-push hook must scan the refs actually being pushed (stdin), not just
# the checked-out branch, and must refuse assistant-fingerprint ref names.
hook_repo="$TMPDIR/hookrepo"
git init -q "$hook_repo"
git -C "$hook_repo" config user.name "Test User"
git -C "$hook_repo" config user.email "test@example.com"
mkdir -p "$hook_repo/scripts/hooks"
cp "$ROOT/scripts/public-metadata-guard.sh" "$hook_repo/scripts/"
cp "$ROOT/scripts/hooks/pre-push" "$hook_repo/scripts/hooks/"
printf '# Clean\n' > "$hook_repo/README.md"
git -C "$hook_repo" add README.md
git -C "$hook_repo" commit -q -m "Initial clean commit"
good_sha="$(git -C "$hook_repo" rev-parse HEAD)"
git -C "$hook_repo" checkout -q -b side
git -C "$hook_repo" commit --allow-empty -q -m $'Bad trailer\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
bad_sha="$(git -C "$hook_repo" rev-parse HEAD)"
git -C "$hook_repo" checkout -q -B main "$good_sha"
zeros=0000000000000000000000000000000000000000

run_hook() {
  (cd "$hook_repo" && scripts/hooks/pre-push origin https://example.invalid/repo.git)
}

# Pushing a clean sha passes.
printf '%s %s %s %s\n' refs/heads/main "$good_sha" refs/heads/main "$zeros" | run_hook > "$TMPDIR/hook-clean.out" 2>&1

# Pushing a non-checked-out branch whose history carries a trailer is blocked.
if printf '%s %s %s %s\n' refs/heads/side "$bad_sha" refs/heads/side "$zeros" | run_hook > "$TMPDIR/hook-bad.out" 2>&1; then
  echo "expected pre-push hook to block a pushed sha carrying a trailer" >&2
  exit 1
fi
grep -q 'denied public metadata string in commit metadata' "$TMPDIR/hook-bad.out"

# Pushing to an assistant-fingerprint ref name is blocked...
if printf '%s %s %s %s\n' refs/heads/main "$good_sha" "refs/heads/clau""de/tidy" "$zeros" | run_hook > "$TMPDIR/hook-name.out" 2>&1; then
  echo "expected pre-push hook to block an assistant-fingerprint ref name" >&2
  exit 1
fi
grep -q 'assistant-fingerprint ref name' "$TMPDIR/hook-name.out"

# ...but deleting one is allowed (that is how the name gets cleaned up).
printf '%s %s %s %s\n' '(delete)' "$zeros" "refs/heads/clau""de/tidy" "$good_sha" | run_hook > "$TMPDIR/hook-delete.out" 2>&1
