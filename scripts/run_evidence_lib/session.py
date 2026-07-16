"""Stable owner and bounded borrower authority for evidence sessions."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Callable

from . import command_state, safe_io


MAX_ANCESTRY_PROCESSES = 64


def _process_backend() -> Any:
    from .command_supervisor import ProcessBackend

    return ProcessBackend()


def _positive_pid(value: Any, label: str) -> int:
    if type(value) is not int or value < 1:
        raise ValueError(f"{label} must be a positive integer")
    return value


def _session_result(session: dict[str, Any], role: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "sessionId": session["sessionId"],
        "generation": session["generation"],
        "state": session["state"],
        "role": role,
        "ownerPid": session["ownerPid"],
    }


def _observe_identity_twice(backend: Any, pid: int) -> str:
    first = backend.current_identity(pid)
    second = backend.current_identity(pid)
    if first != second:
        raise ValueError("process birth identity changed during observation")
    return first


def _caller_role(
    session: dict[str, Any], caller_pid: int, backend: Any
) -> str:
    """Authorize only the owner or a cycle-free bounded descendant."""

    caller_pid = _positive_pid(caller_pid, "caller pid")
    owner_pid = session["ownerPid"]
    owner_identity = session["ownerBirthIdentity"]
    seen: set[int] = set()
    current = caller_pid
    for depth in range(MAX_ANCESTRY_PROCESSES):
        if current in seen:
            raise ValueError("process ancestry contains a cycle")
        seen.add(current)
        identity = _observe_identity_twice(backend, current)
        if current == owner_pid:
            if identity != owner_identity:
                raise PermissionError("session owner birth identity changed")
            return "owner" if depth == 0 else "borrower"
        parent = backend.parent_pid(current)
        if parent < 1 or parent == current:
            break
        current = parent
    raise PermissionError("caller is not the session owner or a bounded descendant")


def claim_session(
    root: Path,
    owner_pid: int,
    *,
    caller_pid: int | None = None,
    process_backend: Any | None = None,
    session_id_factory: Callable[[], str] | None = None,
) -> dict[str, Any]:
    """Create or idempotently verify the immediate parent's owner claim."""

    root = Path(root).absolute()
    owner_pid = _positive_pid(owner_pid, "owner pid")
    caller_pid = os.getppid() if caller_pid is None else _positive_pid(
        caller_pid, "caller pid"
    )
    if owner_pid != caller_pid:
        raise PermissionError("owner pid must equal the CLI immediate parent")
    backend = _process_backend() if process_backend is None else process_backend
    owner_identity = _observe_identity_twice(backend, owner_pid)
    control = root / command_state.CONTROL_DIRECTORY_NAME
    if control.exists():
        session = command_state.read_session(root)
        try:
            role = _caller_role(session, caller_pid, backend)
        except (PermissionError, ProcessLookupError):
            if backend.predecessor_absent(
                session["ownerPid"], session["ownerBirthIdentity"]
            ) is not True:
                raise PermissionError("an active owner session already exists")
            stored = command_state.takeover_session(
                root,
                session["sessionId"],
                session["generation"],
                owner_pid,
                owner_identity,
                process_backend=backend,
            )
            return _session_result(stored, "owner")
        if role != "owner":
            raise PermissionError("an active owner session already exists")
        return _session_result(session, role)

    if session_id_factory is None:
        session_id_factory = lambda: os.urandom(16).hex()
    candidate = {
        "schemaVersion": 1,
        "sessionId": command_state._identifier(
            session_id_factory(), "sessionId"
        ),
        "runId": root.name,
        "ownerPid": owner_pid,
        "ownerBirthIdentity": owner_identity,
        "state": "active",
        "generation": 1,
        "startedAt": safe_io._utc_now(),
    }
    stored = command_state.initialize_control_layout(root, candidate)
    if backend.current_identity(owner_pid) != owner_identity:
        raise ValueError("session owner changed during claim")
    return _session_result(stored, "owner")


def session_status(
    root: Path,
    session_id: str,
    generation: int,
    *,
    caller_pid: int | None = None,
    process_backend: Any | None = None,
) -> dict[str, Any]:
    root = Path(root).absolute()
    session_id = command_state._identifier(session_id, "sessionId")
    generation = command_state._integer(generation, "generation", minimum=1)
    caller_pid = os.getppid() if caller_pid is None else _positive_pid(
        caller_pid, "caller pid"
    )
    backend = _process_backend() if process_backend is None else process_backend
    session = command_state.read_session(root)
    if session["sessionId"] != session_id or session["generation"] != generation:
        raise ValueError("session status authorization is stale")
    role = _caller_role(session, caller_pid, backend)
    return _session_result(session, role)


