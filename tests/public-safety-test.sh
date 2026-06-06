#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

deny_terms=(
  "bri""ck"
  "(^|[^[:alpha:]])ren""tly([^[:alpha:]]|$)"
  "uk[.]co[.]ren""tly"
  "ren""tlytest"
  "cod""ex"
  "app""ium"
  "mae""stro"
  "det""ox"
  "browser""stack"
  "sauce""labs"
  "sauce"" labs"
  "firebase"" test ""lab"
  "kobi""ton"
  "perfect""o"
  "testri""gor"
  "kata""lon"
  "lambda""test"
)

while IFS= read -r -d '' path; do
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  for term in "${deny_terms[@]}"; do
    if [[ "$lower" =~ $term ]]; then
      echo "denied private term in path: $path" >&2
      exit 1
    fi
  done

  for term in "${deny_terms[@]}"; do
    if LC_ALL=C grep -nI -i -E "$term" "$path" >/dev/null 2>&1; then
      echo "denied private term in file contents: $path" >&2
      exit 1
    fi
  done
done < <(git ls-files -z)

if grep -nE 'Local scratch artifacts|_cod\[e\]x_write_test|python_redirect_test|^Gate$|^iOS$' .gitignore; then
  echo "public .gitignore should not contain local scratch or permission-probe entries" >&2
  exit 1
fi
