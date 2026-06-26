# Self-Managed Parallel CI

ZMR does not include a hosted device cloud in this preview. The recommended
scale path is self-managed parallel execution first: run deterministic ZMR
scenarios across the devices your team already controls, collect trace evidence,
and gate claims with repeat-run data.

## Local Matrix

Use `zmr-device-matrix` when a repository has known local Android and iOS
targets:

```bash
zmr-device-matrix .zmr/device-matrix.json --trace-root traces/zmr-matrix --results traces/zmr-matrix/results.jsonl
zmr report traces/zmr-matrix --out traces/zmr-matrix/report.html --junit traces/zmr-matrix/junit.xml
```

Keep matrix entries explicit. Do not rely on whichever simulator happens to be
booted in CI unless the job is intentionally single-device.

## Repeat-Run Reliability

Use `zmr-benchmark` before making reliability claims:

```bash
zmr-benchmark \
  --zmr .zmr/login-smoke.json \
  --platform android \
  --device emulator-5554 \
  --runs 20 \
  --trace-root traces/zmr-login-reliability \
  --results traces/zmr-login-reliability/results.jsonl \
  --replace \
  --min-pass-rate 100 \
  --max-failures 0
```

Use `zmr-compare-benchmarks` when evaluating ZMR against an existing runner:

```bash
zmr-benchmark-command --tool baseline --platform android --device emulator-5554 --scenario .zmr/login-smoke.json --runs 20 --trace-root traces/baseline --results traces/comparison/results.jsonl -- <baseline command>
zmr-compare-benchmarks --results traces/comparison/results.jsonl --candidate zmr --baseline baseline --out traces/comparison/comparison.md --evidence-out traces/comparison/evidence.jsonl
```

## CI Artifact Contract

Every matrix or reliability job should upload:

- `results.jsonl`
- `report.html`
- `junit.xml`
- failed trace directories or redacted `.zmrtrace` bundles

For private app repositories, prefer redacted `.zmrtrace` bundles over raw
screenshots and recordings.

## Hosted Cloud Boundary

Hosted cloud should be a later product, not a hidden preview claim. A credible
ZMR cloud needs:

- device isolation and reset policy
- device model and OS version catalog
- parallel scheduling semantics
- artifact retention and redaction policy
- PR checks and status reporting
- secrets handling
- provider-specific reliability evidence

Until those exist, public docs should say "local and self-managed device
targets" rather than "cloud device farm support."
