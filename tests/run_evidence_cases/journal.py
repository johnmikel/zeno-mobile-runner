"""Publication journal and crash-recovery cases."""

import base64
import hashlib
import time
from datetime import datetime, timedelta

from .support import *  # noqa: F401,F403


class TransactionRecoveryTests(StorageTestCase):
    def test_request_fingerprint_enforces_exact_canonical_request_cap(self):
        self.assertEqual(
            run_evidence.MAX_TRANSACTION_REQUEST_BYTES, 4 * 1024 * 1024
        )
        root = self.attempt_root("fingerprint-boundary")
        request = {"value": "bounded"}
        payload = {
            "schemaVersion": 1,
            "operation": "finalize",
            "attemptRoot": f"attempts/{root.name}",
            "request": request,
        }
        exact_size = len(run_evidence._json_bytes(payload))

        with mock.patch.object(
            run_evidence.journal,
            "MAX_TRANSACTION_REQUEST_BYTES",
            exact_size,
            create=True,
        ):
            fingerprint = run_evidence._request_fingerprint(
                self.publication_root, "finalize", root, request
            )
        self.assertRegex(fingerprint, r"^sha256:[0-9a-f]{64}$")

        with mock.patch.object(
            run_evidence.journal,
            "MAX_TRANSACTION_REQUEST_BYTES",
            exact_size - 1,
            create=True,
        ), self.assertRaisesRegex(ValueError, "transaction request exceeds"):
            run_evidence._request_fingerprint(
                self.publication_root, "finalize", root, request
            )

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
def pause_before_rename(operation, phase, destination):
    destination = Path(destination)
    if (operation == "atomic_write" and phase == "before_replace"
            and destination.parent.name == ".transactions"
            and destination.suffix == ".json"):
        candidates = list(destination.parent.glob(f".{destination.name}.*.tmp"))
        print(candidates[0].name, flush=True)
        time.sleep(60)

module.safe_io._rooted_io_checkpoint = pause_before_rename
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
def pause_before_target_replace(operation, phase, destination):
    destination = Path(destination)
    if (operation == "atomic_write" and phase == "before_replace"
            and destination.name == sys.argv[6]):
        candidates = list(destination.parent.glob(f".{destination.name}.*.tmp"))
        print(str(candidates[0]), flush=True)
        time.sleep(60)

