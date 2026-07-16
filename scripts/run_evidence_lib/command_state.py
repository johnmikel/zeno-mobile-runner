"""Bounded private state for durable command supervision.

This module owns only private document contracts and descriptor-rooted storage.
It deliberately has no dependency on lifecycle or command execution code so
recovery and session orchestration can call these primitives without a cycle.
"""

from __future__ import annotations

import copy
import ctypes
import errno
import hashlib
import os
import re
import stat
import sys
import threading
import time
import weakref
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
    MAX_JSONL_LINE_BYTES,
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
CONTROL_RETIREMENT_NAME = ".evidence-control.retiring"

_COMPATIBILITY_ACTIVITY_LOCK = threading.Lock()
_COMPATIBILITY_ACTIVITY: dict[str, int] = {}


def _enter_compatibility_activity(root: Path) -> None:
    """Register an in-process legacy command until durable launch owns it."""

    key = str(Path(root).absolute())
    with _COMPATIBILITY_ACTIVITY_LOCK:
        _COMPATIBILITY_ACTIVITY[key] = _COMPATIBILITY_ACTIVITY.get(key, 0) + 1


def _leave_compatibility_activity(root: Path) -> None:
    key = str(Path(root).absolute())
    with _COMPATIBILITY_ACTIVITY_LOCK:
        count = _COMPATIBILITY_ACTIVITY.get(key, 0)
        if count <= 0:
            raise RuntimeError("compatibility command activity is unbalanced")
        if count == 1:
            del _COMPATIBILITY_ACTIVITY[key]
        else:
            _COMPATIBILITY_ACTIVITY[key] = count - 1


def _compatibility_activity_count(root: Path) -> int:
    key = str(Path(root).absolute())
    with _COMPATIBILITY_ACTIVITY_LOCK:
        return _COMPATIBILITY_ACTIVITY.get(key, 0)

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
_EVENT_BINDING_KEYS = {"seq", "bytes", "sha256", "event"}
_TERMINAL_EVENT_REQUIRED_KEYS = {
    "schemaVersion",
    "seq",
    "timestamp",
    "phase",
    "status",
    "command",
    "artifact",
}
_TERMINAL_EVENT_OPTIONAL_KEYS = {
    "errorCode",
    "summary",
    "commandStatus",
}
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
_RETIREMENT_TOMBSTONE_RE = re.compile(
    r"^\.retiring-([0-9a-f]{32})-(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$"
)
_COMMAND_STABLE_NAMES = (
    "group.lease",
    "state.lock",
    "stderr.recovery",
    "stdout.recovery",
    "supervisor.lease",
)
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
    if ERROR_CLASSIFICATION[failure_code] == "cancelled":
        raise ValueError("command request failureCode is cancellation-class")
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


def _timestamp_instant(value: str) -> datetime:
    return datetime.fromisoformat(value[:-1] + "+00:00")


def _terminal_outcome_timestamp(outcome: dict[str, Any]) -> str:
    return outcome[
        {
            "exit": "finishedAt",
            "signal": "finishedAt",
            "exec_failure": "execFailedAt",
            "supervisor_failure": "failedAt",
            "stopped_before_ack": "stoppedAt",
        }[outcome["kind"]]
    ]


def _terminal_event_signature(event: dict[str, Any]) -> tuple[Any, ...]:
    return (
        event["status"],
        event.get("errorCode"),
        "commandStatus" in event,
        event.get("commandStatus"),
        event.get("summary"),
    )


def _historical_terminal_signature(
    request: dict[str, Any],
    outcome: dict[str, Any],
    stop_intent: dict[str, Any] | None,
) -> tuple[Any, ...]:
    kind = outcome["kind"]
    if stop_intent is not None and kind in (
        "exit",
        "signal",
        "stopped_before_ack",
    ):
        if stop_intent["killAuthorizedAt"] is not None:
            return (
                "failed",
                "runner.cleanup_failed",
                False,
                None,
                "Command cleanup required forced termination",
            )
        if stop_intent["kind"] == "expected":
            return ("passed", None, True, 0, None)
        return (
            "cancelled",
            "run.cancelled",
            False,
            None,
            (
                "Command stopped before execution acknowledgement"
                if kind == "stopped_before_ack"
                else "Command cancelled after execution acknowledgement"
            ),
        )
    if kind == "exit":
        status = outcome["exitStatus"]
        if status == 0:
            return ("passed", None, True, 0, None)
        return (
            "failed",
            request["failureCode"],
            True,
            status,
            f"Command exited with status {status}",
        )
    if kind == "signal":
        return (
            "failed",
            request["failureCode"],
            False,
            None,
            f"Command terminated by signal {outcome['signal']}",
        )
    if kind == "exec_failure":
        return (
            "failed",
            request["failureCode"],
            True,
            outcome["exitStatus"],
            "Command execution failed before acknowledgement",
        )
    if kind == "stopped_before_ack":
        raise ValueError("stopped-before-ack outcome requires a stop intent")
    status = outcome["exitStatus"]
    summary = (
        "Command capture failed"
        if outcome["errorCode"] == "runner.capture_failed"
        else "Command supervision failed"
    )
    return (
        "failed",
        outcome["errorCode"],
        status is not None,
        status,
        summary,
    )


def _recovery_loss_terminal_signature(
    outcome: dict[str, Any]
) -> tuple[Any, ...]:
    return (
        "failed",
        "runner.command_supervisor_lost",
        False,
        None,
        "Command supervision failed",
    )


def _validate_frozen_terminal_event(
    value: Any,
    *,
    request: dict[str, Any],
    paths: dict[str, str],
    started_event: dict[str, Any],
    supervisor: dict[str, Any],
    outcome: dict[str, Any],
    stop_intent: dict[str, Any] | None,
) -> bytes:
    if type(value) is not dict:
        raise ValueError("command frozen terminal event must be an object")
    keys = set(value)
    if not _TERMINAL_EVENT_REQUIRED_KEYS.issubset(keys) or not keys.issubset(
        _TERMINAL_EVENT_REQUIRED_KEYS | _TERMINAL_EVENT_OPTIONAL_KEYS
    ):
        raise ValueError("command frozen terminal event has an invalid object shape")
    if value["schemaVersion"] != 1 or type(value["schemaVersion"]) is not int:
        raise ValueError("command frozen terminal event schemaVersion must equal 1")
    _integer(value["seq"], "command frozen terminal event seq", minimum=1)
    _utc_timestamp(
        value["timestamp"], "command frozen terminal event timestamp"
    )
    if value["phase"] != request["phase"]:
        raise ValueError("command frozen terminal event phase disagrees with request")
    if value["status"] not in ("passed", "failed", "cancelled"):
        raise ValueError("command frozen terminal event status is not terminal")
    if value["command"] != paths["metadata"]:
        raise ValueError(
            "command frozen terminal event command disagrees with metadata path"
        )
    if value["artifact"] != paths["metadata"]:
        raise ValueError(
            "command frozen terminal event artifact disagrees with metadata path"
        )
    if "errorCode" in value:
        error_code = _text(
            value["errorCode"], "command frozen terminal event errorCode"
        )
        if error_code not in ERROR_CLASSIFICATION:
            raise ValueError("command frozen terminal event errorCode is unknown")
    if "summary" in value:
        _text(value["summary"], "command frozen terminal event summary")
    if "commandStatus" in value:
        _integer(
            value["commandStatus"],
            "command frozen terminal event commandStatus",
        )
    if value["status"] == "passed":
        if "errorCode" in value or "summary" in value:
            raise ValueError("passed frozen terminal event cannot contain failure detail")
    elif "errorCode" not in value or "summary" not in value:
        raise ValueError("non-passing frozen terminal event requires failure detail")

    if value["seq"] <= started_event["seq"]:
        raise ValueError("command terminal event must follow its started event")
    terminal_instant = _timestamp_instant(value["timestamp"])
    if terminal_instant < _timestamp_instant(started_event["timestamp"]):
        raise ValueError("command terminal event predates its started event")
    if terminal_instant < _timestamp_instant(
        _terminal_outcome_timestamp(outcome)
    ):
        raise ValueError("command terminal event predates its terminal outcome")

    observed = _terminal_event_signature(value)
    allowed = {
        _historical_terminal_signature(request, outcome, stop_intent)
    }
    if supervisor["role"] == "recovery":
        allowed.add(_recovery_loss_terminal_signature(outcome))
    if observed not in allowed:
        raise ValueError("command frozen terminal event contradicts terminal outcome")
    return bounded_io._jsonl_line_bytes_bounded(
        value,
        maximum=MAX_JSONL_LINE_BYTES,
        label="command frozen terminal event",
    )


