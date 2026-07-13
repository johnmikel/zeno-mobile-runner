"""Bounded private state for durable command supervision.

This module owns only private document contracts and descriptor-rooted storage.
It deliberately has no dependency on lifecycle or command execution code so
recovery and session orchestration can call these primitives without a cycle.
"""

from __future__ import annotations

import copy
import errno
import hashlib
import os
import re
import stat
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator

if os.name == "posix":
    import fcntl

from . import bounded_io, safe_io
from .constants import (
    ERROR_CLASSIFICATION,
    MAX_ACTIVE_COMMANDS,
    MAX_COMMAND_ARGV_BYTES,
    MAX_COMMAND_ARGV_COUNT,
    MAX_COMMAND_ARG_BYTES,
    MAX_COMMAND_STATE_BYTES,
    MAX_SESSION_COMMANDS,
    MAX_SESSION_STATE_BYTES,
    MAX_TERMINAL_INTENT_BYTES,
    MAX_TERMINAL_SECONDARY_DIAGNOSTICS,
    PHASES,
    SUPERVISOR_ONLY_FAILURE_CODES,
    _CLASSIFICATION_PRECEDENCE,
    _COMMAND_SLUG_RE,
    _DIGEST_RE,
    _LOG_LIMIT,
)
from .contracts import _safe_run_segment, _valid_datetime, _valid_relative_path


CONTROL_DIRECTORY_NAME = ".evidence-control"
COMMANDS_LOCK_NAME = ".commands.lock"
SESSION_FILE_NAME = "session.json"
TERMINAL_INTENT_FILE_NAME = "terminal-intent.json"
COMMANDS_DIRECTORY_NAME = "commands"

_SESSION_KEYS = {
    "schemaVersion",
    "sessionId",
    "runId",
    "ownerPid",
    "ownerBirthIdentity",
    "state",
    "generation",
    "startedAt",
}
_TERMINAL_INTENT_KEYS = {
    "schemaVersion",
    "sessionId",
    "nextOrdinal",
    "primary",
    "secondary",
    "droppedCount",
}
_CALLER_DIAGNOSTIC_COMMON_KEYS = {
    "status",
    "classification",
    "phase",
    "commandStatus",
    "source",
}
_CALLER_DIAGNOSTIC_FAILURE_KEYS = {
    "errorCode",
    "summary",
    "hint",
}
_SERVER_DIAGNOSTIC_KEYS = {
    "recordedAt",
    "ordinal",
    "recordedGeneration",
}
_COMMAND_STATE_KEYS = {
    "schemaVersion",
    "commandId",
    "sessionId",
    "creationGeneration",
    "stage",
    "requestFingerprint",
    "request",
    "paths",
    "startedEvent",
    "supervisor",
    "anchorReservation",
    "anchor",
    "child",
    "stopIntent",
    "outcome",
    "capture",
    "materialized",
}
_REQUEST_KEYS = {
    "phase",
    "name",
    "failureCode",
    "failurePolicy",
    "stopPolicy",
    "mode",
    "stdinPolicy",
    "sanitizedArgv",
}
_PATH_KEYS = {"metadata", "stdout", "stderr"}
_STARTED_EVENT_KEYS = {
    "schemaVersion",
    "seq",
    "timestamp",
    "phase",
    "status",
    "command",
}
_SUPERVISOR_KEYS = {
    "pid",
    "birthIdentity",
    "leaseIdentity",
    "role",
    "predecessor",
}
_ANCHOR_RESERVATION_KEYS = {
    "groupLeaseIdentity",
    "controlProtocolVersion",
}
_ANCHOR_KEYS = {
    "pid",
    "birthIdentity",
    "sid",
    "pgid",
    "groupLeaseIdentity",
    "controlProtocolVersion",
}
_CHILD_KEYS = {"pid", "birthIdentity", "execAcknowledgedAt"}
_STOP_INTENT_KEYS = {"kind", "requestedAt", "killAuthorizedAt"}
_OUTCOME_KEYS = {
    "kind",
    "exitStatus",
    "signal",
    "shellVisibleStatus",
    "finishedAt",
}
_EXEC_FAILURE_OUTCOME_KEYS = {
    "kind",
    "exitStatus",
    "signal",
    "shellVisibleStatus",
    "execFailedAt",
}
_SUPERVISOR_FAILURE_OUTCOME_KEYS = {
    "kind",
    "errorCode",
    "exitStatus",
    "signal",
    "shellVisibleStatus",
    "failedAt",
}
_STOPPED_BEFORE_ACK_OUTCOME_KEYS = {
    "kind",
    "requestKind",
    "graceExpired",
    "escalated",
    "shellVisibleStatus",
    "stoppedAt",
}
_CAPTURE_KEYS = {"captureComplete", "stdout", "stderr"}
_STREAM_KEYS = {
    "originalBytes",
    "sanitizedBytes",
    "storedBytes",
    "truncated",
}
_MATERIALIZED_KEYS = {"metadata", "stdout", "stderr", "terminalEvent"}
_FILE_BINDING_KEYS = {"path", "bytes", "sha256"}
_EVENT_BINDING_KEYS = {"seq", "bytes", "sha256"}
_STAGES = (
    "prepared",
    "anchored",
    "anchor_stop_requested",
    "running",
    "stop_requested",
    "exited",
    "materialized",
    "committed",
)
_SESSION_ID_RE = re.compile(r"^[0-9a-f]{32}$")
_LEASE_IDENTITY_RE = re.compile(r"^(0|[1-9][0-9]*):(0|[1-9][0-9]*)$")
_MAX_TEXT_BYTES = 4096
_MAX_IDENTITY_BYTES = 4096
_MAX_COUNTER = (1 << 63) - 1
_CLASSIFICATION_RANK = {
    classification: index
    for index, classification in enumerate(_CLASSIFICATION_PRECEDENCE)
}
_CLASSIFICATION_RANK["passed"] = len(_CLASSIFICATION_RANK)
_EVIDENCE_CONTROL_ERROR_CODES = {
    "runner.evidence_invalid",
    "runner.command_supervisor_lost",
    "runner.capture_failed",
}


def _closed_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if type(value) is not dict or set(value) != keys:
        raise ValueError(f"{label} has an invalid object shape")
    return value


def _integer(
    value: Any,
    label: str,
    *,
    minimum: int = 0,
    maximum: int = _MAX_COUNTER,
) -> int:
    if type(value) is not int or value < minimum or value > maximum:
        raise ValueError(f"{label} is not a bounded integer")
    return value


def _text(
    value: Any,
    label: str,
    *,
    maximum: int = _MAX_TEXT_BYTES,
) -> str:
    if type(value) is not str or not value:
        raise ValueError(f"{label} must be a non-empty string")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{label} must contain valid UTF-8") from exc
    if len(encoded) > maximum:
        raise ValueError(f"{label} exceeds {maximum} bytes")
    if any(
        ord(character) <= 0x1F
        or ord(character) == 0x7F
        or 0xD800 <= ord(character) <= 0xDFFF
        for character in value
    ):
        raise ValueError(f"{label} contains an unsafe character")
    return value


def _identifier(value: Any, label: str) -> str:
    if type(value) is not str or _SESSION_ID_RE.fullmatch(value) is None:
        raise ValueError(f"{label} must be 32 lowercase hexadecimal characters")
    return value


def _digest(value: Any, label: str) -> str:
    if type(value) is not str or _DIGEST_RE.fullmatch(value) is None:
        raise ValueError(f"{label} must be a SHA-256 digest")
    return value


def _lease_identity(value: Any, label: str) -> str:
    identity = _text(value, label, maximum=256)
    match = _LEASE_IDENTITY_RE.fullmatch(identity)
    if match is None or any(int(component) > (1 << 64) - 1 for component in match.groups()):
        raise ValueError(f"{label} must be a canonical dev:ino identity")
    return identity


def _utc_timestamp(value: Any, label: str) -> str:
    if type(value) is not str or not value.lower().endswith("z") or not _valid_datetime(value):
        raise ValueError(f"{label} must be an RFC3339 UTC timestamp")
    return value


def _canonical_content(value: Any, maximum: int, label: str) -> bytes:
    encoded = bounded_io._json_bytes_bounded(value, maximum=maximum, label=label)
    if not encoded.endswith(b"\n"):
        raise RuntimeError("canonical JSON must end with a newline")
    return encoded[:-1]


def _canonical_digest(value: Any, maximum: int, label: str) -> str:
    return "sha256:" + hashlib.sha256(
        _canonical_content(value, maximum, label)
    ).hexdigest()


def validate_session(
    value: Any, *, expected_session_id: str | None = None
) -> dict[str, Any]:
    """Validate one exact ``session.json`` document."""

    session = _closed_object(value, _SESSION_KEYS, "session state")
    if session["schemaVersion"] != 1 or type(session["schemaVersion"]) is not int:
        raise ValueError("session schemaVersion must equal 1")
    session_id = _identifier(session["sessionId"], "sessionId")
    if expected_session_id is not None and session_id != _identifier(
        expected_session_id, "expected sessionId"
    ):
        raise ValueError("sessionId does not match the expected session")
    _text(session["runId"], "session runId", maximum=128)
    if not _safe_run_segment(session["runId"]):
        raise ValueError("session runId is not a safe attempt segment")
    _integer(session["ownerPid"], "session ownerPid", minimum=1)
    _text(
        session["ownerBirthIdentity"],
        "session ownerBirthIdentity",
        maximum=_MAX_IDENTITY_BYTES,
    )
    if session["state"] not in ("active", "finalizing", "committed"):
        raise ValueError("session state is invalid")
    _integer(session["generation"], "session generation", minimum=1)
    _utc_timestamp(session["startedAt"], "session startedAt")
    return session


