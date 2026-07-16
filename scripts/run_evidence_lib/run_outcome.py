"""Strict consumer for the internal, versioned zmr run-outcome sidecar."""

from __future__ import annotations

import copy
import re
import stat
from pathlib import Path, PurePosixPath
from typing import Any

from . import bounded_io, command_state, journal, lifecycle, safe_io, sanitization
from . import session as session_api
from .constants import ERROR_CLASSIFICATION, MAX_STRUCTURED_JSON_BYTES, PHASES


MAX_RUN_OUTCOME_BYTES = 64 * 1024
_COMMAND_ID = re.compile(r"^[0-9a-f]{32}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_OUTCOME_KEYS = {
    "schemaVersion",
    "status",
    "failureOwner",
    "errorCode",
    "phase",
    "summary",
    "hint",
    "trace",
    "report",
    "childStatus",
    "iosShim",
}
_IOS_SHIM_KEYS = {"targetKind", "mode", "digest"}
_OWNER_CLASSIFICATION = {
    "runner": "runner_failure",
    "app": "app_failure",
    "configuration": "configuration_failure",
    "infrastructure": "infrastructure_failure",
}


def _closed_object(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    unknown = sorted(set(value) - expected)
    missing = sorted(expected - set(value))
    if unknown:
        raise ValueError(f"{label} contains unknown fields: {', '.join(unknown)}")
    if missing:
        raise ValueError(f"{label} is missing fields: {', '.join(missing)}")
    return value


def _text(value: Any, label: str, *, maximum: int) -> str:
    if type(value) is not str or not value or len(value.encode("utf-8")) > maximum:
        raise ValueError(f"{label} must be non-empty bounded text")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise ValueError(f"{label} contains control characters")
    return value


def _optional_text(value: Any, label: str, *, maximum: int) -> str | None:
    if value is None:
        return None
    return _text(value, label, maximum=maximum)


def _relative_path(value: Any, label: str) -> str | None:
    if value is None:
        return None
    text = _text(value, label, maximum=4096)
    if "\\" in text:
        raise ValueError(f"{label} must use normalized separators")
    parsed = PurePosixPath(text)
    if parsed.is_absolute() or not parsed.parts or any(
        part in ("", ".", "..") for part in parsed.parts
    ):
        raise ValueError(f"{label} must be an attempt-relative path")
    if parsed.as_posix() != text:
        raise ValueError(f"{label} must be normalized")
    return text


def validate_run_outcome(value: Any) -> dict[str, Any]:
    outcome = copy.deepcopy(_closed_object(value, _OUTCOME_KEYS, "run outcome"))
    if outcome["schemaVersion"] != 1:
        raise ValueError("run outcome schemaVersion must equal 1")
    status_value = outcome["status"]
    owner = outcome["failureOwner"]
    phase = outcome["phase"]
    if type(status_value) is not str or status_value not in (
        "passed",
        "failed",
        "cancelled",
    ):
        raise ValueError("run outcome status is invalid")
    if type(owner) is not str or owner not in (
        "none",
        "runner",
        "app",
        "configuration",
        "infrastructure",
    ):
        raise ValueError("run outcome failureOwner is invalid")
    if type(phase) is not str or phase not in PHASES:
        raise ValueError("run outcome phase is invalid")

    error_code = _optional_text(
        outcome["errorCode"], "run outcome errorCode", maximum=256
    )
    summary = _optional_text(outcome["summary"], "run outcome summary", maximum=512)
    hint = _optional_text(outcome["hint"], "run outcome hint", maximum=512)
    outcome["trace"] = _relative_path(outcome["trace"], "run outcome trace")
    outcome["report"] = _relative_path(outcome["report"], "run outcome report")
    child_status = outcome["childStatus"]
    if child_status is not None and (
        type(child_status) is not int or not 0 <= child_status <= 255
    ):
        raise ValueError("run outcome childStatus is invalid")

    if status_value == "passed":
        if (
            owner != "none"
            or phase != "complete"
            or any(value is not None for value in (error_code, summary, hint))
            or child_status not in (None, 0)
        ):
            raise ValueError("passed run outcome fields are contradictory")
    elif status_value == "cancelled":
        if (
            owner != "none"
            or error_code != "run.cancelled"
            or summary is None
            or hint is None
        ):
            raise ValueError("cancelled run outcome fields are contradictory")
    else:
        if owner == "none" or error_code is None or summary is None or hint is None:
            raise ValueError("failed run outcome fields are incomplete")
        classification = ERROR_CLASSIFICATION.get(error_code)
        if classification != _OWNER_CLASSIFICATION.get(owner):
            raise ValueError("run outcome failureOwner disagrees with errorCode")

    ios_shim = outcome["iosShim"]
    if ios_shim is not None:
        shim = _closed_object(ios_shim, _IOS_SHIM_KEYS, "run outcome iosShim")
        if shim["targetKind"] not in ("simulator", "physical"):
            raise ValueError("run outcome iosShim targetKind is invalid")
        if shim["mode"] not in ("disabled", "generated", "provided"):
            raise ValueError("run outcome iosShim mode is invalid")
        digest = shim["digest"]
        if shim["mode"] == "disabled":
            if digest is not None:
                raise ValueError("disabled run outcome iosShim must not have a digest")
        elif type(digest) is not str or _DIGEST.fullmatch(digest) is None:
            raise ValueError("enabled run outcome iosShim requires a SHA-256 digest")
    return outcome


def _parse_sidecar_path(value: str) -> tuple[str, str]:
    relative = _relative_path(value, "run outcome path")
    parts = PurePosixPath(relative).parts
    if len(parts) != 2 or parts[0] != "run-outcomes":
        raise ValueError("run outcome path must be directly under run-outcomes")
    filename = parts[1]
    if not filename.endswith(".json"):
        raise ValueError("run outcome path must end in .json")
    command_id = filename[:-5]
    if _COMMAND_ID.fullmatch(command_id) is None:
        raise ValueError("run outcome filename must contain one commandId")
    return relative, command_id


def _read_json_file(root: Path, relative: str, *, maximum: int, label: str) -> dict:
    path = root.joinpath(*PurePosixPath(relative).parts)
    publication_root = journal._publication_root_for_attempt(root)
    with safe_io._rooted_io(publication_root, mutation=False):
        if safe_io._evidence_is_symlink(path) or not safe_io._evidence_is_file(path):
            raise ValueError(f"{label} is missing or unsafe")
        metadata = safe_io._evidence_stat(path)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"{label} must be a regular file")
        value, _byte_count = bounded_io._read_json_bounded(
            path,
            maximum=maximum,
            expected_metadata=metadata,
        )
    if not isinstance(value, dict):
        raise ValueError(f"{label} must contain an object")
    return value


