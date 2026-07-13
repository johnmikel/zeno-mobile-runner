"""Publication journal validation, replay, and recovery."""

from __future__ import annotations

import base64
import binascii
import hashlib
import os
import re
import stat
from pathlib import Path
from typing import Any

from . import bounded_io
from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .bounded_io import _read_bounded_bytes
from .receipts import (
    MAX_FINALIZE_RECEIPT_BYTES,
    _finalize_receipt_relative,
    _legacy_finalize_receipt_request_fingerprint,
    _make_finalize_receipt,
    _read_finalize_receipt,
    _validate_finalize_receipt_binding,
    _validate_finalize_receipt_content,
)
from .safe_io import *  # noqa: F401,F403
from .journal_validation import _validate_transaction_operation
from . import safe_io as _safe_io_owner


_TRANSACTION_OPERATIONS = ("init", "register", "context", "finalize")
_TRANSACTION_KEYS = {
    "schemaVersion",
    "operation",
    "attemptRoot",
    "requestFingerprint",
    "requiredDirectories",
    "targets",
}
_TRANSACTION_TARGET_KEYS = {"path", "contentBase64", "sha256"}
_REQUEST_FINGERPRINT_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
_ATOMIC_TEMP_TOKEN_PATTERN = r"[a-z0-9_]{8}"
_ATOMIC_WRITE_TEMP_RE = re.compile(
    rf"^[.].+[.]{_ATOMIC_TEMP_TOKEN_PATTERN}[.]tmp$"
)
_TRANSACTION_TEMP_RE = re.compile(
    r"^[.](?P<operation>init|register|context|finalize)-"
    r"(?P<runId>.+)-(?P<fingerprint>[0-9a-f]{16})[.]json[.]"
    rf"(?P<token>{_ATOMIC_TEMP_TOKEN_PATTERN})[.]tmp$"
)
_TRANSACTION_JOURNAL_RE = re.compile(
    r"^(?P<operation>init|register|context|finalize)-"
    r"(?P<runId>.+)-(?P<fingerprint>[0-9a-f]{16})[.]json$"
)
_BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_BASE64_ALPHABET_SET = frozenset(_BASE64_ALPHABET)


def _atomic_write_bytes(path: Path, content: bytes, mode: int = 0o600) -> None:
    """Route atomic writes through their owning module for fault injection."""

    _safe_io_owner._atomic_write_bytes(path, content, mode)


def _transaction_checkpoint(stage: str, position: int) -> None:
    """Fault-injection seam used by deterministic crash-recovery tests."""


def _publication_root_for_attempt(root: Path) -> Path:
    return Path(root).absolute().parent.parent


def _attempt_root_relative(publication_root: Path, root: Path) -> str:
    publication_root = Path(publication_root).absolute()
    root = Path(root).absolute()
    try:
        relative = root.relative_to(publication_root).as_posix()
    except ValueError as exc:
        raise ValueError("attempt root escapes the publication root") from exc
    parts = relative.split("/")
    if len(parts) != 2 or parts[0] != "attempts" or not _safe_run_segment(parts[1]):
        raise ValueError("attempt root must be attempts/<runId>")
    return relative


def _request_fingerprint(
    publication_root: Path, operation: str, root: Path, request: Any
) -> str:
    """Hash one sanitized semantic request without persisting its contents."""

    if operation not in _TRANSACTION_OPERATIONS:
        raise ValueError("transaction request operation is invalid")
    payload = {
        "schemaVersion": 1,
        "operation": operation,
        "attemptRoot": _attempt_root_relative(publication_root, root),
        "request": request,
    }
    try:
        content = _json_bytes(payload)
    except (TypeError, ValueError) as exc:
        raise ValueError("transaction request is not canonical JSON") from exc
    return "sha256:" + hashlib.sha256(content).hexdigest()


def _contained_transaction_path(
    publication_root: Path, relative: Any, label: str
) -> Path:
    if not _valid_relative_path(relative):
        raise ValueError(f"{label}: must be a normalized relative path")
    if relative == ".transactions" or relative.startswith(".transactions/"):
        raise ValueError(f"{label}: transaction internals cannot be targets")
    publication_root = Path(publication_root).absolute()
    candidate = publication_root.joinpath(*relative.split("/"))
    _active_rooted_io().revalidate_root()
    _active_rooted_io()._relative(candidate)
    return candidate


def _transaction_directory(publication_root: Path, *, create: bool) -> Path:
    transaction_root = Path(publication_root) / ".transactions"
    if _evidence_is_symlink(transaction_root):
        raise ValueError("transaction directory must not be a symlink")
    if _evidence_exists(transaction_root):
        if not _evidence_is_dir(transaction_root):
            raise ValueError("transaction directory must be a directory")
    elif create:
        _evidence_mkdir(transaction_root, mode=0o700)
        _fsync_directory(Path(publication_root))
    return transaction_root


def _transaction_target_limit(path: str) -> int:
    if path.endswith("/finalize-receipt.json"):
        return MAX_FINALIZE_RECEIPT_BYTES
    if path.endswith("/bootstrap-events.jsonl"):
        return MAX_LIFECYCLE_EVENT_STREAM_BYTES
    return MAX_STRUCTURED_JSON_BYTES


def _transaction_target_limit_error(path: str, maximum: int) -> ValueError:
    if path.endswith("/finalize-receipt.json"):
        return ValueError(f"finalize receipt exceeds {maximum} bytes")
    return ValueError(
        f"transaction target {path} exceeds {maximum} bytes"
    )