def _validate_materialized(
    value: Any,
    paths: dict[str, str],
    started_event: dict[str, Any],
    capture: dict[str, Any],
    request: dict[str, Any],
    supervisor: dict[str, Any],
    outcome: dict[str, Any],
    stop_intent: dict[str, Any] | None,
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
    content = _validate_frozen_terminal_event(
        event["event"],
        request=request,
        paths=paths,
        started_event=started_event,
        supervisor=supervisor,
        outcome=outcome,
        stop_intent=stop_intent,
    )
    if sequence != event["event"]["seq"]:
        raise ValueError("command terminal event binding seq disagrees with event")
    byte_count = _integer(
        event["bytes"], "command terminal event bytes", minimum=1
    )
    if byte_count != len(content):
        raise ValueError("command terminal event binding bytes disagree with event")
    digest = _digest(event["sha256"], "command terminal event sha256")
    if digest != "sha256:" + hashlib.sha256(content).hexdigest():
        raise ValueError("command terminal event binding sha256 disagrees with event")
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
            _validate_exec_failure_outcome(outcome)
            _validate_negative_exec_capture(capture)
        elif outcome_kind == "stopped_before_ack":
            if anchor is None or child is not None or stop_intent is None:
                raise ValueError("stopped-before-ack has invalid identities")
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
                state["request"],
                supervisor,
                outcome,
                stop_intent,
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

    if (
        pair == ("exited", "materialized")
        and before["supervisor"]["role"] == "recovery"
        and _terminal_event_signature(
            after["materialized"]["terminalEvent"]["event"]
        )
        != _recovery_loss_terminal_signature(after["outcome"])
    ):
        raise ValueError(
            "recovery materialization requires the exact supervisor loss event"
        )

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


def _command_recovery_checkpoint(
    stage: str, path: Path | None = None
) -> None:
    """No-op fault seam for deterministic command recovery tests."""


def _atomic_rename_no_replace(
    source: str,
    target: str,
    *,
    src_dir_fd: int,
    dst_dir_fd: int,
) -> None:
    """Atomically rename one descriptor-relative entry without replacement."""

    for value, label in ((source, "source"), (target, "target")):
        if (
            type(value) is not str
            or value in ("", ".", "..")
            or "/" in value
            or "\x00" in value
        ):
            raise ValueError(f"atomic rename {label} is not a safe component")
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith("linux"):
        rename = getattr(library, "renameat2", None)
        flags = 1  # RENAME_NOREPLACE
    elif sys.platform == "darwin":
        rename = getattr(library, "renameatx_np", None)
        flags = 0x00000004  # RENAME_EXCL
    else:
        raise RuntimeError(
            "atomic no-replace rename is unsupported on this platform"
        )
    if rename is None:
        raise RuntimeError(
            "atomic no-replace rename is unavailable on this platform"
        )
    rename.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    rename.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = rename(
        src_dir_fd,
        os.fsencode(source),
        dst_dir_fd,
        os.fsencode(target),
        flags,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number in (errno.EEXIST, errno.ENOTEMPTY):
        raise FileExistsError(error_number, os.strerror(error_number), target)
    if error_number in (
        errno.ENOSYS,
        getattr(errno, "ENOTSUP", errno.EINVAL),
        getattr(errno, "EOPNOTSUPP", errno.EINVAL),
    ):
        raise RuntimeError(
            "atomic no-replace rename is unsupported by this filesystem"
        )
    raise OSError(error_number, os.strerror(error_number), target)


def _retirement_tombstone_name(
    command_id: str, identity: tuple[int, int]
) -> str:
    return f".retiring-{command_id}-{identity[0]}-{identity[1]}"


def _retirement_survivors(names: set[str]) -> tuple[str, ...]:
    for offset in range(len(_COMMAND_STABLE_NAMES) + 1):
        survivors = _COMMAND_STABLE_NAMES[offset:]
        if names == set(survivors):
            return survivors
    raise ValueError(
        "retirement tombstone is not a deterministic crash-prefix layout"
    )


class _RetirementHandles:
    """Descriptor-bound locks retained after a command directory is renamed."""

    def __init__(
        self,
        directory_descriptor: int,
        directory_identity: tuple[int, int],
        entry_descriptors: dict[str, int],
        entry_identities: dict[str, tuple[int, int]],
    ) -> None:
        self.directory_descriptor = directory_descriptor
        self.directory_identity = directory_identity
        self.entry_descriptors = entry_descriptors
        self.entry_identities = entry_identities

    def close(self) -> None:
        descriptors = tuple(self.entry_descriptors.values())
        directory_descriptor = self.directory_descriptor
        self.entry_descriptors.clear()
        self.directory_descriptor = -1
        cleanup_error = _cleanup_retirement_descriptors(
            descriptors, directory_descriptor
        )
        if cleanup_error is not None:
            raise cleanup_error


def _cleanup_retirement_descriptors(
    entry_descriptors: Any,
    directory_descriptor: int,
) -> BaseException | None:
    """Attempt every unlock and close, retaining the first cleanup error."""

    first_error: BaseException | None = None
    for descriptor in tuple(entry_descriptors):
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        except BaseException as exc:
            if first_error is None:
                first_error = exc
        try:
            os.close(descriptor)
        except BaseException as exc:
            if first_error is None:
                first_error = exc
    if directory_descriptor >= 0:
        try:
            os.close(directory_descriptor)
        except BaseException as exc:
            if first_error is None:
                first_error = exc
    return first_error


def _close_retirement_scope(
    handles: _RetirementHandles | None,
    commands_descriptor: int,
) -> None:
    """Close every retirement owner and raise the first cleanup error."""

    first_error: BaseException | None = None
    if handles is not None:
        try:
            handles.close()
        except BaseException as exc:
            first_error = exc
    try:
        os.close(commands_descriptor)
    except BaseException as exc:
        if first_error is None:
            first_error = exc
    if first_error is not None:
        raise first_error


def _private_owner_is_current(metadata: os.stat_result) -> bool:
    return not hasattr(os, "geteuid") or metadata.st_uid == os.geteuid()


def _validate_retirement_directory_metadata(
    metadata: os.stat_result,
    expected_identity: tuple[int, int],
) -> None:
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or (metadata.st_dev, metadata.st_ino) != expected_identity
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or not _private_owner_is_current(metadata)
    ):
        raise ValueError("retirement command directory binding is unsafe")


def _validate_retirement_entry_metadata(
    metadata: os.stat_result,
    *,
    identity: tuple[int, int] | None = None,
) -> None:
    if (
        not stat.S_ISREG(metadata.st_mode)
        or (identity is not None and (metadata.st_dev, metadata.st_ino) != identity)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or not _private_owner_is_current(metadata)
        or metadata.st_size != 0
    ):
        raise ValueError("retirement command entry is unsafe")


def _descriptor_names(
    descriptor: int, maximum: int, label: str
) -> list[str]:
    names: list[str] = []
    with os.scandir(descriptor) as entries:
        for entry in entries:
            if len(names) >= maximum:
                raise ValueError(f"{label} exceeds {maximum} entries")
            name = entry.name
            if name in ("", ".", "..") or "/" in name or "\x00" in name:
                raise ValueError(f"{label} contains an unsafe entry")
            names.append(name)
    return sorted(names)


def _revalidate_retirement_handles(
    commands_descriptor: int,
    directory_name: str,
    handles: _RetirementHandles,
    expected_names: tuple[str, ...],
) -> None:
    directory_metadata = os.fstat(handles.directory_descriptor)
    visible_directory = os.stat(
        directory_name,
        dir_fd=commands_descriptor,
        follow_symlinks=False,
    )
    _validate_retirement_directory_metadata(
        directory_metadata, handles.directory_identity
    )
    _validate_retirement_directory_metadata(
        visible_directory, handles.directory_identity
    )
    names = _descriptor_names(
        handles.directory_descriptor,
        len(_COMMAND_STABLE_NAMES) + 1,
        "retirement command directory",
    )
    if names != sorted(expected_names):
        raise ValueError("retirement command directory layout changed")
    if set(handles.entry_descriptors) != set(expected_names):
        raise ValueError("retirement command descriptor set changed")
    for name in expected_names:
        descriptor = handles.entry_descriptors[name]
        opened = os.fstat(descriptor)
        visible = os.stat(
            name,
            dir_fd=handles.directory_descriptor,
            follow_symlinks=False,
        )
        identity = handles.entry_identities[name]
        _validate_retirement_entry_metadata(opened, identity=identity)
        _validate_retirement_entry_metadata(visible, identity=identity)


def _open_retirement_handles(
    commands_descriptor: int,
    directory_name: str,
    expected_identity: tuple[int, int],
    expected_names: tuple[str, ...],
) -> _RetirementHandles | None:
    directory_descriptor = -1
    entry_descriptors: dict[str, int] = {}
    entry_identities: dict[str, tuple[int, int]] = {}
    try:
        directory_descriptor = os.open(
            directory_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=commands_descriptor,
        )
        os.set_inheritable(directory_descriptor, False)
        opened_directory = os.fstat(directory_descriptor)
        visible_directory = os.stat(
            directory_name,
            dir_fd=commands_descriptor,
            follow_symlinks=False,
        )
        _validate_retirement_directory_metadata(
            opened_directory, expected_identity
        )
        _validate_retirement_directory_metadata(
            visible_directory, expected_identity
        )
        names = _descriptor_names(
            directory_descriptor,
            len(_COMMAND_STABLE_NAMES) + 1,
            "retirement command directory",
        )
        if names != sorted(expected_names):
            raise ValueError("retirement command directory layout changed")
        for name in expected_names:
            descriptor = os.open(
                name,
                os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=directory_descriptor,
            )
            entry_descriptors[name] = descriptor
            os.set_inheritable(descriptor, False)
            opened = os.fstat(descriptor)
            visible = os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
            identity = (opened.st_dev, opened.st_ino)
            _validate_retirement_entry_metadata(opened, identity=identity)
            _validate_retirement_entry_metadata(visible, identity=identity)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                if exc.errno in (errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK):
                    cleanup_error = _cleanup_retirement_descriptors(
                        entry_descriptors.values(), directory_descriptor
                    )
                    entry_descriptors.clear()
                    directory_descriptor = -1
                    if cleanup_error is not None:
                        raise cleanup_error
                    return None
                raise
            entry_identities[name] = identity
        handles = _RetirementHandles(
            directory_descriptor,
            expected_identity,
            entry_descriptors,
            entry_identities,
        )
        directory_descriptor = -1
        entry_descriptors = {}
        try:
            _revalidate_retirement_handles(
                commands_descriptor,
                directory_name,
                handles,
                expected_names,
            )
        except BaseException:
            handles.close()
            raise
        return handles
    except FileNotFoundError as exc:
        raise ValueError("retirement command binding disappeared") from exc
    finally:
        cleanup_error = _cleanup_retirement_descriptors(
            entry_descriptors.values(), directory_descriptor
        )
        if cleanup_error is not None:
            raise cleanup_error


def _validate_tombstone_unlocked(
    root: Path,
    tombstone_name: str,
    match: re.Match[str],
) -> tuple[tuple[int, int], tuple[str, ...]]:
    command_id, device_text, inode_text = match.groups()
    _identifier(command_id, "retirement tombstone commandId")
    device = int(device_text)
    inode = int(inode_text)
    if device > (1 << 64) - 1 or inode > (1 << 64) - 1:
        raise ValueError("retirement tombstone identity is out of range")
    identity = (device, inode)
    path = _control_path(root, COMMANDS_DIRECTORY_NAME) / tombstone_name
    metadata = _assert_private_directory(path, "retirement command directory")
    _validate_retirement_directory_metadata(metadata, identity)
    names = set(
        _bounded_names(
            path,
            len(_COMMAND_STABLE_NAMES) + 1,
            "retirement command directory",
        )
    )
    survivors = _retirement_survivors(names)
    for name in survivors:
        entry = _assert_private_file(
            path / name, f"retirement command {name}"
        )
        _validate_retirement_entry_metadata(entry)
    return identity, survivors


def _inspect_command_entries_unlocked(
    root: Path,
) -> tuple[set[str], dict[str, tuple[str, tuple[int, int], tuple[str, ...]]]]:
    commands_root = _control_path(root, COMMANDS_DIRECTORY_NAME)
    names = _bounded_names(
        commands_root,
        MAX_SESSION_COMMANDS * 2 + 1,
        "private commands directory",
    )
    active: set[str] = set()
    tombstones: dict[
        str, tuple[str, tuple[int, int], tuple[str, ...]]
    ] = {}
    for name in names:
        if name.startswith(".retiring-"):
            match = _RETIREMENT_TOMBSTONE_RE.fullmatch(name)
            if match is None:
                raise ValueError("private commands directory has a malformed tombstone")
            command_id = match.group(1)
            if command_id in tombstones:
                raise ValueError("private commands directory has duplicate tombstones")
            identity, survivors = _validate_tombstone_unlocked(
                root, name, match
            )
            tombstones[command_id] = (name, identity, survivors)
            continue
        active.add(_identifier(name, "command directory name"))
    if active.intersection(tombstones):
        raise ValueError("active command and retirement tombstone are ambiguous")
    if len(active) + len(tombstones) > MAX_SESSION_COMMANDS:
        raise ValueError("session command count exceeds its limit")
    return active, tombstones


def _open_commands_descriptor(root: Path) -> tuple[Any, int, str]:
    authority = safe_io._active_rooted_io()
    commands = _control_path(root, COMMANDS_DIRECTORY_NAME)
    relative = authority._relative(commands)
    descriptor = authority._open_directory_unchecked(relative)
    try:
        authority._validate_directory(relative, descriptor)
    except BaseException as exc:
        try:
            os.close(descriptor)
        except BaseException as cleanup_exc:
            raise cleanup_exc from exc
        raise
    return authority, descriptor, relative


def _delete_locked_tombstone_unlocked(
    root: Path,
    commands_descriptor: int,
    commands_relative: str,
    tombstone_name: str,
    handles: _RetirementHandles,
    survivors: tuple[str, ...],
) -> None:
    authority = safe_io._active_rooted_io()
    _revalidate_retirement_handles(
        commands_descriptor,
        tombstone_name,
        handles,
        survivors,
    )
    remaining = list(survivors)
    for name in survivors:
        descriptor = handles.entry_descriptors[name]
        opened = os.fstat(descriptor)
        visible = os.stat(
            name,
            dir_fd=handles.directory_descriptor,
            follow_symlinks=False,
        )
        identity = handles.entry_identities[name]
        _validate_retirement_entry_metadata(opened, identity=identity)
        _validate_retirement_entry_metadata(visible, identity=identity)
        os.unlink(name, dir_fd=handles.directory_descriptor)
        remaining.pop(0)
        if _descriptor_names(
            handles.directory_descriptor,
            len(_COMMAND_STABLE_NAMES) + 1,
            "retirement command directory",
        ) != sorted(remaining):
            raise ValueError("retirement command directory changed during deletion")
        os.fsync(handles.directory_descriptor)
        _command_recovery_checkpoint(
            "after_retire_unlink",
            _control_path(root, COMMANDS_DIRECTORY_NAME)
            / tombstone_name
            / name,
        )
    if _descriptor_names(
        handles.directory_descriptor,
        1,
        "retirement command directory",
    ):
        raise ValueError("retirement command directory is not empty")
    os.fsync(handles.directory_descriptor)
    authority._validate_directory(commands_relative, commands_descriptor)
    visible = os.stat(
        tombstone_name,
        dir_fd=commands_descriptor,
        follow_symlinks=False,
    )
    _validate_retirement_directory_metadata(
        visible, handles.directory_identity
    )
    os.rmdir(tombstone_name, dir_fd=commands_descriptor)
    os.fsync(commands_descriptor)
    authority._validate_directory(commands_relative, commands_descriptor)
    _command_recovery_checkpoint(
        "after_retire_rmdir",
        _control_path(root, COMMANDS_DIRECTORY_NAME) / tombstone_name,
    )


def _resume_tombstone_unlocked(
    root: Path,
    tombstone: tuple[str, tuple[int, int], tuple[str, ...]],
) -> bool:
    tombstone_name, identity, survivors = tombstone
    authority, commands_descriptor, commands_relative = (
        _open_commands_descriptor(root)
    )
    handles: _RetirementHandles | None = None
    try:
        handles = _open_retirement_handles(
            commands_descriptor,
            tombstone_name,
            identity,
            survivors,
        )
        if handles is None:
            return False
        _delete_locked_tombstone_unlocked(
            root,
            commands_descriptor,
            commands_relative,
            tombstone_name,
            handles,
            survivors,
        )
        return True
    finally:
        _close_retirement_scope(handles, commands_descriptor)


def _recover_retirement_tombstones_unlocked(root: Path) -> None:
    _active, tombstones = _inspect_command_entries_unlocked(root)
    for command_id in sorted(tombstones):
        if not _resume_tombstone_unlocked(root, tombstones[command_id]):
            raise TimeoutError("retirement tombstone is still leased")


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


_RECOVERY_CLAIM_ISSUER = object()


class CommandRecoveryClaim(CommandLayoutReservation):
    """A live, server-constructed recovery supervisor claim."""

    def __init__(
        self,
        *,
        root: Path,
        command_id: str,
        session_id: str,
        generation: int,
        state: dict[str, Any],
        authority: Any,
        lease_context: Any,
        lease: Any,
        group_lease_identity: str,
        group_lease_context: Any = None,
        group_lease: Any = None,
        _issuer: object | None = None,
    ) -> None:
        if _issuer is not _RECOVERY_CLAIM_ISSUER:
            raise ValueError(
                "recovery authority requires a server-issued recovery claim"
            )
        super().__init__(
            root=root,
            command_id=command_id,
            authority=authority,
            lease_context=lease_context,
            lease=lease,
            group_lease_identity=group_lease_identity,
        )
        self._session_id = session_id
        self._generation = generation
        self._state = copy.deepcopy(state)
        self._group_lease_context = group_lease_context
        self._group_lease = group_lease

    @property
    def state(self) -> dict[str, Any]:
        return copy.deepcopy(self._state)

    def _accept_state(self, state: dict[str, Any]) -> None:
        self._state = copy.deepcopy(state)

    def transition(self, state: Any) -> dict[str, Any]:
        candidate = transition_command_state(
            self._root,
            self._session_id,
            self._generation,
            state,
            supervisor_lease=self,
        )
        self._accept_state(candidate)
        return copy.deepcopy(candidate)

    def refresh(self) -> dict[str, Any]:
        self._revalidate(self._root, self._command_id)
        state = read_command_state(
            self._root, self._command_id, self._session_id
        )
        if state["supervisor"] != self._state["supervisor"]:
            raise ValueError("recovery claim supervisor changed")
        self._accept_state(state)
        return copy.deepcopy(state)

    def close(self) -> None:
        _ISSUED_RECOVERY_CLAIMS.discard(self)
        if self._closed:
            return
        group_error: BaseException | None = None
        if self._group_lease_context is not None:
            try:
                self._group_lease_context.__exit__(None, None, None)
            except BaseException as exc:
                group_error = exc
            finally:
                self._group_lease_context = None
                self._group_lease = None
        try:
            super().close()
        finally:
            if group_error is not None:
                raise group_error


_ISSUED_RECOVERY_CLAIMS: weakref.WeakSet[CommandRecoveryClaim] = (
    weakref.WeakSet()
)


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
        with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
            _validate_control_layout_unlocked(root)
            session = _load_session_unlocked(root)
            intent = _load_terminal_intent_unlocked(
                root, session["sessionId"], session["generation"]
            )
            return copy.deepcopy(intent)


def read_command_states(
    root: Path, session_id: str, generation: int
) -> list[dict[str, Any]]:
    """Return one authorized bounded snapshot of all durable commands."""

    root = Path(root).absolute()
    with _with_rooted_read(root):
        with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
            _validate_control_layout_unlocked(root)
            session = _load_session_unlocked(root)
            _authorize_session(session, session_id, generation)
            _load_terminal_intent_unlocked(
                root, session["sessionId"], session["generation"]
            )
            return copy.deepcopy(_scan_commands_unlocked(root, session))


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


@safe_io._rooted_attempt_mutation
def takeover_session(
    root: Path,
    session_id: str,
    generation: int,
    new_owner_pid: int,
    new_owner_birth_identity: str,
    *,
    process_backend: Any,
) -> dict[str, Any]:
    """Atomically replace an absent owner only when every supervisor is stale."""

    root = Path(root).absolute()
    session_id = _identifier(session_id, "sessionId")
    generation = _integer(generation, "generation", minimum=1)
    new_owner_pid = _integer(new_owner_pid, "new ownerPid", minimum=1)
    new_owner_birth_identity = _text(
        new_owner_birth_identity,
        "new ownerBirthIdentity",
        maximum=_MAX_IDENTITY_BYTES,
    )
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] == "committed":
            raise ValueError("committed session ownership is immutable")
        if process_backend.predecessor_absent(
            session["ownerPid"], session["ownerBirthIdentity"]
        ) is not True:
            raise PermissionError("live session owner blocks takeover")
        if (
            process_backend.current_identity(new_owner_pid)
            != new_owner_birth_identity
        ):
            raise ValueError("new session owner identity changed")

        states = _scan_commands_unlocked(root, session)
        authority = safe_io._RootedIO(root.parent.parent)
        claims: list[tuple[Any, Any]] = []
        try:
            for state in states:
                if state["stage"] == "committed":
                    continue
                context = authority.lease(
                    _command_path(
                        root, state["commandId"], "supervisor.lease"
                    ),
                    timeout=0.0,
                )
                lease = context.__enter__()
                claims.append((context, lease))
                if lease.identity != state["supervisor"]["leaseIdentity"]:
                    raise ValueError(
                        "takeover supervisor lease identity changed"
                    )
                if process_backend.predecessor_absent(
                    state["supervisor"]["pid"],
                    state["supervisor"]["birthIdentity"],
                ) is not True:
                    raise ValueError(
                        "takeover found a live command supervisor identity"
                    )

            if process_backend.predecessor_absent(
                session["ownerPid"], session["ownerBirthIdentity"]
            ) is not True:
                raise PermissionError("session owner reappeared during takeover")
            first = process_backend.current_identity(new_owner_pid)
            second = process_backend.current_identity(new_owner_pid)
            if first != new_owner_birth_identity or second != first:
                raise ValueError("new session owner changed during takeover")
            candidate = copy.deepcopy(session)
            candidate.update(
                ownerPid=new_owner_pid,
                ownerBirthIdentity=new_owner_birth_identity,
                generation=session["generation"] + 1,
            )
            content = encode_session(candidate)
            safe_io._active_rooted_io().atomic_write(
                _control_path(root, SESSION_FILE_NAME), content, 0o600
            )
            return copy.deepcopy(candidate)
        finally:
            release_error: BaseException | None = None
            for context, _lease in reversed(claims):
                try:
                    context.__exit__(None, None, None)
                except BaseException as exc:
                    if release_error is None:
                        release_error = exc
            authority.close()
            if release_error is not None:
                raise release_error


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
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] != "active":
            raise ValueError("new command reservations require an active session")
        _recover_retirement_tombstones_unlocked(root)

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
            if len(states) >= MAX_SESSION_COMMANDS:
                raise ValueError("session command count exceeds its limit")
            if (
                sum(item["stage"] != "committed" for item in states)
                >= MAX_ACTIVE_COMMANDS
            ):
                raise ValueError("session active command count exceeds its limit")
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