def encode_session(value: Any) -> bytes:
    session = validate_session(value)
    return bounded_io._json_bytes_bounded(
        session,
        maximum=MAX_SESSION_STATE_BYTES,
        label="session state",
    )


def make_terminal_intent(session_id: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "sessionId": _identifier(session_id, "sessionId"),
        "nextOrdinal": 1,
        "primary": None,
        "secondary": [],
        "droppedCount": 0,
    }


def _diagnostic_fields(value: dict[str, Any]) -> set[str]:
    return set(value) - _SERVER_DIAGNOSTIC_KEYS


def _validate_diagnostic_semantics(
    diagnostic: dict[str, Any], *, persisted: bool
) -> dict[str, Any]:
    expected = set(_CALLER_DIAGNOSTIC_COMMON_KEYS)
    if diagnostic.get("status") != "passed":
        expected.update(_CALLER_DIAGNOSTIC_FAILURE_KEYS)
    if persisted:
        expected.update(_SERVER_DIAGNOSTIC_KEYS)
    _closed_object(diagnostic, expected, "terminal diagnostic")
    status = diagnostic["status"]
    classification = diagnostic["classification"]
    if type(status) is not str or status not in ("passed", "failed", "cancelled"):
        raise ValueError("terminal diagnostic status is invalid")
    if type(classification) is not str or classification not in _CLASSIFICATION_RANK:
        raise ValueError("terminal diagnostic classification is invalid")
    if status == "passed":
        if classification != "passed":
            raise ValueError("passed diagnostic must use passed classification")
    else:
        error_code = _text(
            diagnostic["errorCode"], "terminal diagnostic errorCode", maximum=256
        )
        if error_code not in ERROR_CLASSIFICATION:
            raise ValueError("terminal diagnostic errorCode is not registered")
        if ERROR_CLASSIFICATION[error_code] != classification:
            raise ValueError("terminal diagnostic classification disagrees with errorCode")
        if status == "cancelled" and classification != "cancelled":
            raise ValueError("cancelled diagnostic must use cancelled classification")
        if status == "failed" and classification in ("cancelled", "passed"):
            raise ValueError("failed diagnostic classification is invalid")
        _text(
            diagnostic["summary"],
            "terminal diagnostic summary",
            maximum=512,
        )
        _text(
            diagnostic["hint"],
            "terminal diagnostic hint",
            maximum=512,
        )
    if diagnostic["phase"] not in PHASES:
        raise ValueError("terminal diagnostic phase is invalid")
    command_status = diagnostic["commandStatus"]
    if command_status is not None:
        _integer(command_status, "terminal diagnostic commandStatus", maximum=255)
    _text(diagnostic["source"], "terminal diagnostic source", maximum=256)
    if persisted:
        _utc_timestamp(diagnostic["recordedAt"], "terminal diagnostic recordedAt")
        _integer(diagnostic["ordinal"], "terminal diagnostic ordinal", minimum=1)
        _integer(
            diagnostic["recordedGeneration"],
            "terminal diagnostic recordedGeneration",
            minimum=1,
        )
    return diagnostic


def validate_caller_diagnostic(value: Any) -> dict[str, Any]:
    if type(value) is not dict:
        raise ValueError("terminal diagnostic has an invalid object shape")
    return _validate_diagnostic_semantics(value, persisted=False)


def _diagnostic_key(diagnostic: dict[str, Any]) -> bytes:
    caller = {
        key: diagnostic[key]
        for key in sorted(_diagnostic_fields(diagnostic))
    }
    return _canonical_content(caller, MAX_TERMINAL_INTENT_BYTES, "terminal diagnostic")


def _diagnostic_order(diagnostic: dict[str, Any]) -> tuple[int, int, int]:
    """Return the server-owned resolution order for one retained diagnostic."""

    status = diagnostic["status"]
    error_code = diagnostic.get("errorCode")
    if error_code in _EVIDENCE_CONTROL_ERROR_CODES:
        tier = 1
    elif error_code == "runner.cleanup_failed":
        tier = 2
    elif status == "cancelled" or diagnostic["classification"] == "cancelled":
        tier = 4
    elif error_code == "runner.unclassified":
        tier = 5
    elif status == "passed":
        tier = 6
    else:
        tier = 3
    classification_rank = (
        _CLASSIFICATION_RANK[diagnostic["classification"]] if tier == 3 else 0
    )
    return tier, classification_rank, diagnostic["ordinal"]


def validate_terminal_intent(
    value: Any,
    *,
    expected_session_id: str | None = None,
    maximum_recorded_generation: int | None = None,
) -> dict[str, Any]:
    """Validate one exact, session-bound ``terminal-intent.json`` document."""

    intent = _closed_object(value, _TERMINAL_INTENT_KEYS, "terminal intent")
    if intent["schemaVersion"] != 1 or type(intent["schemaVersion"]) is not int:
        raise ValueError("terminal intent schemaVersion must equal 1")
    session_id = _identifier(intent["sessionId"], "terminal intent sessionId")
    if expected_session_id is not None and session_id != _identifier(
        expected_session_id, "expected sessionId"
    ):
        raise ValueError("terminal intent sessionId does not match")
    next_ordinal = _integer(
        intent["nextOrdinal"], "terminal intent nextOrdinal", minimum=1
    )
    _integer(intent["droppedCount"], "terminal intent droppedCount")
    if type(intent["secondary"]) is not list:
        raise ValueError("terminal intent secondary must be an array")
    if len(intent["secondary"]) > MAX_TERMINAL_SECONDARY_DIAGNOSTICS:
        raise ValueError("terminal intent has too many secondary diagnostics")
    if intent["primary"] is None:
        if intent["secondary"]:
            raise ValueError("terminal intent cannot have secondary without primary")
        if next_ordinal != 1 or intent["droppedCount"] != 0:
            raise ValueError("empty terminal intent must be the initial state")
        retained: list[dict[str, Any]] = []
    else:
        if type(intent["primary"]) is not dict:
            raise ValueError("terminal intent primary must be null or an object")
        retained = [intent["primary"], *intent["secondary"]]
    keys: set[bytes] = set()
    ordinals: set[int] = set()
    for diagnostic in retained:
        if type(diagnostic) is not dict:
            raise ValueError("terminal intent diagnostic must be an object")
        _validate_diagnostic_semantics(diagnostic, persisted=True)
        semantic_key = _diagnostic_key(diagnostic)
        if semantic_key in keys:
            raise ValueError("terminal intent contains a retained duplicate")
        keys.add(semantic_key)
        ordinal = diagnostic["ordinal"]
        if ordinal in ordinals or ordinal >= next_ordinal:
            raise ValueError("terminal intent ordinal is invalid")
        ordinals.add(ordinal)
        if (
            maximum_recorded_generation is not None
            and diagnostic["recordedGeneration"]
            > _integer(
                maximum_recorded_generation,
                "maximum recorded generation",
                minimum=1,
            )
        ):
            raise ValueError(
                "terminal diagnostic recordedGeneration exceeds session generation"
            )
    if retained != sorted(retained, key=_diagnostic_order):
        raise ValueError("terminal intent retained diagnostics are out of order")
    if intent["droppedCount"] != next_ordinal - 1 - len(retained):
        raise ValueError("terminal intent counters are inconsistent")
    return intent


def encode_terminal_intent(value: Any) -> bytes:
    intent = validate_terminal_intent(value)
    return bounded_io._json_bytes_bounded(
        intent,
        maximum=MAX_TERMINAL_INTENT_BYTES,
        label="terminal intent",
    )


def _validate_request(value: Any) -> dict[str, Any]:
    request = _closed_object(value, _REQUEST_KEYS, "command request")
    if type(request["phase"]) is not str or request["phase"] not in PHASES:
        raise ValueError("command request phase is invalid")
    if type(request["name"]) is not str or _COMMAND_SLUG_RE.fullmatch(request["name"]) is None:
        raise ValueError("command request name is invalid")
    failure_code = _text(
        request["failureCode"], "command request failureCode", maximum=256
    )
    if failure_code not in ERROR_CLASSIFICATION:
        raise ValueError("command request failureCode is not registered")
    if failure_code in SUPERVISOR_ONLY_FAILURE_CODES:
        raise ValueError("command request failureCode is supervisor-owned")
    if request["failurePolicy"] not in ("terminal", "handled"):
        raise ValueError("command request failurePolicy is invalid")
    if request["stopPolicy"] not in ("none", "expected-term"):
        raise ValueError("command request stopPolicy is invalid")
    if request["mode"] not in (
        "foreground",
        "background",
        "capture-stdout",
        "capture-both",
    ):
        raise ValueError("command request mode is invalid")
    if request["stdinPolicy"] not in ("devnull", "inherit"):
        raise ValueError("command request stdinPolicy is invalid")
    if request["mode"] == "background" and request["stdinPolicy"] != "devnull":
        raise ValueError("background command request must use devnull stdin")
    argv = request["sanitizedArgv"]
    if type(argv) is not list or not argv or len(argv) > MAX_COMMAND_ARGV_COUNT:
        raise ValueError("command request sanitizedArgv has an invalid count")
    aggregate = 0
    for argument in argv:
        if type(argument) is not str:
            raise ValueError("command request sanitizedArgv must contain strings")
        try:
            encoded = argument.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise ValueError("command request argument is not valid UTF-8") from exc
        if (
            len(encoded) > MAX_COMMAND_ARG_BYTES
            or any(
                ord(character) <= 0x1F
                or ord(character) == 0x7F
                or 0xD800 <= ord(character) <= 0xDFFF
                for character in argument
            )
        ):
            raise ValueError("command request argument is unsafe or oversized")
        aggregate += len(encoded)
        if aggregate > MAX_COMMAND_ARGV_BYTES:
            raise ValueError("command request sanitizedArgv exceeds its aggregate limit")
    return request


