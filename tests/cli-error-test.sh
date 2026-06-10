#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ZMR="$ROOT/zig-out/bin/zmr"
test -x "$ZMR"

FAILING_ADB="$TMPDIR/failing-adb.sh"
cat > "$FAILING_ADB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "devices" ]]; then
  echo "adb daemon unavailable" >&2
  exit 7
fi
exit 2
SH
chmod +x "$FAILING_ADB"

set +e
"$ZMR" devices --json --adb "$FAILING_ADB" > "$TMPDIR/stdout.txt" 2> "$TMPDIR/stderr.txt"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected devices command to fail for failing adb" >&2
  exit 1
fi

grep -q 'error\[device.command_failed\]: device command failed' "$TMPDIR/stderr.txt"
if grep -Eq 'src/|ensureSuccess|error return trace|\.zig:' "$TMPDIR/stderr.txt"; then
  echo "CLI stderr should not expose Zig stack traces" >&2
  cat "$TMPDIR/stderr.txt" >&2
  exit 1
fi

set +e
"$ZMR" --definitely-missing-command > "$TMPDIR/unknown-stdout.txt" 2> "$TMPDIR/unknown-stderr.txt"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected unknown command to fail" >&2
  exit 1
fi

grep -q 'error\[cli.unknown_command\]: unknown command' "$TMPDIR/unknown-stderr.txt"
if grep -Eq 'src/|error return trace|\.zig:' "$TMPDIR/unknown-stderr.txt"; then
  echo "unknown command stderr should not expose Zig stack traces" >&2
  cat "$TMPDIR/unknown-stderr.txt" >&2
  exit 1
fi

# A consumer closing the pipe early (`zmr schemas --json | head -c 200`) must
# not surface internal.error. The read end is closed before zmr starts so the
# EPIPE is deterministic regardless of output size vs the pipe buffer.
set +e
python3 - "$ZMR" > "$TMPDIR/epipe-stderr.txt" <<'PY'
import os, subprocess, sys

read_fd, write_fd = os.pipe()
os.close(read_fd)
os.set_inheritable(write_fd, True)
proc = subprocess.run(
    [sys.argv[1], "schemas", "--json"],
    stdout=write_fd,
    stderr=subprocess.PIPE,
    close_fds=False,
)
os.close(write_fd)
sys.stdout.write(proc.stderr.decode())
sys.exit(proc.returncode)
PY
STATUS=$?
set -e

if [[ "$STATUS" -ne 141 ]]; then
  echo "expected exit status 141 on closed stdout pipe, got $STATUS" >&2
  cat "$TMPDIR/epipe-stderr.txt" >&2
  exit 1
fi

if [[ -s "$TMPDIR/epipe-stderr.txt" ]]; then
  echo "closed stdout pipe should exit quietly, but stderr was:" >&2
  cat "$TMPDIR/epipe-stderr.txt" >&2
  exit 1
fi
