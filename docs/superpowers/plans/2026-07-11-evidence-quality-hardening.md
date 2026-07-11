# Evidence Quality Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose the dependency-free run-evidence monolith without behavior change, then close the verified registration, retry, resource-bound, child-lifecycle, rooted-I/O, and bundle-validation findings with deterministic tests.

**Architecture:** `scripts/run_evidence.py` becomes a thin compatibility facade and executable wrapper over a standard-library-only `scripts/run_evidence_lib` package. Mutating operations share a POSIX rooted-I/O capability and the publication WAL; command capture streams through bounded collectors; bundle validation uses a separately bounded incremental reader. Existing imports, CLI behavior, schema parity, and private fault-injection seams remain testable through explicit re-exports.

**Tech Stack:** Python 3.10+ standard library, `unittest`, POSIX `dir_fd`/`O_NOFOLLOW`, `fcntl.flock`, JSON Schema contract tests in Node.

---

## File map

Production modules after Phase A:

- `scripts/run_evidence.py` — executable compatibility facade only.
- `scripts/run_evidence_lib/constants.py` — public vocabularies and limits.
- `scripts/run_evidence_lib/contracts.py` — comparability, classification, manual event/summary validators.
- `scripts/run_evidence_lib/sanitization.py` — secret/path/argv sanitization and later streaming sanitization.
- `scripts/run_evidence_lib/safe_io.py` — time, canonical JSON, atomic files, locks, and later rooted fd-relative I/O.
- `scripts/run_evidence_lib/journal.py` — WAL schema, preparation, validation, replay, and fault checkpoints.
- `scripts/run_evidence_lib/lifecycle.py` — attempt index, context, events, initialization.
- `scripts/run_evidence_lib/summaries.py` — summary construction and finalization.
- `scripts/run_evidence_lib/commands.py` — subprocess and external-command evidence.
- `scripts/run_evidence_lib/bundle.py` — bundle validation and safety scanning.
- `scripts/run_evidence_lib/aggregate.py` — summary aggregation.
- `scripts/run_evidence_lib/cli.py` — parser, dispatch, and `main`.
- `scripts/run_evidence_lib/__init__.py` — intentional public and compatibility re-exports.

Tests after Phase A:

- `tests/run_evidence_test.py` — lightweight `load_tests` aggregator.
- `tests/run_evidence_cases/support.py` — module loader, factories, subprocess helpers, storage fixtures.
- `tests/run_evidence_cases/contracts.py`
- `tests/run_evidence_cases/lifecycle.py`
- `tests/run_evidence_cases/journal.py`
- `tests/run_evidence_cases/sanitization.py`
- `tests/run_evidence_cases/commands.py`
- `tests/run_evidence_cases/bundle.py`
- `tests/run_evidence_cases/cli.py`

## Phase A: behavior-preserving decomposition

### Task A1: Freeze compatibility surface

**Files:**
- Modify: `tests/run_evidence_test.py`
- Create: `tests/run_evidence_cases/support.py`

- [ ] Record the baseline command and count: `python3 -W error -m unittest tests/run_evidence_test.py` must report 86 passing tests.
- [ ] In shared support, load the facade from `scripts/run_evidence.py` exactly as current external callers do.
- [ ] Preserve direct names used by tests: `PHASES`, `COMPARABILITY_FIELDS`, `ERROR_CLASSIFICATION`, public validators/lifecycle functions, `_atomic_write_bytes`, `_transaction_checkpoint`, `_bounded_log`, `os`, and `main`.
- [ ] Do not add a behavior expectation in Phase A; every moved test must pass before and after its move.

### Task A2: Extract constants, contracts, and sanitization

**Files:**
- Create: `scripts/run_evidence_lib/{constants,contracts,sanitization}.py`
- Modify: `scripts/run_evidence.py`

- [ ] Move definitions without rewriting bodies.
- [ ] Keep dependencies one-way: `constants -> contracts`; `constants -> sanitization`; contracts must not import lifecycle or I/O.
- [ ] Re-export the existing names from `scripts/run_evidence_lib/__init__.py` and the facade.
- [ ] Run contract, classification, validation, and sanitization cases after each move.

### Task A3: Extract safe I/O and WAL

**Files:**
- Create: `scripts/run_evidence_lib/{safe_io,journal}.py`
- Modify: `scripts/run_evidence.py`
- Move tests to: `tests/run_evidence_cases/journal.py`