module.safe_io._rooted_io_checkpoint = pause_before_target_replace
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

    def crash_transaction_process(
        self,
        action,
        index_path,
        root,
        context,
        stage,
        position,
        *,
        finalize_request=None,
        expected_journal_count=1,
        journal_limits=None,
    ):
        code = """
import importlib.util
import json
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_child", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
stage = sys.argv[6]
position = int(sys.argv[7])
def die_at_boundary(actual_stage, actual_position):
    if actual_stage == stage and actual_position == position:
        os._exit(73)

module.journal._transaction_checkpoint = die_at_boundary
for name, value in json.loads(sys.argv[9]).items():
    setattr(module.journal, name, value)
action = sys.argv[2]
index_path = Path(sys.argv[3])
root = Path(sys.argv[4])
context = json.loads(sys.argv[5])
if action == "register":
    module.register_attempt(index_path, root, context)
elif action == "init":
    module._initialize_attempt(index_path, root, context)
else:
    request = json.loads(sys.argv[8])
    status = request.pop("status")
    module._finalize_attempt(root, status, **request)
"""
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                code,
                str(MODULE_PATH),
                action,
                str(index_path),
                str(root),
                json.dumps(context),
                stage,
                str(position),
                json.dumps(finalize_request or {"status": "passed"}),
                json.dumps(journal_limits or {}),
            ],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        journals = self.transaction_files(Path(index_path).parent)
        self.assertEqual(len(journals), expected_journal_count)
        return journals[0] if journals else None

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

    def rewrite_pending_finalize_as_distinct_clock_legacy(
        self, root, *, legacy_timestamp=None
    ):
        publication_root = root.parent.parent
        journals = self.transaction_files(publication_root)
        self.assertEqual(len(journals), 1)
        journal_path = journals[0]
        journal = self.read_json(journal_path)
        self.assertEqual(journal["operation"], "finalize")

        journal["targets"] = [
            target
            for target in journal["targets"]
            if not target["path"].endswith("/finalize-receipt.json")
        ]
        event_target = next(
            target
            for target in journal["targets"]
            if target["path"].endswith("/bootstrap-events.jsonl")
        )
        summary_target = next(
            target
            for target in journal["targets"]
            if target["path"].endswith("/run-summary.json")
        )
        summary = json.loads(
            base64.b64decode(summary_target["contentBase64"], validate=True)
        )
        summary.pop("finalizeRequestFingerprint", None)
        summary_content = run_evidence._json_bytes(summary)
        summary_target["contentBase64"] = base64.b64encode(
            summary_content
        ).decode("ascii")
        summary_target["sha256"] = (
            "sha256:" + hashlib.sha256(summary_content).hexdigest()
        )
        events = [
            json.loads(line)
            for line in base64.b64decode(
                event_target["contentBase64"], validate=True
            ).splitlines()
            if line.strip()
        ]
        finished_at = datetime.fromisoformat(
            summary["finishedAt"].replace("Z", "+00:00")
        )
        if legacy_timestamp is None:
            legacy_timestamp = (
                finished_at + timedelta(milliseconds=1)
            ).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        self.assertNotEqual(legacy_timestamp, summary["finishedAt"])
        events[-1]["timestamp"] = legacy_timestamp
        event_content = b"".join(
            run_evidence._json_bytes(event) for event in events
        )
        event_target["contentBase64"] = base64.b64encode(
            event_content
        ).decode("ascii")
        event_target["sha256"] = (
            "sha256:" + hashlib.sha256(event_content).hexdigest()
        )

        journal_bytes = run_evidence._json_bytes(journal)
        legacy_path = journal_path.with_name(
            f"finalize-{root.name}-"
            f"{hashlib.sha256(journal_bytes).hexdigest()[:16]}.json"
        )
        journal_path.unlink()
        legacy_path.write_bytes(journal_bytes)
        legacy_path.chmod(0o600)
        return journal, summary, legacy_timestamp

    def prepare_distinct_clock_legacy_finalize(
        self,
        root,
        *,
        fallback=False,
        request=None,
        legacy_timestamp=None,
    ):
        if fallback:
            context_path = root / "run-context.json"
            damaged = self.read_json(context_path)
            damaged["platform"] = "invalid-platform"
            context_path.write_text(json.dumps(damaged), encoding="utf-8")
        request = dict(request or {"status": "passed", "command_status": 0})
        status = request.pop("status")
        with self.checkpoint_failure("prepared", -1):
            with self.assertRaises(OSError):
                run_evidence._finalize_attempt(root, status, **request)
        return self.rewrite_pending_finalize_as_distinct_clock_legacy(
            root, legacy_timestamp=legacy_timestamp
        )

    def attempt_evidence_snapshot(self, root):
        return {
            path.relative_to(root).as_posix(): path.read_bytes()
            for path in sorted(root.rglob("*"))
            if path.is_file() and not path.name.endswith(".lock")
        }

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

    @unittest.skipUnless(
        os.name == "posix",
        "requires immediate POSIX process-death semantics",
    )
    def test_real_process_death_retries_are_bound_to_the_sanitized_request(self):
        cases = {
            "register": (("prepared", -1), ("target", 0)),
            "init": (
                ("prepared", -1),
                ("target", 0),
                ("target", 1),
                ("target", 2),
            ),
            "finalize": (
                ("prepared", -1),
                ("target", 0),
                ("target", 1),
                ("target", 2),
            ),
        }
        for retry_kind in ("identical", "mismatched"):
            for action, fault_points in cases.items():
                for case_number, (stage, position) in enumerate(fault_points, 1):
                    with self.subTest(
                        retry=retry_kind,
                        action=action,
                        stage=stage,
                        position=position,
                    ):
                        publication, index_path = self.new_publication()
                        run_id = (
                            f"request-{retry_kind}-{action}-{case_number}"
                        )
                        context = valid_context(
                            runId=run_id,
                            executionId=run_id + "-execution",
                            fixtureId="fixture-original",
                        )
                        root = publication / "attempts" / run_id
                        if action == "register":
                            root.mkdir(parents=True)
                        elif action == "finalize":
                            run_evidence._initialize_attempt(
                                index_path, root, context
                            )

                        journal_path = self.crash_transaction_process(
                            action,
                            index_path,
                            root,
                            context,
                            stage,
                            position,
                            finalize_request={
                                "status": "passed",
                                "command_status": 0,
                            },
                        )
                        journal = self.read_json(journal_path)
                        self.assertIn("requestFingerprint", journal)
                        self.assertRegex(
                            journal["requestFingerprint"],
                            r"^sha256:[0-9a-f]{64}$",
                        )

                        if retry_kind == "identical":
                            if action == "register":
                                result = run_evidence.register_attempt(
                                    index_path, root, context
                                )
                                self.assertEqual(
                                    result, self.read_json(index_path)
                                )
                            elif action == "init":
                                result = run_evidence._initialize_attempt(
                                    index_path, root, context
                                )
                                self.assertEqual(result["runId"], run_id)
                            else:
                                result = run_evidence._finalize_attempt(
                                    root, "passed", command_status=0
                                )
                                self.assertEqual(result["status"], "passed")
                        else:
                            if action == "register":
                                mismatched_context = dict(context)
                                mismatched_context["fixtureId"] = "fixture-other"
                                retry = lambda: run_evidence.register_attempt(
                                    index_path, root, mismatched_context
                                )
                            elif action == "init":
                                mismatched_context = dict(context)
                                mismatched_context["executionId"] += "-other"
                                retry = lambda: run_evidence._initialize_attempt(
                                    index_path, root, mismatched_context
                                )
                            else:
                                retry = lambda: run_evidence._finalize_attempt(
                                    root,
                                    "failed",
                                    error_code="runner.unclassified",
                                    command_status=0,
                                )
                            with self.assertRaisesRegex(
                                ValueError, "request fingerprint"
                            ):
                                retry()

                        self.assertEqual(
                            self.transaction_files(publication), []
                        )

    def test_request_fingerprint_and_journal_filename_hash_fail_closed(self):
        publication, index_path = self.new_publication()
        root, context, journal_path = self.prepare_crashed_init(
            publication, index_path, "request-fingerprint-tamper"
        )
        journal = self.read_json(journal_path)
        self.assertIn("requestFingerprint", journal)
        malformed = dict(journal)
        malformed["requestFingerprint"] = "sha256:not-a-digest"
        with self.assertRaisesRegex(ValueError, "requestFingerprint"):
            run_evidence._validate_transaction_journal(publication, malformed)

        journal["requestFingerprint"] = "sha256:" + "0" * 64
        journal_path.write_bytes(run_evidence._json_bytes(journal))
        with self.assertRaisesRegex(ValueError, "journal filename hash"):
            run_evidence._initialize_attempt(index_path, root, context)
        self.assertTrue(journal_path.is_file())

    def test_finalize_retry_without_original_artifact_patch_fails_closed(self):
        root = self.attempt_root("finalize-artifact-request-binding")
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
            artifacts={"trace": None, "report": None},
        )
        run_evidence._initialize_attempt(self.index_path, root, context)

        with self.checkpoint_failure("prepared", -1):
            with self.assertRaises(OSError):
                run_evidence._finalize_attempt(
                    root,
                    "passed",
                    command_status=0,
                    artifact_patch={"trace": "traces/requested.json"},
                )

        self.assertEqual(
            self.transaction_target_paths(),
            [
                f"attempts/{root.name}/run-context.json",
                f"attempts/{root.name}/bootstrap-events.jsonl",
                f"attempts/{root.name}/run-summary.json",
                f"attempts/{root.name}/finalize-receipt.json",
            ],
        )
        with self.assertRaisesRegex(ValueError, "request fingerprint"):
            run_evidence._finalize_attempt(root, "passed", command_status=0)

        self.assertEqual(
            self.read_json(root / "run-context.json")["artifacts"]["trace"],
            "traces/requested.json",
        )
        self.assertTrue((root / "run-summary.json").is_file())
        self.assertEqual(self.transaction_files(), [])

    def test_finalize_retry_accepts_legacy_separate_artifact_commit(self):
        root = self.attempt_root("finalize-legacy-artifact-recovery")
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
            artifacts={"trace": None, "report": None},
        )
        run_evidence._initialize_attempt(self.index_path, root, context)
        run_evidence.update_context(
            root,
            {"artifacts": {"trace": "traces/requested.json"}},
        )
        self.prepare_distinct_clock_legacy_finalize(root)

        self.assertEqual(
            self.transaction_target_paths(),
            [
                f"attempts/{root.name}/bootstrap-events.jsonl",
                f"attempts/{root.name}/run-summary.json",
            ],
        )
        recovered = run_evidence._finalize_attempt(
            root,
            "passed",
            command_status=0,
            artifact_patch={"trace": "traces/requested.json"},
        )

        self.assertEqual(recovered, self.read_json(root / "run-summary.json"))
        self.assertEqual(
            recovered["artifacts"]["trace"], "traces/requested.json"
        )
        self.assertEqual(len(self.terminal_events(root, recovered)), 1)
        self.assertTrue((root / "finalize-receipt.json").is_file())
        self.assertEqual(self.transaction_files(), [])
        self.assertEqual(
            run_evidence._finalize_attempt(
                root,
                "passed",
                command_status=0,
                artifact_patch={"trace": "traces/requested.json"},
            ),
            recovered,
        )

    def test_request_fingerprint_persists_no_secret_or_absolute_request_material(self):
        publication, index_path = self.new_publication()
        root = publication / "attempts" / "sanitized-fingerprint"
        secret = "request-fingerprint-secret"
        context = valid_context(
            runId=root.name,
            executionId="sanitized-fingerprint-execution",
            fixtureId=secret,
            device={
                "requested": str(publication / "private-device"),
                "resolved": "simulator-udid",
            },
        )
        with mock.patch.dict(
            os.environ,
            {
                "API_TOKEN": secret,
                "GITHUB_WORKSPACE": str(publication),
            },
        ):
            with self.checkpoint_failure("prepared", -1):
                with self.assertRaises(OSError):
                    run_evidence._initialize_attempt(index_path, root, context)
            journal_path = self.transaction_files(publication)[0]
            journal_text = journal_path.read_text(encoding="utf-8")
            self.assertNotIn(secret, journal_text)
            self.assertNotIn(str(publication), journal_text)
            self.assertNotIn('"request":', journal_text)
            recovered = run_evidence._initialize_attempt(
                index_path, root, context
            )
        self.assertEqual(recovered["fixtureId"], "<redacted>")
        self.assertEqual(
            recovered["device"]["requested"], "${WORKSPACE}/private-device"
        )

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
                retried = run_evidence.update_context(
                    second, {"runtimeVersion": "18.5"}
                )
                self.assertEqual(
                    retried, self.read_json(second / "run-context.json")
                )

    def test_context_recovery_applies_the_current_different_patch(self):
        root = self.attempt_root("context-current-request")
        context = valid_context(
            runId=root.name,
            executionId="context-current-request-execution",
            runtimeVersion=None,
        )
        run_evidence._initialize_attempt(self.index_path, root, context)

        with self.checkpoint_failure("prepared", -1):
            with self.assertRaises(OSError):
                run_evidence.update_context(root, {"runtimeVersion": "18.5"})
        self.assertEqual(len(self.transaction_files()), 1)

        recovered_and_updated = run_evidence.update_context(
            root, {"artifacts": {"trace": "traces/retry.json"}}
        )

        self.assertEqual(recovered_and_updated["runtimeVersion"], "18.5")
        self.assertEqual(
            recovered_and_updated["artifacts"]["trace"], "traces/retry.json"
        )
        self.assertEqual(
            recovered_and_updated, self.read_json(root / "run-context.json")
        )
        self.assertEqual(self.transaction_files(), [])

    def test_valid_finalization_rolls_forward_without_duplicate_terminal_event(self):
        fault_points = [
            ("prepared", -1),
            ("target", 0),
            ("target", 1),
            ("target", 2),
        ]
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
                        f"attempts/{root.name}/finalize-receipt.json",
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
                self.assertEqual(
                    summary["finalizeRequestFingerprint"],
                    self.read_json(root / "finalize-receipt.json")[
                        "requestFingerprint"
                    ],
                )
                self.assertEqual(len(self.terminal_events(root, summary)), 1)
                self.assertEqual(self.transaction_files(), [])
                self.assertEqual(
                    run_evidence._finalize_attempt(root, "passed"), summary
                )

    def test_finalize_response_loss_after_durable_unlink_is_request_safe(self):
        root = self.attempt_root("finalize-committed-response-loss")
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
            artifacts={"trace": None, "report": None},
        )
        run_evidence._initialize_attempt(self.index_path, root, context)
        request = {
            "command_status": 0,
            "artifact_patch": {"trace": "traces/committed.json"},
        }

        with self.checkpoint_failure("committed", -1):
            with self.assertRaises(OSError):
                run_evidence._finalize_attempt(root, "passed", **request)

        self.assertEqual(self.transaction_files(), [])
        committed = self.read_json(root / "run-summary.json")
        receipt_path = root / "finalize-receipt.json"
        self.assertEqual(
            committed["finalizeRequestFingerprint"],
            self.read_json(receipt_path)["requestFingerprint"],
        )
        receipt_before_mismatch = receipt_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "request fingerprint"):
            run_evidence._finalize_attempt(
                root, "failed", error_code="runner.unclassified"
            )
        self.assertEqual(receipt_path.read_bytes(), receipt_before_mismatch)

        retried = run_evidence._finalize_attempt(root, "passed", **request)
        self.assertEqual(retried, committed)
        self.assertEqual(len(self.terminal_events(root, committed)), 1)
        self.assertEqual(
            self.read_json(root / "run-context.json")["artifacts"]["trace"],
            "traces/committed.json",
        )

    @unittest.skipUnless(
        os.name == "posix",
        "requires immediate POSIX process-death semantics",
    )
    def test_process_death_after_durable_unlink_reconciles_finalize(self):
        root = self.attempt_root("finalize-committed-process-death")
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
        )
        run_evidence._initialize_attempt(self.index_path, root, context)

        journal_path = self.crash_transaction_process(
            "finalize",
            self.index_path,
            root,
            context,
            "committed",
            -1,
            finalize_request={"status": "passed", "command_status": 0},
            expected_journal_count=0,
        )

        self.assertIsNone(journal_path)
        committed = self.read_json(root / "run-summary.json")
        self.assertTrue((root / "finalize-receipt.json").is_file())
        self.assertEqual(
            committed["finalizeRequestFingerprint"],
            self.read_json(root / "finalize-receipt.json")[
                "requestFingerprint"
            ],
        )
        retried = run_evidence._finalize_attempt(
            root, "passed", command_status=0
        )
        self.assertEqual(retried, committed)
        self.assertEqual(len(self.terminal_events(root, committed)), 1)

    def test_finalize_receipt_is_exact_bounded_and_binds_committed_summary(self):
        root = self.attempt_root("finalize-receipt-validation")
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
        )
        run_evidence._initialize_attempt(self.index_path, root, context)
        committed = run_evidence._finalize_attempt(
            root, "passed", command_status=0
        )
        receipt_path = root / "finalize-receipt.json"
        receipt_bytes = receipt_path.read_bytes()
        receipt = json.loads(receipt_bytes)
        self.assertEqual(
            set(receipt),
            {
                "schemaVersion",
                "operation",
                "attemptRoot",
                "requestFingerprint",
                "resultPath",
                "resultSha256",
            },
        )
        self.assertEqual(receipt["operation"], "finalize")
        self.assertEqual(receipt["attemptRoot"], f"attempts/{root.name}")
        self.assertEqual(
            receipt["resultPath"], f"attempts/{root.name}/run-summary.json"
        )
        self.assertEqual(
            committed["finalizeRequestFingerprint"],
            receipt["requestFingerprint"],
        )

        malformed = dict(receipt)
        malformed["unexpected"] = True
        receipt_path.write_bytes(run_evidence._json_bytes(malformed))
        with self.assertRaisesRegex(ValueError, "invalid object shape"):
            run_evidence._finalize_attempt(root, "passed", command_status=0)

        receipt_path.write_bytes(
            receipt_bytes
            + b" "
            * (
                run_evidence.MAX_FINALIZE_RECEIPT_BYTES
                - len(receipt_bytes)
                + 1
            )
        )
        with self.assertRaisesRegex(ValueError, "exceeds .* bytes"):
            run_evidence._finalize_attempt(root, "passed", command_status=0)

        receipt_path.write_bytes(receipt_bytes)
        summary_path = root / "run-summary.json"
        summary_bytes = summary_path.read_bytes()
        summary_path.write_bytes(summary_bytes + b"\n")
        with self.assertRaisesRegex(ValueError, "result hash"):
            run_evidence._finalize_attempt(root, "passed", command_status=0)

        summary_path.write_bytes(summary_bytes)
        self.assertEqual(
            run_evidence._finalize_attempt(root, "passed", command_status=0),
            committed,
        )

        rebound_summary = dict(committed)
        rebound_summary["finalizeRequestFingerprint"] = "sha256:" + "0" * 64
        rebound_summary_bytes = run_evidence._json_bytes(rebound_summary)
        summary_path.write_bytes(rebound_summary_bytes)
        rebound_receipt = dict(receipt)
        rebound_receipt["resultSha256"] = (
            "sha256:" + hashlib.sha256(rebound_summary_bytes).hexdigest()
        )
        receipt_path.write_bytes(run_evidence._json_bytes(rebound_receipt))
        with self.assertRaisesRegex(ValueError, "request fingerprint"):
            run_evidence._finalize_attempt(root, "passed", command_status=0)

    def test_finalize_journal_receipt_is_bound_to_request_and_summary(self):
        root = self.attempt_root("finalize-receipt-journal-binding")
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
        )
        run_evidence._initialize_attempt(self.index_path, root, context)
        with self.checkpoint_failure("prepared", -1):
            with self.assertRaises(OSError):
                run_evidence._finalize_attempt(
                    root, "passed", command_status=0
                )

        journal = self.read_json(self.transaction_files()[0])
        receipt_target = next(
            target
            for target in journal["targets"]
            if target["path"].endswith("/finalize-receipt.json")
        )
        summary_target = next(
            target
            for target in journal["targets"]
            if target["path"].endswith("/run-summary.json")
        )
        receipt = json.loads(
            base64.b64decode(receipt_target["contentBase64"], validate=True)
        )
        summary = json.loads(
            base64.b64decode(summary_target["contentBase64"], validate=True)
        )
        self.assertEqual(
            receipt["requestFingerprint"], journal["requestFingerprint"]
        )
        self.assertEqual(receipt["resultSha256"], summary_target["sha256"])
        self.assertEqual(
            summary["finalizeRequestFingerprint"],
            journal["requestFingerprint"],
        )

        def journal_with_summary_binding(value):
            candidate = copy.deepcopy(journal)
            candidate_summary_target = next(
                target
                for target in candidate["targets"]
                if target["path"].endswith("/run-summary.json")
            )
            candidate_summary = json.loads(
                base64.b64decode(
                    candidate_summary_target["contentBase64"], validate=True
                )
            )
            if value is None:
                candidate_summary.pop("finalizeRequestFingerprint", None)
            else:
                candidate_summary["finalizeRequestFingerprint"] = value
            candidate_summary_content = run_evidence._json_bytes(
                candidate_summary
            )
            candidate_summary_target["contentBase64"] = base64.b64encode(
                candidate_summary_content
            ).decode("ascii")
            candidate_summary_target["sha256"] = (
                "sha256:"
                + hashlib.sha256(candidate_summary_content).hexdigest()
            )
            candidate_receipt_target = next(
                target
                for target in candidate["targets"]
                if target["path"].endswith("/finalize-receipt.json")
            )
            candidate_receipt = json.loads(
                base64.b64decode(
                    candidate_receipt_target["contentBase64"], validate=True
                )
            )
            candidate_receipt["resultSha256"] = candidate_summary_target[
                "sha256"
            ]
            candidate_receipt_content = run_evidence._json_bytes(
                candidate_receipt
            )
            candidate_receipt_target["contentBase64"] = base64.b64encode(
                candidate_receipt_content
            ).decode("ascii")
            candidate_receipt_target["sha256"] = (
                "sha256:"
                + hashlib.sha256(candidate_receipt_content).hexdigest()
            )
            return candidate

        for value in (None, "sha256:" + "0" * 64):
            with self.subTest(summary_binding=value), run_evidence._rooted_io(
                self.publication_root, mutation=False
            ), self.assertRaisesRegex(
                ValueError, "summary finalize request fingerprint"
            ):
                run_evidence._validate_transaction_journal(
                    self.publication_root,
                    journal_with_summary_binding(value),
                )

        mismatched = copy.deepcopy(journal)
        mismatched_target = next(
            target
            for target in mismatched["targets"]
            if target["path"].endswith("/finalize-receipt.json")
        )
        mismatched_receipt = dict(receipt)
        mismatched_receipt["requestFingerprint"] = "sha256:" + "0" * 64
        content = run_evidence._json_bytes(mismatched_receipt)
        mismatched_target["contentBase64"] = base64.b64encode(content).decode(
            "ascii"
        )
        mismatched_target["sha256"] = (
            "sha256:" + hashlib.sha256(content).hexdigest()
        )
        with run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(ValueError, "receipt request fingerprint"):
            run_evidence._validate_transaction_journal(
                self.publication_root, mismatched
            )

    def test_finalize_journal_rejects_terminal_timestamp_mismatch(self):
        for fallback in (False, True):
            with self.subTest(fallback=fallback):
                publication, index_path = self.new_publication()
                run_id = (
                    "finalize-timestamp-fallback"
                    if fallback
                    else "finalize-timestamp-normal"
                )
                root = publication / "attempts" / run_id
                context = valid_context(
                    runId=run_id,
                    executionId=run_id + "-execution",
                )
                run_evidence._initialize_attempt(index_path, root, context)
                if fallback:
                    context_path = root / "run-context.json"
                    damaged = self.read_json(context_path)
                    damaged["platform"] = "invalid-platform"
                    context_path.write_text(json.dumps(damaged), encoding="utf-8")
                with self.checkpoint_failure("prepared", -1):
                    with self.assertRaises(OSError):
                        run_evidence._finalize_attempt(root, "passed")

                journal = self.read_json(
                    self.transaction_files(publication)[0]
                )
                event_target = next(
                    target
                    for target in journal["targets"]
                    if target["path"].endswith("/bootstrap-events.jsonl")
                )
                events = [
                    json.loads(line)
                    for line in base64.b64decode(
                        event_target["contentBase64"], validate=True
                    ).splitlines()
                    if line.strip()
                ]
                events[-1]["timestamp"] = "2026-07-11T10:00:02.000Z"
                content = b"".join(
                    run_evidence._json_bytes(event) for event in events
                )
                event_target["contentBase64"] = base64.b64encode(
                    content
                ).decode("ascii")
                event_target["sha256"] = (
                    "sha256:" + hashlib.sha256(content).hexdigest()
                )

                with run_evidence._rooted_io(
                    publication, mutation=False
                ), self.assertRaisesRegex(ValueError, "event timestamp"):
                    run_evidence._validate_transaction_journal(
                        publication, journal
                    )

    def test_finalize_journal_rejects_fingerprint_without_receipt_before_mutation(self):
        root = self.attempt_root("finalize-one-sided-binding")
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
        )
        run_evidence._initialize_attempt(self.index_path, root, context)
        with self.checkpoint_failure("prepared", -1):
            with self.assertRaises(OSError):
                run_evidence._finalize_attempt(
                    root, "passed", command_status=0
                )

        original_path = self.transaction_files()[0]
        journal = self.read_json(original_path)
        journal["targets"] = [
            target
            for target in journal["targets"]
            if not target["path"].endswith("/finalize-receipt.json")
        ]
        content = run_evidence._json_bytes(journal)
        replacement = original_path.with_name(
            f"finalize-{root.name}-"
            f"{hashlib.sha256(content).hexdigest()[:16]}.json"
        )
        original_path.unlink()
        replacement.write_bytes(content)
        replacement.chmod(0o600)
        before = self.attempt_evidence_snapshot(root)

        with self.assertRaisesRegex(
            ValueError,
            "receipt and summary finalize request fingerprint must either both",
        ):
            run_evidence._recover_pending_transactions(
                self.publication_root
            )

        self.assertEqual(self.attempt_evidence_snapshot(root), before)
        self.assertTrue(replacement.is_file())

    def test_finalize_recovers_and_upgrades_distinct_clock_legacy_journals(self):
        for fallback in (False, True):
            with self.subTest(fallback=fallback):
                publication, index_path = self.new_publication()
                suffix = "fallback" if fallback else "normal"
                root = publication / "attempts" / f"legacy-upgrade-{suffix}"
                context = valid_context(
                    runId=root.name,
                    executionId=root.name + "-execution",
                )
                run_evidence._initialize_attempt(index_path, root, context)
                journal, expected, legacy_timestamp = (
                    self.prepare_distinct_clock_legacy_finalize(
                        root, fallback=fallback
                    )
                )
                upgraded_fingerprint = (
                    run_evidence._legacy_finalize_receipt_request_fingerprint(
                        journal["requestFingerprint"]
                    )
                )
                expected = dict(expected)
                expected["finalizeRequestFingerprint"] = upgraded_fingerprint

                recovered = run_evidence._finalize_attempt(
                    root, "passed", command_status=0
                )

                self.assertEqual(recovered, expected)
                self.assertEqual(
                    recovered, self.read_json(root / "run-summary.json")
                )
                terminal_event = self.read_events(root)[-1]
                self.assertNotEqual(legacy_timestamp, recovered["finishedAt"])
                self.assertEqual(
                    terminal_event["timestamp"], recovered["finishedAt"]
                )
                receipt_path = root / "finalize-receipt.json"
                self.assertTrue(receipt_path.is_file())
                self.assertLessEqual(
                    receipt_path.stat().st_size,
                    run_evidence.MAX_FINALIZE_RECEIPT_BYTES,
                )
                receipt = self.read_json(receipt_path)
                self.assertEqual(
                    receipt["requestFingerprint"],
                    upgraded_fingerprint,
                )
                self.assertEqual(
                    recovered["finalizeRequestFingerprint"],
                    receipt["requestFingerprint"],
                )
                self.assertEqual(
                    receipt["resultSha256"],
                    "sha256:"
                    + hashlib.sha256(
                        (root / "run-summary.json").read_bytes()
                    ).hexdigest(),
                )
                self.assertEqual(self.transaction_files(publication), [])
                self.assertEqual(
                    run_evidence._finalize_attempt(
                        root, "passed", command_status=0
                    ),
                    recovered,
                )

    def test_legacy_summary_upgrade_obeys_exact_and_overhead_caps(self):
        for fallback in (False, True):
            for upgrade_fits in (False, True):
                with self.subTest(
                    fallback=fallback, upgrade_fits=upgrade_fits
                ):
                    publication, index_path = self.new_publication()
                    kind = "fallback" if fallback else "normal"
                    boundary = "overhead" if upgrade_fits else "exact"
                    root = publication / "attempts" / (
                        f"legacy-summary-{kind}-{boundary}"
                    )
                    context = valid_context(
                        runId=root.name,
                        executionId=root.name + "-execution",
                    )
                    run_evidence._initialize_attempt(
                        index_path, root, context
                    )
                    journal, legacy_summary, legacy_timestamp = (
                        self.prepare_distinct_clock_legacy_finalize(
                            root, fallback=fallback
                        )
                    )
                    summary_target = next(
                        target
                        for target in journal["targets"]
                        if target["path"].endswith("/run-summary.json")
                    )
                    legacy_content = base64.b64decode(
                        summary_target["contentBase64"], validate=True
                    )
                    upgraded_fingerprint = (
                        run_evidence._legacy_finalize_receipt_request_fingerprint(
                            journal["requestFingerprint"]
                        )
                    )
                    upgraded_summary = dict(legacy_summary)
                    upgraded_summary["finalizeRequestFingerprint"] = (
                        upgraded_fingerprint
                    )
                    upgraded_content = run_evidence._json_bytes(
                        upgraded_summary
                    )
                    self.assertGreater(
                        len(upgraded_content), len(legacy_content)
                    )
                    summary_cap = (
                        len(upgraded_content)
                        if upgrade_fits
                        else len(legacy_content)
                    )

                    with mock.patch.object(
                        journal_module,
                        "MAX_STRUCTURED_JSON_BYTES",
                        summary_cap,
                    ):
                        recovered = run_evidence._finalize_attempt(
                            root, "passed", command_status=0
                        )

                    self.assertEqual(
                        self.transaction_files(publication), []
                    )
                    if upgrade_fits:
                        self.assertEqual(recovered, upgraded_summary)
                        self.assertEqual(
                            self.read_events(root)[-1]["timestamp"],
                            recovered["finishedAt"],
                        )
                        self.assertTrue(
                            (root / "finalize-receipt.json").is_file()
                        )
                    else:
                        self.assertEqual(recovered, legacy_summary)
                        self.assertNotIn(
                            "finalizeRequestFingerprint", recovered
                        )
                        self.assertEqual(
                            self.read_events(root)[-1]["timestamp"],
                            legacy_timestamp,
                        )
                        self.assertFalse(
                            (root / "finalize-receipt.json").exists()
                        )

    def test_legacy_event_upgrade_overflow_replays_original_transaction(self):
        publication, index_path = self.new_publication()
        root = publication / "attempts" / "legacy-event-overflow"
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
        )
        run_evidence._initialize_attempt(index_path, root, context)
        short_timestamp = "2026-07-11T10:00:00Z"
        journal, legacy_summary, legacy_timestamp = (
            self.prepare_distinct_clock_legacy_finalize(
                root, legacy_timestamp=short_timestamp
            )
        )
        event_target = next(
            target
            for target in journal["targets"]
            if target["path"].endswith("/bootstrap-events.jsonl")
        )
        legacy_event_content = base64.b64decode(
            event_target["contentBase64"], validate=True
        )
        migrated_events = [
            json.loads(line)
            for line in legacy_event_content.splitlines()
            if line.strip()
        ]
        migrated_events[-1]["timestamp"] = legacy_summary["finishedAt"]
        migrated_event_content = b"".join(
            run_evidence._json_bytes(event) for event in migrated_events
        )
        self.assertGreater(
            len(migrated_event_content), len(legacy_event_content)
        )

        with mock.patch.object(
            journal_module,
            "MAX_LIFECYCLE_EVENT_STREAM_BYTES",
            len(legacy_event_content),
        ):
            recovered = run_evidence._finalize_attempt(
                root, "passed", command_status=0
            )

        self.assertEqual(recovered, legacy_summary)
        self.assertEqual(
            self.read_events(root)[-1]["timestamp"], legacy_timestamp
        )
        self.assertFalse((root / "finalize-receipt.json").exists())
        self.assertEqual(self.transaction_files(publication), [])

    def test_legacy_aggregate_upgrade_overflow_replays_original_transaction(self):
        publication, index_path = self.new_publication()
        root = publication / "attempts" / "legacy-aggregate-overflow"
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
        )
        run_evidence._initialize_attempt(index_path, root, context)
        journal, legacy_summary, legacy_timestamp = (
            self.prepare_distinct_clock_legacy_finalize(root)
        )
        legacy_aggregate = sum(
            len(base64.b64decode(target["contentBase64"], validate=True))
            for target in journal["targets"]
        )

        with mock.patch.object(
            journal_module,
            "MAX_TRANSACTION_TARGET_AGGREGATE_BYTES",
            legacy_aggregate,
        ):
            recovered = run_evidence._finalize_attempt(
                root, "passed", command_status=0
            )

        self.assertEqual(recovered, legacy_summary)
        self.assertNotIn("finalizeRequestFingerprint", recovered)
        self.assertEqual(
            self.read_events(root)[-1]["timestamp"], legacy_timestamp
        )
        self.assertFalse((root / "finalize-receipt.json").exists())
        self.assertEqual(self.transaction_files(publication), [])

    @unittest.skipUnless(
        os.name == "posix",
        "requires immediate POSIX process-death semantics",
    )
    def test_process_death_after_unupgradable_legacy_commit_refuses_retry_guess(self):
        publication, index_path = self.new_publication()
        root = publication / "attempts" / "legacy-boundary-death"
        context = valid_context(
            runId=root.name,
            executionId=root.name + "-execution",
        )
        run_evidence._initialize_attempt(index_path, root, context)
        journal, legacy_summary, legacy_timestamp = (
            self.prepare_distinct_clock_legacy_finalize(root)
        )
        summary_target = next(
            target
            for target in journal["targets"]
            if target["path"].endswith("/run-summary.json")
        )
        legacy_summary_bytes = base64.b64decode(
            summary_target["contentBase64"], validate=True
        )

        journal_path = self.crash_transaction_process(
            "finalize",
            index_path,
            root,
            context,
            "committed",
            -1,
            finalize_request={
                "status": "passed",
                "command_status": 0,
            },
            expected_journal_count=0,
            journal_limits={
                "MAX_STRUCTURED_JSON_BYTES": len(legacy_summary_bytes)
            },
        )

        self.assertIsNone(journal_path)
        self.assertEqual(self.read_json(root / "run-summary.json"), legacy_summary)
        self.assertEqual(
            self.read_events(root)[-1]["timestamp"], legacy_timestamp
        )
        self.assertFalse((root / "finalize-receipt.json").exists())
        # Once the legacy journal is gone, a lost response has no durable
        # request binding; refusing to infer retry success is the safe limit.
        with self.assertRaisesRegex(
            FileExistsError, "terminal run summary already exists"
        ):
            run_evidence._finalize_attempt(
                root, "passed", command_status=0
            )

    def test_legacy_finalize_committed_response_loss_is_request_safe(self):
        for fallback in (False, True):
            with self.subTest(fallback=fallback):
                publication, index_path = self.new_publication()
                suffix = "fallback" if fallback else "normal"
                root = publication / "attempts" / f"legacy-loss-{suffix}"
                context = valid_context(
                    runId=root.name,
                    executionId=root.name + "-execution",
                )
                run_evidence._initialize_attempt(index_path, root, context)
                self.prepare_distinct_clock_legacy_finalize(
                    root, fallback=fallback
                )

                with self.checkpoint_failure("committed", -1):
                    with self.assertRaises(OSError):
                        run_evidence._finalize_attempt(
                            root, "passed", command_status=0
                        )

                self.assertEqual(self.transaction_files(publication), [])
                self.assertTrue((root / "finalize-receipt.json").is_file())
                committed = self.read_json(root / "run-summary.json")
                self.assertEqual(
                    committed["finalizeRequestFingerprint"],
                    self.read_json(root / "finalize-receipt.json")[
                        "requestFingerprint"
                    ],
                )
                before_mismatch = self.attempt_evidence_snapshot(root)
                with self.assertRaisesRegex(ValueError, "request fingerprint"):
                    run_evidence._finalize_attempt(
                        root,
                        "failed",
                        error_code="runner.unclassified",
                    )
                self.assertEqual(
                    self.attempt_evidence_snapshot(root), before_mismatch
                )
                self.assertEqual(
                    run_evidence._finalize_attempt(
                        root, "passed", command_status=0
                    ),
                    committed,
                )

    @unittest.skipUnless(
        os.name == "posix",
        "requires immediate POSIX process-death semantics",
    )
    def test_process_death_after_legacy_upgrade_reconciles_finalize(self):
        for fallback in (False, True):
            with self.subTest(fallback=fallback):
                publication, index_path = self.new_publication()
                suffix = "fallback" if fallback else "normal"
                root = publication / "attempts" / f"legacy-death-{suffix}"
                context = valid_context(
                    runId=root.name,
                    executionId=root.name + "-execution",
                )
                run_evidence._initialize_attempt(index_path, root, context)
                self.prepare_distinct_clock_legacy_finalize(
                    root, fallback=fallback
                )

                journal_path = self.crash_transaction_process(
                    "finalize",
                    index_path,
                    root,
                    context,
                    "committed",
                    -1,
                    finalize_request={
                        "status": "passed",
                        "command_status": 0,
                    },
                    expected_journal_count=0,
                )

                self.assertIsNone(journal_path)
                committed = self.read_json(root / "run-summary.json")
                self.assertTrue((root / "finalize-receipt.json").is_file())
                self.assertEqual(
                    committed["finalizeRequestFingerprint"],
                    self.read_json(root / "finalize-receipt.json")[
                        "requestFingerprint"
                    ],
                )
                self.assertEqual(
                    self.read_events(root)[-1]["timestamp"],
                    committed["finishedAt"],
                )
                self.assertEqual(
                    run_evidence._finalize_attempt(
                        root, "passed", command_status=0
                    ),
                    committed,
                )

    def test_invalid_fallback_rolls_forward_after_every_target_position(self):
        fault_points = [
            ("prepared", -1),
            *(("target", index) for index in range(5)),
        ]
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
                        f"attempts/{root.name}/finalize-receipt.json",
                    ],
                )
                summary = run_evidence._finalize_attempt(root, "passed")
                self.assertEqual(summary["errorCode"], "runner.evidence_invalid")
                self.assertEqual(run_evidence.validate_summary(summary), [])
                self.assertEqual(
                    summary["finalizeRequestFingerprint"],
                    self.read_json(root / "finalize-receipt.json")[
                        "requestFingerprint"
                    ],
                )
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

    def test_plumbed_recovery_result_rejects_a_changed_committed_target(self):
        root = self.attempt_root("plumbed-result-changed")
        context = valid_context(
            runId=root.name,
            executionId="plumbed-result-changed-execution",
        )
        run_evidence._initialize_attempt(self.index_path, root, context)
        with self.checkpoint_failure("prepared", -1):
            with self.assertRaises(OSError):
                run_evidence._finalize_attempt(root, "passed")

        recovered = run_evidence._recover_pending_transactions(
            self.publication_root
        )
        summary_path = root / "run-summary.json"
        summary_path.write_text('{"tampered":true}\n', encoding="utf-8")
        with self.assertRaisesRegex(
            ValueError, "recovered transaction result target changed"
        ):
            run_evidence._finalize_attempt(
                root,
                "passed",
                _recovered_transactions=recovered,
            )

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


