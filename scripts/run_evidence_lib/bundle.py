"""Evidence bundle validation and public-safety scanning."""

from __future__ import annotations

import argparse
import base64
import binascii
import errno
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import constants as _limits
from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .sanitization import *  # noqa: F401,F403
from .safe_io import *  # noqa: F401,F403
from .journal import *  # noqa: F401,F403
from .lifecycle import *  # noqa: F401,F403
from .summaries import *  # noqa: F401,F403
from .commands import *  # noqa: F401,F403
from .bounded_io import *  # noqa: F401,F403
from .bundle_scan import *  # noqa: F401,F403
from .bundle_consistency import *  # noqa: F401,F403


_MAX_VALIDATION_DIAGNOSTICS = 4096


class _BoundedErrorList(list[str]):
    """Deduplicate diagnostics and cap adversarial per-record error growth."""

    def __init__(self, values=()) -> None:
        super().__init__()
        self._seen: set[str] = set()
        self._overflowed = False
        self.extend(values)

    def append(self, value: str) -> None:
        if value in self._seen or self._overflowed:
            return
        if len(self) >= _MAX_VALIDATION_DIAGNOSTICS:
            overflow = (
                "$: validation diagnostics exceed maximum "
                f"({_MAX_VALIDATION_DIAGNOSTICS})"
            )
            super().append(overflow)
            self._seen.add(overflow)
            self._overflowed = True
            return
        super().append(value)
        self._seen.add(value)

    def extend(self, values) -> None:
        for value in values:
            self.append(value)


def _resolve_bundle_reference(
    root: Path,
    relative: Any,
    label: str,
    errors: list[str],
    *,
    expected: str | None = None,
) -> Path | None:
    if not _valid_relative_path(relative):
        errors.append(f"{label}: reference must be a normalized relative path")
        return None
    root_absolute = root.absolute()
    candidate = root_absolute.joinpath(*relative.split("/"))
    current = root_absolute
    for part in relative.split("/"):
        current = current / part
        if _evidence_is_symlink(current):
            errors.append(f"{label}: referenced path contains a symlink")
            return None
    try:
        _active_rooted_io()._relative(candidate)
    except RootedIOError:
        errors.append(f"{label}: referenced path escapes the attempt root")
        return None
    if not _evidence_exists(candidate):
        errors.append(f"{label}: referenced path does not exist")
        return None
    if expected == "file" and not _evidence_is_file(candidate):
        errors.append(f"{label}: referenced path must be a file")
    elif expected == "directory" and not _evidence_is_dir(candidate):
        errors.append(f"{label}: referenced path must be a directory")
    return candidate


