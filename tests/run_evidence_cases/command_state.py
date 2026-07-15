"""Strict private command-state contracts and rooted persistence tests."""

from __future__ import annotations

import copy
import contextlib
import fcntl
import hashlib
import itertools
import json
import os
import stat
import sys
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


def valid_terminal_event(paths=None, **patch):
    paths = valid_paths() if paths is None else paths
    value = {
        "schemaVersion": 1,
        "seq": 4,
        "timestamp": "2026-07-11T00:00:03.100Z",
        "phase": "scenario.execute",
        "status": "passed",
        "command": paths["metadata"],
        "commandStatus": 0,
        "artifact": paths["metadata"],
    }
    value.update(patch)
    return value


def valid_materialized(paths=None, *, terminal_event=None, **patch):
    paths = valid_paths() if paths is None else paths
    event = (
        valid_terminal_event(paths)
        if terminal_event is None
        else copy.deepcopy(terminal_event)
    )
    event_line = (
        json.dumps(
            event,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")

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
            "seq": event["seq"],
            "bytes": len(event_line),
            "sha256": "sha256:" + hashlib.sha256(event_line).hexdigest(),
            "event": event,
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
        terminal_event = valid_terminal_event(
            state["paths"],
            status="failed",
            errorCode=state["request"]["failureCode"],
            summary="Command execution failed before acknowledgement",
            commandStatus=127,
        )
        state["materialized"] = valid_materialized(
            state["paths"], terminal_event=terminal_event
        )
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
        summary = (
            "Command capture failed"
            if error_code == "runner.capture_failed"
            else "Command supervision failed"
        )
        terminal_event = valid_terminal_event(
            state["paths"],
            status="failed",
            errorCode=error_code,
            summary=summary,
        )
        terminal_event.pop("commandStatus")
        state["materialized"] = valid_materialized(
            state["paths"], terminal_event=terminal_event
        )
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
        if kind == "expected":
            terminal_event = valid_terminal_event(state["paths"])
        else:
            terminal_event = valid_terminal_event(
                state["paths"],
                status="cancelled",
                errorCode="run.cancelled",
                summary="Command stopped before execution acknowledgement",
            )
            terminal_event.pop("commandStatus")
        state["materialized"] = valid_materialized(
            state["paths"], terminal_event=terminal_event
        )
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
    def test_command_request_rejects_cancellation_class_failure_codes(self):
        for error_code, classification in command_state.ERROR_CLASSIFICATION.items():
            if classification != "cancelled":
                continue
            with self.subTest(error_code=error_code), self.assertRaisesRegex(
                ValueError, "cancellation"
            ):
                valid_command_state(
                    request=valid_request(failureCode=error_code)
                )

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

    def test_post_exit_recovery_preserves_historical_outcome_and_capture(self):
        launch = valid_supervisor()
        recovery = valid_supervisor(
            pid=2234,
            birthIdentity="linux:boot-id:200",
            leaseIdentity=launch["leaseIdentity"],
            role="recovery",
            predecessor=command_state.supervisor_fingerprint(launch),
        )
        historical = (
            valid_command_state("exited", supervisor=recovery),
            negative_exec_state() | {"supervisor": recovery},
            stopped_before_ack_state() | {"supervisor": recovery},
            valid_command_state("materialized", supervisor=recovery),
            valid_command_state("committed", supervisor=recovery),
        )
        for recovered in historical:
            with self.subTest(
                stage=recovered["stage"], kind=recovered["outcome"]["kind"]
            ):
                expected_outcome = copy.deepcopy(recovered["outcome"])
                expected_capture = copy.deepcopy(recovered["capture"])
                self.assertEqual(
                    command_state.validate_command_state(recovered), recovered
                )
                self.assertEqual(recovered["outcome"], expected_outcome)
                self.assertEqual(recovered["capture"], expected_capture)

    def test_frozen_terminal_event_is_exact_canonical_and_hash_bound(self):
        state = valid_command_state("materialized")
        binding = state["materialized"]["terminalEvent"]
        event = binding["event"]
        canonical = (
            json.dumps(
                event,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")
        self.assertEqual(binding["seq"], event["seq"])
        self.assertGreater(binding["seq"], state["startedEvent"]["seq"])
        self.assertEqual(binding["bytes"], len(canonical))
        self.assertEqual(
            binding["sha256"],
            "sha256:" + hashlib.sha256(canonical).hexdigest(),
        )
        self.assertEqual(command_state.validate_command_state(state), state)
        for historical in (
            negative_exec_state("materialized"),
            supervisor_failure_state(final_stage="materialized"),
            stopped_before_ack_state("materialized"),
        ):
            with self.subTest(valid_kind=historical["outcome"]["kind"]):
                self.assertEqual(
                    command_state.validate_command_state(historical), historical
                )

        def rebound(mutator):
            candidate = copy.deepcopy(state)
            candidate_event = candidate["materialized"]["terminalEvent"][
                "event"
            ]
            mutator(candidate_event)
            line = (
                json.dumps(
                    candidate_event,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=False,
                    allow_nan=False,
                )
                + "\n"
            ).encode("utf-8")
            candidate_binding = candidate["materialized"]["terminalEvent"]
            candidate_binding["seq"] = candidate_event.get("seq", 4)
            candidate_binding["bytes"] = len(line)
            candidate_binding["sha256"] = (
                "sha256:" + hashlib.sha256(line).hexdigest()
            )
            return candidate

        semantic_tampering = {
            "unknown-key": lambda value: value.__setitem__("extra", True),
            "not-after-started": lambda value: value.__setitem__("seq", 3),
            "request-phase": lambda value: value.__setitem__("phase", "cleanup"),
            "metadata-command": lambda value: value.__setitem__(
                "command", "commands/other.json"
            ),
            "metadata-artifact": lambda value: value.__setitem__(
                "artifact", "commands/other.json"
            ),
            "timestamp": lambda value: value.__setitem__("timestamp", "soon"),
            "terminal-status": lambda value: value.__setitem__(
                "status", "started"
            ),
            "error-code": lambda value: value.__setitem__(
                "errorCode", "unknown.failure"
            ),
            "command-status": lambda value: value.__setitem__(
                "commandStatus", 1 << 80
            ),
            "summary-bound": lambda value: value.update(
                status="failed",
                errorCode="runner.command_supervisor_lost",
                summary="x" * 4097,
            ),
            "launch-exit-cannot-freeze-supervisor-loss": lambda value: value.update(
                status="failed",
                errorCode="runner.command_supervisor_lost",
                summary="Supervisor disappeared",
                commandStatus=125,
            ),
            "passed-status-must-be-zero": lambda value: value.update(
                status="passed", commandStatus=1
            ),
            "terminal-time-must-follow-outcome": lambda value: value.update(
                timestamp="2026-07-10T23:59:59Z"
            ),
        }
        for label, mutate in semantic_tampering.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                command_state.validate_command_state(rebound(mutate))

        for field, replacement in (
            ("seq", binding["seq"] + 1),
            ("bytes", binding["bytes"] + 1),
            ("sha256", "sha256:" + "0" * 64),
        ):
            tampered = copy.deepcopy(state)
            tampered["materialized"]["terminalEvent"][field] = replacement
            with self.subTest(binding=field), self.assertRaises(ValueError):
                command_state.validate_command_state(tampered)

        one_byte = copy.deepcopy(state)
        one_byte["materialized"]["terminalEvent"]["event"]["commandStatus"] = 1
        with self.assertRaises(ValueError):
            command_state.validate_command_state(one_byte)

        supervisor_failure = supervisor_failure_state(
            final_stage="materialized"
        )
        failure_binding = supervisor_failure["materialized"]["terminalEvent"]
        failure_binding["event"]["commandStatus"] = 125
        failure_line = (
            json.dumps(
                failure_binding["event"],
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")
        failure_binding["bytes"] = len(failure_line)
        failure_binding["sha256"] = (
            "sha256:" + hashlib.sha256(failure_line).hexdigest()
        )
        with self.assertRaises(ValueError):
            command_state.validate_command_state(supervisor_failure)

    def test_frozen_terminal_event_semantics_are_exact_for_every_outcome_family(self):
        def bind(state, event):
            candidate = copy.deepcopy(state)
            candidate["stage"] = "materialized"
            candidate["materialized"] = valid_materialized(
                candidate["paths"], terminal_event=event
            )
            for stream_name in ("stdout", "stderr"):
                candidate["materialized"][stream_name]["bytes"] = candidate[
                    "capture"
                ][stream_name]["storedBytes"]
            return candidate

        nonzero = valid_command_state("exited")
        nonzero["outcome"] = valid_outcome(
            exitStatus=7,
            shellVisibleStatus=7,
        )
        nonzero = bind(
            nonzero,
            valid_terminal_event(
                nonzero["paths"],
                status="failed",
                errorCode=nonzero["request"]["failureCode"],
                summary="Command exited with status 7",
                commandStatus=7,
            ),
        )

        signalled = valid_command_state("exited")
        signalled["outcome"] = valid_outcome(
            kind="signal",
            exitStatus=None,
            signal=15,
            shellVisibleStatus=143,
        )
        signal_event = valid_terminal_event(
            signalled["paths"],
            status="failed",
            errorCode=signalled["request"]["failureCode"],
            summary="Command terminated by signal 15",
        )
        signal_event.pop("commandStatus")
        signalled = bind(signalled, signal_event)

        expected_stop = stopped_before_ack_state(
            "materialized", kind="expected"
        )
        cancel_stop = stopped_before_ack_state(
            "materialized", kind="cancel"
        )

        escalated_cleanup = stopped_before_ack_state("exited", kind="cancel")
        escalated_cleanup["stopIntent"]["killAuthorizedAt"] = (
            "2026-07-11T00:00:02.750Z"
        )
        escalated_cleanup["outcome"].update(
            graceExpired=True,
            escalated=True,
            shellVisibleStatus=125,
        )
        cleanup_event = valid_terminal_event(
            escalated_cleanup["paths"],
            status="failed",
            errorCode="runner.cleanup_failed",
            summary="Command cleanup required forced termination",
        )
        cleanup_event.pop("commandStatus")
        escalated_cleanup = bind(escalated_cleanup, cleanup_event)

        def stopped_child(
            *,
            kind,
            outcome,
            event_status,
            error_code=None,
            summary=None,
            command_status=None,
            escalated=False,
        ):
            request = valid_request(
                stopPolicy="expected-term" if kind == "expected" else "none"
            )
            state = valid_command_state("exited", request=request)
            state["stopIntent"] = {
                "kind": kind,
                "requestedAt": "2026-07-11T00:00:02.500Z",
                "killAuthorizedAt": (
                    "2026-07-11T00:00:02.750Z" if escalated else None
                ),
            }
            state["outcome"] = outcome
            event = valid_terminal_event(
                state["paths"],
                status=event_status,
            )
            if error_code is not None:
                event["errorCode"] = error_code
            if summary is not None:
                event["summary"] = summary
            if command_status is None:
                event.pop("commandStatus")
            else:
                event["commandStatus"] = command_status
            return bind(state, event)

        expected_child_stop = stopped_child(
            kind="expected",
            outcome=valid_outcome(
                exitStatus=143,
                shellVisibleStatus=0,
            ),
            event_status="passed",
            command_status=0,
        )
        cancel_child_stop = stopped_child(
            kind="cancel",
            outcome=valid_outcome(
                exitStatus=0,
                shellVisibleStatus=130,
            ),
            event_status="cancelled",
            error_code="run.cancelled",
            summary="Command cancelled after execution acknowledgement",
        )
        escalated_child_cleanup = stopped_child(
            kind="cancel",
            outcome=valid_outcome(
                kind="signal",
                exitStatus=None,
                signal=9,
                shellVisibleStatus=125,
            ),
            event_status="failed",
            error_code="runner.cleanup_failed",
            summary="Command cleanup required forced termination",
            escalated=True,
        )

        cases = {
            "normal-nonzero-exit": (nonzero, 7),
            "unexpected-signal": (signalled, None),
            "expected-stop-before-ack": (expected_stop, 0),
            "cancel-stop-before-ack": (cancel_stop, None),
            "escalated-cleanup-before-ack": (escalated_cleanup, None),
            "expected-stop-after-ack": (expected_child_stop, 0),
            "cancel-stop-after-ack": (cancel_child_stop, None),
            "escalated-cleanup-after-ack": (
                escalated_child_cleanup,
                None,
            ),
            "exec-failure": (negative_exec_state("materialized"), 127),
            "capture-failure": (
                supervisor_failure_state(
                    error_code="runner.capture_failed",
                    final_stage="materialized",
                ),
                None,
            ),
            "supervisor-loss": (
                supervisor_failure_state(final_stage="materialized"),
                None,
            ),
        }

        for label, (state, expected_command_status) in cases.items():
            with self.subTest(case=label, variant="exact"):
                self.assertEqual(
                    command_state.validate_command_state(state), state
                )

            exact_event = state["materialized"]["terminalEvent"]["event"]
            self.assertEqual(
                "commandStatus" in exact_event,
                expected_command_status is not None,
            )
            self.assertEqual(
                exact_event.get("commandStatus"), expected_command_status
            )
            for field in ("status", "errorCode", "summary", "commandStatus"):
                candidate = copy.deepcopy(state)
                event = candidate["materialized"]["terminalEvent"]["event"]
                if field == "status":
                    event["status"] = {
                        "passed": "failed",
                        "failed": "cancelled",
                        "cancelled": "failed",
                    }[exact_event["status"]]
                    if exact_event["status"] == "passed":
                        event["errorCode"] = state["request"]["failureCode"]
                        event["summary"] = "Command unexpectedly failed"
                elif field == "errorCode":
                    event["errorCode"] = (
                        "runner.unclassified"
                        if exact_event.get("errorCode")
                        == "runner.evidence_invalid"
                        else "runner.evidence_invalid"
                    )
                elif field == "summary":
                    event["summary"] = (
                        exact_event.get("summary", "") + " altered"
                    )
                else:
                    event["commandStatus"] = (
                        exact_event.get("commandStatus", 124) + 1
                    )
                candidate = bind(candidate, event)
                with self.subTest(
                    case=label, mutation=field
                ), self.assertRaises(ValueError):
                    command_state.validate_command_state(candidate)

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

    def test_recovery_prepared_and_historical_negative_exec_are_valid(self):
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
        self.assertEqual(
            command_state.validate_command_state(negative),
            negative,
        )
        with self.assertRaises(ValueError):
            command_state.validate_command_transition(
                recovered_anchored,
                negative,
                session_id=SESSION_ID,
                generation=1,
            )

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

    def test_launch_and_close_have_exactly_one_serial_winner(self):
        for iteration in range(16):
            with self.subTest(iteration=iteration), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "attempts" / "logical-1-attempt-1"
                root.mkdir(parents=True)
                command_state.initialize_control_layout(
                    root,
                    valid_session(
                        ownerPid=os.getpid(),
                        ownerBirthIdentity="test:current-process",
                    ),
                )
                barrier = threading.Barrier(2)
                launch_outcome = []
                close_outcome = []
                leases = []

                def launch():
                    barrier.wait()
                    try:
                        lease = command_state.reserve_command_layout(
                            root, SESSION_ID, 1, COMMAND_ID
                        )
                        leases.append(lease)
                        prepared = valid_command_state(
                            "prepared",
                            supervisor=valid_supervisor(
                                pid=os.getpid(),
                                birthIdentity="test:current-process",
                                leaseIdentity=lease.identity,
                            ),
                            anchorReservation=lease.anchor_reservation,
                        )
                        command_state.create_command_state(
                            root, prepared, supervisor_lease=lease
                        )
                    except ValueError:
                        launch_outcome.append("refused")
                    else:
                        launch_outcome.append("prepared")

                def close():
                    barrier.wait()
                    close_outcome.append(
                        command_state.transition_session_state(
                            root, SESSION_ID, 1, "finalizing"
                        )["state"]
                    )

                workers = [
                    threading.Thread(target=launch),
                    threading.Thread(target=close),
                ]
                for worker in workers:
                    worker.start()
                for worker in workers:
                    worker.join(timeout=5)
                for lease in leases:
                    lease.close()

                self.assertTrue(all(not worker.is_alive() for worker in workers))
                self.assertEqual(close_outcome, ["finalizing"])
                self.assertEqual(len(launch_outcome), 1)
                state_path = (
                    root
                    / ".evidence-control"
                    / "commands"
                    / COMMAND_ID
                    / "state.json"
                )
                self.assertEqual(
                    (launch_outcome[0], state_path.exists()),
                    (
                        ("prepared", True)
                        if launch_outcome[0] == "prepared"
                        else ("refused", False)
                    ),
                )

    def test_ninth_active_command_is_rejected_without_reservation_mutation(self):
        self.initialize()
        leases = []
        for index in range(command_state.MAX_ACTIVE_COMMANDS):
            command_id = f"{index + 1:032x}"
            paths = {
                "metadata": f"commands/{command_id}.json",
                "stdout": f"commands/{command_id}.stdout.log",
                "stderr": f"commands/{command_id}.stderr.log",
            }
            lease = command_state.reserve_command_layout(
                self.attempt_root, SESSION_ID, 1, command_id
            )
            leases.append(lease)
            self.addCleanup(lease.close)
            prepared = valid_command_state(
                "prepared",
                commandId=command_id,
                paths=paths,
                supervisor=valid_supervisor(
                    pid=os.getpid(), leaseIdentity=lease.identity
                ),
                anchorReservation=lease.anchor_reservation,
            )
            command_state.create_command_state(
                self.attempt_root, prepared, supervisor_lease=lease
            )

        before = self.snapshot(self.attempt_root)
        rejected_id = f"{command_state.MAX_ACTIVE_COMMANDS + 1:032x}"
        with self.assertRaisesRegex(ValueError, "active command count"):
            command_state.reserve_command_layout(
                self.attempt_root, SESSION_ID, 1, rejected_id
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

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

    def test_atomic_terminal_intent_write_serializes_before_layout_validation(self):
        self.initialize()
        control = self.attempt_root / ".evidence-control"
        target = control / "terminal-intent.json"
        commands_lock = control / ".commands.lock"
        first_at_replace = threading.Event()
        release_first = threading.Event()
        progress_changed = threading.Condition()
        progress = {"secondGateAttempted": False, "secondDone": False}
        checkpoint_guard = threading.Lock()
        first_checkpoint_seen = False
        observed_temporaries = []
        outcomes_guard = threading.Lock()
        results = []
        failures = []
        original_checkpoint = command_state.safe_io._rooted_io_checkpoint
        original_stable_lock = command_state._stable_lock

        def blocking_checkpoint(operation, phase, path):
            nonlocal first_checkpoint_seen
            should_block = False
            if (
                operation == "atomic_write"
                and phase == "before_replace"
                and Path(path) == target
            ):
                with checkpoint_guard:
                    if not first_checkpoint_seen:
                        first_checkpoint_seen = True
                        observed_temporaries.extend(
                            sorted(control.glob(f".{target.name}.*.tmp"))
                        )
                        should_block = True
            if should_block:
                first_at_replace.set()
                if not release_first.wait(5):
                    raise TimeoutError("terminal-intent writer was not released")
            return original_checkpoint(operation, phase, path)

        @contextlib.contextmanager
        def observed_stable_lock(path, timeout=5.0):
            if (
                threading.current_thread().name == "diagnostic-second"
                and Path(path) == commands_lock
            ):
                with progress_changed:
                    progress["secondGateAttempted"] = True
                    progress_changed.notify_all()
            with original_stable_lock(path, timeout=timeout):
                yield

        def record(index):
            try:
                result = command_state.record_terminal_diagnostic(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    failed_diagnostic(index),
                )
                with outcomes_guard:
                    results.append(result)
            except BaseException as exc:  # pragma: no cover - asserted below
                with outcomes_guard:
                    failures.append(exc)
            finally:
                if threading.current_thread().name == "diagnostic-second":
                    with progress_changed:
                        progress["secondDone"] = True
                        progress_changed.notify_all()

        first = threading.Thread(target=record, args=(1,), name="diagnostic-first")
        second = threading.Thread(target=record, args=(2,), name="diagnostic-second")
        with (
            mock.patch.object(
                command_state.safe_io,
                "_rooted_io_checkpoint",
                side_effect=blocking_checkpoint,
            ),
            mock.patch.object(command_state, "_stable_lock", observed_stable_lock),
        ):
            first.start()
            try:
                self.assertTrue(first_at_replace.wait(5))
                second.start()
                with progress_changed:
                    progressed = progress_changed.wait_for(
                        lambda: progress["secondGateAttempted"]
                        or progress["secondDone"],
                        timeout=5,
                    )
                    second_gate_attempted = progress["secondGateAttempted"]
                    second_done = progress["secondDone"]
                self.assertTrue(progressed)
                self.assertTrue(second_gate_attempted)
                self.assertFalse(second_done)
            finally:
                release_first.set()
                first.join(10)
                if second.ident is not None:
                    second.join(10)

        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(len(results), 2)
        self.assertEqual(len(observed_temporaries), 1)
        self.assertEqual(list(control.glob(f".{target.name}.*.tmp")), [])
        intent = command_state.read_terminal_intent(self.attempt_root)
        retained = [intent["primary"], *intent["secondary"]]
        self.assertEqual(intent["nextOrdinal"], 3)
        self.assertEqual(intent["droppedCount"], 0)
        self.assertEqual(len(retained), 2)
        self.assertEqual({item["ordinal"] for item in retained}, {1, 2})

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


class CrashRecoveryStateTests(CommandStateTestCase):
    _STABLE_NAMES = (
        "group.lease",
        "state.lock",
        "stderr.recovery",
        "stdout.recovery",
        "supervisor.lease",
    )

    @staticmethod
    @contextlib.contextmanager
    def hold_raw_lease(path):
        descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    @staticmethod
    def command_root(root):
        return Path(root) / ".evidence-control" / "commands" / COMMAND_ID

    def exact_tree_snapshot(self, root):
        root = Path(root)
        identities = {}
        for path in (root, *sorted(root.rglob("*"))):
            metadata = path.lstat()
            relative = "." if path == root else path.relative_to(root).as_posix()
            identities[relative] = (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_mode,
                metadata.st_size,
            )
        return self.snapshot(root), identities

    def make_unprepared_tombstone(self, root, survivors):
        root = Path(root)
        root.mkdir(parents=True, exist_ok=True)
        command_state.initialize_control_layout(root, valid_session())
        reservation = command_state.reserve_command_layout(
            root, SESSION_ID, 1, COMMAND_ID
        )
        reservation.close()
        command_root = self.command_root(root)
        metadata = command_root.stat()
        tombstone = command_root.with_name(
            f".retiring-{COMMAND_ID}-{metadata.st_dev}-{metadata.st_ino}"
        )
        command_root.rename(tombstone)
        survivors = frozenset(survivors)
        for name in self._STABLE_NAMES:
            if name not in survivors:
                (tombstone / name).unlink()
        return command_root, tombstone

    def prepare_stored_state(self):
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        lease.close()
        return prepared

    def assert_mutation_locks_are_free(self):
        command_root = self.command_root(self.attempt_root)
        for path in (
            command_root.parent.parent / ".commands.lock",
            command_root / "state.lock",
        ):
            descriptor = os.open(
                path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
            )
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def assert_mutation_locks_are_held(self):
        command_root = self.command_root(self.attempt_root)
        for path in (
            command_root.parent.parent / ".commands.lock",
            command_root / "state.lock",
        ):
            descriptor = os.open(
                path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
            )
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(
                        descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                    )
            finally:
                os.close(descriptor)

    @staticmethod
    def replace_file(path, content):
        temporary = path.with_name(path.name + ".probe-replacement")
        temporary.write_bytes(content)
        temporary.chmod(0o600)
        os.replace(temporary, path)

    def recovery_backend(
        self,
        *,
        identity="linux:boot-id:recovery-current",
        absent=True,
        hook=None,
    ):
        class Backend:
            def __init__(backend):
                backend.calls = []

            def current_identity(backend, pid):
                backend.calls.append(("current", pid))
                if hook is not None:
                    hook("current")
                return identity

            def predecessor_absent(backend, pid, birth_identity):
                backend.calls.append(("absent", pid, birth_identity))
                if hook is not None:
                    hook("absent")
                return absent

        return Backend()

    def require_recovery_api(self, name):
        api = getattr(command_state, name, None)
        self.assertTrue(callable(api), f"missing crash-recovery API: {name}")
        return api

    def test_unprepared_retirement_holds_exact_locks_through_each_destructive_syscall(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        lease, _prepared = self.reserve_prepared_state()
        lease.close()
        command_root = self.command_root(self.attempt_root)
        commands_root = command_root.parent
        command_metadata = command_root.stat()
        command_identity = (command_metadata.st_dev, command_metadata.st_ino)
        commands_metadata = commands_root.stat()
        commands_identity = (commands_metadata.st_dev, commands_metadata.st_ino)
        entry_identities = {
            name: (
                (command_root / name).stat().st_dev,
                (command_root / name).stat().st_ino,
            )
            for name in self._STABLE_NAMES
        }
        lock_paths = (
            command_root.parent.parent / ".commands.lock",
            command_root / "state.lock",
            command_root / "supervisor.lease",
            command_root / "group.lease",
        )
        observers = [
            os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
            for path in lock_paths
        ]
        original_unlink = os.unlink
        original_rmdir = os.rmdir
        original_rename = command_state._atomic_rename_no_replace
        original_fsync = os.fsync
        tombstone_name = (
            f".retiring-{COMMAND_ID}-{command_identity[0]}-"
            f"{command_identity[1]}"
        )
        operations = []
        unlinked = []
        removed = []
        fsynced = []

        def assert_all_held():
            for descriptor in observers:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(
                        descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                    )

        def checked_rename(
            source,
            target,
            *,
            src_dir_fd=None,
            dst_dir_fd=None,
        ):
            self.assertEqual(source, COMMAND_ID)
            self.assertEqual(target, tombstone_name)
            self.assertIsNotNone(src_dir_fd)
            self.assertIsNotNone(dst_dir_fd)
            source_parent = os.fstat(src_dir_fd)
            target_parent = os.fstat(dst_dir_fd)
            self.assertEqual(
                (source_parent.st_dev, source_parent.st_ino), commands_identity
            )
            self.assertEqual(
                (target_parent.st_dev, target_parent.st_ino), commands_identity
            )
            visible = os.stat(
                source, dir_fd=src_dir_fd, follow_symlinks=False
            )
            self.assertEqual((visible.st_dev, visible.st_ino), command_identity)
            assert_all_held()
            operations.append("rename")
            return original_rename(
                source,
                target,
                src_dir_fd=src_dir_fd,
                dst_dir_fd=dst_dir_fd,
            )

        def checked_unlink(name, *args, dir_fd=None, **kwargs):
            self.assertIsNotNone(dir_fd)
            parent = os.fstat(dir_fd)
            self.assertEqual((parent.st_dev, parent.st_ino), command_identity)
            visible = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
            self.assertEqual(
                (visible.st_dev, visible.st_ino), entry_identities[name]
            )
            assert_all_held()
            operations.append(f"unlink:{name}")
            unlinked.append(name)
            return original_unlink(name, *args, dir_fd=dir_fd, **kwargs)

        def checked_rmdir(name, *args, dir_fd=None, **kwargs):
            self.assertIsNotNone(dir_fd)
            parent = os.fstat(dir_fd)
            self.assertEqual((parent.st_dev, parent.st_ino), commands_identity)
            visible = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
            self.assertEqual((visible.st_dev, visible.st_ino), command_identity)
            self.assertEqual(name, tombstone_name)
            assert_all_held()
            operations.append("rmdir")
            removed.append(name)
            return original_rmdir(name, *args, dir_fd=dir_fd, **kwargs)

        def checked_fsync(descriptor):
            metadata = os.fstat(descriptor)
            identity = (metadata.st_dev, metadata.st_ino)
            fsynced.append(identity)
            if identity == commands_identity:
                assert_all_held()
                operations.append("fsync:commands")
            elif identity == command_identity:
                assert_all_held()
                operations.append("fsync:tombstone")
            return original_fsync(descriptor)

        try:
            with mock.patch.object(
                command_state,
                "_atomic_rename_no_replace",
                side_effect=checked_rename,
            ), mock.patch.object(
                command_state.os, "unlink", side_effect=checked_unlink
            ), mock.patch.object(
                command_state.os, "rmdir", side_effect=checked_rmdir
            ), mock.patch.object(
                command_state.os, "fsync", side_effect=checked_fsync
            ):
                self.assertTrue(
                    retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
                )
        finally:
            for descriptor in observers:
                os.close(descriptor)

        self.assertEqual(unlinked, list(self._STABLE_NAMES))
        self.assertEqual(removed, [tombstone_name])
        self.assertGreaterEqual(fsynced.count(commands_identity), 2)
        self.assertGreaterEqual(fsynced.count(command_identity), 1)
        self.assertEqual(operations[:2], ["rename", "fsync:commands"])
        self.assertEqual(operations[-2:], ["rmdir", "fsync:commands"])
        rmdir_index = operations.index("rmdir")
        final_unlink_index = max(
            index
            for index, operation in enumerate(operations)
            if operation.startswith("unlink:")
        )
        self.assertEqual(operations[rmdir_index - 1], "fsync:tombstone")
        self.assertLess(final_unlink_index, rmdir_index - 1)
        self.assertFalse(command_root.exists())
        replacement = command_state.reserve_command_layout(
            self.attempt_root, SESSION_ID, 1, COMMAND_ID
        )
        replacement.close()
        self.assertTrue(command_root.is_dir())

    def test_retirement_resumes_after_rename_every_unlink_and_rmdir_fault(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()

        class InjectedCrash(RuntimeError):
            pass

        fault_points = [("after_retire_rename", 1)] + [
            ("after_retire_unlink", ordinal)
            for ordinal in range(1, len(self._STABLE_NAMES) + 1)
        ] + [("after_retire_rmdir", 1)]
        for fault_stage, fault_ordinal in fault_points:
            with self.subTest(stage=fault_stage, ordinal=fault_ordinal):
                command_root = self.command_root(self.attempt_root)
                if not command_root.exists():
                    reservation = command_state.reserve_command_layout(
                        self.attempt_root, SESSION_ID, 1, COMMAND_ID
                    )
                    reservation.close()
                seen = 0

                def crash(stage, path):
                    nonlocal seen
                    if stage != fault_stage:
                        return
                    seen += 1
                    if seen == fault_ordinal:
                        raise InjectedCrash(str(path))

                with mock.patch.object(
                    command_state,
                    "_command_recovery_checkpoint",
                    side_effect=crash,
                    create=True,
                ), self.assertRaises(InjectedCrash):
                    retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
                self.assertFalse(command_root.exists())
                commands_root = command_root.parent
                tombstones = sorted(
                    path
                    for path in commands_root.iterdir()
                    if path.name.startswith(f".retiring-{COMMAND_ID}-")
                )
                if fault_stage == "after_retire_rmdir":
                    self.assertEqual(tombstones, [])
                    self.assertFalse(
                        retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
                    )
                elif fault_stage == "after_retire_rename":
                    self.assertEqual(len(tombstones), 1)
                    self.assertEqual(
                        sorted(path.name for path in tombstones[0].iterdir()),
                        list(self._STABLE_NAMES),
                    )
                    replacement = command_state.reserve_command_layout(
                        self.attempt_root, SESSION_ID, 1, COMMAND_ID
                    )
                    replacement.close()
                    self.assertTrue(command_root.is_dir())
                    continue
                else:
                    self.assertEqual(len(tombstones), 1)
                    metadata = tombstones[0].stat()
                    self.assertEqual(
                        tombstones[0].name,
                        f".retiring-{COMMAND_ID}-{metadata.st_dev}-"
                        f"{metadata.st_ino}",
                    )
                    self.assertEqual(
                        sorted(path.name for path in tombstones[0].iterdir()),
                        list(self._STABLE_NAMES[fault_ordinal:]),
                    )
                    self.assertTrue(
                        retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
                    )
                replacement = command_state.reserve_command_layout(
                    self.attempt_root, SESSION_ID, 1, COMMAND_ID
                )
                replacement.close()
                self.assertFalse(
                    any(
                        path.name.startswith(f".retiring-{COMMAND_ID}-")
                        for path in commands_root.iterdir()
                    )
                )

    def test_retirement_blocks_mismatched_unsafe_or_multiple_tombstones_untouched(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )

        for corruption in (
            "identity",
            "extra",
            "nonempty",
            "wrong-mode",
            "symlink",
            "multiple",
        ):
            with self.subTest(
                corruption=corruption
            ), tempfile.TemporaryDirectory() as directory:
                root = (
                    Path(directory)
                    / "attempts"
                    / "logical-1-attempt-1"
                )
                root.mkdir(parents=True)
                command_state.initialize_control_layout(root, valid_session())
                reservation = command_state.reserve_command_layout(
                    root, SESSION_ID, 1, COMMAND_ID
                )
                reservation.close()
                command_root = self.command_root(root)
                metadata = command_root.stat()
                tombstone = command_root.with_name(
                    f".retiring-{COMMAND_ID}-{metadata.st_dev}-"
                    f"{metadata.st_ino}"
                )
                command_root.rename(tombstone)
                if corruption == "identity":
                    wrong = tombstone.with_name(
                        f".retiring-{COMMAND_ID}-{metadata.st_dev}-"
                        f"{metadata.st_ino + 1}"
                    )
                    tombstone.rename(wrong)
                elif corruption == "extra":
                    (tombstone / "unexpected").write_bytes(b"")
                    (tombstone / "unexpected").chmod(0o600)
                elif corruption == "nonempty":
                    (tombstone / "stdout.recovery").write_bytes(b"x")
                elif corruption == "wrong-mode":
                    (tombstone / "stderr.recovery").chmod(0o640)
                elif corruption == "symlink":
                    (tombstone / "stdout.recovery").unlink()
                    (tombstone / "stdout.recovery").symlink_to("state.lock")
                elif corruption == "multiple":
                    second = tombstone.parent / ".second-retirement"
                    second.mkdir(mode=0o700)
                    second_metadata = second.stat()
                    second.rename(
                        second.with_name(
                            f".retiring-{COMMAND_ID}-{second_metadata.st_dev}-"
                            f"{second_metadata.st_ino}"
                        )
                    )
                before = self.snapshot(root)
                with self.assertRaises(ValueError):
                    retire(root, SESSION_ID, 1, COMMAND_ID)
                self.assertEqual(self.snapshot(root), before)
                with self.assertRaises(ValueError):
                    command_state.reserve_command_layout(
                        root, SESSION_ID, 1, COMMAND_ID
                    )
                self.assertEqual(self.snapshot(root), before)
                self.assertFalse(command_root.exists())

    def test_retirement_and_reservation_refuse_active_or_malformed_tombstone_ambiguity(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        for corruption in ("active-and-tombstone", "malformed-prefix"):
            with self.subTest(
                corruption=corruption
            ), tempfile.TemporaryDirectory() as directory:
                root = (
                    Path(directory)
                    / "attempts"
                    / "logical-1-attempt-1"
                )
                root.mkdir(parents=True)
                command_state.initialize_control_layout(root, valid_session())
                reservation = command_state.reserve_command_layout(
                    root, SESSION_ID, 1, COMMAND_ID
                )
                reservation.close()
                command_root = self.command_root(root)
                commands_root = command_root.parent
                if corruption == "active-and-tombstone":
                    candidate = commands_root / ".retirement-candidate"
                    candidate.mkdir(mode=0o700)
                    metadata = candidate.stat()
                    candidate.rename(
                        commands_root
                        / (
                            f".retiring-{COMMAND_ID}-{metadata.st_dev}-"
                            f"{metadata.st_ino}"
                        )
                    )
                else:
                    command_root.rename(
                        commands_root
                        / f".retiring-{COMMAND_ID}-malformed"
                    )
                before = self.snapshot(root)
                with self.assertRaises(ValueError):
                    retire(root, SESSION_ID, 1, COMMAND_ID)
                self.assertEqual(self.snapshot(root), before)
                with self.assertRaises(ValueError):
                    command_state.reserve_command_layout(
                        root, SESSION_ID, 1, COMMAND_ID
                    )
                self.assertEqual(self.snapshot(root), before)
                self.assertEqual(
                    command_root.exists(),
                    corruption == "active-and-tombstone",
                )

    def test_tombstone_resume_rejects_nonprefix_survivors_without_mutation(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        all_subsets = {
            frozenset(combination)
            for length in range(len(self._STABLE_NAMES) + 1)
            for combination in itertools.combinations(
                self._STABLE_NAMES, length
            )
        }
        legal_suffixes = {
            frozenset(self._STABLE_NAMES[index:])
            for index in range(len(self._STABLE_NAMES) + 1)
        }
        illegal_survivors = sorted(
            all_subsets - legal_suffixes,
            key=lambda members: (
                len(members),
                tuple(
                    name for name in self._STABLE_NAMES if name in members
                ),
            ),
        )
        self.assertEqual(len(all_subsets), 32)
        self.assertEqual(len(legal_suffixes), 6)
        self.assertEqual(len(illegal_survivors), 26)

        for survivors in illegal_survivors:
            ordered_survivors = tuple(
                name for name in self._STABLE_NAMES if name in survivors
            )
            with self.subTest(
                survivors=ordered_survivors
            ), tempfile.TemporaryDirectory() as directory:
                root = (
                    Path(directory)
                    / "attempts"
                    / "logical-1-attempt-1"
                )
                command_root, tombstone = self.make_unprepared_tombstone(
                    root, survivors
                )
                before = self.exact_tree_snapshot(root)
                with self.assertRaises(ValueError):
                    retire(root, SESSION_ID, 1, COMMAND_ID)
                self.assertEqual(self.exact_tree_snapshot(root), before)
                with self.assertRaises(ValueError):
                    command_state.reserve_command_layout(
                        root, SESSION_ID, 1, COMMAND_ID
                    )
                self.assertEqual(self.exact_tree_snapshot(root), before)
                self.assertFalse(command_root.exists())
                self.assertTrue(tombstone.is_dir())

    def test_each_partial_tombstone_suffix_rejects_corrupt_survivor_untouched(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        for suffix_index in range(1, len(self._STABLE_NAMES)):
            survivors = self._STABLE_NAMES[suffix_index:]
            for corruption in ("nonempty", "wrong-mode", "symlink"):
                with self.subTest(
                    survivors=survivors,
                    corruption=corruption,
                ), tempfile.TemporaryDirectory() as directory:
                    root = (
                        Path(directory)
                        / "attempts"
                        / "logical-1-attempt-1"
                    )
                    command_root, tombstone = (
                        self.make_unprepared_tombstone(root, survivors)
                    )
                    target = tombstone / survivors[0]
                    if corruption == "nonempty":
                        target.write_bytes(b"corrupt")
                    elif corruption == "wrong-mode":
                        target.chmod(0o640)
                    else:
                        target.unlink()
                        target.symlink_to("missing-private-entry")

                    before = self.exact_tree_snapshot(root)
                    with self.assertRaises(ValueError):
                        retire(root, SESSION_ID, 1, COMMAND_ID)
                    self.assertEqual(
                        self.exact_tree_snapshot(root), before
                    )
                    with self.assertRaises(ValueError):
                        command_state.reserve_command_layout(
                            root, SESSION_ID, 1, COMMAND_ID
                        )
                    self.assertEqual(
                        self.exact_tree_snapshot(root), before
                    )
                    self.assertFalse(command_root.exists())
                    self.assertTrue(tombstone.is_dir())

    def test_partial_tombstone_with_a_held_surviving_lease_is_busy_and_untouched(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        reservation = command_state.reserve_command_layout(
            self.attempt_root, SESSION_ID, 1, COMMAND_ID
        )
        reservation.close()
        command_root = self.command_root(self.attempt_root)
        metadata = command_root.stat()
        tombstone = command_root.with_name(
            f".retiring-{COMMAND_ID}-{metadata.st_dev}-{metadata.st_ino}"
        )
        command_root.rename(tombstone)
        for name in self._STABLE_NAMES[:-1]:
            (tombstone / name).unlink()
        before = self.exact_tree_snapshot(self.attempt_root)
        with self.hold_raw_lease(tombstone / "supervisor.lease"):
            self.assertFalse(
                retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
            )
            self.assertEqual(self.exact_tree_snapshot(self.attempt_root), before)
            with self.assertRaises((TimeoutError, ValueError)):
                command_state.reserve_command_layout(
                    self.attempt_root, SESSION_ID, 1, COMMAND_ID
                )
            self.assertEqual(self.exact_tree_snapshot(self.attempt_root), before)
            self.assertFalse(command_root.exists())
        self.assertTrue(
            retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
        )

    def test_partial_tombstone_resume_locks_every_surviving_lock_through_parent_fsync(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        reservation = command_state.reserve_command_layout(
            self.attempt_root, SESSION_ID, 1, COMMAND_ID
        )
        reservation.close()
        command_root = self.command_root(self.attempt_root)
        commands_root = command_root.parent
        metadata = command_root.stat()
        command_identity = (metadata.st_dev, metadata.st_ino)
        commands_metadata = commands_root.stat()
        commands_identity = (commands_metadata.st_dev, commands_metadata.st_ino)
        tombstone = command_root.with_name(
            f".retiring-{COMMAND_ID}-{metadata.st_dev}-{metadata.st_ino}"
        )
        command_root.rename(tombstone)
        (tombstone / self._STABLE_NAMES[0]).unlink()
        surviving_names = self._STABLE_NAMES[1:]
        surviving_locks = ("state.lock", "supervisor.lease")
        observer_paths = (
            commands_root.parent / ".commands.lock",
            *(tombstone / name for name in surviving_locks),
        )
        observers = [
            os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
            for path in observer_paths
        ]
        original_unlink = os.unlink
        original_rmdir = os.rmdir
        original_fsync = os.fsync
        operations = []

        def assert_all_held():
            for descriptor in observers:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(
                        descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                    )

        def checked_unlink(name, *args, dir_fd=None, **kwargs):
            parent = os.fstat(dir_fd)
            self.assertEqual((parent.st_dev, parent.st_ino), command_identity)
            self.assertIn(name, surviving_names)
            assert_all_held()
            operations.append(f"unlink:{name}")
            return original_unlink(name, *args, dir_fd=dir_fd, **kwargs)

        def checked_rmdir(name, *args, dir_fd=None, **kwargs):
            parent = os.fstat(dir_fd)
            self.assertEqual((parent.st_dev, parent.st_ino), commands_identity)
            self.assertEqual(name, tombstone.name)
            assert_all_held()
            result = original_rmdir(name, *args, dir_fd=dir_fd, **kwargs)
            operations.append("rmdir")
            return result

        def checked_fsync(descriptor):
            metadata = os.fstat(descriptor)
            identity = (metadata.st_dev, metadata.st_ino)
            if identity == commands_identity:
                assert_all_held()
                operations.append("fsync:commands")
            elif identity == command_identity:
                assert_all_held()
                operations.append("fsync:tombstone")
            return original_fsync(descriptor)

        try:
            with mock.patch.object(
                command_state.os, "unlink", side_effect=checked_unlink
            ), mock.patch.object(
                command_state.os, "rmdir", side_effect=checked_rmdir
            ), mock.patch.object(
                command_state.os, "fsync", side_effect=checked_fsync
            ):
                self.assertTrue(
                    retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
                )
        finally:
            for descriptor in observers:
                os.close(descriptor)
        self.assertEqual(
            [
                operation
                for operation in operations
                if operation.startswith("unlink:")
            ],
            [f"unlink:{name}" for name in surviving_names],
        )
        rmdir_index = operations.index("rmdir")
        self.assertEqual(operations[rmdir_index - 1], "fsync:tombstone")
        self.assertEqual(operations[-2:], ["rmdir", "fsync:commands"])
        self.assertFalse(tombstone.exists())

    def test_unprepared_retirement_returns_busy_for_each_held_lease(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        lease, _prepared = self.reserve_prepared_state()
        command_root = self.command_root(self.attempt_root)
        before = self.snapshot(self.attempt_root)
        self.assertFalse(retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID))
        self.assertEqual(self.snapshot(self.attempt_root), before)
        lease.close()

        for name in ("state.lock", "group.lease"):
            with self.subTest(held=name), self.hold_raw_lease(command_root / name):
                before = self.snapshot(self.attempt_root)
                self.assertFalse(
                    retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
                )
                self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_unprepared_retirement_disagreement_is_untouched(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        lease, _prepared = self.reserve_prepared_state()
        lease.close()
        command_root = self.command_root(self.attempt_root)

        corruptions = (
            (
                "nonempty",
                lambda: (command_root / "stdout.recovery").write_bytes(b"x"),
                lambda: (command_root / "stdout.recovery").write_bytes(b""),
            ),
            (
                "extra",
                lambda: (command_root / "extra").write_bytes(b""),
                lambda: (command_root / "extra").unlink(),
            ),
            (
                "mode",
                lambda: (command_root / "group.lease").chmod(0o700),
                lambda: (command_root / "group.lease").chmod(0o600),
            ),
        )
        for label, corrupt, restore in corruptions:
            corrupt()
            before = self.snapshot(self.attempt_root)
            with self.subTest(corruption=label), self.assertRaises(ValueError):
                retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
            self.assertEqual(self.snapshot(self.attempt_root), before)
            restore()

        substituted = []

        def substitute_after_snapshot(stage, _path):
            if stage != "after_retire_snapshot":
                return
            target = command_root / "group.lease"
            moved = command_root / "group.lease.original"
            target.rename(moved)
            target.write_bytes(b"")
            target.chmod(0o600)
            substituted.append(self.snapshot(self.attempt_root))

        with mock.patch.object(
            command_state,
            "_command_recovery_checkpoint",
            side_effect=substitute_after_snapshot,
            create=True,
        ), self.assertRaises(ValueError):
            retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
        self.assertEqual(self.snapshot(self.attempt_root), substituted[0])

    def test_unprepared_retirement_rejects_whole_directory_substitution(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        lease, _prepared = self.reserve_prepared_state()
        lease.close()
        command_root = self.command_root(self.attempt_root)
        moved_root = command_root.with_name(COMMAND_ID + ".original")
        injected = []

        def substitute(stage, path):
            if stage != "after_retire_snapshot":
                return
            self.assertEqual(Path(path), command_root)
            command_root.rename(moved_root)
            command_root.mkdir(mode=0o700)
            for name in self._STABLE_NAMES:
                (command_root / name).write_bytes(b"")
                (command_root / name).chmod(0o600)
            injected.append(self.snapshot(self.attempt_root))

        with mock.patch.object(
            command_state,
            "_command_recovery_checkpoint",
            side_effect=substitute,
            create=True,
        ), self.assertRaises(ValueError):
            retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
        self.assertEqual(self.snapshot(self.attempt_root), injected[0])

    def test_retirement_no_replace_preserves_a_racing_target(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        lease, _prepared = self.reserve_prepared_state()
        lease.close()
        command_root = self.command_root(self.attempt_root)
        injected = []

        def create_target(stage, path):
            if stage != "before_retire_rename":
                return
            target = Path(path)
            target.mkdir(mode=0o700)
            injected.append(self.exact_tree_snapshot(self.attempt_root))

        with mock.patch.object(
            command_state,
            "_command_recovery_checkpoint",
            side_effect=create_target,
        ), self.assertRaises(ValueError):
            retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
        self.assertEqual(len(injected), 1)
        self.assertEqual(
            self.exact_tree_snapshot(self.attempt_root), injected[0]
        )
        self.assertTrue(command_root.is_dir())

    def test_retirement_rolls_back_a_racing_source_substitution(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        lease, _prepared = self.reserve_prepared_state()
        lease.close()
        command_root = self.command_root(self.attempt_root)
        original = command_root.with_name(COMMAND_ID + ".original")
        injected = []

        def substitute_source(stage, _path):
            if stage != "before_retire_rename":
                return
            command_root.rename(original)
            command_root.mkdir(mode=0o700)
            for name in self._STABLE_NAMES:
                entry = command_root / name
                entry.write_bytes(b"")
                entry.chmod(0o600)
            injected.append(self.exact_tree_snapshot(self.attempt_root))

        with mock.patch.object(
            command_state,
            "_command_recovery_checkpoint",
            side_effect=substitute_source,
        ), self.assertRaises(ValueError):
            retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
        self.assertEqual(len(injected), 1)
        self.assertEqual(
            self.exact_tree_snapshot(self.attempt_root), injected[0]
        )
        self.assertTrue(command_root.is_dir())
        self.assertTrue(original.is_dir())

    def test_atomic_no_replace_rename_fails_closed_off_supported_platforms(self):
        directory = self.publication_root / "rename-test"
        directory.mkdir(mode=0o700)
        (directory / "source").write_bytes(b"source")
        descriptor = os.open(
            directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
        )
        try:
            with mock.patch.object(sys, "platform", "unsupported"):
                with self.assertRaises(RuntimeError):
                    command_state._atomic_rename_no_replace(
                        "source",
                        "target",
                        src_dir_fd=descriptor,
                        dst_dir_fd=descriptor,
                    )
            self.assertEqual((directory / "source").read_bytes(), b"source")
            self.assertFalse((directory / "target").exists())
        finally:
            os.close(descriptor)

    def test_retirement_handle_close_attempts_every_descriptor(self):
        directory = self.publication_root / "handles"
        directory.mkdir(mode=0o700)
        directory_descriptor = os.open(
            directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
        )
        entry_descriptors = {}
        for name in ("one", "two", "three"):
            path = directory / name
            path.write_bytes(b"")
            descriptor = os.open(path, os.O_RDWR | os.O_CLOEXEC)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            entry_descriptors[name] = descriptor
        handles = command_state._RetirementHandles(
            directory_descriptor,
            (directory.stat().st_dev, directory.stat().st_ino),
            dict(entry_descriptors),
            {
                name: (os.fstat(descriptor).st_dev, os.fstat(descriptor).st_ino)
                for name, descriptor in entry_descriptors.items()
            },
        )
        original_flock = fcntl.flock
        unlocks = []

        def fail_first_unlock(descriptor, operation):
            original_flock(descriptor, operation)
            if operation == fcntl.LOCK_UN:
                unlocks.append(descriptor)
                if len(unlocks) == 1:
                    raise OSError("injected unlock failure")

        all_descriptors = [*entry_descriptors.values(), directory_descriptor]
        try:
            with mock.patch.object(
                command_state.fcntl,
                "flock",
                side_effect=fail_first_unlock,
            ), self.assertRaisesRegex(OSError, "injected"):
                handles.close()
            self.assertEqual(set(unlocks), set(entry_descriptors.values()))
            self.assertEqual(handles.entry_descriptors, {})
            self.assertEqual(handles.directory_descriptor, -1)
            for descriptor in all_descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
        finally:
            for descriptor in all_descriptors:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_open_commands_validation_failure_closes_its_descriptor(self):
        self.initialize()

        class InjectedFailure(RuntimeError):
            pass

        opened = []
        with command_state.safe_io._rooted_io(self.publication_root):
            authority = command_state.safe_io._active_rooted_io()
            original_open = authority._open_directory_unchecked

            def track_open(relative):
                descriptor = original_open(relative)
                opened.append(descriptor)
                return descriptor

            with mock.patch.object(
                authority,
                "_open_directory_unchecked",
                side_effect=track_open,
            ), mock.patch.object(
                authority,
                "_validate_directory",
                side_effect=InjectedFailure("injected validation failure"),
            ), self.assertRaises(InjectedFailure):
                command_state._open_commands_descriptor(self.attempt_root)
            self.assertEqual(len(opened), 1)
            try:
                with self.assertRaises(OSError):
                    os.fstat(opened[0])
            finally:
                try:
                    os.close(opened[0])
                except OSError:
                    pass

    def test_retirement_parent_scope_closes_commands_fd_after_handle_error(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )

        class InjectedCleanupFailure(RuntimeError):
            pass

        for flow in ("active", "resume"):
            with self.subTest(flow=flow), tempfile.TemporaryDirectory() as directory:
                root = (
                    Path(directory)
                    / "attempts"
                    / "logical-1-attempt-1"
                )
                if flow == "resume":
                    self.make_unprepared_tombstone(root, self._STABLE_NAMES)
                else:
                    root.mkdir(parents=True)
                    command_state.initialize_control_layout(root, valid_session())
                    reservation = command_state.reserve_command_layout(
                        root, SESSION_ID, 1, COMMAND_ID
                    )
                    reservation.close()
                opened_commands = []
                original_open_commands = command_state._open_commands_descriptor
                original_close = command_state._RetirementHandles.close

                def track_commands_descriptor(attempt_root):
                    result = original_open_commands(attempt_root)
                    opened_commands.append(result[1])
                    return result

                def close_then_fail(handles):
                    original_close(handles)
                    raise InjectedCleanupFailure("injected handle cleanup failure")

                try:
                    with mock.patch.object(
                        command_state,
                        "_open_commands_descriptor",
                        side_effect=track_commands_descriptor,
                    ), mock.patch.object(
                        command_state._RetirementHandles,
                        "close",
                        new=close_then_fail,
                    ), self.assertRaises(InjectedCleanupFailure):
                        retire(root, SESSION_ID, 1, COMMAND_ID)
                    self.assertGreaterEqual(len(opened_commands), 1)
                    for descriptor in opened_commands:
                        with self.assertRaises(OSError):
                            os.fstat(descriptor)
                finally:
                    for descriptor in opened_commands:
                        try:
                            os.close(descriptor)
                        except OSError:
                            pass

    def test_retirement_entry_validation_failure_closes_newly_opened_fd(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        lease, _prepared = self.reserve_prepared_state()
        lease.close()

        class InjectedValidationFailure(RuntimeError):
            pass

        original_open = os.open
        original_validate = command_state._validate_retirement_entry_metadata
        opened_entry = []

        def track_open(path, *args, dir_fd=None, **kwargs):
            descriptor = original_open(path, *args, dir_fd=dir_fd, **kwargs)
            if (
                type(path) is str
                and path in self._STABLE_NAMES
                and dir_fd is not None
                and not opened_entry
            ):
                opened_entry.append(descriptor)
            return descriptor

        def fail_after_entry_open(metadata, **kwargs):
            if opened_entry:
                raise InjectedValidationFailure("injected entry validation failure")
            return original_validate(metadata, **kwargs)

        try:
            with mock.patch.object(
                command_state.os, "open", side_effect=track_open
            ), mock.patch.object(
                command_state,
                "_validate_retirement_entry_metadata",
                side_effect=fail_after_entry_open,
            ), self.assertRaises(InjectedValidationFailure):
                retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID)
            self.assertEqual(len(opened_entry), 1)
            with self.assertRaises(OSError):
                os.fstat(opened_entry[0])
        finally:
            for descriptor in opened_entry:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_retirement_is_idempotent_generation_bound_and_finalizing_safe(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.initialize()
        empty = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            retire(self.attempt_root, SESSION_ID, 2, COMMAND_ID)
        self.assertEqual(self.snapshot(self.attempt_root), empty)
        self.assertFalse(retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID))

        lease, _prepared = self.reserve_prepared_state()
        lease.close()
        before = self.snapshot(self.attempt_root)
        with self.assertRaises(ValueError):
            retire(self.attempt_root, SESSION_ID, 2, COMMAND_ID)
        self.assertEqual(self.snapshot(self.attempt_root), before)
        command_state.transition_session_state(
            self.attempt_root, SESSION_ID, 1, "finalizing"
        )
        self.assertTrue(retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID))
        self.assertFalse(retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID))

    def test_retirement_never_removes_a_persisted_command_state(self):
        retire = self.require_recovery_api(
            "retire_unprepared_command_layout"
        )
        self.prepare_stored_state()
        before = self.snapshot(self.attempt_root)
        self.assertFalse(retire(self.attempt_root, SESSION_ID, 1, COMMAND_ID))
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_recovery_claim_is_server_constructed_and_probes_without_mutation_locks(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        prepared = self.prepare_stored_state()
        backend = self.recovery_backend(
            hook=lambda _stage: self.assert_mutation_locks_are_free()
        )
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=backend,
        )
        self.addCleanup(claim.close)
        replacement = {
            "pid": os.getpid(),
            "birthIdentity": "linux:boot-id:recovery-current",
            "leaseIdentity": prepared["supervisor"]["leaseIdentity"],
            "role": "recovery",
            "predecessor": command_state.supervisor_fingerprint(
                prepared["supervisor"]
            ),
        }
        self.assertEqual(
            backend.calls,
            [
                ("current", os.getpid()),
                (
                    "absent",
                    prepared["supervisor"]["pid"],
                    prepared["supervisor"]["birthIdentity"],
                )
            ],
        )
        self.assertEqual(claim.state["supervisor"], replacement)
        self.assertEqual(claim.identity, replacement["leaseIdentity"])
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )["supervisor"],
            replacement,
        )

    def test_recovery_gate_leases_are_nonblocking_under_both_mutation_locks(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        original_lease = command_state.safe_io._RootedIO.lease
        observed = []

        def checked_lease(authority, path, timeout=0.0):
            if Path(path).name in ("supervisor.lease", "group.lease"):
                self.assertEqual(timeout, 0.0)
                self.assert_mutation_locks_are_held()
                observed.append(Path(path).name)
            return original_lease(authority, path, timeout)

        with mock.patch.object(
            command_state.safe_io._RootedIO,
            "lease",
            new=checked_lease,
        ):
            claim = claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=self.recovery_backend(),
                timeout=0.25,
            )
        self.addCleanup(claim.close)
        self.assertEqual(observed, ["supervisor.lease", "group.lease"])

    def test_recovery_gate_retries_and_sleeps_only_after_releasing_locks(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        group_path = self.command_root(self.attempt_root) / "group.lease"
        held_group = os.open(
            group_path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
        )
        fcntl.flock(held_group, fcntl.LOCK_EX | fcntl.LOCK_NB)
        released = False
        sleeps = []
        original_lease = command_state.safe_io._RootedIO.lease

        def checked_lease(authority, path, timeout=0.0):
            self.assertEqual(timeout, 0.0)
            self.assert_mutation_locks_are_held()
            return original_lease(authority, path, timeout)

        def release_during_retry(delay):
            nonlocal held_group, released
            self.assert_mutation_locks_are_free()
            sleeps.append(delay)
            if not released:
                fcntl.flock(held_group, fcntl.LOCK_UN)
                os.close(held_group)
                held_group = -1
                released = True

        try:
            with mock.patch.object(
                command_state.safe_io._RootedIO,
                "lease",
                new=checked_lease,
            ), mock.patch.object(
                command_state.time,
                "sleep",
                side_effect=release_during_retry,
            ):
                claim = claim_recovery(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    COMMAND_ID,
                    process_backend=self.recovery_backend(),
                    timeout=0.25,
                )
        finally:
            if held_group >= 0:
                fcntl.flock(held_group, fcntl.LOCK_UN)
                os.close(held_group)
        self.addCleanup(claim.close)
        self.assertGreaterEqual(len(sleeps), 1)

    def test_recovery_claim_is_preallocated_before_state_replacement(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        before = self.exact_tree_snapshot(self.attempt_root)

        class ConstructorFailure(RuntimeError):
            pass

        with mock.patch.object(
            command_state,
            "CommandRecoveryClaim",
            side_effect=ConstructorFailure("injected constructor failure"),
        ), self.assertRaises(ConstructorFailure):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=self.recovery_backend(),
            )
        self.assertEqual(self.exact_tree_snapshot(self.attempt_root), before)
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )["supervisor"]["role"],
            "launch",
        )

    def test_recovery_reacquires_the_same_current_claim_after_write_ambiguity(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")

        class InjectedCrash(RuntimeError):
            pass

        for seam in ("replace_return", "after_content_verify", "parent_fsync"):
            with self.subTest(seam=seam), tempfile.TemporaryDirectory() as directory:
                root = (
                    Path(directory)
                    / "attempts"
                    / "logical-1-attempt-1"
                )
                root.mkdir(parents=True)
                command_state.initialize_control_layout(root, valid_session())
                lease = command_state.reserve_command_layout(
                    root, SESSION_ID, 1, COMMAND_ID
                )
                prepared = valid_command_state(
                    "prepared",
                    supervisor=valid_supervisor(
                        pid=os.getpid(), leaseIdentity=lease.identity
                    ),
                    anchorReservation=lease.anchor_reservation,
                )
                command_state.create_command_state(
                    root, prepared, supervisor_lease=lease
                )
                lease.close()

                original_replace = os.replace
                original_fsync = os.fsync
                replaced = False

                def replace_then_maybe_fail(*args, **kwargs):
                    nonlocal replaced
                    result = original_replace(*args, **kwargs)
                    replaced = True
                    if seam == "replace_return":
                        raise InjectedCrash("after replace")
                    return result

                def checkpoint(operation, phase, _path):
                    if (
                        seam == "after_content_verify"
                        and operation == "atomic_write"
                        and phase == "after_content_verify"
                    ):
                        raise InjectedCrash("after content verification")

                def fsync_then_maybe_fail(descriptor):
                    result = original_fsync(descriptor)
                    if (
                        seam == "parent_fsync"
                        and replaced
                        and stat.S_ISDIR(os.fstat(descriptor).st_mode)
                    ):
                        raise InjectedCrash("after parent fsync")
                    return result

                with mock.patch.object(
                    command_state.safe_io.os,
                    "replace",
                    side_effect=replace_then_maybe_fail,
                ), mock.patch.object(
                    command_state.safe_io,
                    "_rooted_io_checkpoint",
                    side_effect=checkpoint,
                ), mock.patch.object(
                    command_state.safe_io.os,
                    "fsync",
                    side_effect=fsync_then_maybe_fail,
                ), self.assertRaises(InjectedCrash):
                    claim_recovery(
                        root,
                        SESSION_ID,
                        1,
                        COMMAND_ID,
                        process_backend=self.recovery_backend(),
                    )

                stored = command_state.read_command_state(
                    root, COMMAND_ID, SESSION_ID
                )
                self.assertEqual(stored["supervisor"]["role"], "recovery")
                retry_backend = self.recovery_backend(absent=False)
                claim = claim_recovery(
                    root,
                    SESSION_ID,
                    1,
                    COMMAND_ID,
                    process_backend=retry_backend,
                )
                self.assertEqual(
                    retry_backend.calls, [("current", os.getpid())]
                )
                self.assertEqual(claim.state, stored)
                claim.close()

    def test_live_launch_supervisor_lease_blocks_claim_without_probes_or_mutation(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        before = self.exact_tree_snapshot(self.attempt_root)
        backend = self.recovery_backend(
            hook=lambda _stage: self.fail(
                "a busy supervisor lease must fail before process probes"
            )
        )
        with self.assertRaises((TimeoutError, ValueError)):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=backend,
                timeout=0.0,
            )
        self.assertEqual(backend.calls, [])
        self.assertEqual(
            self.exact_tree_snapshot(self.attempt_root), before
        )

    def test_recovery_claim_holds_supervisor_lease_and_cannot_be_forged(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(),
        )
        supervisor_path = (
            self.command_root(self.attempt_root) / "supervisor.lease"
        )
        observer = os.open(
            supervisor_path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
        )
        observer_locked = False
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)

            failed = supervisor_failure_state("prepared")
            failed.update(
                supervisor=copy.deepcopy(claim.state["supervisor"]),
                anchorReservation=copy.deepcopy(
                    claim.state["anchorReservation"]
                ),
            )

            class DummyClaim:
                identity = claim.identity
                anchor_reservation = copy.deepcopy(
                    claim.state["anchorReservation"]
                )
                state = copy.deepcopy(claim.state)

                @staticmethod
                def close():
                    return None

            before = self.exact_tree_snapshot(self.attempt_root)
            with self.assertRaises(ValueError):
                command_state.transition_command_state(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    failed,
                    supervisor_lease=DummyClaim(),
                )
            self.assertEqual(
                self.exact_tree_snapshot(self.attempt_root), before
            )
            self.assertEqual(
                command_state.transition_command_state(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    failed,
                    supervisor_lease=claim,
                ),
                failed,
            )
            claim.close()
            fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            observer_locked = True
        finally:
            claim.close()
            if observer_locked:
                fcntl.flock(observer, fcntl.LOCK_UN)
            os.close(observer)

    def test_closed_recovery_claim_cannot_be_reconstructed_from_a_reservation(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        prepared = self.prepare_stored_state()
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(),
        )
        recovered = claim.state
        claim.close()

        reservation = command_state.reserve_command_layout(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
        )
        forged = None
        failed = supervisor_failure_state("prepared")
        failed.update(
            supervisor=copy.deepcopy(recovered["supervisor"]),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
        )
        before = self.exact_tree_snapshot(self.attempt_root)
        try:
            with self.assertRaisesRegex(ValueError, "server-issued recovery claim"):
                forged = command_state.CommandRecoveryClaim(
                    root=self.attempt_root,
                    command_id=COMMAND_ID,
                    session_id=SESSION_ID,
                    generation=1,
                    state=recovered,
                    authority=reservation._authority,
                    lease_context=reservation._lease_context,
                    lease=reservation._lease,
                    group_lease_identity=reservation._group_lease_identity,
                )
                command_state.transition_command_state(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    failed,
                    supervisor_lease=forged,
                )
        finally:
            if forged is not None:
                forged.close()
            else:
                reservation.close()
        self.assertEqual(self.exact_tree_snapshot(self.attempt_root), before)

    def test_public_transition_cannot_replace_the_persisted_supervisor(self):
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        replacement = copy.deepcopy(prepared)
        replacement["supervisor"] = {
            "pid": os.getpid(),
            "birthIdentity": "linux:boot-id:forged-recovery",
            "leaseIdentity": lease.identity,
            "role": "recovery",
            "predecessor": command_state.supervisor_fingerprint(
                prepared["supervisor"]
            ),
        }
        before = self.exact_tree_snapshot(self.attempt_root)
        with self.assertRaisesRegex(ValueError, "supervisor"):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                replacement,
                supervisor_lease=lease,
            )
        self.assertEqual(self.exact_tree_snapshot(self.attempt_root), before)

    def test_recovery_owned_transition_requires_the_exact_live_claim(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        prepared = self.prepare_stored_state()
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(),
        )
        self.addCleanup(claim.close)
        failed = supervisor_failure_state("prepared")
        failed.update(
            supervisor=copy.deepcopy(claim.state["supervisor"]),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
        )
        downgraded = command_state.CommandLayoutReservation(
            root=self.attempt_root,
            command_id=COMMAND_ID,
            authority=claim._authority,
            lease_context=claim._lease_context,
            lease=claim._lease,
            group_lease_identity=claim._group_lease_identity,
        )
        before = self.exact_tree_snapshot(self.attempt_root)
        with self.assertRaisesRegex(ValueError, "recovery claim"):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                failed,
                supervisor_lease=downgraded,
            )
        self.assertEqual(self.exact_tree_snapshot(self.attempt_root), before)

        cached = copy.deepcopy(claim._state["supervisor"])
        claim._state["supervisor"]["birthIdentity"] = "tampered"
        with self.assertRaisesRegex(ValueError, "recovery claim"):
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                failed,
                supervisor_lease=claim,
            )
        claim._state["supervisor"] = cached
        self.assertEqual(
            command_state.transition_command_state(
                self.attempt_root,
                SESSION_ID,
                1,
                failed,
                supervisor_lease=claim,
            ),
            failed,
        )

    def test_recovery_materialization_requires_the_supervisor_loss_event(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        anchor_pid = os.getpid() + 1000
        exited = valid_command_state(
            "exited",
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
            child=valid_child(pid=anchor_pid + 1),
        )
        state_path = self.command_root(self.attempt_root) / "state.json"
        state_path.write_bytes(command_state.encode_command_state(exited))
        lease.close()
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(),
        )
        self.addCleanup(claim.close)

        historical = claim.state
        historical.update(
            stage="materialized",
            materialized=valid_materialized(historical["paths"]),
        )
        before = self.exact_tree_snapshot(self.attempt_root)
        with self.assertRaisesRegex(ValueError, "supervisor loss"):
            claim.transition(historical)
        self.assertEqual(self.exact_tree_snapshot(self.attempt_root), before)

        terminal_event = valid_terminal_event(
            historical["paths"],
            status="failed",
            errorCode="runner.command_supervisor_lost",
            summary="Command supervision failed",
        )
        terminal_event.pop("commandStatus")
        recovered = claim.state
        recovered.update(
            stage="materialized",
            materialized=valid_materialized(
                recovered["paths"], terminal_event=terminal_event
            ),
        )
        self.assertEqual(claim.transition(recovered), recovered)

    def test_failed_identity_absence_or_stale_generation_does_not_mutate_or_consume_lease(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        before = self.snapshot(self.attempt_root)
        present = self.recovery_backend(absent=False)
        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=present,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)
        self.assertTrue(any(call[0] == "absent" for call in present.calls))

        malformed = self.recovery_backend(identity=7)
        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=malformed,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)

        stale = self.recovery_backend()
        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                2,
                COMMAND_ID,
                process_backend=stale,
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)
        self.assertEqual(stale.calls, [])

        accepted = self.recovery_backend()
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=accepted,
        )
        self.addCleanup(claim.close)
        self.assertTrue(any(call[0] == "absent" for call in accepted.calls))

    def test_claim_rejects_identical_state_bytes_on_a_new_inode_after_probe(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        state_path = self.command_root(self.attempt_root) / "state.json"
        original = state_path.read_bytes()
        old_metadata = state_path.stat()
        replaced = []

        def race(stage):
            self.assert_mutation_locks_are_free()
            if stage != "absent":
                return
            self.replace_file(state_path, original)
            metadata = state_path.stat()
            self.assertNotEqual(
                (metadata.st_dev, metadata.st_ino),
                (old_metadata.st_dev, old_metadata.st_ino),
            )
            replaced.append((metadata.st_dev, metadata.st_ino))

        backend = self.recovery_backend(hook=race)
        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=backend,
            )
        metadata = state_path.stat()
        self.assertEqual((metadata.st_dev, metadata.st_ino), replaced[0])
        self.assertEqual(state_path.read_bytes(), original)
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )["supervisor"]["role"],
            "launch",
        )

    def test_claim_rejects_identical_session_bytes_on_a_new_inode_after_probe(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        session_path = (
            self.attempt_root / ".evidence-control" / "session.json"
        )
        original = session_path.read_bytes()
        old_metadata = session_path.stat()
        replacements = []

        def race(stage):
            self.assert_mutation_locks_are_free()
            if stage != "absent":
                return
            self.replace_file(session_path, original)
            metadata = session_path.stat()
            identity = (metadata.st_dev, metadata.st_ino)
            self.assertNotEqual(
                identity,
                (old_metadata.st_dev, old_metadata.st_ino),
            )
            replacements.append(
                (
                    identity,
                    session_path.read_bytes(),
                    self.exact_tree_snapshot(self.attempt_root),
                )
            )

        backend = self.recovery_backend(hook=race)
        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=backend,
            )
        self.assertEqual(len(replacements), 1)
        replacement_identity, replacement_content, replacement_tree = (
            replacements[0]
        )
        metadata = session_path.stat()
        self.assertEqual(
            (metadata.st_dev, metadata.st_ino), replacement_identity
        )
        self.assertEqual(session_path.read_bytes(), replacement_content)
        self.assertEqual(replacement_content, original)
        self.assertEqual(
            self.exact_tree_snapshot(self.attempt_root), replacement_tree
        )
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )["supervisor"]["role"],
            "launch",
        )

    def test_claim_rejects_semantic_state_and_session_races_after_probe(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        prepared = self.prepare_stored_state()
        state_path = self.command_root(self.attempt_root) / "state.json"
        raced = copy.deepcopy(prepared)
        raced["startedEvent"]["timestamp"] = "2026-07-11T00:00:01.500Z"
        raced_content = command_state.encode_command_state(raced)

        def mutate_state(stage):
            self.assert_mutation_locks_are_free()
            if stage == "absent":
                state_path.write_bytes(raced_content)

        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=self.recovery_backend(hook=mutate_state),
            )
        self.assertEqual(state_path.read_bytes(), raced_content)
        self.assertEqual(
            command_state.read_command_state(
                self.attempt_root, COMMAND_ID, SESSION_ID
            )["supervisor"]["role"],
            "launch",
        )

        session_path = self.attempt_root / ".evidence-control" / "session.json"
        generation_two = valid_session(
            ownerPid=2234,
            ownerBirthIdentity="linux:boot-id:takeover",
            generation=2,
        )
        generation_two_content = command_state.encode_session(generation_two)

        def mutate_session(stage):
            self.assert_mutation_locks_are_free()
            if stage == "absent":
                session_path.write_bytes(generation_two_content)

        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=self.recovery_backend(hook=mutate_session),
            )
        self.assertEqual(session_path.read_bytes(), generation_two_content)
        self.assertEqual(state_path.read_bytes(), raced_content)

    def test_prepared_claim_requires_the_group_lease_to_be_free(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        group_path = self.command_root(self.attempt_root) / "group.lease"
        before = self.snapshot(self.attempt_root)
        with self.hold_raw_lease(group_path), self.assertRaises(
            (TimeoutError, ValueError)
        ):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=self.recovery_backend(),
            )
        self.assertEqual(self.snapshot(self.attempt_root), before)
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(),
        )
        observer = os.open(
            group_path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
        )
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            claim.close()
            fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(observer, fcntl.LOCK_UN)
        finally:
            os.close(observer)

    def test_two_concurrent_recoverers_cannot_both_claim(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        barrier = threading.Barrier(2)
        results = []
        failures = []
        guard = threading.Lock()

        def recover():
            try:
                barrier.wait(5)
                claim = claim_recovery(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    COMMAND_ID,
                    process_backend=self.recovery_backend(),
                    timeout=0.0,
                )
            except BaseException as exc:
                with guard:
                    failures.append(exc)
            else:
                with guard:
                    results.append(claim)

        threads = [threading.Thread(target=recover) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(len(results), 1)
        self.assertEqual(len(failures), 1)
        self.assertIsInstance(failures[0], (TimeoutError, ValueError))
        results[0].close()

    def test_claim_is_allowed_while_finalizing_but_committed_is_immutable(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.prepare_stored_state()
        command_state.transition_session_state(
            self.attempt_root, SESSION_ID, 1, "finalizing"
        )
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(),
        )
        self.assertEqual(claim.state["supervisor"]["role"], "recovery")
        claim.close()

    def test_committed_command_refuses_recovery_claim_without_process_probes(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        anchor_pid = os.getpid() + 1000
        committed = valid_command_state(
            "committed",
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
            child=valid_child(pid=anchor_pid + 1),
        )
        state_path = self.command_root(self.attempt_root) / "state.json"
        state_path.write_bytes(command_state.encode_command_state(committed))
        lease.close()
        before = self.snapshot(self.attempt_root)
        backend = self.recovery_backend()
        with self.assertRaises(ValueError):
            claim_recovery(
                self.attempt_root,
                SESSION_ID,
                1,
                COMMAND_ID,
                process_backend=backend,
            )
        self.assertEqual(backend.calls, [])
        self.assertEqual(self.snapshot(self.attempt_root), before)

    def test_post_exit_claim_preserves_each_historical_outcome_family(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
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
        group_identity = prepared["anchorReservation"]["groupLeaseIdentity"]
        anchor_pid = os.getpid() + 1000
        launch = copy.deepcopy(prepared["supervisor"])

        normal = valid_command_state(
            "exited",
            supervisor=copy.deepcopy(launch),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
            anchor=valid_anchor(
                pid=anchor_pid,
                sid=anchor_pid,
                pgid=anchor_pid,
                groupLeaseIdentity=group_identity,
            ),
            child=valid_child(pid=anchor_pid + 1),
        )
        signalled = copy.deepcopy(normal)
        signalled["outcome"] = valid_outcome(
            kind="signal",
            exitStatus=None,
            signal=15,
            shellVisibleStatus=143,
        )
        exec_failure = negative_exec_state()
        exec_failure.update(
            supervisor=copy.deepcopy(launch),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
            anchor=valid_anchor(
                pid=anchor_pid,
                sid=anchor_pid,
                pgid=anchor_pid,
                groupLeaseIdentity=group_identity,
            ),
        )
        stopped = stopped_before_ack_state()
        stopped.update(
            supervisor=copy.deepcopy(launch),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
            anchor=valid_anchor(
                pid=anchor_pid,
                sid=anchor_pid,
                pgid=anchor_pid,
                groupLeaseIdentity=group_identity,
            ),
        )
        capture_failed = supervisor_failure_state(
            error_code="runner.capture_failed"
        )
        capture_failed.update(
            supervisor=copy.deepcopy(launch),
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
        )
        lease.close()
        for historical in (
            normal,
            signalled,
            exec_failure,
            stopped,
            capture_failed,
        ):
            state_path.write_bytes(command_state.encode_command_state(historical))
            with self.subTest(kind=historical["outcome"]["kind"]):
                claim = claim_recovery(
                    self.attempt_root,
                    SESSION_ID,
                    1,
                    COMMAND_ID,
                    process_backend=self.recovery_backend(),
                )
                self.assertEqual(claim.state["supervisor"]["role"], "recovery")
                self.assertEqual(
                    claim.state["supervisor"]["predecessor"],
                    command_state.supervisor_fingerprint(launch),
                )
                self.assertEqual(claim.state["outcome"], historical["outcome"])
                self.assertEqual(claim.state["capture"], historical["capture"])
                self.assertIs(
                    claim.state["capture"]["captureComplete"],
                    historical["capture"]["captureComplete"],
                )
                claim.close()

    def test_materialized_claim_preserves_the_frozen_terminal_payload(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        self.initialize()
        lease, prepared = self.reserve_prepared_state()
        command_state.create_command_state(
            self.attempt_root, prepared, supervisor_lease=lease
        )
        anchor_pid = os.getpid() + 1000
        materialized = valid_command_state(
            "materialized",
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
            child=valid_child(pid=anchor_pid + 1),
        )
        frozen = copy.deepcopy(materialized["materialized"])
        state_path = self.command_root(self.attempt_root) / "state.json"
        state_path.write_bytes(command_state.encode_command_state(materialized))
        lease.close()
        claim = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(),
        )
        self.assertEqual(claim.state["materialized"], frozen)
        claim.close()

    def test_repeat_recovery_chains_predecessors_without_rewriting_terminal_truth(self):
        claim_recovery = self.require_recovery_api("claim_command_recovery")
        prepared = self.prepare_stored_state()
        state_path = self.command_root(self.attempt_root) / "state.json"

        first = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(
                identity="linux:boot-id:recovery-one"
            ),
        )
        first_supervisor = copy.deepcopy(first.state["supervisor"])
        first.close()

        exited = supervisor_failure_state()
        exited.update(
            supervisor=first_supervisor,
            anchorReservation=copy.deepcopy(prepared["anchorReservation"]),
        )
        state_path.write_bytes(command_state.encode_command_state(exited))
        historical_outcome = copy.deepcopy(exited["outcome"])
        historical_capture = copy.deepcopy(exited["capture"])
        second = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(
                identity="linux:boot-id:recovery-two"
            ),
        )
        self.assertEqual(
            second.state["supervisor"]["predecessor"],
            command_state.supervisor_fingerprint(first_supervisor),
        )
        self.assertEqual(second.state["outcome"], historical_outcome)
        self.assertEqual(second.state["capture"], historical_capture)
        second_supervisor = copy.deepcopy(second.state["supervisor"])
        second.close()

        terminal_event = valid_terminal_event(
            exited["paths"],
            status="failed",
            errorCode="runner.command_supervisor_lost",
            summary="Command supervision failed",
        )
        terminal_event.pop("commandStatus")
        materialized = copy.deepcopy(exited)
        materialized.update(
            stage="materialized",
            supervisor=second_supervisor,
            materialized=valid_materialized(
                exited["paths"], terminal_event=terminal_event
            ),
        )
        frozen = copy.deepcopy(materialized["materialized"])
        state_path.write_bytes(command_state.encode_command_state(materialized))
        third = claim_recovery(
            self.attempt_root,
            SESSION_ID,
            1,
            COMMAND_ID,
            process_backend=self.recovery_backend(
                identity="linux:boot-id:recovery-three"
            ),
        )
        self.assertEqual(
            third.state["supervisor"]["predecessor"],
            command_state.supervisor_fingerprint(second_supervisor),
        )
        self.assertEqual(third.state["outcome"], historical_outcome)
        self.assertEqual(third.state["capture"], historical_capture)
        self.assertEqual(third.state["materialized"], frozen)
        third.close()


if __name__ == "__main__":
    unittest.main()
