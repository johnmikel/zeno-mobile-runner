"""Strict private command-state contracts and rooted persistence tests."""

from __future__ import annotations

import copy
import hashlib
import itertools
import json
import os
import stat
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from scripts.run_evidence_lib import command_state


SESSION_ID = "0123456789abcdef0123456789abcdef"
COMMAND_ID = "fedcba9876543210fedcba9876543210"
STARTED_AT = "2026-07-11T00:00:00Z"


def valid_session(**patch):
    value = {
        "schemaVersion": 1,
        "sessionId": SESSION_ID,
        "runId": "logical-1-attempt-1",
        "ownerPid": 1234,
        "ownerBirthIdentity": "linux:boot-id:100",
        "state": "active",
        "generation": 1,
        "startedAt": STARTED_AT,
    }
    value.update(patch)
    return value


def valid_request(**patch):
    value = {
        "phase": "scenario.execute",
        "name": "zmr-run",
        "failureCode": "runner.unclassified",
        "failurePolicy": "terminal",
        "stopPolicy": "none",
        "mode": "foreground",
        "stdinPolicy": "devnull",
        "sanitizedArgv": ["zmr", "run", "<absolute-path>"],
    }
    value.update(patch)
    return value


def valid_paths(**patch):
    value = {
        "metadata": "commands/zmr-run.json",
        "stdout": "commands/zmr-run.stdout.log",
        "stderr": "commands/zmr-run.stderr.log",
    }
    value.update(patch)
    return value


def valid_supervisor(**patch):
    value = {
        "pid": 1234,
        "birthIdentity": "linux:boot-id:100",
        "leaseIdentity": "1:100",
        "role": "launch",
        "predecessor": None,
    }
    value.update(patch)
    return value


def valid_anchor(**patch):
    value = {
        "pid": 1235,
        "birthIdentity": "linux:boot-id:101",
        "sid": 1235,
        "pgid": 1235,
        "groupLeaseIdentity": "1:101",
        "controlProtocolVersion": 1,
    }
    value.update(patch)
    return value


def valid_anchor_reservation(**patch):
    value = {
        "groupLeaseIdentity": "1:101",
        "controlProtocolVersion": 1,
    }
    value.update(patch)
    return value


def valid_child(**patch):
    value = {
        "pid": 1236,
        "birthIdentity": "linux:boot-id:102",
        "execAcknowledgedAt": "2026-07-11T00:00:02Z",
    }
    value.update(patch)
    return value


def valid_stream(**patch):
    value = {
        "originalBytes": 12,
        "sanitizedBytes": 12,
        "storedBytes": 12,
        "truncated": False,
    }
    value.update(patch)
    return value


def valid_capture(**patch):
    value = {
        "captureComplete": True,
        "stdout": valid_stream(),
        "stderr": valid_stream(),
    }
    value.update(patch)
    return value


def valid_outcome(**patch):
    value = {
        "kind": "exit",
        "exitStatus": 0,
        "signal": None,
        "shellVisibleStatus": 0,
        "finishedAt": "2026-07-11T00:00:03Z",
    }
    value.update(patch)
    return value


def valid_materialized(paths=None, **patch):
    paths = valid_paths() if paths is None else paths

    def binding(path):
        return {
            "path": path,
            "bytes": 12,
            "sha256": "sha256:" + "a" * 64,
        }

    value = {
        "metadata": binding(paths["metadata"]),
        "stdout": binding(paths["stdout"]),
        "stderr": binding(paths["stderr"]),
        "terminalEvent": {
            "seq": 4,
            "bytes": 128,
            "sha256": "sha256:" + "b" * 64,
        },
    }
    value.update(patch)
    return value


def valid_command_state(stage="prepared", **patch):
    request = copy.deepcopy(patch.pop("request", valid_request()))
    paths = copy.deepcopy(patch.pop("paths", valid_paths()))
    generation = patch.pop("creationGeneration", 1)
    value = {
        "schemaVersion": 1,
        "commandId": COMMAND_ID,
        "sessionId": SESSION_ID,
        "creationGeneration": generation,
        "stage": stage,
        "requestFingerprint": command_state.request_fingerprint(
            SESSION_ID, generation, request, paths
        ),
        "request": request,
        "paths": paths,
        "startedEvent": {
            "schemaVersion": 1,
            "seq": 3,
            "timestamp": "2026-07-11T00:00:01Z",
            "phase": request["phase"],
            "status": "started",
            "command": paths["metadata"],
        },
        "supervisor": valid_supervisor(),
        "anchorReservation": valid_anchor_reservation(),
        "anchor": None,
        "child": None,
        "stopIntent": None,
        "outcome": None,
        "capture": None,
        "materialized": None,
    }
    if stage in (
        "anchored",
        "anchor_stop_requested",
        "running",
        "stop_requested",
        "exited",
        "materialized",
        "committed",
    ):
        value["anchor"] = valid_anchor()
        value["child"] = valid_child()
    if stage in ("anchored", "anchor_stop_requested"):
        value["child"] = None
    if stage == "anchor_stop_requested":
        value["stopIntent"] = {
            "kind": "cancel",
            "requestedAt": "2026-07-11T00:00:02.500Z",
            "killAuthorizedAt": None,
        }
    if stage == "stop_requested":
        value["stopIntent"] = {
            "kind": "cancel",
            "requestedAt": "2026-07-11T00:00:02.500Z",
            "killAuthorizedAt": None,
        }
    if stage in ("exited", "materialized", "committed"):
        value["outcome"] = valid_outcome()
        value["capture"] = valid_capture()
    if stage in ("materialized", "committed"):
        value["materialized"] = valid_materialized(paths)
    value.update(patch)
    return value


def raw_request_fingerprint(session_id, generation, request, paths):
    payload = {
        "sessionId": session_id,
        "creationGeneration": generation,
        "request": request,
        "paths": paths,
    }
    canonical = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(canonical).hexdigest()


def negative_exec_state(stage="exited"):
    state = valid_command_state("anchored")
    state.update(
        stage=stage,
        anchor=valid_anchor(),
        child=None,
        stopIntent=None,
        outcome={
            "kind": "exec_failure",
            "exitStatus": 127,
            "signal": None,
            "shellVisibleStatus": 127,
            "execFailedAt": "2026-07-11T00:00:02Z",
        },
        capture={
            "captureComplete": True,
            "stdout": valid_stream(
                originalBytes=0,
                sanitizedBytes=0,
                storedBytes=0,
            ),
            "stderr": valid_stream(
                originalBytes=24,
                sanitizedBytes=20,
                storedBytes=20,
            ),
        },
    )
    if stage in ("materialized", "committed"):
        state["materialized"] = valid_materialized(state["paths"])
        state["materialized"]["stdout"]["bytes"] = 0
        state["materialized"]["stderr"]["bytes"] = 20
    return state


def supervisor_failure_state(
    source_stage="prepared",
    *,
    error_code="runner.command_supervisor_lost",
    final_stage="exited",
):
    state = valid_command_state(source_stage)
    if error_code == "runner.command_supervisor_lost":
        previous = state["supervisor"]
        state["supervisor"] = valid_supervisor(
            pid=2234,
            birthIdentity="linux:boot-id:200",
            leaseIdentity="1:100",
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(previous),
        )
    state.update(
        stage=final_stage,
        outcome={
            "kind": "supervisor_failure",
            "errorCode": error_code,
            "exitStatus": None,
            "signal": None,
            "shellVisibleStatus": 125,
            "failedAt": "2026-07-11T00:00:03Z",
        },
        capture=valid_capture(
            captureComplete=False,
            stdout=valid_stream(truncated=True),
            stderr=valid_stream(truncated=True),
        ),
        materialized=None,
    )
    if final_stage in ("materialized", "committed"):
        state["materialized"] = valid_materialized(state["paths"])
    return state


def stopped_before_ack_state(final_stage="exited", *, kind="cancel"):
    request = valid_request(
        stopPolicy="expected-term" if kind == "expected" else "none"
    )
    state = valid_command_state("anchor_stop_requested", request=request)
    state["stopIntent"]["kind"] = kind
    state.update(
        stage=final_stage,
        outcome={
            "kind": "stopped_before_ack",
            "requestKind": kind,
            "graceExpired": False,
            "escalated": False,
            "shellVisibleStatus": 0 if kind == "expected" else 130,
            "stoppedAt": "2026-07-11T00:00:03Z",
        },
        capture=valid_capture(),
        materialized=None,
    )
    if final_stage in ("materialized", "committed"):
        state["materialized"] = valid_materialized(state["paths"])
    return state


