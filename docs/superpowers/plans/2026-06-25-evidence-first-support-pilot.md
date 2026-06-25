# Evidence-First Support Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an app-team support evidence kit that generates the matrix, command checklist, and review artifacts needed to prove Android, iPhone, and iPad support claims.

**Architecture:** Keep the existing pilot runners as the execution layer. Add a focused generator script that writes support-evidence templates, then document how teams run those templates through `zmr-device-matrix` and `zmr-pilot-gate`.

**Tech Stack:** Bash, Python stdlib JSON generation, existing shell tests, npm package metadata, Markdown docs.

---

### Task 1: Support Evidence Kit Generator

**Files:**
- Create: `scripts/support-evidence-kit.sh`
- Create: `tests/support-evidence-kit-test.sh`

- [x] **Step 1: Write the failing test**

Test that `scripts/support-evidence-kit.sh --out <dir> --app-id <id> --android-scenario <path> --ios-scenario <path>` writes:
- `device-matrix.template.json`
- `pilot-commands.md`
- `support-claim-checklist.md`
- `README.md`

Expected assertions:
- Matrix includes Android emulator, Android physical, iPhone simulator, iPad simulator, iPhone physical, and iPad physical rows.
- iPad rows use `iosDeviceType: simulator` or `physical` and keep tablet evidence separate from iPhone evidence.
- Commands include 20-run gates, zero-failure thresholds, redacted-trace guidance, and existing scripts rather than inventing a new runner path.

- [x] **Step 2: Run test to verify it fails**

Run: `bash tests/support-evidence-kit-test.sh`
Expected: FAIL because `scripts/support-evidence-kit.sh` does not exist.

- [x] **Step 3: Implement the generator**

Build a small Bash CLI with required `--out` and optional defaults:
- `--app-id`
- `--android-scenario`
- `--ios-scenario`
- `--android-app-root`
- `--ios-app-root`
- `--ios-app-path`
- `--android-apk`
- `--zmr-bin`

Generate deterministic files using Python `json.dump` for the matrix and here-doc Markdown for the command/checklist files.

- [x] **Step 4: Run test to verify it passes**

Run: `bash tests/support-evidence-kit-test.sh`
Expected: PASS.

### Task 2: Package And Documentation

**Files:**
- Modify: `package.json`
- Modify: `tests/docs-readiness-test.sh`
- Modify: `docs/support-matrix.md`
- Modify: `docs/production-readiness.md`
- Modify: `docs/ai-agents.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [x] **Step 1: Write failing packaging/docs assertions**

Extend docs/package tests to assert:
- package exposes `zmr-support-evidence`
- docs mention `zmr-support-evidence`
- support matrix points teams to the generated evidence kit before making iPad claims

- [x] **Step 2: Run tests to verify failure**

Run:
- `node --test tests/npm-package.test.mjs`
- `bash tests/docs-readiness-test.sh`

Expected: FAIL because the package bin/docs references do not exist yet.

- [x] **Step 3: Add bin entry and docs**

Add `zmr-support-evidence` to `package.json` and document the workflow:
- Generate evidence kit.
- Fill device serials and app paths.
- Run matrix/pilot gates.
- Attach redacted bundles and reports.
- Update support claims only after evidence passes.

- [x] **Step 4: Run tests to verify pass**

Run:
- `bash tests/support-evidence-kit-test.sh`
- `node --test tests/npm-package.test.mjs`
- `bash tests/docs-readiness-test.sh`

Expected: PASS.

### Task 3: Final Verification

**Files:**
- All changed files.

- [x] **Step 1: Run targeted gate**

Run:
- `bash tests/support-evidence-kit-test.sh`
- `bash tests/device-matrix-test.sh`
- `bash tests/pilot-gate-script-test.sh`
- `bash tests/docs-readiness-test.sh`
- `node --test tests/npm-package.test.mjs`

Expected: all pass.

- [x] **Step 2: Run full CI gate**

Run: `bash scripts/ci-gate.sh`
Expected: exit 0.

- [x] **Step 3: Commit**

```bash
git add scripts/support-evidence-kit.sh tests/support-evidence-kit-test.sh package.json README.md docs/support-matrix.md docs/production-readiness.md docs/ai-agents.md tests/docs-readiness-test.sh CHANGELOG.md docs/superpowers/plans/2026-06-25-evidence-first-support-pilot.md
git commit -m "feat: add support evidence pilot kit"
```
