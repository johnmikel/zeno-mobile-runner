"""Operation-specific validation for publication journal candidates."""

from __future__ import annotations

import re

from .constants import (
    ERROR_CLASSIFICATION,
    MAX_EXTERNAL_REMEDIATION_BYTES,
    PHASES,
    _COMMAND_SLUG_RE,
)
from .contracts import _comparability_tuple, _valid_datetime
from .receipts import (
    _finalize_receipt_relative,
    _validate_finalize_receipt_binding,
)


_EXTERNAL_COMMAND_KEYS = {
    "schemaVersion",
    "source",
    "argv",
    "phase",
    "name",
    "failureCode",
    "outcome",
    "remediation",
    "exitStatus",
    "signal",
    "stdout",
    "stderr",
    "limitation",
}
_STREAM_KEYS = {
    "path",
    "originalBytes",
    "sanitizedBytes",
    "storedBytes",
    "truncated",
}


def _is_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _validate_finalize_external_command(
    attempt_relative: str,
    paths: list[str],
    values: dict[str, object],
    events: list[dict],
    terminal: dict,
) -> None:
    """Bind one synthetic hosted-action triplet to its lifecycle events."""

    if len(paths) != 3:
        raise ValueError("finalize external command target set is invalid")
    prefix = re.escape(attempt_relative) + r"/commands/"
    stdout_match = re.fullmatch(
        prefix + r"(?P<sequence>[0-9]{6})-(?P<name>.+)[.]stdout[.]log",
        paths[0],
    )
    if stdout_match is None or _COMMAND_SLUG_RE.fullmatch(
        stdout_match.group("name")
    ) is None:
        raise ValueError("finalize external stdout target is invalid")
    stem = f'{stdout_match.group("sequence")}-{stdout_match.group("name")}'
    expected_paths = [
        f"{attempt_relative}/commands/{stem}.stdout.log",
        f"{attempt_relative}/commands/{stem}.stderr.log",
        f"{attempt_relative}/commands/{stem}.json",
    ]
    if paths != expected_paths:
        raise ValueError("finalize external command targets disagree")

    stdout = values[paths[0]]
    stderr = values[paths[1]]
    metadata = values[paths[2]]
    if not isinstance(stdout, bytes) or not isinstance(stderr, bytes):
        raise ValueError("finalize external command logs are invalid")
    if not isinstance(metadata, dict) or set(metadata) != _EXTERNAL_COMMAND_KEYS:
        raise ValueError("finalize external command metadata shape is invalid")
    remediation = metadata.get("remediation")
    try:
        remediation_size = len(remediation.encode("utf-8"))
    except (AttributeError, UnicodeEncodeError):
        remediation_size = -1
    if (
        not _is_integer(metadata.get("schemaVersion"))
        or metadata.get("schemaVersion") != 1
        or metadata.get("source") != "github-action"
        or metadata.get("argv") != []
        or metadata.get("phase") not in PHASES
        or metadata.get("name") != stdout_match.group("name")
        or metadata.get("failureCode") not in ERROR_CLASSIFICATION
        or metadata.get("outcome") not in ("failure", "cancelled")
        or not isinstance(remediation, str)
        or not remediation.strip()
        or remediation_size < 0
        or remediation_size > MAX_EXTERNAL_REMEDIATION_BYTES
        or metadata.get("exitStatus") is not None
        or metadata.get("signal") is not None
        or metadata.get("limitation")
        != "Synthetic metadata only; hosted log content was not captured."
    ):
        raise ValueError("finalize external command metadata is invalid")
    if (
        metadata["outcome"] == "cancelled"
        and metadata["failureCode"] != "run.cancelled"
    ) or (
        metadata["outcome"] == "failure"
        and metadata["failureCode"] == "run.cancelled"
    ):
        raise ValueError("finalize external command outcome is invalid")

    relative_stem = f"commands/{stem}"
    for stream_name, content in (("stdout", stdout), ("stderr", stderr)):
        stream = metadata.get(stream_name)
        if (
            not isinstance(stream, dict)
            or set(stream) != _STREAM_KEYS
            or stream.get("path") != f"{relative_stem}.{stream_name}.log"
            or not _is_integer(stream.get("originalBytes"))
            or not _is_integer(stream.get("sanitizedBytes"))
            or not _is_integer(stream.get("storedBytes"))
            or stream.get("originalBytes") != len(content)
            or stream.get("sanitizedBytes") != len(content)
            or stream.get("storedBytes") != len(content)
            or stream.get("truncated") is not False
        ):
            raise ValueError("finalize external command stream metadata is invalid")
    expected_stdout = (
        "synthetic external command record. Hosted log content was not captured; "
        "consult the workflow provider for authoritative output.\n"
    ).encode("utf-8")
    expected_stderr = (
        f"synthetic outcome: {metadata['outcome']}. This record does not claim "
        f"hosted log capture.\nremediation: {remediation}\n"
    ).encode("utf-8")
    if stdout != expected_stdout or stderr != expected_stderr:
        raise ValueError("finalize external command log content is invalid")

    if len(events) < 3:
        raise ValueError("finalize external command events are missing")
    started, command_terminal = events[-3:-1]
    metadata_reference = f"{relative_stem}.json"
    expected_status = {
        "failure": "failed",
        "cancelled": "cancelled",
    }[metadata["outcome"]]
    expected_summary = {
        "failure": f"Hosted workflow step {metadata['name']} failed",
        "cancelled": f"Hosted workflow step {metadata['name']} was cancelled",
    }[metadata["outcome"]]
    if (
        terminal.get("phase") != metadata["phase"]
        or terminal.get("errorCode") != metadata["failureCode"]
        or terminal.get("status") != expected_status
        or terminal.get("summary") != expected_summary
    ):
        raise ValueError(
            "finalize external command disagrees with superseding terminal"
        )
    expected_terminal_keys = {
        "schemaVersion",
        "seq",
        "timestamp",
        "phase",
        "status",
        "command",
        "artifact",
        "errorCode",
        "summary",
    }
    if (
        set(started) != {"schemaVersion", "seq", "timestamp", "phase", "status"}
        or started.get("status") != "started"
        or started.get("phase") != metadata["phase"]
        or started.get("seq") != int(stdout_match.group("sequence"))
    ):
        raise ValueError("finalize external command start event is invalid")
    if (
        set(command_terminal) != expected_terminal_keys
        or command_terminal.get("seq") != started["seq"] + 1
        or command_terminal.get("phase") != metadata["phase"]
        or command_terminal.get("status") != expected_status
        or command_terminal.get("command") != metadata_reference
        or command_terminal.get("artifact") != metadata_reference
        or command_terminal.get("errorCode") != metadata["failureCode"]
        or command_terminal.get("summary") != remediation
    ):
        raise ValueError("finalize external command terminal event is invalid")


