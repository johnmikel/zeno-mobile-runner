#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--out" "--app-id" "--device" "--avd" "--runs" "--trace-root" "--api" "--build-tools" "--android-sdk" "--adb" "--emulator"; do
  set +e
  missing_value_output="$("$ROOT/scripts/demo-android-real.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "demo-android-real should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

output="$("$ROOT/scripts/demo-android-real.sh" \
  --dry-run \
  --out "$TMPDIR/demo-android" \
  --device emulator-5554 \
  --avd Pixel_API_35 \
  --app-id com.example.mobiletest \
  --runs 3 \
  --trace-root "$TMPDIR/traces" 2>&1)"

python3 - "$output" "$TMPDIR" <<'PY'
import sys

output = sys.argv[1]
tmp = sys.argv[2]

assert "DRY RUN" in output
assert "Android real demo app:" in output
assert f"{tmp}/demo-android" in output
assert "create-android-demo-app.sh --out" in output
assert "--app-id com.example.mobiletest" in output
assert "adb -s emulator-5554 get-state" in output
assert "auto boot Android emulator Pixel_API_35 when emulator-5554 is not ready" in output
assert "android-emulator.sh boot --avd Pixel_API_35 --device emulator-5554" in output
assert "android-emulator.sh wait-ready --device emulator-5554" in output
assert "adb -s emulator-5554 uninstall com.example.mobiletest" in output
assert "adb -s emulator-5554 install -r" in output
assert "build/app-debug.apk" in output
assert "scripts/run-android-pilot.sh" in output
assert "--scenario" in output
assert ".zmr/android-smoke.json" in output
assert "--device emulator-5554" in output
assert "--app-id com.example.mobiletest" in output
assert "--runs 3" in output
assert f"--trace-root {tmp}/traces" in output
assert "Android real demo complete." in output
PY

if "$ROOT/scripts/demo-android-real.sh" --dry-run --out "$TMPDIR/missing-avd" --device emulator-5554 --no-auto-boot-emulator >/tmp/zmr-android-demo-no-auto.out 2>&1; then
  echo "expected no-auto dry run to fail without a ready device" >&2
  exit 1
fi
grep -q 'device emulator-5554 is not ready and auto boot is disabled' /tmp/zmr-android-demo-no-auto.out

FAKE_CREATE="$TMPDIR/fake-create-android-demo.sh"
cat > "$FAKE_CREATE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out/build" "$out/.zmr"
printf 'apk\n' > "$out/build/app-debug.apk"
printf '{}\n' > "$out/.zmr/android-smoke.json"
SH
chmod +x "$FAKE_CREATE"

FAKE_ADB="$TMPDIR/fake-adb-evidence.sh"
cat > "$FAKE_ADB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == devices ]]; then
  printf 'List of devices attached\nemulator-5554\tdevice\n'
  exit 0
fi
if [[ "${1:-}" == -s && "${3:-}" == get-state ]]; then
  printf 'device\n'
  exit 0
fi
if [[ "${1:-}" == -s && "${3:-}" == shell && "${4:-}" == getprop ]]; then
  printf '1\n'
fi
exit 0
SH
chmod +x "$FAKE_ADB"

PUBLICATION="$TMPDIR/evidence-android-demo"
ATTEMPT="$PUBLICATION/attempts/android-demo-run"
INDEX="$PUBLICATION/attempt-index.json"
mkdir -p "$PUBLICATION/attempts"
python3 "$ROOT/scripts/run_evidence.py" init \
  --root "$ATTEMPT" \
  --index "$INDEX" \
  --context-json '{"runId":"android-demo-run","executionId":"android-demo-logical","fixtureId":"android-demo","fixtureVersion":"1","candidateRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","scenarioDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","appBuildDigest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","platform":"android","deviceClass":"android-emulator","runtimeVersion":"35","timingMode":"cold-command","runnerVersion":"1.0.0","protocolVersion":"2026-04-28","attempt":1,"host":{"os":"macos","arch":"arm64","class":"local-test","ci":false},"device":{"requested":"emulator-5554","resolved":"emulator-5554"},"toolchain":{"xcode":null,"zig":"0.16.0"},"artifacts":{"trace":null,"report":null}}' >/dev/null

CREATE_ANDROID_DEMO_APP="$FAKE_CREATE" \
ZMR_BIN="$ROOT/tests/fixtures/fake-zmr-evidence-success.sh" \
ZMR_RUN_EVIDENCE_ROOT="$ATTEMPT" \
ZMR_RUN_EVIDENCE_INDEX="$INDEX" \
  "$ROOT/scripts/demo-android-real.sh" \
  --out "$TMPDIR/evidence-android-app" \
  --device emulator-5554 \
  --adb "$FAKE_ADB" \
  --no-auto-boot-emulator \
  --trace-root "$ATTEMPT/traces/android-demo" >/dev/null

python3 "$ROOT/scripts/run_evidence.py" validate-bundle --root "$ATTEMPT" >/dev/null
python3 - "$ATTEMPT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in (root / "bootstrap-events.jsonl").read_text().splitlines()]
phases = [event["phase"] for event in events]
expected = ["app.build", "device.preflight", "device.acquire", "device.boot", "app.install", "scenario.execute"]
position = -1
for phase in expected:
    position = phases.index(phase, position + 1)
summary = json.loads((root / "run-summary.json").read_text())
assert summary["status"] == "passed"
assert summary["artifacts"]["trace"] == "traces/android-demo/scenario"
assert summary["artifacts"]["report"] == "traces/android-demo/scenario/report.html"
assert len(list((root / "run-outcomes").glob("*.json"))) == 1
PY