def _validate_command_metadata(
    root: Path, path: Path, metadata: Any, errors: list[str]
) -> None:
    label = path.relative_to(root).as_posix()
    if not isinstance(metadata, dict):
        errors.append(f"{label}: command record must be an object")
        return
    if not _is_integer(metadata.get("schemaVersion")) or metadata["schemaVersion"] != 1:
        errors.append(f"{label}.schemaVersion: must equal 1")
    if metadata.get("source") not in ("subprocess", "github-action"):
        errors.append(f"{label}.source: unknown command record source")
    if not isinstance(metadata.get("failureCode"), str) or not metadata.get(
        "failureCode"
    ):
        errors.append(f"{label}.failureCode: must be a non-empty string")
    elif metadata["failureCode"] not in ERROR_CLASSIFICATION:
        errors.append(f"{label}.failureCode: must be a known error code")
    if metadata.get("phase") not in PHASES:
        errors.append(f"{label}.phase: must be a declared phase")
    try:
        _validate_command_name(metadata.get("name"))
    except ValueError:
        errors.append(f"{label}.name: must be a safe slug")
    if not isinstance(metadata.get("argv"), list) or not all(
        isinstance(item, str) for item in metadata.get("argv", [])
    ):
        errors.append(f"{label}.argv: must be an array of strings")
    exit_status = metadata.get("exitStatus")
    signal_number = metadata.get("signal")
    if exit_status is not None and not _is_integer(exit_status):
        errors.append(f"{label}.exitStatus: must be null or an integer")
    if signal_number is not None and (
        not _is_integer(signal_number) or signal_number <= 0
    ):
        errors.append(f"{label}.signal: must be null or a positive integer")
    if exit_status is not None and signal_number is not None:
        errors.append(f"{label}: exitStatus and signal cannot both be set")
    if metadata.get("source") == "subprocess":
        if exit_status is None and signal_number is None:
            errors.append(f"{label}: subprocess record needs exitStatus or signal")
    elif metadata.get("source") == "github-action":
        if metadata.get("outcome") not in ("success", "failure", "cancelled"):
            errors.append(f"{label}.outcome: must declare the external outcome")
        if not isinstance(metadata.get("limitation"), str) or not metadata.get(
            "limitation"
        ):
            errors.append(f"{label}.limitation: must explain synthetic capture")
        if exit_status is not None:
            errors.append(f"{label}.exitStatus: external records must use null")
        if signal_number is not None:
            errors.append(f"{label}.signal: external records must use null")

    stream_paths = {
        stream_name: (
            metadata.get(stream_name, {}).get("path")
            if isinstance(metadata.get(stream_name), dict)
            else None
        )
        for stream_name in ("stdout", "stderr")
    }
    if (
        isinstance(stream_paths["stdout"], str)
        and stream_paths["stdout"] == stream_paths["stderr"]
    ):
        errors.append(f"{label}.stdout.path and stderr.path: must be distinct")

    for stream_name in ("stdout", "stderr"):
        stream_label = f"{label}.{stream_name}"
        record = metadata.get(stream_name)
        if not isinstance(record, dict):
            errors.append(f"{stream_label}: stream metadata must be an object")
            continue
        original = record.get("originalBytes")
        sanitized = record.get("sanitizedBytes")
        stored = record.get("storedBytes")
        truncated = record.get("truncated")
        if not _is_integer(original) or original < 0:
            errors.append(f"{stream_label}.originalBytes: must be non-negative")
        if not _is_integer(sanitized) or sanitized < 0:
            errors.append(f"{stream_label}.sanitizedBytes: must be non-negative")
        if not _is_integer(stored) or stored < 0:
            errors.append(f"{stream_label}.storedBytes: must be non-negative")
        if not isinstance(truncated, bool):
            errors.append(f"{stream_label}.truncated: must be a boolean")
        stream_path = record.get("path")
        expected_path = f"commands/{path.stem}.{stream_name}.log"
        if isinstance(stream_path, str) and not stream_path.startswith("commands/"):
            errors.append(f"{stream_label}.path: must be under commands/")
        if stream_path != expected_path:
            errors.append(f"{stream_label}.path: must equal {expected_path}")
        referenced = _resolve_bundle_reference(
            root, stream_path, stream_label + ".path", errors, expected="file"
        )
        if referenced is not None and _is_integer(stored):
            if _evidence_stat(referenced).st_size != stored:
                errors.append(
                    f"{stream_label}.storedBytes: does not match referenced log size"
                )
        if _is_integer(sanitized):
            if isinstance(truncated, bool) and truncated != (sanitized > _LOG_LIMIT):
                errors.append(
                    f"{stream_label}.truncated: inconsistent with sanitized byte count"
                )
            if _is_integer(stored) and stored > _LOG_LIMIT:
                errors.append(f"{stream_label}.storedBytes: exceeds the log limit")
            if (
                _is_integer(stored)
                and isinstance(truncated, bool)
                and not truncated
                and stored != sanitized
            ):
                errors.append(
                    f"{stream_label}.storedBytes: must equal untruncated sanitized bytes"
                )


def _command_link_projection(metadata: dict) -> dict:
    """Retain only constant-size fields needed after metadata validation."""

    return {
        "source": (
            metadata.get("source")
            if metadata.get("source") in ("subprocess", "github-action")
            else None
        ),
        "failureCode": (
            metadata.get("failureCode")
            if isinstance(metadata.get("failureCode"), str)
            and metadata.get("failureCode") in ERROR_CLASSIFICATION
            else None
        ),
        "phase": metadata.get("phase") if metadata.get("phase") in PHASES else None,
        "exitStatus": (
            metadata.get("exitStatus")
            if _is_integer(metadata.get("exitStatus"))
            else None
        ),
        "signal": (
            metadata.get("signal")
            if _is_integer(metadata.get("signal"))
            and metadata.get("signal") > 0
            else None
        ),
        "outcome": (
            metadata.get("outcome")
            if metadata.get("outcome") in ("success", "failure", "cancelled")
            else None
        ),
    }


def _command_event_owns_summary(
    event: dict, metadata: dict, summary: Any
) -> bool:
    if not isinstance(summary, dict) or summary.get("commandStatus") is None:
        return False
    command_status = summary.get("commandStatus")
    if (
        metadata.get("source") != "subprocess"
        or metadata.get("exitStatus") != command_status
        or event.get("commandStatus") != command_status
        or event.get("status") != summary.get("status")
    ):
        return False
    if summary.get("status") == "failed":
        return (
            event.get("phase") == summary.get("phase")
            and event.get("errorCode") == summary.get("errorCode")
        )
    return summary.get("status") == "passed"


