#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
DEVICE="$ROOT/.github/workflows/device-smoke.yml"

test -f "$CI"
test -f "$RELEASE"
test -f "$DEVICE"

grep -q '^permissions:$' "$CI"
grep -q '^  contents: read$' "$CI"
grep -q '^concurrency:$' "$CI"
grep -Fq 'group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}' "$CI"
grep -Fq "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$CI"
grep -q '^  quality-gate:$' "$CI"
grep -q '^    name: quality-gate$' "$CI"
if grep -q '^  test:$' "$CI"; then
  echo "CI required job key must remain quality-gate" >&2
  exit 1
fi

grep -q 'ZIG_VERSION: "0.16.0"' "$CI"
grep -q 'actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v5' "$CI"
grep -q 'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16 # v6' "$CI"
grep -q 'go-version-file: clients/go/go.mod' "$CI"
grep -q 'cache: false' "$CI"
grep -q 'rustup toolchain install stable --profile minimal' "$CI"
grep -q 'rustc --version' "$CI"
grep -q 'cargo --version' "$CI"
grep -q 'brew install kcov' "$CI"
grep -q 'ziglang.org/download/${ZIG_VERSION}' "$CI"
grep -q 'gem install xcodeproj' "$CI"
grep -q './scripts/ci-gate.sh' "$CI"
grep -q 'timeout-minutes: 20' "$CI"
grep -q 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7' "$CI"
grep -q 'name: zmr-ci-artifacts' "$CI"
grep -q 'if: always()' "$CI"
grep -q 'traces/' "$CI"
grep -q 'zig-cache/coverage/' "$CI"
grep -q 'zig-out/bin/zmr' "$CI"
grep -q 'if-no-files-found: ignore' "$CI"
grep -q 'retention-days: 14' "$CI"

if grep -q 'cancel-in-progress: true' "$DEVICE"; then
  echo "scheduled device evidence must not be cancellation-prone" >&2
  exit 1
fi
grep -q 'id: evidence_init' "$DEVICE"
grep -q 'run_evidence.py init' "$DEVICE"
grep -q 'id: evidence_finalize' "$DEVICE"
grep -q 'if: always()' "$DEVICE"
grep -q 'finalize-workflow-evidence.sh' "$DEVICE"
grep -q 'validate-bundle' "$DEVICE"
grep -q 'if-no-files-found: error' "$DEVICE"
grep -q 'retention-days: 14' "$DEVICE"
grep -q 'path: /tmp/zmr-android-demo/run-evidence/' "$DEVICE"
grep -q 'path: /tmp/zmr-ios-demo/run-evidence/' "$DEVICE"
if grep -q 'path: /tmp/zmr-.*-demo/traces/' "$DEVICE"; then
  echo "device uploads must target the complete run-evidence root" >&2
  exit 1
fi

python3 - "$DEVICE" "$ROOT/scripts/demo-ios-real.sh" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
jobs = text.split("  ios-simulator:", 1)
assert len(jobs) == 2
android, ios = jobs
for label, job in (("android", android), ("ios", ios)):
    init = job.index("id: evidence_init")
    setup_markers = (
        ("uses: actions/setup-java@", "name: Install Android toolchain")
        if label == "android"
        else ("name: Install iOS toolchain helpers",)
    )
    assert all(init < job.index(marker) for marker in setup_markers), label
    finalize = job.index("id: evidence_finalize")
    upload = job.index("uses: actions/upload-artifact@")
    assert finalize < upload, label
    for required_id in (
        "evidence_init",
        "toolchain_setup",
        "zmr_build",
        "device_acquire",
        "smoke",
        "evidence_finalize",
        "evidence_upload",
    ):
        assert f"id: {required_id}" in job, (label, required_id)

for required_id in ("toolchain_context", "device_context"):
    assert f"id: {required_id}" in ios, required_id

assert "id: java_setup_start" in android
assert "id: java_setup_close" in android
assert "id: smoke_action_start" in android
assert "id: smoke_action_close" in android
assert "id: smoke_close" in ios
assert android.index("id: java_setup_start") < android.index("id: java_setup\n")
assert android.index("id: smoke_action_start") < android.index("id: smoke\n")
assert "--step smoke:${{ steps.smoke.outcome }}:device.acquire:infra.emulator_provision" in android
assert "--name smoke --outcome \"$outcome\"" in android
assert "--root \"$ZMR_RUN_EVIDENCE_ROOT\" --phase device.acquire" in android
assert "failure_code=infra.emulator_provision" in android
ios_demo = open(sys.argv[2], encoding="utf-8").read().replace("\\\n", " ")
assert re.search(
    r'zmr_evidence_update_artifact_identity\s+"\$ROOT/examples/ios-smoke[.]json"\s+"\$APP_PATH"\s+"\$ROOT/examples/ios-shim-smoke[.]json"',
    ios_demo,
)

