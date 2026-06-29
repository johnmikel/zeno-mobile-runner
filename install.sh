#!/bin/sh
set -eu

REPO="johnmikel/zeno-mobile-runner"
VERSION="${ZMR_INSTALL_VERSION:-}"
INSTALL_DIR="${ZMR_INSTALL_DIR:-$HOME/.local/bin}"
BASE_URL="${ZMR_INSTALL_BASE_URL:-}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  install.sh [--version <version>] [--install-dir <dir>] [--base-url <url>] [--dry-run]

Installs the zmr native binary from a GitHub release archive.

Options:
  --version <version>     Release version, with or without a leading v.
                          Defaults to the latest GitHub release.
  --install-dir <dir>     Directory where zmr is installed. Defaults to ~/.local/bin.
  --base-url <url>        Release asset base URL. Defaults to the GitHub release URL
                          for the selected version.
  --dry-run               Print the resolved install plan without downloading.
  -h, --help              Show this help.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 2
}

strip_v() {
  value="$1"
  printf '%s\n' "${value#v}"
}

require_next_value() {
  flag="$1"
  value="${2-}"
  if [ -z "$value" ] || [ "${value#--}" != "$value" ]; then
    die "$flag requires a value"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      require_next_value "$1" "${2-}"
      VERSION="$(strip_v "$2")"
      shift 2
      ;;
    --install-dir)
      require_next_value "$1" "${2-}"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --base-url)
      require_next_value "$1" "${2-}"
      BASE_URL="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

host_os="${ZMR_INSTALL_UNAME_S:-$(uname -s)}"
host_arch="${ZMR_INSTALL_UNAME_M:-$(uname -m)}"
case "$host_os-$host_arch" in
  Darwin-arm64)
    TARGET="aarch64-macos.15.0"
    ;;
  Darwin-x86_64)
    TARGET="x86_64-macos.15.0"
    ;;
  Linux-aarch64|Linux-arm64)
    TARGET="aarch64-linux-gnu"
    ;;
  Linux-x86_64)
    TARGET="x86_64-linux-gnu"
    ;;
  *)
    die "unsupported platform: $host_os-$host_arch"
    ;;
esac

fetch_latest_version() {
  if [ -n "${ZMR_INSTALL_LATEST_VERSION:-}" ]; then
    strip_v "$ZMR_INSTALL_LATEST_VERSION"
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    die "curl is required to resolve the latest ZMR release"
  fi
  latest_json="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")"
  latest_version="$(printf '%s\n' "$latest_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$latest_version" ]; then
    die "could not resolve latest ZMR release version"
  fi
  printf '%s\n' "$latest_version"
}

if [ -z "$VERSION" ]; then
  VERSION="$(fetch_latest_version)"
fi

if [ -z "$BASE_URL" ]; then
  BASE_URL="https://github.com/$REPO/releases/download/v$VERSION"
fi
BASE_URL="${BASE_URL%/}"

ARCHIVE_NAME="zmr-$VERSION-$TARGET.tar.gz"
ARCHIVE_URL="$BASE_URL/$ARCHIVE_NAME"
CHECKSUMS_URL="$BASE_URL/SHA256SUMS"

print_next_steps() {
  cat <<'NEXT'
Next steps:
  zmr init --app --app-id <bundle-id>
  zmr doctor --strict --json --config .zmr/config.json
NEXT
}

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
zmr install plan
version: $VERSION
target: $TARGET
install-dir: $INSTALL_DIR
archive: $ARCHIVE_URL
checksums: $CHECKSUMS_URL
checksum-verification: required
EOF
  print_next_steps
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  die "curl is required"
fi
if ! command -v tar >/dev/null 2>&1; then
  die "tar is required"
fi
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  die "shasum or sha256sum is required"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmr-install.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

archive_path="$work_dir/$ARCHIVE_NAME"
checksums_path="$work_dir/SHA256SUMS"

curl -fsSL -o "$checksums_path" "$CHECKSUMS_URL"
curl -fsSL -o "$archive_path" "$ARCHIVE_URL"

if ! checksum_line="$(awk -v name="$ARCHIVE_NAME" '
  $2 == name || $2 == "./" name { print; found = 1; exit }
  END { if (!found) exit 1 }
' "$checksums_path")"; then
  die "missing checksum entry for $ARCHIVE_NAME"
fi

if command -v shasum >/dev/null 2>&1; then
  (cd "$work_dir" && printf '%s\n' "$checksum_line" | shasum -a 256 -c - >/dev/null)
else
  (cd "$work_dir" && printf '%s\n' "$checksum_line" | sha256sum -c - >/dev/null)
fi

tar -xzf "$archive_path" -C "$work_dir"
binary_path="$work_dir/zmr-$VERSION-$TARGET/zmr"
if [ ! -f "$binary_path" ]; then
  die "release archive did not contain zmr binary at zmr-$VERSION-$TARGET/zmr"
fi

mkdir -p "$INSTALL_DIR"
cp "$binary_path" "$INSTALL_DIR/zmr"
chmod +x "$INSTALL_DIR/zmr"

printf 'installed zmr to %s\n' "$INSTALL_DIR/zmr"
print_next_steps
