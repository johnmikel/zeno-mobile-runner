# Releasing

Maintainer runbook for publishing a ZMR release. Nobody installing or using ZMR
needs this page — see [install.md](install.md) for that.

## Before tagging

Run the full gate and capture the real exit code. Do not pipe it: a pipeline's
exit status is the last command's, so `./scripts/release-gate.sh | tail` reports
success on a failing gate. That has shipped a broken tag before.

```bash
ZMR_KCOV_TIMEOUT_SECONDS=1800 ./scripts/release-gate.sh > /tmp/gate.log 2>&1; echo "EXIT=$?"
```

`EXIT=0` is the only acceptable result. `ci-gate.sh` is a subset and does not
substitute — it skips checks that only the release gate runs, including the
public metadata guard.

Coverage via kcov can exceed its default 300s limit on slower or loaded hosts,
which surfaces as exit `137` (SIGKILL) in `scripts/coverage.sh`. Raise
`ZMR_KCOV_TIMEOUT_SECONDS` rather than assuming a real failure.

Version consistency is enforced separately and is worth checking first:

```bash
ZMR_VERSION=<version> ./scripts/verify-release-version.sh
```

That compares `package.json` against `src/version.zig`. Other files carry the
version too — docs, client manifests, test fixtures — and the docs readiness
test covers those.

## Building the npm tarball

```bash
npm run pack:npm
```

That builds release binaries, copies them into `prebuilds/`, and runs `npm pack`
into `./dist/`.

## Trusted publishing (normal path)

Tagged GitHub releases publish through npm trusted publishing, not a long-lived
`NPM_TOKEN` secret. Configure the npm package trusted publisher before relying
on the tag workflow:

- Package: `zeno-mobile-runner`
- Provider: GitHub Actions
- Organization or user: `johnmikel`
- Repository: `zeno-mobile-runner`
- Workflow filename: `release.yml`
- Environment name: leave blank unless the release job also declares a GitHub
  deployment environment.
- Allowed actions: `npm publish`

The release workflow already requests `id-token: write`, builds the npm tarball
from the tag, attests the generated release artifacts, uploads the GitHub
release assets, verifies exactly one local npm tarball exists under `./dist/`,
and then publishes that tarball with public access.

Trusted publishing requires a current npm runtime. The tag workflow uses Node
24 so the npm CLI can exchange the GitHub Actions OIDC identity for publish
authorization.

With `npm@11.10.0` or newer, maintainers can also configure the same trust
relationship from an authenticated local shell:

```bash
npm trust list zeno-mobile-runner
npm trust github zeno-mobile-runner \
  --repo johnmikel/zeno-mobile-runner \
  --file release.yml \
  --allow-publish
```

If `npm trust` is not available, update npm or use the package settings page on
npmjs.com. A failed publish with `E404` for an existing package usually means
the trusted-publisher configuration is missing, points at a different GitHub
owner/repository/workflow filename, names an environment that the workflow does
not use, or does not allow `npm publish`.

## Manual publish with passkey or 2FA

Use trusted publishing for normal tagged releases. If you need to publish a
verified local tarball manually, authenticate first:

```bash
npm login --auth-type=web
npm whoami
```

The browser/passkey step must finish before publishing. If `npm whoami` returns
`E401 Unauthorized`, the local machine is not authenticated and `npm publish`
will fail.

Build and verify the package before publishing:

```bash
./scripts/ci-gate.sh
npm pack --dry-run --json
npm run pack:npm
```

Publish the generated tarball from `dist/`:

```bash
npm publish ./dist/zeno-mobile-runner-<version>.tgz --access public
```

If npm returns `EOTP`, the account or organization requires a TOTP-style
one-time password for this publish command. The browser/passkey login flow can
authenticate the local CLI session, but `npm publish` itself only accepts the
publish-time second factor through `--otp`. Prefer the tagged trusted-publishing
workflow for normal releases; otherwise enter the TOTP locally or use a granular
automation token configured to bypass 2FA. Do not send OTPs or tokens through
issue comments, chat, or commit history.

If npm returns `E403` with a two-factor authentication message, the account or
organization requires either a current interactive 2FA challenge or a granular
automation token configured to bypass 2FA. For local passkey accounts, rerun
`npm login --auth-type=web`, complete the passkey challenge in the browser, and
confirm `npm whoami` before retrying the same `npm publish` command.

## After publishing

Verify the published artifact rather than trusting the workflow's status:

```bash
npm view zeno-mobile-runner version
npm view zeno-mobile-runner@<version> bin --json
gh release view v<version> --json assets --jq '.assets[].name'
./install.sh --version <version> --dry-run
```

The `bin` check matters: a release whose docs describe a command the published
package does not expose is worse than a delayed release. Confirm the binary the
gate measured is the one you tagged — several scripts resolve `ZMR_BIN`, then
`PATH`, then `zig-out/bin/zmr`, so a stale copy earlier in `PATH` can be
benchmarked silently.

## Commit metadata

`scripts/public-metadata-guard.sh` scans branch, remote, and tag metadata and
fails the release gate on unwanted contributor identity strings. It scans local
tags too, so a stale local tag pointing at a pre-rewrite commit fails the gate
even when the published history is clean. Re-sync before assuming the worst:

```bash
git tag -d <tag> && git fetch origin --tags --force
```