def _validate_unprepared_command_unlocked(
    root: Path, command_id: str
) -> tuple[int, int]:
    command_root = _command_path(root, command_id)
    metadata = _assert_private_directory(
        command_root, "unprepared private command directory"
    )
    names = set(
        _bounded_names(
            command_root,
            len(_COMMAND_STABLE_NAMES) + 1,
            "unprepared private command directory",
        )
    )
    if names != set(_COMMAND_STABLE_NAMES):
        raise ValueError("unprepared private command layout is not exact")
    for name in _COMMAND_STABLE_NAMES:
        entry = _assert_private_file(
            command_root / name, f"unprepared private command {name}"
        )
        _validate_retirement_entry_metadata(entry)
    return metadata.st_dev, metadata.st_ino


def _read_private_file_snapshot(
    path: Path, maximum: int, label: str
) -> tuple[tuple[int, int], bytes]:
    authority = safe_io._active_rooted_io()
    parent, name, parent_relative, _relative = authority._parent(path)
    descriptor = -1
    try:
        authority._validate_directory(parent_relative, parent)
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent,
        )
        os.set_inheritable(descriptor, False)
        opened = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino)
        if (
            not stat.S_ISREG(opened.st_mode)
            or stat.S_IMODE(opened.st_mode) != 0o600
            or not _private_owner_is_current(opened)
            or opened.st_size > maximum
        ):
            raise ValueError(f"{label} is unsafe or oversized")
        visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(visible.st_mode)
            or (visible.st_dev, visible.st_ino) != identity
            or stat.S_IMODE(visible.st_mode) != 0o600
            or not _private_owner_is_current(visible)
        ):
            raise ValueError(f"{label} binding changed")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        content = b"".join(chunks)
        if len(content) > maximum:
            raise ValueError(f"{label} exceeds {maximum} bytes")
        final_opened = os.fstat(descriptor)
        final_visible = os.stat(
            name, dir_fd=parent, follow_symlinks=False
        )
        if (
            (final_opened.st_dev, final_opened.st_ino) != identity
            or (final_visible.st_dev, final_visible.st_ino) != identity
            or final_opened.st_size != len(content)
            or final_visible.st_size != len(content)
        ):
            raise ValueError(f"{label} changed while read")
        authority._validate_directory(parent_relative, parent)
        return identity, content
    except FileNotFoundError as exc:
        raise ValueError(f"{label} disappeared") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def _capture_recovery_snapshot_unlocked(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
) -> dict[str, Any]:
    session = _load_session_unlocked(root)
    _authorize_session(session, session_id, generation)
    _load_terminal_intent_unlocked(
        root, session["sessionId"], session["generation"]
    )
    if session["state"] == "committed":
        raise ValueError("committed session command state is immutable")
    active, tombstones = _inspect_command_entries_unlocked(root)
    if command_id in tombstones or command_id not in active:
        raise ValueError("recovery command layout is not active")
    _validate_command_layout_unlocked(root, command_id)
    state = _load_command_state_unlocked(
        root, command_id, session["sessionId"]
    )
    if state["creationGeneration"] > session["generation"]:
        raise ValueError("command creationGeneration exceeds session generation")
    if state["stage"] == "committed":
        raise ValueError("committed command state is immutable")
    session_identity, session_content = _read_private_file_snapshot(
        _control_path(root, SESSION_FILE_NAME),
        MAX_SESSION_STATE_BYTES,
        "private session state",
    )
    state_identity, state_content = _read_private_file_snapshot(
        _command_path(root, command_id, "state.json"),
        MAX_COMMAND_STATE_BYTES,
        "private command state",
    )
    if bounded_io._decode_json_bytes(session_content) != session:
        raise ValueError("private session state changed while captured")
    if bounded_io._decode_json_bytes(state_content) != state:
        raise ValueError("private command state changed while captured")
    return {
        "session": copy.deepcopy(session),
        "sessionIdentity": session_identity,
        "sessionContent": session_content,
        "state": copy.deepcopy(state),
        "stateIdentity": state_identity,
        "stateContent": state_content,
    }