for action in (
    "actions/checkout",
    "actions/setup-java",
    "reactivecircus/android-emulator-runner",
    "actions/upload-artifact",
):
    for match in re.finditer(re.escape(action) + r"@([^\s]+)", text):
        assert re.fullmatch(r"[0-9a-f]{40}", match.group(1)), (action, match.group(1))

assert text.count("outcome: ${{ steps.") >= 3
assert text.count("run_evidence.py external") >= 3
assert text.count("run_evidence.py command") >= 6
PY

python3 - "$CI" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for action in ("actions/checkout", "actions/setup-go", "actions/upload-artifact"):
    matches = list(re.finditer(re.escape(action) + r"@([^\s]+)", text))
    assert matches, action
    assert all(re.fullmatch(r"[0-9a-f]{40}", match.group(1)) for match in matches), action
PY

grep -q 'ZIG_VERSION: "0.16.0"' "$RELEASE"
grep -q 'actions/checkout@v5' "$RELEASE"
grep -q 'actions/setup-go@v6' "$RELEASE"
grep -q 'go-version-file: clients/go/go.mod' "$RELEASE"
grep -q 'cache: false' "$RELEASE"
grep -q 'rustup toolchain install stable --profile minimal' "$RELEASE"
grep -q 'rustc --version' "$RELEASE"
grep -q 'cargo --version' "$RELEASE"
grep -q 'brew install kcov' "$RELEASE"
grep -q 'ziglang.org/download/${ZIG_VERSION}' "$RELEASE"
grep -q 'gem install xcodeproj' "$RELEASE"
grep -q 'timeout-minutes: 45' "$RELEASE"
grep -q 'ZMR_VERSION="${GITHUB_REF_NAME#v}"' "$RELEASE"
grep -q './scripts/release-gate.sh --phase static' "$RELEASE"
grep -q './scripts/release-gate.sh --phase platform-scripts' "$RELEASE"
grep -q './scripts/release-gate.sh --phase clients' "$RELEASE"
grep -q './scripts/release-gate.sh --phase protocol-smoke' "$RELEASE"
grep -q './scripts/release-gate.sh --phase release-artifacts' "$RELEASE"
grep -q 'attestations: write' "$RELEASE"
grep -q 'id-token: write' "$RELEASE"
grep -q 'actions/attest@v4' "$RELEASE"
grep -q 'softprops/action-gh-release@v3' "$RELEASE"
if grep -q 'actions/attest-build-provenance@v2\|softprops/action-gh-release@v2' "$RELEASE"; then
  echo "release workflow should not use Node 20-era release actions" >&2
  exit 1
fi
grep -q 'dist/RELEASE_MANIFEST.json' "$RELEASE"
grep -q 'actions/setup-node@v6' "$RELEASE"
grep -q 'node-version: "24"' "$RELEASE"
grep -q 'npm version --no-git-tag-version --allow-same-version "${GITHUB_REF_NAME#v}"' "$RELEASE"
grep -q 'npm run pack:npm' "$RELEASE"
grep -q 'package-manager-cache: false' "$RELEASE"
grep -q 'actions/upload-artifact@v7' "$RELEASE"
grep -q 'name: zmr-release-dist' "$RELEASE"
grep -q 'dist/' "$RELEASE"
grep -q 'if-no-files-found: error' "$RELEASE"
grep -q 'retention-days: 30' "$RELEASE"
grep -q 'dist/zeno-mobile-runner-\*.tgz' "$RELEASE"
grep -q 'npm_package=(./dist/zeno-mobile-runner-\*.tgz)' "$RELEASE"
grep -q 'test "${#npm_package\[@\]}" -eq 1' "$RELEASE"
grep -q 'npm publish "${npm_package\[0\]}" --access public' "$RELEASE"
if grep -q 'NODE_AUTH_TOKEN\|NPM_TOKEN' "$RELEASE"; then
  echo "release workflow should use npm trusted publishing, not token secrets" >&2
  exit 1
fi