def _validate_paths(value: Any) -> dict[str, str]:
    paths = _closed_object(value, _PATH_KEYS, "command paths")
    observed: set[str] = set()
    for name in sorted(_PATH_KEYS):
        path = paths[name]
        if not _valid_relative_path(path):
            raise ValueError(f"command {name} path is not normalized and relative")
        _text(path, f"command {name} path", maximum=1024)
        parts = path.split("/")
        if len(parts) != 2 or parts[0] != "commands" or parts[1].startswith("."):
            raise ValueError(f"command {name} path must be a direct commands/ target")
        required_suffix = {
            "metadata": ".json",
            "stdout": ".stdout.log",
            "stderr": ".stderr.log",
        }[name]
        if not parts[1].endswith(required_suffix):
            raise ValueError(f"command {name} path has an invalid suffix")
        if path in observed:
            raise ValueError("command paths must be distinct")
        observed.add(path)
    metadata_stem = paths["metadata"][: -len(".json")]
    stdout_stem = paths["stdout"][: -len(".stdout.log")]
    stderr_stem = paths["stderr"][: -len(".stderr.log")]
    if metadata_stem != stdout_stem or metadata_stem != stderr_stem:
        raise ValueError("command output paths must share one command-owned stem")
    return paths


def request_fingerprint(
    session_id: str,
    creation_generation: int,
    request: Any,
    paths: Any,
) -> str:
    """Hash exactly the immutable, canonical persisted command request."""

    payload = {
        "sessionId": _identifier(session_id, "sessionId"),
        "creationGeneration": _integer(
            creation_generation, "creationGeneration", minimum=1
        ),
        "request": _validate_request(request),
        "paths": _validate_paths(paths),
    }
    return _canonical_digest(
        payload,
        MAX_COMMAND_STATE_BYTES + MAX_COMMAND_ARGV_BYTES + 16 * 1024,
        "command request",
    )


def _validate_started_event(
    value: Any, request: dict[str, Any], paths: dict[str, str]
) -> dict[str, Any]:
    event = _closed_object(value, _STARTED_EVENT_KEYS, "command startedEvent")
    if event["schemaVersion"] != 1 or type(event["schemaVersion"]) is not int:
        raise ValueError("command startedEvent schemaVersion must equal 1")
    _integer(event["seq"], "command startedEvent seq", minimum=1)
    _utc_timestamp(event["timestamp"], "command startedEvent timestamp")
    if event["phase"] != request["phase"]:
        raise ValueError("command startedEvent phase disagrees with request")
    if event["status"] != "started":
        raise ValueError("command startedEvent status must be started")
    if event["command"] != paths["metadata"]:
        raise ValueError("command startedEvent command disagrees with metadata path")
    return event


def _validate_supervisor(value: Any) -> dict[str, Any]:
    supervisor = _closed_object(value, _SUPERVISOR_KEYS, "command supervisor")
    _integer(supervisor["pid"], "command supervisor pid", minimum=1)
    _text(
        supervisor["birthIdentity"],
        "command supervisor birthIdentity",
        maximum=_MAX_IDENTITY_BYTES,
    )
    _lease_identity(
        supervisor["leaseIdentity"],
        "command supervisor leaseIdentity",
    )
    if supervisor["role"] not in ("launch", "recovery"):
        raise ValueError("command supervisor role is invalid")
    predecessor = supervisor["predecessor"]
    if predecessor is not None:
        _digest(predecessor, "command supervisor predecessor")
    if supervisor["role"] == "launch" and predecessor is not None:
        raise ValueError("launch supervisor predecessor must be null")
    if supervisor["role"] == "recovery" and predecessor is None:
        raise ValueError("recovery supervisor predecessor must be a digest")
    return supervisor


def supervisor_fingerprint(value: Any) -> str:
    supervisor = _validate_supervisor(value)
    return _canonical_digest(supervisor, 16 * 1024, "command supervisor")


def _validate_anchor_reservation(value: Any) -> dict[str, Any]:
    reservation = _closed_object(
        value, _ANCHOR_RESERVATION_KEYS, "command anchorReservation"
    )
    _lease_identity(
        reservation["groupLeaseIdentity"],
        "command anchorReservation groupLeaseIdentity",
    )
    if (
        reservation["controlProtocolVersion"] != 1
        or type(reservation["controlProtocolVersion"]) is not int
    ):
        raise ValueError(
            "command anchorReservation controlProtocolVersion must equal 1"
        )
    return reservation


def _validate_anchor(value: Any) -> dict[str, Any]:
    anchor = _closed_object(value, _ANCHOR_KEYS, "command anchor")
    pid = _integer(anchor["pid"], "command anchor pid", minimum=1)
    _text(
        anchor["birthIdentity"],
        "command anchor birthIdentity",
        maximum=_MAX_IDENTITY_BYTES,
    )
    sid = _integer(anchor["sid"], "command anchor sid", minimum=1)
    pgid = _integer(anchor["pgid"], "command anchor pgid", minimum=1)
    if pid != sid or pid != pgid:
        raise ValueError("command anchor pid, sid, and pgid must be equal")
    _lease_identity(
        anchor["groupLeaseIdentity"],
        "command anchor groupLeaseIdentity",
    )
    if anchor["controlProtocolVersion"] != 1 or type(anchor["controlProtocolVersion"]) is not int:
        raise ValueError("command anchor controlProtocolVersion must equal 1")
    return anchor


def _validate_child(value: Any) -> dict[str, Any]:
    child = _closed_object(value, _CHILD_KEYS, "command child")
    _integer(child["pid"], "command child pid", minimum=1)
    _text(
        child["birthIdentity"],
        "command child birthIdentity",
        maximum=_MAX_IDENTITY_BYTES,
    )
    _utc_timestamp(child["execAcknowledgedAt"], "command child execAcknowledgedAt")
    return child


def _validate_stop_intent(value: Any) -> dict[str, Any]:
    intent = _closed_object(value, _STOP_INTENT_KEYS, "command stopIntent")
    if intent["kind"] not in ("expected", "cancel"):
        raise ValueError("command stopIntent kind is invalid")
    requested_at = _utc_timestamp(
        intent["requestedAt"], "command stopIntent requestedAt"
    )
    kill_authorized_at = intent["killAuthorizedAt"]
    if kill_authorized_at is not None:
        _utc_timestamp(
            kill_authorized_at, "command stopIntent killAuthorizedAt"
        )
        try:
            requested_time = datetime.fromisoformat(
                requested_at[:-1] + "+00:00"
            )
            authorized_time = datetime.fromisoformat(
                kill_authorized_at[:-1] + "+00:00"
            )
        except ValueError as exc:
            raise ValueError("command stopIntent timestamps are not orderable") from exc
        if authorized_time < requested_time:
            raise ValueError("command kill authorization precedes stop request")
    return intent


def _validate_normal_outcome(
    value: Any, stop_intent: dict[str, Any] | None
) -> dict[str, Any]:
    outcome = _closed_object(value, _OUTCOME_KEYS, "command outcome")
    kind = outcome["kind"]
    shell_status = _integer(
        outcome["shellVisibleStatus"], "command outcome shellVisibleStatus", maximum=255
    )
    if kind == "exit":
        exit_status = _integer(
            outcome["exitStatus"], "command outcome exitStatus", maximum=255
        )
        if outcome["signal"] is not None:
            raise ValueError("exit outcome has inconsistent status fields")
        natural_status = exit_status
    elif kind == "signal":
        signal_number = _integer(
            outcome["signal"], "command outcome signal", minimum=1, maximum=127
        )
        if outcome["exitStatus"] is not None:
            raise ValueError("signal outcome has inconsistent status fields")
        natural_status = 128 + signal_number
    else:
        raise ValueError("command outcome kind is invalid")
    if stop_intent is None:
        expected_shell_status = natural_status
    elif stop_intent["killAuthorizedAt"] is not None:
        expected_shell_status = 125
    elif stop_intent["kind"] == "expected":
        expected_shell_status = 0
    else:
        expected_shell_status = 130
    if shell_status != expected_shell_status:
        raise ValueError("command outcome shellVisibleStatus disagrees with stop state")
    _utc_timestamp(outcome["finishedAt"], "command outcome finishedAt")
    return outcome


def _validate_exec_failure_outcome(value: Any) -> dict[str, Any]:
    outcome = _closed_object(
        value, _EXEC_FAILURE_OUTCOME_KEYS, "command exec-failure outcome"
    )
    if (
        outcome["kind"] != "exec_failure"
        or outcome["exitStatus"] != 127
        or type(outcome["exitStatus"]) is not int
        or outcome["signal"] is not None
        or outcome["shellVisibleStatus"] != 127
        or type(outcome["shellVisibleStatus"]) is not int
    ):
        raise ValueError("command exec-failure outcome is not exact")
    _utc_timestamp(outcome["execFailedAt"], "command outcome execFailedAt")
    return outcome


def _validate_supervisor_failure_outcome(value: Any) -> dict[str, Any]:
    outcome = _closed_object(
        value,
        _SUPERVISOR_FAILURE_OUTCOME_KEYS,
        "command supervisor-failure outcome",
    )
    if (
        outcome["kind"] != "supervisor_failure"
        or outcome["errorCode"]
        not in ("runner.command_supervisor_lost", "runner.capture_failed")
        or outcome["exitStatus"] is not None
        or outcome["signal"] is not None
        or outcome["shellVisibleStatus"] != 125
        or type(outcome["shellVisibleStatus"]) is not int
    ):
        raise ValueError("command supervisor-failure outcome is not exact")
    _utc_timestamp(outcome["failedAt"], "command outcome failedAt")
    return outcome