def _verify_recovery_snapshot_unlocked(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
    snapshot: dict[str, Any],
) -> dict[str, Any]:
    session = _load_session_unlocked(root)
    _authorize_session(session, session_id, generation)
    _load_terminal_intent_unlocked(
        root, session["sessionId"], session["generation"]
    )
    if session != snapshot["session"]:
        raise ValueError("session changed during recovery claim")
    session_identity, session_content = _read_private_file_snapshot(
        _control_path(root, SESSION_FILE_NAME),
        MAX_SESSION_STATE_BYTES,
        "private session state",
    )
    if (
        session_identity != snapshot["sessionIdentity"]
        or session_content != snapshot["sessionContent"]
    ):
        raise ValueError("session binding changed during recovery claim")
    active, tombstones = _inspect_command_entries_unlocked(root)
    if command_id in tombstones or command_id not in active:
        raise ValueError("recovery command layout changed")
    _validate_command_layout_unlocked(root, command_id)
    state = _load_command_state_unlocked(
        root, command_id, session["sessionId"]
    )
    state_identity, state_content = _read_private_file_snapshot(
        _command_path(root, command_id, "state.json"),
        MAX_COMMAND_STATE_BYTES,
        "private command state",
    )
    if (
        state != snapshot["state"]
        or state_identity != snapshot["stateIdentity"]
        or state_content != snapshot["stateContent"]
    ):
        raise ValueError("command state changed during recovery claim")
    return state


