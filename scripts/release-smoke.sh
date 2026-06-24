#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -eq 0 ]]; then
  set -- dist/*.tar.gz
fi

host_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) printf 'aarch64-macos.15.0' ;;
    Darwin:x86_64) printf 'x86_64-macos.15.0' ;;
    Linux:x86_64) printf 'x86_64-linux-gnu' ;;
    Linux:aarch64|Linux:arm64) printf 'aarch64-linux-gnu' ;;
    *)
      printf 'unsupported'
      ;;
  esac
}

target="$(host_target)"
if [[ "$target" == "unsupported" ]]; then
  echo "unsupported smoke-test host: $(uname -s) $(uname -m)" >&2
  exit 1
fi

matched=0
for archive in "$@"; do
  if [[ ! -f "$archive" ]]; then
    echo "missing release archive: $archive" >&2
    exit 1
  fi

  if [[ "$archive" != *"$target.tar.gz" ]]; then
    echo "skip $(basename "$archive") on $target"
    continue
  fi

  matched=1
  archive_name="$(basename "$archive")"
  expected_version="${archive_name#zmr-}"
  expected_version="${expected_version%-$target.tar.gz}"
  if [[ "$expected_version" == "$archive_name" || -z "$expected_version" ]]; then
    echo "could not infer release version from archive name: $archive_name" >&2
    exit 1
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  tar -xzf "$archive" -C "$tmp"
  package_dir="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$package_dir" ]]; then
    echo "archive has no top-level package directory: $archive" >&2
    exit 1
  fi

  version_output="$("$package_dir/zmr" version)"
  printf '%s\n' "$version_output"
  reported_version="$(awk '$1 == "zmr" { print $2; exit }' <<< "$version_output")"
  if [[ "$reported_version" != "$expected_version" ]]; then
    echo "release archive version mismatch for $archive_name: expected $expected_version, reported ${reported_version:-<unknown>}" >&2
    exit 1
  fi

  "$package_dir/zmr" validate "$package_dir/examples/demo-fake.json"

  trace_dir="$tmp/minimal-trace"
  mkdir -p "$trace_dir"
  printf '{"schemaVersion":1,"status":"passed","eventsPath":"events.jsonl","artifactsDir":"artifacts"}\n' > "$trace_dir/trace.json"
  printf '{"seq":1,"timestampMs":1,"kind":"smoke","payload":{"email":"agent@example.com"}}\n' > "$trace_dir/events.jsonl"
  "$package_dir/zmr" export "$trace_dir" --out "$tmp/minimal-redacted.zmrtrace" --redact

  if ! [[ -s "$tmp/minimal-redacted.zmrtrace" ]]; then
    echo "redacted smoke bundle was not created" >&2
    exit 1
  fi

  rm -rf "$tmp"
  trap - EXIT
done

if [[ "$matched" -eq 0 ]]; then
  echo "no release archive matched host target $target" >&2
  exit 1
fi