def _validate_stopped_before_ack_outcome(
    value: Any, stop_intent: dict[str, Any]
) -> dict[str, Any]:
    outcome = _closed_object(
        value,
        _STOPPED_BEFORE_ACK_OUTCOME_KEYS,
        "command stopped-before-ack outcome",
    )
    if outcome["kind"] != "stopped_before_ack":
        raise ValueError("command stopped-before-ack outcome is not exact")
    request_kind = outcome["requestKind"]
    if request_kind not in ("expected", "cancel") or request_kind != stop_intent["kind"]:
        raise ValueError("stopped-before-ack requestKind disagrees with stop intent")
    if type(outcome["graceExpired"]) is not bool or type(outcome["escalated"]) is not bool:
        raise ValueError("stopped-before-ack escalation flags must be booleans")
    if stop_intent["killAuthorizedAt"] is None:
        expected_grace_expired = False
        expected_escalated = False
        expected_status = 0 if request_kind == "expected" else 130
    else:
        expected_grace_expired = True
        expected_escalated = True
        expected_status = 125
    exact_union = (
        outcome["graceExpired"] is expected_grace_expired
        and outcome["escalated"] is expected_escalated
        and outcome["shellVisibleStatus"] == expected_status
        and type(outcome["shellVisibleStatus"]) is int
    )
    if not exact_union:
        raise ValueError("stopped-before-ack outcome has an invalid escalation union")
    _utc_timestamp(outcome["stoppedAt"], "command outcome stoppedAt")
    return outcome


def _validate_stream(value: Any, label: str) -> dict[str, Any]:
    stream = _closed_object(value, _STREAM_KEYS, label)
    original = _integer(stream["originalBytes"], f"{label} originalBytes")
    sanitized = _integer(stream["sanitizedBytes"], f"{label} sanitizedBytes")
    stored = _integer(
        stream["storedBytes"], f"{label} storedBytes", maximum=_LOG_LIMIT
    )
    if type(stream["truncated"]) is not bool:
        raise ValueError(f"{label} truncated must be a boolean")
    if stored > sanitized:
        raise ValueError(f"{label} storedBytes exceeds sanitizedBytes")
    if not stream["truncated"] and stored != sanitized:
        raise ValueError(f"{label} complete storage count is inconsistent")
    if original < 0:
        raise ValueError(f"{label} originalBytes is invalid")
    return stream


def _validate_capture(value: Any) -> dict[str, Any]:
    capture = _closed_object(value, _CAPTURE_KEYS, "command capture")
    if type(capture["captureComplete"]) is not bool:
        raise ValueError("command captureComplete must be a boolean")
    stdout = _validate_stream(capture["stdout"], "command stdout capture")
    stderr = _validate_stream(capture["stderr"], "command stderr capture")
    if not capture["captureComplete"] and not (
        stdout["truncated"] and stderr["truncated"]
    ):
        raise ValueError("incomplete capture streams must be marked truncated")
    return capture


def _validate_negative_exec_capture(value: Any) -> dict[str, Any]:
    capture = _validate_capture(value)
    stdout = capture["stdout"]
    stderr = capture["stderr"]
    if capture["captureComplete"] is not True:
        raise ValueError("negative exec capture must be complete")
    if stdout != {
        "originalBytes": 0,
        "sanitizedBytes": 0,
        "storedBytes": 0,
        "truncated": False,
    }:
        raise ValueError("negative exec stdout capture must be exactly empty")
    if stderr["truncated"] is not False or stderr["storedBytes"] != stderr["sanitizedBytes"]:
        raise ValueError("negative exec stderr capture must be complete")
    return capture


def _validate_materialized(
    value: Any,
    paths: dict[str, str],
    started_event: dict[str, Any],
    capture: dict[str, Any],
) -> dict[str, Any]:
    materialized = _closed_object(value, _MATERIALIZED_KEYS, "command materialized")
    for name in ("metadata", "stdout", "stderr"):
        binding = _closed_object(
            materialized[name], _FILE_BINDING_KEYS, f"command {name} binding"
        )
        if binding["path"] != paths[name]:
            raise ValueError(f"command {name} binding path disagrees with request")
        _integer(binding["bytes"], f"command {name} binding bytes")
        _digest(binding["sha256"], f"command {name} binding sha256")
        if name in ("stdout", "stderr") and binding["bytes"] != capture[name][
            "storedBytes"
        ]:
            raise ValueError(f"command {name} binding bytes disagree with capture")
    event = _closed_object(
        materialized["terminalEvent"],
        _EVENT_BINDING_KEYS,
        "command terminal event binding",
    )
    sequence = _integer(event["seq"], "command terminal event seq", minimum=1)
    if sequence <= started_event["seq"]:
        raise ValueError("command terminal event must follow its started event")
    _integer(event["bytes"], "command terminal event bytes", minimum=1)
    _digest(event["sha256"], "command terminal event sha256")
    return materialized


def _validate_stage_shape(state: dict[str, Any]) -> None:
    stage = state["stage"]
    supervisor = state["supervisor"]
    reservation = state["anchorReservation"]
    anchor = state["anchor"]
    child = state["child"]
    stop_intent = state["stopIntent"]
    outcome = state["outcome"]
    capture = state["capture"]
    materialized = state["materialized"]
    if supervisor is None:
        raise ValueError("command supervisor must be non-null")
    _validate_supervisor(supervisor)
    _validate_anchor_reservation(reservation)
    if anchor is not None:
        _validate_anchor(anchor)
        if (
            anchor["groupLeaseIdentity"] != reservation["groupLeaseIdentity"]
            or anchor["controlProtocolVersion"]
            != reservation["controlProtocolVersion"]
        ):
            raise ValueError("command anchor disagrees with its reservation")
    if child is not None:
        _validate_child(child)
    if stop_intent is not None:
        _validate_stop_intent(stop_intent)
        if (
            stop_intent["kind"] == "expected"
            and state["request"]["stopPolicy"] != "expected-term"
        ):
            raise ValueError("expected stop intent requires expected-term policy")

    if stage == "prepared":
        if any(
            value is not None
            for value in (anchor, child, stop_intent, outcome, capture, materialized)
        ):
            raise ValueError("prepared command has an illegal non-null field")
    elif stage == "anchored":
        if anchor is None or any(
            value is not None
            for value in (child, stop_intent, outcome, capture, materialized)
        ):
            raise ValueError("anchored command has an illegal null combination")
    elif stage == "anchor_stop_requested":
        if anchor is None or stop_intent is None or any(
            value is not None for value in (child, outcome, capture, materialized)
        ):
            raise ValueError(
                "anchor_stop_requested command has an illegal null combination"
            )
    elif stage == "running":
        if child is None or any(
            value is not None for value in (stop_intent, outcome, capture, materialized)
        ) or anchor is None:
            raise ValueError("running command has an illegal null combination")
    elif stage == "stop_requested":
        if child is None or stop_intent is None or any(
            value is not None for value in (outcome, capture, materialized)
        ) or anchor is None:
            raise ValueError("stop_requested command has an illegal null combination")
    else:
        if outcome is None or capture is None:
            raise ValueError("exited command must retain outcome and capture")
        if type(outcome) is not dict:
            raise ValueError("command outcome must be an object")
        outcome_kind = outcome.get("kind")
        if outcome_kind == "exec_failure":
            if anchor is None or child is not None or stop_intent is not None:
                raise ValueError("negative exec handshake has invalid identities")
            if supervisor["role"] != "launch" or supervisor["predecessor"] is not None:
                raise ValueError("negative exec handshake requires its launch supervisor")
            _validate_exec_failure_outcome(outcome)
            _validate_negative_exec_capture(capture)
        elif outcome_kind == "stopped_before_ack":
            if anchor is None or child is not None or stop_intent is None:
                raise ValueError("stopped-before-ack has invalid identities")
            if supervisor["role"] != "launch" or supervisor["predecessor"] is not None:
                raise ValueError(
                    "stopped-before-ack requires its launch supervisor"
                )
            _validate_stopped_before_ack_outcome(outcome, stop_intent)
            stopped_capture = _validate_capture(capture)
            if stopped_capture["captureComplete"] is not True:
                raise ValueError("stopped-before-ack capture must be complete")
        elif outcome_kind == "supervisor_failure":
            failure = _validate_supervisor_failure_outcome(outcome)
            allowed_identities = {
                (False, False, False),
                (True, False, False),
                (True, False, True),
                (True, True, False),
                (True, True, True),
            }
            identity_shape = (
                anchor is not None,
                child is not None,
                stop_intent is not None,
            )
            if identity_shape not in allowed_identities:
                raise ValueError("supervisor failure has invalid retained identities")
            if (
                failure["errorCode"] == "runner.command_supervisor_lost"
                and (
                    supervisor["role"] != "recovery"
                    or supervisor["predecessor"] is None
                )
            ):
                raise ValueError(
                    "supervisor-lost outcome requires its recovery supervisor"
                )
            failure_capture = _validate_capture(capture)
            if failure_capture["captureComplete"] is not False:
                raise ValueError("supervisor failure capture must be incomplete")
        else:
            if anchor is None or child is None:
                raise ValueError("normal outcome requires anchor and child identities")
            if supervisor["role"] != "launch" or supervisor["predecessor"] is not None:
                raise ValueError("normal outcome requires its launch supervisor")
            _validate_normal_outcome(outcome, stop_intent)
            normal_capture = _validate_capture(capture)
            if normal_capture["captureComplete"] is not True:
                raise ValueError("normal outcome capture must be complete")
        if stage == "exited":
            if materialized is not None:
                raise ValueError("exited command cannot already be materialized")
        else:
            if materialized is None:
                raise ValueError("materialized command must retain output bindings")
            _validate_materialized(
                materialized,
                state["paths"],
                state["startedEvent"],
                capture,
            )
    pids = [supervisor["pid"]]
    if anchor is not None:
        pids.append(anchor["pid"])
    if child is not None:
        pids.append(child["pid"])
    if len(pids) != len(set(pids)):
        raise ValueError("command process identities must use distinct PIDs")


