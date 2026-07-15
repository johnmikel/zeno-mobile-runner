"""Trusted-anchor, process-group, and recovery-proof cases."""

from __future__ import annotations

import json
import os
import select
import signal
import subprocess
import sys
import threading
import time

from scripts.run_evidence_lib import command_state, command_supervisor, safe_io

from . import command_state as state_cases
from . import support


class CommandSupervisorTests(state_cases.CommandStateTestCase):
    def setUp(self):
        super().setUp()
        self.initialize()
        self.reservation = command_state.reserve_command_layout(
            self.attempt_root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
        )
        self.addCleanup(self.reservation.close)
        self.anchors = []

    def tearDown(self):
        for anchor in reversed(self.anchors):
            anchor.abort()
        super().tearDown()

    def launch(self, script):
        anchor = command_supervisor.TrustedAnchor.launch(
            root=self.attempt_root,
            command_id=state_cases.COMMAND_ID,
            group_lease_identity=self.reservation.anchor_reservation[
                "groupLeaseIdentity"
            ],
            argv=[sys.executable, "-c", script],
            stdin_policy="devnull",
        )
        self.anchors.append(anchor)
        return anchor

    def prepare(self, argv, *, stop_policy="none"):
        backend = command_supervisor.ProcessBackend()
        request = state_cases.valid_request(
            sanitizedArgv=list(argv), stopPolicy=stop_policy
        )
        prepared = state_cases.valid_command_state(
            "prepared",
            request=request,
            supervisor=state_cases.valid_supervisor(
                pid=os.getpid(),
                birthIdentity=backend.current_identity(os.getpid()),
                leaseIdentity=self.reservation.identity,
            ),
            anchorReservation=self.reservation.anchor_reservation,
        )
        command_state.create_command_state(
            self.attempt_root,
            prepared,
            supervisor_lease=self.reservation,
        )
        with (self.attempt_root / "bootstrap-events.jsonl").open("ab") as stream:
            stream.write(
                (
                    json.dumps(
                        prepared["startedEvent"],
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
            )
            stream.flush()
            os.fsync(stream.fileno())
        return prepared

    def assert_group_lease_held(self):
        authority = safe_io._RootedIO(self.publication_root)
        try:
            context = authority.lease(
                self.attempt_root
                / ".evidence-control"
                / "commands"
                / state_cases.COMMAND_ID
                / "group.lease",
                timeout=0.0,
            )
            with self.assertRaises(TimeoutError):
                context.__enter__()
        finally:
            authority.close()

    def test_linux_stat_parser_is_parentheses_safe_and_identity_is_stable(self):
        fields = ["R", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        fields.extend(str(index) for index in range(10, 40))
        stat_line = "123 (name with ) and ( spaces) " + " ".join(fields)
        self.assertEqual(
            command_supervisor._linux_start_ticks_from_stat(stat_line),
            fields[19],
        )

        backend = command_supervisor.ProcessBackend()
        identity = backend.current_identity(os.getpid())
        self.assertEqual(backend.current_identity(os.getpid()), identity)
        self.assertRegex(identity, r"^(linux|macos):")
        self.assertIs(backend.predecessor_absent(os.getpid(), identity), False)
        self.assertIs(
            backend.predecessor_absent(os.getpid(), identity + ":changed"),
            True,
        )

    def test_anchor_owns_session_group_and_lease_after_child_closes_fds(self):
        script = (
            "import json,os,resource,time\n"
            "limit=min(resource.getrlimit(resource.RLIMIT_NOFILE)[0],256)\n"
            "for fd in range(3,int(limit)):\n"
            " try: os.close(fd)\n"
            " except OSError: pass\n"
            "print(json.dumps({'pid':os.getpid(),'sid':os.getsid(0),"
            "'pgid':os.getpgid(0)}),flush=True)\n"
            "time.sleep(0.4)\n"
        )
        anchor = self.launch(script)
        record = anchor.anchor_record
        self.assertEqual(record["pid"], anchor.pid)
        self.assertEqual(record["sid"], anchor.pid)
        self.assertEqual(record["pgid"], anchor.pid)
        self.assertEqual(
            record["groupLeaseIdentity"],
            self.reservation.anchor_reservation["groupLeaseIdentity"],
        )
        self.assert_group_lease_held()

        child = anchor.start()
        self.assertEqual(os.getsid(child["pid"]), anchor.pid)
        self.assertEqual(os.getpgid(child["pid"]), anchor.pid)
        self.assert_group_lease_held()
        outcome = anchor.wait(timeout=5.0)
        self.assertEqual(outcome["returnCode"], 0)
        observed = json.loads(anchor.stdout.decode("utf-8"))
        self.assertEqual(observed["pid"], child["pid"])
        self.assertEqual(observed["sid"], anchor.pid)
        self.assertEqual(observed["pgid"], anchor.pid)
        self.assert_group_lease_held()

        anchor.acknowledge()
        self.assertEqual(anchor.wait_anchor(timeout=5.0), 0)

    def test_group_term_stops_child_but_not_trusted_anchor(self):
        anchor = self.launch("import time;time.sleep(30)")
        anchor.start()
        os.killpg(anchor.pid, signal.SIGTERM)
        outcome = anchor.wait(timeout=5.0)
        self.assertEqual(outcome["returnCode"], -signal.SIGTERM)
        self.assertIsNone(anchor.poll())
        self.assert_group_lease_held()
        anchor.acknowledge()
        self.assertEqual(anchor.wait_anchor(timeout=5.0), 0)

    def test_executable_never_inherits_the_anchor_group_lease(self):
        anchor = self.launch("import time;time.sleep(30)")
        anchor.start()
        os.kill(anchor.pid, signal.SIGKILL)
        self.assertEqual(anchor.wait_anchor(timeout=5.0), -signal.SIGKILL)

        authority = safe_io._RootedIO(self.publication_root)
        lease_context = authority.lease(
            self.attempt_root
            / ".evidence-control"
            / "commands"
            / state_cases.COMMAND_ID
            / "group.lease",
            timeout=0.0,
        )
        try:
            lease = lease_context.__enter__()
            self.assertEqual(
                lease.identity,
                self.reservation.anchor_reservation["groupLeaseIdentity"],
            )
            lease_context.__exit__(None, None, None)
        finally:
            authority.close()
            try:
                os.killpg(anchor.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_supervisor_eof_keeps_anchor_until_recovery_term(self):
        anchor = self.launch("import time;time.sleep(30)")
        anchor.start()
        anchor.abandon_supervision()
        time.sleep(0.1)
        self.assertIsNone(anchor.poll())
        self.assert_group_lease_held()
        os.killpg(anchor.pid, signal.SIGTERM)
        self.assertEqual(anchor.wait_anchor(timeout=5.0), 0)

    def test_durable_supervisor_persists_anchor_child_capture_and_exit_before_ack(self):
        argv = [
            sys.executable,
            "-c",
            "import sys;sys.stdout.write('out');sys.stderr.write('err')",
        ]
        self.prepare(argv)
        checkpoints = []

        def checkpoint(stage, state):
            checkpoints.append(stage)
            stored = command_state.read_command_state(
                self.attempt_root,
                state_cases.COMMAND_ID,
                state_cases.SESSION_ID,
            )
            self.assertEqual(stored, state)
            if stage == "after_exited":
                self.assert_group_lease_held()

        runner = command_supervisor.DurableCommandSupervisor(
            root=self.attempt_root,
            session_id=state_cases.SESSION_ID,
            generation=1,
            command_id=state_cases.COMMAND_ID,
            supervisor_lease=self.reservation,
            argv=argv,
            checkpoint=checkpoint,
        )
        exited = runner.run()
        self.assertEqual(
            checkpoints,
            ["after_anchored", "after_running", "after_exited", "after_ack"],
        )
        self.assertEqual(exited["stage"], "exited")
        self.assertEqual(exited["anchor"]["pid"], exited["anchor"]["sid"])
        self.assertEqual(exited["anchor"]["pid"], exited["anchor"]["pgid"])
        self.assertEqual(exited["outcome"]["kind"], "exit")
        self.assertEqual(exited["outcome"]["exitStatus"], 0)
        self.assertEqual(exited["outcome"]["shellVisibleStatus"], 0)
        self.assertIs(exited["capture"]["captureComplete"], True)
        command_root = (
            self.attempt_root
            / ".evidence-control"
            / "commands"
            / state_cases.COMMAND_ID
        )
        self.assertEqual((command_root / "stdout.recovery").read_bytes(), b"out")
        self.assertEqual((command_root / "stderr.recovery").read_bytes(), b"err")

    def test_unexpected_child_signal_is_not_reclassified_as_cancellation(self):
        argv = [
            sys.executable,
            "-c",
            "import os,signal;os.kill(os.getpid(),signal.SIGTERM)",
        ]
        self.prepare(argv)
        runner = command_supervisor.DurableCommandSupervisor(
            root=self.attempt_root,
            session_id=state_cases.SESSION_ID,
            generation=1,
            command_id=state_cases.COMMAND_ID,
            supervisor_lease=self.reservation,
            argv=argv,
        )
        exited = runner.run()
        self.assertIsNone(exited["stopIntent"])
        self.assertEqual(exited["outcome"]["kind"], "signal")
        self.assertEqual(exited["outcome"]["signal"], signal.SIGTERM)
        self.assertEqual(
            exited["outcome"]["shellVisibleStatus"], 128 + signal.SIGTERM
        )

    def test_negative_exec_handshake_is_exact_and_never_claims_running(self):
        argv = ["zmr-command-that-does-not-exist-9f2f5e"]
        self.prepare(argv)
        checkpoints = []
        runner = command_supervisor.DurableCommandSupervisor(
            root=self.attempt_root,
            session_id=state_cases.SESSION_ID,
            generation=1,
            command_id=state_cases.COMMAND_ID,
            supervisor_lease=self.reservation,
            argv=argv,
            checkpoint=lambda stage, _state: checkpoints.append(stage),
        )
        exited = runner.run()
        self.assertEqual(
            checkpoints, ["after_anchored", "after_exited", "after_ack"]
        )
        self.assertIsNone(exited["child"])
        self.assertEqual(exited["outcome"]["kind"], "exec_failure")
        self.assertEqual(exited["outcome"]["exitStatus"], 127)
        self.assertEqual(exited["outcome"]["shellVisibleStatus"], 127)
        self.assertIs(exited["capture"]["captureComplete"], True)
        self.assertEqual(exited["capture"]["stdout"]["storedBytes"], 0)
        self.assertGreater(exited["capture"]["stderr"]["storedBytes"], 0)

    def test_expected_stop_is_write_ahead_and_maps_to_shell_success(self):
        argv = [sys.executable, "-c", "import time;time.sleep(30)"]
        self.prepare(argv, stop_policy="expected-term")
        running = threading.Event()
        runner = command_supervisor.DurableCommandSupervisor(
            root=self.attempt_root,
            session_id=state_cases.SESSION_ID,
            generation=1,
            command_id=state_cases.COMMAND_ID,
            supervisor_lease=self.reservation,
            argv=argv,
            checkpoint=lambda stage, _state: (
                running.set() if stage == "after_running" else None
            ),
        )
        results = []
        errors = []

        def execute():
            try:
                results.append(runner.run())
            except BaseException as exc:
                errors.append(exc)

        worker = threading.Thread(target=execute)
        worker.start()
        self.assertTrue(running.wait(5.0))
        requested = runner.request_stop("expected")
        self.assertEqual(requested["stage"], "stop_requested")
        self.assertIsNone(requested["stopIntent"]["killAuthorizedAt"])
        worker.join(timeout=8.0)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        exited = results[0]
        self.assertEqual(exited["stopIntent"]["kind"], "expected")
        self.assertEqual(exited["outcome"]["kind"], "signal")
        self.assertEqual(exited["outcome"]["signal"], signal.SIGTERM)
        self.assertEqual(exited["outcome"]["shellVisibleStatus"], 0)

    def test_kill_escalation_is_write_ahead_cleanup_failure(self):
        argv = [
            sys.executable,
            "-c",
            "import signal,time;signal.signal(signal.SIGTERM,lambda *_:None);time.sleep(30)",
        ]
        self.prepare(argv, stop_policy="expected-term")
        running = threading.Event()
        runner = command_supervisor.DurableCommandSupervisor(
            root=self.attempt_root,
            session_id=state_cases.SESSION_ID,
            generation=1,
            command_id=state_cases.COMMAND_ID,
            supervisor_lease=self.reservation,
            argv=argv,
            checkpoint=lambda stage, _state: (
                running.set() if stage == "after_running" else None
            ),
        )
        results = []
        worker = threading.Thread(target=lambda: results.append(runner.run()))
        worker.start()
        self.assertTrue(running.wait(5.0))
        runner.request_stop("expected")
        worker.join(timeout=10.0)
        self.assertFalse(worker.is_alive())
        exited = results[0]
        self.assertIsNotNone(exited["stopIntent"]["killAuthorizedAt"])
        self.assertEqual(exited["outcome"]["kind"], "signal")
        self.assertEqual(exited["outcome"]["signal"], signal.SIGKILL)
        self.assertEqual(exited["outcome"]["shellVisibleStatus"], 125)

    def test_direct_child_exit_cannot_leave_a_grandchild_behind(self):
        script = (
            "import os,sys,time;pid=os.fork();"
            "pid==0 and os.execl(sys.executable,sys.executable,'-c',"
            "'import os,time;d=os.open(os.devnull,os.O_RDWR);"
            "[os.dup2(d,f) for f in (0,1,2)];"
            "d>2 and os.close(d);time.sleep(30)');"
            "print(pid,flush=True)"
        )
        argv = [sys.executable, "-c", script]
        self.prepare(argv)
        runner = command_supervisor.DurableCommandSupervisor(
            root=self.attempt_root,
            session_id=state_cases.SESSION_ID,
            generation=1,
            command_id=state_cases.COMMAND_ID,
            supervisor_lease=self.reservation,
            argv=argv,
        )
        exited = runner.run()
        grandchild = int(
            (
                self.attempt_root
                / ".evidence-control"
                / "commands"
                / state_cases.COMMAND_ID
                / "stdout.recovery"
            ).read_text(encoding="utf-8")
        )
        def cleanup_grandchild():
            try:
                os.kill(grandchild, signal.SIGKILL)
            except ProcessLookupError:
                pass

        self.addCleanup(cleanup_grandchild)
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            self.fail(f"grandchild {grandchild} survived command completion")
        self.assertEqual(exited["outcome"]["exitStatus"], 0)
        self.assertIsNone(exited["stopIntent"])

    def test_stubborn_grandchild_forces_durable_cleanup_escalation(self):
        script = (
            "import os,sys,time;pid=os.fork();"
            "pid==0 and os.execl(sys.executable,sys.executable,'-c',"
            "'import os,signal,time;d=os.open(os.devnull,os.O_RDWR);"
            "[os.dup2(d,f) for f in (0,1,2)];d>2 and os.close(d);"
            "signal.signal(signal.SIGTERM,lambda *_:None);time.sleep(30)');"
            "time.sleep(.2);print(pid,flush=True)"
        )
        argv = [sys.executable, "-c", script]
        self.prepare(argv)
        runner = command_supervisor.DurableCommandSupervisor(
            root=self.attempt_root,
            session_id=state_cases.SESSION_ID,
            generation=1,
            command_id=state_cases.COMMAND_ID,
            supervisor_lease=self.reservation,
            argv=argv,
        )
        exited = runner.run()
        self.assertEqual(exited["stopIntent"]["kind"], "cancel")
        self.assertIsNotNone(exited["stopIntent"]["killAuthorizedAt"])
        self.assertEqual(exited["outcome"]["kind"], "exit")
        self.assertEqual(exited["outcome"]["exitStatus"], 0)
        self.assertEqual(exited["outcome"]["shellVisibleStatus"], 125)

    def test_lost_supervisor_recovery_stops_group_and_materializes_once(self):
        self.reservation.close()
        (self.attempt_root / "commands").mkdir(mode=0o700)
        initial_events = [
            {
                "schemaVersion": 1,
                "seq": sequence,
                "timestamp": f"2026-07-11T00:00:0{sequence}Z",
                "phase": "evidence.init",
                "status": status,
            }
            for sequence, status in ((1, "started"), (2, "passed"))
        ]
        events_path = self.attempt_root / "bootstrap-events.jsonl"
        events_path.write_bytes(
            b"".join(
                (
                    json.dumps(event, sort_keys=True, separators=(",", ":"))
                    + "\n"
                ).encode("utf-8")
                for event in initial_events
            )
        )
        events_path.chmod(0o600)
        helper = r'''
import json,os,signal,sys
from pathlib import Path
from scripts.run_evidence_lib import command_state,command_supervisor
from tests.run_evidence_cases import command_state as cases
root=Path(sys.argv[1])
lease=command_state.reserve_command_layout(root,cases.SESSION_ID,1,cases.COMMAND_ID)
backend=command_supervisor.ProcessBackend()
argv=[sys.executable,"-c","import time;time.sleep(30)"]
request=cases.valid_request(sanitizedArgv=argv)
prepared=cases.valid_command_state("prepared",request=request,supervisor=cases.valid_supervisor(pid=os.getpid(),birthIdentity=backend.current_identity(os.getpid()),leaseIdentity=lease.identity),anchorReservation=lease.anchor_reservation)
command_state.create_command_state(root,prepared,supervisor_lease=lease)
with (root/"bootstrap-events.jsonl").open("ab") as stream:
 stream.write((json.dumps(prepared["startedEvent"],sort_keys=True,separators=(",",":"))+"\n").encode())
 stream.flush();os.fsync(stream.fileno())
def checkpoint(stage,state):
 if stage=="after_running": os.kill(os.getpid(),signal.SIGKILL)
command_supervisor.DurableCommandSupervisor(root=root,session_id=cases.SESSION_ID,generation=1,command_id=cases.COMMAND_ID,supervisor_lease=lease,argv=argv,checkpoint=checkpoint).run()
'''
        process = subprocess.Popen(
            [sys.executable, "-c", helper, str(self.attempt_root)],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        _stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, -signal.SIGKILL, stderr)
        orphaned = command_state.read_command_state(
            self.attempt_root,
            state_cases.COMMAND_ID,
            state_cases.SESSION_ID,
        )
        self.assertEqual(orphaned["stage"], "running")
        anchor = dict(orphaned["anchor"])
        def cleanup_orphan_group():
            try:
                os.killpg(anchor["pgid"], signal.SIGKILL)
            except ProcessLookupError:
                pass

        self.addCleanup(cleanup_orphan_group)

        recovered = command_supervisor.recover_command(
            self.attempt_root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
            process_backend=command_supervisor.ProcessBackend(),
        )
        self.assertEqual(recovered["stage"], "committed")
        self.assertEqual(recovered["supervisor"]["role"], "recovery")
        self.assertEqual(recovered["outcome"]["kind"], "supervisor_failure")
        self.assertEqual(
            recovered["outcome"]["errorCode"],
            "runner.command_supervisor_lost",
        )
        self.assertIs(recovered["capture"]["captureComplete"], False)
        metadata = json.loads(
            (
                self.attempt_root
                / recovered["materialized"]["metadata"]["path"]
            ).read_bytes()
        )
        self.assertIs(metadata["supervisorFailure"], True)
        self.assertIs(metadata["captureComplete"], False)
        self.assertTrue(
            command_supervisor.prove_group_absent(
                anchor,
                group_lease_free=True,
                backend=command_supervisor.ProcessBackend(),
            )
        )
        replay = command_supervisor.recover_command(
            self.attempt_root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
            process_backend=command_supervisor.ProcessBackend(),
        )
        self.assertEqual(replay, recovered)

    def test_owner_sigterm_persists_cancel_before_forwarding_to_group(self):
        self.reservation.close()
        helper = r'''
import os,sys
from pathlib import Path
from scripts.run_evidence_lib import command_state,command_supervisor
from tests.run_evidence_cases import command_state as cases
root=Path(sys.argv[1])
lease=command_state.reserve_command_layout(root,cases.SESSION_ID,1,cases.COMMAND_ID)
backend=command_supervisor.ProcessBackend()
argv=[sys.executable,"-c","import time;time.sleep(30)"]
request=cases.valid_request(sanitizedArgv=argv)
prepared=cases.valid_command_state("prepared",request=request,supervisor=cases.valid_supervisor(pid=os.getpid(),birthIdentity=backend.current_identity(os.getpid()),leaseIdentity=lease.identity),anchorReservation=lease.anchor_reservation)
command_state.create_command_state(root,prepared,supervisor_lease=lease)
def checkpoint(stage,state):
 if stage=="after_running": print("READY",flush=True)
result=command_supervisor.DurableCommandSupervisor(root=root,session_id=cases.SESSION_ID,generation=1,command_id=cases.COMMAND_ID,supervisor_lease=lease,argv=argv,checkpoint=checkpoint).run()
print("RESULT",result["outcome"]["shellVisibleStatus"],flush=True)
'''
        process = subprocess.Popen(
            [sys.executable, "-c", helper, str(self.attempt_root)],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None
        ready, _write, _error = select.select([process.stdout], [], [], 8.0)
        self.assertTrue(ready)
        self.assertEqual(process.stdout.readline().strip(), "READY")
        os.kill(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        state = command_state.read_command_state(
            self.attempt_root,
            state_cases.COMMAND_ID,
            state_cases.SESSION_ID,
        )
        if state["anchor"] is not None:
            self.addCleanup(
                lambda: (
                    os.killpg(state["anchor"]["pgid"], signal.SIGKILL)
                    if command_supervisor.ProcessBackend().group_probe(
                        state["anchor"]["pgid"]
                    )
                    == "present"
                    else None
                )
            )
        self.assertEqual(process.returncode, 0, stderr)
        self.assertIn("RESULT 130", stdout)
        self.assertEqual(state["stage"], "exited")
        self.assertEqual(state["stopIntent"]["kind"], "cancel")
        self.assertIsNone(state["stopIntent"]["killAuthorizedAt"])
        self.assertEqual(state["outcome"]["signal"], signal.SIGTERM)
        self.assertEqual(state["outcome"]["shellVisibleStatus"], 130)

    def test_post_exit_supervisor_loss_retains_child_truth_and_reaps_anchor(self):
        self.reservation.close()
        (self.attempt_root / "commands").mkdir(mode=0o700)
        events_path = self.attempt_root / "bootstrap-events.jsonl"
        events_path.write_bytes(
            b"".join(
                (
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "seq": sequence,
                            "timestamp": f"2026-07-11T00:00:0{sequence}Z",
                            "phase": "evidence.init",
                            "status": status,
                        },
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
                for sequence, status in ((1, "started"), (2, "passed"))
            )
        )
        events_path.chmod(0o600)
        helper = r'''
import json,os,signal,sys
from pathlib import Path
from scripts.run_evidence_lib import command_state,command_supervisor
from tests.run_evidence_cases import command_state as cases
root=Path(sys.argv[1]);lease=command_state.reserve_command_layout(root,cases.SESSION_ID,1,cases.COMMAND_ID);backend=command_supervisor.ProcessBackend()
argv=[sys.executable,"-c","print('historical-success')"]
request=cases.valid_request(sanitizedArgv=argv)
prepared=cases.valid_command_state("prepared",request=request,supervisor=cases.valid_supervisor(pid=os.getpid(),birthIdentity=backend.current_identity(os.getpid()),leaseIdentity=lease.identity),anchorReservation=lease.anchor_reservation)
command_state.create_command_state(root,prepared,supervisor_lease=lease)
with (root/"bootstrap-events.jsonl").open("ab") as stream:
 stream.write((json.dumps(prepared["startedEvent"],sort_keys=True,separators=(",",":"))+"\n").encode());stream.flush();os.fsync(stream.fileno())
def checkpoint(stage,state):
 if stage=="after_exited": os.kill(os.getpid(),signal.SIGKILL)
command_supervisor.DurableCommandSupervisor(root=root,session_id=cases.SESSION_ID,generation=1,command_id=cases.COMMAND_ID,supervisor_lease=lease,argv=argv,checkpoint=checkpoint).run()
'''
        process = subprocess.run(
            [sys.executable, "-c", helper, str(self.attempt_root)],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        self.assertEqual(process.returncode, -signal.SIGKILL, process.stderr)
        historical = command_state.read_command_state(
            self.attempt_root, state_cases.COMMAND_ID, state_cases.SESSION_ID
        )
        self.assertEqual(historical["stage"], "exited")
        self.assertEqual(historical["outcome"]["exitStatus"], 0)
        anchor = dict(historical["anchor"])
        self.addCleanup(
            lambda: os.killpg(anchor["pgid"], signal.SIGKILL)
            if command_supervisor.ProcessBackend().group_probe(anchor["pgid"])
            == "present"
            else None
        )
        recovered = command_supervisor.recover_command(
            self.attempt_root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
            process_backend=command_supervisor.ProcessBackend(),
        )
        self.assertEqual(recovered["stage"], "committed")
        self.assertEqual(recovered["outcome"]["exitStatus"], 0)
        self.assertIs(recovered["capture"]["captureComplete"], True)
        metadata = json.loads(
            (
                self.attempt_root
                / recovered["materialized"]["metadata"]["path"]
            ).read_bytes()
        )
        self.assertEqual(metadata["exitStatus"], 0)
        self.assertIs(metadata["captureComplete"], True)
        self.assertIs(metadata["supervisorFailure"], True)
        self.assertEqual(
            command_supervisor.ProcessBackend().group_probe(anchor["pgid"]),
            "absent",
        )

    def test_prepared_crash_repairs_started_event_without_spawning(self):
        self.reservation.close()
        (self.attempt_root / "commands").mkdir(mode=0o700)
        events_path = self.attempt_root / "bootstrap-events.jsonl"
        events_path.write_bytes(
            b"".join(
                (
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "seq": sequence,
                            "timestamp": f"2026-07-11T00:00:0{sequence}Z",
                            "phase": "evidence.init",
                            "status": status,
                        },
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode("utf-8")
                for sequence, status in ((1, "started"), (2, "passed"))
            )
        )
        events_path.chmod(0o600)
        helper = r'''
import os,signal,sys
from pathlib import Path
from scripts.run_evidence_lib import command_state,command_supervisor
from tests.run_evidence_cases import command_state as cases
root=Path(sys.argv[1]);lease=command_state.reserve_command_layout(root,cases.SESSION_ID,1,cases.COMMAND_ID);backend=command_supervisor.ProcessBackend();argv=[sys.executable,"-c","raise SystemExit('must-not-run')"]
request=cases.valid_request(sanitizedArgv=argv)
prepared=cases.valid_command_state("prepared",request=request,supervisor=cases.valid_supervisor(pid=os.getpid(),birthIdentity=backend.current_identity(os.getpid()),leaseIdentity=lease.identity),anchorReservation=lease.anchor_reservation)
command_state.create_command_state(root,prepared,supervisor_lease=lease)
os.kill(os.getpid(),signal.SIGKILL)
'''
        process = subprocess.run(
            [sys.executable, "-c", helper, str(self.attempt_root)],
            cwd=support.REPOSITORY_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        self.assertEqual(process.returncode, -signal.SIGKILL, process.stderr)
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root,
                state_cases.COMMAND_ID,
                state_cases.SESSION_ID,
            )["stage"],
            "prepared",
        )
        recovered = command_supervisor.recover_command(
            self.attempt_root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
            process_backend=command_supervisor.ProcessBackend(),
        )
        self.assertEqual(recovered["stage"], "committed")
        self.assertIsNone(recovered["anchor"])
        self.assertIsNone(recovered["child"])
        events = [
            json.loads(line)
            for line in events_path.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual([event["seq"] for event in events], [1, 2, 3, 4])
        self.assertEqual(events[2], recovered["startedEvent"])
        self.assertEqual(events[3]["errorCode"], "runner.command_supervisor_lost")

    def test_group_absence_requires_two_consistent_settled_probes(self):
        anchor = {
            "pid": 4321,
            "birthIdentity": "linux:boot:10",
            "sid": 4321,
            "pgid": 4321,
        }

        class Backend:
            def __init__(self, probes, absent=True):
                self.probes = list(probes)
                self.absent = absent

            def predecessor_absent(self, pid, identity):
                self.observed = (pid, identity)
                return self.absent

            def group_probe(self, pgid):
                self.pgid = pgid
                return self.probes.pop(0)

        backend = Backend(["absent", "absent"])
        self.assertTrue(
            command_supervisor.prove_group_absent(
                anchor,
                group_lease_free=True,
                backend=backend,
                settle=lambda: None,
            )
        )
        self.assertEqual(backend.observed, (4321, "linux:boot:10"))

        for backend in (
            Backend(["present", "absent"]),
            Backend(["absent", "present"]),
            Backend(["absent", "absent"], absent=False),
        ):
            with self.subTest(probes=backend.probes, absent=backend.absent):
                with self.assertRaises(ValueError):
                    command_supervisor.prove_group_absent(
                        anchor,
                        group_lease_free=True,
                        backend=backend,
                        settle=lambda: None,
                    )

        with self.assertRaises(TimeoutError):
            command_supervisor.prove_group_absent(
                anchor,
                group_lease_free=False,
                backend=Backend(["absent", "absent"]),
                settle=lambda: None,
            )
