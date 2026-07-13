"""Cross-file identity checks for one publishable evidence attempt."""

from __future__ import annotations

import stat
from pathlib import Path
from typing import Any

from .bounded_io import _read_json_bounded
from .contracts import (
    _comparability_tuple,
    _validate_context_identity,
    _validate_index,
    _valid_relative_path,
)
from .safe_io import _evidence_is_file, _evidence_is_symlink
from .bundle_scan import _BundleSnapshot


_SUMMARY_CONTEXT_FIELDS = (
    "runId",
    "executionId",
    "fixtureId",
    "fixtureVersion",
    "candidateRevision",
    "scenarioDigest",
    "appBuildDigest",
    "attempt",
    "platform",
    "deviceClass",
    "runtimeVersion",
    "timingMode",
    "runnerVersion",
    "protocolVersion",
    "host",
    "device",
    "toolchain",
    "startedAt",
)

_UNSCANNED_INDEX = object()


def _context_artifacts(context: dict, errors: list[str]) -> dict[str, Any]:
    artifacts = context.get("artifacts")
    if not isinstance(artifacts, dict):
        errors.append("run-context.json.artifacts: must be an object")
        return {}
    if artifacts.keys() - {"trace", "report"}:
        errors.append("run-context.json.artifacts: contains unsupported fields")
    for field in ("trace", "report"):
        value = artifacts.get(field)
        if (
            field in artifacts
            and value is not None
            and not _valid_relative_path(value)
        ):
            errors.append(
                f"run-context.json.artifacts.{field}: must be null or a "
                "normalized relative path"
            )
    return artifacts


def _load_context(
    root: Path,
    errors: list[str],
    *,
    expected_metadata: Any = None,
) -> tuple[Any, bool]:
    path = root / "run-context.json"
    if expected_metadata is not None:
        safe = stat.S_ISREG(expected_metadata.st_mode)
    else:
        safe = _evidence_is_file(path) and not _evidence_is_symlink(path)
    if not safe:
        errors.append("run-context.json: context is missing or unsafe")
        return None, False
    try:
        context, _byte_count = _read_json_bounded(
            path, expected_metadata=expected_metadata
        )
        _validate_context_identity(context)
    except ValueError as exc:
        errors.append(f"run-context.json: {exc}")
        return None, False
    return context, True


def _load_index(root: Path, errors: list[str]) -> Any:
    path = root.parent.parent / "attempt-index.json"
    if not _evidence_is_file(path) or _evidence_is_symlink(path):
        errors.append("attempt-index.json: publication index is missing or unsafe")
        return None
    try:
        index, _byte_count = _read_json_bounded(path)
    except ValueError as exc:
        errors.append(f"attempt-index.json: {exc}")
        return None
    try:
        _validate_index(index)
    except ValueError as exc:
        errors.append(f"attempt-index.json: {exc}")
    return index


def _registrations_for_run(index: Any, run_id: str) -> list[tuple[dict, dict]]:
    matches = []
    if not isinstance(index, dict) or not isinstance(index.get("executions"), list):
        return matches
    for execution in index["executions"]:
        if not isinstance(execution, dict) or not isinstance(
            execution.get("attempts"), list
        ):
            continue
        for entry in execution["attempts"]:
            if isinstance(entry, dict) and entry.get("runId") == run_id:
                matches.append((execution, entry))
    return matches


def _validate_bundle_consistency(
    root: Path,
    summary: Any,
    errors: list[str],
    *,
    snapshot: _BundleSnapshot | None = None,
    index: Any = _UNSCANNED_INDEX,
) -> None:
    """Reconcile the attempt root, context, summary, and publication index."""

    root = Path(root).absolute()
    run_id = root.name
    publication_root = root.parent.parent
    if root != publication_root / "attempts" / run_id:
        errors.append("$: attempt root must equal publication/attempts/<runId>")
    context_metadata = (
        snapshot.metadata("run-context.json") if snapshot is not None else None
    )
    context, context_valid = _load_context(
        root, errors, expected_metadata=context_metadata
    )
    if index is _UNSCANNED_INDEX:
        index = _load_index(root, errors)
    else:
        try:
            _validate_index(index)
        except ValueError as exc:
            errors.append(f"attempt-index.json: {exc}")

    if isinstance(summary, dict) and summary.get("runId") != run_id:
        errors.append("run-summary.json.runId: must match attempt root name")
    if context_valid and context.get("runId") != run_id:
        errors.append("run-context.json.runId: must match attempt root name")

    if isinstance(summary, dict) and context_valid:
        for field in _SUMMARY_CONTEXT_FIELDS:
            if summary.get(field) != context.get(field):
                errors.append(
                    f"run-summary.json.{field}: disagrees with run-context.json"
                )
        expected_first = context.get("attempt") == 1
        if summary.get("firstAttempt") != expected_first:
            errors.append(
                "run-summary.json.firstAttempt: disagrees with run-context.json"
            )
        configured_artifacts = _context_artifacts(context, errors)
        expected_artifacts = {
            "bootstrapEvents": "bootstrap-events.jsonl",
            "commands": "commands",
        }
        for field in ("trace", "report"):
            if field in configured_artifacts:
                expected_artifacts[field] = configured_artifacts[field]
        if summary.get("artifacts") != expected_artifacts:
            errors.append(
                "run-summary.json.artifacts: disagrees with run-context.json"
            )
    registrations = _registrations_for_run(index, run_id)
    if len(registrations) != 1:
        errors.append("attempt-index.json: runId must have exactly one registration")
        return

    execution, entry = registrations[0]
    expected_summary = f"attempts/{run_id}/run-summary.json"
    if entry.get("summary") != expected_summary:
        errors.append("attempt-index.json: summary reference is not normalized")
    if context_valid:
        if execution.get("executionId") != context.get("executionId"):
            errors.append(
                "attempt-index.json: registration executionId disagrees with context"
            )
        if entry.get("attempt") != context.get("attempt"):
            errors.append("attempt-index.json: registration attempt disagrees with context")
        expected_tuple = _comparability_tuple(context)
        if execution.get("comparabilityTuple") != expected_tuple:
            errors.append(
                "attempt-index.json: raw comparability tuple disagrees with context"
            )
    if isinstance(summary, dict):
        if execution.get("executionId") != summary.get("executionId"):
            errors.append(
                "attempt-index.json: registration executionId disagrees with summary"
            )
        if entry.get("attempt") != summary.get("attempt"):
            errors.append("attempt-index.json: registration attempt disagrees with summary")


__all__ = ("_validate_bundle_consistency",)
