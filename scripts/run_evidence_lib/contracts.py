"""Manual evidence contracts and validation primitives."""

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

def _nested(value: Any, *parts: str) -> Any:
    current = value
    for part in parts:
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def _present(value: Any) -> bool:
    return value is not None and (not isinstance(value, str) or bool(value))


def _comparability_tuple(context: Any) -> dict:
    """Derive the private canonical tuple used by persisted evidence indexes."""

    source = context if isinstance(context, dict) else {}
    host_source = source.get("host") if isinstance(source.get("host"), dict) else {}
    raw_toolchain = source.get("toolchain")
    comparable = {
        "candidateRevision": source.get("candidateRevision"),
        "fixtureId": source.get("fixtureId"),
        "fixtureVersion": source.get("fixtureVersion"),
        "scenarioDigest": source.get("scenarioDigest"),
        "appBuildDigest": source.get("appBuildDigest"),
        "platform": source.get("platform"),
        "deviceClass": source.get("deviceClass"),
        "runtimeVersion": source.get("runtimeVersion"),
        "host": {
            "os": host_source.get("os"),
            "arch": host_source.get("arch"),
            "class": host_source.get("class"),
        },
        "runnerVersion": source.get("runnerVersion"),
        "protocolVersion": source.get("protocolVersion"),
        "timingMode": source.get("timingMode"),
        "toolchain": {},
    }

    if isinstance(raw_toolchain, dict) and all(
        isinstance(name, str) for name in raw_toolchain
    ):
        comparable["toolchain"] = {
            name: raw_toolchain[name] for name in sorted(raw_toolchain)
        }
    return comparable


