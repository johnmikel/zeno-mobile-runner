# Zeno Evidence Contract v1

The Evidence Contract turns Zeno Mobile Runner (ZMR) and Playwright results
into the same open, digest-verifiable package. Use it when a release record
needs to say what ran, against which exact build, what passed or failed, and
which business journey the result supports.

## What the contract establishes

Contract validation establishes three local facts:

1. `evidence.json` has the closed v1 shape and satisfies its semantic rules.
2. Every packaged artifact still has the size and SHA-256 digest recorded in
   the manifest.
3. A registered mobile or web target fingerprint can be recomputed from its
   declared build identity.

Those facts make the package tamper-evident and its target identity
deterministic. They do not authenticate the submitter, independently prove
that a test ran, prove that the producer told the truth, or show that a release
is complete, secure, compliant, or bug-free.

Local v1 packages are deliberately self-reported.
Both shipped adapters always emit `attestationState: "unattested"`: the ZMR
adapter and the Playwright reporter do not claim a stronger trust state. No
supported CI identity or producer signature has independently authenticated
their execution claim. The resulting state is `unattested`. A producer's
`provenanceClass` describes the normalization path:

- `zeno_runner` means the package came through the ZMR adapter;
- `official_adapter` means it came through a supported adapter such as the
  Playwright reporter; and
- `imported` means a generic source with weaker, non-qualifying semantics.

These labels are provenance, not authentication or an outcome.

The v1 schema and runtime accept `ci_attested` and `signature_verified`
only as future-compatible producer states. Acceptance means only that the
declared value and surrounding manifest are structurally and semantically valid.
Local schema, semantic, and package validation
neither establishes nor verifies either stronger claim. Each requires an
external authenticated ingestion envelope or verifier that authenticates the
CI workload or producer signature and binds it to the manifest digest.

## Package layout

An evidence package is a directory:

```text
release-evidence/
├── evidence.json
└── artifacts/
    └── sha256/
        └── ab/
            └── cdef...full-remaining-digest
```

`evidence.json` is the contract manifest. Artifact bytes are content-addressed
from the full lower-case SHA-256: the first two hexadecimal characters form a
directory and the remaining 62 form the filename. Identical bytes are stored
once even if several items refer to them. Each manifest reference records the
semantic `type`, package-relative `path`, `digest`, `sizeBytes`, MIME
`contentType`, `redactionState`, and `disclosureState`.

The manifest binds one project, submission claim, producer, release, target,
and run to one or more item attempts. Items carry a stable external ID,
optional journey mapping, scenario hash, outcome, attempt number, timestamps,
duration, failure classification, normalized execution metadata, and artifact
references.

## Identity and the future ingestion boundary

Project identity is `project.externalId`: it says which product the producer
intended this evidence to describe. It is stable correlation data, not an
authorization credential.

Submission identity is a separate self-reported object. Its `actorType` is
`user` or `automation`, its `externalId` names the claimed actor, and its
`claimState` is `self_reported`.
This submission identity is an unauthenticated claim and cannot authorize an
upload or select a tenant/project on its own.

A future authenticated ingestion envelope will sit outside `evidence.json`.
It will authenticate the caller or CI workload, authorize that principal for a
server-side tenant and project, bind the received manifest digest to the
ingestion session, and compare the authenticated context with the manifest's
self-reported project and submission claims. The local v1 package does not
provide that envelope.

## Exact target fingerprint recipes

Both registered recipes hash the UTF-8 bytes of an RFC 8785 JSON
Canonicalization Scheme (JCS) object. The result is stored as
`sha256:<64-lower-case-hex>`. The listed fields are exact: omitting one is an
error, adding an input does not change v1, and a later recipe must receive a
new name rather than reinterpret v1.

A registered target stores the recipe name in `fingerprintRecipe`, the result
in `targetFingerprint`, and `fingerprintVerification: "recomputed"`.

### `mobile-v1`

`mobile-v1` applies only to `ios` and `android`. Hash this exact logical
object:

```json
{
  "appId": "com.example.shop",
  "artifactDigest": "sha256:<SHA-256 of the APK or IPA bytes>",
  "buildNumber": "284",
  "recipe": "mobile-v1",
  "surface": "android",
  "version": "1.4.0"
}
```

The application artifact must be a regular file. A mutable download URL,
commit SHA alone, or human build label is not a mobile build identity.

### `web-v1`

