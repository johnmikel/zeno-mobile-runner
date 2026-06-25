# Demo Video Storyboard

Raw footage comes from `scripts/record-demo-video.sh` (maintainer-only, not in
the npm package). It produces three simulator recordings, terminal transcripts
for every beat, traces, and redacted bundles from the generated public Expo demo
app, so the cut contains no private app references.

Target length: 90–120 seconds. Screen layout: terminal on the left, simulator
on the right (Screen Studio, ScreenFlow, or iMovie side-by-side).

## Beat 1 — The problem (0:00–0:12)

Static title over the simulator's idle home screen.

> Your coding agent can write mobile code. It cannot see the phone.

Show one line in the terminal:

```bash
npm install --save-dev zeno-mobile-runner && npx zmr-wizard --app-id com.example.mobiletest --package-json
```

## Beat 2 — The loop, green (0:12–0:40)

Play `segment-a-pass.mp4` at 1.5–2x. The simulator drives itself: welcome →
Continue → profile form fills ("Riley", email) → keyboard hides → save →
catalog → item detail → review screen.

Terminal shows the real run output from `terminal-a-pass.json` (pretty-print
the `ok/status/durationMs` fields, then the `nextCommands` block).

> One JSON scenario. ZMR taps, types, waits, asserts, and writes a trace.

## Beat 3 — Something breaks (0:40–1:05)

Cut to an editor for two seconds: the copy change (`Profile` → `Your
details` in App.tsx), framed as "a teammate ships a copy tweak".

Play `segment-b-fail.mp4`. The run stops on the renamed screen.

Terminal beat — the heart of the video — from `terminal-b-explain.txt`:

```text
status: failed
failedStepIndex: 3
error: WaitTimeout
diagnostic: wait.visible timeout
visibleTexts: Your details | Name | Email | Save profile | ...
nearestTextMatches: Your details (score ...) | ...
```

> The trace explains itself: the screen now says "Your details".
> No screenshots to squint at. No re-running with print statements.

## Beat 4 — The agent repairs it (1:05–1:25)

Show the one-line scenario edit (selector text `Profile` → `Your details`),
then play `segment-c-pass.mp4` at 2x straight to the review screen.

> An agent reads the same JSON and fixes the test itself.

## Beat 5 — Evidence (1:25–1:45)

Open `viewer/index.html?bundle=workflow-pass.zmrtrace` in a browser. Pan the
timeline, click the snapshot event, show the device screenshot + UI tree side
by side. Optionally flash `report.html` and `junit.xml` for the CI crowd.

> Every run ends with proof: screenshots, UI trees, timings, JUnit for CI,
> and a redacted bundle you can review or share.

## Beat 6 — Close (1:45–2:00)

Terminal types the MCP hookup:

```bash
claude mcp add zmr -- npx zmr mcp --config .zmr/config.json --trace-dir traces/zmr-agent
```

> Zeno Mobile Runner. Mobile verification for AI coding agents.
> npm install zeno-mobile-runner. MIT, runs on your machine.

## Production notes

- For the final take, uninstall + reinstall the app between segments so typed
  fields start empty (re-running against warm state appends text, e.g.
  "RileyRiley"); the pipeline script favors speed over cosmetic state.
- Record terminal beats by replaying the captured transcripts; every output in
  the cut must come from the real run artifacts in the footage directory.
- The simulator recordings are 1206×2622; crop to a device frame at 9:19.5.
- Keep the failure beat slow; it is the differentiator. Everything else can
  run at 1.5–2x.
- Music: low-key; cut hits on the pass→fail→pass transitions.
