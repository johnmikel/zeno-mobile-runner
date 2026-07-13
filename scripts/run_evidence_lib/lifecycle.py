"""Attempt registration, context, events, and initialization."""

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

from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .contracts import _comparability_tuple
from .sanitization import *  # noqa: F401,F403
from .safe_io import *  # noqa: F401,F403
from .journal import *  # noqa: F401,F403

def _load_index(index_path: Path) -> dict:
    if not _evidence_exists(Path(index_path)):
        return {"schemaVersion": "1.0", "executions": []}
    index = _read_json(index_path)
    _validate_index(index)
    return index


def _registered_index_candidate(
    index_path: Path, attempt_root: Path, context: dict
) -> dict:
    _validate_context_identity(context)
    _validate_attempt_root(index_path, attempt_root, context["runId"])
    index = _load_index(index_path)
    run_id = context["runId"]
    execution_id = context["executionId"]
    attempt_number = context["attempt"]
    for execution in index["executions"]:
        for entry in execution["attempts"]:
            if entry["runId"] == run_id:
                raise ValueError("runId is already registered")

    comparable = _comparability_tuple(context)
    execution = next(
        (
            item
            for item in index["executions"]
            if item["executionId"] == execution_id
        ),
        None,
    )
    if execution is None:
        if attempt_number != 1:
            raise ValueError("new execution must start at attempt 1")
        execution = {
            "executionId": execution_id,
            "comparabilityTuple": comparable,
            "attempts": [],
        }
        index["executions"].append(execution)
    else:
        expected_attempt = len(execution["attempts"]) + 1
        if attempt_number != expected_attempt:
            raise ValueError("retry attempt number must be the next contiguous value")
        if execution["comparabilityTuple"] != comparable:
            raise ValueError("retry comparability tuple differs from its execution")

    execution["attempts"].append(
        {
            "runId": run_id,
            "attempt": attempt_number,
            "summary": f"attempts/{run_id}/run-summary.json",
        }
    )
    _validate_index(index)
    return index


def _register_attempt_unlocked(
    index_path: Path,
    attempt_root: Path,
    context: dict,
    *,
    request_fingerprint: str,
) -> dict:
    index = _registered_index_candidate(index_path, attempt_root, context)
    publication_root = Path(index_path).absolute().parent
    attempt_relative = _attempt_root_relative(publication_root, attempt_root)
    transaction = _make_transaction(
        publication_root,
        "register",
        attempt_root,
        [attempt_relative],
        [("attempt-index.json", _json_bytes(index))],
        request_fingerprint=request_fingerprint,
    )
    _commit_transaction_unlocked(publication_root, transaction)
    return index


@_rooted_index_mutation
def register_attempt(index_path: Path, attempt_root: Path, context: dict) -> dict:
    """Register one globally unique, monotonically numbered attempt atomically."""

    index_path = Path(index_path).absolute()
    attempt_root = Path(attempt_root).absolute()
    if not _evidence_is_dir(index_path.parent):
        raise ValueError("attempt index parent does not exist")
    publication_root = index_path.parent
    attempt_relative = _attempt_root_relative(publication_root, attempt_root)
    context = _sanitize_value(
        context,
        roots=_sanitization_roots(attempt_root),
        secrets=_collect_secret_values(),
    )
    _validate_context_identity(context)
    request_fingerprint = _request_fingerprint(
        publication_root, "register", attempt_root, context
    )
    with _exclusive_lock(publication_root / ".transactions.lock"):
        recovered = _recover_pending_transactions_unlocked(publication_root)
        recovered_result = _recovered_result(
            publication_root,
            recovered,
            "register",
            attempt_relative,
            request_fingerprint,
        )
        if recovered_result is not None:
            return recovered_result
        with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
            return _register_attempt_unlocked(
                index_path,
                attempt_root,
                context,
                request_fingerprint=request_fingerprint,
            )


def _deep_merge(base: dict, patch: dict) -> dict:
    result = json.loads(json.dumps(base))
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


