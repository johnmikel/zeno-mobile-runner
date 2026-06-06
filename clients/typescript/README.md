# ZMR TypeScript Reference Client

Zero-dependency ESM client for ZMR's newline-delimited JSON-RPC protocol.

```js
import { createZmrClient } from "./index.mjs";

const zmr = createZmrClient({
  command: "zmr",
  args: [
    "serve",
    "--transport", "stdio",
    "--device", "emulator-5554",
    "--app-id", "com.example.mobiletest",
    "--trace-dir", "traces/agent-session",
  ],
});

try {
  await zmr.createSession();
  await zmr.openLink("exampleapp://e2e-auth?probe=1");
  await zmr.waitUntil({ text: "E2E auth probe" }, { timeoutMs: 30000 });
  const snapshot = await zmr.snapshot();
  const events = await zmr.traceEvents(0, { limit: 100 });
  const explanation = await zmr.explainTrace();
  const discovered = await zmr.discoverTrace(".zmr/discovered/agent-session.json", {
    includeActions: true,
    validate: true,
    force: true,
  });
  const explored = await zmr.exploreTrace(".zmr/discovered/agent-goal.json", "find a stable login smoke", {
    includeActions: true,
    validate: true,
    force: true,
  });
  const validation = await zmr.validateScenario(discovered.out);
  console.log(snapshot.nodes);
  console.log(events.events.length);
  console.log(explanation.status);
  console.log(discovered.out);
  console.log(explored.reviewRequired);
  console.log(validation.ok);
  await zmr.exportTrace("traces/agent-session-redacted.zmrtrace", { redact: true, omitScreenshots: true });
} finally {
  await zmr.close();
}
```

The runtime is plain JavaScript (`index.mjs`) with TypeScript declarations
(`index.d.ts`) so consumers can use it without a build step.