def validate_command_state(
    value: Any,
    *,
    expected_command_id: str | None = None,
    expected_session_id: str | None = None,
) -> dict[str, Any]:
    """Validate one exact command state and recompute its fingerprint."""

    state = _closed_object(value, _COMMAND_STATE_KEYS, "command state")
    if state["schemaVersion"] != 1 or type(state["schemaVersion"]) is not int:
        raise ValueError("command state schemaVersion must equal 1")
    command_id = _identifier(state["commandId"], "commandId")
    session_id = _identifier(state["sessionId"], "command sessionId")
    if expected_command_id is not None and command_id != _identifier(
        expected_command_id, "expected commandId"
    ):
        raise ValueError("commandId does not match the command directory")
    if expected_session_id is not None and session_id != _identifier(
        expected_session_id, "expected sessionId"
    ):
        raise ValueError("command sessionId does not match the session")
    creation_generation = _integer(
        state["creationGeneration"], "command creationGeneration", minimum=1
    )
    if state["stage"] not in _STAGES:
        raise ValueError("command stage is invalid")
    request = _validate_request(state["request"])
    paths = _validate_paths(state["paths"])
    expected_fingerprint = request_fingerprint(
        session_id, creation_generation, request, paths
    )
    if state["requestFingerprint"] != expected_fingerprint:
        raise ValueError("command requestFingerprint does not match persisted request")
    _validate_started_event(state["startedEvent"], request, paths)
    _validate_stage_shape(state)
    return state


def encode_command_state(value: Any) -> bytes:
    state = validate_command_state(value)
    return bounded_io._json_bytes_bounded(
        state,
        maximum=MAX_COMMAND_STATE_BYTES,
        label="command state",
    )


def _without(value: dict[str, Any], names: set[str]) -> dict[str, Any]:
    return {key: member for key, member in value.items() if key not in names}


def validate_command_transition(
    previous: Any,
    candidate: Any,
    *,
    session_id: str,
    generation: int,
) -> dict[str, Any]:
    """Validate one monotonic state transition under current session authority."""

    expected_session = _identifier(session_id, "sessionId")
    current_generation = _integer(generation, "session generation", minimum=1)
    before = validate_command_state(previous, expected_session_id=expected_session)
    after = validate_command_state(
        candidate,
        expected_command_id=before["commandId"],
        expected_session_id=expected_session,
    )
    if before["creationGeneration"] > current_generation:
        raise ValueError("command creationGeneration exceeds current session generation")
    if after["creationGeneration"] > current_generation:
        raise ValueError("command creationGeneration exceeds current session generation")
    immutable = {
        "schemaVersion",
        "commandId",
        "sessionId",
        "creationGeneration",
        "requestFingerprint",
        "request",
        "paths",
        "startedEvent",
        "anchorReservation",
    }
    if any(before[name] != after[name] for name in immutable):
        raise ValueError("command immutable request identity changed")
    if before == after:
        return after

    if before["stage"] == after["stage"]:
        if before["stage"] == "committed":
            raise ValueError("committed command state is immutable")
        if (
            before["stage"] in ("anchor_stop_requested", "stop_requested")
            and before["supervisor"] == after["supervisor"]
            and _without(before, {"stopIntent"})
            == _without(after, {"stopIntent"})
            and before["stopIntent"]["kind"] == after["stopIntent"]["kind"]
            and before["stopIntent"]["requestedAt"]
            == after["stopIntent"]["requestedAt"]
            and before["stopIntent"]["killAuthorizedAt"] is None
            and after["stopIntent"]["killAuthorizedAt"] is not None
        ):
            return after
        if _without(before, {"supervisor"}) != _without(after, {"supervisor"}):
            raise ValueError("recovery claim may replace only the supervisor")
        expected_predecessor = supervisor_fingerprint(before["supervisor"])
        replacement = after["supervisor"]
        if (
            replacement["role"] != "recovery"
            or replacement["predecessor"] != expected_predecessor
        ):
            raise ValueError("recovery supervisor predecessor is invalid")
        if replacement["leaseIdentity"] != before["supervisor"]["leaseIdentity"]:
            raise ValueError("recovery supervisor must retain the stable lease identity")
        return after

    if before["supervisor"] != after["supervisor"]:
        raise ValueError("command supervisor identity changed outside recovery claim")
    pair = (before["stage"], after["stage"])
    allowed_pairs = {
        ("prepared", "anchored"),
        ("prepared", "exited"),
        ("anchored", "running"),
        ("anchored", "anchor_stop_requested"),
        ("anchored", "exited"),
        ("anchor_stop_requested", "exited"),
        ("running", "stop_requested"),
        ("running", "exited"),
        ("stop_requested", "exited"),
        ("exited", "materialized"),
        ("materialized", "committed"),
    }
    if pair not in allowed_pairs:
        raise ValueError("command stage transition is not monotonic")

    if pair in (
        ("anchored", "anchor_stop_requested"),
        ("running", "stop_requested"),
    ) and after["stopIntent"]["killAuthorizedAt"] is not None:
        raise ValueError("initial stop request cannot pre-authorize escalation")

    if pair in (("prepared", "anchored"), ("anchored", "running")) and (
        before["supervisor"]["role"] != "launch"
        or before["supervisor"]["predecessor"] is not None
    ):
        raise ValueError("launch progression requires its launch supervisor")

    if after["stage"] == "exited":
        outcome_kind = after["outcome"]["kind"]
        allowed_outcomes = {
            "prepared": {"supervisor_failure"},
            "anchored": {"exec_failure", "supervisor_failure"},
            "anchor_stop_requested": {
                "stopped_before_ack",
                "supervisor_failure",
            },
            "running": {"exit", "signal", "supervisor_failure"},
            "stop_requested": {"exit", "signal", "supervisor_failure"},
        }
        if outcome_kind not in allowed_outcomes[before["stage"]]:
            raise ValueError("command outcome is invalid for its predecessor stage")
        if (
            before["supervisor"]["role"] == "recovery"
            and outcome_kind != "supervisor_failure"
        ):
            raise ValueError(
                "recovery supervisor may exit only through supervisor failure"
            )

    stable_by_pair = {
        ("anchored", "running"): {"anchor"},
        ("anchored", "anchor_stop_requested"): {"anchor"},
        ("running", "stop_requested"): {"anchor", "child"},
        ("exited", "materialized"): {
            "anchor",
            "child",
            "stopIntent",
            "outcome",
            "capture",
        },
        ("materialized", "committed"): {
            "anchor",
            "child",
            "stopIntent",
            "outcome",
            "capture",
            "materialized",
        },
    }
    if after["stage"] == "exited":
        stable_by_pair[pair] = {"anchor", "child", "stopIntent"}
    for name in stable_by_pair.get(pair, set()):
        if before[name] != after[name]:
            raise ValueError(f"command {name} changed during stage transition")
    return after


def _control_path(root: Path, name: str = "") -> Path:
    control = Path(root).absolute() / CONTROL_DIRECTORY_NAME
    return control / name if name else control


def _command_path(root: Path, command_id: str, name: str = "") -> Path:
    command = (
        _control_path(root, COMMANDS_DIRECTORY_NAME)
        / _identifier(command_id, "commandId")
    )
    return command / name if name else command


def _inode_identity(metadata: os.stat_result) -> str:
    return f"{metadata.st_dev}:{metadata.st_ino}"


class CommandLayoutReservation:
    """A live supervisor lease bound to one reserved command layout."""

    def __init__(
        self,
        *,
        root: Path,
        command_id: str,
        authority: Any,
        lease_context: Any,
        lease: Any,
        group_lease_identity: str,
    ) -> None:
        self._root = Path(root).absolute()
        self._command_id = command_id
        self._authority = authority
        self._lease_context = lease_context
        self._lease = lease
        self._group_lease_identity = group_lease_identity
        self._owner_pid = os.getpid()
        self._closed = False

    @property
    def identity(self) -> str:
        return self._lease.identity

    @property
    def anchor_reservation(self) -> dict[str, Any]:
        return {
            "groupLeaseIdentity": self._group_lease_identity,
            "controlProtocolVersion": 1,
        }

    def _revalidate(self, root: Path, command_id: str) -> None:
        expected_root = Path(root).absolute()
        if self._closed:
            raise ValueError("supervisor lease reservation is closed")
        if expected_root != self._root or command_id != self._command_id:
            raise ValueError("supervisor lease reservation is bound elsewhere")
        if os.getpid() != self._owner_pid:
            raise ValueError("supervisor lease reservation belongs to another process")
        self._authority.revalidate_root()
        try:
            opened = os.fstat(self._lease.descriptor)
        except OSError as exc:
            raise ValueError("supervisor lease descriptor is no longer live") from exc
        supervisor_path = _command_path(
            self._root, self._command_id, "supervisor.lease"
        )
        visible = self._authority.stat(supervisor_path, missing_ok=True)
        if (
            visible is None
            or not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(visible.st_mode)
            or _inode_identity(opened) != self.identity
            or _inode_identity(visible) != self.identity
            or stat.S_IMODE(opened.st_mode) != 0o600
            or stat.S_IMODE(visible.st_mode) != 0o600
            or (
                hasattr(os, "geteuid")
                and (
                    opened.st_uid != os.geteuid()
                    or visible.st_uid != os.geteuid()
                )
            )
        ):
            raise ValueError("supervisor lease descriptor binding changed")
        group = self._authority.stat(
            _command_path(self._root, self._command_id, "group.lease"),
            missing_ok=True,
        )
        if (
            group is None
            or not stat.S_ISREG(group.st_mode)
            or _inode_identity(group) != self._group_lease_identity
            or stat.S_IMODE(group.st_mode) != 0o600
            or (hasattr(os, "geteuid") and group.st_uid != os.geteuid())
        ):
            raise ValueError("group lease reservation binding changed")

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._lease_context.__exit__(None, None, None)
        finally:
            self._authority.close()

    def __enter__(self) -> "CommandLayoutReservation":
        if self._closed:
            raise ValueError("supervisor lease reservation is closed")
        return self

    def __exit__(self, _exc_type: Any, _exc: Any, _traceback: Any) -> None:
        self.close()