- [ ] Move canonical JSON, fsync, atomic-write, advisory-lock, journal validation/replay, and temp cleanup bodies unchanged.
- [ ] Keep `_transaction_checkpoint` in `journal.py`; update tests to patch that owning module.
- [ ] Keep atomic-write fault tests patching `safe_io._atomic_write_bytes` or an explicit injected hook, not a disconnected facade binding.
- [ ] Run all 16 transaction-recovery tests.

### Task A4: Extract lifecycle and summaries

**Files:**
- Create: `scripts/run_evidence_lib/{lifecycle,summaries}.py`
- Move tests to: `tests/run_evidence_cases/lifecycle.py`

- [ ] Move index/context/event/init functions to lifecycle.
- [ ] Move summary/fallback/finalize functions to summaries.
- [ ] Break the dependency cycle with narrow callbacks or late imports only at operation boundaries; never import the package facade from a library module.
- [ ] Preserve transaction -> index -> attempt-local lock order.
- [ ] Run lifecycle and journal suites.

### Task A5: Extract commands, bundle, aggregate, and CLI

**Files:**
- Create: `scripts/run_evidence_lib/{commands,bundle,aggregate,cli,__init__}.py`
- Replace: `scripts/run_evidence.py`
- Move tests to: `tests/run_evidence_cases/{commands,bundle,cli}.py`

- [ ] Move bodies unchanged and keep `scripts/run_evidence.py` limited to package re-exports plus `raise SystemExit(main())`.
- [ ] Preserve CLI exit codes and JSON/stderr bytes.
- [ ] Implement the aggregator:

```python
def load_tests(loader, _tests, _pattern):
    suite = unittest.TestSuite()
    for module in CASE_MODULES:
        suite.addTests(loader.loadTestsFromModule(module))
    return suite
```

- [ ] Verify exactly 86 tests, with no duplicate discovery.

### Task A6: Compile package recursively and commit pure refactor

**Files:**
- Modify: `scripts/ci-gate.sh`
- Modify: `tests/ci-gate-script-test.sh`

- [ ] Change the Python compile gate to include `python3 -m compileall -q scripts/run_evidence_lib scripts/run_evidence.py`.
- [ ] Verify `bash scripts/ci-gate.sh --dry-run` emits that command.
- [ ] Run all required Phase A gates and `git diff --check`.
- [ ] Confirm production modules are focused and preferably below 700 lines.
- [ ] Commit exactly as `refactor(evidence): decompose evidence core`.

## Phase B: TDD behavior clusters

### Task B1: Journal public registration

**Files:**
- Modify: `scripts/run_evidence_lib/{journal,lifecycle}.py`
- Modify: `tests/run_evidence_cases/{journal,lifecycle}.py`

- [ ] RED: prepare a context journal containing an old index, interleave a new public registration in another process, then recover; prove the old implementation loses or races the registration.
- [ ] Add WAL operation `register` with the normalized attempt root and index-only target.
- [ ] `register_attempt` must hold publication transaction lock across recovery, index locking, journal preparation, and replay.
- [ ] A retry of the same prepared registration returns the recovered index; duplicates without a matching pending operation retain existing duplicate semantics.
- [ ] GREEN: run the concurrency test at least three times and all journal/lifecycle tests.

### Task B2: Make context/finalize retries request-safe

**Files:**
- Modify: `scripts/run_evidence_lib/{lifecycle,summaries,cli}.py`
- Modify: `tests/run_evidence_cases/{lifecycle,cli,journal}.py`

- [ ] RED: after recovering a pending context patch, submit a different patch and prove it is lost; repeat an identical patch and prove it errors.
- [ ] Remove the recovered-result early return from `update_context`; always recover, reload, and evaluate the current request.
- [ ] Return current context when the patch is already fully applied.
- [ ] RED: crash CLI finalize after the trace/report context phase, retry the identical command, and prove current CLI exits 2 without final summary.
- [ ] Make the artifact phase idempotent or fold it into finalization; retry must create/return one summary and one terminal event.
- [ ] GREEN: repeat retry regressions at least three times.

### Task B3: Bound command I/O

**Files:**
- Modify: `scripts/run_evidence_lib/{constants,sanitization,commands}.py`
- Modify: `tests/run_evidence_cases/commands.py`

- [ ] RED: child emits at least 256 MiB combined output under `resource.setrlimit(RLIMIT_AS, ...)`; current `communicate()` must fail or exceed the bound.
- [ ] RED: split secrets, roots, credential URLs, and invalid UTF-8 across reader chunk boundaries.
- [ ] Add named constants for pipe chunk size, sanitization carry, and 10 MiB stored-log bound.
- [ ] Replace `communicate()` with one concurrent chunk reader per pipe and a bounded head/tail collector:

```python
class BoundedHeadTail:
    def feed(self, chunk: bytes) -> None: ...
    def finish(self) -> tuple[bytes, int, bool]: ...
```

- [ ] Keep exact raw byte counts. Persist and replay only sanitized bounded bytes.
- [ ] For capture-stdout, write raw stdout chunks directly to the caller while retaining no raw copy.
- [ ] Use no unbounded raw spool file.
- [ ] GREEN: repeat stress/boundary tests three times.

### Task B4: Own and terminate the child process group

**Files:**
- Modify: `scripts/run_evidence_lib/commands.py`
- Modify: `tests/run_evidence_cases/commands.py`

- [ ] RED: send SIGINT and SIGTERM only to the wrapper; prove child/grandchild survives and event stream is started-only.
- [ ] Start POSIX children in a new session/process group.
- [ ] During command execution, install bounded local signal forwarding: forward the same signal to the group, wait the named grace interval, then SIGKILL the group if needed.
- [ ] Always drain readers and reap the child before returning.
- [ ] Atomically persist logs/metadata and append exactly one cancelled terminal event.
- [ ] Return shell-compatible 130/143 from CLI.
- [ ] GREEN: assert no surviving PIDs and repeat both signal tests three times.

### Task B5: Anchor all mutation with POSIX rooted descriptors

**Files:**
- Modify: `scripts/run_evidence_lib/{constants,safe_io,journal,lifecycle,summaries,commands}.py`
- Modify: all mutation-focused case modules.

- [ ] RED: at deterministic I/O hooks, swap a previously checked publication/attempt directory for an external symlink; prove current path-based code reads or writes outside.
- [ ] Add public `MINIMUM_PYTHON`, mutation-capability, and platform-support constants.
- [ ] Reject mutating evidence operations unless POSIX `dir_fd`, `O_DIRECTORY`, and `O_NOFOLLOW` capabilities are present.
- [ ] Remove the partial `msvcrt` mutation-lock branch.
- [ ] Implement a trusted rooted directory abstraction that stores root `(st_dev, st_ino)` and uses close-on-exec descriptors for traversal, stat, mkdir, open, atomic replace, and unlink.
- [ ] Convert evidence reads/writes/locks to descriptor-relative operations; never fall back to checked absolute paths.
- [ ] Revalidate root identity at operation boundaries and before commit-marker deletion.
- [ ] Add CLI capability/help text, while preserving schema vocabulary parity.
- [ ] GREEN: external target remains untouched and operations fail explicitly in every swap test.

### Task B6: Bound bundle validation

**Files:**
- Modify: `scripts/run_evidence_lib/{constants,bundle,sanitization,safe_io}.py`
- Modify: `tests/run_evidence_cases/bundle.py`

- [ ] RED: large binary and extensionless artifacts, too many files, oversized JSONL lines, and split deny patterns exhaust or evade current scanning.
- [ ] Publish named limits for maximum files, total scanned bytes, structured JSON bytes, and JSONL line bytes.
- [ ] Walk with an incremental `os.scandir` stack and deterministic limit accounting; do not materialize the full tree.
- [ ] Stream regular-file safety detection with bounded carry and do not decode/parse full trace/report artifacts.
- [ ] Read structured JSON only through a bounded helper; stream JSONL lines with an explicit line limit.
- [ ] Fail deterministically when a bound is exceeded and keep error output sorted/deduplicated.
- [ ] GREEN: repeat memory stress three times and run all bundle tests.

### Task B7: Final verification and focused commits

- [ ] After each cluster run its RED/GREEN tests plus the 86+ aggregate suite.
- [ ] Run, on the final tree:

```bash
python3 -W error -m unittest tests/run_evidence_test.py
python3 -m compileall -q scripts/run_evidence_lib scripts/run_evidence.py
node --test tests/schemas-contract.test.mjs
bash tests/schemas-json-test.sh
bash scripts/ci-gate.sh --dry-run
bash tests/public-safety-test.sh
bash tests/public-metadata-guard-test.sh
git diff --check
```

- [ ] Repeat new stress/signal/concurrency cases at least three times.
- [ ] Report Phase A SHA, each cluster RED/GREEN evidence, behavior SHAs, module line counts, constants/resource bounds, POSIX/Python platform statement, and remaining concerns.
