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
from .contracts import _comparability_tuple
from .sanitization import *  # noqa: F401,F403
from .sanitization import _utf8_byte_length
from .safe_io import *  # noqa: F401,F403
from .journal import *  # noqa: F401,F403
from .lifecycle import *  # noqa: F401,F403
from .summaries import *  # noqa: F401,F403
from .summaries import _sanitize_validation_errors
from .commands import *  # noqa: F401,F403
from .receipts import *  # noqa: F401,F403
from .bounded_io import *  # noqa: F401,F403
from .bundle_scan import *  # noqa: F401,F403
from .bundle_consistency import *  # noqa: F401,F403
from .bundle_consistency import _registrations_for_run


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
    snapshot: _BundleSnapshot | None = None,
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
    metadata = snapshot.metadata(relative) if snapshot is not None else None
    if snapshot is not None:
        if metadata is None:
            errors.append(f"{label}: referenced path does not exist")
            return None
    elif not _evidence_exists(candidate):
        errors.append(f"{label}: referenced path does not exist")
        return None
    if expected == "file" and (
        not stat.S_ISREG(metadata.st_mode)
        if metadata is not None
        else not _evidence_is_file(candidate)
    ):
        errors.append(f"{label}: referenced path must be a file")
    elif expected == "directory" and (
        not stat.S_ISDIR(metadata.st_mode)
        if metadata is not None
        else not _evidence_is_dir(candidate)
    ):
        errors.append(f"{label}: referenced path must be a directory")
    return candidate


def _validate_command_metadata(
    root: Path,
    path: Path,
    metadata: Any,
    errors: list[str],
    *,
    snapshot: _BundleSnapshot | None = None,
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
        outcome = metadata.get("outcome")
        if outcome not in ("success", "failure", "cancelled"):
            errors.append(f"{label}.outcome: must declare the external outcome")
        remediation = metadata.get("remediation")
        remediation_bytes = _utf8_byte_length(remediation)
        if not isinstance(remediation, str) or not remediation.strip():
            errors.append(f"{label}.remediation: must be a non-empty string")
        elif remediation_bytes is None:
            errors.append(
                f"{label}.remediation: must contain only Unicode scalar values"
            )
        elif remediation_bytes > MAX_EXTERNAL_REMEDIATION_BYTES:
            errors.append(
                f"{label}.remediation: exceeds maximum "
                f"({MAX_EXTERNAL_REMEDIATION_BYTES} UTF-8 bytes)"
            )
        failure_code = metadata.get("failureCode")
        if outcome == "cancelled" and failure_code != "run.cancelled":
            errors.append(
                f"{label}.failureCode: cancelled outcome requires run.cancelled"
            )
        if outcome == "failure" and failure_code == "run.cancelled":
            errors.append(
                f"{label}.failureCode: failed outcome cannot use run.cancelled"
            )
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
        if _is_integer(stored) and truncated is True:
            # UTF-8-safe head/tail capture can discard at most three bytes at
            # each boundary while retaining the configured byte budget.
            minimum_stored = _LOG_LIMIT - 6
            if not minimum_stored <= stored <= _LOG_LIMIT:
                errors.append(
                    f"{stream_label}.storedBytes: truncated stream must retain "
                    f"between {minimum_stored} and {_LOG_LIMIT} bytes"
                )
        stream_path = record.get("path")
        expected_path = f"commands/{path.stem}.{stream_name}.log"
        if isinstance(stream_path, str) and not stream_path.startswith("commands/"):
            errors.append(f"{stream_label}.path: must be under commands/")
        if stream_path != expected_path:
            errors.append(f"{stream_label}.path: must equal {expected_path}")
        referenced = _resolve_bundle_reference(
            root,
            stream_path,
            stream_label + ".path",
            errors,
            expected="file",
            snapshot=snapshot,
        )
        if referenced is not None and _is_integer(stored):
            referenced_metadata = (
                snapshot.metadata(stream_path)
                if snapshot is not None and isinstance(stream_path, str)
                else _evidence_stat(referenced)
            )
            if (
                referenced_metadata is not None
                and referenced_metadata.st_size != stored
            ):
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

    remediation = metadata.get("remediation")
    remediation_bytes = _utf8_byte_length(remediation)
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
        "remediation": (
            remediation
            if isinstance(remediation, str)
            and bool(remediation.strip())
            and remediation_bytes is not None
            and remediation_bytes <= MAX_EXTERNAL_REMEDIATION_BYTES
            else None
        ),
    }


