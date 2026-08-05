#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for args in "--out" "--name" "--app-id" "--device" "--deployment-target" "--runs" "--trace-root" "--xcrun"; do
  set +e
  missing_value_output="$("$ROOT/scripts/demo-ios-real.sh" $args 2>&1)"
  missing_value_status=$?
  set -e
  if [[ "$missing_value_status" -ne 2 ]]; then
    echo "demo-ios-real should exit 2 for missing value: $args" >&2
    exit 1
  fi
  grep -q -- "$args requires a value" <<< "$missing_value_output"
done

output="$("$ROOT/scripts/demo-ios-real.sh" \
  --dry-run \
  --out "$TMPDIR/demo-ios" \
  --device booted \
  --app-id com.example.mobiletest \
  --runs 3 \
  --trace-root "$TMPDIR/traces" \
  --cleanup-build-products 2>&1)"

python3 - "$output" "$TMPDIR" <<'PY'
import sys

output = sys.argv[1]
tmp = sys.argv[2]

assert "DRY RUN" in output
assert "create-ios-demo-app.sh --out" in output
assert f"{tmp}/demo-ios" in output
assert "xcodebuild -project" in output
assert "ios/ZMRDemo.xcodeproj" in output
assert "-scheme ZMRDemo" in output
assert "-derivedDataPath" in output
assert "xcrun simctl list devices booted" in output
assert "auto boot first available iOS simulator when no simulator is booted" in output
assert "try available iOS simulators until one boots" in output
assert "xcrun simctl bootstatus booted -b" in output
assert "scripts/run-ios-pilot.sh" in output
assert "--app-path" in output
assert "DerivedData/Build/Products/Debug-iphonesimulator/ZMRDemo.app" in output
assert "--device booted" in output
assert "--ios-shim" in output
assert "--runs 3" in output
assert f"--trace-root {tmp}/traces" in output
assert f"rm -rf {tmp}/demo-ios/DerivedData" in output
PY

FAKE_CREATE="$TMPDIR/fake-create-ios-demo.sh"
cat > "$FAKE_CREATE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=
name=ZMRDemo
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=${2:-}; shift 2 ;;
    --name) name=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out/ios/$name.xcodeproj" "$out/.zmr"
cat > "$out/.zmr/ios-shim" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
read -r request
[[ "$request" == '{"cmd":"appState"}' ]]
printf '%s\n' '{"ok":true,"state":"running"}'
INNER
chmod +x "$out/.zmr/ios-shim"
SH
chmod +x "$FAKE_CREATE"

mkdir -p "$TMPDIR/bin"
FAKE_XCODEBUILD="$TMPDIR/bin/xcodebuild"
cat > "$FAKE_XCODEBUILD" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
derived=
scheme=ZMRDemo
while [[ $# -gt 0 ]]; do
  case "$1" in
    -derivedDataPath) derived=${2:-}; shift 2 ;;
    -scheme) scheme=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$derived/Build/Products/Debug-iphonesimulator/$scheme.app"
SH
chmod +x "$FAKE_XCODEBUILD"

FAKE_XCRUN="$TMPDIR/fake-xcrun-evidence.sh"
cat > "$FAKE_XCRUN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'xcrun version 70\n'
  exit 0
fi
if [[ "${1:-}" == simctl && "${2:-}" == list && "${3:-}" == devices && "${4:-}" == booted ]]; then
  printf 'iPhone 16 (fake-ios-1) (Booted)\n'
fi
exit 0
SH
chmod +x "$FAKE_XCRUN"

PUBLICATION="$TMPDIR/evidence-ios-demo"
ATTEMPT="$PUBLICATION/attempts/ios-demo-run"
INDEX="$PUBLICATION/attempt-index.json"
mkdir -p "$PUBLICATION/attempts"
python3 "$ROOT/scripts/run_evidence.py" init \
  --root "$ATTEMPT" \
  --index "$INDEX" \
  --context-json '{"runId":"ios-demo-run","executionId":"ios-demo-logical","fixtureId":"ios-demo","fixtureVersion":"1","candidateRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","scenarioDigest":null,"appBuildDigest":null,"platform":"ios","deviceClass":"ios-simulator","runtimeVersion":"18.5","timingMode":"cold-command","runnerVersion":"1.0.0","protocolVersion":"2026-04-28","attempt":1,"host":{"os":"macos","arch":"arm64","class":"local-test","ci":false},"device":{"requested":"fake-ios-1","resolved":null},"toolchain":{"xcode":"16.4","zig":"0.16.0"},"artifacts":{"trace":null,"report":null}}' >/dev/null

PATH="$TMPDIR/bin:$PATH" \
CREATE_IOS_DEMO_APP="$FAKE_CREATE" \
ZMR_BIN="$ROOT/tests/fixtures/fake-zmr-evidence-success.sh" \
ZMR_RUN_EVIDENCE_ROOT="$ATTEMPT" \
ZMR_RUN_EVIDENCE_INDEX="$INDEX" \
  "$ROOT/scripts/demo-ios-real.sh" \
  --out "$TMPDIR/evidence-ios-app" \
  --device fake-ios-1 \
  --xcrun "$FAKE_XCRUN" \
  --trace-root "$ATTEMPT/traces/ios-demo" >/dev/null

python3 "$ROOT/scripts/run_evidence.py" validate-bundle --root "$ATTEMPT" >/dev/null
python3 - "$ATTEMPT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in (root / "bootstrap-events.jsonl").read_text().splitlines()]
phases = [event["phase"] for event in events]
expected = ["app.build", "device.preflight", "device.acquire", "device.boot", "app.install", "shim.build", "shim.start", "shim.prewarm", "scenario.execute"]
position = -1
for phase in expected:
    position = phases.index(phase, position + 1)
summary = json.loads((root / "run-summary.json").read_text())
assert summary["status"] == "passed"
assert summary["scenarioDigest"].startswith("sha256:")
assert summary["scenarioDigest"] != "sha256:" + "b" * 64
assert summary["appBuildDigest"].startswith("sha256:")
assert summary["appBuildDigest"] != "sha256:" + "c" * 64
assert summary["device"]["resolved"] == "fake-ios-1"
assert summary["artifacts"]["trace"] == "traces/ios-demo/ios-shim-smoke"
assert summary["artifacts"]["report"] == "traces/ios-demo/ios-shim-smoke/report.html"
sidecars = list((root / "run-outcomes").glob("*.json"))
assert len(sidecars) == 2
assert all(json.loads(path.read_text())["iosShim"]["mode"] == "generated" for path in sidecars)
PY
