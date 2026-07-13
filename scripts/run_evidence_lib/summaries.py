"""Terminal summary construction and finalization."""

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
from .sanitization import _utf8_byte_length
from .safe_io import *  # noqa: F401,F403
from .journal import *  # noqa: F401,F403
from .receipts import (
    _finalize_receipt_relative,
    _legacy_finalize_receipt_request_fingerprint,
    _make_finalize_receipt,
)
from .lifecycle import *  # noqa: F401,F403

_MAX_INVALID_SUMMARY_DIAGNOSTICS = 256
_MAX_INVALID_SUMMARY_DIAGNOSTIC_BYTES = 4096
_DIAGNOSTIC_TRUNCATION_SUFFIX = "... <truncated>"


def _bound_validation_diagnostic(value: Any) -> str:
    text = value if isinstance(value, str) else str(value)
    byte_length = _utf8_byte_length(text)
    if byte_length is None:
        return "$: validation returned a non-Unicode scalar diagnostic"
    if not text:
        return "$: validation returned an empty diagnostic"
    if byte_length <= _MAX_INVALID_SUMMARY_DIAGNOSTIC_BYTES:
        return text
    suffix = _DIAGNOSTIC_TRUNCATION_SUFFIX.encode("utf-8")
    prefix_limit = _MAX_INVALID_SUMMARY_DIAGNOSTIC_BYTES - len(suffix)
    prefix = text.encode("utf-8")[:prefix_limit].decode("utf-8", errors="ignore")
    return prefix + _DIAGNOSTIC_TRUNCATION_SUFFIX


def _sanitize_validation_errors(
    errors: list[Any], *, roots: dict[str, str], secrets: list[str]
) -> list[str]:
    sanitized = sorted(
        {
            _bound_validation_diagnostic(
                sanitize_text(error, roots=roots, secrets=secrets)
            )
            for error in errors
        }
    )
    if len(sanitized) <= _MAX_INVALID_SUMMARY_DIAGNOSTICS:
        return sanitized
    overflow = (
        "$: validation diagnostics exceed maximum "
        f"({_MAX_INVALID_SUMMARY_DIAGNOSTICS})"
    )
    return sorted(
        set(sanitized[: _MAX_INVALID_SUMMARY_DIAGNOSTICS - 1] + [overflow])
    )


def _duration_ms(started_at: Any, finished_at: str) -> int:
    if not _valid_datetime(started_at):
        return 0
    started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
    finished = datetime.fromisoformat(finished_at.replace("Z", "+00:00"))
    return max(0, int((finished - started).total_seconds() * 1000))


def _summary_artifacts(context: dict) -> dict:
    configured = context.get("artifacts")
    configured = configured if isinstance(configured, dict) else {}
    artifacts = {
        "bootstrapEvents": "bootstrap-events.jsonl",
        "commands": "commands",
    }
    for field in ("trace", "report"):
        if field in configured:
            artifacts[field] = configured[field]
    return artifacts


