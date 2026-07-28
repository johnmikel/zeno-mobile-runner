# Gate a pull request on ZMR evidence

An agent can already screenshot a simulator and describe what it sees. What it
cannot do is hand you the same answer twice, for nothing, in a form you can gate
a merge on. This page walks the whole chain end to end, with the commands and
the real output from a verified run.

Every command and every value below was executed against
`zeno-mobile-runner 0.2.18` on an iOS 26.5 simulator. Nothing here is
illustrative.

## The chain

```text
zmr run                  →  trace          (deterministic verdict + events)
zmr-evidence from-zmr    →  package        (content-addressed, digest-bound)
zmr-evidence validate    →  exit 0 / 1     (the thing CI gates on)
```

The trace is the observation. The package is the artifact you keep. `validate`
is the gate: it exits non-zero the moment any packaged byte stops matching its
recorded digest.

## 1. Run the scenario

```bash
zmr run .zmr/react-native-expo-ios-workflow.json \
  --device "$SIM_UDID" \
  --platform ios \
  --ios-device-type simulator \
  --trace-dir traces/pr-check
```

Run this from the app directory. A relative `iosShimPath` in
`.zmr/config.json` resolves against the working directory, and without the
XCTest shim ZMR cannot read the iOS UI tree at all — every wait times out and
the failure looks like a bad selector rather than a missing shim.

The trace records a typed verdict plus an event stream. The event count is the
part worth gating on over time: a constant count across repeated runs means the
runner walked the identical path, which is a stronger statement than a pass.
Measured on the generated Expo fixture — 20 consecutive runs of this 17-step
scenario, 20 passes, 45 events every time, p95 51.2 s. Method, environment and
scope: [`benchmarks/2026-07-27-ios-determinism.md`](benchmarks/2026-07-27-ios-determinism.md).

## 2. Package the trace as evidence

```bash
zmr-evidence from-zmr \
  --trace "$PWD/traces/pr-check" \
  --scenario "$PWD/.zmr/react-native-expo-ios-workflow.json" \
  --project-id my-app \
  --submitter-type automation \
  --submitter-id ci \
  --release-id "$(git rev-parse --short HEAD)" \
  --commit-sha "$(git rev-parse HEAD)" \
  --surface ios \
  --app-artifact "$PWD/build/MyApp.app.zip" \
  --app-id com.example.myapp \
  --app-version 1.0.0 \
  --build-number 1 \
  --environment simulator \
  --journey-id onboarding \
  --item-id expo-ios-workflow \
  --run-id "$GITHUB_RUN_ID" \
  --device-name "iPhone-17-Pro" \
  --os-name ios \
  --os-version 26.5 \
  --out release-evidence
```

On success it prints the manifest digest, which is the identity of this run:

```json
{
  "ok": true,
  "command": "from-zmr",
  "output": "release-evidence",
  "manifestDigest": "sha256:1b49ac2907aba9aa343e85644b7e37a19c0933898c722c8cc35d1bc8e087a2d6",
  "items": 1,
  "artifacts": 6
}
```

Six artifact references resolved to five files on disk: artifacts are addressed
by content, so identical bytes are stored once.

### Four things that will stop you here

All four were hit while writing this page. The two source-path rules now name
themselves in the error, but the reasons are worth knowing before you start.

| Symptom | Cause |
|---|---|
| `symlink_source_rejected` on any path under `/tmp` on macOS | Source paths may not contain a symbolic link, and `/tmp` is a symlink to `/private/tmp`. Use the resolved path. |
| `source_not_regular_file` on an iOS `.app` | `--app-artifact` must be a regular file. Zip the bundle, or pass the `.ipa`. |
| `Evidence command failed`, no detail | An underlying validation code outside the CLI's public message allowlist. The CLI deliberately does not leak internals, so unrecognized causes collapse to this string with an empty `issues` array. |
| Rejected before anything runs | All nineteen listed flags are required, and exactly one of `--scenario` or `--scenario-hash`. `--submitter-type` accepts only `user` or `automation`. |

Source-path failures — symbolic links, non-regular files, a source that is too
large or that changed mid-read — report their own code and name the flag to fix.
Anything still reporting `Evidence command failed` is a cause the CLI has no
path-free wording for yet, not a cause it is hiding from you.

## 3. Validate — this is the gate

`validate` takes the manifest path as a positional argument. There is no
`--package` flag.

```bash
zmr-evidence validate release-evidence/evidence.json
```

Clean package, exit code `0`:

```json
{
  "ok": true,
  "command": "validate",
  "manifestDigest": "sha256:1b49ac2907aba9aa343e85644b7e37a19c0933898c722c8cc35d1bc8e087a2d6",
  "items": 1,
  "artifacts": 6
}
```

Now append a single byte to one packaged screenshot and validate again — exit
code `1`, with a typed reason:

```json
{
  "ok": false,
  "error": {
    "code": "artifact_size_mismatch",
    "message": "Packaged artifact size does not match its descriptor",
    "issues": []
  }
}
```

One byte is enough. That is the property that makes the package worth attaching
to a pull request: a reviewer does not have to trust the producer's summary,
because the bytes either match the manifest or they do not.

## 4. Wire it into CI

```bash
set -euo pipefail

zmr run .zmr/pr-check.json --device "$SIM_UDID" --platform ios \
  --ios-device-type simulator --trace-dir traces/pr-check
zmr report traces/pr-check --out traces/pr-check/report.html \
  --junit traces/pr-check/junit.xml
zmr-evidence from-zmr --trace "$PWD/traces/pr-check" ... --out release-evidence
zmr-evidence validate release-evidence/evidence.json
```

Upload `release-evidence/` and `report.html` as build artifacts; publish
`junit.xml` through whatever already reads JUnit. The merge gate is the exit
code of the last command.

Do not check the exit code through a pipe. In `zsh`, `cmd | tail -5; echo $?`
reports the status of `tail`, and `$PIPESTATUS[0]` is empty because `zsh` spells
it `$pipestatus`. Redirect to a file and test `$?` directly — a false pass here
has shipped a broken tag in this repo before.

## What the package does not claim

Both shipped adapters emit `attestationState: "unattested"`, and local
validation establishes exactly three facts: the manifest has the closed v1
shape, every packaged artifact still matches its recorded size and digest, and a
registered target fingerprint recomputes from its declared build identity.

It does not authenticate the submitter, independently prove a test ran, or prove
the producer told the truth. `provenanceClass: zeno_runner` records the
normalization path, not authenticity. Stronger states (`ci_attested`,
`signature_verified`) are accepted by the schema as future-compatible values
only; nothing local verifies them.

Full contract, including the manifest shape: [`evidence-contract.md`](evidence-contract.md).