def _command_binding(
    root: Path, session_id: str, command_id: str
) -> tuple[dict, dict, int]:
    state = command_state.read_command_state(root, command_id, session_id)
    if state["stage"] != "committed" or state["outcome"] is None:
        raise ValueError("run outcome command is not committed")
    metadata_relative = state["paths"]["metadata"]
    metadata = _read_json_file(
        root,
        metadata_relative,
        maximum=MAX_STRUCTURED_JSON_BYTES,
        label="run outcome command metadata",
    )
    if metadata.get("commandId") != command_id:
        raise ValueError("run outcome command metadata commandId disagrees with filename")
    termination = metadata.get("termination")
    if not isinstance(termination, dict):
        raise ValueError("run outcome command metadata termination is missing")
    shell_status = termination.get("shellVisibleStatus")
    if type(shell_status) is not int or not 0 <= shell_status <= 255:
        raise ValueError("run outcome command metadata shell status is invalid")
    if state["outcome"]["shellVisibleStatus"] != shell_status:
        raise ValueError("private and public command status disagree")
    return state, metadata, shell_status


def _read_context(root: Path) -> dict:
    return _read_json_file(
        root,
        "run-context.json",
        maximum=MAX_STRUCTURED_JSON_BYTES,
        label="run outcome context",
    )


def _validate_platform_provenance(context: dict, outcome: dict) -> None:
    platform = context.get("platform")
    shim = outcome["iosShim"]
    if platform == "android":
        if shim is not None:
            raise ValueError("Android run outcome must not contain iosShim")
        return
    if platform != "ios" or shim is None:
        raise ValueError("iOS run outcome requires iosShim provenance")
    device_class = context.get("deviceClass")
    expected = (
        "simulator"
        if isinstance(device_class, str) and "simulator" in device_class
        else "physical"
    )
    if shim["targetKind"] != expected:
        raise ValueError("run outcome iosShim targetKind disagrees with context")


def _validate_sanitized(root: Path, outcome: dict) -> None:
    sanitized = sanitization._sanitize_value(
        outcome,
        roots=sanitization._sanitization_roots(root),
        secrets=sanitization._collect_secret_values(),
    )
    if sanitized != outcome:
        raise ValueError("run outcome contains unsanitized content")