def _assert_private_directory(path: Path, label: str) -> os.stat_result:
    authority = safe_io._active_rooted_io()
    metadata = authority.stat(path, missing_ok=True)
    if metadata is None or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"{label} is missing or unsafe")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ValueError(f"{label} permissions are unsafe")
    if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
        raise ValueError(f"{label} owner is unsafe")
    return metadata


def _assert_private_file(path: Path, label: str) -> os.stat_result:
    authority = safe_io._active_rooted_io()
    metadata = authority.stat(path, missing_ok=True)
    if metadata is None or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{label} is missing or unsafe")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise ValueError(f"{label} permissions are unsafe")
    if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
        raise ValueError(f"{label} owner is unsafe")
    return metadata


def _create_stable_file(path: Path) -> tuple[int, int]:
    """Create one never-replaced private file, or verify a racing creator."""

    authority = safe_io._active_rooted_io()
    parent, name, parent_relative, relative = authority._parent(path)
    descriptor = -1
    created = False
    try:
        authority._validate_directory(parent_relative, parent)
        try:
            descriptor = os.open(
                name,
                os.O_CREAT
                | os.O_EXCL
                | os.O_RDWR
                | os.O_NOFOLLOW
                | os.O_CLOEXEC,
                0o600,
                dir_fd=parent,
            )
            created = True
        except FileExistsError:
            descriptor = os.open(
                name,
                os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=parent,
            )
        os.set_inheritable(descriptor, False)
        if created:
            os.fchmod(descriptor, 0o600)
            os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or not stat.S_ISREG(visible.st_mode)
            or (metadata.st_dev, metadata.st_ino)
            != (visible.st_dev, visible.st_ino)
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or stat.S_IMODE(visible.st_mode) != 0o600
            or (
                hasattr(os, "geteuid")
                and (
                    metadata.st_uid != os.geteuid()
                    or visible.st_uid != os.geteuid()
                )
            )
        ):
            raise ValueError(f"stable private file {relative} is unsafe")
        if created:
            os.fsync(parent)
        authority._validate_directory(parent_relative, parent)
        return metadata.st_dev, metadata.st_ino
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


@contextmanager
def _stable_lock(path: Path, timeout: float = 5.0) -> Iterator[None]:
    """Lock a stable inode without changing its bytes or metadata."""

    if os.name != "posix":
        raise RuntimeError("private command state requires POSIX advisory locks")
    authority = safe_io._active_rooted_io()
    parent, name, parent_relative, relative = authority._parent(path)
    descriptor = -1
    locked = False
    deadline = time.monotonic() + min(max(timeout, 0.0), 5.0)
    try:
        authority._validate_directory(parent_relative, parent)
        descriptor = os.open(
            name,
            os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent,
        )
        os.set_inheritable(descriptor, False)
        metadata = os.fstat(descriptor)
        identity = (metadata.st_dev, metadata.st_ino)

        def validate_binding() -> None:
            opened = os.fstat(descriptor)
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (
                not stat.S_ISREG(opened.st_mode)
                or not stat.S_ISREG(current.st_mode)
                or (opened.st_dev, opened.st_ino) != identity
                or (current.st_dev, current.st_ino) != identity
                or stat.S_IMODE(opened.st_mode) != 0o600
                or stat.S_IMODE(current.st_mode) != 0o600
                or (
                    hasattr(os, "geteuid")
                    and (
                        opened.st_uid != os.geteuid()
                        or current.st_uid != os.geteuid()
                    )
                )
            ):
                raise ValueError(f"stable private lock {relative} is unsafe")

        validate_binding()
        while not locked:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK):
                    raise
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"timed out acquiring private lock {relative}") from exc
                time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
        authority._validate_directory(parent_relative, parent)
        validate_binding()
        yield
        authority._validate_directory(parent_relative, parent)
        validate_binding()
    finally:
        if locked:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def _bounded_names(path: Path, maximum: int, label: str) -> list[str]:
    authority = safe_io._active_rooted_io()
    relative = authority._relative(path)
    try:
        descriptor = authority._open_directory_unchecked(relative)
    except FileNotFoundError as exc:
        raise ValueError(f"{label} is missing") from exc
    names: list[str] = []
    try:
        authority._validate_directory(relative, descriptor)
        with os.scandir(descriptor) as entries:
            for entry in entries:
                if len(names) >= maximum:
                    raise ValueError(f"{label} exceeds {maximum} entries")
                name = entry.name
                if name in ("", ".", "..") or "/" in name or "\x00" in name:
                    raise ValueError(f"{label} contains an unsafe entry")
                names.append(name)
        authority._validate_directory(relative, descriptor)
    finally:
        os.close(descriptor)
    return sorted(names)


def _validate_control_layout_unlocked(root: Path) -> None:
    control = _control_path(root)
    _assert_private_directory(control, "private control directory")
    names = set(_bounded_names(control, 5, "private control directory"))
    expected = {
        COMMANDS_LOCK_NAME,
        SESSION_FILE_NAME,
        TERMINAL_INTENT_FILE_NAME,
        COMMANDS_DIRECTORY_NAME,
    }
    if names != expected:
        raise ValueError("private control directory has an invalid object layout")
    _assert_private_file(control / COMMANDS_LOCK_NAME, "commands lock")
    _assert_private_file(control / SESSION_FILE_NAME, "session state")
    _assert_private_file(control / TERMINAL_INTENT_FILE_NAME, "terminal intent")
    _assert_private_directory(control / COMMANDS_DIRECTORY_NAME, "private commands directory")


def _validate_command_layout_unlocked(root: Path, command_id: str) -> None:
    command = _command_path(root, command_id)
    _assert_private_directory(command, "private command directory")
    names = set(_bounded_names(command, 7, "private command directory"))
    expected = {
        "state.lock",
        "state.json",
        "supervisor.lease",
        "group.lease",
        "stdout.recovery",
        "stderr.recovery",
    }
    if names != expected:
        raise ValueError("private command directory has an invalid object layout")
    for name in expected:
        _assert_private_file(command / name, f"private command {name}")


def _load_session_unlocked(root: Path) -> dict[str, Any]:
    value, _byte_count = bounded_io._read_json_bounded(
        _control_path(root, SESSION_FILE_NAME),
        maximum=MAX_SESSION_STATE_BYTES,
    )
    session = validate_session(value)
    if session["runId"] != Path(root).name:
        raise ValueError("session runId does not match the attempt root")
    return session


def _load_terminal_intent_unlocked(
    root: Path,
    session_id: str,
    generation: int | None = None,
) -> dict[str, Any]:
    value, _byte_count = bounded_io._read_json_bounded(
        _control_path(root, TERMINAL_INTENT_FILE_NAME),
        maximum=MAX_TERMINAL_INTENT_BYTES,
    )
    return validate_terminal_intent(
        value,
        expected_session_id=session_id,
        maximum_recorded_generation=generation,
    )


def _validate_command_file_bindings_unlocked(
    root: Path, state: dict[str, Any]
) -> None:
    command_id = state["commandId"]
    supervisor_metadata = _assert_private_file(
        _command_path(root, command_id, "supervisor.lease"),
        "command supervisor lease",
    )
    group_metadata = _assert_private_file(
        _command_path(root, command_id, "group.lease"),
        "command group lease",
    )
    if state["supervisor"]["leaseIdentity"] != _inode_identity(
        supervisor_metadata
    ):
        raise ValueError("stored command supervisor lease binding changed")
    if state["anchorReservation"]["groupLeaseIdentity"] != _inode_identity(
        group_metadata
    ):
        raise ValueError("stored command group lease binding changed")
    if state["anchor"] is not None and state["anchor"][
        "groupLeaseIdentity"
    ] != _inode_identity(group_metadata):
        raise ValueError("stored command anchor group lease binding changed")


def _load_command_state_unlocked(
    root: Path, command_id: str, session_id: str
) -> dict[str, Any]:
    value, _byte_count = bounded_io._read_json_bounded(
        _command_path(root, command_id, "state.json"),
        maximum=MAX_COMMAND_STATE_BYTES,
    )
    state = validate_command_state(
        value,
        expected_command_id=command_id,
        expected_session_id=session_id,
    )
    _validate_command_file_bindings_unlocked(root, state)
    return state


def _authorize_session(
    session: dict[str, Any], session_id: str, generation: int
) -> None:
    expected_session = _identifier(session_id, "sessionId")
    expected_generation = _integer(generation, "session generation", minimum=1)
    if session["sessionId"] != expected_session:
        raise ValueError("session authorization sessionId does not match")
    if session["generation"] != expected_generation:
        raise ValueError("session authorization generation is stale")


