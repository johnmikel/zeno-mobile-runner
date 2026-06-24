#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

host_target() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) printf 'aarch64-macos.15.0' ;;
    Darwin:x86_64) printf 'x86_64-macos.15.0' ;;
    Linux:x86_64) printf 'x86_64-linux-gnu' ;;
    Linux:aarch64|Linux:arm64) printf 'aarch64-linux-gnu' ;;
    *) printf 'unsupported' ;;
  esac
}

TARGET="$(host_target)"
if [[ "$TARGET" == "unsupported" ]]; then
  echo "skip release smoke script test on unsupported host: $(uname -s) $(uname -m)"
  exit 0
fi

PACKAGE_DIR="$TMPDIR/zmr-0.2.8-$TARGET"
mkdir -p "$PACKAGE_DIR/examples"
printf '{"schemaVersion":1,"name":"smoke","appId":"com.example","platform":"android","steps":[]}\n' > "$PACKAGE_DIR/examples/demo-fake.json"
cat > "$PACKAGE_DIR/zmr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version)
    printf 'zmr 0.2.7 protocol 2026-04-28\n'
    ;;
  validate)
    exit 0
    ;;
  export)
    out=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--out" ]]; then
        out="$2"
        shift 2
      else
        shift
      fi
    done
    test -n "$out"
    printf 'trace\n' > "$out"
    ;;
  *)
    echo "unexpected zmr command: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$PACKAGE_DIR/zmr"

ARCHIVE="$TMPDIR/zmr-0.2.8-$TARGET.tar.gz"
tar -C "$TMPDIR" -czf "$ARCHIVE" "$(basename "$PACKAGE_DIR")"

set +e
output="$("$ROOT/scripts/release-smoke.sh" "$ARCHIVE" 2>&1)"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "expected release-smoke to fail when binary version does not match archive version" >&2
  exit 1
fi
grep -q "release archive version mismatch" <<< "$output"
grep -q "expected 0.2.8" <<< "$output"
grep -q "reported 0.2.7" <<< "$output"
