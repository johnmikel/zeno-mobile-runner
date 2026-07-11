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

if os.name == "nt":
    import msvcrt
else:
    import fcntl

from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .sanitization import *  # noqa: F401,F403
from .safe_io import *  # noqa: F401,F403
from .journal import *  # noqa: F401,F403
from .lifecycle import *  # noqa: F401,F403
from .summaries import *  # noqa: F401,F403
from .commands import *  # noqa: F401,F403

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
        if current.is_symlink():
            errors.append(f"{label}: referenced path contains a symlink")
            return None
    try:
        candidate.resolve(strict=False).relative_to(root_absolute.resolve())
    except ValueError:
        errors.append(f"{label}: referenced path escapes the attempt root")
        return None
    if not candidate.exists():
        errors.append(f"{label}: referenced path does not exist")
        return None
    if expected == "file" and not candidate.is_file():
        errors.append(f"{label}: referenced path must be a file")
    elif expected == "directory" and not candidate.is_dir():
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
        referenced = _resolve_bundle_reference(
            root, record.get("path"), stream_label + ".path", errors, expected="file"
        )
        if referenced is not None and _is_integer(stored):
            if referenced.stat().st_size != stored:
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


_PUBLIC_DENY_SUBSTRINGS = (
    "bri" + "ck",
    "uk.co." + "ren" + "tly",
    "ren" + "tly" + "test",
    "zig" + "-mobile-runner",
    "zig" + " mobile runner",
    "zig" + "_mobile_runner",
    "cod" + "ex",
    "clau" + "de fable",
    "noreply@" + "anthropic.com",
    "co-authored-by:" + " claude",
    "clau" + "de code",
    "clau" + "de mcp add",
    "app" + "ium",
    "mae" + "stro",
    "det" + "ox",
    "browser" + "stack",
    "sauce" + "labs",
    "sauce" + " labs",
    "firebase" + " test " + "lab",
    "kobi" + "ton",
    "perfect" + "o",
    "testri" + "gor",
    "kata" + "lon",
    "lambda" + "test",
)
_PUBLIC_BOUNDARY_DENY_RE = re.compile(
    r"(?:^|[^a-z])" + "ren" + r"tly(?:[^a-z]|$)", re.IGNORECASE
)


def _contains_public_deny_pattern(text: str) -> bool:
    lowered = text.lower()
    return _PUBLIC_BOUNDARY_DENY_RE.search(text) is not None or any(
        term in lowered for term in _PUBLIC_DENY_SUBSTRINGS
    )


def _json_strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [text for item in value for text in _json_strings(item)]
    if isinstance(value, dict):
        return list(value.keys()) + [
            text for item in value.values() for text in _json_strings(item)
        ]
    return []


def _scan_publishable_files(root: Path, secrets: list[str], errors: list[str]) -> None:
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(root).as_posix()
        if _ATOMIC_WRITE_TEMP_RE.fullmatch(path.name):
            errors.append(
                f"{relative}: publishable bundle contains an atomic-write temporary"
            )
            continue
        if path.is_symlink():
            errors.append(f"{relative}: publishable bundle contains a symlink")
            continue
        if not path.is_file():
            continue
        try:
            raw = path.read_bytes()
        except OSError as exc:
            errors.append(f"{relative}: cannot scan publishable file: {exc.strerror}")
            continue
        text = raw.decode("utf-8", errors="replace")
        semantic_text = text
        try:
            if path.suffix.lower() == ".json":
                semantic_text = "\n".join(_json_strings(json.loads(text)))
            elif path.suffix.lower() == ".jsonl":
                semantic_text = "\n".join(
                    item
                    for line in text.splitlines()
                    if line.strip()
                    for item in _json_strings(json.loads(line))
                )
        except json.JSONDecodeError:
            semantic_text = text
        for secret in sorted(
            {item for item in secrets if isinstance(item, str) and item}
        ):
            if secret.encode("utf-8") in raw or secret in semantic_text:
                errors.append(f"{relative}: contains a current known secret value")
                break
        if _CREDENTIAL_URL_RE.search(semantic_text):
            errors.append(f"{relative}: contains a credential URL")
        if (
            _FILE_URL_RE.search(semantic_text)
            or _WINDOWS_ABSOLUTE_RE.search(semantic_text)
            or _POSIX_ABSOLUTE_RE.search(semantic_text)
        ):
            errors.append(f"{relative}: contains a raw absolute path")
        if _contains_public_deny_pattern(semantic_text):
            errors.append(f"{relative}: contains a public safety deny pattern")