def _build_summary(
    context: dict,
    status: str,
    *,
    classification: str | None,
    phase: str | None,
    error_code: str | None,
    summary_text: str | None,
    hint: str | None,
    command_status: int | None,
    finished_at: str,
    finalize_request_fingerprint: str | None = None,
) -> dict:
    started_at = context.get("startedAt")
    computed = comparability(context)
    summary = {
        "schemaVersion": 1,
        "runId": context.get("runId"),
        "executionId": context.get("executionId"),
        "fixtureId": context.get("fixtureId"),
        "fixtureVersion": context.get("fixtureVersion"),
        "candidateRevision": context.get("candidateRevision"),
        "scenarioDigest": context.get("scenarioDigest"),
        "appBuildDigest": context.get("appBuildDigest"),
        "comparabilityKey": computed["comparabilityKey"],
        "certificationEligible": computed["certificationEligible"],
        "ineligibilityReasons": computed["ineligibilityReasons"],
        "status": status,
        "classification": classification,
        "phase": phase,
        "startedAt": started_at,
        "finishedAt": finished_at,
        "durationMs": _duration_ms(started_at, finished_at),
        "attempt": context.get("attempt"),
        "firstAttempt": context.get("attempt") == 1,
        "platform": context.get("platform"),
        "deviceClass": context.get("deviceClass"),
        "runtimeVersion": context.get("runtimeVersion"),
        "timingMode": context.get("timingMode"),
        "runnerVersion": context.get("runnerVersion"),
        "protocolVersion": context.get("protocolVersion"),
        "commandStatus": command_status,
        "host": context.get("host"),
        "device": context.get("device"),
        "toolchain": context.get("toolchain"),
        "artifacts": _summary_artifacts(context),
    }
    if finalize_request_fingerprint is not None:
        summary["finalizeRequestFingerprint"] = finalize_request_fingerprint
    if status != "passed":
        summary.update(
            errorCode=error_code,
            summary=summary_text,
            hint=hint,
        )
    return summary


def _valid_or_default_string(value: Any, default: str) -> str:
    return value if isinstance(value, str) and value else default


def _valid_nullable_string(value: Any) -> str | None:
    return value if value is None or isinstance(value, str) and value else None


def _fallback_summary(
    root: Path,
    context: dict,
    finished_at: str,
    command_status: int | None,
    *,
    finalize_request_fingerprint: str | None = None,
) -> dict:
    run_id = _valid_or_default_string(context.get("runId"), root.name or "unknown-run")
    if not _safe_run_segment(run_id):
        run_id = "unknown-run"
    started_at = context.get("startedAt")
    if not _valid_datetime(started_at):
        started_at = finished_at
    host_source = context.get("host")
    host_source = host_source if isinstance(host_source, dict) else {}
    ci = host_source.get("ci")
    if ci is not None and not isinstance(ci, bool):
        ci = None
    device_source = context.get("device")
    device_source = device_source if isinstance(device_source, dict) else {}
    raw_toolchain = context.get("toolchain")
    toolchain = {}
    if isinstance(raw_toolchain, dict):
        for name, version in raw_toolchain.items():
            if (
                isinstance(name, str)
                and _TOOL_NAME_RE.fullmatch(name)
                and (version is None or isinstance(version, str) and version)
            ):
                toolchain[name] = version
    if not toolchain:
        toolchain = {"unknown": None}
    attempt = context.get("attempt")
    if not _is_integer(attempt) or attempt < 1:
        attempt = 1
    safe_context = {
        "runId": run_id,
        "executionId": _valid_or_default_string(context.get("executionId"), run_id),
        "fixtureId": _valid_or_default_string(context.get("fixtureId"), "unknown"),
        "fixtureVersion": _valid_or_default_string(
            context.get("fixtureVersion"), "unknown"
        ),
        "candidateRevision": (
            context.get("candidateRevision")
            if isinstance(context.get("candidateRevision"), str)
            and _REVISION_RE.fullmatch(context["candidateRevision"])
            else None
        ),
        "scenarioDigest": (
            context.get("scenarioDigest")
            if isinstance(context.get("scenarioDigest"), str)
            and _DIGEST_RE.fullmatch(context["scenarioDigest"])
            else None
        ),
        "appBuildDigest": (
            context.get("appBuildDigest")
            if isinstance(context.get("appBuildDigest"), str)
            and _DIGEST_RE.fullmatch(context["appBuildDigest"])
            else None
        ),
        "platform": (
            context.get("platform")
            if context.get("platform") in ("android", "ios")
            else "ios"
        ),
        "deviceClass": _valid_nullable_string(context.get("deviceClass")),
        "runtimeVersion": _valid_nullable_string(context.get("runtimeVersion")),
        "timingMode": (
            context.get("timingMode")
            if context.get("timingMode") in ("cold-command", "warm-session")
            else "cold-command"
        ),
        "runnerVersion": _valid_or_default_string(
            context.get("runnerVersion"), "unknown"
        ),
        "protocolVersion": _valid_or_default_string(
            context.get("protocolVersion"), "unknown"
        ),
        "attempt": attempt,
        "startedAt": started_at,
        "host": {
            "os": _valid_nullable_string(host_source.get("os")),
            "arch": _valid_nullable_string(host_source.get("arch")),
            "class": _valid_nullable_string(host_source.get("class")),
            "ci": ci,
        },
        "device": {
            "requested": _valid_nullable_string(device_source.get("requested")),
            "resolved": _valid_nullable_string(device_source.get("resolved")),
        },
        "toolchain": toolchain,
        "artifacts": {},
    }
    configured_artifacts = context.get("artifacts")
    if isinstance(configured_artifacts, dict):
        for field in ("trace", "report"):
            value = configured_artifacts.get(field)
            safe_context["artifacts"][field] = (
                value if value is None or _valid_relative_path(value) else None
            )
    fallback = _build_summary(
        safe_context,
        "failed",
        classification="runner_failure",
        phase="evidence.finalize",
        error_code="runner.evidence_invalid",
        summary_text="Run evidence validation failed",
        hint="Inspect the sanitized invalid-summary diagnostics",
        command_status=command_status if _is_integer(command_status) else None,
        finished_at=finished_at,
        finalize_request_fingerprint=finalize_request_fingerprint,
    )
    errors = validate_summary(fallback)
    if errors:
        raise RuntimeError("internal fallback summary is invalid: " + "; ".join(errors))
    return fallback


