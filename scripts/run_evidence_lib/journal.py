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
from .safe_io import *  # noqa: F401,F403
from . import safe_io as _safe_io_owner


_TRANSACTION_OPERATIONS = ("init", "context", "finalize")
_TRANSACTION_KEYS = {
    "schemaVersion",
    "operation",
    "attemptRoot",
    "requiredDirectories",
    "targets",
}
_TRANSACTION_TARGET_KEYS = {"path", "contentBase64", "sha256"}
_ATOMIC_TEMP_TOKEN_PATTERN = r"[a-z0-9_]{8}"
_ATOMIC_WRITE_TEMP_RE = re.compile(
    rf"^[.].+[.]{_ATOMIC_TEMP_TOKEN_PATTERN}[.]tmp$"
)
_TRANSACTION_TEMP_RE = re.compile(
    r"^[.](?P<operation>init|context|finalize)-"
    r"(?P<runId>.+)-(?P<fingerprint>[0-9a-f]{16})[.]json[.]"
    rf"(?P<token>{_ATOMIC_TEMP_TOKEN_PATTERN})[.]tmp$"
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


def _contained_transaction_path(
    publication_root: Path, relative: Any, label: str
) -> Path:
    if not _valid_relative_path(relative):
        raise ValueError(f"{label}: must be a normalized relative path")
    if relative == ".transactions" or relative.startswith(".transactions/"):
        raise ValueError(f"{label}: transaction internals cannot be targets")
    publication_root = Path(publication_root).absolute()
    if publication_root.is_symlink() or not publication_root.is_dir():
        raise ValueError("publication root must be a real directory")
    candidate = publication_root.joinpath(*relative.split("/"))
    current = publication_root
    for part in relative.split("/"):
        current = current / part
        if current.is_symlink():
            raise ValueError(f"{label}: path contains a symlink")
    try:
        candidate.resolve(strict=False).relative_to(publication_root.resolve())
    except ValueError as exc:
        raise ValueError(f"{label}: path escapes publication root") from exc
    return candidate


def _transaction_directory(publication_root: Path, *, create: bool) -> Path:
    transaction_root = Path(publication_root) / ".transactions"
    if transaction_root.is_symlink():
        raise ValueError("transaction directory must not be a symlink")
    if transaction_root.exists():
        if not transaction_root.is_dir():
            raise ValueError("transaction directory must be a directory")
    elif create:
        transaction_root.mkdir(mode=0o700)
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
        if directory.exists() and not directory.is_dir():
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
        if candidate.exists() and not candidate.is_file():
            raise ValueError("transaction target exists but is not a file")
        try:
            content = base64.b64decode(target.get("contentBase64"), validate=True)
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

    event_path = attempt_relative + "/bootstrap-events.jsonl"
    context_path = attempt_relative + "/run-context.json"
    summary_path = attempt_relative + "/run-summary.json"
    invalid_path = attempt_relative + "/run-summary.invalid.json"
    diagnostic_path = attempt_relative + "/run-summary.invalid.errors.json"
    ordered_paths = [target["path"] for target in decoded_targets]
    values = {target["path"]: target["value"] for target in decoded_targets}
    run_id = attempt_relative.split("/")[-1]
    if operation == "init":
        expected_paths = [context_path, event_path, "attempt-index.json"]
        expected_directories = [
            "attempts",
            attempt_relative,
            attempt_relative + "/commands",
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
        index = values["attempt-index.json"]
        registrations = [
            (execution, entry)
            for execution in index["executions"]
            for entry in execution["attempts"]
            if entry["runId"] == run_id
        ]
        if len(registrations) != 1:
            raise ValueError("init transaction index registration is invalid")
        execution, entry = registrations[0]
        if (
            execution["executionId"] != context["executionId"]
            or execution["comparabilityTuple"]
            != comparability(context)["comparabilityTuple"]
            or entry["attempt"] != context["attempt"]
        ):
            raise ValueError("init transaction index disagrees with context")
    elif operation == "context":
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
        registrations = [
            (execution, entry)
            for execution in index["executions"]
            for entry in execution["attempts"]
            if entry["runId"] == run_id
        ]
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
                or comparability(context)["comparabilityTuple"]
                != execution["comparabilityTuple"]
            ):
                raise ValueError(
                    "context transaction target disagrees with the attempt index"
                )
    else:
        expected_paths = [event_path, summary_path]
        invalid_expected_paths = [
            invalid_path,
            diagnostic_path,
            event_path,
            summary_path,
        ]
        if ordered_paths not in (expected_paths, invalid_expected_paths):
            raise ValueError("finalize transaction contains an invalid target set")
        if required_directories != [attempt_relative]:
            raise ValueError("finalize transaction directory set is invalid")
        terminal = values[summary_path]
        if terminal.get("runId") != run_id:
            raise ValueError("finalize transaction summary runId is invalid")
        events = values[event_path]
        if not events:
            raise ValueError("finalize transaction event stream is empty")
        final_event = events[-1]
        for field in ("phase", "status", "errorCode", "summary", "commandStatus"):
            if final_event.get(field) != terminal.get(field):
                raise ValueError(
                    "finalize transaction event disagrees with terminal summary"
                )
        if ordered_paths == invalid_expected_paths:
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

    return {
        "journal": journal,
        "operation": operation,
        "attemptRoot": attempt_relative,
        "requiredDirectories": required_directories,
        "targets": decoded_targets,
    }


def _pending_transaction_paths(
    publication_root: Path, *, cleanup_orphan_temporaries: bool = False
) -> list[Path]:
    transaction_root = _transaction_directory(publication_root, create=False)
    if not transaction_root.exists():
        return []
    paths = []
    orphan_temporaries = []
    transaction_resolved = transaction_root.resolve(strict=True)
    for entry in sorted(transaction_root.iterdir(), key=lambda item: item.name):
        if entry.is_symlink():
            raise ValueError("pending transaction journal must not be a symlink")
        temporary_match = _TRANSACTION_TEMP_RE.fullmatch(entry.name)
        if temporary_match is not None:
            metadata = entry.stat(follow_symlinks=False)
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError("orphan transaction temporary must be a regular file")
            if not _safe_run_segment(temporary_match.group("runId")):
                raise ValueError("orphan transaction temporary has an unsafe runId")
            try:
                entry.resolve(strict=True).relative_to(transaction_resolved)
            except ValueError as exc:
                raise ValueError(
                    "orphan transaction temporary escapes the transaction directory"
                ) from exc
            if os.name == "posix" and stat.S_IMODE(metadata.st_mode) != 0o600:
                raise ValueError("orphan transaction temporary has an unsafe mode")
            if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
                raise ValueError("orphan transaction temporary has an unsafe owner")
            orphan_temporaries.append((entry, metadata))
            continue
        if not entry.is_file() or entry.suffix != ".json":
            raise ValueError("transaction directory contains an unsafe entry")
        paths.append(entry)
    if orphan_temporaries:
        if not cleanup_orphan_temporaries:
            raise ValueError("orphan transaction temporary requires recovery")
        for entry, original_metadata in orphan_temporaries:
            current_metadata = entry.stat(follow_symlinks=False)
            if (
                not stat.S_ISREG(current_metadata.st_mode)
                or current_metadata.st_dev != original_metadata.st_dev
                or current_metadata.st_ino != original_metadata.st_ino
            ):
                raise ValueError("orphan transaction temporary changed before cleanup")
        for entry, _metadata in orphan_temporaries:
            entry.unlink()
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
        journal = _read_json(journal_path)
        validated = _validate_transaction_journal(publication_root, journal)
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
        if directory.exists():
            if not directory.is_dir():
                raise ValueError("transaction required directory is not a directory")
            continue
        if not directory.parent.is_dir() or directory.parent.is_symlink():
            raise ValueError("transaction required directory parent is unsafe")
        directory.mkdir(mode=0o700)
        _fsync_directory(directory.parent)


def _validated_target_temporaries(path: Path) -> list[tuple[Path, os.stat_result]]:
    path = Path(path)
    parent = path.parent
    if not parent.exists():
        return []
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError("transaction target parent is unsafe")
    parent_resolved = parent.resolve(strict=True)
    exact_pattern = re.compile(
        rf"^[.]{re.escape(path.name)}[.]"
        rf"{_ATOMIC_TEMP_TOKEN_PATTERN}[.]tmp$"
    )
    candidate_prefixes = (f".{path.name}.", f"{path.name}.")
    temporaries = []
    for entry in sorted(parent.iterdir(), key=lambda item: item.name):
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
        if entry.is_symlink():
            raise ValueError("transaction target temporary must not be a symlink")
        metadata = entry.stat(follow_symlinks=False)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("transaction target temporary must be a regular file")
        try:
            entry.resolve(strict=True).relative_to(parent_resolved)
        except ValueError as exc:
            raise ValueError(
                "transaction target temporary escapes its target directory"
            ) from exc
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
        if entry.is_symlink():
            raise ValueError("transaction target temporary changed before cleanup")
        current_metadata = entry.stat(follow_symlinks=False)
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
        entry.unlink()
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
    for index, (target, path, temporaries) in enumerate(prepared_targets):
        _remove_target_temporaries(path, temporaries)
        existing = path.read_bytes() if path.is_file() else None
        if existing is None or hashlib.sha256(existing).digest() != hashlib.sha256(
            target["content"]
        ).digest():
            _atomic_write_bytes(path, target["content"])
        _remove_target_temporaries(
            path, _validated_target_temporaries(path)
        )
        if not path.is_file() or path.is_symlink():
            raise ValueError("transaction target was not written safely")
        if "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest() != target["sha256"]:
            raise ValueError("transaction target failed hash verification")
        _transaction_checkpoint("target", index)

    for target in transaction["targets"]:
        path = _contained_transaction_path(
            publication_root, target["path"], "transaction final target"
        )
        if "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest() != target["sha256"]:
            raise ValueError("transaction final hash verification failed")
    journal_path.unlink()
    _fsync_directory(journal_path.parent)


def _recover_pending_transactions_unlocked(publication_root: Path) -> list[dict]:
    pending = _load_pending_transactions(
        publication_root, cleanup_orphan_temporaries=True
    )
    recovered = []
    for journal_path, transaction in pending:
        _apply_transaction(publication_root, journal_path, transaction)
        recovered.append(transaction)
    return recovered


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
) -> dict:
    attempt_relative = _attempt_root_relative(publication_root, root)
    journal = {
        "schemaVersion": 1,
        "operation": operation,
        "attemptRoot": attempt_relative,
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
    if journal_path.exists():
        raise ValueError("transaction journal already exists")
    _atomic_write_bytes(journal_path, journal_bytes)
    _transaction_checkpoint("prepared", -1)
    _apply_transaction(publication_root, journal_path, transaction)


def _recovered_result(
    recovered: list[dict], operation: str, attempt_relative: str
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
    suffix = "/run-summary.json" if operation == "finalize" else "/run-context.json"
    target = next(
        (
            target
            for target in matching[0]["targets"]
            if target["path"] == attempt_relative + suffix
        ),
        None,
    )
    if target is None:
        raise ValueError("recovered transaction has no result target")
    try:
        result = json.loads(target["content"].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("recovered transaction result is invalid") from exc
    if not isinstance(result, dict):
        raise ValueError("recovered transaction result must be an object")
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
    "_ATOMIC_TEMP_TOKEN_PATTERN",
    "_ATOMIC_WRITE_TEMP_RE",
    "_TRANSACTION_TEMP_RE",
    "_transaction_checkpoint",
    "_publication_root_for_attempt",
    "_attempt_root_relative",
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
    "_pending_transaction_errors_for_attempt",
)