@safe_io._rooted_attempt_mutation
def initialize_control_layout(
    root: Path, session: Any
) -> dict[str, Any]:
    """Initialize or idempotently verify the exact private control layout."""

    root = Path(root).absolute()
    candidate = copy.deepcopy(validate_session(session))
    if candidate["runId"] != root.name:
        raise ValueError("session runId does not match the attempt root")
    if candidate["state"] != "active" or candidate["generation"] != 1:
        raise ValueError("new private session must start active at generation 1")
    session_content = encode_session(candidate)
    initial_intent = make_terminal_intent(candidate["sessionId"])
    intent_content = encode_terminal_intent(initial_intent)
    authority = safe_io._active_rooted_io()
    control = _control_path(root)
    existing = authority.stat(control, missing_ok=True)
    if existing is not None:
        if not stat.S_ISDIR(existing.st_mode):
            raise ValueError("private control path is unsafe")
        _assert_private_directory(control, "private control directory")
    else:
        authority.ensure_directory(control, 0o700)
    commands = control / COMMANDS_DIRECTORY_NAME
    commands_metadata = authority.stat(commands, missing_ok=True)
    if commands_metadata is None:
        authority.ensure_directory(commands, 0o700)
    else:
        _assert_private_directory(commands, "private commands directory")
    _create_stable_file(control / COMMANDS_LOCK_NAME)
    with _stable_lock(control / COMMANDS_LOCK_NAME):
        names = set(_bounded_names(control, 5, "private control directory"))
        allowed = {
            COMMANDS_LOCK_NAME,
            SESSION_FILE_NAME,
            TERMINAL_INTENT_FILE_NAME,
            COMMANDS_DIRECTORY_NAME,
        }
        if not names.issubset(allowed):
            raise ValueError("private control directory has an invalid object layout")
        has_session = SESSION_FILE_NAME in names
        has_intent = TERMINAL_INTENT_FILE_NAME in names
        command_names = _bounded_names(
            commands, 1, "private commands directory"
        )
        if command_names:
            raise ValueError("private control initialization contains commands")
        if has_session:
            stored = _load_session_unlocked(root)
            if stored != candidate:
                raise ValueError("existing private session does not match initialization")
        if has_intent:
            stored_intent = _load_terminal_intent_unlocked(
                root, candidate["sessionId"], candidate["generation"]
            )
            if stored_intent != initial_intent:
                raise ValueError("existing terminal intent does not match initialization")
        if not has_intent:
            authority.atomic_write(
                control / TERMINAL_INTENT_FILE_NAME, intent_content, 0o600
            )
        if not has_session:
            authority.atomic_write(
                control / SESSION_FILE_NAME, session_content, 0o600
            )
        _validate_control_layout_unlocked(root)
        return copy.deepcopy(candidate)


def _with_rooted_read(root: Path):
    publication_root = Path(root).absolute().parent.parent
    return safe_io._rooted_io(publication_root, mutation=False)


def read_session(root: Path) -> dict[str, Any]:
    root = Path(root).absolute()
    with _with_rooted_read(root):
        _validate_control_layout_unlocked(root)
        with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
            _validate_control_layout_unlocked(root)
            session = _load_session_unlocked(root)
            _load_terminal_intent_unlocked(
                root, session["sessionId"], session["generation"]
            )
            return copy.deepcopy(session)


def read_terminal_intent(root: Path) -> dict[str, Any]:
    root = Path(root).absolute()
    with _with_rooted_read(root):
        _validate_control_layout_unlocked(root)
        with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
            _validate_control_layout_unlocked(root)
            session = _load_session_unlocked(root)
            intent = _load_terminal_intent_unlocked(
                root, session["sessionId"], session["generation"]
            )
            return copy.deepcopy(intent)


@safe_io._rooted_attempt_mutation
def transition_session_state(
    root: Path,
    session_id: str,
    generation: int,
    state: str,
) -> dict[str, Any]:
    root = Path(root).absolute()
    if state not in ("active", "finalizing", "committed"):
        raise ValueError("candidate session state is invalid")
    _validate_control_layout_unlocked(root)
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        order = {"active": 0, "finalizing": 1, "committed": 2}
        if order[state] < order[session["state"]] or order[state] > order[session["state"]] + 1:
            raise ValueError("session state transition is not monotonic")
        if state == session["state"]:
            return copy.deepcopy(session)
        candidate = copy.deepcopy(session)
        candidate["state"] = state
        content = encode_session(candidate)
        safe_io._active_rooted_io().atomic_write(
            _control_path(root, SESSION_FILE_NAME), content, 0o600
        )
        return candidate


def _scan_commands_unlocked(
    root: Path,
    session: dict[str, Any],
    *,
    exclude_command_id: str | None = None,
) -> list[dict[str, Any]]:
    commands_root = _control_path(root, COMMANDS_DIRECTORY_NAME)
    names = _bounded_names(
        commands_root, MAX_SESSION_COMMANDS, "private commands directory"
    )
    states: list[dict[str, Any]] = []
    for command_id in names:
        _identifier(command_id, "command directory name")
        if command_id == exclude_command_id:
            continue
        _validate_command_layout_unlocked(root, command_id)
        with _stable_lock(_command_path(root, command_id, "state.lock")):
            state = _load_command_state_unlocked(
                root, command_id, session["sessionId"]
            )
        if state["creationGeneration"] > session["generation"]:
            raise ValueError("command creationGeneration exceeds session generation")
        states.append(state)
    return states


@safe_io._rooted_attempt_mutation
def reserve_command_layout(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
) -> CommandLayoutReservation:
    """Reserve stable command inodes and return the held supervisor lease."""

    root = Path(root).absolute()
    command_id = _identifier(command_id, "commandId")
    _validate_control_layout_unlocked(root)
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] != "active":
            raise ValueError("new command reservations require an active session")

        authority = safe_io._active_rooted_io()
        command_root = _command_path(root, command_id)
        existing = authority.stat(command_root, missing_ok=True)
        states = _scan_commands_unlocked(
            root,
            session,
            exclude_command_id=command_id if existing is not None else None,
        )
        stable_names = {
            "state.lock",
            "supervisor.lease",
            "group.lease",
            "stdout.recovery",
            "stderr.recovery",
        }
        if existing is None:
            authority.ensure_directory(command_root, 0o700)
            names: set[str] = set()
            has_state = False
        else:
            if not stat.S_ISDIR(existing.st_mode):
                raise ValueError("private command reservation path is unsafe")
            _assert_private_directory(command_root, "private command directory")
            names = set(
                _bounded_names(command_root, 7, "private command directory")
            )
            has_state = "state.json" in names
            allowed_names = stable_names | ({"state.json"} if has_state else set())
            if not names.issubset(allowed_names):
                raise ValueError("private command reservation layout is unsafe")
            if has_state and names != stable_names | {"state.json"}:
                raise ValueError("persisted private command layout is incomplete")
            for name in names:
                metadata = _assert_private_file(
                    command_root / name, f"reserved private command {name}"
                )
                if not has_state and metadata.st_size != 0:
                    raise ValueError("reserved private command file is not empty")

        if not has_state:
            if len(states) >= MAX_SESSION_COMMANDS:
                raise ValueError("session command count exceeds its limit")
            if (
                sum(item["stage"] != "committed" for item in states)
                >= MAX_ACTIVE_COMMANDS
            ):
                raise ValueError("session active command count exceeds its limit")

        if not has_state:
            for name in sorted(stable_names - names):
                _create_stable_file(command_root / name)
        final_names = set(
            _bounded_names(command_root, 7, "private command directory")
        )
        expected_names = stable_names | ({"state.json"} if has_state else set())
        if final_names != expected_names:
            raise ValueError("private command reservation layout is incomplete")
        for name in stable_names:
            metadata = _assert_private_file(
                command_root / name, f"reserved private command {name}"
            )
            if not has_state and metadata.st_size != 0:
                raise ValueError("reserved private command file is not empty")
        if has_state:
            _load_command_state_unlocked(root, command_id, session["sessionId"])

        group_metadata = _assert_private_file(
            command_root / "group.lease", "reserved command group lease"
        )
        group_identity = _inode_identity(group_metadata)

        long_authority = safe_io._RootedIO(root.parent.parent)
        lease_context = long_authority.lease(
            command_root / "supervisor.lease", timeout=0.0
        )
        try:
            lease = lease_context.__enter__()
        except BaseException:
            long_authority.close()
            raise
        return CommandLayoutReservation(
            root=root,
            command_id=command_id,
            authority=long_authority,
            lease_context=lease_context,
            lease=lease,
            group_lease_identity=group_identity,
        )


