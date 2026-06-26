#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

private_terms=(
  "bri""ck"
  "(^|[^[:alpha:]])ren""tly([^[:alpha:]]|$)"
  "uk[.]co[.]ren""tly"
  "ren""tlytest"
  "zig""-mobile-runner"
  "zig"" mobile runner"
  "zig""_mobile_runner"
  "cod""ex"
)

comparison_terms=(
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

comparison_term_allowed_path() {
  case "$1" in
    docs/benchmarks/*) return 0 ;;
    README.md) return 0 ;;
    FEATURES.md) return 0 ;;
    docs/protocol.md) return 0 ;;
    docs/scenario-authoring.md) return 0 ;;
    docs/command-reference.md) return 0 ;;
    docs/json-traces-vs-yaml.md) return 0 ;;
    docs/maestro-migration.md) return 0 ;;
    schemas/import-output.schema.json) return 0 ;;
    schemas/README.md) return 0 ;;
    src/cli_import.zig) return 0 ;;
    src/cli_import_tests.zig) return 0 ;;
    src/cli_output.zig) return 0 ;;
    src/cli_output_tests.zig) return 0 ;;
    src/main.zig) return 0 ;;
    tests/import-flow-yaml-test.sh) return 0 ;;
    tests/public-safety-test.sh) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' path; do
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  for term in "${private_terms[@]}"; do
    if [[ "$lower" =~ $term ]]; then
      echo "denied private term in path: $path" >&2
      exit 1
    fi
  done

  for term in "${comparison_terms[@]}"; do
    if [[ "$lower" =~ $term ]] && ! comparison_term_allowed_path "$path"; then
      echo "denied comparison term outside benchmark evidence path: $path" >&2
      exit 1
    fi
  done

  for term in "${private_terms[@]}"; do
    if LC_ALL=C grep -nI -i -E "$term" "$path" >/dev/null 2>&1; then
      echo "denied private term in file contents: $path" >&2
      exit 1
    fi
  done

  for term in "${comparison_terms[@]}"; do
    if LC_ALL=C grep -nI -i -E "$term" "$path" >/dev/null 2>&1; then
      if ! comparison_term_allowed_path "$path"; then
        echo "denied comparison term outside benchmark evidence contents: $path" >&2
        exit 1
      fi
    fi
  done
done < <(git ls-files -z)

if grep -nE 'Local scratch artifacts|_cod\[e\]x_write_test|python_redirect_test|^Gate$|^iOS$' .gitignore; then
  echo "public .gitignore should not contain local scratch or permission-probe entries" >&2
  exit 1
fi
