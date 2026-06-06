# Production Readiness

ZMR is a public developer preview. The npm package is live, release artifacts
are signed by GitHub release attestations, and local app teams can collect
repeatable Android, iOS simulator, and physical iOS evidence. ZMR should not be
called production-stable until the gates below are met and kept passing.

## Current Release Standard

Every public release should satisfy:

- `bash tests/docs-readiness-test.sh`
- `bash tests/public-safety-test.sh`
- `npm test`
- `zig test src/test_harness.zig -target aarch64-macos.15.0`
- `./scripts/release-gate.sh`
- `npm run pack:npm`
- `./scripts/verify-release-artifacts.sh --dist dist`
- at least one trace or benchmark report rendered with `zmr report --junit`,
  or a pilot wrapper run that produced both `report.html` and `junit.xml`
- a fresh npm install smoke:

  ```bash
  npm install --save-dev zeno-mobile-runner
  npx zmr version --json
  ```

Tagged releases are expected to build release archives, generate
`RELEASE_MANIFEST.json`, publish GitHub artifact attestations, upload release
assets, and publish the npm tarball through trusted publishing after the npm
package is configured with the `release.yml` trusted publisher.

## Product Gates Before 1.0

| Area | Required evidence | Current status |
| --- | --- | --- |
| Android emulator | 20-run pilot gate with zero failures and trace/report artifacts | Supported by `zmr-pilot-gate` and demo app |
| Android physical device | 20-run pilot gate on a real connected device | Supported by ADB flow; app teams must collect evidence |
| iOS simulator | 20-run pilot gate with XCTest shim selectors, screenshots, and reports | Supported by iOS demo and app-local shim |
| iOS physical device | 20-run pilot gate on a real trusted device | Supported for lifecycle and shim screenshots; needs repeated public evidence |
| React Native | Public setup guidance plus selector-grade app evidence using stable labels or ids | Guidance exists; repeated public demo evidence is still needed |
| Expo | Public smoke, dev-client scaffold, and iOS/Android run evidence | Basic iOS smoke is documented; repeated matrix evidence is still needed |
| Flutter | Platform-level Android/iOS smoke using semantics, deep links, and screenshots | Supported at platform level; widget-tree claims are intentionally out of scope |
| Agent workflows | MCP and JSON-RPC loop with semantic snapshots, typed actions, traces, redacted export, and scenario validation | Supported; built-in autonomous crawler is not shipped |
| CI reporting | HTML reports plus JUnit XML artifacts from trace, benchmark, and pilot directories | Supported by `zmr report --junit` and pilot wrappers |
| Trace privacy | Redacted export path, denylist/allowlist controls, and public-safety tests | Supported and gated |
| Release supply chain | Trusted npm publish, GitHub artifact attestations, checksums, SBOM, and release manifest | Workflow is ready; npm trusted publisher must be configured in package settings |

## Reliability Evidence

Use repeated app-local pilots before making app or device claims:

```bash
zmr-pilot-gate \
  --android \
  --ios \
  --android-app-root . \
  --android-app-id com.example.mobiletest \
  --android-device emulator-5554 \
  --ios-app-root . \
  --ios-app-path ./build/Debug-iphonesimulator/Sample.app \
  --ios-app-id com.example.mobiletest \
  --ios-device booted \
  --ios-shim ./.zmr/ios-shim \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --evidence-out traces/zmr-pilots/evidence.jsonl
```

Then summarize readiness:

```bash
zmr-release-readiness \
  --evidence traces/zmr-pilots/evidence.jsonl \
  --target production \
  --json
```

Keep the generated evidence in the app repository unless it is fully redacted
and safe to publish.

## Agentic Standard

ZMR is agentic when an external agent can work from structured state instead of
screenscraping or guessing:

- `zmr doctor --json` explains setup state and remediation.
- `zmr schemas --json` exposes machine-readable contracts.
- `zmr validate --json` catches scenario mistakes before device runs.
- `zmr serve` exposes JSON-RPC for long-running sessions.
- `zmr mcp` exposes MCP tools for semantic snapshots and typed actions.
- `zmr explain --json` summarizes failed traces.
- `zmr report --junit` emits CI-compatible test results from trace and
  benchmark evidence.
- `zmr export --redact` produces shareable trace bundles.

The safe discovery pattern is still external-agent-first: observe with
`semantic_snapshot`, choose one typed action, record successful steps into a
candidate scenario, validate it, rerun it deterministically, and require human
review before committing generated tests.

## Claims Policy

- Claim Android and iOS app-level support only for flows that pass local pilot
  evidence on the target device class.
- Claim React Native and Expo support through app-level lifecycle, deep links,
  accessibility labels, selectors, screenshots, traces, and reports.
- Claim Flutter support at the Android/iOS app level when the app exposes stable
  semantics, labels, ids, or deep links.
- Do not claim Flutter widget-tree inspection, Dart state inspection, managed
  device-farm coverage, or a built-in autonomous test writer until those
  features exist and have public evidence.