def failed_diagnostic(index=0, *, classification="app_failure"):
    code = {
        "app_failure": "app.assertion_failed",
        "runner_failure": "runner.unclassified",
        "configuration_failure": "config.invalid",
        "infrastructure_failure": "infra.network",
    }[classification]
    return {
        "status": "failed",
        "classification": classification,
        "phase": "scenario.execute",
        "errorCode": code,
        "summary": f"failure {index}",
        "hint": "Inspect evidence",
        "commandStatus": 1,
        "source": f"source-{index}",
    }


class CommandStateTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.publication_root = Path(self.temporary.name)
        self.attempt_root = self.publication_root / "attempts" / "logical-1-attempt-1"
        self.attempt_root.mkdir(parents=True)

    def initialize(self):
        return command_state.initialize_control_layout(
            self.attempt_root, valid_session()
        )

    def reserve_prepared_state(self, **patch):
        lease = command_state.reserve_command_layout(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
        )
        self.addCleanup(lease.close)
        supervisor = valid_supervisor(
            pid=os.getpid(),
            leaseIdentity=lease.identity,
        )
        state = valid_command_state(
            "prepared",
            supervisor=supervisor,
            anchorReservation=lease.anchor_reservation,
            **patch,
        )
        return lease, state

    @staticmethod
    def snapshot(root):
        result = {}
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root).as_posix()
            metadata = path.lstat()
            if path.is_symlink():
                result[relative] = ("symlink", os.readlink(path))
            elif path.is_dir():
                result[relative] = ("directory", stat.S_IMODE(metadata.st_mode))
            else:
                result[relative] = (
                    "file",
                    stat.S_IMODE(metadata.st_mode),
                    path.read_bytes(),
                )
        return result