def _exact_timestamp_delta_ms(started_at: Any, finished_at: Any) -> int | None:
    """Return an exact non-negative millisecond delta for RFC3339 values."""

    if not (_valid_datetime(started_at) and _valid_datetime(finished_at)):
        return None
    try:
        started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        finished = datetime.fromisoformat(finished_at.replace("Z", "+00:00"))
        delta = finished - started
    except (AttributeError, TypeError, ValueError):
        return None
    microseconds = (
        delta.days * 86_400_000_000
        + delta.seconds * 1_000_000
        + delta.microseconds
    )
    if microseconds < 0 or microseconds % 1000:
        return None
    return microseconds // 1000


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
    *,
    snapshot: _BundleSnapshot | None = None,
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
    _resolve_bundle_reference(
        root,
        reference,
        label,
        errors,
        expected="file",
        snapshot=snapshot,
    )
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
    if (
        metadata.get("source") == "github-action"
        and expected_status in ("failed", "cancelled")
        and event.get("summary") != metadata.get("remediation")
    ):
        errors.append(f"{label}.summary: must match external remediation")
    return _command_event_owns_summary(event, metadata, summary)


def _validate_finalize_receipt_for_bundle(
    root: Path,
    snapshot: _BundleSnapshot,
    summary_metadata: Any,
    summary: Any,
    errors: list[str],
) -> None:
    """Validate an optional durable receipt against the snapshotted summary."""

    receipt_relative = "finalize-receipt.json"
    receipt_metadata = snapshot.metadata(receipt_relative)
    has_summary_fingerprint = isinstance(summary, dict) and (
        "finalizeRequestFingerprint" in summary
    )
    if receipt_metadata is None:
        if has_summary_fingerprint:
            errors.append(
                "finalize receipt and run-summary.json.finalizeRequestFingerprint "
                "must either both be present or both be absent"
            )
        return
    if not has_summary_fingerprint:
        errors.append(
            "finalize receipt and run-summary.json.finalizeRequestFingerprint "
            "must either both be present or both be absent"
        )
        return
    if not stat.S_ISREG(receipt_metadata.st_mode):
        errors.append("finalize-receipt.json: must be a regular file")
        return
    receipt_path = root / receipt_relative
    try:
        receipt_content = _read_bounded_bytes(
            receipt_path,
            MAX_FINALIZE_RECEIPT_BYTES,
            expected_metadata=receipt_metadata,
        )
    except ValueError as exc:
        if str(exc).startswith("structured JSON exceeds"):
            errors.append(
                "finalize-receipt.json: finalize receipt exceeds "
                f"{MAX_FINALIZE_RECEIPT_BYTES} bytes"
            )
        else:
            errors.append(f"finalize-receipt.json: {exc}")
        return
    canonical_relative = (
        f"attempts/{root.name}/finalize-receipt.json"
    )
    try:
        receipt = _validate_finalize_receipt_content(
            canonical_relative, receipt_content
        )
        summary_content = _read_bounded_bytes(
            root / "run-summary.json",
            _limits.MAX_STRUCTURED_JSON_BYTES,
            expected_metadata=summary_metadata,
        )
        if not isinstance(summary, dict) or not isinstance(
            summary.get("finalizeRequestFingerprint"), str
        ):
            raise ValueError(
                "run-summary.json.finalizeRequestFingerprint is required "
                "when a finalize receipt exists"
            )
        _validate_finalize_receipt_binding(
            receipt,
            request_fingerprint=summary["finalizeRequestFingerprint"],
            result_sha256=(
                "sha256:" + hashlib.sha256(summary_content).hexdigest()
            ),
        )
    except (KeyError, ValueError) as exc:
        errors.append(f"finalize-receipt.json: {exc}")


def _is_evidence_invalid_fallback(summary: Any) -> bool:
    """Return whether *summary* carries the internal semantic failure marker."""

    return isinstance(summary, dict) and all(
        summary.get(field) == expected
        for field, expected in (
            ("status", "failed"),
            ("classification", "runner_failure"),
            ("errorCode", "runner.evidence_invalid"),
        )
    )


