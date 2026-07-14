# Evidence Contract v1 conformance fixtures

These files are the public conformance surface for Evidence Contract v1. Their
exact bytes are versioned API: consumers may copy them into independent schema,
semantic, package, and adapter test suites. Changes therefore require the same
compatibility review as changes to `schemas/evidence-v1.schema.json`.

## Valid manifest fixtures

- `manifests/zeno-passed.json` — complete passing Zeno evidence.
- `manifests/zeno-failed.json` — complete failed Zeno evidence with a bounded error.
- `manifests/zeno-partial.json` — partial Zeno evidence.
- `manifests/playwright-passed.json` — complete passing browser evidence.
- `manifests/playwright-retry-pass.json` — failed attempt followed by a passing retry.
- `manifests/unregistered-target.json` — retained, explicitly non-qualifying context.
- `manifests/missing-optional-artifacts.json` — valid evidence with no optional artifacts.
- `manifests/redacted-omitted-screenshot.json` — valid redaction metadata with an omitted screenshot.

## Valid Playwright source fixtures

- `sources/playwright/passed.json` — valid single-attempt passing lifecycle source.
- `sources/playwright/retry-pass.json` — valid retry lifecycle source ending in a pass.

## Intentionally invalid fixtures

- `invalid/missing-target-fingerprint.json` — required target fingerprint omitted.
- `invalid/empty-project-id.json` — empty project identity.
- `invalid/whitespace-journey-id.json` — edge-whitespace journey identity.
- `invalid/unknown-schema-version.json` — unsupported contract version.
- `invalid/malformed-manifest.json` — syntactically valid JSON with the wrong structure.
- `invalid/malicious-artifact-path.json` — parent-traversal artifact path.
- `invalid/artifact-digest-mismatch/` — valid manifest semantics but mismatched package bytes.

`cases.json` declares which validation layers apply to each case. A `null`
expectation means that layer is genuinely not part of the current phase; it is
not a passing result. The JUnit, CTRF, ZMR archive, and Playwright source cases
remain visible but inactive until their named adapter phase implements them.

The Playwright source JSON files use `zeno-playwright-reporter-fixture-v1`, a
small documented lifecycle record designed to be translated into public
Playwright Reporter API-shaped fakes. They are not Playwright's private JSON
reporter output.
