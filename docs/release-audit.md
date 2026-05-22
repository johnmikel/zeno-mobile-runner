# Release Completion Audit

This audit maps the release objective to concrete evidence. Treat it as the
source of truth before tagging a public release or making competitive claims.

Current status: **ready for `0.1.0` developer preview**. Not production-stable.

Latest release-candidate evidence:

- Evidence: `traces/release-candidate/20260517-180801/evidence.jsonl`
- Summary: `traces/release-candidate/20260517-180801/summary.md`
- Dev preview: `ready`
- Production: `blocked`
- Market claim: `blocked`

The latest local candidate passed its generated public Android demo app build
and generated public iOS simulator demo. Production and market claims remain
blocked until the hardware and benchmark evidence below exists.

Latest full local gate verification:

- Date: `2026-05-18`
- Command: `./scripts/release-gate.sh`
- Result: passed
- Zig tests: 214/214 passed with `zig test src/main.zig -target aarch64-macos.15.0`
- Coverage: `94.40%` line coverage
- Release artifacts: built and verified
- Release smoke: passed on the local macOS archive
- npm package dry-run: passed

Additional local pilot evidence:

- `traces/hardware-pilots/20260517-evidence.jsonl`
- Public generated iOS simulator lifecycle pilot: 20/20 passed, p95 10392ms.
- Public generated iOS simulator selector-shim pilot: 20/20 passed, p95 4175ms.
- Public generated Android emulator pilot: 20/20 passed, p95 12596ms, after
  cleaning generated build artifacts and hardening the generated demo's first
  screen wait from 10s to 30s.

This strengthens the public generated-demo evidence for both platforms, but it
does not replace the required real app/device pilots for production readiness.

## Prompt-to-artifact checklist

| Requirement | Evidence | Current state |
| --- | --- | --- |
| Leaner, easier-to-understand core | Focused modules under `src/cli_*`, `src/runner_*`, `src/json_rpc_*`, `src/ios_*`, `src/android_*`, plus focused tests | Implemented and covered by `zig test src/main.zig -target aarch64-macos.15.0` |
| Developer-friendly first run | `npm install`, `npx zmr-wizard`, `.zmr/config.json`, smoke scenarios, package scripts | Implemented; covered by `tests/npm-package.test.mjs` and `tests/init-app-test.sh` |
| AI-agent usability | JSON-RPC, MCP, semantic snapshots, live trace events, schemas, clients, agent skill | Implemented; covered by protocol fixtures, client tests, MCP tests, and docs |
| Public package hygiene | npm files whitelist, public-safety scan, private trace exclusion | Implemented; covered by `tests/npm-package.test.mjs` and `tests/public-safety-test.sh` |
| App-install package surface | npm tarball exposes app-facing commands and excludes maintainer-only release tooling | Implemented; covered by `tests/npm-package.test.mjs` and `npm pack --dry-run` |
| Android/iOS local demos | Public generated Android and iOS demo scripts | Implemented; included in release-candidate dev-preview evidence |
| Release artifacts | archives, checksums, SBOM, Homebrew formula, npm dry-run | Implemented; covered by `./scripts/release-gate.sh` |
| Dev-preview release readiness | `zmr-release-readiness --target dev-preview --json` | Ready when `satisfied` includes local release gate plus public Android/iOS demos |
| Production release readiness | `zmr-release-readiness --target production --json` | Blocked until physical iOS readiness and repeated real-app/device pilots pass with structured thresholds, app-id, app-root, app-artifact, and device evidence |
| Competitive market claim | `zmr-release-readiness --target market-claim --json` | Blocked until same-device benchmark evidence exists |

## Required evidence before production

Run these before claiming production readiness:

```bash
zmr-release-readiness --evidence traces/release-candidate/<run>/evidence.jsonl \
  --evidence /path/to/private-app/traces/zmr-pilots/evidence.jsonl \
  --target production --json
```

Production readiness requires:

- physical iOS readiness with concrete device evidence
- Android hardware pilot with structured `runs >= 20`, `minPassRate >= 100`, `maxFailures <= 0`, app-id evidence, app-root evidence, and Android device evidence
- iOS simulator hardware pilot with structured `runs >= 20`, `minPassRate >= 100`, `maxFailures <= 0`, app-id evidence, app-root evidence, iOS app-artifact evidence, and iOS simulator device evidence
- iOS physical hardware pilot with structured `runs >= 20`, `minPassRate >= 100`, `maxFailures <= 0`, app-id evidence, app-root evidence, iOS app-artifact evidence, and physical device evidence

Market-claim readiness additionally requires same-device benchmark evidence
with candidate and baseline name evidence against the specific tool or runner
being discussed, results path evidence for the source benchmark rows, and
measured result evidence proving the thresholds were met. The benchmark
comparison row must also include `sameContext: true` and structured platform,
device, app id, scenario, and app-build context, with at least 20 candidate
runs and at least 20 baseline runs.

## Release wording

Use this wording for the current release:

> ZMR `0.1.0` is a public developer preview for local, agent-native
> mobile automation. It is not production-stable yet. Production and competitive
> claims require the release-readiness evidence gates.

Do not say:

- production-ready
- stable `1.0`
- better than another runner
- fully certified on physical iOS

unless the matching evidence exists in `evidence.jsonl` and
`zmr-release-readiness` returns `ready` for that target.
