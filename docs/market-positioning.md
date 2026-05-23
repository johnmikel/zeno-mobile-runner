# Market Positioning

ZMR is a developer-preview runner. It should compete by being the best local
mobile automation control plane for AI agents, not by pretending to be a mature
drop-in replacement for every existing runner on day one.

## What The Market Rewards

The existing market rewards frameworks that feel easy to start, expose stable
selectors and waits, produce useful reports, and run well in CI. Some tools lean
on app internals, some use simple flow files, and some emphasize hosted device
coverage. ZMR should avoid copying those surfaces directly. Its opportunity is a
mobile-native control plane: device lifecycle, app install/launch/clear state,
accessibility trees, selector actions, logs, screenshots, trace bundles, and
physical-device workflows.

## ZMR Position

ZMR should lead with:

- **Agent-native protocol:** structured snapshots and actions over JSON-RPC,
  plus an MCP stdio server for agent runtimes.
- **Semantic mobile tree:** normalized roles, names, selectors, bounds, and
  recommended actions so agents do not parse platform-specific hierarchy dumps.
- **Trace-first reliability:** every action produces evidence agents and humans
  can inspect.
- **Small deterministic core:** Zig runner, explicit adapters, schema-validated
  inputs, stable CLI JSON.
- **App-local setup:** `.zmr/` owns config, scenarios, shims, and private traces.
- **Language-neutral clients:** TypeScript, Python, Go, and Rust can all drive
  the same protocol.

## Where ZMR Is Already Strong

| Area | ZMR advantage |
| --- | --- |
| AI agent integration | First-class JSON-RPC, MCP tools, semantic snapshots, live trace events, schemas, agent guide, packaged skill |
| Failure diagnostics | Trace bundles, snapshot replay, UI tree, screenshots, logs, `zmr explain` |
| Language neutrality | Protocol clients across multiple languages |
| Local release discipline | Release gate, coverage gate, artifacts, SBOM, checksums, attestation |
| App-local privacy | `.zmr/` config and redacted trace export |
| Mobile focus versus browser engines | Native Android/iOS device lifecycle and accessibility semantics instead of CDP-only web primitives |

## Where ZMR Must Catch Up

| Area | Gap |
| --- | --- |
| npm distribution | Tarball exists in GitHub release, registry publish still pending |
| Android proof | Public generic Android demo wrapper exists; repeated emulator proof and app-local pilots still need published release evidence |
| iOS scale | Simulator demo passes, but repeated-run evidence should be published |
| Physical iOS | Local lifecycle and selector support exist through `devicectl` plus the XCTest shim; screenshots use the shim, physical log capture still needs hardening |
| Cloud | Not supported yet |
| Human DSL | JSON is reliable for agents; a friendlier authoring layer should compile to JSON |
| Brand surface | README is now concise; a docs/landing site should follow after npm publish |

## Website Recommendation

For `0.1.x`, GitHub README plus release assets are enough. After npm publish,
create a docs site with:

- homepage: value proposition, install, demo GIF/video, trace viewer screenshot
- docs: install, `.zmr/`, scenarios, JSON-RPC, clients, shims, privacy
- compare: honest capability matrix
- examples: Android app, iOS app, agent session
- releases: checksums, SBOM, artifact verification

Do not create a marketing-only site before the npm package and repeated device
evidence are in place. The strongest market fit is a clean first-run path that
actually works.