def _validate_live_claim_lease(
    authority: Any,
    path: Path,
    lease: Any,
    expected_identity: str,
    label: str,
) -> None:
    opened = os.fstat(lease.descriptor)
    visible = authority.stat(path, missing_ok=True)
    if (
        visible is None
        or not stat.S_ISREG(opened.st_mode)
        or not stat.S_ISREG(visible.st_mode)
        or _inode_identity(opened) != expected_identity
        or _inode_identity(visible) != expected_identity
        or stat.S_IMODE(opened.st_mode) != 0o600
        or stat.S_IMODE(visible.st_mode) != 0o600
        or not _private_owner_is_current(opened)
        or not _private_owner_is_current(visible)
    ):
        raise ValueError(f"{label} binding changed")


@safe_io._rooted_attempt_mutation
def retire_unprepared_command_layout(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
) -> bool:
    """Atomically tombstone and retire one never-prepared command layout."""

    root = Path(root).absolute()
    command_id = _identifier(command_id, "commandId")
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] == "committed":
            raise ValueError("committed session command layouts are immutable")
        active, tombstones = _inspect_command_entries_unlocked(root)
        tombstone = tombstones.get(command_id)
        if tombstone is not None:
            return _resume_tombstone_unlocked(root, tombstone)
        if command_id not in active:
            return False

        command_root = _command_path(root, command_id)
        names = set(
            _bounded_names(
                command_root,
                len(_COMMAND_STABLE_NAMES) + 2,
                "private command directory",
            )
        )
        if "state.json" in names:
            _validate_command_layout_unlocked(root, command_id)
            return False
        identity = _validate_unprepared_command_unlocked(root, command_id)
        authority, commands_descriptor, commands_relative = (
            _open_commands_descriptor(root)
        )
        handles: _RetirementHandles | None = None
        try:
            handles = _open_retirement_handles(
                commands_descriptor,
                command_id,
                identity,
                _COMMAND_STABLE_NAMES,
            )
            if handles is None:
                return False
            _command_recovery_checkpoint(
                "after_retire_snapshot", command_root
            )
            _revalidate_retirement_handles(
                commands_descriptor,
                command_id,
                handles,
                _COMMAND_STABLE_NAMES,
            )
            tombstone_name = _retirement_tombstone_name(
                command_id, identity
            )
            # Threat boundary: .commands.lock serializes cooperative same-owner
            # writers. No-replace plus inode checks and rollback bounds one-shot
            # races; a continuously malicious same-EUID actor is outside it.
            _command_recovery_checkpoint(
                "before_retire_rename",
                _control_path(root, COMMANDS_DIRECTORY_NAME)
                / tombstone_name,
            )
            try:
                _atomic_rename_no_replace(
                    command_id,
                    tombstone_name,
                    src_dir_fd=commands_descriptor,
                    dst_dir_fd=commands_descriptor,
                )
            except FileExistsError as exc:
                raise ValueError("retirement tombstone already exists") from exc
            try:
                renamed = os.stat(
                    tombstone_name,
                    dir_fd=commands_descriptor,
                    follow_symlinks=False,
                )
                opened = os.fstat(handles.directory_descriptor)
                _validate_retirement_directory_metadata(opened, identity)
                _validate_retirement_directory_metadata(renamed, identity)
            except BaseException as verification_error:
                rollback_error: BaseException | None = None
                try:
                    _atomic_rename_no_replace(
                        tombstone_name,
                        command_id,
                        src_dir_fd=commands_descriptor,
                        dst_dir_fd=commands_descriptor,
                    )
                except BaseException as exc:
                    rollback_error = exc
                try:
                    os.fsync(commands_descriptor)
                    authority._validate_directory(
                        commands_relative, commands_descriptor
                    )
                except BaseException as exc:
                    if rollback_error is None:
                        rollback_error = exc
                if rollback_error is not None:
                    raise ValueError(
                        "retirement source binding changed and rollback failed"
                    ) from rollback_error
                raise ValueError(
                    "retirement source binding changed before rename"
                ) from verification_error
            os.fsync(commands_descriptor)
            authority._validate_directory(
                commands_relative, commands_descriptor
            )
            _revalidate_retirement_handles(
                commands_descriptor,
                tombstone_name,
                handles,
                _COMMAND_STABLE_NAMES,
            )
            _command_recovery_checkpoint(
                "after_retire_rename",
                _control_path(root, COMMANDS_DIRECTORY_NAME)
                / tombstone_name,
            )
            _delete_locked_tombstone_unlocked(
                root,
                commands_descriptor,
                commands_relative,
                tombstone_name,
                handles,
                _COMMAND_STABLE_NAMES,
            )
            return True
        finally:
            _close_retirement_scope(handles, commands_descriptor)