class TransactionResourceLimitTests(StorageTestCase):
    def capture_init_transaction(self, run_id="bounded-wal"):
        root = self.attempt_root(run_id)
        context = valid_context(
            runId=run_id, executionId=run_id + "-execution"
        )
        captured = []

        with mock.patch.object(
            run_evidence.lifecycle,
            "_commit_transaction_unlocked",
            side_effect=lambda _publication, transaction: captured.append(
                transaction
            ),
        ):
            run_evidence._initialize_attempt(self.index_path, root, context)
        self.assertEqual(len(captured), 1)
        return root, copy.deepcopy(captured[0])

    def write_pending_journal(self, journal, suffix=b""):
        content = run_evidence._json_bytes(journal) + suffix
        transaction_root = self.publication_root / ".transactions"
        transaction_root.mkdir(exist_ok=True)
        fingerprint = hashlib.sha256(content).hexdigest()[:16]
        run_id = journal["attemptRoot"].split("/")[-1]
        path = transaction_root / (
            f"{journal['operation']}-{run_id}-{fingerprint}.json"
        )
        path.write_bytes(content)
        path.chmod(0o600)
        return path, content

    def test_pending_journal_file_limit_accepts_exact_and_rejects_plus_one(self):
        _root, transaction = self.capture_init_transaction()
        journal_path, content = self.write_pending_journal(
            transaction["journal"]
        )
        with mock.patch.object(
            journal_module, "MAX_TRANSACTION_JOURNAL_BYTES", len(content)
        ), run_evidence._rooted_io(self.publication_root, mutation=False):
            self.assertEqual(
                len(
                    run_evidence.journal._load_pending_transactions(
                        self.publication_root
                    )
                ),
                1,
            )

        journal_path.unlink()
        self.write_pending_journal(transaction["journal"], b" ")
        with mock.patch.object(
            journal_module, "MAX_TRANSACTION_JOURNAL_BYTES", len(content)
        ), run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "transaction journal exceeds"
        ):
            run_evidence.journal._load_pending_transactions(
                self.publication_root
            )

    def test_pending_enumeration_bounds_entries_count_and_aggregate_before_load(self):
        transaction_root = self.publication_root / ".transactions"
        transaction_root.mkdir()
        paths = [transaction_root / f"pending-{index}.json" for index in range(2)]
        for path in paths:
            path.write_bytes(b"{}")
            path.chmod(0o600)

        with mock.patch.object(
            journal_module, "MAX_TRANSACTION_DIRECTORY_ENTRY_COUNT", 1
        ), mock.patch.object(
            journal_module,
            "_evidence_iterdir",
            side_effect=AssertionError("unbounded listing was used"),
        ), run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "directory entry"
        ):
            run_evidence.journal._pending_transaction_paths(
                self.publication_root
            )

        with mock.patch.object(
            journal_module, "MAX_TRANSACTION_DIRECTORY_ENTRY_COUNT", 128
        ), mock.patch.object(
            journal_module, "MAX_PENDING_TRANSACTION_COUNT", 1
        ), run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "pending transaction count"
        ):
            run_evidence.journal._pending_transaction_paths(
                self.publication_root
            )

        paths[1].unlink()
        with mock.patch.object(
            journal_module, "MAX_PENDING_TRANSACTION_BYTES", 1
        ), run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "pending transaction bytes"
        ):
            run_evidence.journal._pending_transaction_paths(
                self.publication_root
            )

    def test_make_transaction_rejects_raw_limits_before_base64_encoding(self):
        root = self.attempt_root("producer-bounds")
        fingerprint = "sha256:" + "a" * 64
        cases = (
            ({"MAX_TRANSACTION_TARGET_COUNT": 0}, "target count"),
            (
                {"MAX_TRANSACTION_REQUIRED_DIRECTORY_COUNT": 0},
                "required directory count",
            ),
            ({"MAX_STRUCTURED_JSON_BYTES": 2}, "target .* exceeds"),
            (
                {"MAX_TRANSACTION_TARGET_AGGREGATE_BYTES": 2},
                "aggregate",
            ),
        )
        for patched_limits, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic), mock.patch.multiple(
                journal_module, **patched_limits
            ), mock.patch.object(
                journal_module.base64,
                "b64encode",
                side_effect=AssertionError(
                    "base64 encoding happened before admission"
                ),
            ) as encoder, run_evidence._rooted_io(
                self.publication_root, mutation=False
            ), self.assertRaisesRegex(
                ValueError, diagnostic
            ):
                run_evidence._make_transaction(
                    self.publication_root,
                    "register",
                    root,
                    ["attempts/producer-bounds"],
                    [("attempt-index.json", b"{}\n")],
                    request_fingerprint=fingerprint,
                )
            self.assertEqual(encoder.call_count, 0)

    def test_journal_rejects_per_target_and_aggregate_base64_before_decode(self):
        _root, transaction = self.capture_init_transaction()
        oversized = copy.deepcopy(transaction["journal"])
        oversized["targets"][0]["contentBase64"] = "AAAA"
        oversized["targets"][0]["sha256"] = "sha256:" + "0" * 64
        cases = (
            (
                oversized,
                {"MAX_STRUCTURED_JSON_BYTES": 1},
                "target .* exceeds",
            ),
            (
                transaction["journal"],
                {"MAX_TRANSACTION_TARGET_AGGREGATE_BYTES": 1},
                "aggregate",
            ),
        )
        for journal, patched_limits, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic), mock.patch.multiple(
                journal_module, **patched_limits
            ), mock.patch.object(
                journal_module.base64,
                "b64decode",
                side_effect=AssertionError("oversized base64 was decoded"),
            ) as decoder, run_evidence._rooted_io(
                self.publication_root, mutation=False
            ), self.assertRaisesRegex(
                ValueError, diagnostic
            ):
                run_evidence._validate_transaction_journal(
                    self.publication_root, journal
                )
            self.assertEqual(decoder.call_count, 0)

    def test_transaction_targets_use_strict_bounded_json_decoding(self):
        context = run_evidence._json_bytes(
            valid_context(runId="strict-target")
        )
        duplicate = context.replace(
            b'"runId":"strict-target"',
            b'"runId":"strict-target","runId":"strict-target"',
            1,
        )
        cases = (
            (duplicate, "duplicate object key"),
            (b'{"runId":NaN}\n', "non-finite JSON number"),
            (
                (b'{"value":' * 257) + b"null" + (b"}" * 257),
                "nesting exceeds supported depth",
            ),
        )
        for content, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic), self.assertRaisesRegex(
                ValueError, diagnostic
            ):
                journal_module._validate_transaction_target_content(
                    "attempts/strict-target/run-context.json", content
                )

        with mock.patch.object(
            journal_module, "MAX_STRUCTURED_JSON_BYTES", len(context)
        ):
            journal_module._validate_transaction_target_content(
                "attempts/strict-target/run-context.json", context
            )
        with mock.patch.object(
            journal_module, "MAX_STRUCTURED_JSON_BYTES", len(context) - 1
        ), self.assertRaisesRegex(ValueError, "target .* exceeds"):
            journal_module._validate_transaction_target_content(
                "attempts/strict-target/run-context.json", context
            )

    def test_apply_transaction_streams_existing_and_written_target_hashes(self):
        root, transaction = self.capture_init_transaction("streamed-replay")
        root.mkdir(parents=True)
        context_target = next(
            target
            for target in transaction["targets"]
            if target["path"].endswith("/run-context.json")
        )
        (root / "run-context.json").write_bytes(
            b"x" * (len(context_target["content"]) + 1024)
        )
        journal_path, _content = self.write_pending_journal(
            transaction["journal"]
        )
        with mock.patch.object(
            journal_module,
            "_evidence_read_bytes",
            side_effect=AssertionError("replay used an unbounded full-file read"),
        ), run_evidence._rooted_io(self.publication_root, mutation=True):
            journal_module._apply_transaction(
                self.publication_root, journal_path, transaction
            )
        self.assertEqual(
            (root / "run-context.json").read_bytes(),
            context_target["content"],
        )
        self.assertFalse(journal_path.exists())

    def test_recovered_result_rejects_size_mismatch_before_reading(self):
        root, transaction = self.capture_init_transaction("bounded-result")
        root.mkdir(parents=True)
        (root / "run-context.json").write_bytes(b"oversized-result")
        with mock.patch.object(
            journal_module,
            "_evidence_read_bytes",
            side_effect=AssertionError("result used an unbounded full-file read"),
        ), mock.patch.object(
            run_evidence.bounded_io,
            "_iter_regular_chunks",
            side_effect=AssertionError("size mismatch was streamed"),
        ), run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "result target changed"
        ):
            journal_module._recovered_result(
                self.publication_root,
                [transaction],
                "init",
                f"attempts/{root.name}",
                transaction["requestFingerprint"],
            )

    def test_base64_shape_and_exact_multi_target_aggregate_precede_decoding(self):
        _root, transaction = self.capture_init_transaction("aggregate-wal")
        journal = transaction["journal"]
        decoded_total = sum(
            len(base64.b64decode(target["contentBase64"], validate=True))
            for target in journal["targets"]
        )
        with mock.patch.object(
            journal_module,
            "MAX_TRANSACTION_TARGET_AGGREGATE_BYTES",
            decoded_total,
        ), run_evidence._rooted_io(self.publication_root, mutation=False):
            run_evidence._validate_transaction_journal(
                self.publication_root, journal
            )

        with mock.patch.object(
            journal_module,
            "MAX_TRANSACTION_TARGET_AGGREGATE_BYTES",
            decoded_total - 1,
        ), mock.patch.object(
            journal_module.base64,
            "b64decode",
            side_effect=AssertionError("over-limit aggregate was decoded"),
        ) as decoder, run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "aggregate"
        ):
            run_evidence._validate_transaction_journal(
                self.publication_root, journal
            )
        self.assertEqual(decoder.call_count, 0)

        malformed = copy.deepcopy(journal)
        malformed["targets"][1]["contentBase64"] = "!!!!"
        with mock.patch.object(
            journal_module.base64,
            "b64decode",
            side_effect=AssertionError("malformed later target followed a decode"),
        ) as decoder, run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "contentBase64"
        ):
            run_evidence._validate_transaction_journal(
                self.publication_root, malformed
            )
        self.assertEqual(decoder.call_count, 0)

    def test_recovery_preflights_every_journal_and_target_before_any_mutation(self):
        first_root = self.attempt_root("a-preflight")
        second_root = self.attempt_root("z-preflight")
        run_evidence._initialize_attempt(
            self.index_path,
            first_root,
            valid_context(
                runId=first_root.name,
                executionId="preflight-execution",
                attempt=1,
            ),
        )
        run_evidence._initialize_attempt(
            self.index_path,
            second_root,
            valid_context(
                runId=second_root.name,
                executionId="preflight-execution",
                attempt=2,
            ),
        )

        transactions = []
        for root in (first_root, second_root):
            with mock.patch.object(
                run_evidence.summaries,
                "_commit_transaction_unlocked",
                side_effect=lambda _publication, transaction: transactions.append(
                    copy.deepcopy(transaction)
                ),
            ):
                run_evidence._finalize_attempt(root, "passed")
        self.assertEqual(len(transactions), 2)
        for transaction in transactions:
            self.write_pending_journal(transaction["journal"])

        orphan = self.publication_root / ".transactions" / (
            ".init-orphan-0123456789abcdef.json.abcdefgh.tmp"
        )
        orphan.write_bytes(b"trusted-looking orphan")
        orphan.chmod(0o600)
        unsafe_target_temp = second_root / (
            ".bootstrap-events.jsonl.abcdefgh.tmp"
        )
        unsafe_target_temp.write_bytes(b"unsafe later target temp")
        unsafe_target_temp.chmod(0o644)

        def snapshot():
            result = {}
            for path in sorted(self.publication_root.rglob("*")):
                metadata = path.lstat()
                relative = path.relative_to(self.publication_root).as_posix()
                result[relative] = (
                    metadata.st_dev,
                    metadata.st_ino,
                    metadata.st_mode,
                    path.read_bytes() if path.is_file() else None,
                )
            return result

        before = snapshot()
        with self.assertRaisesRegex(ValueError, "temporary"):
            run_evidence._recover_pending_transactions(self.publication_root)
        self.assertEqual(snapshot(), before)

    def test_consumer_counts_and_event_limits_are_checked_before_decode(self):
        _root, transaction = self.capture_init_transaction("consumer-wal")
        journal = transaction["journal"]
        for patched_limits, diagnostic in (
            ({"MAX_TRANSACTION_TARGET_COUNT": 2}, "target count"),
            (
                {"MAX_TRANSACTION_REQUIRED_DIRECTORY_COUNT": 2},
                "required directory count",
            ),
        ):
            with self.subTest(diagnostic=diagnostic), mock.patch.multiple(
                journal_module, **patched_limits
            ), mock.patch.object(
                journal_module.base64,
                "b64decode",
                side_effect=AssertionError("count overflow reached decode"),
            ) as decoder, run_evidence._rooted_io(
                self.publication_root, mutation=False
            ), self.assertRaisesRegex(
                ValueError, diagnostic
            ):
                run_evidence._validate_transaction_journal(
                    self.publication_root, journal
                )
            self.assertEqual(decoder.call_count, 0)

        event_target = next(
            target
            for target in transaction["targets"]
            if target["path"].endswith("/bootstrap-events.jsonl")
        )
        event_path = event_target["path"]
        event_content = event_target["content"]
        maximum_line = max(
            len(line) for line in event_content.splitlines()
        )
        with mock.patch.object(
            journal_module,
            "MAX_LIFECYCLE_EVENT_STREAM_BYTES",
            len(event_content),
        ), mock.patch.object(
            journal_module, "MAX_JSONL_LINE_BYTES", maximum_line
        ):
            journal_module._validate_transaction_target_content(
                event_path, event_content
            )
        with mock.patch.object(
            journal_module,
            "MAX_LIFECYCLE_EVENT_STREAM_BYTES",
            len(event_content) - 1,
        ), self.assertRaisesRegex(ValueError, "target .* exceeds"):
            journal_module._validate_transaction_target_content(
                event_path, event_content
            )
        with mock.patch.object(
            journal_module, "MAX_JSONL_LINE_BYTES", maximum_line - 1
        ), self.assertRaisesRegex(ValueError, "JSONL line exceeds"):
            journal_module._validate_transaction_target_content(
                event_path, event_content
            )

    def test_commit_bounds_journal_before_creating_transaction_directory(self):
        _root, transaction = self.capture_init_transaction("commit-bound")
        journal_size = len(run_evidence._json_bytes(transaction["journal"]))
        with mock.patch.object(
            journal_module, "MAX_TRANSACTION_JOURNAL_BYTES", journal_size - 1
        ), run_evidence._rooted_io(
            self.publication_root, mutation=True
        ), self.assertRaisesRegex(
            ValueError, "transaction journal exceeds"
        ):
            journal_module._commit_transaction_unlocked(
                self.publication_root, transaction
            )
        self.assertFalse((self.publication_root / ".transactions").exists())

    def test_matching_replay_targets_are_streamed_without_rewrite(self):
        root, transaction = self.capture_init_transaction("matching-replay")
        first_journal, _content = self.write_pending_journal(
            transaction["journal"]
        )
        with run_evidence._rooted_io(self.publication_root, mutation=True):
            journal_module._apply_transaction(
                self.publication_root, first_journal, transaction
            )
        second_journal, _content = self.write_pending_journal(
            transaction["journal"]
        )
        with mock.patch.object(
            journal_module,
            "_evidence_read_bytes",
            side_effect=AssertionError("matching replay used a full-file read"),
        ), mock.patch.object(
            journal_module,
            "_atomic_write_bytes",
            side_effect=AssertionError("matching replay rewrote a target"),
        ) as writer, run_evidence._rooted_io(
            self.publication_root, mutation=True
        ):
            journal_module._apply_transaction(
                self.publication_root, second_journal, transaction
            )
        self.assertEqual(writer.call_count, 0)
        self.assertTrue((root / "run-context.json").is_file())

    @unittest.skipUnless(os.name == "posix", "requires POSIX file modes")
    def test_orphan_mode_change_after_preflight_is_not_unlinked(self):
        transaction_root = self.publication_root / ".transactions"
        transaction_root.mkdir(mode=0o700)
        orphan = transaction_root / (
            ".init-mode-race-0123456789abcdef.json.abcdefgh.tmp"
        )
        orphan.write_bytes(b"orphan")
        orphan.chmod(0o600)
        original_preflight = journal_module._preflight_pending_transactions

        def change_mode_after_preflight(publication_root, pending):
            original_preflight(publication_root, pending)
            orphan.chmod(0o644)

        with mock.patch.object(
            journal_module,
            "_preflight_pending_transactions",
            side_effect=change_mode_after_preflight,
        ), self.assertRaisesRegex(ValueError, "changed before cleanup"):
            run_evidence._recover_pending_transactions(self.publication_root)
        self.assertTrue(orphan.is_file())
        self.assertEqual(orphan.stat().st_mode & 0o777, 0o644)

    def test_recovery_directory_preflight_does_not_borrow_later_declarations(self):
        earlier = {
            "requiredDirectories": ["attempts/earlier/child"],
            "targets": [],
        }
        later = {
            "requiredDirectories": ["attempts", "attempts/earlier"],
            "targets": [],
        }
        pending = [
            (self.publication_root / "earlier.json", earlier),
            (self.publication_root / "later.json", later),
        ]
        with run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "parent is unsafe"
        ):
            journal_module._preflight_pending_transactions(
                self.publication_root, pending
            )

    def test_pending_journal_read_is_bound_to_inventory_metadata(self):
        root, transaction = self.capture_init_transaction("inventory-binding")
        journal_path, content = self.write_pending_journal(
            transaction["journal"]
        )
        original_loader = journal_module._load_transactions_from_paths

        def grow_after_inventory(publication_root, inventory):
            journal_path.write_bytes(content + b" " * 4096)
            return original_loader(publication_root, inventory)

        with mock.patch.object(
            journal_module,
            "MAX_PENDING_TRANSACTION_BYTES",
            len(content),
        ), mock.patch.object(
            journal_module,
            "MAX_TRANSACTION_JOURNAL_BYTES",
            len(content) + 4096,
        ), mock.patch.object(
            journal_module,
            "_load_transactions_from_paths",
            side_effect=grow_after_inventory,
        ), self.assertRaisesRegex(
            run_evidence.RootedIOError, "changed while scanning"
        ):
            run_evidence._recover_pending_transactions(self.publication_root)

        self.assertTrue(journal_path.is_file())
        self.assertFalse(root.exists())

    def test_target_parent_scan_accepts_public_bundle_sized_directories(self):
        context = valid_context(
            runId="target-parent-bound",
            executionId="target-parent-bound-execution",
        )
        root = self.attempt_root(context["runId"])
        run_evidence._initialize_attempt(self.index_path, root, context)
        commands = root / "commands"
        public_directory_limit = max(
            4096, run_evidence.MAX_BUNDLE_FILE_COUNT
        )
        for index in range(run_evidence.MAX_BUNDLE_FILE_COUNT):
            (commands / f"artifact-{index:04d}.log").write_bytes(b"safe")
        for index in range(public_directory_limit - 1):
            (commands / f"child-{index:04d}").mkdir()
        target = commands / "future.log"

        with run_evidence._rooted_io(
            self.publication_root, mutation=False
        ):
            self.assertEqual(
                journal_module._validated_target_temporaries(target), []
            )

        for index in range(run_evidence.MAX_TRANSACTION_DIRECTORY_ENTRY_COUNT):
            (commands / f"transaction-control-{index:03d}").write_bytes(b"")
        self.assertEqual(
            len(tuple(commands.iterdir())),
            run_evidence.MAX_TRANSACTION_TARGET_PARENT_ENTRY_COUNT,
        )
        with run_evidence._rooted_io(
            self.publication_root, mutation=False
        ):
            self.assertEqual(
                journal_module._validated_target_temporaries(target), []
            )

        (commands / "over-production-limit").write_bytes(b"")
        with run_evidence._rooted_io(
            self.publication_root, mutation=False
        ), self.assertRaisesRegex(
            ValueError, "target parent directory entry count"
        ):
            journal_module._validated_target_temporaries(target)

    def _assert_unlink_replacement_is_preserved(
        self, victim, replacement, operation
    ):
        original = victim.with_name(victim.name + ".original")
        replacement_content = replacement.read_bytes()
        swapped = False

        def swap_at_unlink(actual_operation, phase, path):
            nonlocal swapped
            if (
                not swapped
                and actual_operation == "unlink"
                and phase == "before_unlink"
                and Path(path) == victim
            ):
                victim.replace(original)
                replacement.replace(victim)
                swapped = True

        with mock.patch.object(
            run_evidence.safe_io,
            "_rooted_io_checkpoint",
            side_effect=swap_at_unlink,
        ), self.assertRaisesRegex(
            run_evidence.RootedIOError, "unlink target binding changed"
        ):
            operation()

        self.assertTrue(swapped)
        self.assertEqual(victim.read_bytes(), replacement_content)
        self.assertTrue(original.is_file())

    def test_orphan_cleanup_binds_identity_through_unlink(self):
        transaction_root = self.publication_root / ".transactions"
        transaction_root.mkdir(mode=0o700)
        orphan = transaction_root / (
            ".init-unlink-race-0123456789abcdef.json.abcdefgh.tmp"
        )
        orphan.write_bytes(b"original orphan")
        orphan.chmod(0o600)
        replacement = self.publication_root / "replacement-orphan"
        replacement.write_bytes(b"replacement orphan")
        replacement.chmod(0o600)

        self._assert_unlink_replacement_is_preserved(
            orphan,
            replacement,
            lambda: run_evidence._recover_pending_transactions(
                self.publication_root
            ),
        )

    def test_target_temporary_cleanup_binds_identity_through_unlink(self):
        _root, transaction = self.capture_init_transaction("target-unlink-race")
        self.write_pending_journal(transaction["journal"])
        temporary = self.publication_root / ".attempt-index.json.abcdefgh.tmp"
        temporary.write_bytes(b"original target temporary")
        temporary.chmod(0o600)
        replacement = self.publication_root / "replacement-target-temporary"
        replacement.write_bytes(b"replacement target temporary")
        replacement.chmod(0o600)

        self._assert_unlink_replacement_is_preserved(
            temporary,
            replacement,
            lambda: run_evidence._recover_pending_transactions(
                self.publication_root
            ),
        )

    def test_final_journal_cleanup_binds_identity_through_unlink(self):
        _root, transaction = self.capture_init_transaction("journal-unlink-race")
        journal_path, content = self.write_pending_journal(
            transaction["journal"]
        )
        replacement = self.publication_root / "replacement-journal"
        replacement.write_bytes(content)
        replacement.chmod(0o600)

        self._assert_unlink_replacement_is_preserved(
            journal_path,
            replacement,
            lambda: run_evidence._recover_pending_transactions(
                self.publication_root
            ),
        )