@_rooted_attempt_mutation
def _finalize_attempt(
    root: Path,
    status: str,
    *,
    classification: str | None = None,
    phase: str | None = None,
    error_code: str | None = None,
    summary_text: str | None = None,
    hint: str | None = None,
    command_status: int | None = None,
    artifact_patch: dict[str, str] | None = None,
    _recovered_transactions: list[dict] | None = None,
) -> dict:
    root = Path(root).absolute()
    publication_root = _publication_root_for_attempt(root)
    attempt_relative = _attempt_root_relative(publication_root, root)
    index_path = publication_root / "attempt-index.json"
    with _exclusive_lock(publication_root / ".transactions.lock"):
        recovered = list(_recovered_transactions or [])
        recovered.extend(
            _recover_pending_transactions_unlocked(publication_root)
        )
        if status not in _TERMINAL_STATUSES:
            raise ValueError("terminal status must be passed, failed, or cancelled")
        if not _evidence_is_file(index_path):
            raise ValueError("attempt index is missing")
        with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
            with _exclusive_lock(root / ".lifecycle.lock"):
                with _exclusive_lock(root / ".events.lock"):
                    summary_path = root / "run-summary.json"
                    context = _read_json(root / "run-context.json")
                    roots = _sanitization_roots(root)
                    secrets = _collect_secret_values()
                    context = _sanitize_value(
                        context,
                        roots=roots,
                        secrets=secrets,
                    )
                    sanitized_artifact_patch = None
                    if artifact_patch is not None:
                        patch = _sanitize_value(
                            {"artifacts": artifact_patch},
                            roots=roots,
                            secrets=secrets,
                        )
                        _validate_context_patch(patch)
                        sanitized_artifact_patch = patch["artifacts"]
                        context = _deep_merge(context, patch)
                        _validate_context_identity(context)
                    index = _load_index(index_path)
                    execution = _execution_for_run(index, context.get("runId"))
                    current_tuple = _comparability_tuple(context)
                    registered_tuple = execution["comparabilityTuple"]
                    tuple_mismatch = registered_tuple != current_tuple

                    if status == "passed":
                        if classification is not None and classification != "passed":
                            raise ValueError(
                                "passed status requires passed classification"
                            )
                        classification = "passed"
                        phase = "complete" if phase is None else phase
                        error_code = summary_text = hint = None
                    elif status == "cancelled":
                        if classification is not None and classification != "cancelled":
                            raise ValueError(
                                "cancelled status requires cancelled classification"
                            )
                        phase = "cleanup" if phase is None else phase
                        if error_code is not None and error_code != "run.cancelled":
                            raise ValueError(
                                "cancelled status requires run.cancelled"
                            )
                        classification = "cancelled"
                        error_code = "run.cancelled"
                        summary_text = summary_text or "Run cancelled"
                        hint = hint or "Retry when ready"
                    else:
                        error_code = error_code or "runner.unclassified"
                        inferred, primary_code = classify([error_code])
                        if classification is not None and classification != inferred:
                            raise ValueError(
                                "classification disagrees with the owning error code"
                            )
                        classification = inferred
                        error_code = primary_code
                        phase = phase or "invocation"
                        summary_text = summary_text or "Run failed"
                        hint = hint or "Inspect bootstrap events and command logs"

                    error_code = (
                        sanitize_text(error_code, roots=roots, secrets=secrets)
                        if error_code is not None
                        else None
                    )
                    summary_text = (
                        sanitize_text(summary_text, roots=roots, secrets=secrets)
                        if summary_text is not None
                        else None
                    )
                    hint = (
                        sanitize_text(hint, roots=roots, secrets=secrets)
                        if hint is not None
                        else None
                    )
                    request = {
                        "context": context,
                        "terminal": {
                            "status": status,
                            "classification": classification,
                            "phase": phase,
                            "errorCode": error_code,
                            "summary": summary_text,
                            "hint": hint,
                            "commandStatus": command_status,
                        },
                    }
                    if sanitized_artifact_patch is not None:
                        request["artifactPatch"] = sanitized_artifact_patch
                    request_fingerprint = _request_fingerprint(
                        publication_root,
                        "finalize",
                        root,
                        request,
                    )
                    legacy_artifact_request_fingerprint = None
                    if sanitized_artifact_patch is not None:
                        legacy_request = dict(request)
                        legacy_request.pop("artifactPatch")
                        legacy_artifact_request_fingerprint = (
                            _request_fingerprint(
                                publication_root,
                                "finalize",
                                root,
                                legacy_request,
                            )
                        )
                    recovery_fingerprint = request_fingerprint
                    matching_recovered = [
                        transaction
                        for transaction in recovered
                        if transaction["operation"] == "finalize"
                        and transaction["attemptRoot"] == attempt_relative
                    ]
                    recovered_legacy_upgrade = bool(
                        len(matching_recovered) == 1
                        and matching_recovered[0].get(
                            "legacyFinalizeUpgrade"
                        )
                    )
                    if recovered_legacy_upgrade:
                        recovery_fingerprint = (
                            _legacy_finalize_receipt_request_fingerprint(
                                request_fingerprint
                            )
                        )
                    context_target_path = (
                        attempt_relative + "/run-context.json"
                    )
                    if (
                        legacy_artifact_request_fingerprint is not None
                        and len(matching_recovered) == 1
                        and all(
                            target["path"] != context_target_path
                            for target in matching_recovered[0]["targets"]
                        )
                    ):
                        # Finalize journals written before artifact patching
                        # became atomic bind only the already-patched context.
                        recovery_fingerprint = (
                            legacy_artifact_request_fingerprint
                        )
                        if recovered_legacy_upgrade:
                            recovery_fingerprint = (
                                _legacy_finalize_receipt_request_fingerprint(
                                    recovery_fingerprint
                                )
                            )
                    recovered_result = _recovered_result(
                        publication_root,
                        recovered,
                        "finalize",
                        attempt_relative,
                        recovery_fingerprint,
                    )
                    if recovered_result is not None:
                        return recovered_result
                    completed_result = _completed_finalize_result(
                        publication_root,
                        attempt_relative,
                        request_fingerprint,
                        compatible_request_fingerprints=tuple(
                            _legacy_finalize_receipt_request_fingerprint(
                                fingerprint
                            )
                            for fingerprint in (
                                request_fingerprint,
                                legacy_artifact_request_fingerprint,
                            )
                            if fingerprint is not None
                        ),
                    )
                    if completed_result is not None:
                        return completed_result
                    if _evidence_exists(summary_path):
                        raise FileExistsError(
                            "terminal run summary already exists"
                        )

                    finished_at = _utc_now()
                    candidate = _build_summary(
                        context,
                        status,
                        classification=classification,
                        phase=phase,
                        error_code=error_code,
                        summary_text=summary_text,
                        hint=hint,
                        command_status=command_status,
                        finished_at=finished_at,
                        finalize_request_fingerprint=request_fingerprint,
                    )
                    validation_errors = validate_summary(candidate)
                    if tuple_mismatch:
                        validation_errors = validation_errors + [
                            "$.comparabilityTuple: context disagrees with the registered execution"
                        ]
                    validation_errors = _sanitize_validation_errors(
                        validation_errors,
                        roots=roots,
                        secrets=secrets,
                    )
                    if validation_errors:
                        terminal = _fallback_summary(
                            root,
                            _context_with_registered_tuple(
                                context, registered_tuple
                            ),
                            finished_at,
                            command_status,
                            finalize_request_fingerprint=request_fingerprint,
                        )
                    else:
                        terminal = candidate

                    summary_bytes = _json_bytes(terminal)
                    if len(summary_bytes) > MAX_STRUCTURED_JSON_BYTES:
                        raise ValueError(
                            "terminal summary exceeds "
                            f"{MAX_STRUCTURED_JSON_BYTES} bytes"
                        )

                    event_metadata = {
                        "commandStatus": terminal.get("commandStatus")
                    }
                    if terminal["status"] != "passed":
                        event_metadata.update(
                            errorCode=terminal["errorCode"],
                            summary=terminal["summary"],
                        )
                    _terminal_event, event_bytes, _events = (
                        _event_stream_candidate(
                            root,
                            terminal["phase"],
                            terminal["status"],
                            _timestamp=terminal["finishedAt"],
                            **event_metadata,
                        )
                    )
                    targets = []
                    if artifact_patch is not None:
                        targets.append(
                            (
                                attempt_relative + "/run-context.json",
                                _json_bytes(context),
                            )
                        )
                    if validation_errors:
                        targets.extend(
                            [
                                (
                                    attempt_relative
                                    + "/run-summary.invalid.json",
                                    _json_bytes(candidate),
                                ),
                                (
                                    attempt_relative
                                    + "/run-summary.invalid.errors.json",
                                    _json_bytes({"errors": validation_errors}),
                                ),
                            ]
                        )
                    targets.append(
                        (
                            attempt_relative + "/bootstrap-events.jsonl",
                            event_bytes,
                        )
                    )
                    targets.append(
                        (attempt_relative + "/run-summary.json", summary_bytes)
                    )
                    targets.append(
                        (
                            _finalize_receipt_relative(attempt_relative),
                            _make_finalize_receipt(
                                attempt_relative,
                                request_fingerprint,
                                summary_bytes,
                            ),
                        )
                    )
                    transaction = _make_transaction(
                        publication_root,
                        "finalize",
                        root,
                        [attempt_relative],
                        targets,
                        request_fingerprint=request_fingerprint,
                    )
                    _commit_transaction_unlocked(
                        publication_root, transaction
                    )
                    return terminal

__all__ = (
    "_duration_ms",
    "_summary_artifacts",
    "_build_summary",
    "_valid_or_default_string",
    "_valid_nullable_string",
    "_fallback_summary",
    "_finalize_attempt",
)