def close_session(
    root: Path,
    session_id: str,
    generation: int,
    *,
    caller_pid: int | None = None,
    process_backend: Any | None = None,
) -> dict[str, Any]:
    status = session_status(
        root,
        session_id,
        generation,
        caller_pid=caller_pid,
        process_backend=process_backend,
    )
    if status["role"] != "owner":
        raise PermissionError("only the exact session owner may close the launch gate")
    stored = command_state.transition_session_state(
        root, session_id, generation, "finalizing"
    )
    return _session_result(stored, "owner")


def record_session_intent(
    root: Path,
    session_id: str,
    generation: int,
    diagnostic: Any,
    *,
    caller_pid: int | None = None,
    process_backend: Any | None = None,
) -> dict[str, Any]:
    """Allow borrowers to defer failures while reserving pass for the owner."""

    status = session_status(
        root,
        session_id,
        generation,
        caller_pid=caller_pid,
        process_backend=process_backend,
    )
    validated = command_state.validate_caller_diagnostic(diagnostic)
    if status["role"] != "owner" and validated["status"] == "passed":
        raise PermissionError("only the session owner may record pass intent")
    return command_state.record_terminal_diagnostic(
        root, session_id, generation, validated
    )


def _finalize_request(intent: dict[str, Any]) -> dict[str, Any]:
    primary = intent["primary"]
    if primary is None:
        raise ValueError("session finalization requires durable terminal intent")
    request = {
        "status": primary["status"],
        "classification": primary["classification"],
        "phase": None if primary["status"] == "passed" else primary["phase"],
        "command_status": primary["commandStatus"],
    }
    if primary["status"] != "passed":
        request.update(
            error_code=primary["errorCode"],
            summary_text=primary["summary"],
            hint=primary["hint"],
        )
    return request


def finalize_session(
    root: Path,
    session_id: str,
    generation: int,
    *,
    caller_pid: int | None = None,
    process_backend: Any | None = None,
) -> dict[str, Any]:
    """Recover commands, commit the owner intent, and retire private control."""

    from . import commands
    from .command_supervisor import recover_command
    from . import summaries

    root = Path(root).absolute()
    control = root / command_state.CONTROL_DIRECTORY_NAME
    retirement = root / command_state.CONTROL_RETIREMENT_NAME
    summary_path = root / "run-summary.json"
    if not control.exists() and summary_path.exists():
        publication_root = summaries._publication_root_for_attempt(root)
        attempt_relative = summaries._attempt_root_relative(
            publication_root, root
        )
        with safe_io._rooted_io(publication_root, mutation=False):
            summary, _content = summaries.bounded_io._read_json_bounded(
                summary_path
            )
            fingerprint = summary.get("finalizeRequestFingerprint")
            if type(fingerprint) is not str:
                raise ValueError("retired session summary fingerprint is missing")
            completed = summaries._completed_finalize_result(
                publication_root,
                attempt_relative,
                fingerprint,
            )
        if completed is None:
            raise ValueError("retired session finalize receipt is missing")
        if retirement.exists():
            command_state.cleanup_committed_control_layout(root)
        return completed
    status = session_status(
        root,
        session_id,
        generation,
        caller_pid=caller_pid,
        process_backend=process_backend,
    )
    if status["role"] != "owner":
        raise PermissionError("only the exact session owner may finalize")
    if status["state"] not in ("finalizing", "committed"):
        raise ValueError("session must close its launch gate before finalization")

    states = command_state.read_command_states(root, session_id, generation)
    for state in states:
        if state["stage"] == "committed":
            commands.verify_committed_command_materialization(
                root, session_id, generation, state["commandId"]
            )
        else:
            recovered = recover_command(
                root, session_id, generation, state["commandId"]
            )
            if recovered["stage"] != "committed":
                raise ValueError("command recovery did not commit its evidence")

    intent = command_state.read_terminal_intent(root)
    request = _finalize_request(intent)
    summary = summaries._finalize_attempt(root, **request)
    command_state.transition_session_state(
        root, session_id, generation, "committed"
    )
    command_state.cleanup_committed_control_layout(root)
    return summary


__all__ = (
    "MAX_ANCESTRY_PROCESSES",
    "claim_session",
    "session_status",
    "close_session",
    "record_session_intent",
    "finalize_session",
)