class DocumentContractTests(CommandStateTestCase):
    def test_session_contract_is_exact_bounded_and_canonical(self):
        session = valid_session()
        self.assertEqual(command_state.validate_session(session), session)
        expected = (
            json.dumps(
                session,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")
        self.assertEqual(command_state.encode_session(session), expected)
        self.assertLessEqual(len(expected), command_state.MAX_SESSION_STATE_BYTES)

        invalid = copy.deepcopy(session)
        invalid["unknown"] = True
        with self.assertRaisesRegex(ValueError, "session.*shape"):
            command_state.validate_session(invalid)
        for field, value in (
            ("sessionId", SESSION_ID.upper()),
            ("generation", True),
            ("ownerPid", 0),
            ("state", "closed"),
            ("startedAt", "2026-07-11"),
        ):
            with self.subTest(field=field):
                invalid = valid_session(**{field: value})
                with self.assertRaises(ValueError):
                    command_state.validate_session(invalid)

        oversized = valid_session(ownerBirthIdentity="x" * (16 * 1024))
        with self.assertRaisesRegex(ValueError, "session.*exceeds"):
            command_state.encode_session(oversized)

    def test_request_fingerprint_hashes_exact_canonical_native_payload(self):
        request = valid_request()
        paths = valid_paths()
        payload = {
            "sessionId": SESSION_ID,
            "creationGeneration": 1,
            "request": request,
            "paths": paths,
        }
        canonical = json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
        expected = "sha256:" + hashlib.sha256(canonical).hexdigest()
        self.assertEqual(
            command_state.request_fingerprint(SESSION_ID, 1, request, paths),
            expected,
        )

        reordered = dict(reversed(list(request.items())))
        self.assertEqual(
            command_state.request_fingerprint(SESSION_ID, 1, reordered, paths),
            expected,
        )
        changed = valid_paths(
            metadata="commands/other.json",
            stdout="commands/other.stdout.log",
            stderr="commands/other.stderr.log",
        )
        self.assertNotEqual(
            command_state.request_fingerprint(SESSION_ID, 1, request, changed),
            expected,
        )

    def test_command_contract_rejects_unknown_fields_and_fingerprint_mismatch(self):
        prepared = valid_command_state()
        self.assertEqual(command_state.validate_command_state(prepared), prepared)
        self.assertLessEqual(
            len(command_state.encode_command_state(prepared)),
            command_state.MAX_COMMAND_STATE_BYTES,
        )

        cases = []
        unknown_top = copy.deepcopy(prepared)
        unknown_top["unknown"] = None
        cases.append(unknown_top)
        unknown_request = copy.deepcopy(prepared)
        unknown_request["request"]["rawArgv"] = ["secret"]
        cases.append(unknown_request)
        unknown_supervisor = copy.deepcopy(prepared)
        unknown_supervisor["supervisor"]["recursiveHistory"] = []
        cases.append(unknown_supervisor)
        wrong_fingerprint = copy.deepcopy(prepared)
        wrong_fingerprint["requestFingerprint"] = "sha256:" + "0" * 64
        cases.append(wrong_fingerprint)
        absolute_path = copy.deepcopy(prepared)
        absolute_path["paths"]["stdout"] = "/tmp/raw.log"
        cases.append(absolute_path)
        for index, value in enumerate(cases):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(value)

    def test_untrusted_scalar_types_fail_as_contract_errors(self):
        request = valid_request(failureCode=[])
        with self.assertRaises(ValueError):
            command_state.request_fingerprint(
                SESSION_ID, 1, request, valid_paths()
            )
        diagnostic = failed_diagnostic()
        diagnostic["classification"] = []
        with self.assertRaises(ValueError):
            command_state.validate_caller_diagnostic(diagnostic)

    def test_all_command_stages_have_exact_legal_null_combinations(self):
        for stage in (
            "prepared",
            "anchored",
            "anchor_stop_requested",
            "running",
            "stop_requested",
            "exited",
            "materialized",
            "committed",
        ):
            with self.subTest(stage=stage):
                state = valid_command_state(stage)
                self.assertEqual(command_state.validate_command_state(state), state)

        illegal = (
            valid_command_state("prepared", anchor=valid_anchor()),
            valid_command_state("anchored", child=valid_child()),
            valid_command_state("anchor_stop_requested", stopIntent=None),
            valid_command_state("running", child=None),
            valid_command_state("running", stopIntent={
                "kind": "cancel",
                "requestedAt": "2026-07-11T00:00:02Z",
                "killAuthorizedAt": None,
            }),
            valid_command_state("stop_requested", outcome=valid_outcome()),
            valid_command_state("exited", capture=None),
            valid_command_state("materialized", materialized=None),
        )
        for index, state in enumerate(illegal):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(state)

    def test_negative_exec_handshake_is_the_only_childless_exited_shape(self):
        state = negative_exec_state()
        self.assertEqual(command_state.validate_command_state(state), state)

        mutations = []
        for path, value in (
            (("anchor",), None),
            (("child",), valid_child()),
            (("outcome", "exitStatus"), 126),
            (("outcome", "signal"), 9),
            (("outcome", "kind"), "exit"),
            (("capture", "captureComplete"), False),
            (("capture", "stdout", "storedBytes"), 1),
            (("capture", "stderr", "truncated"), True),
            (("stopIntent",), {
                "kind": "cancel",
                "requestedAt": "2026-07-11T00:00:02Z",
                "killAuthorizedAt": None,
            }),
        ):
            changed = copy.deepcopy(state)
            target = changed
            for component in path[:-1]:
                target = target[component]
            target[path[-1]] = value
            mutations.append(changed)
        for index, changed in enumerate(mutations):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(changed)

    def test_anchor_reservation_is_exact_immutable_and_cross_bound(self):
        anchored = valid_command_state("anchored")
        self.assertEqual(command_state.validate_command_state(anchored), anchored)
        for changed in (
            valid_command_state(
                "prepared",
                anchorReservation={
                    "groupLeaseIdentity": "1:101",
                    "controlProtocolVersion": 1,
                    "extra": True,
                },
            ),
            valid_command_state(
                "anchored",
                anchorReservation=valid_anchor_reservation(
                    groupLeaseIdentity="1:999"
                ),
            ),
            valid_command_state(
                "anchored",
                anchorReservation=valid_anchor_reservation(
                    controlProtocolVersion=2
                ),
            ),
        ):
            with self.assertRaises(ValueError):
                command_state.validate_command_state(changed)

        changed = copy.deepcopy(anchored)
        changed["anchorReservation"] = valid_anchor_reservation(
            groupLeaseIdentity="1:999"
        )
        changed["anchor"]["groupLeaseIdentity"] = "1:999"
        with self.assertRaisesRegex(ValueError, "immutable"):
            command_state.validate_command_transition(
                valid_command_state("prepared"),
                changed,
                session_id=SESSION_ID,
                generation=1,
            )

    def test_supervisor_failure_has_exact_identity_and_capture_variants(self):
        sources = (
            "prepared",
            "anchored",
            "anchor_stop_requested",
            "running",
            "stop_requested",
        )
        for source in sources:
            before = valid_command_state(source)
            recovery = copy.deepcopy(before)
            recovery["supervisor"] = copy.deepcopy(
                supervisor_failure_state(source)["supervisor"]
            )
            failed = supervisor_failure_state(source)
            with self.subTest(source=source, code="lost"):
                self.assertEqual(
                    command_state.validate_command_transition(
                        before,
                        recovery,
                        session_id=SESSION_ID,
                        generation=1,
                    ),
                    recovery,
                )
                self.assertEqual(
                    command_state.validate_command_transition(
                        recovery,
                        failed,
                        session_id=SESSION_ID,
                        generation=1,
                    ),
                    failed,
                )
            capture_failed = supervisor_failure_state(
                source, error_code="runner.capture_failed"
            )
            with self.subTest(source=source, code="capture"):
                self.assertEqual(
                    command_state.validate_command_transition(
                        before,
                        capture_failed,
                        session_id=SESSION_ID,
                        generation=1,
                    ),
                    capture_failed,
                )

        invalid = supervisor_failure_state("prepared")
        invalid["supervisor"] = valid_supervisor()
        with self.assertRaises(ValueError):
            command_state.validate_command_state(invalid)
        invalid = supervisor_failure_state(
            "running", error_code="runner.capture_failed"
        )
        invalid["capture"]["stdout"]["truncated"] = False
        with self.assertRaises(ValueError):
            command_state.validate_command_state(invalid)

    def test_stopped_before_ack_is_exact_and_cross_bound_to_stop(self):
        for kind, status in (("expected", 0), ("cancel", 130)):
            stopped = stopped_before_ack_state(kind=kind)
            source = valid_command_state(
                "anchor_stop_requested",
                request=valid_request(
                    stopPolicy="expected-term" if kind == "expected" else "none"
                ),
            )
            source["stopIntent"]["kind"] = kind
            with self.subTest(kind=kind):
                self.assertEqual(stopped["outcome"]["shellVisibleStatus"], status)
                self.assertEqual(
                    command_state.validate_command_transition(
                        source,
                        stopped,
                        session_id=SESSION_ID,
                        generation=1,
                    ),
                    stopped,
                )

        escalated = stopped_before_ack_state()
        escalated["stopIntent"]["killAuthorizedAt"] = (
            "2026-07-11T00:00:02.750Z"
        )
        escalated["outcome"].update(
            graceExpired=True,
            escalated=True,
            shellVisibleStatus=125,
        )
        self.assertEqual(command_state.validate_command_state(escalated), escalated)
        for grace_expired, escalated_value, status in (
            (True, False, 125),
            (False, True, 125),
            (True, True, 130),
        ):
            invalid = stopped_before_ack_state()
            invalid["outcome"].update(
                graceExpired=grace_expired,
                escalated=escalated_value,
                shellVisibleStatus=status,
            )
            with self.subTest(
                grace_expired=grace_expired,
                escalated=escalated_value,
                status=status,
            ):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(invalid)

    def test_terminal_state_cross_field_invariants_reject_forged_documents(self):
        launch = valid_supervisor()
        recovery = valid_supervisor(
            pid=2234,
            birthIdentity="linux:boot-id:200",
            leaseIdentity=launch["leaseIdentity"],
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(launch),
        )
        for forged in (
            valid_command_state("exited", supervisor=recovery),
            stopped_before_ack_state() | {"supervisor": recovery},
        ):
            with self.subTest(kind=forged["outcome"]["kind"]):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(forged)

    def test_kill_authorization_is_one_write_ahead_monotonic_transition(self):
        for stage in ("anchor_stop_requested", "stop_requested"):
            before = valid_command_state(stage)
            authorized = copy.deepcopy(before)
            authorized["stopIntent"]["killAuthorizedAt"] = (
                "2026-07-11T00:00:02.750Z"
            )
            with self.subTest(stage=stage, transition="authorize"):
                self.assertEqual(
                    command_state.validate_command_transition(
                        before,
                        authorized,
                        session_id=SESSION_ID,
                        generation=1,
                    ),
                    authorized,
                )
            for invalid in (
                before,
                authorized
                | {
                    "stopIntent": copy.deepcopy(authorized["stopIntent"])
                    | {"killAuthorizedAt": "2026-07-11T00:00:03Z"}
                },
            ):
                with self.subTest(stage=stage, transition="rewrite"):
                    with self.assertRaises(ValueError):
                        command_state.validate_command_transition(
                            authorized,
                            invalid,
                            session_id=SESSION_ID,
                            generation=1,
                        )

            combined = copy.deepcopy(authorized)
            combined["supervisor"] = valid_supervisor(
                pid=2234,
                birthIdentity="linux:boot-id:200",
                leaseIdentity=before["supervisor"]["leaseIdentity"],
                role="recovery",
                predecessor=command_state.supervisor_fingerprint(
                    before["supervisor"]
                ),
            )
            with self.subTest(stage=stage, transition="combined-recovery"):
                with self.assertRaises(ValueError):
                    command_state.validate_command_transition(
                        before,
                        combined,
                        session_id=SESSION_ID,
                        generation=1,
                    )

        for source_stage, stop_stage in (
            ("anchored", "anchor_stop_requested"),
            ("running", "stop_requested"),
        ):
            source = valid_command_state(source_stage)
            preauthorized = valid_command_state(stop_stage)
            preauthorized["stopIntent"]["killAuthorizedAt"] = (
                "2026-07-11T00:00:02.750Z"
            )
            with self.subTest(source=source_stage, transition="initial"):
                with self.assertRaises(ValueError):
                    command_state.validate_command_transition(
                        source,
                        preauthorized,
                        session_id=SESSION_ID,
                        generation=1,
                    )

        invalid_time = valid_command_state("stop_requested")
        invalid_time["stopIntent"]["killAuthorizedAt"] = (
            "2026-07-11T00:00:02.250Z"
        )
        with self.assertRaises(ValueError):
            command_state.validate_command_state(invalid_time)

    def test_normal_outcome_shell_status_cross_binds_stop_and_escalation(self):
        cancel = valid_command_state(
            "exited",
            stopIntent={
                "kind": "cancel",
                "requestedAt": "2026-07-11T00:00:02.500Z",
                "killAuthorizedAt": None,
            },
            outcome=valid_outcome(shellVisibleStatus=130),
        )
        expected = valid_command_state(
            "exited",
            request=valid_request(stopPolicy="expected-term"),
            stopIntent={
                "kind": "expected",
                "requestedAt": "2026-07-11T00:00:02.500Z",
                "killAuthorizedAt": None,
            },
            outcome=valid_outcome(shellVisibleStatus=0),
        )
        escalated = copy.deepcopy(cancel)
        escalated["stopIntent"]["killAuthorizedAt"] = (
            "2026-07-11T00:00:02.750Z"
        )
        escalated["outcome"]["shellVisibleStatus"] = 125
        for state in (cancel, expected, escalated):
            self.assertEqual(command_state.validate_command_state(state), state)
            wrong = copy.deepcopy(state)
            wrong["outcome"]["shellVisibleStatus"] = 1
            with self.assertRaises(ValueError):
                command_state.validate_command_state(wrong)

        expected_stop = {
            "kind": "expected",
            "requestedAt": "2026-07-11T00:00:02.500Z",
            "killAuthorizedAt": None,
        }
        for stage in ("anchor_stop_requested", "stop_requested", "exited"):
            forged = valid_command_state(
                stage,
                stopIntent=copy.deepcopy(expected_stop),
            )
            with self.subTest(stage=stage, invariant="expected-stop-policy"):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(forged)

        for outcome_state in (
            valid_command_state("exited"),
            stopped_before_ack_state(),
        ):
            forged = copy.deepcopy(outcome_state)
            forged["capture"] = valid_capture(
                captureComplete=False,
                stdout=valid_stream(truncated=True),
                stderr=valid_stream(truncated=True),
            )
            with self.subTest(
                kind=forged["outcome"]["kind"], invariant="capture-complete"
            ):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(forged)

        for stream_name in ("stdout", "stderr"):
            forged = valid_command_state("materialized")
            forged["materialized"][stream_name]["bytes"] += 1
            with self.subTest(stream=stream_name, invariant="materialized-size"):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(forged)

    def test_admitted_argv_worst_case_fits_raised_state_cap(self):
        argument = '"\\' * (16 * 1024 // 2)
        request = valid_request(sanitizedArgv=[argument] * 4)
        state = valid_command_state(request=request)
        encoded = command_state.encode_command_state(state)
        self.assertLessEqual(len(encoded), 256 * 1024)
        self.assertEqual(command_state.MAX_COMMAND_STATE_BYTES, 256 * 1024)
        unsafe = valid_request(sanitizedArgv=["line\nbreak"])
        with self.assertRaises(ValueError):
            valid_command_state(request=unsafe)

    def test_command_transitions_are_monotonic_and_identity_preserving(self):
        prepared = valid_command_state("prepared")
        anchored = valid_command_state("anchored")
        anchor_stopped = valid_command_state("anchor_stop_requested")
        running = valid_command_state("running")
        stopped = valid_command_state("stop_requested")
        exited = valid_command_state("exited")
        materialized = valid_command_state("materialized")
        committed = valid_command_state("committed")
        for before, after in (
            (prepared, anchored),
            (anchored, running),
            (anchored, anchor_stopped),
            (running, stopped),
            (running, exited),
            (stopped, valid_command_state(
                "exited",
                stopIntent=copy.deepcopy(stopped["stopIntent"]),
                outcome=valid_outcome(shellVisibleStatus=130),
            )),
            (exited, materialized),
            (materialized, committed),
            (anchored, negative_exec_state()),
            (anchor_stopped, stopped_before_ack_state()),
            (negative_exec_state(), negative_exec_state("materialized")),
            (negative_exec_state("materialized"), negative_exec_state("committed")),
        ):
            with self.subTest(before=before["stage"], after=after["stage"]):
                self.assertEqual(
                    command_state.validate_command_transition(
                        before,
                        after,
                        session_id=SESSION_ID,
                        generation=1,
                    ),
                    after,
                )

        for before, after in (
            (prepared, running),
            (prepared, exited),
            (anchored, stopped),
            (anchor_stopped, running),
            (running, materialized),
            (exited, running),
            (committed, committed | {"stage": "materialized"}),
        ):
            with self.subTest(before=before["stage"], after=after["stage"]):
                with self.assertRaises(ValueError):
                    command_state.validate_command_transition(
                        before,
                        after,
                        session_id=SESSION_ID,
                        generation=1,
                    )

        changed_request = copy.deepcopy(running)
        changed_request["request"]["name"] = "other"
        changed_request["requestFingerprint"] = command_state.request_fingerprint(
            SESSION_ID,
            1,
            changed_request["request"],
            changed_request["paths"],
        )
        with self.assertRaisesRegex(ValueError, "immutable"):
            command_state.validate_command_transition(
                anchored,
                changed_request,
                session_id=SESSION_ID,
                generation=1,
            )

    def test_recovery_claim_uses_digest_of_exact_prior_supervisor(self):
        before = valid_command_state("running")
        after = copy.deepcopy(before)
        after["supervisor"] = valid_supervisor(
            pid=2234,
            birthIdentity="linux:boot-id:200",
            leaseIdentity="1:100",
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(before["supervisor"]),
        )
        self.assertEqual(
            command_state.validate_command_transition(
                before, after, session_id=SESSION_ID, generation=2
            ),
            after,
        )
        bad = copy.deepcopy(after)
        bad["supervisor"]["predecessor"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "predecessor"):
            command_state.validate_command_transition(
                before, bad, session_id=SESSION_ID, generation=2
            )
        changed_lease = copy.deepcopy(after)
        changed_lease["supervisor"]["leaseIdentity"] = "1:999"
        with self.assertRaisesRegex(ValueError, "stable lease identity"):
            command_state.validate_command_transition(
                before,
                changed_lease,
                session_id=SESSION_ID,
                generation=2,
            )

    def test_tokens_paths_and_argv_are_confined_at_exact_boundaries(self):
        for field in ("runId", "ownerBirthIdentity"):
            for character in ("\x01", "\n", "\x7f"):
                with self.subTest(field=field, character=ord(character)):
                    with self.assertRaises(ValueError):
                        command_state.validate_session(
                            valid_session(**{field: f"unsafe{character}token"})
                        )
        for field in ("birthIdentity", "leaseIdentity"):
            supervisor = valid_supervisor(**{field: "unsafe\x1ftoken"})
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(
                        valid_command_state(supervisor=supervisor)
                    )

        for identity in (
            "01:2",
            "1:02",
            "+1:2",
            "-1:2",
            "1 :2",
            "1:2:3",
            f"{1 << 64}:2",
            f"1:{1 << 64}",
        ):
            with self.subTest(lease_identity=identity):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(
                        valid_command_state(
                            supervisor=valid_supervisor(leaseIdentity=identity)
                        )
                    )
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(
                        valid_command_state(
                            anchorReservation=valid_anchor_reservation(
                                groupLeaseIdentity=identity
                            )
                        )
                    )
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(
                        valid_command_state(
                            "anchored",
                            anchor=valid_anchor(groupLeaseIdentity=identity),
                        )
                    )

        for code in (
            "runner.command_supervisor_lost",
            "runner.capture_failed",
        ):
            with self.subTest(supervisor_only_failure_code=code):
                with self.assertRaises(ValueError):
                    valid_command_state(
                        request=valid_request(failureCode=code)
                    )

        for field, path in (
            ("metadata", "reports/result.json"),
            ("metadata", "commands/result.log"),
            ("stdout", "commands/result.json"),
            ("stderr", ".evidence-control/stderr.log"),
        ):
            with self.subTest(field=field, path=path):
                paths = valid_paths(**{field: path})
                with self.assertRaises(ValueError):
                    valid_command_state(paths=paths)
        mismatched_stems = valid_paths(stdout="commands/other.stdout.log")
        with self.assertRaises(ValueError):
            valid_command_state(paths=mismatched_stems)

        exact_count = valid_request(sanitizedArgv=["x"] * 256)
        exact_term = valid_request(sanitizedArgv=["x" * (16 * 1024)])
        exact_aggregate = valid_request(sanitizedArgv=["x" * (16 * 1024)] * 4)
        for request in (exact_count, exact_term, exact_aggregate):
            state = valid_command_state(request=request)
            self.assertEqual(command_state.validate_command_state(state), state)
        for argv in (
            ["x"] * 257,
            ["x" * (16 * 1024 + 1)],
            ["x" * (16 * 1024)] * 4 + ["x"],
            ["unsafe\x00argument"],
        ):
            with self.subTest(size=sum(len(item) for item in argv)):
                request = valid_request(sanitizedArgv=argv)
                with self.assertRaises(ValueError):
                    valid_command_state(request=request)

    def test_nested_shapes_cross_bindings_and_process_identities_are_exact(self):
        mutations = []
        for stage, path, value in (
            ("running", ("anchor", "extra"), True),
            ("running", ("child", "extra"), True),
            ("stop_requested", ("stopIntent", "extra"), True),
            ("exited", ("outcome", "extra"), True),
            ("exited", ("capture", "stdout", "extra"), True),
            ("materialized", ("materialized", "metadata", "extra"), True),
            ("materialized", ("materialized", "terminalEvent", "extra"), True),
            ("running", ("startedEvent", "phase"), "cleanup"),
            ("running", ("startedEvent", "command"), "commands/other.json"),
            ("materialized", ("materialized", "stdout", "path"), "commands/other.log"),
            ("running", ("anchor", "sid"), 9999),
            ("running", ("anchor", "pgid"), 9999),
            ("running", ("child", "pid"), 1235),
            ("running", ("supervisor", "pid"), 1235),
        ):
            state = valid_command_state(stage)
            target = state
            for component in path[:-1]:
                target = target[component]
            target[path[-1]] = value
            mutations.append((stage, path, state))
        for stage, path, state in mutations:
            with self.subTest(stage=stage, path=path):
                with self.assertRaises(ValueError):
                    command_state.validate_command_state(state)

    def test_transitions_reject_every_historical_identity_mutation(self):
        cases = []
        running = valid_command_state("running")
        stopped = valid_command_state("stop_requested")
        changed = copy.deepcopy(stopped)
        changed["anchor"]["birthIdentity"] = "linux:boot-id:changed"
        cases.append((running, changed))
        changed = copy.deepcopy(stopped)
        changed["child"]["birthIdentity"] = "linux:boot-id:changed"
        cases.append((running, changed))

        exited = valid_command_state("exited")
        materialized = valid_command_state("materialized")
        for field in ("anchor", "child", "stopIntent", "outcome", "capture"):
            changed = copy.deepcopy(materialized)
            if field == "anchor":
                changed[field]["birthIdentity"] = "linux:boot-id:changed"
            elif field == "child":
                changed[field]["birthIdentity"] = "linux:boot-id:changed"
            elif field == "stopIntent":
                exited_with_stop = copy.deepcopy(exited)
                exited_with_stop[field] = {
                    "kind": "cancel",
                    "requestedAt": "2026-07-11T00:00:02Z",
                    "killAuthorizedAt": None,
                }
                changed[field] = {
                    "kind": "expected",
                    "requestedAt": "2026-07-11T00:00:02Z",
                    "killAuthorizedAt": None,
                }
                cases.append((exited_with_stop, changed))
                continue
            elif field == "outcome":
                changed[field]["finishedAt"] = "2026-07-11T00:00:04Z"
            else:
                changed[field]["stdout"]["truncated"] = True
            cases.append((exited, changed))

        committed = valid_command_state("committed")
        changed = copy.deepcopy(committed)
        changed["materialized"]["metadata"]["sha256"] = "sha256:" + "c" * 64
        cases.append((materialized, changed))
        for before, after in cases:
            with self.subTest(before=before["stage"], after=after["stage"]):
                with self.assertRaises(ValueError):
                    command_state.validate_command_transition(
                        before,
                        after,
                        session_id=SESSION_ID,
                        generation=1,
                    )

        recovered_committed = copy.deepcopy(committed)
        recovered_committed["supervisor"] = valid_supervisor(
            pid=2234,
            birthIdentity="linux:boot-id:200",
            leaseIdentity="1:100",
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(
                committed["supervisor"]
            ),
        )
        with self.assertRaises(ValueError):
            command_state.validate_command_transition(
                committed,
                recovered_committed,
                session_id=SESSION_ID,
                generation=1,
            )

    def test_recovery_prepared_is_valid_but_negative_exec_requires_launch(self):
        launch = valid_supervisor()
        recovery = valid_supervisor(
            pid=2234,
            birthIdentity="linux:boot-id:200",
            leaseIdentity="1:100",
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(launch),
        )
        recovered_prepared = valid_command_state("prepared", supervisor=recovery)
        self.assertEqual(
            command_state.validate_command_state(recovered_prepared),
            recovered_prepared,
        )
        recovered_anchored = valid_command_state("anchored", supervisor=recovery)
        with self.assertRaises(ValueError):
            command_state.validate_command_transition(
                recovered_prepared,
                recovered_anchored,
                session_id=SESSION_ID,
                generation=1,
            )
        with self.assertRaises(ValueError):
            command_state.validate_command_transition(
                recovered_anchored,
                valid_command_state("running", supervisor=recovery),
                session_id=SESSION_ID,
                generation=1,
            )
        negative = negative_exec_state()
        negative["supervisor"] = recovery
        with self.assertRaises(ValueError):
            command_state.validate_command_state(negative)

    def test_recovery_pre_exit_may_persist_stop_but_only_supervisor_failure(self):
        def recovery_claim(state):
            claimed = copy.deepcopy(state)
            claimed["supervisor"] = valid_supervisor(
                pid=2234,
                birthIdentity="linux:boot-id:200",
                leaseIdentity="1:100",
                role="recovery",
                predecessor=command_state.supervisor_fingerprint(
                    state["supervisor"]
                ),
            )
            return claimed

        anchored = recovery_claim(valid_command_state("anchored"))
        anchor_stopped = valid_command_state(
            "anchor_stop_requested",
            supervisor=copy.deepcopy(anchored["supervisor"]),
        )
        self.assertEqual(
            command_state.validate_command_transition(
                anchored,
                anchor_stopped,
                session_id=SESSION_ID,
                generation=1,
            ),
            anchor_stopped,
        )

        running = recovery_claim(valid_command_state("running"))
        stopped = valid_command_state(
            "stop_requested",
            supervisor=copy.deepcopy(running["supervisor"]),
        )
        self.assertEqual(
            command_state.validate_command_transition(
                running,
                stopped,
                session_id=SESSION_ID,
                generation=1,
            ),
            stopped,
        )

        forbidden = (
            (
                anchor_stopped,
                stopped_before_ack_state()
                | {"supervisor": copy.deepcopy(anchor_stopped["supervisor"])},
            ),
            (
                running,
                valid_command_state(
                    "exited",
                    supervisor=copy.deepcopy(running["supervisor"]),
                ),
            ),
            (
                stopped,
                valid_command_state(
                    "exited",
                    supervisor=copy.deepcopy(stopped["supervisor"]),
                    stopIntent=copy.deepcopy(stopped["stopIntent"]),
                    outcome=valid_outcome(shellVisibleStatus=130),
                ),
            ),
        )
        for before, after in forbidden:
            with self.subTest(stage=before["stage"], kind=after["outcome"]["kind"]):
                with self.assertRaises(ValueError):
                    command_state.validate_command_transition(
                        before,
                        after,
                        session_id=SESSION_ID,
                        generation=1,
                    )


class RootedPersistenceTests(CommandStateTestCase):
    def test_initialization_creates_only_private_rooted_stable_layout(self):
        session = self.initialize()
        self.assertEqual(session, valid_session())
        control = self.attempt_root / ".evidence-control"
        self.assertEqual(
            {path.name for path in control.iterdir()},
            {".commands.lock", "session.json", "terminal-intent.json", "commands"},
        )
        self.assertEqual((control.stat().st_mode & 0o777), 0o700)
        self.assertEqual((control / "commands").stat().st_mode & 0o777, 0o700)
        for name in (".commands.lock", "session.json", "terminal-intent.json"):
            path = control / name
            self.assertTrue(path.is_file())
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(command_state.read_session(self.attempt_root), valid_session())
        self.assertEqual(
            command_state.read_terminal_intent(self.attempt_root),
            command_state.make_terminal_intent(SESSION_ID),
        )

        before = self.snapshot(self.attempt_root)
        self.assertEqual(self.initialize(), valid_session())
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_initialization_requires_new_active_generation_one_matching_attempt(self):
        for patch in (
            {"state": "finalizing"},
            {"generation": 2},
            {"runId": "different-attempt"},
        ):
            with self.subTest(patch=patch):
                before = self.snapshot(self.attempt_root)
                with self.assertRaises(ValueError):
                    command_state.initialize_control_layout(
                        self.attempt_root, valid_session(**patch)
                    )
                self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_symlinked_control_root_is_rejected_without_touching_target(self):
        outside = self.publication_root / "outside"
        outside.mkdir()
        marker = outside / "marker"
        marker.write_text("untouched", encoding="utf-8")
        (self.attempt_root / ".evidence-control").symlink_to(
            outside, target_is_directory=True
        )
        before = self.snapshot(self.publication_root)
        with self.assertRaises(ValueError):
            self.initialize()
        self.assertEqual(self.snapshot(self.publication_root), before)
        self.assertEqual(marker.read_text(encoding="utf-8"), "untouched")

    def test_private_layout_requires_exact_file_and_directory_modes(self):
        self.initialize()
        control = self.attempt_root / ".evidence-control"
        session_path = control / "session.json"
        for mode in (0o700, 0o4600):
            session_path.chmod(mode)
            self.assertEqual(stat.S_IMODE(session_path.stat().st_mode), mode)
            before = self.snapshot(self.attempt_root)
            with self.subTest(kind="file", mode=oct(mode)):
                with self.assertRaises(ValueError):
                    command_state.read_session(self.attempt_root)
                self.assertEqual(self.snapshot(self.attempt_root), before)
            session_path.chmod(0o600)

        for mode in (0o500, 0o1700):
            control.chmod(mode)
            self.assertEqual(stat.S_IMODE(control.stat().st_mode), mode)
            before = self.snapshot(self.attempt_root)
            with self.subTest(kind="directory", mode=oct(mode)):
                with self.assertRaises(ValueError):
                    command_state.read_session(self.attempt_root)
                self.assertEqual(self.snapshot(self.attempt_root), before)
            control.chmod(0o700)

        lease, state = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, state, supervisor_lease=lease
        )
        supervisor_path = control / "commands" / COMMAND_ID / "supervisor.lease"
        supervisor_path.chmod(0o700)
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)
        supervisor_path.chmod(0o600)

    def test_command_creation_installs_stable_files_and_atomic_state(self):
        self.initialize()
        lease, state = self.reserve_prepared_state()
        self.assertEqual(
            command_state.create_command_state(
                self.attempt_root, state, supervisor_lease=lease
            ),
            state,
        )
        command_root = (
            self.attempt_root / ".evidence-control" / "commands" / COMMAND_ID
        )
        self.assertEqual(
            {path.name for path in command_root.iterdir()},
            {
                "state.lock",
                "state.json",
                "supervisor.lease",
                "group.lease",
                "stdout.recovery",
                "stderr.recovery",
            },
        )
        stable = {}
        for name in (
            "state.lock",
            "supervisor.lease",
            "group.lease",
            "stdout.recovery",
            "stderr.recovery",
        ):
            path = command_root / name
            stable[name] = (path.stat().st_dev, path.stat().st_ino)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            ),
            state,
        )
        self.assertEqual(
            {
                name: (
                    (command_root / name).stat().st_dev,
                    (command_root / name).stat().st_ino,
                )
                for name in stable
            },
            stable,
        )
        self.assertEqual(
            state["supervisor"]["leaseIdentity"],
            f"{(command_root / 'supervisor.lease').stat().st_dev}:"
            f"{(command_root / 'supervisor.lease').stat().st_ino}",
        )
        self.assertEqual(
            state["anchorReservation"]["groupLeaseIdentity"],
            f"{(command_root / 'group.lease').stat().st_dev}:"
            f"{(command_root / 'group.lease').stat().st_ino}",
        )

    def test_rooted_transition_requires_live_command_lease_and_current_pid(self):
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        group_identity = prepared["anchorReservation"]["groupLeaseIdentity"]
        anchor_pid = os.getpid() + 1000
        anchored = valid_command_state(
            "anchored",
            supervisor=copy.deepcopy(prepared["supervisor"]),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
            anchor=valid_anchor(
                pid=anchor_pid,
                sid=anchor_pid,
                pgid=anchor_pid,
                groupLeaseIdentity=group_identity,
            ),
        )

        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.transition_command_state(
                self.attempt_root, SESSION_ID, 1, anchored
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        wrong_pid = copy.deepcopy(prepared)
        wrong_pid["supervisor"] = valid_supervisor(
            pid=os.getpid() + 100000,
            birthIdentity="linux:boot-id:replacement",
            leaseIdentity=lease.identity,
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(
                prepared["supervisor"]
            ),
        )
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                wrong_pid,
                supervisor_lease=lease,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        alternate_id = "b" * 32
        wrong_bound = command_state.reserve_command_layout(
            self.attempt_root,
            SESSION_ID,
            1,
            alternate_id,
        )
        self.addCleanup(wrong_bound.close)
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                anchored,
                supervisor_lease=wrong_bound,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        self.assertEqual(
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                anchored,
                supervisor_lease=lease,
            ),
            anchored,
        )
        lease.close()
        child_pid = anchor_pid + 1
        running = valid_command_state(
            "running",
            supervisor=copy.deepcopy(anchored["supervisor"]),
            anchorReservation=copy.deepcopy(anchored["anchorReservation"]),
            anchor=copy.deepcopy(anchored["anchor"]),
            child=valid_child(pid=child_pid),
        )
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                running,
                supervisor_lease=lease,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_rooted_reads_cross_bind_persisted_state_to_stable_inodes(self):
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        state_path = (
            self.attempt_root
            / ".evidence-control"
            / "commands"
            / COMMAND_ID
            / "state.json"
        )
        wrong_supervisor = copy.deepcopy(prepared)
        wrong_supervisor["supervisor"]["leaseIdentity"] = "1:999"
        state_path.write_bytes(command_state.encode_command_state(wrong_supervisor))
        with self.assertRaisesRegex(ValueError, "supervisor lease binding"):
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )

        state_path.write_bytes(command_state.encode_command_state(prepared))
        anchor_pid = os.getpid() + 1000
        anchored = valid_command_state(
            "anchored",
            supervisor=copy.deepcopy(prepared["supervisor"]),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
            anchor=valid_anchor(
                pid=anchor_pid,
                sid=anchor_pid,
                pgid=anchor_pid,
                groupLeaseIdentity=prepared["anchorReservation"][
                    "groupLeaseIdentity"
                ],
            ),
        )
        command_state.transition_command_state(
            self.attempt_root,
            SESSION_ID,
            1,
            anchored,
            supervisor_lease=lease,
        )
        wrong_group = copy.deepcopy(anchored)
        wrong_group["anchorReservation"]["groupLeaseIdentity"] = "1:999"
        wrong_group["anchor"]["groupLeaseIdentity"] = "1:999"
        state_path.write_bytes(command_state.encode_command_state(wrong_group))
        with self.assertRaisesRegex(ValueError, "group lease binding"):
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )

    def test_rooted_kill_authorization_is_durable_before_escalation(self):
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        anchor_pid = os.getpid() + 1000
        anchored = valid_command_state(
            "anchored",
            supervisor=copy.deepcopy(prepared["supervisor"]),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
            anchor=valid_anchor(
                pid=anchor_pid,
                sid=anchor_pid,
                pgid=anchor_pid,
                groupLeaseIdentity=prepared["anchorReservation"][
                    "groupLeaseIdentity"
                ],
            ),
        )
        command_state.transition_command_state(
            self.attempt_root,
            SESSION_ID,
            1,
            anchored,
            supervisor_lease=lease,
        )
        stopped = valid_command_state(
            "anchor_stop_requested",
            supervisor=copy.deepcopy(anchored["supervisor"]),
            anchorReservation=copy.deepcopy(anchored["anchorReservation"]),
            anchor=copy.deepcopy(anchored["anchor"]),
        )
        command_state.transition_command_state(
            self.attempt_root,
            SESSION_ID,
            1,
            stopped,
            supervisor_lease=lease,
        )
        authorized = copy.deepcopy(stopped)
        authorized["stopIntent"]["killAuthorizedAt"] = (
            "2026-07-11T00:00:02.750Z"
        )
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                authorized,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)
        self.assertEqual(
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                authorized,
                supervisor_lease=lease,
            ),
            authorized,
        )
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )["stopIntent"]["killAuthorizedAt"],
            "2026-07-11T00:00:02.750Z",
        )

    def test_initial_command_creation_requires_launch_supervisor(self):
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        launch = prepared["supervisor"]
        recovery = valid_supervisor(
            pid=os.getpid(),
            birthIdentity="linux:boot-id:200",
            leaseIdentity=lease.identity,
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(launch),
        )
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.create_command_state(
                self.attempt_root,
                prepared | {"supervisor": recovery},
                supervisor_lease=lease,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_prepared_commit_requires_live_rebound_supervisor_lease(self):
        self.initialize()
        lease, state = self.reserve_prepared_state()
        wrong_pid = copy.deepcopy(state)
        wrong_pid["supervisor"]["pid"] = os.getpid() + 100000
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.create_command_state(
                self.attempt_root, wrong_pid, supervisor_lease=lease
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        wrong_group = copy.deepcopy(state)
        wrong_group["anchorReservation"]["groupLeaseIdentity"] = "1:999"
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.create_command_state(
                self.attempt_root, wrong_group, supervisor_lease=lease
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        lease.close()
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.create_command_state(
                self.attempt_root, state, supervisor_lease=lease
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_session_transition_is_atomic_and_preserves_old_sibling_on_failure(self):
        self.initialize()
        path = self.attempt_root / ".evidence-control" / "session.json"
        before = path.read_bytes()

        def fail_before_replace(operation, phase, candidate):
            if (
                operation == "atomic_write"
                and phase == "before_replace"
                and candidate.name == "session.json"
            ):
                raise RuntimeError("injected")

        with mock.patch.object(
            command_state.safe_io,
            "_rooted_io_checkpoint",
            side_effect=fail_before_replace,
        ):
            with self.assertRaisesRegex(RuntimeError, "injected"):
                command_state.transition_session_state(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    "finalizing",
                )
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(
            list(path.parent.glob(".session.json.*.tmp")),
            [],
        )

        updated = command_state.transition_session_state(
            self.attempt_root, SESSION_ID, 1, "finalizing"
        )
        self.assertEqual(updated["state"], "finalizing")
        with self.assertRaises(ValueError):
            command_state.transition_session_state(
                self.attempt_root, SESSION_ID, 1, "active"
            )

    def test_corrupt_oversized_or_mismatched_state_blocks_mutation(self):
        self.initialize()
        lease, state = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, state, supervisor_lease=lease
        )
        state_path = (
            self.attempt_root
            / ".evidence-control"
            / "commands"
            / COMMAND_ID
            / "state.json"
        )
        corrupt = copy.deepcopy(state)
        corrupt["unknown"] = True
        state_path.write_text(json.dumps(corrupt), encoding="utf-8")
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                valid_command_state("running"),
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        session_path = self.attempt_root / ".evidence-control" / "session.json"
        session_path.write_bytes(b"{" + b" " * command_state.MAX_SESSION_STATE_BYTES + b"}")
        before = self.snapshot(self.attempt_root)
        with self.assertRaisesRegex(ValueError, "exceeds"):
            command_state.record_terminal_diagnostic(
                self.attempt_root,
                SESSION_ID,
                1,
                failed_diagnostic(),
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_mismatched_session_and_symlinked_command_reject_without_mutation(self):
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        mismatched = copy.deepcopy(prepared)
        mismatched.update(
            sessionId="a" * 32,
        )
        mismatched["requestFingerprint"] = raw_request_fingerprint(
            mismatched["sessionId"],
            mismatched["creationGeneration"],
            mismatched["request"],
            mismatched["paths"],
        )
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.create_command_state(
                self.attempt_root, mismatched, supervisor_lease=lease
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        outside = self.publication_root / "outside-command"
        outside.mkdir()
        marker = outside / "marker"
        marker.write_text("untouched", encoding="utf-8")
        alternate_id = "b" * 32
        command_link = self.attempt_root / ".evidence-control" / "commands" / alternate_id
        command_link.symlink_to(outside, target_is_directory=True)
        before = self.snapshot(self.publication_root)
        with self.assertRaises(ValueError):
            command_state.reserve_command_layout(
                self.attempt_root,
                SESSION_ID,
                1,
                alternate_id,
            )
        self.assertEqual(self.snapshot(self.publication_root), before)
        self.assertEqual(marker.read_text(encoding="utf-8"), "untouched")

    def test_duplicate_key_and_oversized_documents_are_rejected_on_bounded_read(self):
        self.initialize()
        lease, state = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, state, supervisor_lease=lease
        )
        control = self.attempt_root / ".evidence-control"
        state_path = control / "commands" / COMMAND_ID / "state.json"
        documents = (
            (control / "session.json", command_state.read_session),
            (control / "terminal-intent.json", command_state.read_terminal_intent),
            (
                state_path,
                lambda root: command_state.read_command_state(
                    root, COMMAND_ID, SESSION_ID
                ),
            ),
        )
        limits = (
            command_state.MAX_SESSION_STATE_BYTES,
            command_state.MAX_TERMINAL_INTENT_BYTES,
            command_state.MAX_COMMAND_STATE_BYTES,
        )
        originals = {path: path.read_bytes() for path, _reader in documents}
        for path, reader in documents:
            path.write_bytes(b'{"schemaVersion":1,"schemaVersion":1}')
            before = self.snapshot(self.attempt_root)
            with self.subTest(path=path.name, kind="duplicate"):
                with self.assertRaisesRegex(ValueError, "duplicate object key"):
                    reader(self.attempt_root)
                self.assertEqual(self.snapshot(self.attempt_root), before)
            path.write_bytes(originals[path])
        for (path, reader), limit in zip(documents, limits):
            path.write_bytes(b"{" + b" " * limit + b"}")
            before = self.snapshot(self.attempt_root)
            with self.subTest(path=path.name, kind="oversized"):
                with self.assertRaisesRegex(ValueError, "exceeds"):
                    reader(self.attempt_root)
                self.assertEqual(self.snapshot(self.attempt_root), before)
            path.write_bytes(originals[path])

    def test_symlink_substitution_of_commands_and_stable_files_is_fail_closed(self):
        self.initialize()
        lease, state = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, state, supervisor_lease=lease
        )
        control = self.attempt_root / ".evidence-control"
        outside = self.publication_root / "outside-private"
        outside.mkdir()
        marker = outside / "marker"
        marker.write_text("untouched", encoding="utf-8")

        commands = control / "commands"
        moved_commands = control / "commands-real"
        commands.rename(moved_commands)
        commands.symlink_to(outside, target_is_directory=True)
        before = self.snapshot(self.publication_root)
        with self.assertRaises(ValueError):
            command_state.read_session(self.attempt_root)
        self.assertEqual(self.snapshot(self.publication_root), before)
        commands.unlink()
        moved_commands.rename(commands)

        command_root = commands / COMMAND_ID
        for name in ("state.lock", "supervisor.lease", "group.lease"):
            with self.subTest(name=name):
                stable = command_root / name
                moved = command_root / f"{name}.real"
                stable.rename(moved)
                stable.symlink_to(marker)
                before = self.snapshot(self.publication_root)
                with self.assertRaises(ValueError):
                    command_state.read_command_state(
                        self.attempt_root, COMMAND_ID, SESSION_ID
                    )
                self.assertEqual(self.snapshot(self.publication_root), before)
                stable.unlink()
                moved.rename(stable)

    def test_partial_initialization_and_command_creation_resume_safely(self):
        original_checkpoint = command_state.safe_io._rooted_io_checkpoint

        def fail_session_replace(operation, phase, path):
            if (
                operation == "atomic_write"
                and phase == "before_replace"
                and path.name == "session.json"
            ):
                raise RuntimeError("injected session seam")
            return original_checkpoint(operation, phase, path)

        with mock.patch.object(
            command_state.safe_io,
            "_rooted_io_checkpoint",
            side_effect=fail_session_replace,
        ):
            with self.assertRaisesRegex(RuntimeError, "session seam"):
                self.initialize()
        control = self.attempt_root / ".evidence-control"
        self.assertTrue((control / "terminal-intent.json").is_file())
        self.assertFalse((control / "session.json").exists())
        self.assertEqual(self.initialize(), valid_session())

        lease, state = self.reserve_prepared_state()

        def fail_state_replace(operation, phase, path):
            if (
                operation == "atomic_write"
                and phase == "before_replace"
                and path.name == "state.json"
            ):
                raise RuntimeError("injected state seam")
            return original_checkpoint(operation, phase, path)

        with mock.patch.object(
            command_state.safe_io,
            "_rooted_io_checkpoint",
            side_effect=fail_state_replace,
        ):
            with self.assertRaisesRegex(RuntimeError, "state seam"):
                command_state.create_command_state(
                    self.attempt_root, state, supervisor_lease=lease
                )
        command_root = control / "commands" / COMMAND_ID
        self.assertTrue(command_root.is_dir())
        self.assertFalse((command_root / "state.json").exists())
        self.assertEqual(
            command_state.create_command_state(
                self.attempt_root, state, supervisor_lease=lease
            ),
            state,
        )
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            ),
            state,
        )


class TerminalIntentTests(CommandStateTestCase):
    def test_empty_terminal_intent_is_initial_state_only(self):
        initial = command_state.make_terminal_intent(SESSION_ID)
        self.assertEqual(command_state.validate_terminal_intent(initial), initial)
        for next_ordinal, dropped_count in ((2, 1), (10, 9)):
            forged = copy.deepcopy(initial)
            forged["nextOrdinal"] = next_ordinal
            forged["droppedCount"] = dropped_count
            with self.assertRaises(ValueError):
                command_state.validate_terminal_intent(forged)

    def test_worst_case_retained_diagnostics_fit_terminal_intent_cap(self):
        intent = command_state.make_terminal_intent(SESSION_ID)
        for index in range(9):
            suffix = f"{index:02d}"
            diagnostic = failed_diagnostic(index) | {
                "summary": '"\\' * 255 + suffix,
                "hint": '\\"' * 255 + suffix,
                "source": '"\\' * 127 + suffix,
            }
            intent, changed = command_state._record_diagnostic_candidate(
                intent,
                diagnostic,
                1,
                "2026-07-11T00:00:04Z",
            )
            self.assertTrue(changed)
        encoded = command_state.encode_terminal_intent(intent)
        self.assertLessEqual(
            len(encoded), command_state.MAX_TERMINAL_INTENT_BYTES
        )
        for field in ("summary", "hint"):
            for value in ("x" * 513, "unsafe\x00text", "unsafe\x7ftext", "\ud800"):
                with self.subTest(field=field, value=repr(value)):
                    with self.assertRaises(ValueError):
                        command_state.validate_caller_diagnostic(
                            failed_diagnostic() | {field: value}
                        )

    def test_server_owned_resolution_tiers_choose_same_primary_for_permutations(self):
        diagnostics = (
            failed_diagnostic(1, classification="app_failure"),
            failed_diagnostic(2, classification="runner_failure"),
            failed_diagnostic(3, classification="runner_failure")
            | {"errorCode": "runner.cleanup_failed"},
            failed_diagnostic(4, classification="runner_failure")
            | {"errorCode": "runner.evidence_invalid"},
        )
        for permutation in itertools.permutations(diagnostics):
            intent = command_state.make_terminal_intent(SESSION_ID)
            for diagnostic in permutation:
                intent, changed = command_state._record_diagnostic_candidate(
                    intent,
                    diagnostic,
                    1,
                    "2026-07-11T00:00:04Z",
                )
                self.assertTrue(changed)
            self.assertEqual(
                intent["primary"]["errorCode"],
                "runner.evidence_invalid",
            )
            self.assertEqual(
                intent["secondary"][0]["errorCode"],
                "runner.cleanup_failed",
            )

    def test_persisted_counter_and_generation_invariants_are_exact(self):
        self.initialize()
        intent = command_state.record_terminal_diagnostic(
            self.attempt_root, SESSION_ID, 1, failed_diagnostic(1)
        )
        for field, value in (
            ("droppedCount", 1),
            ("nextOrdinal", 3),
        ):
            changed = copy.deepcopy(intent)
            changed[field] = value
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    command_state.validate_terminal_intent(changed)

        changed = copy.deepcopy(intent)
        changed["primary"]["recordedGeneration"] = 2
        path = self.attempt_root / ".evidence-control" / "terminal-intent.json"
        path.write_bytes(command_state.encode_terminal_intent(changed))
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.record_terminal_diagnostic(
                self.attempt_root, SESSION_ID, 1, failed_diagnostic(2)
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_terminal_intent_rejects_caller_server_fields_and_invalid_pass(self):
        self.initialize()
        diagnostic = failed_diagnostic()
        for field, value in (
            ("recordedAt", STARTED_AT),
            ("ordinal", 1),
            ("recordedGeneration", 1),
            ("unknown", True),
        ):
            with self.subTest(field=field):
                invalid = diagnostic | {field: value}
                before = self.snapshot(self.attempt_root)
                with self.assertRaises(ValueError):
                    command_state.record_terminal_diagnostic(
                        self.attempt_root, SESSION_ID, 1, invalid
                    )
                self.assertEqual(self.snapshot(self.attempt_root), before)

        passed = {
            "status": "passed",
            "classification": "passed",
            "phase": "complete",
            "commandStatus": 0,
            "source": "owner-exit",
        }
        with mock.patch.object(
            command_state, "_utc_now", return_value="2026-07-11T00:00:04Z"
        ):
            intent = command_state.record_terminal_diagnostic(
                self.attempt_root, SESSION_ID, 1, passed
            )
        self.assertNotIn("errorCode", intent["primary"])
        self.assertNotIn("summary", intent["primary"])
        self.assertNotIn("hint", intent["primary"])

        invalid_pass = passed | {"errorCode": "runner.unclassified"}
        with self.assertRaises(ValueError):
            command_state.record_terminal_diagnostic(
                self.attempt_root, SESSION_ID, 1, invalid_pass
            )

    def test_dedupe_allocates_nothing_for_retained_semantic_key(self):
        self.initialize()
        diagnostic = failed_diagnostic()
        with mock.patch.object(
            command_state, "_utc_now", return_value="2026-07-11T00:00:04Z"
        ):
            first = command_state.record_terminal_diagnostic(
                self.attempt_root, SESSION_ID, 1, diagnostic
            )
        path = self.attempt_root / ".evidence-control" / "terminal-intent.json"
        before_content = path.read_bytes()
        before_identity = (path.stat().st_dev, path.stat().st_ino)
        with mock.patch.object(
            command_state, "_utc_now", return_value="2026-07-11T00:00:05Z"
        ):
            duplicate = command_state.record_terminal_diagnostic(
                self.attempt_root, SESSION_ID, 1, diagnostic
            )
        self.assertEqual(duplicate, first)
        self.assertEqual(duplicate["nextOrdinal"], 2)
        self.assertEqual(duplicate["droppedCount"], 0)
        self.assertEqual(path.read_bytes(), before_content)
        self.assertEqual((path.stat().st_dev, path.stat().st_ino), before_identity)

    def test_retained_set_precedence_eviction_and_drop_semantics(self):
        self.initialize()
        for index in range(9):
            command_state.record_terminal_diagnostic(
                self.attempt_root,
                SESSION_ID,
                1,
                failed_diagnostic(index),
            )
        intent = command_state.record_terminal_diagnostic(
            self.attempt_root,
            SESSION_ID,
            1,
            failed_diagnostic(9),
        )
        self.assertEqual(intent["nextOrdinal"], 11)
        self.assertEqual(intent["droppedCount"], 1)
        self.assertEqual(
            [item["ordinal"] for item in [intent["primary"], *intent["secondary"]]],
            list(range(1, 10)),
        )

        before = copy.deepcopy(intent)
        duplicate = command_state.record_terminal_diagnostic(
            self.attempt_root,
            SESSION_ID,
            1,
            failed_diagnostic(0),
        )
        self.assertEqual(duplicate, before)

        stronger = command_state.record_terminal_diagnostic(
            self.attempt_root,
            SESSION_ID,
            1,
            failed_diagnostic(20, classification="runner_failure")
            | {"errorCode": "runner.evidence_invalid"},
        )
        retained = [stronger["primary"], *stronger["secondary"]]
        self.assertEqual(stronger["primary"]["classification"], "runner_failure")
        self.assertEqual(stronger["primary"]["ordinal"], 11)
        self.assertEqual([item["ordinal"] for item in retained[1:]], list(range(1, 9)))
        self.assertEqual(stronger["droppedCount"], 2)
        self.assertEqual(stronger["nextOrdinal"], 12)

        redelivered = command_state.record_terminal_diagnostic(
            self.attempt_root,
            SESSION_ID,
            1,
            failed_diagnostic(8),
        )
        self.assertEqual(redelivered["nextOrdinal"], 13)
        self.assertEqual(redelivered["droppedCount"], 3)
        self.assertNotIn(
            12,
            [
                item["ordinal"]
                for item in [redelivered["primary"], *redelivered["secondary"]]
            ],
        )

    def test_terminal_intent_session_generation_and_corruption_fail_without_write(self):
        self.initialize()
        path = self.attempt_root / ".evidence-control" / "terminal-intent.json"
        for session_id, generation in (("a" * 32, 1), (SESSION_ID, 2)):
            before = self.snapshot(self.attempt_root)
            with self.assertRaises(ValueError):
                command_state.record_terminal_diagnostic(
                    self.attempt_root,
                    session_id,
                    generation,
                    failed_diagnostic(),
                )
            self.assertEqual(self.snapshot(self.attempt_root), before)

        corrupt = command_state.make_terminal_intent(SESSION_ID)
        corrupt["unknown"] = True
        path.write_text(json.dumps(corrupt), encoding="utf-8")
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            command_state.record_terminal_diagnostic(
                self.attempt_root, SESSION_ID, 1, failed_diagnostic()
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_concurrent_delivery_serializes_under_stable_commands_lock(self):
        self.initialize()
        failures = []

        def record(index):
            try:
                command_state.record_terminal_diagnostic(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    failed_diagnostic(index),
                )
            except BaseException as exc:  # pragma: no cover - asserted below
                failures.append(exc)

        threads = [threading.Thread(target=record, args=(index,)) for index in range(20)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(failures, [])
        intent = command_state.read_terminal_intent(self.attempt_root)
        retained = [intent["primary"], *intent["secondary"]]
        self.assertEqual(intent["nextOrdinal"], 21)
        self.assertEqual(intent["droppedCount"], 11)
        self.assertEqual(len(retained), 9)
        self.assertEqual(len({item["ordinal"] for item in retained}), 9)
        self.assertEqual(
            [item["ordinal"] for item in retained],
            sorted(item["ordinal"] for item in retained),
        )

    def test_takeover_generation_stamps_new_diagnostics_without_rewriting_old(self):
        self.initialize()
        first = command_state.record_terminal_diagnostic(
            self.attempt_root, SESSION_ID, 1, failed_diagnostic(1)
        )
        self.assertEqual(first["primary"]["recordedGeneration"], 1)

        session_path = self.attempt_root / ".evidence-control" / "session.json"
        taken_over = valid_session(
            ownerPid=2234,
            ownerBirthIdentity="linux:boot-id:200",
            generation=2,
        )
        session_path.write_bytes(command_state.encode_session(taken_over))
        second = command_state.record_terminal_diagnostic(
            self.attempt_root, SESSION_ID, 2, failed_diagnostic(2)
        )
        retained = [second["primary"], *second["secondary"]]
        self.assertEqual(
            [item["recordedGeneration"] for item in retained],
            [1, 2],
        )
        with self.assertRaises(ValueError):
            command_state.record_terminal_diagnostic(
                self.attempt_root, SESSION_ID, 1, failed_diagnostic(3)
            )


if __name__ == "__main__":
    unittest.main()