@safe_io._rooted_attempt_mutation
def claim_command_recovery(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
    *,
    process_backend: Any,
    timeout: float = 0.0,
) -> CommandRecoveryClaim:
    """Exclusively replace an absent command supervisor with this process."""

    root = Path(root).absolute()
    session_id = _identifier(session_id, "sessionId")
    generation = _integer(generation, "session generation", minimum=1)
    command_id = _identifier(command_id, "commandId")
    if (
        type(timeout) not in (int, float)
        or timeout < 0
        or timeout != timeout
    ):
        raise ValueError("recovery claim timeout must be non-negative")
    current_identity = getattr(process_backend, "current_identity", None)
    predecessor_absent = getattr(
        process_backend, "predecessor_absent", None
    )
    if not callable(current_identity) or not callable(predecessor_absent):
        raise ValueError("recovery claim requires a stable process backend")

    long_authority = safe_io._RootedIO(root.parent.parent)
    supervisor_context: Any = None
    supervisor_lease: Any = None
    supervisor_entered = False
    group_context: Any = None
    group_lease: Any = None
    group_entered = False
    claim: CommandRecoveryClaim | None = None
    transferred = False

    def release_acquired_leases() -> BaseException | None:
        nonlocal supervisor_context
        nonlocal supervisor_lease
        nonlocal supervisor_entered
        nonlocal group_context
        nonlocal group_lease
        nonlocal group_entered
        cleanup_error: BaseException | None = None
        if group_entered:
            try:
                group_context.__exit__(None, None, None)
            except BaseException as exc:
                cleanup_error = exc
        group_context = None
        group_lease = None
        group_entered = False
        if supervisor_entered:
            try:
                supervisor_context.__exit__(None, None, None)
            except BaseException as exc:
                if cleanup_error is None:
                    cleanup_error = exc
        supervisor_context = None
        supervisor_lease = None
        supervisor_entered = False
        return cleanup_error

    try:
        deadline = time.monotonic() + min(float(timeout), 5.0)
        supervisor_path = _command_path(root, command_id, "supervisor.lease")
        while True:
            try:
                with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
                    _validate_control_layout_unlocked(root)
                    with _stable_lock(
                        _command_path(root, command_id, "state.lock")
                    ):
                        snapshot = _capture_recovery_snapshot_unlocked(
                            root, session_id, generation, command_id
                        )
                        state = snapshot["state"]
                        supervisor_context = long_authority.lease(
                            supervisor_path, timeout=0.0
                        )
                        supervisor_lease = supervisor_context.__enter__()
                        supervisor_entered = True
                        if (
                            supervisor_lease.identity
                            != state["supervisor"]["leaseIdentity"]
                        ):
                            raise ValueError(
                                "recovery supervisor lease identity changed"
                            )
                        if state["stage"] == "prepared":
                            group_path = _command_path(
                                root, command_id, "group.lease"
                            )
                            group_context = long_authority.lease(
                                group_path, timeout=0.0
                            )
                            group_lease = group_context.__enter__()
                            group_entered = True
                            if (
                                group_lease.identity
                                != state["anchorReservation"][
                                    "groupLeaseIdentity"
                                ]
                            ):
                                raise ValueError(
                                    "recovery group lease identity changed"
                                )
                        _verify_recovery_snapshot_unlocked(
                            root,
                            session_id,
                            generation,
                            command_id,
                            snapshot,
                        )
                break
            except TimeoutError:
                cleanup_error = release_acquired_leases()
                if cleanup_error is not None:
                    raise cleanup_error
                now = time.monotonic()
                if now >= deadline:
                    raise
                time.sleep(min(0.05, max(0.0, deadline - now)))

        replacement_birth_identity = _text(
            current_identity(os.getpid()),
            "recovery supervisor birthIdentity",
            maximum=_MAX_IDENTITY_BYTES,
        )
        predecessor = state["supervisor"]
        same_current_recovery = (
            predecessor["role"] == "recovery"
            and predecessor["pid"] == os.getpid()
            and predecessor["birthIdentity"] == replacement_birth_identity
        )
        candidate = copy.deepcopy(state)
        if same_current_recovery:
            write_required = False
        else:
            if predecessor_absent(
                predecessor["pid"], predecessor["birthIdentity"]
            ) is not True:
                raise ValueError("prior command supervisor is still present")
            candidate["supervisor"] = {
                "pid": os.getpid(),
                "birthIdentity": replacement_birth_identity,
                "leaseIdentity": supervisor_lease.identity,
                "role": "recovery",
                "predecessor": supervisor_fingerprint(predecessor),
            }
            validate_command_transition(
                state,
                candidate,
                session_id=session_id,
                generation=generation,
            )
            write_required = True
        content = encode_command_state(candidate)
        claim = CommandRecoveryClaim(
            root=root,
            command_id=command_id,
            session_id=session_id,
            generation=generation,
            state=candidate,
            authority=long_authority,
            lease_context=supervisor_context,
            lease=supervisor_lease,
            group_lease_identity=state["anchorReservation"][
                "groupLeaseIdentity"
            ],
            group_lease_context=group_context if group_entered else None,
            group_lease=group_lease if group_entered else None,
            _issuer=_RECOVERY_CLAIM_ISSUER,
        )
        _ISSUED_RECOVERY_CLAIMS.add(claim)

        with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
            _validate_control_layout_unlocked(root)
            with _stable_lock(
                _command_path(root, command_id, "state.lock")
            ):
                stored = _verify_recovery_snapshot_unlocked(
                    root,
                    session_id,
                    generation,
                    command_id,
                    snapshot,
                )
                _validate_live_claim_lease(
                    long_authority,
                    supervisor_path,
                    supervisor_lease,
                    state["supervisor"]["leaseIdentity"],
                    "recovery supervisor lease",
                )
                if group_entered:
                    _validate_live_claim_lease(
                        long_authority,
                        _command_path(root, command_id, "group.lease"),
                        group_lease,
                        state["anchorReservation"][
                            "groupLeaseIdentity"
                        ],
                        "recovery group lease",
                    )
                if write_required:
                    safe_io._active_rooted_io().atomic_write(
                        _command_path(root, command_id, "state.json"),
                        content,
                        0o600,
                    )
        transferred = True
        return claim
    finally:
        if not transferred:
            if claim is not None:
                _ISSUED_RECOVERY_CLAIMS.discard(claim)
            cleanup_error = release_acquired_leases()
            long_authority.close()
            if cleanup_error is not None:
                raise cleanup_error


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
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        return _create_command_state_unlocked(
            root, candidate, content, supervisor_lease
        )


def _create_command_state_unlocked(
    root: Path,
    candidate: dict[str, Any],
    content: bytes,
    supervisor_lease: CommandLayoutReservation,
) -> dict[str, Any]:
    """Install a prevalidated state while the caller holds ``.commands.lock``."""

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
    names = set(_bounded_names(command_root, 7, "private command directory"))
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