def _validate_command_event_link(
    root: Path,
    line_number: int,
    event: dict,
    metadata_by_reference: dict[str, dict],
    link_counts: dict[str, int],
    summary: Any,
    errors: list[str],
) -> bool:
    """Validate one command event and report whether it owns the summary."""

    reference = event.get("command")
    if reference is None:
        return False
    label = f"bootstrap-events.jsonl:{line_number}.command"
    if not (
        isinstance(reference, str)
        and _valid_relative_path(reference)
        and reference.startswith("commands/")
        and reference.count("/") == 1
        and reference.endswith(".json")
    ):
        errors.append(f"{label}: must be a command metadata reference")
        return False
    _resolve_bundle_reference(root, reference, label, errors, expected="file")
    metadata = metadata_by_reference.get(reference)
    if metadata is None:
        errors.append(f"{label}: referenced command record is missing")
        return False
    link_counts[reference] += 1
    if event.get("status") not in ("passed", "failed", "cancelled"):
        errors.append(f"{label}: command metadata may only appear on a terminal event")
        return False
    if event.get("phase") != metadata.get("phase"):
        errors.append(f"{label}: phase disagrees with command metadata")

    expected_status = None
    expected_command_status = None
    if metadata.get("source") == "subprocess":
        if metadata.get("signal") is not None:
            expected_status = "cancelled"
        elif _is_integer(metadata.get("exitStatus")):
            expected_command_status = metadata.get("exitStatus")
            expected_status = "passed" if expected_command_status == 0 else "failed"
    elif metadata.get("source") == "github-action":
        expected_status = {
            "success": "passed",
            "failure": "failed",
            "cancelled": "cancelled",
        }.get(metadata.get("outcome"))

    if event.get("status") != expected_status:
        errors.append(f"{label}: event status disagrees with command metadata")
    if event.get("commandStatus") != expected_command_status:
        errors.append(f"{label}: commandStatus disagrees with metadata exitStatus/outcome")
    if expected_status == "passed":
        if event.get("errorCode") is not None:
            errors.append(f"{label}: passed command event must omit errorCode")
    elif event.get("errorCode") != metadata.get("failureCode"):
        errors.append(f"{label}: failureCode disagrees with command metadata")
    return _command_event_owns_summary(event, metadata, summary)