def _diagnostic(outcome: dict, source: str) -> dict:
    if outcome["status"] == "passed":
        raise ValueError("passed outcome does not create borrower terminal intent")
    if outcome["status"] == "cancelled":
        classification = "cancelled"
    else:
        classification = _OWNER_CLASSIFICATION[outcome["failureOwner"]]
    return {
        "status": outcome["status"],
        "classification": classification,
        "phase": outcome["phase"],
        "errorCode": outcome["errorCode"],
        "summary": outcome["summary"],
        "hint": outcome["hint"],
        # The sidecar is separately bound to the supervised command status.
        # Keeping it out of terminal intent avoids falsely claiming that the
        # generic command event proved the structured app/runner owner.
        "commandStatus": None,
        "source": source,
    }


def _evidence_invalid_diagnostic() -> dict:
    return {
        "status": "failed",
        "classification": "runner_failure",
        "phase": "scenario.execute",
        "errorCode": "runner.evidence_invalid",
        "summary": "Structured run outcome evidence is invalid",
        "hint": "Inspect the bounded run-outcome sidecar and command binding",
        "commandStatus": None,
        "source": "run-outcome-consumer",
    }


def _record_invalid(
    root: Path,
    session_id: str,
    generation: int,
) -> None:
    session_api.record_session_intent(
        root,
        session_id,
        generation,
        _evidence_invalid_diagnostic(),
    )


def _register_outcome_event(
    root: Path,
    session_id: str,
    generation: int,
    relative: str,
    outcome: dict,
) -> None:
    publication_root = journal._publication_root_for_attempt(root)
    with safe_io._rooted_io(publication_root, mutation=False):
        events = lifecycle._read_bootstrap_events(root)
    matching = [event for event in events if event.get("artifact") == relative]
    expected = {
        "phase": outcome["phase"],
        "status": outcome["status"],
        "errorCode": outcome["errorCode"],
        "summary": outcome["summary"],
        "commandStatus": outcome["childStatus"],
        "artifact": relative,
    }
    if matching:
        if len(matching) != 1 or any(
            matching[0].get(key) != value for key, value in expected.items()
        ):
            raise ValueError("existing run outcome event disagrees with sidecar")
        return
    lifecycle._append_event(
        root,
        outcome["phase"],
        outcome["status"],
        session_id=session_id,
        generation=generation,
        **{
            "errorCode": outcome["errorCode"],
            "summary": outcome["summary"],
            "commandStatus": outcome["childStatus"],
            "artifact": relative,
        },
    )


def consume_run_outcome(root: Path, session_id: str, path: str) -> dict[str, str]:
    """Validate, bind, register, and classify one committed run sidecar."""

    root = Path(root).absolute()
    stored_session = command_state.read_session(root)
    if stored_session["sessionId"] != session_id:
        raise PermissionError("run outcome sessionId does not match active session")
    generation = stored_session["generation"]
    command_status: int | None = None
    try:
        relative, command_id = _parse_sidecar_path(path)
        _state, _metadata, command_status = _command_binding(
            root, session_id, command_id
        )
        outcome = validate_run_outcome(
            _read_json_file(
                root,
                relative,
                maximum=MAX_RUN_OUTCOME_BYTES,
                label="run outcome sidecar",
            )
        )
        if outcome["childStatus"] is not None and outcome["childStatus"] != command_status:
            raise ValueError("run outcome childStatus disagrees with command metadata")
        context = _read_context(root)
        _validate_platform_provenance(context, outcome)
        _validate_sanitized(root, outcome)
        for field in ("trace", "report"):
            artifact = outcome[field]
            if artifact is not None:
                artifact_path = root.joinpath(*PurePosixPath(artifact).parts)
                publication_root = journal._publication_root_for_attempt(root)
                with safe_io._rooted_io(publication_root, mutation=False):
                    valid_kind = safe_io._evidence_is_file(artifact_path) or (
                        field == "trace" and safe_io._evidence_is_dir(artifact_path)
                    )
                    if safe_io._evidence_is_symlink(artifact_path) or not valid_kind:
                        raise ValueError(f"run outcome {field} artifact is missing or unsafe")

        if outcome["status"] != "passed":
            session_api.record_session_intent(
                root,
                session_id,
                generation,
                _diagnostic(outcome, "run-outcome-consumer"),
            )
        artifact_patch = {
            field: outcome[field]
            for field in ("trace", "report")
            if outcome[field] is not None
        }
        if artifact_patch:
            lifecycle.update_context(
                root,
                {"artifacts": artifact_patch},
                session_id=session_id,
                generation=generation,
            )
        _register_outcome_event(
            root, session_id, generation, relative, outcome
        )
        return {"consumed": relative, "status": outcome["status"]}
    except Exception as exc:
        try:
            _record_invalid(root, session_id, generation)
        except Exception as record_error:
            raise ValueError(
                "run outcome evidence is invalid and could not be recorded"
            ) from record_error
        raise ValueError("run outcome evidence is invalid") from exc


