"""Owner, borrower, takeover, and owner-only session authority cases."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from unittest import mock

from scripts.run_evidence_lib import command_state, session as session_api

from . import command_state as state_cases
from . import support


class FakeProcessBackend:
    def __init__(self, identities, parents=None, absent=None):
        self.identities = dict(identities)
        self.parents = dict(parents or {})
        self.absent = set(absent or ())

    def current_identity(self, pid):
        if pid not in self.identities:
            raise ProcessLookupError(pid)
        return self.identities[pid]

    def parent_pid(self, pid):
        return self.parents.get(pid, 0)

    def predecessor_absent(self, pid, identity):
        return (pid, identity) in self.absent


class SessionAuthorityTests(support.StorageTestCase):
    def setUp(self):
        super().setUp()
        self.root = self.attempt_root("session-authority")
        context = support.valid_context(
            runId=self.root.name,
            executionId="session-authority-execution",
        )
        support.run_evidence._initialize_attempt(
            self.index_path, self.root, context
        )

    def cli(self, *arguments, timeout=15):
        return subprocess.run(
            [
                sys.executable,
                str(support.MODULE_PATH),
                *map(str, arguments),
            ],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def claim(self):
        result = self.cli(
            "session-claim",
            "--root",
            self.root,
            "--owner-pid",
            os.getpid(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_owner_claim_status_and_close_are_generation_bound(self):
        claimed = self.claim()
        self.assertEqual(
            set(claimed),
            {
                "schemaVersion",
                "sessionId",
                "generation",
                "state",
                "role",
                "ownerPid",
            },
        )
        self.assertRegex(claimed["sessionId"], r"^[0-9a-f]{32}$")
        self.assertEqual(claimed["generation"], 1)
        self.assertEqual(claimed["state"], "active")
        self.assertEqual(claimed["role"], "owner")
        self.assertEqual(claimed["ownerPid"], os.getpid())

        replay = self.claim()
        self.assertEqual(replay, claimed)

        status = self.cli(
            "session-status",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
        )
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout), claimed)

        closed = self.cli(
            "session-close",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
        )
        self.assertEqual(closed.returncode, 0, closed.stderr)
        closed_payload = json.loads(closed.stdout)
        self.assertEqual(closed_payload["state"], "finalizing")
        self.assertEqual(closed_payload["role"], "owner")

        stale = self.cli(
            "session-status",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            2,
        )
        self.assertEqual(stale.returncode, 2)
        self.assertEqual(
            json.loads(
                (
                    self.root
                    / ".evidence-control"
                    / "session.json"
                ).read_text(encoding="utf-8")
            )["state"],
            "finalizing",
        )

    def test_spoofed_owner_pid_is_rejected_before_control_creation(self):
        result = self.cli(
            "session-claim",
            "--root",
            self.root,
            "--owner-pid",
            os.getpid() + 100000,
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / ".evidence-control").exists())

    def test_descendant_is_borrower_and_cannot_close_owner_session(self):
        claimed = self.claim()
        helper = r'''
import json,subprocess,sys
command=[sys.executable,sys.argv[1],"session-status","--root",sys.argv[2],"--session-id",sys.argv[3],"--generation","1"]
status=subprocess.run(command,capture_output=True,text=True,check=False)
close=subprocess.run([sys.executable,sys.argv[1],"session-close","--root",sys.argv[2],"--session-id",sys.argv[3],"--generation","1"],capture_output=True,text=True,check=False)
print(json.dumps({"statusCode":status.returncode,"status":status.stdout,"statusError":status.stderr,"closeCode":close.returncode,"closeError":close.stderr},sort_keys=True,separators=(",",":")))
'''
        process = subprocess.run(
            [
                sys.executable,
                "-c",
                helper,
                str(support.MODULE_PATH),
                str(self.root),
                claimed["sessionId"],
            ],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        observed = json.loads(process.stdout)
        self.assertEqual(observed["statusCode"], 0, observed["statusError"])
        borrower = json.loads(observed["status"])
        self.assertEqual(borrower["role"], "borrower")
        self.assertEqual(borrower["ownerPid"], os.getpid())
        self.assertEqual(observed["closeCode"], 2)

        owner_status = self.cli(
            "session-status",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
        )
        self.assertEqual(owner_status.returncode, 0, owner_status.stderr)
        self.assertEqual(json.loads(owner_status.stdout)["state"], "active")

    def test_orphan_takeover_increments_generation_and_stales_old_authority(self):
        old_owner = 70001
        new_owner = 70002
        command_state.initialize_control_layout(
            self.root,
            state_cases.valid_session(
                runId=self.root.name,
                ownerPid=old_owner,
                ownerBirthIdentity="test:old-owner",
            ),
        )
        backend = FakeProcessBackend(
            {new_owner: "test:new-owner"},
            absent={(old_owner, "test:old-owner")},
        )
        takeover = session_api.claim_session(
            self.root,
            new_owner,
            caller_pid=new_owner,
            process_backend=backend,
            session_id_factory=lambda: "f" * 32,
        )
        self.assertEqual(takeover["sessionId"], state_cases.SESSION_ID)
        self.assertEqual(takeover["generation"], 2)
        self.assertEqual(takeover["ownerPid"], new_owner)
        self.assertEqual(takeover["role"], "owner")
        stored = command_state.read_session(self.root)
        self.assertEqual(stored["ownerBirthIdentity"], "test:new-owner")
        self.assertEqual(stored["generation"], 2)

        with self.assertRaises(ValueError):
            session_api.session_status(
                self.root,
                state_cases.SESSION_ID,
                1,
                caller_pid=new_owner,
                process_backend=backend,
            )

    def test_live_owner_and_live_supervisor_each_block_takeover(self):
        old_owner = 71001
        new_owner = 71002
        command_state.initialize_control_layout(
            self.root,
            state_cases.valid_session(
                runId=self.root.name,
                ownerPid=old_owner,
                ownerBirthIdentity="test:old-owner",
            ),
        )
        live_owner_backend = FakeProcessBackend(
            {
                old_owner: "test:old-owner",
                new_owner: "test:new-owner",
            }
        )
        with self.assertRaises(PermissionError):
            session_api.claim_session(
                self.root,
                new_owner,
                caller_pid=new_owner,
                process_backend=live_owner_backend,
            )
        self.assertEqual(command_state.read_session(self.root)["generation"], 1)

        lease = command_state.reserve_command_layout(
            self.root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
        )
        try:
            prepared = state_cases.valid_command_state(
                "prepared",
                supervisor=state_cases.valid_supervisor(
                    pid=os.getpid(),
                    birthIdentity="test:live-supervisor",
                    leaseIdentity=lease.identity,
                ),
                anchorReservation=lease.anchor_reservation,
            )
            command_state.create_command_state(
                self.root, prepared, supervisor_lease=lease
            )
            orphan_backend = FakeProcessBackend(
                {new_owner: "test:new-owner"},
                absent={(old_owner, "test:old-owner")},
            )
            with self.assertRaises(TimeoutError):
                session_api.claim_session(
                    self.root,
                    new_owner,
                    caller_pid=new_owner,
                    process_backend=orphan_backend,
                )
        finally:
            lease.close()
        self.assertEqual(command_state.read_session(self.root)["generation"], 1)

    def test_borrower_may_defer_failure_but_not_pass_intent(self):
        claimed = self.claim()
        failure = {
            "status": "failed",
            "classification": "runner_failure",
            "phase": "scenario.execute",
            "errorCode": "runner.unclassified",
            "summary": "borrowed command failed",
            "hint": "inspect command evidence",
            "commandStatus": 7,
            "source": "borrower-test",
        }
        passed = {
            "status": "passed",
            "classification": "passed",
            "phase": "evidence.finalize",
            "commandStatus": None,
            "source": "borrower-test",
        }
        helper = r'''
import json,subprocess,sys
base=[sys.executable,sys.argv[1],"session-intent","--root",sys.argv[2],"--session-id",sys.argv[3],"--generation","1"]
failure=subprocess.run(base+["--intent-json",sys.argv[4]],capture_output=True,text=True,check=False)
passed=subprocess.run(base+["--intent-json",sys.argv[5]],capture_output=True,text=True,check=False)
print(json.dumps({"failureCode":failure.returncode,"failure":failure.stdout,"failureError":failure.stderr,"passCode":passed.returncode,"passError":passed.stderr},sort_keys=True,separators=(",",":")))
'''
        process = subprocess.run(
            [
                sys.executable,
                "-c",
                helper,
                str(support.MODULE_PATH),
                str(self.root),
                claimed["sessionId"],
                json.dumps(failure, separators=(",", ":")),
                json.dumps(passed, separators=(",", ":")),
            ],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        observed = json.loads(process.stdout)
        self.assertEqual(
            observed["failureCode"], 0, observed["failureError"]
        )
        intent = json.loads(observed["failure"])
        self.assertEqual(intent["primary"]["errorCode"], "runner.unclassified")
        self.assertEqual(intent["primary"]["recordedGeneration"], 1)
        self.assertEqual(observed["passCode"], 2)
        retained = command_state.read_terminal_intent(self.root)
        self.assertEqual(retained["nextOrdinal"], 2)
        self.assertEqual(len(retained["secondary"]), 0)

    def test_only_owner_finalizes_and_removes_verified_control_state(self):
        claimed = self.claim()
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>session-finalized</html>", encoding="utf-8")
        passed = {
            "status": "passed",
            "classification": "passed",
            "phase": "evidence.finalize",
            "commandStatus": None,
            "source": "owner-test",
        }
        intent = self.cli(
            "session-intent",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
            "--intent-json",
            json.dumps(passed, separators=(",", ":")),
        )
        self.assertEqual(intent.returncode, 0, intent.stderr)

        borrower_helper = r'''
import subprocess,sys
result=subprocess.run([sys.executable,sys.argv[1],"session-finalize","--root",sys.argv[2],"--session-id",sys.argv[3],"--generation","1"],capture_output=True,text=True,check=False)
print(result.returncode)
print(result.stderr,end="")
'''
        borrower = subprocess.run(
            [
                sys.executable,
                "-c",
                borrower_helper,
                str(support.MODULE_PATH),
                str(self.root),
                claimed["sessionId"],
            ],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(borrower.returncode, 0, borrower.stderr)
        self.assertTrue(borrower.stdout.startswith("2\n"), borrower.stdout)
        self.assertFalse((self.root / "run-summary.json").exists())

        closed = self.cli(
            "session-close",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
        )
        self.assertEqual(closed.returncode, 0, closed.stderr)
        finalized = self.cli(
            "session-finalize",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
        )
        self.assertEqual(finalized.returncode, 0, finalized.stderr)
        summary = json.loads(finalized.stdout)
        self.assertEqual(summary["status"], "passed", summary)
        self.assertEqual(summary["classification"], "passed")
        self.assertIsNone(summary["commandStatus"])
        self.assertFalse((self.root / ".evidence-control").exists())
        self.assertEqual(
            support.run_evidence.validate_bundle(self.root, secrets=[]), []
        )
        replay = self.cli(
            "session-finalize",
            "--root",
            self.root,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
        )
        self.assertEqual(replay.returncode, 0, replay.stderr)
        self.assertEqual(json.loads(replay.stdout), summary)

    def test_finalize_retry_resumes_control_retirement_after_rename(self):
        claimed = self.claim()
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>retry</html>", encoding="utf-8")
        session_api.record_session_intent(
            self.root,
            claimed["sessionId"],
            1,
            {
                "status": "passed",
                "classification": "passed",
                "phase": "evidence.finalize",
                "commandStatus": None,
                "source": "retry-test",
            },
            caller_pid=os.getpid(),
        )
        session_api.close_session(
            self.root,
            claimed["sessionId"],
            1,
            caller_pid=os.getpid(),
        )
        with mock.patch.object(
            command_state,
            "_delete_control_retirement_unlocked",
            side_effect=RuntimeError("crash after control rename"),
        ), self.assertRaisesRegex(RuntimeError, "crash after control rename"):
            session_api.finalize_session(
                self.root,
                claimed["sessionId"],
                1,
                caller_pid=os.getpid(),
            )
        self.assertFalse((self.root / ".evidence-control").exists())
        self.assertTrue(
            (
                self.root
                / command_state.CONTROL_RETIREMENT_NAME
            ).is_dir()
        )
        self.assertTrue((self.root / "run-summary.json").is_file())

        replay = session_api.finalize_session(
            self.root,
            claimed["sessionId"],
            1,
            caller_pid=os.getpid(),
        )
        self.assertEqual(replay["status"], "passed")
        self.assertFalse(
            (self.root / command_state.CONTROL_RETIREMENT_NAME).exists()
        )
        self.assertEqual(
            support.run_evidence.validate_bundle(self.root, secrets=[]), []
        )

    def test_finalize_retry_resumes_after_committed_state_before_cleanup(self):
        claimed = self.claim()
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>committed-retry</html>", encoding="utf-8")
        session_api.record_session_intent(
            self.root,
            claimed["sessionId"],
            1,
            {
                "status": "passed",
                "classification": "passed",
                "phase": "evidence.finalize",
                "commandStatus": None,
                "source": "committed-retry-test",
            },
            caller_pid=os.getpid(),
        )
        session_api.close_session(
            self.root,
            claimed["sessionId"],
            1,
            caller_pid=os.getpid(),
        )
        with mock.patch.object(
            command_state,
            "cleanup_committed_control_layout",
            side_effect=RuntimeError("crash before control cleanup"),
        ), self.assertRaisesRegex(RuntimeError, "crash before control cleanup"):
            session_api.finalize_session(
                self.root,
                claimed["sessionId"],
                1,
                caller_pid=os.getpid(),
            )
        self.assertEqual(command_state.read_session(self.root)["state"], "committed")
        self.assertTrue((self.root / "run-summary.json").is_file())

        replay = session_api.finalize_session(
            self.root,
            claimed["sessionId"],
            1,
            caller_pid=os.getpid(),
        )
        self.assertEqual(replay["status"], "passed")
        self.assertFalse((self.root / ".evidence-control").exists())
        self.assertEqual(
            support.run_evidence.validate_bundle(self.root, secrets=[]), []
        )

    def test_finalization_retires_private_state_for_committed_command(self):
        claimed = self.claim()
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>command-session</html>", encoding="utf-8")
        command_id = state_cases.COMMAND_ID
        command = self.cli(
            "command-supervise",
            "--root",
            self.root,
            "--command-id",
            command_id,
            "--session-id",
            claimed["sessionId"],
            "--generation",
            1,
            "--phase",
            "scenario.execute",
            "--name",
            "session-command",
            "--failure-code",
            "runner.driver_protocol",
            "--failure-policy",
            "handled",
            "--stop-policy",
            "none",
            "--mode",
            "foreground",
            "--stdin-policy",
            "devnull",
            "--",
            sys.executable,
            "-c",
            "print('session-command-output')",
        )
        self.assertEqual(command.returncode, 0, command.stderr)
        self.assertEqual(command.stdout, "session-command-output\n")
        stored = command_state.read_command_state(
            self.root, command_id, claimed["sessionId"]
        )
        self.assertEqual(stored["stage"], "committed")
        metadata_path = self.root / stored["paths"]["metadata"]
        self.assertTrue(metadata_path.is_file())

        session_api.record_session_intent(
            self.root,
            claimed["sessionId"],
            1,
            {
                "status": "passed",
                "classification": "passed",
                "phase": "evidence.finalize",
                "commandStatus": 0,
                "source": "command-session-test",
            },
            caller_pid=os.getpid(),
        )
        session_api.close_session(
            self.root,
            claimed["sessionId"],
            1,
            caller_pid=os.getpid(),
        )
        summary = session_api.finalize_session(
            self.root,
            claimed["sessionId"],
            1,
            caller_pid=os.getpid(),
        )
        self.assertEqual(summary["status"], "passed", summary)
        self.assertEqual(summary["commandStatus"], 0)
        self.assertTrue(metadata_path.is_file())
        self.assertFalse((self.root / ".evidence-control").exists())
        self.assertEqual(
            support.run_evidence.validate_bundle(self.root, secrets=[]), []
        )