def _strict_base64_decoded_size(
    encoded: Any, *, path: str, maximum: int
) -> int:
    """Validate base64 framing and size without allocating decoded content."""

    if not isinstance(encoded, str):
        raise ValueError("transaction target contentBase64 is invalid")
    encoded_maximum = ((maximum + 2) // 3) * 4
    if len(encoded) > encoded_maximum:
        raise _transaction_target_limit_error(path, maximum)
    if len(encoded) % 4 != 0:
        raise ValueError("transaction target contentBase64 is invalid")
    padding = 2 if encoded.endswith("==") else 1 if encoded.endswith("=") else 0
    payload_end = len(encoded) - padding
    if encoded.find("=") not in (-1, payload_end) or any(
        encoded[index] not in _BASE64_ALPHABET_SET
        for index in range(payload_end)
    ):
        raise ValueError("transaction target contentBase64 is invalid")
    if padding and payload_end == 0:
        raise ValueError("transaction target contentBase64 is invalid")
    if padding == 2 and _BASE64_ALPHABET.index(encoded[payload_end - 1]) & 0x0F:
        raise ValueError("transaction target contentBase64 is not canonical")
    if padding == 1 and _BASE64_ALPHABET.index(encoded[payload_end - 1]) & 0x03:
        raise ValueError("transaction target contentBase64 is not canonical")
    decoded_size = (len(encoded) // 4) * 3 - padding
    if decoded_size < 0:
        raise ValueError("transaction target contentBase64 is invalid")
    if decoded_size > maximum:
        raise _transaction_target_limit_error(path, maximum)
    return decoded_size


def _decode_transaction_json(path: str, content: bytes) -> Any:
    try:
        return bounded_io._decode_json_bytes(content)
    except ValueError as exc:
        raise ValueError(
            f"transaction target {path} is invalid JSON evidence: {exc}"
        ) from exc


def _decode_transaction_events(path: str, content: bytes) -> list[dict]:
    events = []
    offset = 0
    line_number = 1
    while offset < len(content):
        newline = content.find(b"\n", offset)
        end = len(content) if newline < 0 else newline
        if end - offset > MAX_JSONL_LINE_BYTES:
            raise ValueError(
                "transaction event JSONL line exceeds "
                f"{MAX_JSONL_LINE_BYTES} bytes at line {line_number}"
            )
        encoded_line = content[offset:end]
        if encoded_line.strip():
            event = _decode_transaction_json(path, encoded_line)
            errors = validate_event(event)
            if errors:
                raise ValueError("; ".join(errors))
            events.append(event)
        if newline < 0:
            break
        offset = newline + 1
        line_number += 1
    return events


def _validate_transaction_target_content(path: str, content: bytes) -> Any:
    if not isinstance(path, str) or not isinstance(content, bytes):
        raise ValueError("transaction target path and content are invalid")
    maximum = _transaction_target_limit(path)
    if len(content) > maximum:
        raise _transaction_target_limit_error(path, maximum)
    if path == "attempt-index.json":
        value = _decode_transaction_json(path, content)
        _validate_index(value)
    elif path.endswith("/run-context.json"):
        value = _decode_transaction_json(path, content)
        _validate_context_identity(value)
    elif path.endswith("/run-summary.json"):
        value = _decode_transaction_json(path, content)
        errors = validate_summary(value)
        if errors:
            raise ValueError("; ".join(errors))
    elif path.endswith("/run-summary.invalid.json"):
        value = _decode_transaction_json(path, content)
        if not isinstance(value, dict):
            raise ValueError("invalid candidate must be an object")
    elif path.endswith("/run-summary.invalid.errors.json"):
        value = _decode_transaction_json(path, content)
        if not isinstance(value, dict) or not isinstance(value.get("errors"), list):
            raise ValueError("invalid diagnostics must contain errors")
    elif path.endswith("/finalize-receipt.json"):
        value = _validate_finalize_receipt_content(path, content)
    elif path.endswith("/bootstrap-events.jsonl"):
        events = _decode_transaction_events(path, content)
        if [event["seq"] for event in events] != list(range(1, len(events) + 1)):
            raise ValueError("event sequence is not contiguous")
        value = events
    else:
        raise ValueError("transaction target is not an approved lifecycle file")
    return value


def _validate_transaction_journal(publication_root: Path, journal: Any) -> dict:
    bounded_io._validate_json_nesting(journal)
    if not isinstance(journal, dict) or set(journal) != _TRANSACTION_KEYS:
        raise ValueError("transaction journal has an invalid object shape")
    schema_version = journal.get("schemaVersion")
    if not _is_integer(schema_version) or schema_version != 1:
        raise ValueError("transaction journal schemaVersion must equal 1")
    operation = journal.get("operation")
    if operation not in _TRANSACTION_OPERATIONS:
        raise ValueError("transaction journal operation is invalid")
    request_fingerprint = journal.get("requestFingerprint")
    if (
        not isinstance(request_fingerprint, str)
        or _REQUEST_FINGERPRINT_RE.fullmatch(request_fingerprint) is None
    ):
        raise ValueError("transaction journal requestFingerprint is invalid")
    attempt_relative = journal.get("attemptRoot")
    attempt_path = _contained_transaction_path(
        publication_root, attempt_relative, "transaction attemptRoot"
    )
    parts = attempt_relative.split("/") if isinstance(attempt_relative, str) else []
    if len(parts) != 2 or parts[0] != "attempts" or not _safe_run_segment(parts[1]):
        raise ValueError("transaction attemptRoot must be attempts/<runId>")
    del attempt_path

    required_directories = journal.get("requiredDirectories")
    if not isinstance(required_directories, list) or not required_directories:
        raise ValueError("transaction requiredDirectories must be a non-empty array")
    if len(required_directories) > MAX_TRANSACTION_REQUIRED_DIRECTORY_COUNT:
        raise ValueError(
            "transaction required directory count exceeds "
            f"{MAX_TRANSACTION_REQUIRED_DIRECTORY_COUNT}"
        )
    for index, relative in enumerate(required_directories):
        directory = _contained_transaction_path(
            publication_root, relative, f"requiredDirectories[{index}]"
        )
        if relative != "attempts" and not relative.startswith("attempts/"):
            raise ValueError("transaction directories must be under attempts")
        if _evidence_exists(directory) and not _evidence_is_dir(directory):
            raise ValueError("transaction required directory is not a directory")
    if len(required_directories) != len(set(required_directories)):
        raise ValueError("transaction requiredDirectories must be unique")
    if required_directories != sorted(
        required_directories, key=lambda item: (item.count("/"), item)
    ):
        raise ValueError("transaction requiredDirectories must be canonically ordered")
    if attempt_relative not in required_directories:
        raise ValueError("transaction must declare its attempt root directory")

    targets = journal.get("targets")
    if not isinstance(targets, list) or not targets:
        raise ValueError("transaction targets must be a non-empty array")
    if len(targets) > MAX_TRANSACTION_TARGET_COUNT:
        raise ValueError(
            f"transaction target count exceeds {MAX_TRANSACTION_TARGET_COUNT}"
        )
    prepared_targets = []
    seen_paths = set()
    aggregate_decoded_bytes = 0
    for index, target in enumerate(targets):
        if not isinstance(target, dict) or set(target) != _TRANSACTION_TARGET_KEYS:
            raise ValueError(f"transaction target {index} has an invalid shape")
        relative = target.get("path")
        candidate = _contained_transaction_path(
            publication_root, relative, f"targets[{index}].path"
        )
        if relative in seen_paths:
            raise ValueError("transaction target paths must be unique")
        seen_paths.add(relative)
        if _evidence_exists(candidate) and not _evidence_is_file(candidate):
            raise ValueError("transaction target exists but is not a file")
        encoded_content = target.get("contentBase64")
        maximum = _transaction_target_limit(relative)
        decoded_size = _strict_base64_decoded_size(
            encoded_content, path=relative, maximum=maximum
        )
        aggregate_decoded_bytes += decoded_size
        if aggregate_decoded_bytes > MAX_TRANSACTION_TARGET_AGGREGATE_BYTES:
            raise ValueError(
                "transaction target aggregate exceeds "
                f"{MAX_TRANSACTION_TARGET_AGGREGATE_BYTES} bytes"
            )
        prepared_targets.append((relative, encoded_content, target))

    decoded_targets = []
    for relative, encoded_content, target in prepared_targets:
        try:
            content = base64.b64decode(encoded_content, validate=True)
        except (TypeError, ValueError, binascii.Error) as exc:
            raise ValueError("transaction target contentBase64 is invalid") from exc
        digest = "sha256:" + hashlib.sha256(content).hexdigest()
        if target.get("sha256") != digest:
            raise ValueError("transaction target hash does not match content")
        value = _validate_transaction_target_content(relative, content)
        decoded_targets.append(
            {
                "path": relative,
                "content": content,
                "sha256": digest,
                "value": value,
            }
        )

    _validate_transaction_operation(
        operation,
        attempt_relative,
        required_directories,
        decoded_targets,
        request_fingerprint,
    )

    return {
        "journal": journal,
        "operation": operation,
        "attemptRoot": attempt_relative,
        "requestFingerprint": request_fingerprint,
        "requiredDirectories": required_directories,
        "targets": decoded_targets,
    }


def _decoded_transaction_target(path: str, content: bytes) -> dict:
    digest = "sha256:" + hashlib.sha256(content).hexdigest()
    return {
        "path": path,
        "content": content,
        "sha256": digest,
        "value": _validate_transaction_target_content(path, content),
    }


def _upgrade_legacy_finalize_transaction(transaction: dict) -> None:
    """Upgrade a validated receipt-less WAL when the projection stays bounded."""

    if transaction["operation"] != "finalize":
        return
    attempt_relative = transaction["attemptRoot"]
    receipt_path = _finalize_receipt_relative(attempt_relative)
    if any(target["path"] == receipt_path for target in transaction["targets"]):
        return

    event_path = attempt_relative + "/bootstrap-events.jsonl"
    summary_path = attempt_relative + "/run-summary.json"
    event_target = next(
        target for target in transaction["targets"] if target["path"] == event_path
    )
    summary_target = next(
        target for target in transaction["targets"] if target["path"] == summary_path
    )
    migrated_events = [dict(event) for event in event_target["value"]]
    migrated_events[-1]["timestamp"] = summary_target["value"]["finishedAt"]
    migrated_event_lines = [_json_bytes(event) for event in migrated_events]
    migrated_event_content = b"".join(migrated_event_lines)
    # Any admission return preserves the receiptless WAL exactly. If its
    # response is then lost after journal removal, a retry cannot be reconciled.
    if (
        len(migrated_event_content) > MAX_LIFECYCLE_EVENT_STREAM_BYTES
        or any(
            len(line) - 1 > MAX_JSONL_LINE_BYTES
            for line in migrated_event_lines
        )
    ):
        return

    legacy_request_fingerprint = transaction["requestFingerprint"]
    receipt_request_fingerprint = (
        _legacy_finalize_receipt_request_fingerprint(
            legacy_request_fingerprint
        )
    )
    migrated_summary = dict(summary_target["value"])
    migrated_summary["finalizeRequestFingerprint"] = (
        receipt_request_fingerprint
    )
    migrated_summary_content = _json_bytes(migrated_summary)
    if len(migrated_summary_content) > MAX_STRUCTURED_JSON_BYTES:
        return
    try:
        receipt_content = _make_finalize_receipt(
            attempt_relative,
            receipt_request_fingerprint,
            migrated_summary_content,
        )
    except ValueError as exc:
        if str(exc).startswith("finalize receipt exceeds"):
            return
        raise

    candidate_target_contents = [
        (
            migrated_event_content
            if target["path"] == event_path
            else migrated_summary_content
            if target["path"] == summary_path
            else target["content"]
        )
        for target in transaction["targets"]
    ] + [receipt_content]
    if (
        len(candidate_target_contents) > MAX_TRANSACTION_TARGET_COUNT
        or sum(map(len, candidate_target_contents))
        > MAX_TRANSACTION_TARGET_AGGREGATE_BYTES
    ):
        return

    migrated_event_target = _decoded_transaction_target(
        event_path, migrated_event_content
    )
    migrated_summary_target = _decoded_transaction_target(
        summary_path, migrated_summary_content
    )
    receipt_target = _decoded_transaction_target(
        receipt_path, receipt_content
    )
    candidate_targets = [
        (
            migrated_event_target
            if target["path"] == event_path
            else migrated_summary_target
            if target["path"] == summary_path
            else target
        )
        for target in transaction["targets"]
    ] + [receipt_target]
    _validate_transaction_operation(
        transaction["operation"],
        attempt_relative,
        transaction["requiredDirectories"],
        candidate_targets,
        receipt_request_fingerprint,
    )

    transaction["targets"] = candidate_targets
    transaction["requestFingerprint"] = receipt_request_fingerprint
    transaction["legacyFinalizeUpgrade"] = True


def _bounded_directory_entries(path: Path, *, label: str) -> list[Path]:
    """Enumerate a transaction-related directory before sorting bounded names."""

    authority = _active_rooted_io()
    path = Path(path)
    relative = authority._relative(path)
    descriptor = authority._open_directory_unchecked(relative)
    names = []
    try:
        _rooted_io_checkpoint("list", "before_list", authority.path(relative))
        authority._validate_directory(relative, descriptor)
        with os.scandir(descriptor) as entries:
            for entry in entries:
                name = entry.name
                if name in ("", ".", "..") or "/" in name or "\x00" in name:
                    raise authority._error("transaction entry name is not normalized")
                if len(names) >= MAX_TRANSACTION_DIRECTORY_ENTRY_COUNT:
                    raise ValueError(
                        f"{label} directory entry count exceeds "
                        f"{MAX_TRANSACTION_DIRECTORY_ENTRY_COUNT}"
                    )
                names.append(name)
        authority._validate_directory(relative, descriptor)
    except OSError as exc:
        raise authority._error(
            "descriptor-relative transaction directory listing failed", exc
        ) from exc
    finally:
        os.close(descriptor)
    return [path / name for name in sorted(names)]


def _pending_transaction_inventory(
    publication_root: Path,
) -> tuple[Path, list[Path], list[tuple[Path, os.stat_result]]]:
    transaction_root = _transaction_directory(publication_root, create=False)
    if not _evidence_exists(transaction_root):
        return transaction_root, [], []
    paths = []
    orphan_temporaries = []
    pending_bytes = 0
    for entry in _bounded_directory_entries(
        transaction_root, label="transaction"
    ):
        if _evidence_is_symlink(entry):
            raise ValueError("pending transaction journal must not be a symlink")
        temporary_match = _TRANSACTION_TEMP_RE.fullmatch(entry.name)
        if temporary_match is not None:
            metadata = _evidence_stat(entry)
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError("orphan transaction temporary must be a regular file")
            if not _safe_run_segment(temporary_match.group("runId")):
                raise ValueError("orphan transaction temporary has an unsafe runId")
            if os.name == "posix" and stat.S_IMODE(metadata.st_mode) != 0o600:
                raise ValueError("orphan transaction temporary has an unsafe mode")
            if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
                raise ValueError("orphan transaction temporary has an unsafe owner")
            orphan_temporaries.append((entry, metadata))
            continue
        metadata = _evidence_stat(entry)
        if not stat.S_ISREG(metadata.st_mode) or entry.suffix != ".json":
            raise ValueError("transaction directory contains an unsafe entry")
        if metadata.st_size > MAX_TRANSACTION_JOURNAL_BYTES:
            raise ValueError(
                "transaction journal exceeds "
                f"{MAX_TRANSACTION_JOURNAL_BYTES} bytes"
            )
        if len(paths) >= MAX_PENDING_TRANSACTION_COUNT:
            raise ValueError(
                "pending transaction count exceeds "
                f"{MAX_PENDING_TRANSACTION_COUNT}"
            )
        pending_bytes += metadata.st_size
        if pending_bytes > MAX_PENDING_TRANSACTION_BYTES:
            raise ValueError(
                "pending transaction bytes exceed "
                f"{MAX_PENDING_TRANSACTION_BYTES}"
            )
        paths.append(entry)
    return transaction_root, paths, orphan_temporaries


def _cleanup_orphan_transaction_temporaries(
    transaction_root: Path,
    orphan_temporaries: list[tuple[Path, os.stat_result]],
) -> None:
    if orphan_temporaries:
        for entry, original_metadata in orphan_temporaries:
            current_metadata = _evidence_stat(entry)
            if (
                not stat.S_ISREG(current_metadata.st_mode)
                or current_metadata.st_dev != original_metadata.st_dev
                or current_metadata.st_ino != original_metadata.st_ino
                or (
                    os.name == "posix"
                    and stat.S_IMODE(current_metadata.st_mode) != 0o600
                )
                or (
                    hasattr(os, "geteuid")
                    and current_metadata.st_uid != os.geteuid()
                )
            ):
                raise ValueError("orphan transaction temporary changed before cleanup")
        for entry, _metadata in orphan_temporaries:
            _evidence_unlink(entry)
        _fsync_directory(transaction_root)


def _pending_transaction_paths(
    publication_root: Path, *, cleanup_orphan_temporaries: bool = False
) -> list[Path]:
    transaction_root, paths, orphan_temporaries = (
        _pending_transaction_inventory(publication_root)
    )
    if orphan_temporaries and not cleanup_orphan_temporaries:
        raise ValueError("orphan transaction temporary requires recovery")
    if cleanup_orphan_temporaries:
        _cleanup_orphan_transaction_temporaries(
            transaction_root, orphan_temporaries
        )
    return paths


def _load_transactions_from_paths(
    publication_root: Path, journal_paths: list[Path]
) -> list[tuple[Path, dict]]:
    loaded = []
    seen_targets = set()
    seen_operations = set()
    for journal_path in journal_paths:
        metadata = _evidence_stat(journal_path)
        try:
            journal_bytes = _read_bounded_bytes(
                journal_path,
                MAX_TRANSACTION_JOURNAL_BYTES,
                expected_metadata=metadata,
            )
        except ValueError as exc:
            if str(exc).startswith("structured JSON exceeds"):
                raise ValueError(
                    "transaction journal exceeds "
                    f"{MAX_TRANSACTION_JOURNAL_BYTES} bytes"
                ) from exc
            raise
        try:
            journal = bounded_io._decode_json_bytes(journal_bytes)
        except ValueError as exc:
            raise ValueError(f"transaction journal is invalid JSON: {exc}") from exc
        name_match = _TRANSACTION_JOURNAL_RE.fullmatch(journal_path.name)
        if name_match is None:
            raise ValueError("transaction journal filename is invalid")
        journal_hash = hashlib.sha256(journal_bytes).hexdigest()[:16]
        if name_match.group("fingerprint") != journal_hash:
            raise ValueError("transaction journal filename hash is invalid")
        validated = _validate_transaction_journal(publication_root, journal)
        run_id = validated["attemptRoot"].split("/")[-1]
        if (
            name_match.group("operation") != validated["operation"]
            or name_match.group("runId") != run_id
        ):
            raise ValueError("transaction journal filename identity is invalid")
        _upgrade_legacy_finalize_transaction(validated)
        operation_key = (validated["operation"], validated["attemptRoot"])
        if operation_key in seen_operations:
            raise ValueError("duplicate pending transaction operation")
        seen_operations.add(operation_key)
        target_paths = {target["path"] for target in validated["targets"]}
        if seen_targets & target_paths:
            raise ValueError("pending transactions contain overlapping targets")
        seen_targets.update(target_paths)
        loaded.append((journal_path, validated))
    return loaded


def _load_pending_transactions(
    publication_root: Path, *, cleanup_orphan_temporaries: bool = False
) -> list[tuple[Path, dict]]:
    transaction_root, paths, orphan_temporaries = (
        _pending_transaction_inventory(publication_root)
    )
    if orphan_temporaries and not cleanup_orphan_temporaries:
        raise ValueError("orphan transaction temporary requires recovery")
    loaded = _load_transactions_from_paths(publication_root, paths)
    if cleanup_orphan_temporaries:
        _preflight_pending_transactions(publication_root, loaded)
        _cleanup_orphan_transaction_temporaries(
            transaction_root, orphan_temporaries
        )
    return loaded


def _ensure_transaction_directories(publication_root: Path, relatives: list[str]) -> None:
    for relative in sorted(relatives, key=lambda item: (item.count("/"), item)):
        directory = _contained_transaction_path(
            publication_root, relative, "transaction required directory"
        )
        if _evidence_exists(directory):
            if not _evidence_is_dir(directory):
                raise ValueError("transaction required directory is not a directory")
            continue
        if not _evidence_is_dir(directory.parent) or _evidence_is_symlink(directory.parent):
            raise ValueError("transaction required directory parent is unsafe")
        _evidence_mkdir(directory, mode=0o700)
        _fsync_directory(directory.parent)


def _validated_target_temporaries(path: Path) -> list[tuple[Path, os.stat_result]]:
    path = Path(path)
    parent = path.parent
    if not _evidence_exists(parent):
        return []
    if _evidence_is_symlink(parent) or not _evidence_is_dir(parent):
        raise ValueError("transaction target parent is unsafe")
    exact_pattern = re.compile(
        rf"^[.]{re.escape(path.name)}[.]"
        rf"{_ATOMIC_TEMP_TOKEN_PATTERN}[.]tmp$"
    )
    candidate_prefixes = (f".{path.name}.", f"{path.name}.")
    temporaries = []
    for entry in _bounded_directory_entries(
        parent, label="transaction target parent"
    ):
        if entry.name == f"{path.name}.lock":
            continue
        exact = exact_pattern.fullmatch(entry.name) is not None
        near_match = any(
            entry.name.startswith(prefix) for prefix in candidate_prefixes
        )
        if not exact and not near_match:
            continue
        if not exact:
            raise ValueError("transaction target has a malformed atomic temporary")
        if _evidence_is_symlink(entry):
            raise ValueError("transaction target temporary must not be a symlink")
        metadata = _evidence_stat(entry)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("transaction target temporary must be a regular file")
        if os.name == "posix" and stat.S_IMODE(metadata.st_mode) != 0o600:
            raise ValueError("transaction target temporary has an unsafe mode")
        if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
            raise ValueError("transaction target temporary has an unsafe owner")
        temporaries.append((entry, metadata))
    return temporaries


def _remove_target_temporaries(
    path: Path, temporaries: list[tuple[Path, os.stat_result]]
) -> None:
    if not temporaries:
        return
    for entry, original_metadata in temporaries:
        if _evidence_is_symlink(entry):
            raise ValueError("transaction target temporary changed before cleanup")
        current_metadata = _evidence_stat(entry)
        if (
            not stat.S_ISREG(current_metadata.st_mode)
            or current_metadata.st_dev != original_metadata.st_dev
            or current_metadata.st_ino != original_metadata.st_ino
            or (
                os.name == "posix"
                and stat.S_IMODE(current_metadata.st_mode) != 0o600
            )
            or (
                hasattr(os, "geteuid")
                and current_metadata.st_uid != os.geteuid()
            )
        ):
            raise ValueError("transaction target temporary changed before cleanup")
    for entry, _metadata in temporaries:
        _evidence_unlink(entry)
    _fsync_directory(Path(path).parent)


def _stream_target_sha256(
    path: Path,
    *,
    maximum: int,
    expected_size: int,
    expected_metadata: os.stat_result | None = None,
) -> str:
    metadata = (
        _evidence_stat(path)
        if expected_metadata is None
        else expected_metadata
    )
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size != expected_size
        or metadata.st_size > maximum
    ):
        raise ValueError("transaction target size is invalid")
    digest = hashlib.sha256()
    observed = 0
    for chunk in bounded_io._iter_regular_chunks(
        path, expected_metadata=metadata
    ):
        observed += len(chunk)
        if observed > maximum or observed > expected_size:
            raise ValueError("transaction target size changed while hashing")
        digest.update(chunk)
    if observed != expected_size:
        raise ValueError("transaction target size changed while hashing")
    return "sha256:" + digest.hexdigest()


def _existing_target_matches(path: Path, target: dict) -> bool:
    if not _evidence_is_file(path) or _evidence_is_symlink(path):
        return False
    metadata = _evidence_stat(path)
    expected_size = len(target["content"])
    if metadata.st_size != expected_size:
        return False
    return _stream_target_sha256(
        path,
        maximum=_transaction_target_limit(target["path"]),
        expected_size=expected_size,
        expected_metadata=metadata,
    ) == target["sha256"]


def _preflight_pending_transactions(
    publication_root: Path, pending: list[tuple[Path, dict]]
) -> None:
    """Validate the complete recovery set before its first filesystem change."""

    virtual_directories = set()
    for _journal_path, transaction in pending:
        for relative in sorted(
            transaction["requiredDirectories"],
            key=lambda item: (item.count("/"), item),
        ):
            directory = _contained_transaction_path(
                publication_root, relative, "transaction required directory"
            )
            if _evidence_exists(directory):
                if _evidence_is_symlink(directory) or not _evidence_is_dir(directory):
                    raise ValueError(
                        "transaction required directory is not a safe directory"
                    )
                continue
            parent_relative = (
                relative.rsplit("/", 1)[0] if "/" in relative else ""
            )
            if parent_relative not in virtual_directories:
                parent = directory.parent
                if _evidence_is_symlink(parent) or not _evidence_is_dir(parent):
                    raise ValueError(
                        "transaction required directory parent is unsafe"
                    )
            virtual_directories.add(relative)

        for index, target in enumerate(transaction["targets"]):
            path = _contained_transaction_path(
                publication_root, target["path"], f"targets[{index}].path"
            )
            parent_relative = (
                target["path"].rsplit("/", 1)[0]
                if "/" in target["path"]
                else ""
            )
            if not _evidence_exists(path.parent):
                if parent_relative not in virtual_directories:
                    raise ValueError("transaction target parent is unavailable")
                continue
            if _evidence_is_symlink(path.parent) or not _evidence_is_dir(path.parent):
                raise ValueError("transaction target parent is unsafe")
            _validated_target_temporaries(path)
            if _evidence_exists(path):
                if _evidence_is_symlink(path) or not _evidence_is_file(path):
                    raise ValueError("transaction target is not a safe file")
                _existing_target_matches(path, target)


def _apply_transaction(
    publication_root: Path, journal_path: Path, transaction: dict
) -> None:
    prepared_targets = []
    for index, target in enumerate(transaction["targets"]):
        path = _contained_transaction_path(
            publication_root, target["path"], f"targets[{index}].path"
        )
        prepared_targets.append(
            (target, path, _validated_target_temporaries(path))
        )
    _ensure_transaction_directories(
        publication_root, transaction["requiredDirectories"]
    )
    target_parent_identities = {}
    for _target, path, _temporaries in prepared_targets:
        parent_metadata = _evidence_stat(path.parent)
        target_parent_identities[path.parent] = (
            parent_metadata.st_dev,
            parent_metadata.st_ino,
        )
    for index, (target, path, temporaries) in enumerate(prepared_targets):
        _remove_target_temporaries(path, temporaries)
        if not _existing_target_matches(path, target):
            _atomic_write_bytes(path, target["content"])
        _remove_target_temporaries(
            path, _validated_target_temporaries(path)
        )
        if not _evidence_is_file(path) or _evidence_is_symlink(path):
            raise ValueError("transaction target was not written safely")
        if _stream_target_sha256(
            path,
            maximum=_transaction_target_limit(target["path"]),
            expected_size=len(target["content"]),
        ) != target["sha256"]:
            raise ValueError("transaction target failed hash verification")
        _transaction_checkpoint("target", index)

    for target in transaction["targets"]:
        path = _contained_transaction_path(
            publication_root, target["path"], "transaction final target"
        )
        if _stream_target_sha256(
            path,
            maximum=_transaction_target_limit(target["path"]),
            expected_size=len(target["content"]),
        ) != target["sha256"]:
            raise ValueError("transaction final hash verification failed")
    _safe_io_owner._rooted_io_checkpoint(
        "journal", "before_unlink", journal_path
    )
    for parent, expected_identity in target_parent_identities.items():
        current = _evidence_stat(parent)
        if (
            not stat.S_ISDIR(current.st_mode)
            or (current.st_dev, current.st_ino) != expected_identity
        ):
            raise RootedIOError(
                f"{ROOTED_IO_CONTAINMENT_ERROR}: transaction target parent changed before commit"
            )
    _evidence_unlink(journal_path)
    _fsync_directory(journal_path.parent)
    _transaction_checkpoint("committed", -1)


def _recover_pending_transactions_unlocked(publication_root: Path) -> list[dict]:
    transaction_root, paths, orphan_temporaries = (
        _pending_transaction_inventory(publication_root)
    )
    pending = _load_transactions_from_paths(publication_root, paths)
    _preflight_pending_transactions(publication_root, pending)
    _cleanup_orphan_transaction_temporaries(
        transaction_root, orphan_temporaries
    )
    recovered = []
    for journal_path, transaction in pending:
        _apply_transaction(publication_root, journal_path, transaction)
        recovered.append(transaction)
    return recovered


@_rooted_publication_mutation
def _recover_pending_transactions(publication_root: Path) -> list[dict]:
    publication_root = Path(publication_root)
    with _exclusive_lock(publication_root / ".transactions.lock"):
        return _recover_pending_transactions_unlocked(publication_root)


def _make_transaction(
    publication_root: Path,
    operation: str,
    root: Path,
    required_directories: list[str],
    targets: list[tuple[str, bytes]],
    *,
    request_fingerprint: str,
) -> dict:
    attempt_relative = _attempt_root_relative(publication_root, root)
    if operation not in _TRANSACTION_OPERATIONS:
        raise ValueError("transaction operation is invalid")
    if (
        not isinstance(request_fingerprint, str)
        or _REQUEST_FINGERPRINT_RE.fullmatch(request_fingerprint) is None
    ):
        raise ValueError("transaction requestFingerprint is invalid")
    if not isinstance(required_directories, list) or not required_directories:
        raise ValueError("transaction requiredDirectories must be a non-empty array")
    if len(required_directories) > MAX_TRANSACTION_REQUIRED_DIRECTORY_COUNT:
        raise ValueError(
            "transaction required directory count exceeds "
            f"{MAX_TRANSACTION_REQUIRED_DIRECTORY_COUNT}"
        )
    if not isinstance(targets, list) or not targets:
        raise ValueError("transaction targets must be a non-empty array")
    if len(targets) > MAX_TRANSACTION_TARGET_COUNT:
        raise ValueError(
            f"transaction target count exceeds {MAX_TRANSACTION_TARGET_COUNT}"
        )

    seen_directories = set()
    for index, relative in enumerate(required_directories):
        _contained_transaction_path(
            publication_root, relative, f"requiredDirectories[{index}]"
        )
        if relative in seen_directories:
            raise ValueError("transaction requiredDirectories must be unique")
        seen_directories.add(relative)
    canonical_directories = sorted(
        seen_directories, key=lambda item: (item.count("/"), item)
    )

    prepared_targets = []
    aggregate_bytes = 0
    seen_paths = set()
    for index, item in enumerate(targets):
        if not isinstance(item, tuple) or len(item) != 2:
            raise ValueError(f"transaction target {index} is invalid")
        path, content = item
        _contained_transaction_path(
            publication_root, path, f"targets[{index}].path"
        )
        if path in seen_paths:
            raise ValueError("transaction target paths must be unique")
        seen_paths.add(path)
        if not isinstance(content, bytes):
            raise ValueError("transaction target content must be bytes")
        maximum = _transaction_target_limit(path)
        if len(content) > maximum:
            raise _transaction_target_limit_error(path, maximum)
        aggregate_bytes += len(content)
        if aggregate_bytes > MAX_TRANSACTION_TARGET_AGGREGATE_BYTES:
            raise ValueError(
                "transaction target aggregate exceeds "
                f"{MAX_TRANSACTION_TARGET_AGGREGATE_BYTES} bytes"
            )
        _validate_transaction_target_content(path, content)
        prepared_targets.append((path, content))

    journal = {
        "schemaVersion": 1,
        "operation": operation,
        "attemptRoot": attempt_relative,
        "requestFingerprint": request_fingerprint,
        "requiredDirectories": canonical_directories,
        "targets": [
            {
                "path": path,
                "contentBase64": base64.b64encode(content).decode("ascii"),
                "sha256": "sha256:" + hashlib.sha256(content).hexdigest(),
            }
            for path, content in prepared_targets
        ],
    }
    bounded_io._json_bytes_bounded(
        journal,
        maximum=MAX_TRANSACTION_JOURNAL_BYTES,
        label="transaction journal",
    )
    return _validate_transaction_journal(publication_root, journal)


def _commit_transaction_unlocked(publication_root: Path, transaction: dict) -> None:
    journal_bytes = bounded_io._json_bytes_bounded(
        transaction["journal"],
        maximum=MAX_TRANSACTION_JOURNAL_BYTES,
        label="transaction journal",
    )
    transaction_root = _transaction_directory(publication_root, create=True)
    run_id = transaction["attemptRoot"].split("/")[-1]
    fingerprint = hashlib.sha256(journal_bytes).hexdigest()[:16]
    journal_path = transaction_root / (
        f"{transaction['operation']}-{run_id}-{fingerprint}.json"
    )
    if _evidence_exists(journal_path):
        raise ValueError("transaction journal already exists")
    _atomic_write_bytes(journal_path, journal_bytes)
    _transaction_checkpoint("prepared", -1)
    _apply_transaction(publication_root, journal_path, transaction)


def _recovered_result(
    publication_root: Path,
    recovered: list[dict],
    operation: str,
    attempt_relative: str,
    request_fingerprint: str,
) -> dict | None:
    matching = [
        transaction
        for transaction in recovered
        if transaction["operation"] == operation
        and transaction["attemptRoot"] == attempt_relative
    ]
    if not matching:
        return None
    if len(matching) != 1:
        raise ValueError("multiple recovered results match one operation")
    if matching[0]["requestFingerprint"] != request_fingerprint:
        raise ValueError(
            "recovered transaction request fingerprint does not match retry"
        )
    if operation == "register":
        result_path = "attempt-index.json"
    else:
        suffix = (
            "/run-summary.json"
            if operation == "finalize"
            else "/run-context.json"
        )
        result_path = attempt_relative + suffix
    target = next(
        (
            target
            for target in matching[0]["targets"]
            if target["path"] == result_path
        ),
        None,
    )
    if target is None:
        raise ValueError("recovered transaction has no result target")
    current_path = _contained_transaction_path(
        publication_root,
        target["path"],
        "recovered transaction result target",
    )
    if not _evidence_is_file(current_path) or _evidence_is_symlink(current_path):
        raise ValueError("recovered transaction result target changed")
    metadata = _evidence_stat(current_path)
    expected_size = len(target["content"])
    maximum = _transaction_target_limit(target["path"])
    if metadata.st_size != expected_size or metadata.st_size > maximum:
        raise ValueError("recovered transaction result target changed")
    try:
        digest = _stream_target_sha256(
            current_path,
            maximum=maximum,
            expected_size=expected_size,
            expected_metadata=metadata,
        )
    except ValueError as exc:
        raise ValueError("recovered transaction result target changed") from exc
    if digest != target["sha256"]:
        raise ValueError("recovered transaction result target changed")
    try:
        result = bounded_io._decode_json_bytes(target["content"])
    except ValueError as exc:
        raise ValueError("recovered transaction result is invalid") from exc
    if not isinstance(result, dict):
        raise ValueError("recovered transaction result must be an object")
    return result


def _completed_finalize_result(
    publication_root: Path,
    attempt_relative: str,
    request_fingerprint: str,
    *,
    compatible_request_fingerprints: tuple[str, ...] = (),
) -> dict | None:
    """Reconcile a durably committed finalize after its journal was removed."""

    receipt_relative = _finalize_receipt_relative(attempt_relative)
    result_relative = attempt_relative + "/run-summary.json"
    receipt_path = _contained_transaction_path(
        publication_root, receipt_relative, "finalize receipt"
    )
    result_path = _contained_transaction_path(
        publication_root, result_relative, "finalize receipt result"
    )
    receipt_exists = _evidence_exists(receipt_path) or _evidence_is_symlink(
        receipt_path
    )
    result_exists = _evidence_exists(result_path) or _evidence_is_symlink(
        result_path
    )
    if not receipt_exists:
        return None
    if _evidence_is_symlink(receipt_path) or not _evidence_is_file(receipt_path):
        raise ValueError("finalize receipt is not a safe regular file")
    if (
        not result_exists
        or _evidence_is_symlink(result_path)
        or not _evidence_is_file(result_path)
    ):
        raise ValueError("finalize receipt result is not a safe regular file")

    receipt = _read_finalize_receipt(receipt_path, receipt_relative)
    result_content = _read_bounded_bytes(result_path, MAX_STRUCTURED_JSON_BYTES)
    result_sha256 = "sha256:" + hashlib.sha256(result_content).hexdigest()
    result = _validate_transaction_target_content(result_relative, result_content)
    if not isinstance(result, dict):
        raise ValueError("finalize receipt result must be an object")
    _validate_finalize_receipt_binding(
        receipt,
        request_fingerprint=result.get("finalizeRequestFingerprint"),
        result_sha256=result_sha256,
    )
    if receipt["requestFingerprint"] not in (
        request_fingerprint,
        *compatible_request_fingerprints,
    ):
        raise ValueError(
            "completed finalize request fingerprint does not match retry"
        )
    return result


def _pending_transaction_errors_for_attempt(root: Path) -> list[str]:
    root = Path(root)
    publication_root = _publication_root_for_attempt(root)
    try:
        pending = _load_pending_transactions(publication_root)
        attempt_relative = _attempt_root_relative(publication_root, root)
    except ValueError as exc:
        return [f"transactions: unsafe pending journal: {exc}"]
    errors = []
    for journal_path, transaction in pending:
        if transaction["attemptRoot"] == attempt_relative or any(
            target["path"].startswith(attempt_relative + "/")
            for target in transaction["targets"]
        ):
            errors.append(
                f"transactions/{journal_path.name}: pending transaction affects attempt"
            )
    return errors

__all__ = (
    "_TRANSACTION_OPERATIONS",
    "_TRANSACTION_KEYS",
    "_TRANSACTION_TARGET_KEYS",
    "_REQUEST_FINGERPRINT_RE",
    "_ATOMIC_TEMP_TOKEN_PATTERN",
    "_ATOMIC_WRITE_TEMP_RE",
    "_TRANSACTION_TEMP_RE",
    "_TRANSACTION_JOURNAL_RE",
    "_transaction_checkpoint",
    "_publication_root_for_attempt",
    "_attempt_root_relative",
    "_request_fingerprint",
    "_contained_transaction_path",
    "_transaction_directory",
    "_validate_transaction_target_content",
    "_validate_transaction_journal",
    "_pending_transaction_paths",
    "_load_pending_transactions",
    "_ensure_transaction_directories",
    "_validated_target_temporaries",
    "_remove_target_temporaries",
    "_apply_transaction",
    "_recover_pending_transactions_unlocked",
    "_recover_pending_transactions",
    "_make_transaction",
    "_commit_transaction_unlocked",
    "_recovered_result",
    "_completed_finalize_result",
    "_pending_transaction_errors_for_attempt",
)