def validate_published_run_outcomes(
    root: Path,
    snapshot: Any,
    command_metadata: dict[str, dict],
    events: list[dict],
) -> list[str]:
    """Revalidate every retained sidecar against public bundle evidence."""

    errors: list[str] = []
    relatives = snapshot.relatives()
    outcome_entries = sorted(
        relative
        for relative in relatives
        if relative.startswith("run-outcomes/")
    )
    direct_entries = [
        relative
        for relative in outcome_entries
        if "/" not in relative[len("run-outcomes/") :]
    ]
    for relative in outcome_entries:
        if relative not in direct_entries:
            errors.append(f"{relative}: nested run outcome entries are forbidden")
    metadata_by_id = {
        metadata.get("commandId"): metadata
        for metadata in command_metadata.values()
        if isinstance(metadata, dict) and isinstance(metadata.get("commandId"), str)
    }
    context = None
    context_metadata = snapshot.metadata("run-context.json")
    if context_metadata is not None and stat.S_ISREG(context_metadata.st_mode):
        try:
            context, _bytes = bounded_io._read_json_bounded(
                root / "run-context.json",
                maximum=MAX_STRUCTURED_JSON_BYTES,
                expected_metadata=context_metadata,
            )
        except ValueError as exc:
            errors.append(f"run-context.json: {exc}")

    for relative in direct_entries:
        metadata = snapshot.metadata(relative)
        label = relative
        if (
            metadata is None
            or not stat.S_ISREG(metadata.st_mode)
            or not relative.endswith(".json")
        ):
            errors.append(f"{label}: run outcome entry must be a regular JSON file")
            continue
        try:
            parsed_relative, command_id = _parse_sidecar_path(relative)
            value, _byte_count = bounded_io._read_json_bounded(
                root.joinpath(*PurePosixPath(relative).parts),
                maximum=MAX_RUN_OUTCOME_BYTES,
                expected_metadata=metadata,
            )
            outcome = validate_run_outcome(value)
            if isinstance(context, dict):
                _validate_platform_provenance(context, outcome)
            command = metadata_by_id.get(command_id)
            if command is None:
                raise ValueError("no public command metadata matches commandId")
            termination = command.get("termination")
            shell_status = (
                termination.get("shellVisibleStatus")
                if isinstance(termination, dict)
                else None
            )
            if outcome["childStatus"] is not None and outcome["childStatus"] != shell_status:
                raise ValueError("childStatus disagrees with public command metadata")
            matching_events = [
                event for event in events if event.get("artifact") == parsed_relative
            ]
            if len(matching_events) != 1:
                raise ValueError("sidecar must have exactly one bootstrap event")
            event = matching_events[0]
            expected_event = {
                "phase": outcome["phase"],
                "status": outcome["status"],
                "errorCode": outcome["errorCode"],
                "summary": outcome["summary"],
                "commandStatus": outcome["childStatus"],
            }
            if any(event.get(key) != expected for key, expected in expected_event.items()):
                raise ValueError("bootstrap event disagrees with sidecar")
            for field in ("trace", "report"):
                artifact = outcome[field]
                if artifact is None:
                    continue
                artifact_metadata = snapshot.metadata(artifact)
                valid_kind = artifact_metadata is not None and (
                    stat.S_ISREG(artifact_metadata.st_mode)
                    or (field == "trace" and stat.S_ISDIR(artifact_metadata.st_mode))
                )
                if not valid_kind:
                    raise ValueError(f"{field} artifact is missing or unsafe")
        except (OSError, UnicodeError, ValueError) as exc:
            errors.append(f"{label}: {exc}")
    return sorted(set(errors))


__all__ = (
    "MAX_RUN_OUTCOME_BYTES",
    "validate_run_outcome",
    "consume_run_outcome",
    "validate_published_run_outcomes",
)