def validate_bundle(root: Path, *, secrets: list[str]) -> list[str]:
    """Validate a complete attempt bundle, including containment and redaction."""

    root = Path(root)
    errors: list[str] = _pending_transaction_errors_for_attempt(root)
    if root.is_symlink():
        errors.append("$: attempt root must not be a symlink")
        return _finish_errors(errors)
    if not root.is_dir():
        errors.append("$: attempt root must be a directory")
        return _finish_errors(errors)

    summary_path = root / "run-summary.json"
    summary = None
    if not summary_path.is_file() or summary_path.is_symlink():
        errors.append("run-summary.json: terminal summary is missing or unsafe")
    else:
        try:
            summary = _read_json(summary_path)
            errors.extend(
                "run-summary.json" + error[1:] if error.startswith("$") else error
                for error in validate_summary(summary)
            )
        except ValueError as exc:
            errors.append(f"run-summary.json: {exc}")

    events = []
    events_path = root / "bootstrap-events.jsonl"
    if not events_path.is_file() or events_path.is_symlink():
        errors.append("bootstrap-events.jsonl: event log is missing or unsafe")
    else:
        try:
            for line_number, line in enumerate(
                events_path.read_text(encoding="utf-8").splitlines(), 1
            ):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    errors.append(
                        f"bootstrap-events.jsonl:{line_number}: invalid JSON: {exc.msg}"
                    )
                    continue
                for error in validate_event(event):
                    errors.append(
                        f"bootstrap-events.jsonl:{line_number}{error[1:]}"
                        if error.startswith("$")
                        else f"bootstrap-events.jsonl:{line_number}: {error}"
                    )
                events.append(event)
        except (OSError, UnicodeError) as exc:
            errors.append(f"bootstrap-events.jsonl: cannot read event log: {exc}")
    if events:
        actual_sequence = [event.get("seq") for event in events]
        if actual_sequence != list(range(1, len(events) + 1)):
            errors.append("bootstrap-events.jsonl: sequence must start at 1 and increment")
    else:
        errors.append("bootstrap-events.jsonl: must contain events")

    if isinstance(summary, dict) and events:
        terminal = events[-1]
        consistent = (
            terminal.get("phase") == summary.get("phase")
            and terminal.get("status") == summary.get("status")
            and terminal.get("commandStatus") == summary.get("commandStatus")
        )
        if summary.get("status") != "passed":
            consistent = consistent and terminal.get("errorCode") == summary.get(
                "errorCode"
            )
        if not consistent:
            errors.append("bootstrap-events.jsonl: terminal event disagrees with summary")

    if isinstance(summary, dict):
        artifacts = summary.get("artifacts")
        if isinstance(artifacts, dict):
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

    for line_number, event in enumerate(events, 1):
        artifact = event.get("artifact") if isinstance(event, dict) else None
        if artifact is not None:
            _resolve_bundle_reference(
                root,
                artifact,
                f"bootstrap-events.jsonl:{line_number}.artifact",
                errors,
            )
        command_ref = event.get("command") if isinstance(event, dict) else None
        if command_ref is not None:
            if not (
                isinstance(command_ref, str)
                and _valid_relative_path(command_ref)
                and command_ref.startswith("commands/")
                and command_ref.count("/") == 1
                and command_ref.endswith(".json")
            ):
                errors.append(
                    f"bootstrap-events.jsonl:{line_number}.command: "
                    "must be a command metadata reference"
                )
            else:
                _resolve_bundle_reference(
                    root,
                    command_ref,
                    f"bootstrap-events.jsonl:{line_number}.command",
                    errors,
                    expected="file",
                )

    commands_root = root / "commands"
    metadata_paths = []
    metadata_by_reference = {}
    if commands_root.is_dir() and not commands_root.is_symlink():
        metadata_paths = sorted(commands_root.glob("*.json"))
    for metadata_path in metadata_paths:
        if metadata_path.is_symlink():
            errors.append(
                f"{metadata_path.relative_to(root).as_posix()}: command record is a symlink"
            )
            continue
        try:
            metadata = _read_json(metadata_path)
        except ValueError as exc:
            errors.append(
                f"{metadata_path.relative_to(root).as_posix()}: {exc}"
            )
            continue
        if isinstance(metadata, dict):
            metadata_by_reference[metadata_path.relative_to(root).as_posix()] = metadata
        _validate_command_metadata(root, metadata_path, metadata, errors)

    linked_commands = []
    link_counts = {reference: 0 for reference in metadata_by_reference}
    for line_number, event in enumerate(events, 1):
        if not isinstance(event, dict) or event.get("command") is None:
            continue
        reference = event.get("command")
        label = f"bootstrap-events.jsonl:{line_number}.command"
        metadata = metadata_by_reference.get(reference)
        if metadata is None:
            if isinstance(reference, str) and reference in link_counts:
                link_counts[reference] += 1
            errors.append(f"{label}: referenced command record is missing")
            continue
        link_counts[reference] += 1
        if event.get("status") not in ("passed", "failed", "cancelled"):
            errors.append(f"{label}: command metadata may only appear on a terminal event")
            continue
        if event.get("phase") != metadata.get("phase"):
            errors.append(f"{label}: phase disagrees with command metadata")

        expected_status = None
        expected_command_status = None
        if metadata.get("source") == "subprocess":
            if metadata.get("signal") is not None:
                expected_status = "cancelled"
            elif _is_integer(metadata.get("exitStatus")):
                expected_command_status = metadata.get("exitStatus")
                expected_status = (
                    "passed" if expected_command_status == 0 else "failed"
                )
        elif metadata.get("source") == "github-action":
            expected_status = {
                "success": "passed",
                "failure": "failed",
                "cancelled": "cancelled",
            }.get(metadata.get("outcome"))

        if event.get("status") != expected_status:
            errors.append(f"{label}: event status disagrees with command metadata")
        if event.get("commandStatus") != expected_command_status:
            errors.append(
                f"{label}: commandStatus disagrees with metadata exitStatus/outcome"
            )
        if expected_status == "passed":
            if event.get("errorCode") is not None:
                errors.append(f"{label}: passed command event must omit errorCode")
        elif event.get("errorCode") != metadata.get("failureCode"):
            errors.append(f"{label}: failureCode disagrees with command metadata")
        linked_commands.append((event, metadata))

    for reference, count in sorted(link_counts.items()):
        if count != 1:
            errors.append(
                f"{reference}: command metadata must have exactly one terminal event link"
            )

    if isinstance(summary, dict) and summary.get("commandStatus") is not None:
        command_status = summary.get("commandStatus")
        owners = [
            (event, metadata)
            for event, metadata in linked_commands
            if metadata.get("source") == "subprocess"
            and metadata.get("exitStatus") == command_status
            and event.get("commandStatus") == command_status
        ]
        if summary.get("status") == "failed":
            owners = [
                (event, metadata)
                for event, metadata in owners
                if event.get("phase") == summary.get("phase")
                and event.get("errorCode") == summary.get("errorCode")
            ]
        elif summary.get("status") == "passed":
            owners = [
                (event, metadata)
                for event, metadata in owners
                if event.get("status") == "passed"
            ]
        if not owners:
            errors.append(
                "run-summary.json.commandStatus: does not match an exact terminal command event"
            )

    _scan_publishable_files(root, secrets, errors)
    return _finish_errors(errors)

__all__ = (
    "_resolve_bundle_reference",
    "_validate_command_metadata",
    "_PUBLIC_DENY_SUBSTRINGS",
    "_PUBLIC_BOUNDARY_DENY_RE",
    "_contains_public_deny_pattern",
    "_json_strings",
    "_scan_publishable_files",
    "validate_bundle",
)
