# Protocol Versioning

Use this page when changing scenario JSON, JSON-RPC, MCP-visible schemas, trace
schemas, or stable error codes. ZMR exposes two public automation surfaces:

- scenario JSON files consumed by `zmr run`
- JSON-RPC methods exposed by `zmr serve`

The current protocol version is a date string. Before `v1.0.0`, breaking
changes are allowed only when the protocol version and changelog are updated
together.
`runner.capabilities` exposes this policy in machine-readable form:

```json
{
  "protocol": {
    "version": "2026-04-28",
    "minimumCompatibleVersion": "2026-04-28",
    "stability": "dev-preview",
    "breakingChangePolicy": "version-and-changelog"
  }
}
```

Clients should continue reading the top-level `protocolVersion` field for older
servers, but new clients should prefer `protocol.version` and reject servers
older than `protocol.minimumCompatibleVersion` unless they intentionally support
that older shape.

## Compatibility Rules

- Adding optional fields is non-breaking.
- Adding new methods or actions is non-breaking when existing behavior remains.
- Removing fields, renaming fields, changing required params, or changing error
  codes is breaking.
- Native shim protocols are internal and not covered by the public compatibility
  promise until explicitly documented as stable.

## Test Requirements

Protocol changes must update:

- `docs/protocol.md`
- `schemas/`
- JSON-RPC or scenario parser tests
- `CHANGELOG.md`

## Governance

The protocol is reviewed as a product contract, not an implementation detail.
Any change to scenario JSON, JSON-RPC methods, stable error codes, trace
schemas, or `runner.capabilities` must call out compatibility impact in the
pull request or release notes.

Governance rules:

- Non-breaking additions may ship in the current protocol version when existing
  clients keep working unchanged.
- Breaking changes require a protocol version bump, changelog entry, fixture
  update, and migration note in `docs/protocol.md`.
- Removing a documented field or method requires a deprecation window unless
  the project is still before its first stable release and the changelog names
  the break explicitly.
- Client authors should be able to discover support from `runner.capabilities`
  without probing by failure.
- The protocol fixture files under `docs/protocol-fixtures/` are treated as
  golden examples for agent integrations and must stay deterministic.
