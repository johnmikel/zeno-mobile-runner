# Migrating From Maestro

Use `zmr import maestro` to move an existing Maestro smoke flow into a reviewed
ZMR JSON scenario. Treat this as a migration helper, not a permanent runtime
dependency.

```bash
zmr import maestro flows/login.yaml --out .zmr/login-smoke.json --json
zmr validate --json .zmr/login-smoke.json
zmr run .zmr/login-smoke.json --json --trace-dir traces/zmr-login-smoke
```

The JSON response includes a `compatibility` object that tells agents and CI
scripts what happened:

```json
{
  "ok": true,
  "format": "maestro",
  "compatibility": {
    "source": "maestro-yaml",
    "native": "zmr-json",
    "mode": "smoke-subset",
    "reviewRequired": true,
    "unsupportedCommandPolicy": "fail-fast"
  }
}
```

## Supported First Slice

The importer covers common smoke-flow commands:

- App lifecycle: `launchApp`, `stopApp`, `clearState`, `clearAppState`
- Actions: `tapOn`, `inputText`, `eraseText`, `hideKeyboard`, `openLink`,
  `back`, `pressBack`, `scrollUntilVisible`
- Assertions and waits: `assertVisible`, `assertNotVisible`,
  `waitUntilVisible`, `waitUntilNotVisible`, `waitForAnimationToEnd`
- Evidence: `takeScreenshot`

Unsupported commands fail the import instead of being guessed. That behavior is
intentional: a bad migration should stop at review time, not create a flaky CI
test.

## Recommended Migration Path

1. Start with one high-value smoke flow such as login, onboarding, checkout, or
   a critical deep link.
2. Run `zmr import maestro` and inspect the generated JSON.
3. Replace fragile text selectors with app-owned IDs or accessibility labels.
4. Run `zmr validate --json`.
5. Run the scenario locally and generate evidence:

   ```bash
   zmr run .zmr/login-smoke.json --json --trace-dir traces/zmr-login-smoke
   zmr explain --json traces/zmr-login-smoke
   zmr report traces/zmr-login-smoke --out traces/zmr-login-smoke/report.html --junit traces/zmr-login-smoke/junit.xml
   zmr export traces/zmr-login-smoke --out traces/zmr-login-smoke.zmrtrace --redact
   ```

6. Add a repeat-run gate before claiming reliability:

   ```bash
   zmr-benchmark --zmr .zmr/login-smoke.json --platform android --device emulator-5554 --runs 20 --trace-root traces/zmr-login-pilot --results traces/zmr-login-pilot/results.jsonl --replace --min-pass-rate 100 --max-failures 0
   ```

## What To Rewrite By Hand

Rewrite these Maestro patterns directly in ZMR JSON:

- `runFlow`, hooks, and reusable setup: keep the first ZMR migration explicit
  until sub-scenario support is proven for your suite.
- JavaScript/faker/HTTP setup: move data setup to the app test harness or CI
  script, then pass stable values into the scenario.
- AI assertions: convert to deterministic waits/assertions first. Optional AI
  analysis can annotate evidence later, but should not be the first pass/fail
  gate.
- Cloud-only configuration: use self-managed matrix scripts until a hosted ZMR
  cloud product exists.

## Review Checklist

- Scenario validates with `zmr validate --json`.
- Selectors prefer app-owned IDs, resource IDs, or accessibility identifiers.
- The trace contains screenshots, semantic snapshots, events, and report output.
- A redacted `.zmrtrace` can be shared without app-private data.
- Repeated runs meet the team's pass-rate and p95 duration gates.
