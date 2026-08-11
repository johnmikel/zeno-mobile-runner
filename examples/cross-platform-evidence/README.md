# One evidence contract over web and mobile

A worked example, not a diagram. It runs a real Playwright suite and a real ZMR
mobile scenario, packages both under Evidence Contract v1, validates both with
the same command, and then changes one byte to show the validation is load-bearing.

```bash
bash examples/cross-platform-evidence/run-demo.sh
```

Actual output:

```
=== 1/4  web: a real Playwright run, Zeno attached as a reporter ===
  ✓  1 checkout.spec.mjs:9:1 › a shopper can complete checkout (135ms)
  1 passed (949ms)

=== 2/4  mobile: a real ZMR scenario, converted to the same evidence format ===

=== 3/4  one gate over both: same command, same contract ===
  ok  web/evidence.json
  ok  mobile/evidence.json

=== 4/4  tamper check: change one byte and the package stops validating ===
  rejected after a 1-byte change to a586e1b290566c7cdcc959ad9153de770b813390526ed0e8e9627aaea581c1
```

Both manifests declare contract `1.0`. They differ only where they should:

| | web | mobile |
|---|---|---|
| `target.surface` | `web` | `android` |
| `target.fingerprintRecipe` | `web-v1` | `mobile-v1` |
| produced by | Playwright + Zeno reporter | `zmr run` + `zmr-evidence from-zmr` |
| validated by | `zmr-evidence validate` | `zmr-evidence validate` |

## What the example is actually claiming

That last row is the whole point. A merge gate over both suites is a loop with no
branch on platform:

```yaml
- name: Verify evidence
  run: |
    for manifest in evidence/*/evidence.json; do
      npx zmr-evidence validate "$manifest"
    done
```

Screenshots and JUnit XML cannot back a gate like this, because nothing about
them resists editing. Step 4 is what separates the two: appending a single byte
to one artifact makes the package stop validating, so "the tests passed" becomes
a statement someone else can check from the bytes alone.

## What is real here and what is not

Being precise, because a demo that overstates itself is worth less than none:

- **Real.** The Playwright run, its screenshots and trace, the ZMR scenario run,
  every SHA-256 digest, both fingerprints, and the tamper rejection.
- **Not real.** The mobile run drives ZMR's fake device rather than an emulator,
  so `--app-artifact` points at a stand-in file instead of an `.apk`. Its digest
  is genuinely computed — it just describes a placeholder. Point the flag at your
  real build and nothing else about the command changes.
- **Not claimed.** Passing evidence says a run happened and its bytes are intact.
  It does not say the tests were good ones.

## Adopting it

The web half needs no test changes at all — `checkout.spec.mjs` contains nothing
Zeno-specific. The only edit to a Playwright project is the reporter entry in
[playwright.config.mjs](playwright.config.mjs); its options are in
[zeno-reporter-options.mjs](zeno-reporter-options.mjs), kept in a separate module
so CI can construct the real reporter with them and catch drift before a reader does.

Requirements and the full option reference are in
[docs/evidence-contract.md](../../docs/evidence-contract.md).
