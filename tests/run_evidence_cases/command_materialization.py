"""Crash-safe command materialization and exact event-repair contracts."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import inspect
import json
import os
import stat
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from scripts.run_evidence_lib import command_state, commands, safe_io

from . import command_state as state_cases
from . import support


STDOUT = b"stdout bytes"
STDERR = b"stderr bytes"


class InjectedCrash(OSError):
    """A deterministic process-loss boundary used by replay tests."""


def canonical_line(value):
    return (
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def noncanonical_line(value):
    encoded = json.dumps(
        value,
        sort_keys=False,
        separators=(", ", ": "),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8") + b"\n"
    assert json.loads(encoded) == value
    assert encoded != canonical_line(value)
    return encoded


class CommandMaterializationTests(support.StorageTestCase):
    def setUp(self):
        super().setUp()
        self.fixture_number = 0
        self.leases = []

    def tearDown(self):
        for lease in reversed(self.leases):
            lease.close()
        super().tearDown()

    def require_api(self, name):
        api = getattr(commands, name, None)
        self.assertTrue(callable(api), f"missing command materialization API: {name}")
        return api

    def fixture(
        self,
        *,
        kind="success",
        append_started=True,
        started_seq=3,
        durable_stage="exited",
        failure_code=None,
    ):
        self.fixture_number += 1
        run_id = f"materialization-{self.fixture_number}"
        root = self.attempt_root(run_id)
        context = support.valid_context(
            runId=run_id,
            executionId=f"{run_id}-execution",
        )
        support.run_evidence._initialize_attempt(self.index_path, root, context)
        command_state.initialize_control_layout(
            root,
            state_cases.valid_session(
                runId=run_id,
                ownerPid=os.getpid(),
                ownerBirthIdentity="test:current-process",
            ),
        )
        lease = command_state.reserve_command_layout(
            root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
        )
        self.leases.append(lease)
        launch = state_cases.valid_supervisor(
            pid=os.getpid(),
            birthIdentity="test:current-process",
            leaseIdentity=lease.identity,
        )
        prepared = state_cases.valid_command_state(
            "prepared",
            supervisor=launch,
            anchorReservation=lease.anchor_reservation,
        )
        if failure_code is not None:
            prepared["request"]["failureCode"] = failure_code
            prepared["requestFingerprint"] = command_state.request_fingerprint(
                state_cases.SESSION_ID,
                1,
                prepared["request"],
                prepared["paths"],
            )
        prepared["startedEvent"]["seq"] = started_seq
        command_state.create_command_state(
            root,
            prepared,
            supervisor_lease=lease,
        )
        if append_started:
            self.append_raw(root, canonical_line(prepared["startedEvent"]))

        command_root = (
            root
            / ".evidence-control"
            / "commands"
            / state_cases.COMMAND_ID
        )
        if durable_stage == "prepared":
            return SimpleNamespace(
                root=root,
                lease=lease,
                prepared=prepared,
                exited=prepared,
                command_root=command_root,
            )
        if durable_stage != "exited":
            raise AssertionError(f"unknown fixture durable stage: {durable_stage}")

        stream = lambda content, truncated=False: state_cases.valid_stream(
            originalBytes=len(content),
            sanitizedBytes=len(content),
            storedBytes=len(content),
            truncated=truncated,
        )
        if kind == "success":
            exited = copy.deepcopy(prepared)
            anchor_pid = os.getpid() + 10000 + self.fixture_number * 10
            exited.update(
                stage="exited",
                anchor=state_cases.valid_anchor(
                    pid=anchor_pid,
                    sid=anchor_pid,
                    pgid=anchor_pid,
                    groupLeaseIdentity=lease.anchor_reservation[
                        "groupLeaseIdentity"
                    ],
                ),
                child=state_cases.valid_child(pid=anchor_pid + 1),
                outcome=state_cases.valid_outcome(),
                capture=state_cases.valid_capture(
                    stdout=stream(STDOUT),
                    stderr=stream(STDERR),
                ),
            )
        elif kind == "recovery_loss":
            lease.close()
            claim = command_state.claim_command_recovery(
                root,
                state_cases.SESSION_ID,
                1,
                state_cases.COMMAND_ID,
                process_backend=self.recovery_backend(
                    "test:recovery-process"
                ),
            )
            self.leases.append(claim)
            lease = claim
            exited = claim.state
            exited.update(
                stage="exited",
                outcome={
                    "kind": "supervisor_failure",
                    "errorCode": "runner.command_supervisor_lost",
                    "exitStatus": None,
                    "signal": None,
                    "shellVisibleStatus": 125,
                    "failedAt": "2026-07-11T00:00:03Z",
                },
                capture=state_cases.valid_capture(
                    captureComplete=False,
                    stdout=stream(STDOUT, truncated=True),
                    stderr=stream(STDERR, truncated=True),
                ),
            )
        else:
            raise AssertionError(f"unknown fixture kind: {kind}")

        (command_root / "stdout.recovery").write_bytes(STDOUT)
        (command_root / "stderr.recovery").write_bytes(STDERR)
        if kind == "recovery_loss":
            exited = lease.transition(exited)
        else:
            (command_root / "state.json").write_bytes(
                command_state.encode_command_state(exited)
            )
        return SimpleNamespace(
            root=root,
            lease=lease,
            prepared=prepared,
            exited=exited,
            command_root=command_root,
        )

    @staticmethod
    def append_raw(root, content):
        with (root / "bootstrap-events.jsonl").open("ab") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())

    @staticmethod
    def invoke(api, fixture, *, lease=None):
        return api(
            fixture.root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
            supervisor_lease=fixture.lease if lease is None else lease,
        )

    @staticmethod
    def recovery_backend(identity):
        class Backend:
            def current_identity(self, pid):
                if pid != os.getpid():
                    raise AssertionError("recovery queried a foreign current PID")
                return identity

            def predecessor_absent(self, pid, birth_identity):
                if not isinstance(pid, int) or pid < 1:
                    raise AssertionError("recovery queried an invalid predecessor PID")
                if not isinstance(birth_identity, str) or not birth_identity:
                    raise AssertionError(
                        "recovery queried an invalid predecessor identity"
                    )
                return True

        return Backend()

    def claim_recovery(self, fixture, *, identity, predecessor_lease=None):
        claim_api = getattr(command_state, "claim_command_recovery", None)
        self.assertTrue(
            callable(claim_api),
            "missing crash-recovery API: claim_command_recovery",
        )
        authority = fixture.lease if predecessor_lease is None else predecessor_lease
        authority.close()
        claim = claim_api(
            fixture.root,
            state_cases.SESSION_ID,
            1,
            state_cases.COMMAND_ID,
            process_backend=self.recovery_backend(identity),
        )
        self.leases.append(claim)
        return claim

    @staticmethod
    def event_bytes(root):
        return (root / "bootstrap-events.jsonl").read_bytes()

    @staticmethod
    def state_path(fixture):
        return fixture.command_root / "state.json"

    def durable_state(self, fixture):
        return command_state.read_command_state(
            fixture.root,
            state_cases.COMMAND_ID,
            state_cases.SESSION_ID,
        )

    def assert_exactly_one_terminal_reference(self, fixture, state):
        binding = state["materialized"]["terminalEvent"]
        encoded = canonical_line(binding["event"])
        raw_lines = self.event_bytes(fixture.root).splitlines(keepends=True)
        self.assertEqual(raw_lines.count(encoded), 1)
        events = [json.loads(line) for line in raw_lines]
        terminal_references = [
            event
            for event in events
            if event.get("command") == fixture.exited["paths"]["metadata"]
            and event.get("status") in ("passed", "failed", "cancelled")
        ]
        self.assertEqual(terminal_references, [binding["event"]])

    @staticmethod
    def projection_snapshot(fixture):
        paths = [
            fixture.root / "bootstrap-events.jsonl",
            *(fixture.root / value for value in fixture.exited["paths"].values()),
        ]
        snapshot = {}
        for path in paths:
            relative = path.relative_to(fixture.root).as_posix()
            try:
                metadata = path.lstat()
            except FileNotFoundError:
                snapshot[relative] = ("missing",)
            else:
                if path.is_symlink():
                    snapshot[relative] = ("symlink", os.readlink(path))
                elif stat.S_ISREG(metadata.st_mode):
                    snapshot[relative] = (
                        "file",
                        stat.S_IMODE(metadata.st_mode),
                        metadata.st_ino,
                        metadata.st_mtime_ns,
                        path.read_bytes(),
                    )
                else:
                    snapshot[relative] = (
                        "special",
                        stat.S_IFMT(metadata.st_mode),
                        stat.S_IMODE(metadata.st_mode),
                        metadata.st_ino,
                    )
        return snapshot

    @staticmethod
    def assert_binding(test, binding, content):
        test.assertEqual(binding["bytes"], len(content))
        test.assertEqual(
            binding["sha256"],
            "sha256:" + hashlib.sha256(content).hexdigest(),
        )

    def test_materialization_apis_accept_only_identity_and_live_authority(self):
        expected = [
            "root",
            "session_id",
            "generation",
            "command_id",
            "supervisor_lease",
        ]
        for name in ("repair_command_started_event", "materialize_command"):
            with self.subTest(api=name):
                signature = inspect.signature(self.require_api(name))
                parameters = list(signature.parameters.values())
                self.assertEqual([item.name for item in parameters], expected)
                self.assertTrue(
                    all(
                        item.kind is inspect.Parameter.POSITIONAL_OR_KEYWORD
                        for item in parameters[:4]
                    )
                )
                self.assertIs(
                    parameters[4].kind,
                    inspect.Parameter.KEYWORD_ONLY,
                )
                self.assertIs(parameters[4].default, inspect.Parameter.empty)

    def test_missing_started_event_is_exactly_appended_and_identical_is_noop(self):
        repair = self.require_api("repair_command_started_event")
        fixture = self.fixture(
            append_started=False,
            durable_stage="prepared",
        )
        path = fixture.root / "bootstrap-events.jsonl"
        before = path.read_bytes()
        state_before = self.state_path(fixture).read_bytes()
        expected = canonical_line(fixture.prepared["startedEvent"])

        self.invoke(repair, fixture)

        self.assertEqual(path.read_bytes(), before + expected)
        self.assertEqual(self.state_path(fixture).read_bytes(), state_before)
        self.assertEqual(self.durable_state(fixture)["stage"], "prepared")
        self.assertTrue(path.read_bytes().endswith(b"\n"))
        unchanged = path.stat()
        self.invoke(repair, fixture)
        self.assertEqual(path.read_bytes(), before + expected)
        self.assertEqual(path.stat().st_ino, unchanged.st_ino)
        self.assertEqual(path.stat().st_mtime_ns, unchanged.st_mtime_ns)

    def test_started_event_crash_after_append_retries_without_duplication(self):
        repair = self.require_api("repair_command_started_event")
        for supervisor_role in ("launch", "recovery"):
            with self.subTest(supervisor=supervisor_role):
                fixture = self.fixture(
                    append_started=False,
                    durable_stage="prepared",
                )
                authority = fixture.lease
                if supervisor_role == "recovery":
                    authority = self.claim_recovery(
                        fixture,
                        identity="linux:test:prepared-repair-recovery",
                    )
                path = fixture.root / "bootstrap-events.jsonl"
                before = path.read_bytes()
                state_before = self.state_path(fixture).read_bytes()
                expected = canonical_line(fixture.prepared["startedEvent"])
                hits = []

                def crash_after_append(stage, path=None):
                    if stage == "after_started_event":
                        hits.append((stage, path))
                        raise InjectedCrash(stage)

                with mock.patch.object(
                    commands,
                    "_command_materialization_checkpoint",
                    side_effect=crash_after_append,
                    create=True,
                ), self.assertRaises(InjectedCrash):
                    self.invoke(repair, fixture, lease=authority)

                self.assertEqual(len(hits), 1)
                self.assertEqual(path.read_bytes(), before + expected)
                self.assertEqual(self.state_path(fixture).read_bytes(), state_before)
                self.assertEqual(self.durable_state(fixture)["stage"], "prepared")
                appended = path.stat()
                self.invoke(repair, fixture, lease=authority)
                self.assertEqual(path.read_bytes(), before + expected)
                self.assertEqual(
                    path.read_bytes().splitlines(keepends=True).count(expected),
                    1,
                )
                self.assertEqual(path.stat().st_ino, appended.st_ino)
                self.assertEqual(path.stat().st_mtime_ns, appended.st_mtime_ns)

    def test_started_event_noncanonical_occupied_and_gap_are_rejected_untouched(self):
        repair = self.require_api("repair_command_started_event")

        noncanonical = self.fixture(
            append_started=False,
            durable_stage="prepared",
        )
        self.append_raw(
            noncanonical.root,
            noncanonical_line(noncanonical.prepared["startedEvent"]),
        )

        occupied = self.fixture(
            append_started=False,
            durable_stage="prepared",
        )
        different = copy.deepcopy(occupied.prepared["startedEvent"])
        different["timestamp"] = "2026-07-11T00:00:01.500Z"
        self.append_raw(occupied.root, canonical_line(different))

        gap = self.fixture(
            append_started=False,
            started_seq=4,
            durable_stage="prepared",
        )
        for label, fixture in (
            ("decoded-equal noncanonical", noncanonical),
            ("different occupied sequence", occupied),
            ("sequence gap", gap),
        ):
            with self.subTest(case=label):
                before = self.projection_snapshot(fixture)
                with self.assertRaises((ValueError, OSError)):
                    self.invoke(repair, fixture)
                self.assertEqual(self.projection_snapshot(fixture), before)

    def test_materialization_apis_reject_unbound_closed_and_foreign_authority(self):
        for api_name in ("repair_command_started_event", "materialize_command"):
            api = self.require_api(api_name)
            for authority_kind in ("unbound", "closed", "foreign"):
                with self.subTest(api=api_name, authority=authority_kind):
                    target = self.fixture(
                        append_started=api_name != "repair_command_started_event",
                        durable_stage=(
                            "prepared"
                            if api_name == "repair_command_started_event"
                            else "exited"
                        ),
                    )
                    if authority_kind == "unbound":
                        authority = object()
                    elif authority_kind == "closed":
                        target.lease.close()
                        authority = target.lease
                    else:
                        foreign = self.fixture()
                        authority = foreign.lease
                    before_public = self.projection_snapshot(target)
                    before_state = self.state_path(target).read_bytes()
                    with self.assertRaises((ValueError, OSError, RuntimeError)):
                        self.invoke(api, target, lease=authority)
                    self.assertEqual(
                        self.projection_snapshot(target),
                        before_public,
                    )
                    self.assertEqual(
                        self.state_path(target).read_bytes(),
                        before_state,
                    )

    def test_terminal_binding_embeds_exact_event_and_hashes_canonical_jsonl_line(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()

        committed = self.invoke(materialize, fixture)

        self.assertEqual(committed["stage"], "committed")
        binding = committed["materialized"]["terminalEvent"]
        self.assertEqual(set(binding), {"seq", "bytes", "sha256", "event"})
        self.assertEqual(binding["seq"], binding["event"]["seq"])
        encoded = canonical_line(binding["event"])
        self.assertTrue(encoded.endswith(b"\n"))
        self.assert_binding(self, binding, encoded)
        raw_lines = self.event_bytes(fixture.root).splitlines(keepends=True)
        self.assertEqual(raw_lines[binding["seq"] - 1], encoded)

        before = self.projection_snapshot(fixture)
        repeated = self.invoke(materialize, fixture)
        self.assertEqual(repeated, committed)
        self.assertEqual(self.projection_snapshot(fixture), before)

    def test_materialized_intent_is_durable_before_any_public_projection(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()
        before = self.projection_snapshot(fixture)
        event_before = self.event_bytes(fixture.root)
        hits = []

        def crash_after_intent(stage, path=None):
            if stage == "after_materialized_intent":
                hits.append((stage, path))
                raise InjectedCrash(stage)

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=crash_after_intent,
            create=True,
        ), self.assertRaises(InjectedCrash):
            self.invoke(materialize, fixture)

        self.assertEqual(len(hits), 1)
        intent = self.durable_state(fixture)
        self.assertEqual(intent["stage"], "materialized")
        self.assertIsNotNone(intent["materialized"])
        self.assertEqual(self.event_bytes(fixture.root), event_before)
        for relative in fixture.exited["paths"].values():
            self.assertFalse((fixture.root / relative).exists())
        self.assertEqual(self.projection_snapshot(fixture), before)

    def test_frozen_terminal_sequence_collision_rejects_without_reallocation(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()

        def crash_after_intent(stage, path=None):
            if stage == "after_materialized_intent":
                raise InjectedCrash(stage)

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=crash_after_intent,
            create=True,
        ), self.assertRaises(InjectedCrash):
            self.invoke(materialize, fixture)
        intent = self.durable_state(fixture)
        frozen = copy.deepcopy(intent["materialized"]["terminalEvent"])
        occupied = {
            "schemaVersion": 1,
            "seq": frozen["seq"],
            "timestamp": "2026-07-11T00:00:03.075Z",
            "phase": "scenario.execute",
            "status": "skipped",
        }
        self.assertNotEqual(canonical_line(occupied), canonical_line(frozen["event"]))
        self.append_raw(fixture.root, canonical_line(occupied))
        before_public = self.projection_snapshot(fixture)
        before_state = self.state_path(fixture).read_bytes()

        with self.assertRaises((ValueError, OSError)):
            self.invoke(materialize, fixture)

        self.assertEqual(self.projection_snapshot(fixture), before_public)
        self.assertEqual(self.state_path(fixture).read_bytes(), before_state)
        retained = self.durable_state(fixture)
        self.assertEqual(retained["materialized"]["terminalEvent"], frozen)
        lines = self.event_bytes(fixture.root).splitlines(keepends=True)
        self.assertEqual(lines[frozen["seq"] - 1], canonical_line(occupied))
        self.assertNotIn(canonical_line(frozen["event"]), lines)

    def test_terminal_uses_exact_next_sequence_after_an_intervening_event(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()
        intervening = {
            "schemaVersion": 1,
            "seq": fixture.prepared["startedEvent"]["seq"] + 1,
            "timestamp": "2026-07-11T00:00:03.050Z",
            "phase": "scenario.execute",
            "status": "passed",
        }
        self.append_raw(fixture.root, canonical_line(intervening))

        committed = self.invoke(materialize, fixture)

        binding = committed["materialized"]["terminalEvent"]
        self.assertEqual(binding["seq"], intervening["seq"] + 1)
        raw_lines = self.event_bytes(fixture.root).splitlines(keepends=True)
        self.assertEqual(raw_lines[intervening["seq"] - 1], canonical_line(intervening))
        self.assertEqual(
            raw_lines[binding["seq"] - 1],
            canonical_line(binding["event"]),
        )
        self.assert_exactly_one_terminal_reference(fixture, committed)

    def test_terminal_decoded_equal_noncanonical_and_duplicate_reference_reject(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()

        def crash_after_intent(stage, path=None):
            if stage == "after_materialized_intent":
                raise InjectedCrash("after materialized intent")

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=crash_after_intent,
            create=True,
        ), self.assertRaises(InjectedCrash):
            self.invoke(materialize, fixture)
        intent = command_state.read_command_state(
            fixture.root,
            state_cases.COMMAND_ID,
            state_cases.SESSION_ID,
        )
        event = intent["materialized"]["terminalEvent"]["event"]
        self.append_raw(fixture.root, noncanonical_line(event))
        before = self.projection_snapshot(fixture)
        with self.assertRaises((ValueError, OSError)):
            self.invoke(materialize, fixture)
        self.assertEqual(self.projection_snapshot(fixture), before)

        duplicate = self.fixture()
        duplicate_event = {
            "schemaVersion": 1,
            "seq": 4,
            "timestamp": "2026-07-11T00:00:03Z",
            "phase": duplicate.exited["request"]["phase"],
            "status": "passed",
            "command": duplicate.exited["paths"]["metadata"],
            "commandStatus": 0,
            "artifact": duplicate.exited["paths"]["metadata"],
        }
        self.append_raw(duplicate.root, canonical_line(duplicate_event))
        before = self.projection_snapshot(duplicate)
        with self.assertRaises((ValueError, OSError)):
            self.invoke(materialize, duplicate)
        self.assertEqual(self.projection_snapshot(duplicate), before)

    def test_terminal_event_crash_retry_preserves_event_inode_mtime_and_line(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()
        hits = []

        def crash_after_terminal(stage, path=None):
            if stage == "after_terminal_event":
                hits.append((stage, path))
                raise InjectedCrash(stage)

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=crash_after_terminal,
            create=True,
        ), self.assertRaises(InjectedCrash):
            self.invoke(materialize, fixture)

        self.assertEqual(len(hits), 1)
        intent = self.durable_state(fixture)
        self.assertEqual(intent["stage"], "materialized")
        self.assert_exactly_one_terminal_reference(fixture, intent)
        path = fixture.root / "bootstrap-events.jsonl"
        before = path.read_bytes()
        appended = (path.stat().st_ino, path.stat().st_mtime_ns)

        committed = self.invoke(materialize, fixture)

        self.assertEqual(committed["stage"], "committed")
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual((path.stat().st_ino, path.stat().st_mtime_ns), appended)
        self.assert_exactly_one_terminal_reference(fixture, committed)

    def test_launch_and_recovery_loss_survive_two_crashes_and_exact_replay(self):
        materialize = self.require_api("materialize_command")
        for kind, terminal_status in (
            ("success", "passed"),
            ("recovery_loss", "failed"),
        ):
            with self.subTest(kind=kind):
                fixture = self.fixture(kind=kind)
                for checkpoint in (
                    "after_materialized_intent",
                    "after_terminal_event",
                ):
                    hits = []

                    def crash(stage, path=None, expected=checkpoint):
                        if stage == expected:
                            hits.append(stage)
                            raise InjectedCrash(stage)

                    with mock.patch.object(
                        commands,
                        "_command_materialization_checkpoint",
                        side_effect=crash,
                        create=True,
                    ), self.assertRaises(InjectedCrash):
                        self.invoke(materialize, fixture)
                    self.assertEqual(hits, [checkpoint])

                committed = self.invoke(materialize, fixture)
                self.assertEqual(committed["stage"], "committed")
                event = committed["materialized"]["terminalEvent"]["event"]
                self.assertEqual(event["status"], terminal_status)
                if kind == "recovery_loss":
                    self.assertEqual(
                        event["errorCode"],
                        "runner.command_supervisor_lost",
                    )
                self.assert_exactly_one_terminal_reference(fixture, committed)

    def test_each_public_install_and_commit_boundary_replays_exactly_once(self):
        materialize = self.require_api("materialize_command")
        for binding_name in ("stdout", "stderr", "metadata"):
            with self.subTest(boundary="after_file_install", binding=binding_name):
                fixture = self.fixture()
                target = fixture.root / fixture.exited["paths"][binding_name]
                hits = []

                def crash_after_install(stage, path=None):
                    if stage == "after_file_install" and Path(path) == target:
                        hits.append((stage, path))
                        raise InjectedCrash(f"{stage}:{binding_name}")

                with mock.patch.object(
                    commands,
                    "_command_materialization_checkpoint",
                    side_effect=crash_after_install,
                    create=True,
                ), self.assertRaises(InjectedCrash):
                    self.invoke(materialize, fixture)
                self.assertEqual(len(hits), 1)
                self.assertEqual(hits[0][0], "after_file_install")
                self.assertEqual(Path(hits[0][1]), target)
                durable = self.durable_state(fixture)
                self.assertEqual(durable["stage"], "materialized")
                self.assertTrue(target.is_file())
                self.assert_binding(
                    self,
                    durable["materialized"][binding_name],
                    target.read_bytes(),
                )
                installed = (target.stat().st_ino, target.stat().st_mtime_ns)

                committed = self.invoke(materialize, fixture)
                self.assertEqual(committed["stage"], "committed")
                self.assertEqual(
                    (target.stat().st_ino, target.stat().st_mtime_ns),
                    installed,
                )
                self.assert_exactly_one_terminal_reference(fixture, committed)
                before_repeat = self.projection_snapshot(fixture)
                self.assertEqual(self.invoke(materialize, fixture), committed)
                self.assertEqual(self.projection_snapshot(fixture), before_repeat)

        for checkpoint, durable_stage in (
            ("before_committed_state", "materialized"),
            ("after_committed_state", "committed"),
        ):
            with self.subTest(boundary=checkpoint):
                fixture = self.fixture()
                hits = []

                def crash_at_commit(stage, path=None, expected=checkpoint):
                    if stage == expected:
                        hits.append((stage, path))
                        raise InjectedCrash(stage)

                with mock.patch.object(
                    commands,
                    "_command_materialization_checkpoint",
                    side_effect=crash_at_commit,
                    create=True,
                ), self.assertRaises(InjectedCrash):
                    self.invoke(materialize, fixture)
                self.assertEqual(len(hits), 1)
                durable = self.durable_state(fixture)
                self.assertEqual(durable["stage"], durable_stage)
                for relative in fixture.exited["paths"].values():
                    self.assertTrue((fixture.root / relative).is_file())
                self.assert_exactly_one_terminal_reference(fixture, durable)
                projected = self.projection_snapshot(fixture)

                committed = self.invoke(materialize, fixture)
                self.assertEqual(committed["stage"], "committed")
                self.assert_exactly_one_terminal_reference(fixture, committed)
                self.assertEqual(self.projection_snapshot(fixture), projected)

    def test_partial_hard_crash_staging_is_safely_recreated(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()

        def crash_after_terminal(stage, path=None):
            if stage == "after_terminal_event":
                raise InjectedCrash(stage)

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=crash_after_terminal,
            create=True,
        ), self.assertRaises(InjectedCrash):
            self.invoke(materialize, fixture)

        target = fixture.root / fixture.exited["paths"]["stdout"]
        temporary = commands._materialization_temporary_path(target, STDOUT)
        temporary.write_bytes(STDOUT[:3])
        temporary.chmod(0o600)
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())

        committed = self.invoke(materialize, fixture)

        self.assertEqual(committed["stage"], "committed")
        self.assertFalse(temporary.exists())
        self.assertEqual(target.read_bytes(), STDOUT)
        self.assert_exactly_one_terminal_reference(fixture, committed)

    def test_unsafe_staging_occupants_are_rejected_untouched(self):
        materialize = self.require_api("materialize_command")
        for occupant in ("symlink", "hardlink"):
            with self.subTest(occupant=occupant):
                fixture = self.fixture()

                def crash_after_terminal(stage, path=None):
                    if stage == "after_terminal_event":
                        raise InjectedCrash(stage)

                with mock.patch.object(
                    commands,
                    "_command_materialization_checkpoint",
                    side_effect=crash_after_terminal,
                    create=True,
                ), self.assertRaises(InjectedCrash):
                    self.invoke(materialize, fixture)

                target = fixture.root / fixture.exited["paths"]["stdout"]
                temporary = commands._materialization_temporary_path(
                    target, STDOUT
                )
                outside = fixture.root / f"outside-{occupant}"
                outside.write_bytes(b"do not delete")
                outside.chmod(0o600)
                if occupant == "symlink":
                    temporary.symlink_to(outside)
                else:
                    os.link(outside, temporary)
                before = temporary.lstat()

                with self.assertRaises((ValueError, OSError)):
                    self.invoke(materialize, fixture)

                after = temporary.lstat()
                self.assertEqual(
                    (after.st_dev, after.st_ino, after.st_mode, after.st_nlink),
                    (before.st_dev, before.st_ino, before.st_mode, before.st_nlink),
                )
                self.assertEqual(outside.read_bytes(), b"do not delete")
                self.assertFalse(target.exists())
                self.assertEqual(self.durable_state(fixture)["stage"], "materialized")

    def test_tampered_or_truncated_spool_after_intent_rejects_without_publication(self):
        materialize = self.require_api("materialize_command")
        for stream_name, mutation in (
            ("stdout", "tamper"),
            ("stderr", "truncate"),
        ):
            with self.subTest(stream=stream_name, mutation=mutation):
                fixture = self.fixture()

                def crash_after_intent(stage, path=None):
                    if stage == "after_materialized_intent":
                        raise InjectedCrash(stage)

                with mock.patch.object(
                    commands,
                    "_command_materialization_checkpoint",
                    side_effect=crash_after_intent,
                    create=True,
                ), self.assertRaises(InjectedCrash):
                    self.invoke(materialize, fixture)

                intent = self.durable_state(fixture)
                spool = fixture.command_root / f"{stream_name}.recovery"
                original = spool.read_bytes()
                self.assert_binding(
                    self,
                    intent["materialized"][stream_name],
                    original,
                )
                if mutation == "tamper":
                    changed = bytes([original[0] ^ 1]) + original[1:]
                else:
                    changed = original[:-1]
                spool.write_bytes(changed)
                before_public = self.projection_snapshot(fixture)
                before_state = self.state_path(fixture).read_bytes()

                with self.assertRaises((ValueError, OSError)):
                    self.invoke(materialize, fixture)

                self.assertEqual(self.projection_snapshot(fixture), before_public)
                self.assertEqual(self.state_path(fixture).read_bytes(), before_state)
                self.assertEqual(spool.read_bytes(), changed)

    def test_committed_is_verify_only_for_missing_or_mismatched_projection(self):
        materialize = self.require_api("materialize_command")
        cases = [
            (f"{name}-{mutation}", name, mutation)
            for name in ("stdout", "stderr", "metadata")
            for mutation in ("missing", "mismatch")
        ]
        cases.extend(
            (
                ("terminal-event-missing", "terminalEvent", "missing"),
                ("terminal-event-mismatch", "terminalEvent", "mismatch"),
            )
        )

        for label, binding_name, mutation in cases:
            with self.subTest(case=label):
                fixture = self.fixture()
                committed = self.invoke(materialize, fixture)
                self.assertEqual(committed["stage"], "committed")
                if binding_name == "terminalEvent":
                    target = fixture.root / "bootstrap-events.jsonl"
                    lines = target.read_bytes().splitlines(keepends=True)
                    if mutation == "missing":
                        target.write_bytes(b"".join(lines[:-1]))
                    else:
                        replacement = copy.deepcopy(
                            committed["materialized"]["terminalEvent"]["event"]
                        )
                        replacement["timestamp"] = "2099-01-01T00:00:00Z"
                        target.write_bytes(
                            b"".join(lines[:-1]) + canonical_line(replacement)
                        )
                else:
                    target = fixture.root / fixture.exited["paths"][binding_name]
                    if mutation == "missing":
                        target.unlink()
                    else:
                        target.write_bytes(b"hostile occupant")
                        target.chmod(0o600)

                before_public = self.projection_snapshot(fixture)
                before_state = self.state_path(fixture).read_bytes()
                with self.assertRaises((ValueError, OSError, FileExistsError)):
                    self.invoke(materialize, fixture)
                self.assertEqual(self.projection_snapshot(fixture), before_public)
                self.assertEqual(self.state_path(fixture).read_bytes(), before_state)
                self.assertEqual(self.durable_state(fixture)["stage"], "committed")

    def test_committed_session_rejects_writes_but_allows_exact_verification(self):
        repair = self.require_api("repair_command_started_event")
        materialize = self.require_api("materialize_command")

        prepared = self.fixture(
            append_started=False,
            durable_stage="prepared",
        )
        command_state.transition_session_state(
            prepared.root, state_cases.SESSION_ID, 1, "finalizing"
        )
        command_state.transition_session_state(
            prepared.root, state_cases.SESSION_ID, 1, "committed"
        )
        prepared_before = self.projection_snapshot(prepared)
        prepared_state = self.state_path(prepared).read_bytes()
        with self.assertRaisesRegex(ValueError, "committed session"):
            self.invoke(repair, prepared)
        self.assertEqual(self.projection_snapshot(prepared), prepared_before)
        self.assertEqual(self.state_path(prepared).read_bytes(), prepared_state)

        exited = self.fixture()
        exited_before = self.projection_snapshot(exited)
        exited_state = self.state_path(exited).read_bytes()
        command_state.transition_session_state(
            exited.root, state_cases.SESSION_ID, 1, "finalizing"
        )
        command_state.transition_session_state(
            exited.root, state_cases.SESSION_ID, 1, "committed"
        )
        with self.assertRaisesRegex(ValueError, "committed session"):
            self.invoke(materialize, exited)
        self.assertEqual(self.projection_snapshot(exited), exited_before)
        self.assertEqual(self.state_path(exited).read_bytes(), exited_state)

        committed_fixture = self.fixture()
        committed = self.invoke(materialize, committed_fixture)
        command_state.transition_session_state(
            committed_fixture.root,
            state_cases.SESSION_ID,
            1,
            "finalizing",
        )
        command_state.transition_session_state(
            committed_fixture.root,
            state_cases.SESSION_ID,
            1,
            "committed",
        )
        projection = self.projection_snapshot(committed_fixture)
        self.assertEqual(self.invoke(materialize, committed_fixture), committed)
        self.assertEqual(
            self.projection_snapshot(committed_fixture), projection
        )

    def test_stale_generation_fails_before_transaction_recovery(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()
        before = self.projection_snapshot(fixture)
        state_before = self.state_path(fixture).read_bytes()

        with mock.patch.object(
            commands,
            "_recover_pending_transactions_unlocked",
            side_effect=AssertionError(
                "stale generation reached transaction recovery"
            ),
        ) as recover, self.assertRaisesRegex(ValueError, "generation"):
            materialize(
                fixture.root,
                state_cases.SESSION_ID,
                2,
                state_cases.COMMAND_ID,
                supervisor_lease=fixture.lease,
            )

        recover.assert_not_called()
        self.assertEqual(self.projection_snapshot(fixture), before)
        self.assertEqual(self.state_path(fixture).read_bytes(), state_before)

    def test_configured_cleanup_failure_does_not_imply_supervisor_failure(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture(failure_code="runner.cleanup_failed")

        committed = self.invoke(materialize, fixture)
        metadata_path = fixture.root / committed["materialized"]["metadata"][
            "path"
        ]
        metadata = json.loads(metadata_path.read_bytes())

        self.assertEqual(
            metadata["configuredFailureCode"], "runner.cleanup_failed"
        )
        self.assertEqual(metadata["failureCode"], "runner.cleanup_failed")
        self.assertIs(metadata["supervisorFailure"], False)
        self.assertEqual(metadata["commandId"], state_cases.COMMAND_ID)
        self.assertEqual(
            metadata["termination"],
            {
                "kind": "exit",
                "code": 0,
                "signal": None,
                "stopRequested": False,
                "requestKind": None,
                "graceExpired": False,
                "escalated": False,
                "shellVisibleStatus": 0,
            },
        )

    def test_post_exit_recovery_loss_is_primary_without_erasing_child_truth(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()
        historical_outcome = copy.deepcopy(fixture.exited["outcome"])
        historical_capture = copy.deepcopy(fixture.exited["capture"])
        claim = self.claim_recovery(
            fixture,
            identity="linux:test:materialization-recovery-one",
        )
        self.assertEqual(claim.state["supervisor"]["role"], "recovery")
        self.assertEqual(claim.state["outcome"], historical_outcome)
        self.assertEqual(claim.state["capture"], historical_capture)

        committed = self.invoke(materialize, fixture, lease=claim)

        event = committed["materialized"]["terminalEvent"]["event"]
        self.assertEqual(event["status"], "failed")
        self.assertEqual(event["errorCode"], "runner.command_supervisor_lost")
        self.assertNotIn("commandStatus", event)
        self.assertEqual(committed["outcome"], historical_outcome)
        self.assertEqual(committed["capture"], historical_capture)
        metadata_path = fixture.root / committed["materialized"]["metadata"]["path"]
        metadata = json.loads(metadata_path.read_bytes())
        self.assertEqual(metadata["failureCode"], "runner.command_supervisor_lost")
        self.assertEqual(
            metadata["configuredFailureCode"],
            fixture.exited["request"]["failureCode"],
        )
        self.assertIs(metadata["supervisorFailure"], True)
        self.assertIs(metadata["captureComplete"], True)
        self.assertEqual(metadata["exitStatus"], historical_outcome["exitStatus"])
        self.assertEqual(metadata["signal"], historical_outcome["signal"])
        self.assertEqual(metadata["commandId"], state_cases.COMMAND_ID)
        self.assertEqual(
            metadata["termination"],
            {
                "kind": "exit",
                "code": historical_outcome["exitStatus"],
                "signal": None,
                "stopRequested": False,
                "requestKind": None,
                "graceExpired": False,
                "escalated": False,
                "shellVisibleStatus": historical_outcome[
                    "shellVisibleStatus"
                ],
            },
        )
        for stream_name, expected_content in (
            ("stdout", STDOUT),
            ("stderr", STDERR),
        ):
            with self.subTest(stream=stream_name):
                self.assertEqual(
                    fixture.root.joinpath(
                        committed["materialized"][stream_name]["path"]
                    ).read_bytes(),
                    expected_content,
                )
                for field in (
                    "originalBytes",
                    "sanitizedBytes",
                    "storedBytes",
                    "truncated",
                ):
                    self.assertEqual(
                        metadata[stream_name][field],
                        historical_capture[stream_name][field],
                    )
        self.assert_exactly_one_terminal_reference(fixture, committed)

    def test_materialized_launch_success_is_frozen_across_a_recovery_claim(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()

        def crash_after_intent(stage, path=None):
            if stage == "after_materialized_intent":
                raise InjectedCrash(stage)

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=crash_after_intent,
            create=True,
        ), self.assertRaises(InjectedCrash):
            self.invoke(materialize, fixture)
        intent = self.durable_state(fixture)
        frozen = copy.deepcopy(intent["materialized"])
        self.assertEqual(frozen["terminalEvent"]["event"]["status"], "passed")

        claim = self.claim_recovery(
            fixture,
            identity="linux:test:materialized-success-recovery",
        )
        self.assertEqual(claim.state["materialized"], frozen)
        committed = self.invoke(materialize, fixture, lease=claim)

        self.assertEqual(committed["materialized"], frozen)
        self.assertEqual(
            committed["materialized"]["terminalEvent"]["event"]["status"],
            "passed",
        )
        self.assertNotIn(
            "errorCode",
            committed["materialized"]["terminalEvent"]["event"],
        )
        self.assert_exactly_one_terminal_reference(fixture, committed)

    def test_frozen_recovery_loss_is_exact_across_a_second_recovery_claim(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()
        first = self.claim_recovery(
            fixture,
            identity="linux:test:recovery-loss-one",
        )

        def crash_after_intent(stage, path=None):
            if stage == "after_materialized_intent":
                raise InjectedCrash(stage)

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=crash_after_intent,
            create=True,
        ), self.assertRaises(InjectedCrash):
            self.invoke(materialize, fixture, lease=first)
        intent = self.durable_state(fixture)
        frozen = copy.deepcopy(intent["materialized"])
        frozen_event = frozen["terminalEvent"]["event"]
        self.assertEqual(frozen_event["status"], "failed")
        self.assertEqual(
            frozen_event["errorCode"],
            "runner.command_supervisor_lost",
        )
        self.assertNotIn("commandStatus", frozen_event)

        second = self.claim_recovery(
            fixture,
            identity="linux:test:recovery-loss-two",
            predecessor_lease=first,
        )
        self.assertEqual(second.state["materialized"], frozen)
        committed = self.invoke(materialize, fixture, lease=second)

        self.assertEqual(committed["materialized"], frozen)
        self.assertEqual(
            committed["materialized"]["terminalEvent"]["event"],
            frozen_event,
        )
        self.assert_exactly_one_terminal_reference(fixture, committed)

    def test_recovery_state_rejects_wrong_closed_and_foreign_claim_authority(self):
        for api_name in ("repair_command_started_event", "materialize_command"):
            api = self.require_api(api_name)
            for authority_kind in (
                "wrong-predecessor",
                "closed-claim",
                "foreign-claim",
            ):
                with self.subTest(api=api_name, authority=authority_kind):
                    durable_stage = (
                        "prepared"
                        if api_name == "repair_command_started_event"
                        else "exited"
                    )
                    fixture = self.fixture(
                        append_started=api_name != "repair_command_started_event",
                        durable_stage=durable_stage,
                    )
                    claim = self.claim_recovery(
                        fixture,
                        identity=f"linux:test:target-{api_name}-{authority_kind}",
                    )
                    if authority_kind == "wrong-predecessor":
                        mismatched = copy.deepcopy(claim.state)
                        wrong_predecessor = "sha256:" + "f" * 64
                        if (
                            mismatched["supervisor"]["predecessor"]
                            == wrong_predecessor
                        ):
                            wrong_predecessor = "sha256:" + "e" * 64
                        mismatched["supervisor"][
                            "predecessor"
                        ] = wrong_predecessor
                        self.state_path(fixture).write_bytes(
                            command_state.encode_command_state(mismatched)
                        )
                        authority = claim
                    elif authority_kind == "closed-claim":
                        claim.close()
                        authority = claim
                    else:
                        foreign = self.fixture(durable_stage=durable_stage)
                        authority = self.claim_recovery(
                            foreign,
                            identity=f"linux:test:foreign-claim-{api_name}",
                        )
                    before_public = self.projection_snapshot(fixture)
                    before_state = self.state_path(fixture).read_bytes()
                    with self.assertRaises((ValueError, OSError, RuntimeError)):
                        self.invoke(api, fixture, lease=authority)
                    self.assertEqual(
                        self.projection_snapshot(fixture),
                        before_public,
                    )
                    self.assertEqual(
                        self.state_path(fixture).read_bytes(),
                        before_state,
                    )

    def test_missing_only_projection_and_identical_files_are_never_replaced(self):
        materialize = self.require_api("materialize_command")
        reference = self.fixture()
        projected = self.invoke(materialize, reference)
        contents = {
            name: (reference.root / binding["path"]).read_bytes()
            for name, binding in projected["materialized"].items()
            if name in ("metadata", "stdout", "stderr")
        }

        fixture = self.fixture()
        recorded = {}
        for name, content in contents.items():
            target = fixture.root / fixture.exited["paths"][name]
            target.write_bytes(content)
            target.chmod(0o600)
            recorded[name] = (target.stat().st_ino, target.stat().st_mtime_ns)

        committed = self.invoke(materialize, fixture)
        self.assertEqual(committed["stage"], "committed")
        for name, content in contents.items():
            target = fixture.root / fixture.exited["paths"][name]
            self.assertEqual(target.read_bytes(), content)
            self.assertEqual(
                (target.stat().st_ino, target.stat().st_mtime_ns),
                recorded[name],
            )

    def test_mismatch_symlink_fifo_and_check_install_race_are_not_clobbered(self):
        materialize = self.require_api("materialize_command")

        mismatch = self.fixture()
        mismatch_target = mismatch.root / mismatch.exited["paths"]["stdout"]
        mismatch_target.write_bytes(b"occupant")
        mismatch_target.chmod(0o600)

        symlink = self.fixture()
        outside = self.publication_root / "outside.log"
        outside.write_bytes(STDERR)
        outside.chmod(0o600)
        symlink_target = symlink.root / symlink.exited["paths"]["stderr"]
        symlink_target.symlink_to(outside)
        self.assertEqual(
            outside.read_bytes(),
            (symlink.command_root / "stderr.recovery").read_bytes(),
        )

        fifo = self.fixture()
        fifo_target = fifo.root / fifo.exited["paths"]["metadata"]
        os.mkfifo(fifo_target, 0o600)

        for label, fixture in (
            ("mismatch", mismatch),
            ("symlink", symlink),
            ("fifo", fifo),
        ):
            with self.subTest(case=label):
                before = self.projection_snapshot(fixture)
                outside_before = outside.read_bytes()
                with self.assertRaises((ValueError, OSError, FileExistsError)):
                    self.invoke(materialize, fixture)
                self.assertEqual(self.projection_snapshot(fixture), before)
                self.assertEqual(outside.read_bytes(), outside_before)

        race = self.fixture()
        raced = []

        def install_racer(stage, path=None):
            if stage != "before_file_install" or raced:
                return
            target = Path(path)
            self.assertTrue(target.is_absolute())
            relative = target.relative_to(race.root)
            self.assertNotIn("..", relative.parts)
            self.assertIn(relative.as_posix(), race.exited["paths"].values())
            target.write_bytes(b"racer")
            target.chmod(0o600)
            raced.append(target)

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=install_racer,
            create=True,
        ), self.assertRaises((ValueError, OSError, FileExistsError)):
            self.invoke(materialize, race)
        self.assertEqual(len(raced), 1)
        self.assertEqual(raced[0].read_bytes(), b"racer")

        identical = self.fixture()
        identical_target = (
            identical.root / identical.exited["paths"]["stdout"]
        )
        identical_racer = []

        def identical_install_racer(stage, path=None):
            if (
                stage != "before_file_install"
                or identical_racer
                or Path(path) != identical_target
            ):
                return
            identical_target.write_bytes(STDOUT)
            identical_target.chmod(0o600)
            identical_racer.append(
                (
                    identical_target.stat().st_ino,
                    identical_target.stat().st_mtime_ns,
                )
            )

        with mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=identical_install_racer,
            create=True,
        ):
            committed = self.invoke(materialize, identical)
        self.assertEqual(committed["stage"], "committed")
        self.assertEqual(len(identical_racer), 1)
        self.assertEqual(identical_target.read_bytes(), STDOUT)
        self.assertEqual(
            (
                identical_target.stat().st_ino,
                identical_target.stat().st_mtime_ns,
            ),
            identical_racer[0],
        )

    def test_lock_order_is_transactions_commands_lifecycle_events_state(self):
        materialize = self.require_api("materialize_command")
        fixture = self.fixture()
        required = (
            ".transactions.lock",
            ".commands.lock",
            ".lifecycle.lock",
            ".events.lock",
            "state.lock",
        )
        rank = {name: index for index, name in enumerate(required)}
        held = []
        observed = []
        checkpoints = []
        state_writes = []
        event_writes = []
        file_checkpoints = {"before_file_install": [], "after_file_install": []}
        frozen_bindings = {}
        state_path = self.state_path(fixture).absolute()
        event_path = (fixture.root / "bootstrap-events.jsonl").absolute()
        public_paths = {
            (fixture.root / relative).absolute()
            for relative in fixture.exited["paths"].values()
        }
        original_io_lock = safe_io._RootedIO.lock
        original_atomic_write = safe_io._RootedIO.atomic_write
        original_stable_lock = command_state._stable_lock

        def assert_locks(expected, operation):
            self.assertEqual(
                tuple(held[: len(expected)]),
                expected,
                f"{operation} ran without its required locks: {held}",
            )

        def assert_full_locks(operation):
            assert_locks(required, operation)
            self.assertEqual(
                tuple(held),
                required,
                f"{operation} ran with an unexpected lock set: {held}",
            )

        @contextlib.contextmanager
        def tracked_io_lock(authority, path, timeout=5.0):
            with original_io_lock(authority, path, timeout):
                name = Path(path).name
                tracked = name in rank
                if tracked:
                    self.assertTrue(
                        all(rank[member] < rank[name] for member in held),
                        f"lock inversion while acquiring {name}: {held}",
                    )
                    held.append(name)
                    observed.append(tuple(held))
                try:
                    yield
                finally:
                    if tracked:
                        self.assertEqual(held.pop(), name)

        @contextlib.contextmanager
        def tracked_stable_lock(path, timeout=5.0):
            with original_stable_lock(path, timeout):
                name = Path(path).name
                tracked = name in rank
                if tracked:
                    self.assertTrue(
                        all(rank[member] < rank[name] for member in held),
                        f"lock inversion while acquiring {name}: {held}",
                    )
                    held.append(name)
                    observed.append(tuple(held))
                try:
                    yield
                finally:
                    if tracked:
                        self.assertEqual(held.pop(), name)

        def tracked_atomic_write(authority, path, content, mode=0o600):
            resolved = Path(path).absolute()
            if resolved == state_path:
                state = json.loads(content)
                if state.get("stage") in ("materialized", "committed"):
                    assert_full_locks(f"{state['stage']} state write")
                    state_writes.append(state["stage"])
                    if state["stage"] == "materialized":
                        frozen_bindings.update(
                            copy.deepcopy(state["materialized"])
                        )
            elif resolved == event_path:
                assert_locks(required[:4], "terminal event write")
                event_writes.append(tuple(held))
            return original_atomic_write(authority, path, content, mode)

        def observe_checkpoint(stage, path=None):
            if stage in (
                "after_materialized_intent",
                "before_committed_state",
                "after_committed_state",
            ):
                assert_full_locks(stage)
            elif stage == "after_terminal_event":
                assert_locks(required[:4], stage)
            elif stage in file_checkpoints:
                assert_full_locks(stage)
                target = Path(path).absolute()
                self.assertIn(target, public_paths)
                if stage == "before_file_install":
                    with self.assertRaises(FileNotFoundError):
                        target.lstat()
                else:
                    metadata = target.lstat()
                    self.assertTrue(stat.S_ISREG(metadata.st_mode))
                    relative = target.relative_to(fixture.root).as_posix()
                    binding_name = next(
                        name
                        for name, expected in fixture.exited["paths"].items()
                        if expected == relative
                    )
                    binding = frozen_bindings[binding_name]
                    self.assertEqual(binding["path"], relative)
                    self.assert_binding(self, binding, target.read_bytes())
                file_checkpoints[stage].append(target)
            checkpoints.append((stage, tuple(held), path))

        with mock.patch.object(
            safe_io._RootedIO,
            "lock",
            tracked_io_lock,
        ), mock.patch.object(
            safe_io._RootedIO,
            "atomic_write",
            tracked_atomic_write,
        ), mock.patch.object(
            command_state,
            "_stable_lock",
            tracked_stable_lock,
        ), mock.patch.object(
            commands,
            "_stable_lock",
            tracked_stable_lock,
            create=True,
        ), mock.patch.object(
            commands,
            "_command_materialization_checkpoint",
            side_effect=observe_checkpoint,
            create=True,
        ):
            self.invoke(materialize, fixture)
        self.assertIn(required, observed)
        self.assertEqual(state_writes, ["materialized", "committed"])
        checkpoint_names = [stage for stage, _locks, _path in checkpoints]
        for required_checkpoint in (
            "after_materialized_intent",
            "after_terminal_event",
            "before_committed_state",
            "after_committed_state",
        ):
            self.assertEqual(checkpoint_names.count(required_checkpoint), 1)
        self.assertEqual(
            set(file_checkpoints["before_file_install"]),
            public_paths,
        )
        self.assertEqual(
            set(file_checkpoints["after_file_install"]),
            public_paths,
        )
        self.assertEqual(len(file_checkpoints["before_file_install"]), 3)
        self.assertEqual(len(file_checkpoints["after_file_install"]), 3)
        for lock_snapshot in event_writes:
            self.assertEqual(lock_snapshot[:4], required[:4])