_CONTEXT_PATCH_FIELDS = {
    "candidateRevision",
    "fixtureId",
    "fixtureVersion",
    "scenarioDigest",
    "appBuildDigest",
    "platform",
    "deviceClass",
    "runtimeVersion",
    "host",
    "runnerVersion",
    "protocolVersion",
    "timingMode",
    "toolchain",
    "device",
    "artifacts",
}


def _validate_context_patch(patch: Any) -> None:
    if not isinstance(patch, dict):
        raise ValueError("context patch must be an object")
    unknown = sorted(set(patch) - _CONTEXT_PATCH_FIELDS)
    if unknown:
        raise ValueError("context patch contains disallowed fields: " + ", ".join(unknown))
    closed = {
        "host": {"os", "arch", "class", "ci"},
        "device": {"requested", "resolved"},
        "artifacts": {"trace", "report"},
    }
    for field, allowed in closed.items():
        value = patch.get(field)
        if value is not None:
            if not isinstance(value, dict):
                raise ValueError(f"$.{field}: patch must be an object")
            extra = sorted(set(value) - allowed)
            if extra:
                raise ValueError(f"$.{field}: disallowed fields: " + ", ".join(extra))


def _merge_resolved_identity(existing: Any, updated: Any, path: str = "$") -> Any:
    if isinstance(existing, dict) and isinstance(updated, dict):
        if set(existing) != set(updated):
            raise ValueError(f"{path}: identity keys cannot change")
        return {
            key: _merge_resolved_identity(
                existing[key], updated[key], path + "." + str(key)
            )
            for key in existing
        }
    if existing is None:
        return updated
    if updated != existing:
        raise ValueError(f"{path}: resolved identity cannot change")
    return existing


def _execution_for_run(index: dict, run_id: str) -> dict:
    matches = [
        execution
        for execution in index["executions"]
        if any(entry["runId"] == run_id for entry in execution["attempts"])
    ]
    if len(matches) != 1:
        raise ValueError("runId must have exactly one registered execution")
    return matches[0]


def _context_with_registered_tuple(context: dict, comparable: dict) -> dict:
    restored = json.loads(json.dumps(context))
    for field in (
        "candidateRevision",
        "fixtureId",
        "fixtureVersion",
        "scenarioDigest",
        "appBuildDigest",
        "platform",
        "deviceClass",
        "runtimeVersion",
        "runnerVersion",
        "protocolVersion",
        "timingMode",
        "toolchain",
    ):
        restored[field] = comparable.get(field)
    host = restored.get("host")
    ci = host.get("ci") if isinstance(host, dict) else None
    restored["host"] = dict(comparable.get("host", {}))
    restored["host"]["ci"] = ci
    return restored