def _validate_invalid_summary_diagnostic_pair(
    root: Path,
    snapshot: _BundleSnapshot,
    summary: Any,
    index: Any,
    secrets: list[str],
    errors: list[str],
) -> None:
    """Bind an evidence-invalid fallback to its canonical diagnostics."""

    candidate_relative = "run-summary.invalid.json"
    diagnostics_relative = "run-summary.invalid.errors.json"
    candidate_metadata = snapshot.metadata(candidate_relative)
    diagnostics_metadata = snapshot.metadata(diagnostics_relative)
    fallback = _is_evidence_invalid_fallback(summary)

    if not fallback:
        if candidate_metadata is not None or diagnostics_metadata is not None:
            errors.append(
                "invalid-summary diagnostic pair: artifacts require the exact "
                "evidence-invalid fallback summary"
            )
        return

    if (
        summary.get("phase") != "evidence.finalize"
        or summary.get("summary") != "Run evidence validation failed"
        or summary.get("hint")
        != "Inspect the sanitized invalid-summary diagnostics"
    ):
        errors.append(
            "invalid-summary diagnostic pair: evidence-invalid fallback text "
            "must use the stable internal values"
        )
        return

    if (
        candidate_metadata is None
        or diagnostics_metadata is None
        or not stat.S_ISREG(candidate_metadata.st_mode)
        or not stat.S_ISREG(diagnostics_metadata.st_mode)
    ):
        errors.append(
            "invalid-summary diagnostic pair: evidence-invalid fallback requires "
            "two regular diagnostic files"
        )
        return

    try:
        candidate, _candidate_bytes = _read_json_bounded(
            root / candidate_relative,
            expected_metadata=candidate_metadata,
        )
        diagnostics, _diagnostics_bytes = _read_json_bounded(
            root / diagnostics_relative,
            expected_metadata=diagnostics_metadata,
        )
    except ValueError:
        errors.append(
            "invalid-summary diagnostic pair: files must be bounded strict JSON"
        )
        return

    if not isinstance(candidate, dict):
        errors.append(
            "invalid-summary diagnostic pair: candidate must be an invalid "
            "summary object"
        )
        return

    candidate_errors = list(validate_summary(candidate))
    registrations = _registrations_for_run(index, root.name)
    if len(registrations) == 1:
        execution, _entry = registrations[0]
        if _comparability_tuple(candidate) != execution.get(
            "comparabilityTuple"
        ):
            candidate_errors.append(
                "$.comparabilityTuple: context disagrees with the registered "
                "execution"
            )
    if not candidate_errors:
        errors.append(
            "invalid-summary diagnostic pair: candidate must fail summary validation"
        )
        return

    expected_diagnostics = _sanitize_validation_errors(
        candidate_errors,
        roots=_sanitization_roots(root),
        secrets=secrets,
    )
    if diagnostics != {"errors": expected_diagnostics}:
        errors.append(
            "invalid-summary diagnostic pair: diagnostics must exactly match the "
            "canonical candidate validation errors"
        )


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
    try:
        _unused_roots, secrets = _normalize_scan_inputs(
            roots={}, secrets=secrets
        )
    except ValueError:
        errors.append(f"$: {_SCAN_INPUT_LIMIT_DIAGNOSTIC}")
        return _finish_errors(errors)
    if _scan_publishable_entry_name(root.name, secrets, errors):
        return _finish_errors(errors)
    index_scan = _scan_publishable_index(root, secrets, errors)
    if index_scan is None:
        scanned_index = None
        index_metadata = None
    else:
        scanned_index, index_metadata = index_scan
    snapshot = _scan_publishable_files(root, secrets, errors)
    if snapshot is None:
        return _finish_errors(errors)

    summary_path = root / "run-summary.json"
    summary = None
    summary_metadata = snapshot.metadata("run-summary.json")
    if summary_metadata is None or not stat.S_ISREG(summary_metadata.st_mode):
        errors.append("run-summary.json: terminal summary is missing or unsafe")
    else:
        try:
            summary, _summary_bytes = _read_json_bounded(
                summary_path, expected_metadata=summary_metadata
            )
            errors.extend(
                "run-summary.json" + error[1:] if error.startswith("$") else error
                for error in validate_summary(summary)
            )
        except ValueError as exc:
            errors.append(f"run-summary.json: {exc}")

    if summary_metadata is not None and stat.S_ISREG(summary_metadata.st_mode):
        _validate_finalize_receipt_for_bundle(
            root, snapshot, summary_metadata, summary, errors
        )

    _validate_invalid_summary_diagnostic_pair(
        root, snapshot, summary, scanned_index, secrets, errors
    )

    if isinstance(summary, dict) and (
        _valid_datetime(summary.get("startedAt"))
        and _valid_datetime(summary.get("finishedAt"))
    ):
        expected_duration = _exact_timestamp_delta_ms(
            summary.get("startedAt"), summary.get("finishedAt")
        )
        if expected_duration is None or summary.get("durationMs") != expected_duration:
            errors.append(
                "run-summary.json.durationMs: must equal the exact "
                "startedAt/finishedAt delta"
            )

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
                ("trace", "file"),
                ("report", "file"),
            ):
                if field not in artifacts or artifacts[field] is None:
                    continue
                _resolve_bundle_reference(
                    root,
                    artifacts[field],
                    f"run-summary.json.artifacts.{field}",
                    errors,
                    expected=expected,
                    snapshot=snapshot,
                )

    _validate_bundle_consistency(
        root,
        summary,
        errors,
        snapshot=snapshot,
        index=scanned_index,
    )

    metadata_paths: list[Path] = []
    metadata_by_reference = {}
    commands_metadata = snapshot.metadata("commands")
    if commands_metadata is not None and stat.S_ISDIR(commands_metadata.st_mode):
        metadata_paths = [
            root.joinpath(*relative.split("/"))
            for relative in snapshot.regular_files("commands", ".json")
        ]
    for metadata_path in metadata_paths:
        metadata_relative = metadata_path.relative_to(root).as_posix()
        metadata_snapshot = snapshot.metadata(metadata_relative)
        try:
            metadata, _metadata_bytes = _read_json_bounded(
                metadata_path, expected_metadata=metadata_snapshot
            )
        except ValueError as exc:
            errors.append(
                f"{metadata_relative}: {exc}"
            )
            continue
        if isinstance(metadata, dict):
            metadata_by_reference[metadata_relative] = (
                _command_link_projection(metadata)
            )
        _validate_command_metadata(
            root,
            metadata_path,
            metadata,
            errors,
            snapshot=snapshot,
        )

    link_counts = {reference: 0 for reference in metadata_by_reference}
    event_count = 0
    terminal_event = None
    sequence_error = False
    summary_command_owner_found = False
    events_path = root / "bootstrap-events.jsonl"
    events_metadata = snapshot.metadata("bootstrap-events.jsonl")
    if events_metadata is None or not stat.S_ISREG(events_metadata.st_mode):
        errors.append("bootstrap-events.jsonl: event log is missing or unsafe")
    else:
        try:
            for line_number, encoded_line in _iter_bounded_jsonl_lines(
                events_path, expected_metadata=events_metadata
            ):
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
                        snapshot=snapshot,
                    )
                if _validate_command_event_link(
                    root,
                    line_number,
                    event,
                    metadata_by_reference,
                    link_counts,
                    summary,
                    errors,
                    snapshot=snapshot,
                ):
                    summary_command_owner_found = True
        except (OSError, RootedIOError) as exc:
            errors.append(f"bootstrap-events.jsonl: cannot read event log: {exc}")

    if event_count == 0:
        errors.append("bootstrap-events.jsonl: must contain events")
    elif sequence_error:
        errors.append("bootstrap-events.jsonl: sequence must start at 1 and increment")

    if isinstance(summary, dict) and terminal_event is not None:
        if terminal_event.get("timestamp") != summary.get("finishedAt"):
            errors.append(
                "bootstrap-events.jsonl: terminal event timestamp disagrees with "
                "run-summary.json.finishedAt"
            )
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

    _verify_publishable_snapshot(root, snapshot, errors)
    if index_metadata is not None:
        _verify_regular_snapshot(
            root.parent.parent / "attempt-index.json", index_metadata, errors
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