def _authorize_persisted_supervisor_unlocked(
    root: Path,
    persisted: dict[str, Any],
    supervisor_lease: CommandLayoutReservation | None,
) -> None:
    """Authorize a lock-held mutation against the exact persisted supervisor."""

    supervisor = persisted["supervisor"]
    if supervisor["role"] == "recovery":
        if (
            type(supervisor_lease) is not CommandRecoveryClaim
            or supervisor_lease not in _ISSUED_RECOVERY_CLAIMS
        ):
            raise ValueError(
                "recovery-owned command mutation requires its exact live "
                "server-issued recovery claim"
            )
        assert isinstance(supervisor_lease, CommandRecoveryClaim)
        if (
            supervisor_lease._session_id != persisted["sessionId"]
            or supervisor_lease._state["supervisor"] != supervisor
        ):
            raise ValueError(
                "recovery claim disagrees with the persisted supervisor"
            )
    elif type(supervisor_lease) is not CommandLayoutReservation:
        raise ValueError(
            "launch-owned command mutation requires its live launch reservation"
        )
    assert isinstance(supervisor_lease, CommandLayoutReservation)
    supervisor_lease._revalidate(root, persisted["commandId"])
    if supervisor["pid"] != os.getpid():
        raise ValueError("command supervisor pid must be the current process")
    if (
        supervisor["leaseIdentity"] != supervisor_lease.identity
        or persisted["anchorReservation"]
        != supervisor_lease.anchor_reservation
    ):
        raise ValueError(
            "command supervisor disagrees with its live reservation"
        )
    supervisor_lease._revalidate(root, persisted["commandId"])


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
            if previous["supervisor"] != candidate["supervisor"]:
                raise ValueError(
                    "public command transition cannot replace its persisted supervisor"
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
            _authorize_persisted_supervisor_unlocked(
                root, previous, supervisor_lease
            )
            safe_io._active_rooted_io().atomic_write(
                _command_path(root, candidate["commandId"], "state.json"),
                content,
                0o600,
            )
            if isinstance(supervisor_lease, CommandRecoveryClaim):
                supervisor_lease._accept_state(candidate)
            return copy.deepcopy(candidate)


@safe_io._rooted_attempt_mutation
def persist_command_stop_intent(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
    kind: str,
) -> dict[str, Any]:
    """Persist an authorized external stop before any group signal is sent."""

    root = Path(root).absolute()
    command_id = _identifier(command_id, "commandId")
    if kind not in ("expected", "cancel"):
        raise ValueError("command stop kind must be expected or cancel")
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] == "committed":
            raise ValueError("committed session commands are immutable")
        _validate_command_layout_unlocked(root, command_id)
        with _stable_lock(_command_path(root, command_id, "state.lock")):
            persisted = _load_command_state_unlocked(
                root, command_id, session["sessionId"]
            )
            if kind == "expected" and persisted["request"]["stopPolicy"] != "expected-term":
                raise ValueError("expected stop requires expected-term policy")
            if persisted["stage"] in (
                "anchor_stop_requested",
                "stop_requested",
            ):
                if persisted["stopIntent"]["kind"] != kind:
                    raise ValueError("command already has a different stop intent")
                return copy.deepcopy(persisted)
            target = {
                "anchored": "anchor_stop_requested",
                "running": "stop_requested",
            }.get(persisted["stage"])
            if target is None:
                raise ValueError("command is not externally stoppable")
            candidate = copy.deepcopy(persisted)
            candidate["stage"] = target
            candidate["stopIntent"] = {
                "kind": kind,
                "requestedAt": _utc_now(),
                "killAuthorizedAt": None,
            }
            candidate = validate_command_transition(
                persisted,
                candidate,
                session_id=session["sessionId"],
                generation=session["generation"],
            )
            safe_io._active_rooted_io().atomic_write(
                _command_path(root, command_id, "state.json"),
                encode_command_state(candidate),
                0o600,
            )
            return copy.deepcopy(candidate)


@safe_io._rooted_attempt_mutation
def persist_command_kill_authorization(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
) -> dict[str, Any]:
    """Persist grace expiry before an external SIGKILL escalation."""

    root = Path(root).absolute()
    command_id = _identifier(command_id, "commandId")
    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] == "committed":
            raise ValueError("committed session commands are immutable")
        _validate_command_layout_unlocked(root, command_id)
        with _stable_lock(_command_path(root, command_id, "state.lock")):
            persisted = _load_command_state_unlocked(
                root, command_id, session["sessionId"]
            )
            if persisted["stage"] not in (
                "anchor_stop_requested",
                "stop_requested",
            ):
                raise ValueError("command has no active stop intent")
            if persisted["stopIntent"]["killAuthorizedAt"] is not None:
                return copy.deepcopy(persisted)
            candidate = copy.deepcopy(persisted)
            candidate["stopIntent"]["killAuthorizedAt"] = _utc_now()
            candidate = validate_command_transition(
                persisted,
                candidate,
                session_id=session["sessionId"],
                generation=session["generation"],
            )
            safe_io._active_rooted_io().atomic_write(
                _command_path(root, command_id, "state.json"),
                encode_command_state(candidate),
                0o600,
            )
            return copy.deepcopy(candidate)