@_rooted_attempt_read
def validate_bundle(root: Path, *, secrets: list[str]) -> list[str]:
    """Validate a complete attempt bundle, including containment and redaction."""

    root = Path(root).absolute()
    errors: list[str] = _BoundedErrorList()
    if _has_pending_transaction_entries(root):
        errors.append(
            "transactions: pending transaction state prevents publication"
        )
        return _finish_errors(errors)
    if _evidence_is_symlink(root):
        errors.append("$: attempt root must not be a symlink")
        return _finish_errors(errors)
    if not _evidence_is_dir(root):
        errors.append("$: attempt root must be a directory")
        return _finish_errors(errors)
    if _scan_publishable_entry_name(root.name, secrets, errors):
        return _finish_errors(errors)
    if not _scan_publishable_files(root, secrets, errors):
        return _finish_errors(errors)

    summary_path = root / "run-summary.json"
    summary = None
    if not _evidence_is_file(summary_path) or _evidence_is_symlink(summary_path):
        errors.append("run-summary.json: terminal summary is missing or unsafe")
    else:
        try:
            summary, _summary_bytes = _read_json_bounded(summary_path)
            errors.extend(
                "run-summary.json" + error[1:] if error.startswith("$") else error
                for error in validate_summary(summary)
            )
        except ValueError as exc:
            errors.append(f"run-summary.json: {exc}")

    if isinstance(summary, dict):
        artifacts = summary.get("artifacts")
        if isinstance(artifacts, dict):
            for field, canonical in (
                ("bootstrapEvents", "bootstrap-events.jsonl"),
                ("commands", "commands"),
            ):
                if artifacts.get(field) != canonical:
                    errors.append(
                        f"run-summary.json.artifacts.{field}: must equal {canonical}"
                    )
            for field, expected in (
                ("bootstrapEvents", "file"),
                ("commands", "directory"),
                ("trace", None),
                ("report", None),
            ):
                if field not in artifacts or artifacts[field] is None:
                    continue
                _resolve_bundle_reference(
                    root,
                    artifacts[field],
                    f"run-summary.json.artifacts.{field}",
                    errors,
                    expected=expected,
                )

    _validate_bundle_consistency(root, summary, errors)

    commands_root = root / "commands"
    metadata_paths = []
    metadata_by_reference = {}
    if _evidence_is_dir(commands_root) and not _evidence_is_symlink(commands_root):
        metadata_paths = sorted(_evidence_glob(commands_root, "*.json"))
    for metadata_path in metadata_paths:
        if _evidence_is_symlink(metadata_path):
            errors.append(
                f"{metadata_path.relative_to(root).as_posix()}: command record is a symlink"
            )
            continue
        try:
            metadata, _metadata_bytes = _read_json_bounded(metadata_path)
        except ValueError as exc:
            errors.append(
                f"{metadata_path.relative_to(root).as_posix()}: {exc}"
            )
            continue
        if isinstance(metadata, dict):
            metadata_by_reference[metadata_path.relative_to(root).as_posix()] = (
                _command_link_projection(metadata)
            )
        _validate_command_metadata(root, metadata_path, metadata, errors)

    link_counts = {reference: 0 for reference in metadata_by_reference}
    event_count = 0
    terminal_event = None
    sequence_error = False
    summary_command_owner_found = False
    events_path = root / "bootstrap-events.jsonl"
    if not _evidence_is_file(events_path) or _evidence_is_symlink(events_path):
        errors.append("bootstrap-events.jsonl: event log is missing or unsafe")
    else:
        try:
            for line_number, encoded_line in _iter_bounded_jsonl_lines(events_path):
                if encoded_line is None:
                    errors.append(
                        f"bootstrap-events.jsonl:{line_number}: JSONL line exceeds "
                        f"{_limits.MAX_JSONL_LINE_BYTES} bytes"
                    )
                    continue
                try:
                    line = encoded_line.decode("utf-8")
                except UnicodeError as exc:
                    errors.append(
                        f"bootstrap-events.jsonl:{line_number}: invalid UTF-8: {exc}"
                    )
                    continue
                if not line.strip():
                    continue
                try:
                    event = _decode_json_bytes(encoded_line)
                except ValueError as exc:
                    errors.append(
                        f"bootstrap-events.jsonl:{line_number}: invalid JSON: {exc}"
                    )
                    continue
                for error in validate_event(event):
                    errors.append(
                        f"bootstrap-events.jsonl:{line_number}{error[1:]}"
                        if error.startswith("$")
                        else f"bootstrap-events.jsonl:{line_number}: {error}"
                    )
                event_count += 1
                if not isinstance(event, dict):
                    sequence_error = True
                    continue
                if event.get("seq") != event_count:
                    sequence_error = True
                terminal_event = event
                artifact = event.get("artifact")
                if artifact is not None:
                    _resolve_bundle_reference(
                        root,
                        artifact,
                        f"bootstrap-events.jsonl:{line_number}.artifact",
                        errors,
                    )
                if _validate_command_event_link(
                    root,
                    line_number,
                    event,
                    metadata_by_reference,
                    link_counts,
                    summary,
                    errors,
                ):
                    summary_command_owner_found = True
        except OSError as exc:
            errors.append(f"bootstrap-events.jsonl: cannot read event log: {exc}")

    if event_count == 0:
        errors.append("bootstrap-events.jsonl: must contain events")
    elif sequence_error:
        errors.append("bootstrap-events.jsonl: sequence must start at 1 and increment")

    if isinstance(summary, dict) and terminal_event is not None:
        consistent = (
            terminal_event.get("phase") == summary.get("phase")
            and terminal_event.get("status") == summary.get("status")
            and terminal_event.get("commandStatus") == summary.get("commandStatus")
            and terminal_event.get("summary") == summary.get("summary")
        )
        if summary.get("status") != "passed":
            consistent = consistent and terminal_event.get("errorCode") == summary.get(
                "errorCode"
            )
        if not consistent:
            errors.append("bootstrap-events.jsonl: terminal event disagrees with summary")

    for reference, count in sorted(link_counts.items()):
        if count != 1:
            errors.append(
                f"{reference}: command metadata must have exactly one terminal event link"
            )

    if (
        isinstance(summary, dict)
        and summary.get("commandStatus") is not None
        and not summary_command_owner_found
    ):
        errors.append(
            "run-summary.json.commandStatus: does not match an exact terminal command event"
        )

    return _finish_errors(errors)

__all__ = (
    "_MAX_VALIDATION_DIAGNOSTICS",
    "_BoundedErrorList",
    "_resolve_bundle_reference",
    "_validate_command_metadata",
    "_PUBLIC_DENY_SUBSTRINGS",
    "_PUBLIC_BOUNDARY_DENY_RE",
    "_contains_public_deny_pattern",
    "_json_strings",
    "_scan_publishable_files",
    "validate_bundle",
)