def _registrations_for_run(index: dict, run_id: str) -> list[tuple[dict, dict]]:
    return [
        (execution, entry)
        for execution in index["executions"]
        for entry in execution["attempts"]
        if entry["runId"] == run_id
    ]


def _validate_transaction_operation(
    operation: str,
    attempt_relative: str,
    required_directories: list[str],
    decoded_targets: list[dict],
    request_fingerprint: str,
) -> None:
    event_path = attempt_relative + "/bootstrap-events.jsonl"
    context_path = attempt_relative + "/run-context.json"
    summary_path = attempt_relative + "/run-summary.json"
    invalid_path = attempt_relative + "/run-summary.invalid.json"
    diagnostic_path = attempt_relative + "/run-summary.invalid.errors.json"
    receipt_path = _finalize_receipt_relative(attempt_relative)
    ordered_paths = [target["path"] for target in decoded_targets]
    values = {target["path"]: target["value"] for target in decoded_targets}
    run_id = attempt_relative.split("/")[-1]

    if operation == "register":
        if (
            ordered_paths != ["attempt-index.json"]
            or required_directories != [attempt_relative]
        ):
            raise ValueError("register transaction target set is invalid")
        registrations = _registrations_for_run(values["attempt-index.json"], run_id)
        if len(registrations) != 1:
            raise ValueError("register transaction index registration is invalid")
        return

    if operation == "init":
        expected_paths = [context_path, event_path, "attempt-index.json"]
        expected_directories = [
            "attempts",
            attempt_relative,
            attempt_relative + "/commands",
            attempt_relative + "/run-outcomes",
        ]
        if (
            ordered_paths != expected_paths
            or required_directories != expected_directories
        ):
            raise ValueError("init transaction target set is invalid")
        context = values[context_path]
        if context.get("runId") != run_id or not _valid_datetime(
            context.get("startedAt")
        ):
            raise ValueError("init transaction context identity is invalid")
        events = values[event_path]
        if [
            (event.get("seq"), event.get("phase"), event.get("status"))
            for event in events
        ] != [
            (1, "evidence.init", "started"),
            (2, "evidence.init", "passed"),
        ]:
            raise ValueError("init transaction event stream is invalid")
        registrations = _registrations_for_run(values["attempt-index.json"], run_id)
        if len(registrations) != 1:
            raise ValueError("init transaction index registration is invalid")
        execution, entry = registrations[0]
        if (
            execution["executionId"] != context["executionId"]
            or execution["comparabilityTuple"]
            != _comparability_tuple(context)
            or entry["attempt"] != context["attempt"]
        ):
            raise ValueError("init transaction index disagrees with context")
        return

    if operation == "context":
        if not ordered_paths or ordered_paths[-1] != "attempt-index.json":
            raise ValueError("context transaction is missing required targets")
        context_paths = ordered_paths[:-1]
        if context_path not in context_paths or context_paths != sorted(context_paths):
            raise ValueError("context transaction target order is invalid")
        if any(
            not re.fullmatch(r"attempts/[^/]+/run-context[.]json", path)
            for path in context_paths
        ):
            raise ValueError("context transaction contains an invalid target")
        expected_directories = sorted(
            {path.rsplit("/", 1)[0] for path in context_paths},
            key=lambda item: (item.count("/"), item),
        )
        if required_directories != expected_directories:
            raise ValueError("context transaction directory set is invalid")
        index = values["attempt-index.json"]
        registrations = _registrations_for_run(index, run_id)
        if len(registrations) != 1:
            raise ValueError("context transaction attempt is not registered")
        execution, _entry = registrations[0]
        registered_attempts = {
            entry["runId"]: entry for entry in execution["attempts"]
        }
        for path in context_paths:
            target_run_id = path.split("/")[1]
            context = values[path]
            entry = registered_attempts.get(target_run_id)
            if (
                entry is None
                or context.get("runId") != target_run_id
                or context.get("executionId") != execution["executionId"]
                or context.get("attempt") != entry["attempt"]
                or _comparability_tuple(context)
                != execution["comparabilityTuple"]
            ):
                raise ValueError(
                    "context transaction target disagrees with the attempt index"
                )
        return

    expected_paths = [event_path, summary_path]
    invalid_expected_paths = [
        invalid_path,
        diagnostic_path,
        event_path,
        summary_path,
    ]
    has_context_target = bool(ordered_paths and ordered_paths[0] == context_path)
    terminal_paths = ordered_paths[1:] if has_context_target else ordered_paths
    external_paths: list[str] = []
    if terminal_paths and terminal_paths[0].startswith(
        attempt_relative + "/commands/"
    ):
        external_paths = terminal_paths[:3]
        terminal_paths = terminal_paths[3:]
    has_receipt_target = bool(
        terminal_paths and terminal_paths[-1] == receipt_path
    )
    lifecycle_paths = terminal_paths[:-1] if has_receipt_target else terminal_paths
    if lifecycle_paths not in (expected_paths, invalid_expected_paths):
        raise ValueError("finalize transaction contains an invalid target set")
    if required_directories != [attempt_relative]:
        raise ValueError("finalize transaction directory set is invalid")
    terminal = values[summary_path]
    if terminal.get("runId") != run_id:
        raise ValueError("finalize transaction summary runId is invalid")
    has_summary_fingerprint = "finalizeRequestFingerprint" in terminal
    if has_receipt_target != has_summary_fingerprint:
        raise ValueError(
            "finalize receipt and summary finalize request fingerprint must "
            "either both be present or both be absent"
        )
    if has_receipt_target:
        summary_request_fingerprint = terminal.get(
            "finalizeRequestFingerprint"
        )
        if summary_request_fingerprint != request_fingerprint:
            raise ValueError(
                "finalize transaction summary finalize request fingerprint "
                "disagrees with transaction"
            )
        summary_target = next(
            target for target in decoded_targets if target["path"] == summary_path
        )
        _validate_finalize_receipt_binding(
            values[receipt_path],
            request_fingerprint=summary_request_fingerprint,
            result_sha256=summary_target["sha256"],
        )
    if has_context_target:
        context = values[context_path]
        context_artifacts = context.get("artifacts")
        context_artifacts = (
            context_artifacts if isinstance(context_artifacts, dict) else {}
        )
        terminal_artifacts = terminal.get("artifacts")
        terminal_artifacts = (
            terminal_artifacts if isinstance(terminal_artifacts, dict) else {}
        )
        if (
            context.get("runId") != run_id
            or context.get("executionId") != terminal.get("executionId")
            or context.get("attempt") != terminal.get("attempt")
            or any(
                context_artifacts.get(field) != terminal_artifacts.get(field)
                for field in ("trace", "report")
            )
        ):
            raise ValueError(
                "finalize transaction context disagrees with terminal summary"
            )
    events = values[event_path]
    if not events:
        raise ValueError("finalize transaction event stream is empty")
    if external_paths:
        _validate_finalize_external_command(
            attempt_relative, external_paths, values, events, terminal
        )
    final_event = events[-1]
    if (
        has_receipt_target
        and final_event.get("timestamp") != terminal.get("finishedAt")
    ):
        raise ValueError(
            "finalize transaction event timestamp disagrees with terminal summary"
        )
    for field in ("phase", "status", "errorCode", "summary", "commandStatus"):
        if final_event.get(field) != terminal.get(field):
            raise ValueError(
                "finalize transaction event disagrees with terminal summary"
            )
    if lifecycle_paths == invalid_expected_paths:
        diagnostics = values[diagnostic_path]
        errors = diagnostics.get("errors")
        if (
            not errors
            or not all(isinstance(error, str) and error for error in errors)
            or errors != sorted(set(errors))
            or terminal.get("classification") != "runner_failure"
            or terminal.get("phase") != "evidence.finalize"
            or terminal.get("errorCode") != "runner.evidence_invalid"
        ):
            raise ValueError("finalize invalid-fallback transaction is invalid")


__all__ = ("_validate_transaction_operation",)