@_rooted_attempt_mutation
def update_context(
    root: Path,
    patch: dict,
    *,
    _recovered_transactions: list[dict] | None = None,
) -> dict:
    """Patch allowlisted context fields while preserving execution identity."""

    root = Path(root).absolute()
    publication_root = _publication_root_for_attempt(root)
    attempt_relative = _attempt_root_relative(publication_root, root)
    context_path = root / "run-context.json"
    index_path = publication_root / "attempt-index.json"
    with _exclusive_lock(publication_root / ".transactions.lock"):
        recovered = _recover_pending_transactions_unlocked(publication_root)
        if _recovered_transactions is not None:
            _recovered_transactions.extend(recovered)

        patch = _sanitize_value(
            patch,
            roots=_sanitization_roots(root),
            secrets=_collect_secret_values(),
        )
        _validate_context_patch(patch)
        request_fingerprint = _request_fingerprint(
            publication_root, "context", root, patch
        )
        if not _evidence_is_file(context_path) or not _evidence_is_file(index_path):
            raise ValueError("attempt context or index is missing")
        with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
            index = _load_index(index_path)
            execution = _execution_for_run(index, root.name)
            sibling_roots = {
                entry["runId"]: publication_root / "attempts" / entry["runId"]
                for entry in execution["attempts"]
            }
            if (
                root.name not in sibling_roots
                or sibling_roots[root.name].absolute() != root
            ):
                raise ValueError("attempt root does not match its registered runId")
            with ExitStack() as locks:
                for sibling_root in sorted(
                    sibling_roots.values(), key=lambda item: item.name
                ):
                    locks.enter_context(
                        _exclusive_lock(sibling_root / ".context.lock")
                    )
                contexts = {}
                for run_id, sibling_root in sibling_roots.items():
                    sibling_context_path = sibling_root / "run-context.json"
                    if not _evidence_is_file(sibling_context_path):
                        raise ValueError("registered sibling attempt context is missing")
                    contexts[run_id] = _read_json(sibling_context_path)

                context = contexts[root.name]
                updated = _deep_merge(context, patch)
                _validate_context_identity(updated)
                if updated == context:
                    return context
                if _evidence_exists(root / "run-summary.json"):
                    raise ValueError("finalized attempt context is immutable")
                registered_tuple = execution["comparabilityTuple"]
                for run_id, sibling_context in contexts.items():
                    if (
                        _comparability_tuple(sibling_context)
                        != registered_tuple
                    ):
                        raise ValueError(
                            f"stored context for {run_id} disagrees with attempt index"
                        )
                new_tuple = _comparability_tuple(updated)
                resolved_tuple = _merge_resolved_identity(
                    registered_tuple, new_tuple
                )
                identity_changed = registered_tuple != resolved_tuple
                if identity_changed and any(
                    _evidence_exists(sibling_root / "run-summary.json")
                    for sibling_root in sibling_roots.values()
                ):
                    raise ValueError("finalized sibling attempt identity is immutable")

                updated_contexts = dict(contexts)
                updated_contexts[root.name] = updated
                if identity_changed:
                    updated_contexts = {
                        run_id: _context_with_registered_tuple(
                            sibling_context, resolved_tuple
                        )
                        for run_id, sibling_context in updated_contexts.items()
                    }
                    for sibling_context in updated_contexts.values():
                        _validate_context_identity(sibling_context)

                execution["comparabilityTuple"] = resolved_tuple
                changed_contexts = {
                    run_id: value
                    for run_id, value in updated_contexts.items()
                    if value != contexts[run_id]
                }
                targets = list(
                    (
                        f"attempts/{run_id}/run-context.json",
                        _json_bytes(value),
                    )
                    for run_id, value in sorted(changed_contexts.items())
                )
                targets.append(("attempt-index.json", _json_bytes(index)))
                required_directories = [
                    f"attempts/{run_id}" for run_id in sorted(changed_contexts)
                ]
                if attempt_relative not in required_directories:
                    required_directories.append(attempt_relative)
                transaction = _make_transaction(
                    publication_root,
                    "context",
                    root,
                    required_directories,
                    targets,
                    request_fingerprint=request_fingerprint,
                )
                _commit_transaction_unlocked(publication_root, transaction)
                return updated_contexts[root.name]


def _read_bootstrap_events(root: Path) -> list[dict]:
    path = root / "bootstrap-events.jsonl"
    events = []
    if _evidence_exists(path):
        try:
            for line_number, line in enumerate(
                _evidence_read_text(path).splitlines(), 1
            ):
                if not line.strip():
                    continue
                event = json.loads(line)
                if validate_event(event):
                    raise ValueError(f"invalid existing event at line {line_number}")
                events.append(event)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"invalid bootstrap event log: {exc}") from exc
    if [item["seq"] for item in events] != list(range(1, len(events) + 1)):
        raise ValueError("bootstrap event sequence is not contiguous")
    return events


def _event_stream_candidate(
    root: Path,
    phase: str,
    status: str,
    *,
    events: list[dict] | None = None,
    _timestamp: str | None = None,
    **metadata: Any,
) -> tuple[dict, bytes, list[dict]]:
    events = _read_bootstrap_events(root) if events is None else list(events)
    event = {
        "schemaVersion": 1,
        "seq": len(events) + 1,
        "timestamp": _utc_now() if _timestamp is None else _timestamp,
        "phase": phase,
        "status": status,
    }
    metadata = _sanitize_value(
        metadata,
        roots=_sanitization_roots(root),
        secrets=_collect_secret_values(),
    )
    for field in ("errorCode", "summary", "command", "commandStatus", "artifact"):
        if field in metadata and metadata[field] is not None:
            event[field] = metadata[field]
    errors = validate_event(event)
    if errors:
        raise ValueError("invalid bootstrap event: " + "; ".join(errors))
    events.append(event)
    content = b"".join(_json_bytes(item) for item in events)
    return event, content, events


