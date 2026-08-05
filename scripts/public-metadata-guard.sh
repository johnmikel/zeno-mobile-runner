#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  scripts/public-metadata-guard.sh [--repo <path>] [--scan-ref <ref-or-sha>]...

Rejects unwanted public contributor/client strings in public docs, public branch
commit metadata, and tag metadata. Local backup refs are intentionally ignored.
--scan-ref adds a ref or sha to the metadata scan; the pre-push hook uses it to
scan exactly the objects a push would publish, whatever branch is checked out.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value"
  fi
}

scan_refs=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo)
      require_value "$1" "${2-}"
      ROOT="$2"
      shift 2
      ;;
    --scan-ref)
      require_value "$1" "${2-}"
      scan_refs="${scan_refs}${2}"$'\n'
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

ROOT="$(cd "$ROOT" && pwd)"

bad_claude="Clau""de"
bad_claude_lower="clau""de"
bad_anthropic="anth""ropic"
metadata_deny_regex="(${bad_claude} Fable|noreply@${bad_anthropic}[.]com|Co-Authored-By:[[:space:]]*${bad_claude})"
doc_deny_regex="(${metadata_deny_regex}|${bad_claude} Code|${bad_claude_lower}[[:space:]]+mcp[[:space:]]+add)"

scan_public_files() {
  git -C "$ROOT" ls-files -z -- \
    README.md \
    FEATURES.md \
    CHANGELOG.md \
    SECURITY.md \
    CONTRIBUTING.md \
    docs \
    skills \
    .github
}

while IFS= read -r -d '' path; do
  if LC_ALL=C grep -nI -i -E "$doc_deny_regex" "$ROOT/$path" >/dev/null 2>&1; then
    echo "denied public metadata string in file contents: $path" >&2
    exit 1
  fi
done < <(scan_public_files)

current_ref="$(git -C "$ROOT" symbolic-ref -q HEAD || true)"
{
  if [[ -n "$current_ref" ]]; then
    printf '%s\n' "$current_ref"
  else
    printf '%s\n' HEAD
  fi
  git -C "$ROOT" for-each-ref --format='%(refname)' refs/remotes/origin refs/tags |
    grep -v '^refs/remotes/origin/HEAD$' || true
} | sort -u | while IFS= read -r ref; do
  if [[ -z "$ref" ]]; then
    continue
  fi
  if git -C "$ROOT" log "$ref" --format='%H%n%an <%ae>%n%cn <%ce>%n%B' |
    LC_ALL=C grep -i -E "$metadata_deny_regex" >/dev/null 2>&1; then
    echo "denied public metadata string in commit metadata: $ref" >&2
    exit 1
  fi

  if git -C "$ROOT" for-each-ref "$ref" --format='%(taggername) %(taggeremail)%0a%(contents)' |
    LC_ALL=C grep -i -E "$metadata_deny_regex" >/dev/null 2>&1; then
    echo "denied public metadata string in tag metadata: $ref" >&2
    exit 1
  fi
done

while IFS= read -r rev; do
  if [[ -z "$rev" ]]; then
    continue
  fi
  if ! git -C "$ROOT" rev-parse --verify --quiet "${rev}^{commit}" >/dev/null; then
    die "unknown ref for --scan-ref: $rev"
  fi
  if [[ "$(git -C "$ROOT" cat-file -t "$rev" 2>/dev/null)" == "tag" ]]; then
    if git -C "$ROOT" cat-file tag "$rev" |
      LC_ALL=C grep -i -E "$metadata_deny_regex" >/dev/null 2>&1; then
      echo "denied public metadata string in tag metadata: $rev" >&2
      exit 1
    fi
  fi
  if git -C "$ROOT" log "$rev" --format='%H%n%an <%ae>%n%cn <%ce>%n%B' |
    LC_ALL=C grep -i -E "$metadata_deny_regex" >/dev/null 2>&1; then
    echo "denied public metadata string in commit metadata: $rev" >&2
    exit 1
  fi
done <<< "$scan_refs"

printf 'public metadata verified: %s\n' "$ROOT"
