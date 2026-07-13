"""Publication journal validation, replay, and recovery."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import stat
from pathlib import Path
from typing import Any

from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .bounded_io import _read_bounded_bytes
from .receipts import (
    MAX_FINALIZE_RECEIPT_BYTES,
    _finalize_receipt_relative,
    _legacy_finalize_receipt_request_fingerprint,
    _make_finalize_receipt,
    _read_finalize_receipt,
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


def _validate_transaction_target_content(path: str, content: bytes) -> Any:
    try:
        if path == "attempt-index.json":
            value = json.loads(content.decode("utf-8"))
            _validate_index(value)
        elif path.endswith("/run-context.json"):
            value = json.loads(content.decode("utf-8"))
            _validate_context_identity(value)
        elif path.endswith("/run-summary.json"):
            value = json.loads(content.decode("utf-8"))
            errors = validate_summary(value)
            if errors:
                raise ValueError("; ".join(errors))
        elif path.endswith("/run-summary.invalid.json"):
            value = json.loads(content.decode("utf-8"))
            if not isinstance(value, dict):
                raise ValueError("invalid candidate must be an object")
        elif path.endswith("/run-summary.invalid.errors.json"):
            value = json.loads(content.decode("utf-8"))
            if not isinstance(value, dict) or not isinstance(value.get("errors"), list):
                raise ValueError("invalid diagnostics must contain errors")
        elif path.endswith("/finalize-receipt.json"):
            value = _validate_finalize_receipt_content(path, content)
        elif path.endswith("/bootstrap-events.jsonl"):
            events = []
            for line in content.decode("utf-8").splitlines():
                if not line.strip():
                    continue
                event = json.loads(line)
                errors = validate_event(event)
                if errors:
                    raise ValueError("; ".join(errors))
                events.append(event)
            if [event["seq"] for event in events] != list(range(1, len(events) + 1)):
                raise ValueError("event sequence is not contiguous")
            value = events
        else:
            raise ValueError("transaction target is not an approved lifecycle file")
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"transaction target {path} is invalid JSON evidence") from exc
    return value


def _validate_transaction_journal(publication_root: Path, journal: Any) -> dict:
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
    decoded_targets = []
    seen_paths = set()
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
        if (
            isinstance(relative, str)
            and relative.endswith("/finalize-receipt.json")
            and isinstance(encoded_content, str)
            and len(encoded_content)
            > ((MAX_FINALIZE_RECEIPT_BYTES + 2) // 3) * 4
        ):
            raise ValueError(
                f"finalize receipt exceeds {MAX_FINALIZE_RECEIPT_BYTES} bytes"
            )
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
    """Project one validated receipt-less finalize WAL into the current format."""

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
    migrated_event_target = _decoded_transaction_target(
        event_path,
        b"".join(_json_bytes(event) for event in migrated_events),
    )

    legacy_request_fingerprint = transaction["requestFingerprint"]
    receipt_request_fingerprint = (
        _legacy_finalize_receipt_request_fingerprint(
            legacy_request_fingerprint
        )
    )
    receipt_target = _decoded_transaction_target(
        receipt_path,
        _make_finalize_receipt(
            attempt_relative,
            receipt_request_fingerprint,
            summary_target["content"],
        ),
    )
    transaction["targets"] = [
        migrated_event_target if target["path"] == event_path else target
        for target in transaction["targets"]
    ] + [receipt_target]
    transaction["requestFingerprint"] = receipt_request_fingerprint
    transaction["legacyFinalizeUpgrade"] = True
    _validate_transaction_operation(
        transaction["operation"],
        attempt_relative,
        transaction["requiredDirectories"],
        transaction["targets"],
        receipt_request_fingerprint,
    )


def _pending_transaction_paths(
    publication_root: Path, *, cleanup_orphan_temporaries: bool = False
) -> list[Path]:
    transaction_root = _transaction_directory(publication_root, create=False)
    if not _evidence_exists(transaction_root):
        return []
    paths = []
    orphan_temporaries = []
    for entry in sorted(_evidence_iterdir(transaction_root), key=lambda item: item.name):
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
        if not _evidence_is_file(entry) or entry.suffix != ".json":
            raise ValueError("transaction directory contains an unsafe entry")
        paths.append(entry)
    if orphan_temporaries:
        if not cleanup_orphan_temporaries:
            raise ValueError("orphan transaction temporary requires recovery")
        for entry, original_metadata in orphan_temporaries:
            current_metadata = _evidence_stat(entry)
            if (
                not stat.S_ISREG(current_metadata.st_mode)
                or current_metadata.st_dev != original_metadata.st_dev
                or current_metadata.st_ino != original_metadata.st_ino
            ):
                raise ValueError("orphan transaction temporary changed before cleanup")
        for entry, _metadata in orphan_temporaries:
            _evidence_unlink(entry)
        _fsync_directory(transaction_root)
    return paths


def _load_pending_transactions(
    publication_root: Path, *, cleanup_orphan_temporaries: bool = False
) -> list[tuple[Path, dict]]:
    loaded = []
    seen_targets = set()
    seen_operations = set()
    for journal_path in _pending_transaction_paths(
        publication_root,
        cleanup_orphan_temporaries=cleanup_orphan_temporaries,
    ):
        journal_bytes = _evidence_read_bytes(journal_path)
        try:
            journal = json.loads(journal_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise ValueError("transaction journal is invalid JSON") from exc
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
    for entry in sorted(_evidence_iterdir(parent), key=lambda item: item.name):
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
        existing = None
        if _evidence_is_file(path):
            if target["path"].endswith("/finalize-receipt.json"):
                receipt_metadata = _evidence_stat(path)
                if receipt_metadata.st_size <= MAX_FINALIZE_RECEIPT_BYTES:
                    existing = _read_bounded_bytes(
                        path,
                        MAX_FINALIZE_RECEIPT_BYTES,
                        expected_metadata=receipt_metadata,
                    )
            else:
                existing = _evidence_read_bytes(path)
        if existing is None or hashlib.sha256(existing).digest() != hashlib.sha256(
            target["content"]
        ).digest():
            _atomic_write_bytes(path, target["content"])
        _remove_target_temporaries(
            path, _validated_target_temporaries(path)
        )
        if not _evidence_is_file(path) or _evidence_is_symlink(path):
            raise ValueError("transaction target was not written safely")
        if target["path"].endswith("/finalize-receipt.json"):
            written_content = _read_bounded_bytes(
                path, MAX_FINALIZE_RECEIPT_BYTES
            )
        else:
            written_content = _evidence_read_bytes(path)
        if "sha256:" + hashlib.sha256(written_content).hexdigest() != target["sha256"]:
            raise ValueError("transaction target failed hash verification")
        _transaction_checkpoint("target", index)

    for target in transaction["targets"]:
        path = _contained_transaction_path(
            publication_root, target["path"], "transaction final target"
        )
        if target["path"].endswith("/finalize-receipt.json"):
            current_content = _read_bounded_bytes(
                path, MAX_FINALIZE_RECEIPT_BYTES
            )
        else:
            current_content = _evidence_read_bytes(path)
        if "sha256:" + hashlib.sha256(current_content).hexdigest() != target["sha256"]:
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
    pending = _load_pending_transactions(
        publication_root, cleanup_orphan_temporaries=True
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
    journal = {
        "schemaVersion": 1,
        "operation": operation,
        "attemptRoot": attempt_relative,
        "requestFingerprint": request_fingerprint,
        "requiredDirectories": sorted(
            set(required_directories), key=lambda item: (item.count("/"), item)
        ),
        "targets": [
            {
                "path": path,
                "contentBase64": base64.b64encode(content).decode("ascii"),
                "sha256": "sha256:" + hashlib.sha256(content).hexdigest(),
            }
            for path, content in targets
        ],
    }
    return _validate_transaction_journal(publication_root, journal)


def _commit_transaction_unlocked(publication_root: Path, transaction: dict) -> None:
    transaction_root = _transaction_directory(publication_root, create=True)
    journal_bytes = _json_bytes(transaction["journal"])
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
    if (
        not _evidence_is_file(current_path)
        or _evidence_is_symlink(current_path)
        or "sha256:"
        + hashlib.sha256(_evidence_read_bytes(current_path)).hexdigest()
        != target["sha256"]
    ):
        raise ValueError("recovered transaction result target changed")
    try:
        result = json.loads(target["content"].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
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
    if receipt["resultSha256"] != result_sha256:
        raise ValueError("finalize receipt result hash does not match summary")
    result = _validate_transaction_target_content(result_relative, result_content)
    if receipt["requestFingerprint"] not in (
        request_fingerprint,
        *compatible_request_fingerprints,
    ):
        raise ValueError(
            "completed finalize request fingerprint does not match retry"
        )
    if not isinstance(result, dict):
        raise ValueError("finalize receipt result must be an object")
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
