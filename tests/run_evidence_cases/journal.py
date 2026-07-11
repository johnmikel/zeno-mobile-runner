"""Publication journal and crash-recovery cases."""

import time

from .support import *  # noqa: F401,F403


class TransactionRecoveryTests(StorageTestCase):
    def stop_process(self, process):
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()

    def wait_for_path(self, path, *processes, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return
            for process in processes:
                if process.poll() is not None:
                    stderr = process.stderr.read() if process.stderr else ""
                    self.fail(
                        f"child {process.pid} exited with {process.returncode}: {stderr}"
                    )
            time.sleep(0.01)
        self.fail(f"timed out waiting for {path.name}")

    def spawn_lock_holder(self, lock_path):
        code = """
import importlib.util
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with module._exclusive_lock(Path(sys.argv[2])):
    print("locked", flush=True)
    time.sleep(60)
"""
        process = subprocess.Popen(
            [sys.executable, "-c", code, str(MODULE_PATH), str(lock_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.stop_process, process)
        self.assertEqual(process.stdout.readline().strip(), "locked")
        return process

    def crash_initialization_before_journal_rename(
        self, index_path, root, context
    ):
        code = """
import importlib.util
import json
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_replace = module.os.replace

def pause_before_rename(source, destination):
    destination = Path(destination)
    if destination.parent.name == ".transactions" and destination.suffix == ".json":
        print(Path(source).name, flush=True)
        time.sleep(60)
    original_replace(source, destination)

module.os.replace = pause_before_rename
module._initialize_attempt(
    Path(sys.argv[2]), Path(sys.argv[3]), json.loads(sys.argv[4])
)
"""
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                code,
                str(MODULE_PATH),
                str(index_path),
                str(root),
                json.dumps(context),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.stop_process, process)
        temporary_name = process.stdout.readline().strip()
        self.assertTrue(temporary_name)
        os.kill(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        return root.parent.parent / ".transactions" / temporary_name

    def crash_lifecycle_before_target_replace(
        self,
        action,
        root,
        target_name,
        *,
        index_path=None,
        context=None,
    ):
        code = """
import importlib.util
import json
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_replace = module.os.replace

def pause_before_target_replace(source, destination):
    destination = Path(destination)
    if destination.name == sys.argv[6]:
        print(str(source), flush=True)
        time.sleep(60)
    original_replace(source, destination)

module.os.replace = pause_before_target_replace
if sys.argv[2] == "init":
    module._initialize_attempt(
        Path(sys.argv[3]), Path(sys.argv[4]), json.loads(sys.argv[5])
    )
else:
    module._finalize_attempt(Path(sys.argv[4]), "passed")
"""
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                code,
                str(MODULE_PATH),
                action,
                str(index_path or self.index_path),
                str(root),
                json.dumps(context or {}),
                target_name,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.stop_process, process)
        temporary_name = process.stdout.readline().strip()
        self.assertTrue(temporary_name)
        os.kill(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        return Path(temporary_name)

    def transaction_files(self, publication_root=None):
        publication_root = self.publication_root if publication_root is None else publication_root
        transaction_root = publication_root / ".transactions"
        if not transaction_root.exists():
            return []
        return sorted(transaction_root.iterdir())

    def checkpoint_failure(self, stage, position):
        state = {"failed": False}

        def fail_once(actual_stage, actual_position):
            if (
                not state["failed"]
                and actual_stage == stage
                and actual_position == position
            ):
                state["failed"] = True
                raise OSError(f"injected crash at {stage}/{position}")

        return mock.patch.object(
            journal_module,
            "_transaction_checkpoint",
            side_effect=fail_once,
            create=True,
        )

    def terminal_events(self, root, summary):
        return [
            event
            for event in self.read_events(root)
            if event["phase"] == summary["phase"]
            and event["status"] == summary["status"]
            and event.get("errorCode") == summary.get("errorCode")
        ]

    def transaction_target_paths(self, publication_root=None):
        journals = self.transaction_files(publication_root)
        self.assertEqual(len(journals), 1)
        return [
            target["path"]
            for target in self.read_json(journals[0])["targets"]
        ]

    def test_register_rolls_forward_after_prepare_and_target_faults(self):
        for case_number, (stage, position) in enumerate(
            (("prepared", -1), ("target", 0)), 1
        ):
            publication, index_path = self.new_publication()
            context = valid_context(
                runId=f"register-crash-{case_number}",
                executionId=f"register-execution-{case_number}",
            )
            root = publication / "attempts" / context["runId"]
            root.mkdir(parents=True)

            with self.subTest(stage=stage, position=position):
                with self.checkpoint_failure(stage, position):
                    with self.assertRaises(OSError):
                        run_evidence.register_attempt(index_path, root, context)

                self.assertEqual(
                    self.transaction_target_paths(publication),
                    ["attempt-index.json"],
                )
                recovered = run_evidence.register_attempt(index_path, root, context)
                self.assertEqual(recovered, self.read_json(index_path))
                registrations = [
                    attempt
                    for execution in recovered["executions"]
                    for attempt in execution["attempts"]
                    if attempt["runId"] == context["runId"]
                ]
                self.assertEqual(len(registrations), 1)
                self.assertEqual(self.transaction_files(publication), [])
                with self.assertRaisesRegex(ValueError, "already registered"):
                    run_evidence.register_attempt(index_path, root, context)

    def test_init_rolls_forward_after_prepare_and_every_target_position(self):
        fault_points = [("prepared", -1), *(('target', index) for index in range(3))]
        for case_number, (stage, position) in enumerate(fault_points, 1):
            context = valid_context(
                runId=f"init-crash-{case_number}",
                executionId=f"init-execution-{case_number}",
            )
            root = self.attempt_root(context["runId"])
            with self.subTest(stage=stage, position=position):
                with self.checkpoint_failure(stage, position):
                    with self.assertRaises(OSError):
                        run_evidence._initialize_attempt(
                            self.index_path, root, context
                        )
                self.assertEqual(len(self.transaction_files()), 1)
                self.assertEqual(
                    self.transaction_target_paths(),
                    [
                        f"attempts/{context['runId']}/run-context.json",
                        f"attempts/{context['runId']}/bootstrap-events.jsonl",
                        "attempt-index.json",
                    ],
                )

                recovered = run_evidence._initialize_attempt(
                    self.index_path, root, context
                )
                self.assertEqual(recovered["runId"], context["runId"])
                self.assertTrue((root / "commands").is_dir())
                self.assertEqual(
                    [(event["seq"], event["phase"], event["status"])
                     for event in self.read_events(root)],
                    [
                        (1, "evidence.init", "started"),
                        (2, "evidence.init", "passed"),
                    ],
                )
                index = self.read_json(self.index_path)
                registrations = [
                    attempt
                    for execution in index["executions"]
                    for attempt in execution["attempts"]
                    if attempt["runId"] == context["runId"]
                ]
                self.assertEqual(len(registrations), 1)
                self.assertEqual(self.transaction_files(), [])
                with self.assertRaises(FileExistsError):
                    run_evidence._initialize_attempt(
                        self.index_path, root, context
                    )

    def test_two_sibling_context_resolution_rolls_forward_every_target(self):
        fault_points = [("prepared", -1), *(('target', index) for index in range(3))]
        for case_number, (stage, position) in enumerate(fault_points, 1):
            execution_id = f"context-execution-{case_number}"
            first_context = valid_context(
                runId=f"context-{case_number}-1",
                executionId=execution_id,
                runtimeVersion=None,
            )
            first = self.attempt_root(first_context["runId"])
            run_evidence._initialize_attempt(
                self.index_path, first, first_context
            )
            second_context = valid_context(
                runId=f"context-{case_number}-2",
                executionId=execution_id,
                attempt=2,
                runtimeVersion=None,
            )
            second = self.attempt_root(second_context["runId"])
            run_evidence._initialize_attempt(
                self.index_path, second, second_context
            )

            with self.subTest(stage=stage, position=position):
                with self.checkpoint_failure(stage, position):
                    with self.assertRaises(OSError):
                        run_evidence.update_context(
                            second, {"runtimeVersion": "18.5"}
                        )
                self.assertEqual(len(self.transaction_files()), 1)
                self.assertEqual(
                    self.transaction_target_paths(),
                    [
                        f"attempts/{first.name}/run-context.json",
                        f"attempts/{second.name}/run-context.json",
                        "attempt-index.json",
                    ],
                )
                recovered = run_evidence.update_context(
                    second, {"runtimeVersion": "18.5"}
                )
                self.assertEqual(recovered["runtimeVersion"], "18.5")
                self.assertEqual(
                    self.read_json(first / "run-context.json")["runtimeVersion"],
                    "18.5",
                )
                self.assertEqual(
                    self.read_json(second / "run-context.json")["runtimeVersion"],
                    "18.5",
                )
                execution = next(
                    item
                    for item in self.read_json(self.index_path)["executions"]
                    if item["executionId"] == execution_id
                )
                self.assertEqual(
                    execution["comparabilityTuple"]["runtimeVersion"], "18.5"
                )
                self.assertEqual(self.transaction_files(), [])
                with self.assertRaises(ValueError):
                    run_evidence.update_context(
                        second, {"runtimeVersion": "18.5"}
                    )

    def test_valid_finalization_rolls_forward_without_duplicate_terminal_event(self):
        fault_points = [("prepared", -1), ("target", 0), ("target", 1)]
        for case_number, (stage, position) in enumerate(fault_points, 1):
            context = valid_context(
                runId=f"finalize-crash-{case_number}",
                executionId=f"finalize-execution-{case_number}",
            )
            root = self.attempt_root(context["runId"])
            run_evidence._initialize_attempt(self.index_path, root, context)
            with self.subTest(stage=stage, position=position):
                with self.checkpoint_failure(stage, position):
                    with self.assertRaises(OSError):
                        run_evidence._finalize_attempt(root, "passed")
                self.assertEqual(len(self.transaction_files()), 1)
                self.assertEqual(
                    self.transaction_target_paths(),
                    [
                        f"attempts/{root.name}/bootstrap-events.jsonl",
                        f"attempts/{root.name}/run-summary.json",
                    ],
                )
                if stage == "prepared":
                    errors = run_evidence.validate_bundle(root, secrets=[])
                    self.assertTrue(
                        any("pending transaction" in error for error in errors),
                        errors,
                    )
                summary = run_evidence._finalize_attempt(root, "passed")
                self.assertEqual(run_evidence.validate_summary(summary), [])
                self.assertEqual(len(self.terminal_events(root, summary)), 1)
                self.assertEqual(self.transaction_files(), [])
                with self.assertRaises(FileExistsError):
                    run_evidence._finalize_attempt(root, "passed")

    def test_invalid_fallback_rolls_forward_after_every_target_position(self):
        fault_points = [("prepared", -1), *(('target', index) for index in range(4))]
        for case_number, (stage, position) in enumerate(fault_points, 1):
            context = valid_context(
                runId=f"fallback-crash-{case_number}",
                executionId=f"fallback-execution-{case_number}",
            )
            root = self.attempt_root(context["runId"])
            run_evidence._initialize_attempt(self.index_path, root, context)
            context_path = root / "run-context.json"
            damaged = self.read_json(context_path)
            damaged["platform"] = "invalid-platform"
            context_path.write_text(json.dumps(damaged), encoding="utf-8")
            with self.subTest(stage=stage, position=position):
                with self.checkpoint_failure(stage, position):
                    with self.assertRaises(OSError):
                        run_evidence._finalize_attempt(root, "passed")
                self.assertEqual(len(self.transaction_files()), 1)
                self.assertEqual(
                    self.transaction_target_paths(),
                    [
                        f"attempts/{root.name}/run-summary.invalid.json",
                        f"attempts/{root.name}/run-summary.invalid.errors.json",
                        f"attempts/{root.name}/bootstrap-events.jsonl",
                        f"attempts/{root.name}/run-summary.json",
                    ],
                )
                summary = run_evidence._finalize_attempt(root, "passed")
                self.assertEqual(summary["errorCode"], "runner.evidence_invalid")
                self.assertEqual(run_evidence.validate_summary(summary), [])
                self.assertEqual(len(self.terminal_events(root, summary)), 1)
                self.assertTrue((root / "run-summary.invalid.json").is_file())
                self.assertTrue(
                    (root / "run-summary.invalid.errors.json").is_file()
                )
                self.assertEqual(self.transaction_files(), [])

    def test_summary_write_failure_recovers_identical_terminal_event(self):
        root = self.attempt_root("summary-write-crash")
        context = valid_context(
            runId=root.name, executionId="summary-write-execution"
        )
        run_evidence._initialize_attempt(self.index_path, root, context)
        original_write = safe_io_module._atomic_write_bytes
        state = {"failed": False}

        def fail_summary_once(path, content, mode=0o600):
            if Path(path).name == "run-summary.json" and not state["failed"]:
                state["failed"] = True
                raise OSError("injected summary write crash")
            return original_write(path, content, mode)

        with mock.patch.object(
            safe_io_module, "_atomic_write_bytes", side_effect=fail_summary_once
        ):
            with self.assertRaises(OSError):
                run_evidence._finalize_attempt(root, "passed")
        self.assertEqual(len(self.transaction_files()), 1)
        summary = run_evidence._finalize_attempt(root, "passed")
        self.assertEqual(len(self.terminal_events(root, summary)), 1)
        self.assertEqual(self.transaction_files(), [])

    def new_publication(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        publication = Path(temporary.name) / "publication"
        publication.mkdir()
        return publication, publication / "attempt-index.json"

    def prepare_crashed_init(self, publication, index_path, run_id):
        context = valid_context(runId=run_id, executionId=run_id + "-execution")
        root = publication / "attempts" / run_id
        with self.checkpoint_failure("prepared", -1):
            with self.assertRaises(OSError):
                run_evidence._initialize_attempt(index_path, root, context)
        journals = self.transaction_files(publication)
        self.assertEqual(len(journals), 1)
        return root, context, journals[0]

    def test_corrupt_hash_path_and_symlink_journals_block_recovery(self):
        corruptions = ("hash", "path", "symlink")
        for corruption in corruptions:
            publication, index_path = self.new_publication()
            root, context, journal_path = self.prepare_crashed_init(
                publication, index_path, "corrupt-" + corruption
            )
            if corruption == "symlink":
                outside = Path(publication.parent) / "outside-journal.json"
                outside.write_bytes(journal_path.read_bytes())
                journal_path.unlink()
                journal_path.symlink_to(outside)
            else:
                journal = self.read_json(journal_path)
                if corruption == "hash":
                    journal["targets"][0]["sha256"] = "sha256:" + "0" * 64
                else:
                    journal["targets"][0]["path"] = "../escape"
                journal_path.write_text(json.dumps(journal), encoding="utf-8")
            with self.subTest(corruption=corruption), self.assertRaises(ValueError):
                run_evidence._initialize_attempt(index_path, root, context)
            self.assertTrue(journal_path.exists() or journal_path.is_symlink())
            self.assertFalse((publication.parent / "escape").exists())

    def test_journal_is_retained_until_every_final_hash_verifies(self):
        publication, index_path = self.new_publication()
        root, context, journal_path = self.prepare_crashed_init(
            publication, index_path, "hash-verify"
        )
        journal = self.read_json(journal_path)
        first_target = publication / journal["targets"][0]["path"]
        state = {"corrupted": False}

        def corrupt_after_first(stage, position):
            if stage == "target" and position == 0 and not state["corrupted"]:
                state["corrupted"] = True
                first_target.write_bytes(b"corrupted-after-write")

        with mock.patch.object(
            journal_module,
            "_transaction_checkpoint",
            side_effect=corrupt_after_first,
            create=True,
        ):
            with self.assertRaises(ValueError):
                run_evidence._initialize_attempt(index_path, root, context)
        self.assertTrue(journal_path.exists())

        recovered = run_evidence._initialize_attempt(index_path, root, context)
        self.assertEqual(recovered["runId"], context["runId"])
        self.assertEqual(self.transaction_files(publication), [])

    @unittest.skipUnless(
        os.name == "posix" and hasattr(signal, "SIGKILL"),
        "requires POSIX process-death semantics",
    )
    def test_prepared_context_cannot_overwrite_concurrent_registration(self):
        first_context = valid_context(runtimeVersion=None)
        first_root = self.attempt_root(first_context["runId"])
        run_evidence._initialize_attempt(
            self.index_path, first_root, first_context
        )
        second_context = valid_context(
            runId="register-race-2", attempt=2, runtimeVersion=None
        )
        second_root = self.create_attempt_root(second_context["runId"])
        (second_root / "run-context.json").write_text(
            json.dumps(second_context), encoding="utf-8"
        )

        controls = Path(self.temporary.name) / "process-controls"
        controls.mkdir()
        register_ready = controls / "register-ready"
        register_resume = controls / "register-resume"
        context_started = controls / "context-started"
        registration_code = """
import importlib.util
import json
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ready = Path(sys.argv[5])
resume = Path(sys.argv[6])

def pause_after_recovery(original, label):
    def paused(publication_root):
        recovered = original(publication_root)
        temporary = ready.with_name(ready.name + ".tmp")
        temporary.write_text(label, encoding="utf-8")
        temporary.replace(ready)
        deadline = time.monotonic() + 10
        while not resume.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("registration resume signal timed out")
            time.sleep(0.01)
        return recovered
    return paused

module.lifecycle._recover_pending_transactions = pause_after_recovery(
    module.lifecycle._recover_pending_transactions, "public"
)
module.lifecycle._recover_pending_transactions_unlocked = pause_after_recovery(
    module.lifecycle._recover_pending_transactions_unlocked, "unlocked"
)
result = module.register_attempt(
    Path(sys.argv[2]), Path(sys.argv[3]), json.loads(sys.argv[4])
)
print(json.dumps(result), flush=True)
"""
        context_code = """
import importlib.util
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def crash_when_prepared(stage, position):
    if stage == "prepared" and position == -1:
        os._exit(42)

module.journal._transaction_checkpoint = crash_when_prepared
Path(sys.argv[3]).write_text("started", encoding="utf-8")
module.update_context(Path(sys.argv[2]), {"runtimeVersion": "18.5"})
raise SystemExit(99)
"""
        registration = subprocess.Popen(
            [
                sys.executable,
                "-c",
                registration_code,
                str(MODULE_PATH),
                str(self.index_path),
                str(second_root),
                json.dumps(second_context),
                str(register_ready),
                str(register_resume),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        context_process = None
        try:
            self.wait_for_path(register_ready, registration)
            paused_recovery = register_ready.read_text(encoding="utf-8")
            self.assertIn(paused_recovery, ("public", "unlocked"))
            context_process = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    context_code,
                    str(MODULE_PATH),
                    str(first_root),
                    str(context_started),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.wait_for_path(context_started, context_process)

            context_stderr = ""
            if paused_recovery == "public":
                self.assertEqual(context_process.wait(timeout=5), 42)
                context_stderr = context_process.stderr.read()
                self.assertEqual(len(self.transaction_files()), 1)
            else:
                self.assertIsNone(context_process.poll())

            register_resume.write_text("resume", encoding="utf-8")
            self.assertEqual(
                registration.wait(timeout=10),
                0,
                registration.stderr.read(),
            )
            if paused_recovery == "unlocked":
                self.assertEqual(context_process.wait(timeout=10), 42)
                context_stderr = context_process.stderr.read()
            self.assertEqual(context_process.returncode, 42, context_stderr)

            recovered = run_evidence._recover_pending_transactions(
                self.publication_root
            )
            self.assertEqual(len(recovered), 1)
            registered_run_ids = [
                attempt["runId"]
                for execution in self.read_json(self.index_path)["executions"]
                for attempt in execution["attempts"]
            ]
            self.assertIn(second_context["runId"], registered_run_ids)
        finally:
            register_resume.touch(exist_ok=True)
            if context_process is not None:
                self.stop_process(context_process)
            self.stop_process(registration)

    @unittest.skipUnless(
        os.name == "posix" and hasattr(signal, "SIGKILL"),
        "requires POSIX process-death semantics",
    )
    def test_live_holder_times_out_without_splitting_the_lock_inode(self):
        lock_path = self.publication_root / ".transactions.lock"
        holder = self.spawn_lock_holder(lock_path)
        locked_inode = lock_path.stat().st_ino
        contender_code = """
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    with module._exclusive_lock(Path(sys.argv[2]), timeout=0.2):
        pass
except TimeoutError:
    raise SystemExit(23)
"""
        contender = subprocess.run(
            [
                sys.executable,
                "-c",
                contender_code,
                str(MODULE_PATH),
                str(lock_path),
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(contender.returncode, 23, contender.stderr)
        self.assertIsNone(holder.poll())
        self.assertEqual(lock_path.stat().st_ino, locked_inode)

    @unittest.skipUnless(
        os.name == "posix" and hasattr(signal, "SIGKILL"),
        "requires POSIX process-death semantics",
    )
    def test_sigkill_releases_lock_and_next_process_recovers_pending_journal(self):
        root, context, _journal_path = self.prepare_crashed_init(
            self.publication_root, self.index_path, "process-death"
        )
        lock_path = self.publication_root / ".transactions.lock"
        holder = self.spawn_lock_holder(lock_path)
        locked_inode = lock_path.stat().st_ino
        os.kill(holder.pid, signal.SIGKILL)
        holder.wait(timeout=5)
        self.assertEqual(lock_path.stat().st_ino, locked_inode)

        recovered = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "init",
                "--root",
                str(root),
                "--context-json",
                json.dumps(context),
                "--index",
                str(self.index_path),
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(self.read_json(root / "run-context.json")["runId"], root.name)
        self.assertEqual(self.transaction_files(), [])
        self.assertEqual(lock_path.stat().st_ino, locked_inode)
        self.assertEqual(lock_path.stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(
        os.name == "posix" and hasattr(signal, "SIGKILL"),
        "requires POSIX process-death semantics",
    )
    def test_pre_rename_journal_temp_is_read_only_for_validation_then_cleaned(self):
        context = valid_context(
            runId="orphan-crash", executionId="orphan-crash-execution"
        )
        root = self.attempt_root(context["runId"])
        temporary_path = self.crash_initialization_before_journal_rename(
            self.index_path, root, context
        )
        self.assertTrue(temporary_path.is_file())
        self.assertEqual(temporary_path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(root.exists())

        errors = run_evidence.validate_bundle(root, secrets=[])
        self.assertTrue(any("transaction" in error for error in errors), errors)
        self.assertTrue(temporary_path.exists())

        stored = run_evidence._initialize_attempt(self.index_path, root, context)
        self.assertEqual(stored["runId"], context["runId"])
        self.assertFalse(temporary_path.exists())
        self.assertEqual(self.transaction_files(), [])

    def test_hostile_orphan_temp_near_matches_still_block_recovery(self):
        hostile_names = (
            "init-hostile-0123456789abcdef.json.abcdefgh.tmp",
            ".init-hostile-0123456789abcdef.json.abcdefg.tmp",
            ".init-hostile-0123456789abcdef.json.abcdefgh.tmp.extra",
        )
        for case_number, hostile_name in enumerate(hostile_names, 1):
            publication, index_path = self.new_publication()
            transaction_root = publication / ".transactions"
            transaction_root.mkdir(mode=0o700)
            hostile_path = transaction_root / hostile_name
            hostile_path.write_bytes(b"hostile")
            hostile_path.chmod(0o600)
            context = valid_context(
                runId=f"hostile-{case_number}",
                executionId=f"hostile-execution-{case_number}",
            )
            root = publication / "attempts" / context["runId"]
            with self.subTest(name=hostile_name), self.assertRaises(ValueError):
                run_evidence._initialize_attempt(index_path, root, context)
            self.assertTrue(hostile_path.exists())
            self.assertFalse(root.exists())

    @unittest.skipUnless(os.name == "posix", "requires POSIX file modes")
    def test_unsafe_exact_orphan_temp_entries_still_block_recovery(self):
        for case_number, kind in enumerate(("directory", "symlink", "mode"), 1):
            publication, index_path = self.new_publication()
            transaction_root = publication / ".transactions"
            transaction_root.mkdir(mode=0o700)
            entry = transaction_root / (
                f".init-unsafe-{case_number}-0123456789abcdef.json.abcdefgh.tmp"
            )
            if kind == "directory":
                entry.mkdir(mode=0o700)
            elif kind == "symlink":
                outside = publication.parent / f"outside-{case_number}"
                outside.write_bytes(b"outside")
                entry.symlink_to(outside)
            else:
                entry.write_bytes(b"unsafe mode")
                entry.chmod(0o644)
            context = valid_context(
                runId=f"unsafe-{case_number}",
                executionId=f"unsafe-execution-{case_number}",
            )
            root = publication / "attempts" / context["runId"]
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                run_evidence._initialize_attempt(index_path, root, context)
            self.assertTrue(entry.exists() or entry.is_symlink())
            self.assertFalse(root.exists())

    @unittest.skipUnless(
        os.name == "posix" and hasattr(signal, "SIGKILL"),
        "requires POSIX process-death semantics",
    )
    def test_sigkill_before_context_replace_cleans_target_temp_on_recovery(self):
        context = valid_context(
            runId="context-target-death",
            executionId="context-target-death-execution",
            artifacts={"trace": None, "report": None},
        )
        root = self.attempt_root(context["runId"])
        temporary_path = self.crash_lifecycle_before_target_replace(
            "init",
            root,
            "run-context.json",
            index_path=self.index_path,
            context=context,
        )
        self.assertTrue(temporary_path.is_file())
        self.assertEqual(len(self.transaction_files()), 1)

        stored = run_evidence._initialize_attempt(self.index_path, root, context)
        self.assertEqual(stored["runId"], context["runId"])
        self.assertFalse(temporary_path.exists())
        self.assertEqual(self.transaction_files(), [])
        run_evidence._finalize_attempt(root, "passed")
        self.assertEqual(run_evidence.validate_bundle(root, secrets=[]), [])

    @unittest.skipUnless(
        os.name == "posix" and hasattr(signal, "SIGKILL"),
        "requires POSIX process-death semantics",
    )
    def test_sigkill_before_summary_replace_cleans_target_temp_on_recovery(self):
        context = valid_context(
            runId="summary-target-death",
            executionId="summary-target-death-execution",
            artifacts={"trace": None, "report": None},
        )
        root = self.attempt_root(context["runId"])
        run_evidence._initialize_attempt(self.index_path, root, context)
        temporary_path = self.crash_lifecycle_before_target_replace(
            "finalize", root, "run-summary.json"
        )
        self.assertTrue(temporary_path.is_file())
        self.assertEqual(len(self.transaction_files()), 1)

        summary = run_evidence._finalize_attempt(root, "passed")
        self.assertFalse(temporary_path.exists())
        self.assertEqual(len(self.terminal_events(root, summary)), 1)
        self.assertEqual(run_evidence.validate_bundle(root, secrets=[]), [])

    def test_hostile_target_temps_block_recovery_without_deletion(self):
        for case_number, kind in enumerate(
            ("mode", "directory", "symlink", "near-match", "missing-dot"), 1
        ):
            publication, index_path = self.new_publication()
            root, context, journal_path = self.prepare_crashed_init(
                publication, index_path, f"target-hostile-{case_number}"
            )
            root.mkdir(parents=True)
            if kind == "near-match":
                name = ".run-context.json.abcdefg.tmp"
            elif kind == "missing-dot":
                name = "run-context.json.abcdefgh.tmp"
            else:
                name = ".run-context.json.abcdefgh.tmp"
            entry = root / name
            if kind == "directory":
                entry.mkdir(mode=0o700)
            elif kind == "symlink":
                outside = publication.parent / f"target-outside-{case_number}"
                outside.write_bytes(b"outside")
                entry.symlink_to(outside)
            else:
                entry.write_bytes(b"hostile target temporary")
                entry.chmod(0o644 if kind == "mode" else 0o600)

            with self.subTest(kind=kind):
                with self.assertRaises(ValueError):
                    run_evidence._initialize_attempt(index_path, root, context)
                self.assertTrue(entry.exists() or entry.is_symlink())
                self.assertTrue(journal_path.exists())
                self.assertFalse((root / "run-context.json").exists())

    def test_bundle_rejects_leftover_atomic_target_temp_without_deleting_it(self):
        context = valid_context(
            runId="bundle-target-temp",
            executionId="bundle-target-temp-execution",
            artifacts={"trace": None, "report": None},
        )
        root = self.attempt_root(context["runId"])
        run_evidence._initialize_attempt(self.index_path, root, context)
        run_evidence._finalize_attempt(root, "passed")
        self.assertEqual(run_evidence.validate_bundle(root, secrets=[]), [])

        temporary_path = root / "commands" / ".leftover.log.abcdefgh.tmp"
        temporary_path.write_bytes(b"leftover but otherwise publishable")
        temporary_path.chmod(0o600)
        errors = run_evidence.validate_bundle(root, secrets=[])
        self.assertTrue(
            any("atomic-write temporary" in error for error in errors), errors
        )
        self.assertTrue(temporary_path.exists())
