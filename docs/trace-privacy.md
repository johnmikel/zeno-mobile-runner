# Trace Privacy

ZMR traces are debugging artifacts. They can contain sensitive app state even
when scenario files are generic.

```mermaid
flowchart LR
    RUN["zmr run / live session"] --> DIR["Trace directory<br/>events.jsonl · screenshots ·<br/>UI trees · logs · timings"]
    DIR --> REPORT["zmr report<br/>report.html · junit.xml"]
    DIR --> EXPLAIN["zmr explain<br/>failure diagnosis"]
    DIR --> EXPORT["zmr export --redact<br/>.zmrtrace bundle"]
    EXPORT --> VIEWER["Static trace viewer<br/>or shared evidence"]
```

Raw trace directories may include:

- screenshots
- screen recordings
- UI hierarchy XML or JSON
- visible text and accessibility labels
- log windows
- app ids, package/activity names, and timing data
- action inputs

## Sharing Rules

- Disable unnecessary raw artifacts in `.zmr/config.json`:

  ```json
  {
    "schemaVersion": 1,
    "artifacts": {
      "screenshots": false,
      "hierarchy": false,
      "logs": false
    },
    "redaction": {
      "denylistText": ["customer dob", "internal token"],
      "denylistResourceIds": ["password-field", "ssn"],
      "allowlistResourceIds": ["public-token-label"]
    }
  }
  ```

- Add app-specific text and resource-id denylist rules for customer data,
  regulated identifiers, and internal identifiers that ZMR cannot infer.
- Share redacted `.zmrtrace` bundles, not raw trace directories.
- Use `zmr export <trace-dir> --out <bundle.zmrtrace> --redact`.
- Review redacted bundles before attaching them to public issues.
- Do not publish raw private app screenshots.
- Do not publish private app screen recordings.
- Do not publish logs containing credentials, tokens, emails, or customer data.

## Current Redaction Behavior

Persisted trace JSON scrubs obvious emails, bearer/JWT-like tokens, sensitive
JSON keys, app-configured denylisted text, and app-configured sensitive
resource ids. Resource-id denylist matches redact the id and force that node's
`text` and `contentDesc` to secret placeholders. App-specific allowlists only
skip app-specific denylist matches; built-in email/token scrubbing still
applies.

Redacted exports scrub common text secrets, replace PNG screenshots with safe
placeholder frames, and omit screen recordings. Add `--omit-screenshots` to
remove screenshot artifacts from the exported bundle entirely. Local trace
directories are not mutated by export.

Pixel-level screenshot masking is not implemented. Raw hierarchy XML can still
contain app text; disable hierarchy capture or review redacted bundles before
sharing them outside a trusted machine.

## Screenshot And XML Strategy

ZMR uses conservative artifact handling instead of partial visual masking:

- Redacted `.zmrtrace` exports replace PNG screenshot files with generated
  placeholder PNGs at the same artifact paths. This keeps trace replay frames
  stable without shipping rendered app pixels.
- `zmr export --redact --omit-screenshots` omits screenshot files entirely for
  teams that cannot share visual artifacts outside trusted machines.
- Redacted `.zmrtrace` exports omit screen recording files entirely. This avoids
  shipping unreliable video masking that could miss rendered secrets.
- Redacted exports scrub text-based artifacts, including JSON events, snapshot
  JSON, logs, reports, and XML-like hierarchy files, for common emails, bearer
  tokens, sensitive key names, and sensitive node attributes.
- App-specific `.zmr/config.json` redaction rules apply before trace files are
  written. Use them for private resource ids and business-specific text that
  generic scrubbing cannot identify.
- Set `artifacts.hierarchy: false` for apps whose raw accessibility trees are
  sensitive by default. Selector matching still uses the live tree; this only
  disables raw hierarchy persistence.
- Keep unredacted local trace directories on trusted developer machines only.

This strategy favors predictable placeholders, explicit visual omission, and
app-owned denylist rules over a best-effort screenshot masker. Pixel-level
masking can be added later as an opt-in exporter mode once it has visual
verification tests.
