# Agent surface: measured before and after

Date: 2026-08-07. Runner: `zmr` built from `feat/agent-surface`.
Method: drive `zmr mcp` over stdio against the Android fake-device harness
(`tests/fake-adb.sh`) and measure the actual bytes on the wire. Every figure
below is read from a real process, not estimated.

## MCP tool surface

| | Before | After |
|---|---|---|
| Tools exposed | 27 | 7 |
| `tools/list` payload | 8248 B | 4182 B (**49% smaller**) |

Reproduce:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' \
  | zmr mcp --platform android --device fake --adb ./tests/fake-adb.sh
```

The 27-tool surface had no way to run a scenario at all — `scenario_validate`
existed, but no executor — so an agent had to replay `tap` / `type` /
`wait_visible` one call at a time. Each call costs a round-trip and a slice of
the agent's context, and what it leaves behind is a chat transcript rather than
a committed test. `run_scenario` takes the whole scenario in one call, so the
artifact the agent produces is the same JSON that CI replays.

## Semantic snapshot payload

| | Full | Compact |
|---|---|---|
| Fixture (5 nodes, unit test) | 1997 B | 899 B (**54% smaller**) |
| Fake device (11 nodes, real binary) | 4929 B | 2017 B (**59% smaller**) |

Reproduce:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"semantic_snapshot","arguments":{"compact":true}}}\n' \
  | zmr mcp --platform android --device fake --adb ./tests/fake-adb.sh
```

The compact form states each abbreviation and each default once in a `uiSchema`
legend, then omits any attribute holding its default value and drops nodes an
agent cannot act on (zero-area, unlabelled layout scaffolding). The full form is
unchanged and remains the default — `compact: true` is opt-in.

## Scope and limits

- Both payload measurements come from a fake device harness, not a real app.
  Node counts on a real screen are larger, and the compact form's advantage
  grows with node count, since the legend is a fixed one-time cost. The honest
  claim is the direction and the order of magnitude, not the exact percentage on
  any particular app.
- The end-to-end call-count claim (snapshot → run → explain) is not measured
  here; it needs a real device run and belongs in a follow-up.
- `src/semantic_tests.zig` asserts a floor of 30% on the fixture, so the
  encoding has to keep earning the reduction as fields are added.