@safe_io._rooted_attempt_mutation
def create_command_state(
    root: Path,
    state: Any,
    *,
    supervisor_lease: CommandLayoutReservation,
) -> dict[str, Any]:
    """Install a prepared command record after validating all existing state."""

    root = Path(root).absolute()
    candidate = copy.deepcopy(validate_command_state(state))
    if candidate["stage"] != "prepared":
        raise ValueError("new command state must be prepared")
    if (
        candidate["supervisor"]["role"] != "launch"
        or candidate["supervisor"]["predecessor"] is not None
    ):
        raise ValueError("new command state requires its launch supervisor")
    if not isinstance(supervisor_lease, CommandLayoutReservation):
        raise ValueError("new command state requires its reserved supervisor lease")
    supervisor_lease._revalidate(root, candidate["commandId"])
    if candidate["supervisor"]["pid"] != os.getpid():
        raise ValueError("new command supervisor pid must be the current process")
    if candidate["supervisor"]["leaseIdentity"] != supervisor_lease.identity:
        raise ValueError("new command supervisor leaseIdentity is not reserved")
    if candidate["anchorReservation"] != supervisor_lease.anchor_reservation:
        raise ValueError("new command anchorReservation is not reserved")
    content = encode_command_state(candidate)
    _validate_control_layout_unlocked(root)
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        _authorize_session(
            session, candidate["sessionId"], candidate["creationGeneration"]
        )
        if session["state"] != "active":
            raise ValueError("new commands require an active session")
        command_root = _command_path(root, candidate["commandId"])
        existing = safe_io._active_rooted_io().stat(command_root, missing_ok=True)
        if existing is None:
            raise ValueError("new command layout has not been reserved")
        supervisor_lease._revalidate(root, candidate["commandId"])
        states = _scan_commands_unlocked(
            root,
            session,
            exclude_command_id=candidate["commandId"],
        )
        candidate_targets = set(candidate["paths"].values())
        for stored_state in states:
            if candidate_targets.intersection(stored_state["paths"].values()):
                raise ValueError("command output path collides with an existing command")
        authority = safe_io._active_rooted_io()
        _assert_private_directory(command_root, "private command directory")
        names = set(
            _bounded_names(command_root, 7, "private command directory")
        )
        stable_names = {
            "state.lock",
            "supervisor.lease",
            "group.lease",
            "stdout.recovery",
            "stderr.recovery",
        }
        if names not in (stable_names, stable_names | {"state.json"}):
            raise ValueError("reserved private command layout is unsafe")
        for name in stable_names:
            metadata = _assert_private_file(
                command_root / name, f"reserved private command {name}"
            )
            if metadata.st_size != 0:
                raise ValueError("reserved private command stable file is not empty")
        supervisor_metadata = _assert_private_file(
            command_root / "supervisor.lease", "reserved command supervisor lease"
        )
        group_metadata = _assert_private_file(
            command_root / "group.lease", "reserved command group lease"
        )
        if candidate["supervisor"]["leaseIdentity"] != _inode_identity(
            supervisor_metadata
        ):
            raise ValueError("command supervisor lease binding disagrees with state")
        if candidate["anchorReservation"]["groupLeaseIdentity"] != _inode_identity(
            group_metadata
        ):
            raise ValueError("command group lease binding disagrees with state")
        if "state.json" in names:
            _validate_command_layout_unlocked(root, candidate["commandId"])
            with _stable_lock(command_root / "state.lock"):
                stored = _load_command_state_unlocked(
                    root, candidate["commandId"], session["sessionId"]
                )
            if stored != candidate:
                raise ValueError("existing command state does not match creation")
            return copy.deepcopy(stored)
        if len(states) >= MAX_SESSION_COMMANDS:
            raise ValueError("session command count exceeds its limit")
        if sum(item["stage"] != "committed" for item in states) >= MAX_ACTIVE_COMMANDS:
            raise ValueError("session active command count exceeds its limit")
        with _stable_lock(command_root / "state.lock"):
            supervisor_lease._revalidate(root, candidate["commandId"])
            authority.atomic_write(command_root / "state.json", content, 0o600)
        _validate_command_layout_unlocked(root, candidate["commandId"])
        return copy.deepcopy(candidate)


def read_command_state(
    root: Path,
    command_id: str,
    session_id: str | None = None,
) -> dict[str, Any]:
    root = Path(root).absolute()
    command_id = _identifier(command_id, "commandId")
    with _with_rooted_read(root):
        _validate_control_layout_unlocked(root)
        with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
            _validate_control_layout_unlocked(root)
            session = _load_session_unlocked(root)
            _load_terminal_intent_unlocked(
                root, session["sessionId"], session["generation"]
            )
            if session_id is not None and session["sessionId"] != _identifier(
                session_id, "expected sessionId"
            ):
                raise ValueError("command query sessionId does not match")
            _validate_command_layout_unlocked(root, command_id)
            with _stable_lock(_command_path(root, command_id, "state.lock")):
                state = _load_command_state_unlocked(
                    root, command_id, session["sessionId"]
                )
            if state["creationGeneration"] > session["generation"]:
                raise ValueError("command creationGeneration exceeds session generation")
            return copy.deepcopy(state)


@safe_io._rooted_attempt_mutation
def transition_command_state(
    root: Path,
    session_id: str,
    generation: int,
    state: Any,
    *,
    supervisor_lease: CommandLayoutReservation | None = None,
) -> dict[str, Any]:
    root = Path(root).absolute()
    candidate = copy.deepcopy(validate_command_state(state))
    content = encode_command_state(candidate)
    _validate_control_layout_unlocked(root)
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        _validate_command_layout_unlocked(root, candidate["commandId"])
        with _stable_lock(_command_path(root, candidate["commandId"], "state.lock")):
            previous = _load_command_state_unlocked(
                root, candidate["commandId"], session["sessionId"]
            )
            validate_command_transition(
                previous,
                candidate,
                session_id=session["sessionId"],
                generation=session["generation"],
            )
            if previous == candidate:
                return copy.deepcopy(previous)
            _validate_command_file_bindings_unlocked(root, candidate)
            if not isinstance(supervisor_lease, CommandLayoutReservation):
                raise ValueError("command transition requires its live supervisor lease")
            if candidate["supervisor"]["pid"] != os.getpid():
                raise ValueError("command supervisor pid must be the current process")
            supervisor_lease._revalidate(root, candidate["commandId"])
            if (
                candidate["supervisor"]["leaseIdentity"]
                != supervisor_lease.identity
                or candidate["anchorReservation"]
                != supervisor_lease.anchor_reservation
            ):
                raise ValueError(
                    "command supervisor disagrees with its live reservation"
                )
            supervisor_lease._revalidate(root, candidate["commandId"])
            safe_io._active_rooted_io().atomic_write(
                _command_path(root, candidate["commandId"], "state.json"),
                content,
                0o600,
            )
            return copy.deepcopy(candidate)


def _utc_now() -> str:
    return safe_io._utc_now()


def _record_diagnostic_candidate(
    intent: dict[str, Any],
    caller: dict[str, Any],
    generation: int,
    recorded_at: str,
) -> tuple[dict[str, Any], bool]:
    semantic_key = _diagnostic_key(caller)
    retained = (
        []
        if intent["primary"] is None
        else [intent["primary"], *intent["secondary"]]
    )
    if any(_diagnostic_key(item) == semantic_key for item in retained):
        return intent, False
    candidate = copy.deepcopy(intent)
    diagnostic = copy.deepcopy(caller)
    diagnostic.update(
        recordedAt=_utc_timestamp(recorded_at, "terminal diagnostic recordedAt"),
        ordinal=candidate["nextOrdinal"],
        recordedGeneration=_integer(
            generation, "terminal diagnostic recordedGeneration", minimum=1
        ),
    )
    _validate_diagnostic_semantics(diagnostic, persisted=True)
    candidate["nextOrdinal"] += 1
    retained.append(diagnostic)
    retained.sort(key=_diagnostic_order)
    maximum_retained = 1 + MAX_TERMINAL_SECONDARY_DIAGNOSTICS
    if len(retained) > maximum_retained:
        retained = retained[:maximum_retained]
        candidate["droppedCount"] += 1
    candidate["primary"] = retained[0] if retained else None
    candidate["secondary"] = retained[1:]
    validate_terminal_intent(candidate, expected_session_id=intent["sessionId"])
    return candidate, True


@safe_io._rooted_attempt_mutation
def record_terminal_diagnostic(
    root: Path,
    session_id: str,
    generation: int,
    diagnostic: Any,
) -> dict[str, Any]:
    """Record one caller diagnostic with server-owned ordering fields."""

    root = Path(root).absolute()
    caller = copy.deepcopy(validate_caller_diagnostic(diagnostic))
    _validate_control_layout_unlocked(root)
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        intent = _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] == "committed":
            raise ValueError("committed session terminal intent is immutable")
        if session["state"] == "finalizing" and caller["status"] == "passed":
            raise ValueError("pass intent is forbidden while finalizing")
        candidate, changed = _record_diagnostic_candidate(
            intent, caller, session["generation"], _utc_now()
        )
        if not changed:
            return copy.deepcopy(intent)
        content = encode_terminal_intent(candidate)
        safe_io._active_rooted_io().atomic_write(
            _control_path(root, TERMINAL_INTENT_FILE_NAME), content, 0o600
        )
        return copy.deepcopy(candidate)


__all__ = (
    "CONTROL_DIRECTORY_NAME",
    "COMMANDS_LOCK_NAME",
    "SESSION_FILE_NAME",
    "TERMINAL_INTENT_FILE_NAME",
    "COMMANDS_DIRECTORY_NAME",
    "MAX_SESSION_STATE_BYTES",
    "MAX_TERMINAL_INTENT_BYTES",
    "MAX_COMMAND_STATE_BYTES",
    "MAX_TERMINAL_SECONDARY_DIAGNOSTICS",
    "MAX_ACTIVE_COMMANDS",
    "MAX_SESSION_COMMANDS",
    "validate_session",
    "encode_session",
    "make_terminal_intent",
    "validate_caller_diagnostic",
    "validate_terminal_intent",
    "encode_terminal_intent",
    "request_fingerprint",
    "supervisor_fingerprint",
    "validate_command_state",
    "encode_command_state",
    "validate_command_transition",
    "CommandLayoutReservation",
    "initialize_control_layout",
    "read_session",
    "read_terminal_intent",
    "transition_session_state",
    "reserve_command_layout",
    "create_command_state",
    "read_command_state",
    "transition_command_state",
    "record_terminal_diagnostic",
)