def _write_stable_private_content(
    path: Path,
    content: bytes,
    expected_identity: tuple[int, int],
) -> None:
    """Rewrite one reserved inode without replacing its lease-visible binding."""

    authority = safe_io._active_rooted_io()
    parent, name, parent_relative, _relative = authority._parent(path)
    descriptor = -1
    try:
        authority._validate_directory(parent_relative, parent)
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent,
        )
        os.set_inheritable(descriptor, False)
        opened = os.fstat(descriptor)
        visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(visible.st_mode)
            or (opened.st_dev, opened.st_ino) != expected_identity
            or (visible.st_dev, visible.st_ino) != expected_identity
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
            raise ValueError("command recovery spool binding changed")
        os.ftruncate(descriptor, 0)
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("command recovery spool write made no progress")
            view = view[written:]
        os.fsync(descriptor)
        observed = os.fstat(descriptor)
        visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (
            (observed.st_dev, observed.st_ino) != expected_identity
            or (visible.st_dev, visible.st_ino) != expected_identity
            or observed.st_size != len(content)
            or visible.st_size != len(content)
        ):
            raise ValueError("command recovery spool changed while writing")
        os.fsync(parent)
        authority._validate_directory(parent_relative, parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


@safe_io._rooted_attempt_mutation
def write_command_recovery_spools(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
    stdout: bytes,
    stderr: bytes,
    *,
    supervisor_lease: CommandLayoutReservation,
) -> dict[str, Any]:
    """Persist bounded capture bytes while retaining every stable inode."""

    root = Path(root).absolute()
    command_id = _identifier(command_id, "commandId")
    if type(stdout) is not bytes or type(stderr) is not bytes:
        raise ValueError("command recovery spools must be bytes")
    if len(stdout) > _LOG_LIMIT or len(stderr) > _LOG_LIMIT:
        raise ValueError("command recovery spool exceeds its limit")
    paths = {
        "stdout": _command_path(root, command_id, "stdout.recovery"),
        "stderr": _command_path(root, command_id, "stderr.recovery"),
    }
    identities: dict[str, tuple[int, int]] = {}

    def authorize() -> dict[str, Any]:
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _authorize_session(session, session_id, generation)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        _validate_command_layout_unlocked(root, command_id)
        persisted = _load_command_state_unlocked(
            root, command_id, session["sessionId"]
        )
        if persisted["stage"] not in (
            "anchored",
            "anchor_stop_requested",
            "running",
            "stop_requested",
        ):
            raise ValueError("command recovery spools require a live command")
        _authorize_persisted_supervisor_unlocked(
            root, persisted, supervisor_lease
        )
        return persisted

    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        with _stable_lock(_command_path(root, command_id, "state.lock")):
            persisted = authorize()
            for name, path in paths.items():
                metadata = _assert_private_file(
                    path, f"command {name} recovery spool"
                )
                identities[name] = (metadata.st_dev, metadata.st_ino)

    _write_stable_private_content(paths["stdout"], stdout, identities["stdout"])
    _write_stable_private_content(paths["stderr"], stderr, identities["stderr"])

    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        with _stable_lock(_command_path(root, command_id, "state.lock")):
            persisted = authorize()
            for name, path in paths.items():
                metadata = _assert_private_file(
                    path, f"command {name} recovery spool"
                )
                if (metadata.st_dev, metadata.st_ino) != identities[name]:
                    raise ValueError("command recovery spool binding changed")
            return copy.deepcopy(persisted)


def _private_entry_is_owned(metadata: os.stat_result, *, directory: bool) -> bool:
    expected_mode = 0o700 if directory else 0o600
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    return (
        expected_type(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == expected_mode
        and (
            not hasattr(os, "geteuid")
            or metadata.st_uid == os.geteuid()
        )
    )


def _open_private_directory_at(
    parent: int, name: str, label: str
) -> int:
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent,
    )
    os.set_inheritable(descriptor, False)
    opened = os.fstat(descriptor)
    visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if (
        not _private_entry_is_owned(opened, directory=True)
        or not _private_entry_is_owned(visible, directory=True)
        or (opened.st_dev, opened.st_ino) != (visible.st_dev, visible.st_ino)
    ):
        os.close(descriptor)
        raise ValueError(f"{label} directory binding is unsafe")
    return descriptor


def _validate_private_file_at(parent: int, name: str, label: str) -> None:
    metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not _private_entry_is_owned(metadata, directory=False):
        raise ValueError(f"{label} file binding is unsafe")


def _bounded_descriptor_names(
    descriptor: int, maximum: int, label: str
) -> list[str]:
    names = os.listdir(descriptor)
    if len(names) > maximum:
        raise ValueError(f"{label} contains too many entries")
    if any(type(name) is not str or not name or "/" in name for name in names):
        raise ValueError(f"{label} contains an invalid entry name")
    return sorted(names)


def _delete_control_retirement_unlocked(root: Path) -> None:
    """Resume deletion of an already-verified committed control tombstone."""

    authority = safe_io._active_rooted_io()
    tombstone = root / CONTROL_RETIREMENT_NAME
    parent, tombstone_name, parent_relative, _relative = authority._parent(
        tombstone
    )
    control_descriptor = -1
    commands_descriptor = -1
    try:
        authority._validate_directory(parent_relative, parent)
        control_descriptor = _open_private_directory_at(
            parent, tombstone_name, "control retirement"
        )
        control_names = set(
            _bounded_descriptor_names(
                control_descriptor, 4, "control retirement directory"
            )
        )
        allowed_control = {
            COMMANDS_LOCK_NAME,
            SESSION_FILE_NAME,
            TERMINAL_INTENT_FILE_NAME,
            COMMANDS_DIRECTORY_NAME,
        }
        if not control_names.issubset(allowed_control):
            raise ValueError("control retirement contains an unknown entry")

        if COMMANDS_DIRECTORY_NAME in control_names:
            commands_descriptor = _open_private_directory_at(
                control_descriptor,
                COMMANDS_DIRECTORY_NAME,
                "retired commands",
            )
            command_names = _bounded_descriptor_names(
                commands_descriptor,
                MAX_SESSION_COMMANDS,
                "retired commands directory",
            )
            allowed_command_files = set(_COMMAND_STABLE_NAMES) | {"state.json"}
            for command_id in command_names:
                _identifier(command_id, "retired command directory name")
                command_descriptor = _open_private_directory_at(
                    commands_descriptor, command_id, "retired command"
                )
                try:
                    names = set(
                        _bounded_descriptor_names(
                            command_descriptor,
                            len(allowed_command_files),
                            "retired command directory",
                        )
                    )
                    if not names.issubset(allowed_command_files):
                        raise ValueError(
                            "retired command contains an unknown entry"
                        )
                    for name in sorted(names):
                        _validate_private_file_at(
                            command_descriptor, name, f"retired command {name}"
                        )
                    for name in sorted(names):
                        os.unlink(name, dir_fd=command_descriptor)
                        os.fsync(command_descriptor)
                finally:
                    os.close(command_descriptor)
                os.rmdir(command_id, dir_fd=commands_descriptor)
                os.fsync(commands_descriptor)
            os.close(commands_descriptor)
            commands_descriptor = -1
            os.rmdir(COMMANDS_DIRECTORY_NAME, dir_fd=control_descriptor)
            os.fsync(control_descriptor)

        remaining = set(
            _bounded_descriptor_names(
                control_descriptor, 3, "control retirement directory"
            )
        )
        allowed_files = {
            COMMANDS_LOCK_NAME,
            SESSION_FILE_NAME,
            TERMINAL_INTENT_FILE_NAME,
        }
        if not remaining.issubset(allowed_files):
            raise ValueError("control retirement file set is invalid")
        for name in sorted(remaining):
            _validate_private_file_at(
                control_descriptor, name, f"retired control {name}"
            )
        for name in sorted(remaining):
            os.unlink(name, dir_fd=control_descriptor)
            os.fsync(control_descriptor)
        os.close(control_descriptor)
        control_descriptor = -1
        os.rmdir(tombstone_name, dir_fd=parent)
        os.fsync(parent)
        authority._validate_directory(parent_relative, parent)
    finally:
        if commands_descriptor >= 0:
            os.close(commands_descriptor)
        if control_descriptor >= 0:
            os.close(control_descriptor)
        os.close(parent)


@safe_io._rooted_attempt_mutation
def cleanup_committed_control_layout(root: Path) -> bool:
    """Retire verified committed private control state, resumably after rename."""

    root = Path(root).absolute()
    authority = safe_io._active_rooted_io()
    control = _control_path(root)
    tombstone = root / CONTROL_RETIREMENT_NAME
    control_metadata = authority.stat(control, missing_ok=True)
    tombstone_metadata = authority.stat(tombstone, missing_ok=True)
    if control_metadata is None:
        if tombstone_metadata is None:
            return False
        _delete_control_retirement_unlocked(root)
        return True
    if tombstone_metadata is not None:
        raise ValueError("control state and retirement tombstone coexist")
    if not _private_entry_is_owned(control_metadata, directory=True):
        raise ValueError("private control directory is unsafe")
    control_identity = (control_metadata.st_dev, control_metadata.st_ino)

    with _stable_lock(_control_path(root, COMMANDS_LOCK_NAME)):
        _validate_control_layout_unlocked(root)
        session = _load_session_unlocked(root)
        _load_terminal_intent_unlocked(
            root, session["sessionId"], session["generation"]
        )
        if session["state"] != "committed":
            raise ValueError("control retirement requires a committed session")
        states = _scan_commands_unlocked(root, session)
        if any(state["stage"] != "committed" for state in states):
            raise ValueError("control retirement requires committed commands")
        for state in states:
            with _stable_lock(
                _command_path(root, state["commandId"], "state.lock")
            ):
                pass
            lease_authority = safe_io._RootedIO(root.parent.parent)
            try:
                for lease_name, expected in (
                    (
                        "supervisor.lease",
                        state["supervisor"]["leaseIdentity"],
                    ),
                    (
                        "group.lease",
                        state["anchorReservation"]["groupLeaseIdentity"],
                    ),
                ):
                    context = lease_authority.lease(
                        _command_path(root, state["commandId"], lease_name),
                        timeout=0.0,
                    )
                    lease = context.__enter__()
                    try:
                        if lease.identity != expected:
                            raise ValueError(
                                "control retirement lease identity changed"
                            )
                    finally:
                        context.__exit__(None, None, None)
            finally:
                lease_authority.close()

    current = authority.stat(control, missing_ok=True)
    if current is None or (current.st_dev, current.st_ino) != control_identity:
        raise ValueError("private control directory changed before retirement")
    parent, control_name, parent_relative, _relative = authority._parent(control)
    try:
        authority._validate_directory(parent_relative, parent)
        _atomic_rename_no_replace(
            control_name,
            CONTROL_RETIREMENT_NAME,
            src_dir_fd=parent,
            dst_dir_fd=parent,
        )
        renamed = os.stat(
            CONTROL_RETIREMENT_NAME,
            dir_fd=parent,
            follow_symlinks=False,
        )
        if (renamed.st_dev, renamed.st_ino) != control_identity:
            raise ValueError("control retirement directory identity changed")
        os.fsync(parent)
        authority._validate_directory(parent_relative, parent)
    finally:
        os.close(parent)
    _delete_control_retirement_unlocked(root)
    return True


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
    "CONTROL_RETIREMENT_NAME",
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
    "CommandRecoveryClaim",
    "initialize_control_layout",
    "read_session",
    "read_terminal_intent",
    "read_command_states",
    "transition_session_state",
    "takeover_session",
    "reserve_command_layout",
    "retire_unprepared_command_layout",
    "claim_command_recovery",
    "create_command_state",
    "read_command_state",
    "transition_command_state",
    "persist_command_stop_intent",
    "persist_command_kill_authorization",
    "write_command_recovery_spools",
    "cleanup_committed_control_layout",
    "record_terminal_diagnostic",
)