def _append_event_unlocked(
    root: Path, phase: str, status: str, **metadata: Any
) -> dict:
    event, content, _events = _event_stream_candidate(
        root, phase, status, **metadata
    )
    _atomic_write_bytes(root / "bootstrap-events.jsonl", content)
    return event


def _append_event_during_lifecycle(
    root: Path, phase: str, status: str, **metadata: Any
) -> dict:
    root = Path(root)
    with _exclusive_lock(root / ".events.lock"):
        if _evidence_exists(root / "run-summary.json"):
            raise ValueError("cannot append events after finalization")
        return _append_event_unlocked(root, phase, status, **metadata)


@_rooted_attempt_mutation
def _append_event(root: Path, phase: str, status: str, **metadata: Any) -> dict:
    root = Path(root)
    _recover_pending_transactions(_publication_root_for_attempt(root))
    with _exclusive_lock(root / ".lifecycle.lock"):
        return _append_event_during_lifecycle(root, phase, status, **metadata)


@_rooted_index_mutation
def _initialize_attempt(index_path: Path, root: Path, context: dict) -> dict:
    index_path = Path(index_path).absolute()
    root = Path(root).absolute()
    publication_root = index_path.parent
    if not _evidence_is_dir(publication_root):
        raise ValueError("attempt index parent does not exist")
    attempt_relative = _attempt_root_relative(publication_root, root)
    context = _sanitize_value(
        context,
        roots=_sanitization_roots(root),
        secrets=_collect_secret_values(),
    )
    _validate_context_identity(context)
    _validate_attempt_root(index_path, root, context["runId"])
    request_fingerprint = _request_fingerprint(
        publication_root, "init", root, context
    )
    with _exclusive_lock(publication_root / ".transactions.lock"):
        recovered = _recover_pending_transactions_unlocked(publication_root)
        recovered_result = _recovered_result(
            publication_root,
            recovered,
            "init",
            attempt_relative,
            request_fingerprint,
        )
        if recovered_result is not None:
            return recovered_result

        if _evidence_exists(root):
            raise FileExistsError("attempt root already exists")
        with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
            if _evidence_exists(root):
                raise FileExistsError("attempt root already exists")
            stored = json.loads(json.dumps(context))
            stored["startedAt"] = _utc_now()
            index = _registered_index_candidate(index_path, root, stored)
            _started, _started_bytes, events = _event_stream_candidate(
                root, "evidence.init", "started", events=[]
            )
            _passed, event_bytes, _events = _event_stream_candidate(
                root, "evidence.init", "passed", events=events
            )
            transaction = _make_transaction(
                publication_root,
                "init",
                root,
                ["attempts", attempt_relative, attempt_relative + "/commands"],
                [
                    (attempt_relative + "/run-context.json", _json_bytes(stored)),
                    (attempt_relative + "/bootstrap-events.jsonl", event_bytes),
                    ("attempt-index.json", _json_bytes(index)),
                ],
                request_fingerprint=request_fingerprint,
            )
            _commit_transaction_unlocked(publication_root, transaction)
            return stored

__all__ = (
    "_load_index",
    "_registered_index_candidate",
    "_register_attempt_unlocked",
    "register_attempt",
    "_deep_merge",
    "_CONTEXT_PATCH_FIELDS",
    "_validate_context_patch",
    "_merge_resolved_identity",
    "_execution_for_run",
    "_context_with_registered_tuple",
    "update_context",
    "_read_bootstrap_events",
    "_event_stream_candidate",
    "_append_event_unlocked",
    "_append_event_during_lifecycle",
    "_append_event",
    "_initialize_attempt",
)