`web-v1` applies only to `web`. Hash this exact logical object:

```json
{
  "buildManifestDigest": "sha256:<SHA-256 of an immutable build manifest>",
  "commitSha": "0123456789abcdef0123456789abcdef01234567",
  "configDigest": "sha256:<SHA-256 of allowlisted non-secret configuration>",
  "deploymentId": "deploy_01J...",
  "environment": "staging",
  "recipe": "web-v1",
  "surface": "web"
}
```

Do not hash secrets into `configDigest`; use a stable allowlist of non-secret
settings that can materially change the deployed behavior. A mutable URL or
commit SHA by itself is not a web deployment identity.

The fingerprint establishes identity, not authenticity.
A future project policy may qualify passing evidence for an exact registered
fingerprint as Verified coverage; that policy decision does not turn a local
adapter into independent execution proof.

## Create a package from ZMR

Generate a trace first, then run `zmr-evidence from-zmr`. The source may be a
trace directory or a supported `.zmrtrace` archive. Supply exactly one of
`--scenario` or `--scenario-hash`.

```bash
zmr run .zmr/checkout-smoke.json \
  --device emulator-5554 \
  --trace-dir traces/android-checkout

zmr-evidence from-zmr \
  --trace traces/android-checkout \
  --scenario .zmr/checkout-smoke.json \
  --project-id shop-mobile \
  --submitter-type automation \
  --submitter-id github-actions \
  --release-id release-2026-07-14 \
  --commit-sha 0123456789abcdef0123456789abcdef01234567 \
  --surface android \
  --app-artifact app/build/outputs/apk/release/app-release.apk \
  --app-id com.example.shop \
  --app-version 1.4.0 \
  --build-number 284 \
  --environment staging \
  --journey-id checkout.guest \
  --item-id android-checkout-smoke \
  --run-id gha-1842-android \
  --device-name "Pixel 9" \
  --os-name Android \
  --os-version 16 \
  --out zeno-evidence/android-checkout
```

The adapter validates the trace manifest and terminal event, checks the
explicit app identity, hashes the scenario and app artifact, normalizes trace
artifacts, recomputes `mobile-v1`, and writes the package atomically. It does
not authenticate the declared project, submitter, release, or CI run. Use
`--force` only when intentionally replacing an existing destination.

## Create web evidence with Playwright

Install the package next to `@playwright/test` and configure the
`zeno-mobile-runner/playwright-reporter` custom reporter. The complete example
is [playwright-zeno-reporter.config.ts](../examples/playwright-zeno-reporter.config.ts).

```ts
import { defineConfig } from "@playwright/test";

export default defineConfig({
  reporter: [
    ["zeno-mobile-runner/playwright-reporter", {
      outputDir: "zeno-evidence/web",
      projectId: process.env.ZENO_PROJECT_ID!,
      submitterType: "automation",
      submitterId: process.env.ZENO_SUBMITTER_ID!,
      releaseId: process.env.ZENO_RELEASE_ID!,
      commitSha: process.env.GITHUB_SHA!,
      deploymentId: process.env.ZENO_DEPLOYMENT_ID!,
      environment: "staging",
      buildManifestPath: "dist/manifest.json",
      configDigest: process.env.ZENO_CONFIG_DIGEST!,
      browserName: "chromium",
      browserVersion: process.env.ZENO_BROWSER_VERSION!,
    }],
  ],
});
```

Map a test to a stable business journey with the public annotation shown in
[playwright-zeno-journey.spec.ts](../examples/playwright-zeno-journey.spec.ts):

```ts
test("guest checkout", {
  annotation: {
    type: "zeno:journey",
    description: "checkout.guest",
  },
}, async ({ page }) => {
  await page.goto("/checkout");
});
```

The reporter retains every recorded test attempt, including retries, preserves
attachments as private artifacts, and computes `web-v1`.
Unmapped Playwright tests cannot qualify a journey; they remain useful run
context with `journeyId: null`.

## A worked example across both surfaces

[examples/cross-platform-evidence](../examples/cross-platform-evidence/README.md)
runs a real Playwright suite and a real ZMR scenario, packages both, validates
both with one command, and then changes a single byte to show the validation is
load-bearing. Run it with:

```bash
bash examples/cross-platform-evidence/run-demo.sh
```

## Validate before retaining or sending

Run `zmr-evidence validate` against the manifest, not just the directory:

```bash
zmr-evidence validate zeno-evidence/android-checkout/evidence.json
```

The command validates JSON syntax, schema and semantic invariants, recomputes a
registered fingerprint, resolves every sibling artifact safely, and compares
its size and digest. Normal behavior is machine-readable JSON:

- success writes one `{ "ok": true, ... }` object to stdout and exits `0`;
- a malformed/tampered package writes `{ "ok": false, "error": ... }` to
  stderr and exits `1`; and
- an invalid command or option writes the same error envelope and exits `2`.

Do not treat a zero exit as authentication. It means only that the local
contract and bytes validate.

## Execution metadata

Execution fields are normalized so consumers do not need source-specific
names:

- mobile items use `kind: "mobile"` with `deviceName`, `osName`, and `osVersion`;
  and
- web items use `kind: "browser"` with `browserName` and `browserVersion`.

The values describe the claimed execution environment. They are required for
registered local adapters but are not signatures or policy conclusions.
Unnormalized future sources use `kind: "unregistered"` plus a namespaced
extension and remain non-qualifying.

## Artifact review and disclosure

Artifact `type` is semantic (`screenshot`, `video`, `event_log`, `report`,
`trace`, or a producer-specific value); `contentType` is the MIME type. Keep
those concepts separate.

Redaction records what happened to the bytes:

- `unreviewed` — nobody has completed a privacy review;
- `reviewed` — the original bytes were reviewed; and
- `redacted` — the retained bytes were deliberately transformed or selected
  from a redacted source.

Disclosure records who may receive the bytes:

- `private` — internal only;
- `review_eligible` — reviewed and eligible for a later selection;
- `disclosed` — explicitly selected in a future published record; and
- `withheld` — deliberately excluded.

Unreviewed artifacts remain private by default. Both shipped adapters create
private artifact references; neither publishes a file. Redaction does not
imply disclosure, and omission is represented by no artifact reference rather
than a fabricated empty screenshot. A run separately records aggregate
`redactionState` (`unreviewed`, `reviewed`, `redacted`, or `mixed`) and
`completenessState` (`complete`, `partial`, or `incomplete`).

## New surfaces, versions, and public fixtures

Contract v1 registers only `mobile-v1` for iOS/Android and `web-v1` for web.
Unknown surface/recipe pairs use the `unregistered_recipe` verification state
and are retained as non-qualifying context until a public recipe is registered.
Consumers must not silently reinterpret the digest, infer missing fingerprint
inputs, or map an unknown pair to the closest current surface.

`schemaVersion: "1.0"` is closed by default; producer-specific data belongs in
namespaced `extensions`. A new fingerprint input or incompatible semantic
change requires a new public recipe or contract version. Existing recipe names
and fixture bytes keep their meaning.

The [public Evidence Contract v1 fixtures](../fixtures/evidence/v1/) are the
cross-implementation compatibility surface. `cases.json` declares which
schema, semantic, package, or adapter layer applies to each case; `null` means
that layer is not implemented for that phase, not that it passed. Schema,
runtime validation, case expectations, and fixture bytes must change together.

## Security limits

Treat every manifest, directory, archive, and attachment as untrusted input.
The shipped readers enforce these v1 limits and rejections:

- one artifact or TAR entry is at most 128 MiB;
- a ZMR TAR is at most 512 MiB, contains at most 10,000 entries, and contains
  at most 512 MiB of entry bytes;
- only regular ustar file entries are accepted—symlinks, hard links,
  directories, devices, and extension entry types are rejected;
- paths must be safe relative POSIX paths; absolute paths, drive/UNC paths,
  backslashes, `.`/`..` segments, control characters, Windows device names,
  duplicate paths, and traversal are rejected;
- directory and attachment sources must remain inside their explicit
  `allowedRoot`, and symlink components or non-regular files are rejected;
- malformed headers, invalid checksums, truncated bodies, missing TAR end
  markers, and non-zero trailing archive data are rejected;
- manifest nesting deeper than 512 levels, ambiguous/unknown fields outside
  namespaced extensions, invalid timestamps, inconsistent outcomes, unsafe
  artifact paths, and conflicting duplicate artifact descriptors are rejected;
  and
- stored bytes are re-read and checked against declared size and digest before
  a package is accepted.

Validation errors are failures, not warnings or silent fallbacks. Keep source
archives and generated packages private until their artifact disclosure has
been reviewed.
