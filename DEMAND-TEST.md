# ZMR Demand Test — go/no-go by 15 August 2026

**Status:** running. Started 21 July 2026. Decision date **15 August 2026**.

This file is the test. If it isn't committed, the test doesn't exist — the last
copy of this document was written on 20 July, never committed, and was gone
within a day. Commit every edit.

---

## Why this file exists

`../IDEAS.md` holds the standing rule: **nothing new gets built until this test
finishes.** The rule exists because there are 60 project directories on this
machine and six finished products nobody uses.

The month of 21 June – 21 July produced 49 commits on ZMR and zero users. That
is the failure mode this test is designed to catch. Building is not testing.

---

## What is being tested

**The product exactly as it ships today: `zeno-mobile-runner@0.2.17`.**

Not a future version. Specifically **not** `zmr diff` — that command does not
exist in the tree (verified 21 July 2026: no `diff` handler in `src/` or
`npm/commands.mjs`). It may be the eventual moat, but you cannot demand-test a
feature you haven't written. If the current loop can't get three people to care,
a new command won't fix that.

The claim under test:

> An AI coding agent working on an Expo/React Native app needs a way to *see* the
> screen, *act* on native UI, and *prove* the result. ZMR is that, locally, in one
> binary, with a replayable trace.

Either developers building with agents feel that pain and adopt this, or they
don't.

---

## The metric

**What counts: named humans who ran ZMR against their own app.**

| Signal | Counts? |
|---|---|
| A named developer installed ZMR and ran it against **their own** app | ✅ Yes |
| They reported a specific result — worked, or failed at step X | ✅ Yes |
| They came back a second week, unprompted | ✅ Strong yes |
| They asked when something ships, or said they'd be disappointed to lose it | ✅ Strongest |
| npm downloads | ❌ No |
| GitHub stars | ❌ No |
| Anything you ran yourself | ❌ No |

**Why downloads don't count:** ZMR did 1,736 downloads last month but only **75
last week** (checked 21 July 2026). At that level it is overwhelmingly registry
mirrors and CI, not people. Downloads have never once told you whether a human
cared.

---

## Go / no-go on 15 August 2026

**GO — keep investing.** ≥3 external developers ran ZMR against their own app,
**and** ≥1 gave a strong signal (returned unprompted, asked for a feature, or
said they'd miss it). → Continue, and `zmr diff` becomes the next build with a
real user asking for it.

**WEAK — one more cycle, different channel.** 1–2 people ran it and the feedback
was real but thin. → The product may be fine and the distribution wrong. One more
4-week cycle, new channel, same bar. **Maximum one extension.** Not two.

**NO-GO — stop.** Nobody outside you ran it against their own app. → ZMR is
archived as a portfolio artifact and a systems write-up. It stays honest work and
good Staff evidence for the engineering, but it stops receiving build time. Then
pick **one** of the six finished products in `../IDEAS.md` and finish it properly.

Write the outcome at the bottom of this file on 15 August. In your own words.
Whichever way it goes.

---

## The pitch (say it in two sentences)

> If you're using Claude Code or Cursor to build an Expo app, the agent is
> flying blind — it changes code and can't see whether the screen still works.
> ZMR is one local binary that lets the agent drive a real simulator and hands
> back a trace proving what happened.

Then: *"Would you try it on your app this week? I'll help you get it running."*

Do not pitch the roadmap. Pitch what runs today.

---

## Why not the alternatives

Be honest in every conversation. The dishonest version gets found out and costs
you the user.

| | ZMR | mobile-mcp | Maestro | Callstack agent-device |
|---|---|---|---|---|
| Drives real iOS + Android | ✅ | ✅ | ✅ | ✅ |
| Built for agents, no LLM embedded | ✅ | ✅ | ⚠️ agent bolted on | ✅ |
| Replayable trace evidence bundle | ✅ | ❌ | ⚠️ screenshots | ⚠️ traces |
| Exploration → committed CI scenario | ✅ | ❌ | ✅ | ⚠️ |
| Adoption | ~0 | ~22.6k/wk | large | Callstack-backed |
| Typed structural trace diff | ❌ *not built* | ❌ | ❌ | ❌ |

**Read that table honestly.** Your genuine edge today is the evidence bundle plus
the exploration→scenario loop. The last row is empty for everyone including you,
which is the opportunity — but it is not a current selling point, so don't sell
it. Your weakest column is adoption, which is exactly what this test addresses.

---

## The four weeks

**Zero feature commits until 15 August.** Docs to support adoption are allowed.
New capability is not. `zmr diff` is not exempt. Zeno Cloud is not exempt.

- **Week 1 (21–27 Jul) — record the demo video.**
  The storyboard is at `docs/demo-video-storyboard.md`, the recorder is at
  `scripts/record-demo-video.sh`. Both have existed for six weeks. No video has
  ever been recorded — no `.mp4`, `.gif` or `.webm` in the tree. For a visual
  verification tool this is the single highest-leverage asset that does not
  exist. 90 seconds: pass → break → explain → fix → pass.

- **Week 2 (28 Jul – 3 Aug) — publish.**
  Show HN. r/reactnative. Expo Discord. MCP registries (`glama.json` is ready).
  The Claude Code plugin marketplace is already live in this repo — use it.
  Video first in every post.

- **Week 3 (4–10 Aug) — direct outreach.**
  Ten named people, one at a time, not broadcast. Solo devs and small teams
  shipping Expo apps with Claude Code or Cursor. Offer to pair on setup. One
  conversation beats fifty impressions.

- **Week 4 (11–15 Aug) — count and decide.**
  Fill in the tally. Make the call. Write it down.

---

## Tally — external developers who ran ZMR on their own app

Add a row the moment someone runs it. Empty is a valid, informative result.

| Date | Who | Their app | Ran it? | Signal | Notes |
|---|---|---|---|---|---|
| | | | | | |

---

## Outcome — write this on 15 August 2026

_(unwritten)_