def comparability(context: dict) -> dict:
    """Derive the public canonical comparability claims."""

    source = context if isinstance(context, dict) else {}
    raw_toolchain = source.get("toolchain")
    comparable = _comparability_tuple(source)
    reasons = []

    for field in COMPARABILITY_FIELDS:
        if field == "toolchain":
            continue
        value = _nested(source, *field.split("."))
        if not _present(value):
            reasons.append("$." + field)

    if not isinstance(raw_toolchain, dict) or not raw_toolchain:
        reasons.append("$.toolchain")
    elif not all(isinstance(name, str) for name in raw_toolchain):
        reasons.append("$.toolchain")
    else:
        for name, version in comparable["toolchain"].items():
            if not _present(version):
                reasons.append("$.toolchain." + name)

    reasons = sorted(set(reasons))
    if reasons:
        key = None
    else:
        encoded = json.dumps(
            comparable,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        key = "sha256:" + hashlib.sha256(encoded).hexdigest()

    return {
        "comparabilityKey": key,
        "certificationEligible": not reasons,
        "ineligibilityReasons": reasons,
    }


def recompute_comparability(summary: dict) -> dict:
    """Recompute comparison claims exclusively from their source fields."""

    return comparability(summary)


def classify(error_codes: list[str]) -> tuple[str, str]:
    """Return the highest-precedence classification and owning error code."""

    codes = error_codes if isinstance(error_codes, list) else []
    if not codes or any(code not in ERROR_CLASSIFICATION for code in codes):
        return "runner_failure", "runner.unclassified"
    for classification in _CLASSIFICATION_PRECEDENCE:
        for code in codes:
            if ERROR_CLASSIFICATION[code] == classification:
                return classification, code
    return "runner_failure", "runner.unclassified"


def _error(errors: list[str], path: str, message: str) -> None:
    errors.append(f"{path}: {message}")


def _finish_errors(errors: list[str]) -> list[str]:
    return sorted(set(errors))


def _is_integer(value: Any) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if isinstance(value, float):
        return math.isfinite(value) and value.is_integer()
    return True


def _valid_datetime(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    parts = re.split(r"t|\s", value, flags=re.IGNORECASE)
    if len(parts) != 2:
        return False
    date_match = _AJV_DATE_RE.fullmatch(parts[0])
    time_match = _AJV_TIME_RE.fullmatch(parts[1])
    if date_match is None or time_match is None:
        return False

    year, month, day = (int(part) for part in date_match.groups())
    leap_year = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    days = (0, 31, 29 if leap_year else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    if month < 1 or month > 12 or day < 1 or day > days[month]:
        return False

    hour = int(time_match.group(1))
    minute = int(time_match.group(2))
    second = float(time_match.group(3))
    timezone_sign = -1 if time_match.group(5) == "-" else 1
    timezone_hour = int(time_match.group(6) or 0)
    timezone_minute = int(time_match.group(7) or 0)
    if timezone_hour > 23 or timezone_minute > 59:
        return False
    if hour <= 23 and minute <= 59 and second < 60:
        return True
    utc_minute = minute - timezone_minute * timezone_sign
    utc_hour = hour - timezone_hour * timezone_sign - (1 if utc_minute < 0 else 0)
    return (
        utc_hour in (23, -1)
        and utc_minute in (59, -1)
        and second < 61
    )


def _valid_relative_path(value: Any) -> bool:
    if not isinstance(value, str) or not value:
        return False
    if "\\" in value or value.startswith("/") or _SCHEME_RE.match(value):
        return False
    if value.startswith("./") or value.endswith("/") or "//" in value:
        return False
    return all(part not in ("", ".", "..") for part in value.split("/"))


def _require_nonempty_string(value: Any, path: str, errors: list[str]) -> None:
    if not isinstance(value, str) or not value:
        _error(errors, path, "must be a non-empty string")


def _validate_nullable_string(value: Any, path: str, errors: list[str]) -> None:
    if value is not None and (not isinstance(value, str) or not value):
        _error(errors, path, "must be null or a non-empty string")


def _validate_closed_object(
    value: Any,
    path: str,
    required: set[str],
    allowed: set[str],
    errors: list[str],
) -> dict | None:
    if not isinstance(value, dict):
        _error(errors, path, "must be an object")
        return None
    for field in sorted(required - value.keys()):
        _error(errors, f"{path}.{field}", "is required")
    for field in sorted(value.keys() - allowed):
        _error(errors, f"{path}.{field}", "is not allowed")
    return value


def validate_event(event: dict) -> list[str]:
    """Validate one bootstrap event without third-party schema libraries."""

    errors: list[str] = []
    if not isinstance(event, dict):
        return ["$: must be an object"]
    required = {"schemaVersion", "seq", "timestamp", "phase", "status"}
    allowed = required | {
        "errorCode",
        "summary",
        "command",
        "commandStatus",
        "artifact",
    }
    for field in sorted(required - event.keys()):
        _error(errors, "$." + field, "is required")
    for field in sorted(event.keys() - allowed):
        _error(errors, "$." + str(field), "is not allowed")

    if not _is_integer(event.get("schemaVersion")) or event["schemaVersion"] != 1:
        _error(errors, "$.schemaVersion", "must equal 1")
    seq = event.get("seq")
    if not _is_integer(seq) or seq < 1:
        _error(errors, "$.seq", "must be an integer greater than or equal to 1")
    if not _valid_datetime(event.get("timestamp")):
        _error(errors, "$.timestamp", "must be an RFC3339 date-time")
    if event.get("phase") not in PHASES:
        _error(errors, "$.phase", "must be a declared phase")
    if event.get("status") not in _EVENT_STATUSES:
        _error(errors, "$.status", "must be a declared event status")
    for field in ("errorCode", "summary", "command"):
        if field in event and event[field] is not None and not isinstance(event[field], str):
            _error(errors, "$." + field, "must be null or a string")
    if "commandStatus" in event:
        value = event["commandStatus"]
        if value is not None and not _is_integer(value):
            _error(errors, "$.commandStatus", "must be null or an integer")
    if "artifact" in event:
        value = event["artifact"]
        if value is not None and not _valid_relative_path(value):
            _error(errors, "$.artifact", "must be null or a normalized relative path")
    return _finish_errors(errors)


def validate_summary(summary: dict) -> list[str]:
    """Validate one terminal summary against the committed schema contract."""

    errors: list[str] = []
    if not isinstance(summary, dict):
        return ["$: must be an object"]

    required = {
        "schemaVersion",
        "runId",
        "executionId",
        "fixtureId",
        "fixtureVersion",
        "candidateRevision",
        "scenarioDigest",
        "appBuildDigest",
        "comparabilityKey",
        "certificationEligible",
        "ineligibilityReasons",
        "status",
        "classification",
        "phase",
        "startedAt",
        "finishedAt",
        "durationMs",
        "attempt",
        "firstAttempt",
        "platform",
        "deviceClass",
        "runtimeVersion",
        "timingMode",
        "runnerVersion",
        "protocolVersion",
        "commandStatus",
        "host",
        "device",
        "toolchain",
        "artifacts",
    }
    for field in sorted(required - summary.keys()):
        _error(errors, "$." + field, "is required")

    if not _is_integer(summary.get("schemaVersion")) or summary["schemaVersion"] != 1:
        _error(errors, "$.schemaVersion", "must equal 1")
    for field in ("runId", "executionId", "fixtureId", "fixtureVersion"):
        _require_nonempty_string(summary.get(field), "$." + field, errors)
    run_id = summary.get("runId")
    if isinstance(run_id, str) and run_id and not _safe_run_segment(run_id):
        _error(errors, "$.runId", "must be a safe bounded path segment")

    revision = summary.get("candidateRevision")
    if revision is not None and (
        not isinstance(revision, str) or not _REVISION_RE.fullmatch(revision)
    ):
        _error(errors, "$.candidateRevision", "must be null or a 40-character lowercase revision")
    for field in ("scenarioDigest", "appBuildDigest"):
        value = summary.get(field)
        if value is not None and (
            not isinstance(value, str) or not _DIGEST_RE.fullmatch(value)
        ):
            _error(errors, "$." + field, "must be null or a lowercase sha256 digest")

    key = summary.get("comparabilityKey")
    if key is not None and (not isinstance(key, str) or not _DIGEST_RE.fullmatch(key)):
        _error(errors, "$.comparabilityKey", "must be null or a lowercase sha256 digest")
    if "finalizeRequestFingerprint" in summary:
        fingerprint = summary["finalizeRequestFingerprint"]
        if (
            not isinstance(fingerprint, str)
            or not _DIGEST_RE.fullmatch(fingerprint)
        ):
            _error(
                errors,
                "$.finalizeRequestFingerprint",
                "must be a lowercase sha256 digest",
            )
    if not isinstance(summary.get("certificationEligible"), bool):
        _error(errors, "$.certificationEligible", "must be a boolean")
    reasons = summary.get("ineligibilityReasons")
    if not isinstance(reasons, list):
        _error(errors, "$.ineligibilityReasons", "must be an array")
    else:
        seen = set()
        for index, reason in enumerate(reasons):
            if not isinstance(reason, str) or not reason or not _REASON_RE.fullmatch(reason):
                _error(
                    errors,
                    f"$.ineligibilityReasons.{index}",
                    "must be a deterministic JSON path",
                )
            elif reason in seen:
                _error(errors, "$.ineligibilityReasons", "must contain unique paths")
            seen.add(reason)

    status = summary.get("status")
    if status not in _TERMINAL_STATUSES:
        _error(errors, "$.status", "must be passed, failed, or cancelled")
    classification = summary.get("classification")
    if classification not in _TERMINAL_CLASSIFICATIONS:
        _error(errors, "$.classification", "must be a declared classification")
    phase = summary.get("phase")
    if phase not in PHASES:
        _error(errors, "$.phase", "must be a declared phase")
    for field in ("startedAt", "finishedAt"):
        if not _valid_datetime(summary.get(field)):
            _error(errors, "$." + field, "must be an RFC3339 date-time")
    duration = summary.get("durationMs")
    if not _is_integer(duration) or duration < 0:
        _error(errors, "$.durationMs", "must be a non-negative integer")
    attempt = summary.get("attempt")
    if not _is_integer(attempt) or attempt < 1:
        _error(errors, "$.attempt", "must be an integer greater than or equal to 1")
    first_attempt = summary.get("firstAttempt")
    if not isinstance(first_attempt, bool):
        _error(errors, "$.firstAttempt", "must be a boolean")
    elif _is_integer(attempt) and attempt >= 1 and first_attempt != (attempt == 1):
        _error(errors, "$.firstAttempt", "must exactly reflect whether attempt is 1")
    if summary.get("platform") not in ("android", "ios"):
        _error(errors, "$.platform", "must be android or ios")
    for field in ("deviceClass", "runtimeVersion"):
        _validate_nullable_string(summary.get(field), "$." + field, errors)
    if summary.get("timingMode") not in ("cold-command", "warm-session"):
        _error(errors, "$.timingMode", "must be cold-command or warm-session")
    for field in ("runnerVersion", "protocolVersion"):
        _require_nonempty_string(summary.get(field), "$." + field, errors)
    command_status = summary.get("commandStatus")
    if command_status is not None and not _is_integer(command_status):
        _error(errors, "$.commandStatus", "must be null or an integer")

    host = _validate_closed_object(
        summary.get("host"),
        "$.host",
        {"os", "arch", "class", "ci"},
        {"os", "arch", "class", "ci"},
        errors,
    )
    if host is not None:
        for field in ("os", "arch", "class"):
            _validate_nullable_string(host.get(field), "$.host." + field, errors)
        if host.get("ci") is not None and not isinstance(host.get("ci"), bool):
            _error(errors, "$.host.ci", "must be null or a boolean")

    device = _validate_closed_object(
        summary.get("device"),
        "$.device",
        {"requested", "resolved"},
        {"requested", "resolved"},
        errors,
    )
    if device is not None:
        for field in ("requested", "resolved"):
            _validate_nullable_string(device.get(field), "$.device." + field, errors)

    toolchain = summary.get("toolchain")
    if not isinstance(toolchain, dict) or not toolchain:
        _error(errors, "$.toolchain", "must be a non-empty object")
    else:
        for name, version in toolchain.items():
            if not isinstance(name, str) or not _TOOL_NAME_RE.fullmatch(name):
                _error(errors, "$.toolchain", "contains an invalid tool name")
                continue
            _validate_nullable_string(version, "$.toolchain." + name, errors)

    artifacts = _validate_closed_object(
        summary.get("artifacts"),
        "$.artifacts",
        {"bootstrapEvents", "commands"},
        {"bootstrapEvents", "commands", "trace", "report"},
        errors,
    )
    if artifacts is not None:
        for field in ("bootstrapEvents", "commands"):
            if not _valid_relative_path(artifacts.get(field)):
                _error(errors, "$.artifacts." + field, "must be a normalized relative path")
        for field in ("trace", "report"):
            if field in artifacts:
                value = artifacts[field]
                if value is not None and not _valid_relative_path(value):
                    _error(
                        errors,
                        "$.artifacts." + field,
                        "must be null or a normalized relative path",
                    )

    if status == "passed":
        if classification != "passed":
            _error(errors, "$.classification", "must equal passed for a passed run")
        if phase != "complete":
            _error(errors, "$.phase", "must equal complete for a passed run")
        for field in ("errorCode", "summary", "hint"):
            if field in summary:
                _error(errors, "$." + field, "must be omitted for a passed run")
    elif status == "failed":
        if classification not in _FAILURE_CLASSIFICATIONS:
            _error(errors, "$.classification", "must be a failure classification")
        for field in ("errorCode", "summary", "hint"):
            _require_nonempty_string(summary.get(field), "$." + field, errors)
        error_code = summary.get("errorCode")
        expected_classification = ERROR_CLASSIFICATION.get(error_code)
        if expected_classification not in _FAILURE_CLASSIFICATIONS:
            _error(errors, "$.errorCode", "must be a known failure error code")
        elif classification != expected_classification:
            _error(errors, "$.errorCode", "does not own the declared classification")
            _error(
                errors,
                "$.classification",
                "does not match the declared error code",
            )
    elif status == "cancelled":
        if classification != "cancelled":
            _error(errors, "$.classification", "must equal cancelled")
        if summary.get("errorCode") != "run.cancelled":
            _error(errors, "$.errorCode", "must equal run.cancelled")
        for field in ("summary", "hint"):
            _require_nonempty_string(summary.get(field), "$." + field, errors)

    computed = recompute_comparability(summary)
    for field in ("comparabilityKey", "certificationEligible", "ineligibilityReasons"):
        if summary.get(field) != computed[field]:
            _error(errors, "$." + field, "does not match recomputed comparability")

    return _finish_errors(errors)

def _safe_run_segment(value: Any) -> bool:
    if (
        not isinstance(value, str)
        or not value
        or value in (".", "..")
        or "/" in value
        or "\\" in value
        or _SCHEME_RE.match(value)
        or any(
            ord(character) < 0x20
            or ord(character) == 0x7F
            or 0xD800 <= ord(character) <= 0xDFFF
            for character in value
        )
    ):
        return False
    try:
        encoded = str.encode(value, "utf-8")
    except UnicodeEncodeError:
        return False
    return len(encoded) <= MAX_RUN_SEGMENT_BYTES


def _validate_context_identity(context: Any) -> None:
    if not isinstance(context, dict):
        raise ValueError("context must be an object")
    for field in ("runId", "executionId", "fixtureId", "fixtureVersion"):
        if not isinstance(context.get(field), str) or not context[field]:
            raise ValueError(f"$.{field}: must be a non-empty string")
    if not _safe_run_segment(context["runId"]):
        raise ValueError("$.runId: must be a safe path segment")
    attempt = context.get("attempt")
    if not _is_integer(attempt) or attempt < 1:
        raise ValueError("$.attempt: must be an integer greater than or equal to 1")
    if context.get("platform") not in ("android", "ios"):
        raise ValueError("$.platform: must be android or ios")
    if context.get("timingMode") not in ("cold-command", "warm-session"):
        raise ValueError("$.timingMode: must be cold-command or warm-session")
    for field in ("runnerVersion", "protocolVersion"):
        if not isinstance(context.get(field), str) or not context[field]:
            raise ValueError(f"$.{field}: must be a non-empty string")
    revision = context.get("candidateRevision")
    if revision is not None and (
        not isinstance(revision, str) or not _REVISION_RE.fullmatch(revision)
    ):
        raise ValueError("$.candidateRevision: malformed revision")
    for field in ("scenarioDigest", "appBuildDigest"):
        value = context.get(field)
        if value is not None and (
            not isinstance(value, str) or not _DIGEST_RE.fullmatch(value)
        ):
            raise ValueError(f"$.{field}: malformed digest")
    if not isinstance(context.get("host"), dict):
        raise ValueError("$.host: must be an object")
    if not isinstance(context.get("device"), dict):
        raise ValueError("$.device: must be an object")
    toolchain = context.get("toolchain")
    if not isinstance(toolchain, dict) or not toolchain:
        raise ValueError("$.toolchain: must be a non-empty object")
    for name, version in toolchain.items():
        if not isinstance(name, str) or not _TOOL_NAME_RE.fullmatch(name):
            raise ValueError("$.toolchain: contains an invalid tool name")
        if version is not None and (not isinstance(version, str) or not version):
            raise ValueError(f"$.toolchain.{name}: invalid version")


def _expected_attempt_root(index_path: Path, run_id: str) -> Path:
    return Path(index_path).parent / "attempts" / run_id


def _validate_attempt_root(index_path: Path, attempt_root: Path, run_id: str) -> None:
    index_path = Path(index_path).absolute()
    attempt_root = Path(attempt_root).absolute()
    expected = _expected_attempt_root(index_path, run_id).absolute()
    if attempt_root != expected:
        raise ValueError("attempt root must be attempts/<runId> under the index root")


def _validate_index(index: Any) -> None:
    if not isinstance(index, dict) or index.get("schemaVersion") != "1.0":
        raise ValueError("attempt index must have schemaVersion 1.0")
    executions = index.get("executions")
    if not isinstance(executions, list):
        raise ValueError("attempt index executions must be an array")
    execution_ids = set()
    global_run_ids = set()
    for execution in executions:
        if not isinstance(execution, dict):
            raise ValueError("attempt index execution must be an object")
        execution_id = execution.get("executionId")
        if not isinstance(execution_id, str) or not execution_id:
            raise ValueError("attempt index executionId must be non-empty")
        if execution_id in execution_ids:
            raise ValueError("attempt index executionId must be unique")
        execution_ids.add(execution_id)
        if not isinstance(execution.get("comparabilityTuple"), dict):
            raise ValueError("attempt index comparabilityTuple must be an object")
        attempts = execution.get("attempts")
        if not isinstance(attempts, list) or not attempts:
            raise ValueError("attempt index execution must contain attempts")
        for expected_attempt, attempt_entry in enumerate(attempts, 1):
            if not isinstance(attempt_entry, dict):
                raise ValueError("attempt index attempt must be an object")
            run_id = attempt_entry.get("runId")
            if not _safe_run_segment(run_id):
                raise ValueError("attempt index runId must be a safe path segment")
            if run_id in global_run_ids:
                raise ValueError("attempt index runId must be globally unique")
            global_run_ids.add(run_id)
            if attempt_entry.get("attempt") != expected_attempt:
                raise ValueError("attempt numbers must start at 1 and be contiguous")
            expected_summary = f"attempts/{run_id}/run-summary.json"
            if attempt_entry.get("summary") != expected_summary:
                raise ValueError("attempt summary reference is not normalized")

__all__ = (
    "_nested",
    "_present",
    "comparability",
    "recompute_comparability",
    "classify",
    "_error",
    "_finish_errors",
    "_is_integer",
    "_valid_datetime",
    "_valid_relative_path",
    "_require_nonempty_string",
    "_validate_nullable_string",
    "_validate_closed_object",
    "validate_event",
    "validate_summary",
    "_safe_run_segment",
    "_validate_context_identity",
    "_expected_attempt_root",
    "_validate_attempt_root",
    "_validate_index",
)
