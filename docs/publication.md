# Public GitHub Publication

This is the maintainer checklist for uploading ZMR to a public GitHub repository
and making it usable by other mobile app codebases.

## Public Repo State

Before pushing a branch or tag:

```bash
git status --short
bash tests/public-safety-test.sh
./scripts/release-gate.sh
npm pack --dry-run
```

Expected evidence:

- `git status --short` shows only intentional source, docs, workflow, schema,
  shim, client, and test files.
- `bash tests/public-safety-test.sh` passes.
- `./scripts/release-gate.sh` passes locally.
- `npm pack --dry-run` lists only public package contents.

Do not commit generated traces, release archives, npm tarballs, local build
outputs, app credentials, private app identifiers, simulator logs, or raw visual
artifacts. `.gitignore` excludes `traces/`, `dist/`, `zig-out/`, Zig caches,
`prebuilds/`, `node_modules/`, and generated tarballs by default.

## Repository Setup

1. Create the public GitHub repository.
2. Push the source branch.
3. Confirm CI runs `./scripts/release-gate.sh`.
4. Configure branch protection for `main`.
5. Add `NPM_TOKEN` only when npm publish should be automated.
6. For the current dev-preview package, create and push tag `v0.1.0`.

The release workflow builds release archives, generates checksums, verifies
packaged binaries, builds the npm tarball with prebuilt binaries, uploads GitHub
release assets, publishes artifact attestations, and publishes to npm when
`NPM_TOKEN` is configured.

## App Integration Smoke

In a separate mobile app checkout:

```bash
npm install --save-dev zig-mobile-runner
npx zmr-wizard --app-id com.example.mobiletest --package-json
npx zmr doctor --strict --json --config .zmr/config.json
npm run zmr:android
npm run zmr:ios
```

Use `zmr-pilot-gate` for maintainer release evidence on machines with real app
builds and devices:

```bash
npx zmr-pilot-gate \
  --android \
  --ios \
  --android-app-root . \
  --android-app-id com.example.mobiletest \
  --android-device emulator-5554 \
  --ios-app-root . --ios-app-path ./build/Debug-iphonesimulator/Sample.app \
  --ios-app-id com.example.mobiletest \
  --ios-device booted \
  --ios-shim ./.zmr/ios-shim \
  --runs 20 \
  --min-pass-rate 100 \
  --max-failures 0 \
  --evidence-out traces/zmr-pilots/evidence.jsonl
```

Publish reliability claims only from sanitized, app-agnostic summaries. Keep
private scenarios and raw traces in the private app repository.
