# 0001: Agent-First Runner Boundary

## Status

Accepted.

## Context

ZMR is intended for AI agents and deterministic automation, but embedding an
LLM inside the runner would make device control harder to test, version, and
secure. The runner needs a small, stable control surface that external agents,
scripts, and SDKs can consume.

## Decision

ZMR does not embed an LLM. Zig owns orchestration, device control,
JSON-RPC/session handling, scenario execution, wait/assertion logic, and trace
generation. External agents decide what to do next by reading structured
observations and calling typed actions.

The public agent contract is JSON-RPC over stdio or localhost TCP, plus
machine-readable CLI JSON and public schemas.

## Consequences

- The core runner remains deterministic and testable without model calls.
- Agents can be swapped without changing device adapters.
- Trace output records what happened at the protocol/action layer, which makes
  failures explainable without replaying model reasoning.
- Higher-level planning, natural-language test generation, and app-specific
  heuristics belong in external clients or app-local `.zmr/` assets.
