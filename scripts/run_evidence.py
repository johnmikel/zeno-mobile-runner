#!/usr/bin/env python3
"""Dependency-free creation and validation of ZMR run evidence."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PHASES = (
    "invocation",
    "evidence.init",
    "device.acquire",
    "device.preflight",
    "device.boot",
    "app.build",
    "app.install",
    "shim.build",
    "shim.start",
    "shim.prewarm",
    "scenario.validate",
    "scenario.execute",
    "trace.finalize",
    "report.generate",
    "evidence.finalize",
    "cleanup",
    "complete",
)

COMPARABILITY_FIELDS = (
    "candidateRevision",
    "fixtureId",
    "fixtureVersion",
    "scenarioDigest",
    "appBuildDigest",
    "platform",
    "deviceClass",
    "runtimeVersion",
    "host.os",
    "host.arch",
    "host.class",
    "runnerVersion",
    "protocolVersion",
    "timingMode",
    "toolchain",
)

_ERROR_GROUPS = {
    "runner_failure": (
        "runner.unclassified",
        "runner.child_timeout",
        "runner.cleanup_failed",
        "runner.driver_protocol",
        "runner.ios_shim.build_failed",
        "runner.ios_shim.readiness_timeout",
        "runner.trace_failed",
        "runner.report_failed",
        "runner.evidence_invalid",
    ),
    "configuration_failure": (
        "config.invalid",
        "config.app_artifact_missing",
        "config.device_selection",
        "config.signing",
        "config.unsupported_capability",
        "config.required_tool_missing",
    ),
    "infrastructure_failure": (
        "infra.hosted_runner",
        "infra.device_unavailable",
        "infra.emulator_provision",
        "infra.simulator_provision",
        "infra.disk",
        "infra.network",
    ),
    "app_failure": (
        "app.assertion_failed",
        "app.crashed",
        "app.launch_failed",
    ),
    "cancelled": ("run.cancelled",),
}

ERROR_CLASSIFICATION = {
    code: classification
    for classification, codes in _ERROR_GROUPS.items()
    for code in codes
}

_CLASSIFICATION_PRECEDENCE = (
    "runner_failure",
    "configuration_failure",
    "infrastructure_failure",
    "app_failure",
    "cancelled",
)
_EVENT_STATUSES = ("started", "passed", "failed", "skipped", "cancelled")
_TERMINAL_STATUSES = ("passed", "failed", "cancelled")
_TERMINAL_CLASSIFICATIONS = (
    "passed",
    "runner_failure",
    "app_failure",
    "infrastructure_failure",
    "configuration_failure",
    "cancelled",
)
_FAILURE_CLASSIFICATIONS = (
    "runner_failure",
    "app_failure",
    "infrastructure_failure",
    "configuration_failure",
)
_REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
_TOOL_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_REASON_RE = re.compile(r"^\$\.[A-Za-z0-9_.-]+$")
_AJV_DATE_RE = re.compile(r"^(\d\d\d\d)-(\d\d)-(\d\d)$")
_AJV_TIME_RE = re.compile(
    r"^(\d\d):(\d\d):(\d\d(?:\.\d+)?)(z|([+-])(\d\d)(?::?(\d\d))?)$",
    re.IGNORECASE,
)
_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
_CREDENTIAL_URL_RE = re.compile(
    r"(?P<scheme>[A-Za-z][A-Za-z0-9+.-]{0,31}://)[^/@\s]+@"
)
_FILE_URL_RE = re.compile(r"file:///(?:[^\s\x00\"'<>|,;]+)", re.IGNORECASE)
_POSIX_ABSOLUTE_RE = re.compile(
    r"(?<![A-Za-z0-9_}$/<])/(?!/)(?:[^\s\x00\"'<>|,;]+)"
)
_WINDOWS_ABSOLUTE_RE = re.compile(
    r"(?<![A-Za-z0-9_])(?:[A-Za-z]:[\\/]|\\\\)[^\s\x00\"'<>|,;]+"
)
_SENSITIVE_NAME_SEGMENTS = {
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASS",
    "KEY",
    "AUTH",
    "AUTHORIZATION",
    "CREDENTIAL",
    "CREDENTIALS",
}
_LOG_LIMIT = 10 * 1024 * 1024
_LOG_HALF = 5 * 1024 * 1024
_COMMAND_SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def _collect_secret_values(environment: dict[str, str] | None = None) -> list[str]:
    source = os.environ if environment is None else environment
    custom_names = {
        name.strip()
        for name in source.get("ZMR_EVIDENCE_SECRET_NAMES", "").split(",")
        if name.strip()
    }
    values = set()
    for name, value in source.items():
        if name == "ZMR_EVIDENCE_SECRET_NAMES" or not value:
            continue
        segments = {
            segment.upper()
            for segment in re.split(r"[^A-Za-z0-9]+", name)
            if segment
        }
        if name in custom_names or segments & _SENSITIVE_NAME_SEGMENTS:
            values.add(value)
    return sorted(values, key=lambda value: (-len(value), value))


def _replace_root(value: str, root: str, replacement: str) -> str:
    if not root:
        return value
    candidates = {root.rstrip("/\\")}
    if "\\" in root:
        candidates.add(root.replace("\\", "/").rstrip("/"))
    for candidate in sorted(candidates, key=len, reverse=True):
        if not candidate:
            continue
        pattern = re.compile(
            r"(?<![A-Za-z0-9_.-])"
            + re.escape(candidate)
            + r"(?=$|[/\\\s\x00\"'<>|,;])"
        )
        value = pattern.sub(lambda _match: replacement, value)
    return value


def sanitize_text(value: str, *, roots: dict[str, str], secrets: list[str]) -> str:
    """Redact known credentials and host-specific absolute paths from text."""

    text = value if isinstance(value, str) else str(value)
    for secret in sorted(
        {secret for secret in secrets if isinstance(secret, str) and secret},
        key=lambda item: (-len(item), item),
    ):
        text = text.replace(secret, "<redacted>")
    text = _CREDENTIAL_URL_RE.sub(
        lambda match: match.group("scheme"), text
    )
    for key, replacement in (
        ("workspace", "${WORKSPACE}"),
        ("run_root", "${RUN_ROOT}"),
        ("home", "${HOME}"),
    ):
        text = _replace_root(text, str(roots.get(key, "")), replacement)
    text = _FILE_URL_RE.sub("<absolute-path>", text)
    text = _WINDOWS_ABSOLUTE_RE.sub("<absolute-path>", text)
    text = _POSIX_ABSOLUTE_RE.sub("<absolute-path>", text)
    return text


def _repository_root(start: Path | None = None) -> Path:
    current = (Path.cwd() if start is None else Path(start)).resolve()
    if current.is_file():
        current = current.parent
    for candidate in (current, *current.parents):
        if (candidate / ".git").exists():
            return candidate
    return current


def _sanitization_roots(root: Path | None = None) -> dict[str, str]:
    workspace = os.environ.get("GITHUB_WORKSPACE")
    if not workspace:
        workspace = str(_repository_root())
    return {
        "workspace": workspace,
        "run_root": str(Path(root).absolute()) if root is not None else "",
        "home": os.environ.get("HOME", str(Path.home())),
    }


def _sanitize_value(value: Any, *, roots: dict[str, str], secrets: list[str]) -> Any:
    if isinstance(value, str):
        return sanitize_text(value, roots=roots, secrets=secrets)
    if isinstance(value, list):
        return [
            _sanitize_value(item, roots=roots, secrets=secrets) for item in value
        ]
    if isinstance(value, dict):
        return {
            key: _sanitize_value(item, roots=roots, secrets=secrets)
            for key, item in value.items()
        }
    return value


def _credential_flag(value: str) -> bool:
    if not value.startswith("-"):
        return False
    name = value.split("=", 1)[0].lstrip("-")
    segments = {
        segment.upper()
        for segment in re.split(r"[^A-Za-z0-9]+", name)
        if segment
    }
    return bool(segments & _SENSITIVE_NAME_SEGMENTS)


def _sanitize_argv(
    argv: list[str], *, roots: dict[str, str], secrets: list[str]
) -> list[str]:
    sanitized = []
    redact_next = False
    for raw in argv:
        argument = str(raw)
        if redact_next:
            sanitized.append("<redacted>")
            redact_next = False
            continue
        if _credential_flag(argument):
            if "=" in argument:
                flag = argument.split("=", 1)[0]
                sanitized.append(flag + "=<redacted>")
            else:
                sanitized.append(
                    sanitize_text(argument, roots=roots, secrets=secrets)
                )
                redact_next = True
            continue
        sanitized.append(sanitize_text(argument, roots=roots, secrets=secrets))
    return sanitized


def _nested(value: Any, *parts: str) -> Any:
    current = value
    for part in parts:
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def _present(value: Any) -> bool:
    return value is not None and (not isinstance(value, str) or bool(value))


def comparability(context: dict) -> dict:
    """Derive the canonical comparison tuple and its eligibility claims."""

    source = context if isinstance(context, dict) else {}
    host_source = source.get("host") if isinstance(source.get("host"), dict) else {}
    raw_toolchain = source.get("toolchain")
    reasons = []

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
        comparable["toolchain"] = {
            name: raw_toolchain[name] for name in sorted(raw_toolchain)
        }
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
        "comparabilityTuple": comparable,
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


def _utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _json_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        )
        + "\n"
    ).encode("utf-8")


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_write_bytes(path: Path, content: bytes, mode: int = 0o600) -> None:
    path = Path(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix="." + path.name + ".", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_write_json(path: Path, value: Any) -> None:
    _atomic_write_bytes(path, _json_bytes(value))


def _read_json(path: Path) -> Any:
    try:
        with Path(path).open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON file {Path(path).name}: {exc}") from exc


@contextmanager
def _exclusive_lock(path: Path, timeout: float = 5.0):
    """Acquire an O_EXCL lock for at most five seconds.

    Callers that need both publication and attempt locks always acquire the index
    lock first, then the attempt-local lock.
    """

    lock_path = Path(path)
    deadline = time.monotonic() + min(max(timeout, 0.0), 5.0)
    descriptor = None
    while descriptor is None:
        try:
            descriptor = os.open(
                lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600
            )
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"timed out acquiring lock {lock_path.name}")
            time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    try:
        os.write(descriptor, str(os.getpid()).encode("ascii"))
        os.fsync(descriptor)
        yield
    finally:
        os.close(descriptor)
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass


_TRANSACTION_OPERATIONS = ("init", "context", "finalize")
_TRANSACTION_KEYS = {
    "schemaVersion",
    "operation",
    "attemptRoot",
    "requiredDirectories",
    "targets",
}
_TRANSACTION_TARGET_KEYS = {"path", "contentBase64", "sha256"}


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


def _pending_transaction_paths(publication_root: Path) -> list[Path]:
    transaction_root = _transaction_directory(publication_root, create=False)
    if not transaction_root.exists():
        return []
    paths = []
    for entry in sorted(transaction_root.iterdir(), key=lambda item: item.name):
        if entry.is_symlink():
            raise ValueError("pending transaction journal must not be a symlink")
        if not entry.is_file() or entry.suffix != ".json":
            raise ValueError("transaction directory contains an unsafe entry")
        paths.append(entry)
    return paths


def _load_pending_transactions(publication_root: Path) -> list[tuple[Path, dict]]:
    loaded = []
    seen_targets = set()
    seen_operations = set()
    for journal_path in _pending_transaction_paths(publication_root):
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


def _apply_transaction(
    publication_root: Path, journal_path: Path, transaction: dict
) -> None:
    _ensure_transaction_directories(
        publication_root, transaction["requiredDirectories"]
    )
    for index, target in enumerate(transaction["targets"]):
        path = _contained_transaction_path(
            publication_root, target["path"], f"targets[{index}].path"
        )
        existing = path.read_bytes() if path.is_file() else None
        if existing is None or hashlib.sha256(existing).digest() != hashlib.sha256(
            target["content"]
        ).digest():
            _atomic_write_bytes(path, target["content"])
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
    pending = _load_pending_transactions(publication_root)
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


def _safe_run_segment(value: Any) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and value not in (".", "..")
        and "/" not in value
        and "\\" not in value
        and not _SCHEME_RE.match(value)
    )


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
    index_root_resolved = index_path.parent.resolve()
    root_resolved = attempt_root.resolve()
    try:
        root_resolved.relative_to(index_root_resolved)
    except ValueError as exc:
        raise ValueError("attempt root escapes the index root") from exc
    if root_resolved != expected.resolve():
        raise ValueError("attempt root does not resolve to the expected location")


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


def _load_index(index_path: Path) -> dict:
    if not Path(index_path).exists():
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

    comparable = comparability(context)["comparabilityTuple"]
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
    index_path: Path, attempt_root: Path, context: dict
) -> dict:
    index = _registered_index_candidate(index_path, attempt_root, context)
    _atomic_write_json(index_path, index)
    return index


def register_attempt(index_path: Path, attempt_root: Path, context: dict) -> dict:
    """Register one globally unique, monotonically numbered attempt atomically."""

    index_path = Path(index_path)
    if not index_path.parent.is_dir():
        raise ValueError("attempt index parent does not exist")
    _recover_pending_transactions(index_path.parent)
    with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
        return _register_attempt_unlocked(index_path, Path(attempt_root), context)


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


def update_context(root: Path, patch: dict) -> dict:
    """Patch allowlisted context fields while preserving execution identity."""

    root = Path(root).absolute()
    publication_root = _publication_root_for_attempt(root)
    attempt_relative = _attempt_root_relative(publication_root, root)
    context_path = root / "run-context.json"
    index_path = publication_root / "attempt-index.json"
    with _exclusive_lock(publication_root / ".transactions.lock"):
        recovered = _recover_pending_transactions_unlocked(publication_root)
        recovered_result = _recovered_result(recovered, "context", attempt_relative)
        if recovered_result is not None:
            return recovered_result

        patch = _sanitize_value(
            patch,
            roots=_sanitization_roots(root),
            secrets=_collect_secret_values(),
        )
        _validate_context_patch(patch)
        if not context_path.is_file() or not index_path.is_file():
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
                    if not sibling_context_path.is_file():
                        raise ValueError("registered sibling attempt context is missing")
                    contexts[run_id] = _read_json(sibling_context_path)

                context = contexts[root.name]
                updated = _deep_merge(context, patch)
                _validate_context_identity(updated)
                if updated == context:
                    raise ValueError("context patch makes no changes")
                registered_tuple = execution["comparabilityTuple"]
                for run_id, sibling_context in contexts.items():
                    if (
                        comparability(sibling_context)["comparabilityTuple"]
                        != registered_tuple
                    ):
                        raise ValueError(
                            f"stored context for {run_id} disagrees with attempt index"
                        )
                new_tuple = comparability(updated)["comparabilityTuple"]
                resolved_tuple = _merge_resolved_identity(
                    registered_tuple, new_tuple
                )
                identity_changed = registered_tuple != resolved_tuple
                if identity_changed and any(
                    (sibling_root / "run-summary.json").exists()
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
                )
                _commit_transaction_unlocked(publication_root, transaction)
                return updated_contexts[root.name]


def _read_bootstrap_events(root: Path) -> list[dict]:
    path = root / "bootstrap-events.jsonl"
    events = []
    if path.exists():
        try:
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), 1
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
    **metadata: Any,
) -> tuple[dict, bytes, list[dict]]:
    events = _read_bootstrap_events(root) if events is None else list(events)
    event = {
        "schemaVersion": 1,
        "seq": len(events) + 1,
        "timestamp": _utc_now(),
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
        if (root / "run-summary.json").exists():
            raise ValueError("cannot append events after finalization")
        return _append_event_unlocked(root, phase, status, **metadata)


def _append_event(root: Path, phase: str, status: str, **metadata: Any) -> dict:
    root = Path(root)
    _recover_pending_transactions(_publication_root_for_attempt(root))
    with _exclusive_lock(root / ".lifecycle.lock"):
        return _append_event_during_lifecycle(root, phase, status, **metadata)


def _initialize_attempt(index_path: Path, root: Path, context: dict) -> dict:
    index_path = Path(index_path).absolute()
    root = Path(root).absolute()
    publication_root = index_path.parent
    if not publication_root.is_dir():
        raise ValueError("attempt index parent does not exist")
    attempt_relative = _attempt_root_relative(publication_root, root)
    with _exclusive_lock(publication_root / ".transactions.lock"):
        recovered = _recover_pending_transactions_unlocked(publication_root)
        recovered_result = _recovered_result(recovered, "init", attempt_relative)
        if recovered_result is not None:
            return recovered_result

        context = _sanitize_value(
            context,
            roots=_sanitization_roots(root),
            secrets=_collect_secret_values(),
        )
        _validate_context_identity(context)
        _validate_attempt_root(index_path, root, context["runId"])
        if root.exists():
            raise FileExistsError("attempt root already exists")
        with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
            if root.exists():
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
            )
            _commit_transaction_unlocked(publication_root, transaction)
            return stored


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
    root: Path, context: dict, finished_at: str, command_status: int | None
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
    )
    errors = validate_summary(fallback)
    if errors:
        raise RuntimeError("internal fallback summary is invalid: " + "; ".join(errors))
    return fallback


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
) -> dict:
    root = Path(root).absolute()
    publication_root = _publication_root_for_attempt(root)
    attempt_relative = _attempt_root_relative(publication_root, root)
    index_path = publication_root / "attempt-index.json"
    with _exclusive_lock(publication_root / ".transactions.lock"):
        recovered = _recover_pending_transactions_unlocked(publication_root)
        recovered_result = _recovered_result(
            recovered, "finalize", attempt_relative
        )
        if recovered_result is not None:
            return recovered_result
        if status not in _TERMINAL_STATUSES:
            raise ValueError("terminal status must be passed, failed, or cancelled")
        if not index_path.is_file():
            raise ValueError("attempt index is missing")
        with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
            with _exclusive_lock(root / ".lifecycle.lock"):
                with _exclusive_lock(root / ".events.lock"):
                    summary_path = root / "run-summary.json"
                    if summary_path.exists():
                        raise FileExistsError("terminal run summary already exists")
                    context = _read_json(root / "run-context.json")
                    context = _sanitize_value(
                        context,
                        roots=_sanitization_roots(root),
                        secrets=_collect_secret_values(),
                    )
                    index = _load_index(index_path)
                    execution = _execution_for_run(index, context.get("runId"))
                    current_tuple = comparability(context)["comparabilityTuple"]
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

                    roots = _sanitization_roots(root)
                    secrets = _collect_secret_values()
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
                    )
                    validation_errors = validate_summary(candidate)
                    if tuple_mismatch:
                        validation_errors = sorted(
                            set(
                                validation_errors
                                + [
                                    "$.comparabilityTuple: context disagrees with the registered execution"
                                ]
                            )
                        )
                    if validation_errors:
                        terminal = _fallback_summary(
                            root,
                            _context_with_registered_tuple(
                                context, registered_tuple
                            ),
                            finished_at,
                            command_status,
                        )
                    else:
                        terminal = candidate

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
                            **event_metadata,
                        )
                    )
                    targets = []
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
                        (
                            attempt_relative + "/run-summary.json",
                            _json_bytes(terminal),
                        )
                    )
                    transaction = _make_transaction(
                        publication_root,
                        "finalize",
                        root,
                        [attempt_relative],
                        targets,
                    )
                    _commit_transaction_unlocked(
                        publication_root, transaction
                    )
                    return terminal


def _validate_command_name(name: str) -> None:
    if (
        not isinstance(name, str)
        or not _COMMAND_SLUG_RE.fullmatch(name)
        or name in (".", "..")
    ):
        raise ValueError("command name must be a safe slug")


def _bounded_log(content: bytes, original_size: int) -> tuple[bytes, bool]:
    del original_size
    truncated = len(content) > _LOG_LIMIT
    if len(content) <= _LOG_LIMIT:
        return content, truncated
    head = content[:_LOG_HALF]
    try:
        head.decode("utf-8")
    except UnicodeDecodeError as exc:
        head = head[: exc.start]
    tail_start = len(content) - _LOG_HALF
    while tail_start < len(content) and content[tail_start] & 0xC0 == 0x80:
        tail_start += 1
    tail = content[tail_start:]
    tail.decode("utf-8")
    return head + tail, True


def _stream_record(
    path: str,
    original_size: int,
    sanitized_size: int,
    content: bytes,
    truncated: bool,
) -> dict:
    return {
        "path": path,
        "originalBytes": original_size,
        "sanitizedBytes": sanitized_size,
        "storedBytes": len(content),
        "truncated": truncated,
    }


def _replay_bytes(stream: Any, content: bytes) -> None:
    target = getattr(stream, "buffer", stream)
    try:
        target.write(content)
    except TypeError:
        target.write(content.decode("utf-8", errors="replace"))
    target.flush()


def _run_command_during_lifecycle(
    root: Path,
    phase: str,
    name: str,
    failure_code: str,
    argv: list[str],
    *,
    capture_stdout: bool = False,
    stdout_stream: Any = None,
    stderr_stream: Any = None,
) -> int:
    root = Path(root)
    _validate_command_name(name)
    if phase not in PHASES:
        raise ValueError("command phase must be a declared phase")
    if not isinstance(failure_code, str) or not failure_code:
        raise ValueError("failure code must be non-empty")
    if failure_code not in ERROR_CLASSIFICATION:
        raise ValueError("failure code must be registered")
    if not isinstance(argv, list) or not argv or not all(
        isinstance(item, str) and item for item in argv
    ):
        raise ValueError("command argv must contain at least one non-empty argument")
    if (root / "run-summary.json").exists():
        raise ValueError("cannot run a command after finalization")
    commands_root = root / "commands"
    if not commands_root.is_dir() or commands_root.is_symlink():
        raise ValueError("attempt commands directory is missing or unsafe")

    roots = _sanitization_roots(root)
    secrets = _collect_secret_values()
    sanitized_argv = _sanitize_argv(argv, roots=roots, secrets=secrets)
    started = _append_event_during_lifecycle(root, phase, "started")
    stem = f"{started['seq']:06d}-{name}"
    stdout_relative = f"commands/{stem}.stdout.log"
    stderr_relative = f"commands/{stem}.stderr.log"
    metadata_relative = f"commands/{stem}.json"

    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
        )
        raw_stdout, raw_stderr = child.communicate()
        return_code = child.returncode
    except OSError as exc:
        raw_stdout = b""
        raw_stderr = str(exc).encode("utf-8", errors="replace")
        return_code = 127

    stdout_text = raw_stdout.decode("utf-8", errors="replace")
    stderr_text = raw_stderr.decode("utf-8", errors="replace")
    sanitized_stdout = sanitize_text(
        stdout_text, roots=roots, secrets=secrets
    ).encode("utf-8")
    sanitized_stderr = sanitize_text(
        stderr_text, roots=roots, secrets=secrets
    ).encode("utf-8")
    stored_stdout, stdout_truncated = _bounded_log(
        sanitized_stdout, len(raw_stdout)
    )
    stored_stderr, stderr_truncated = _bounded_log(
        sanitized_stderr, len(raw_stderr)
    )
    _atomic_write_bytes(root / stdout_relative, stored_stdout)
    _atomic_write_bytes(root / stderr_relative, stored_stderr)

    exit_status = return_code if return_code >= 0 else None
    signal_number = -return_code if return_code < 0 else None
    metadata = {
        "schemaVersion": 1,
        "source": "subprocess",
        "argv": sanitized_argv,
        "phase": phase,
        "name": name,
        "failureCode": failure_code,
        "exitStatus": exit_status,
        "signal": signal_number,
        "stdout": _stream_record(
            stdout_relative,
            len(raw_stdout),
            len(sanitized_stdout),
            stored_stdout,
            stdout_truncated,
        ),
        "stderr": _stream_record(
            stderr_relative,
            len(raw_stderr),
            len(sanitized_stderr),
            stored_stderr,
            stderr_truncated,
        ),
    }
    metadata = _sanitize_value(metadata, roots=roots, secrets=secrets)
    _atomic_write_json(root / metadata_relative, metadata)

    if return_code == 0:
        event_status = "passed"
        event_metadata = {
            "command": metadata_relative,
            "commandStatus": 0,
            "artifact": metadata_relative,
        }
    elif return_code < 0:
        event_status = "cancelled"
        event_metadata = {
            "errorCode": failure_code,
            "summary": f"Command {name} was terminated by signal {signal_number}",
            "command": metadata_relative,
            "artifact": metadata_relative,
        }
    else:
        event_status = "failed"
        event_metadata = {
            "errorCode": failure_code,
            "summary": f"Command {name} exited with status {return_code}",
            "command": metadata_relative,
            "commandStatus": return_code,
            "artifact": metadata_relative,
        }
    _append_event_during_lifecycle(root, phase, event_status, **event_metadata)

    if stdout_stream is None:
        stdout_stream = sys.stdout
    if stderr_stream is None:
        stderr_stream = sys.stderr
    _replay_bytes(
        stdout_stream, raw_stdout if capture_stdout else sanitized_stdout
    )
    _replay_bytes(stderr_stream, sanitized_stderr)
    return return_code


def _run_command(
    root: Path,
    phase: str,
    name: str,
    failure_code: str,
    argv: list[str],
    *,
    capture_stdout: bool = False,
    stdout_stream: Any = None,
    stderr_stream: Any = None,
) -> int:
    root = Path(root)
    _recover_pending_transactions(_publication_root_for_attempt(root))
    with _exclusive_lock(root / ".lifecycle.lock"):
        return _run_command_during_lifecycle(
            root,
            phase,
            name,
            failure_code,
            argv,
            capture_stdout=capture_stdout,
            stdout_stream=stdout_stream,
            stderr_stream=stderr_stream,
        )


def _record_external_during_lifecycle(
    root: Path,
    phase: str,
    name: str,
    outcome: str,
    failure_code: str,
) -> int:
    root = Path(root)
    _validate_command_name(name)
    if phase not in PHASES:
        raise ValueError("external phase must be a declared phase")
    if outcome not in ("success", "failure", "cancelled"):
        raise ValueError("external outcome must be success, failure, or cancelled")
    if not isinstance(failure_code, str) or not failure_code:
        raise ValueError("failure code must be non-empty")
    if failure_code not in ERROR_CLASSIFICATION:
        raise ValueError("failure code must be registered")
    if outcome == "cancelled" and failure_code != "run.cancelled":
        raise ValueError("cancelled external outcome requires run.cancelled")
    if outcome == "failure" and failure_code == "run.cancelled":
        raise ValueError("failed external outcome cannot use run.cancelled")
    if (root / "run-summary.json").exists():
        raise ValueError("cannot record an external command after finalization")
    commands_root = root / "commands"
    if not commands_root.is_dir() or commands_root.is_symlink():
        raise ValueError("attempt commands directory is missing or unsafe")

    started = _append_event_during_lifecycle(root, phase, "started")
    stem = f"{started['seq']:06d}-{name}"
    stdout_relative = f"commands/{stem}.stdout.log"
    stderr_relative = f"commands/{stem}.stderr.log"
    metadata_relative = f"commands/{stem}.json"
    stdout_content = (
        "synthetic external command record. Hosted log content was not captured; "
        "consult the workflow provider for authoritative output.\n"
    ).encode("utf-8")
    stderr_content = (
        f"synthetic outcome: {outcome}. This record does not claim hosted log capture.\n"
    ).encode("utf-8")
    _atomic_write_bytes(root / stdout_relative, stdout_content)
    _atomic_write_bytes(root / stderr_relative, stderr_content)
    metadata = {
        "schemaVersion": 1,
        "source": "github-action",
        "argv": [],
        "phase": phase,
        "name": name,
        "failureCode": failure_code,
        "outcome": outcome,
        "exitStatus": None,
        "signal": None,
        "stdout": _stream_record(
            stdout_relative,
            len(stdout_content),
            len(stdout_content),
            stdout_content,
            False,
        ),
        "stderr": _stream_record(
            stderr_relative,
            len(stderr_content),
            len(stderr_content),
            stderr_content,
            False,
        ),
        "limitation": "Synthetic metadata only; hosted log content was not captured.",
    }
    _atomic_write_json(root / metadata_relative, metadata)
    event_status = {
        "success": "passed",
        "failure": "failed",
        "cancelled": "cancelled",
    }[outcome]
    event_metadata = {"command": metadata_relative, "artifact": metadata_relative}
    if outcome != "success":
        event_metadata.update(
            errorCode=failure_code,
            summary=f"External command {name} reported {outcome}",
        )
    _append_event_during_lifecycle(root, phase, event_status, **event_metadata)
    return {"success": 0, "failure": 1, "cancelled": 130}[outcome]


def _record_external(
    root: Path,
    phase: str,
    name: str,
    outcome: str,
    failure_code: str,
) -> int:
    root = Path(root)
    _recover_pending_transactions(_publication_root_for_attempt(root))
    with _exclusive_lock(root / ".lifecycle.lock"):
        return _record_external_during_lifecycle(
            root, phase, name, outcome, failure_code
        )


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


def _summary_paths(inputs: list[Path]) -> list[Path]:
    paths = []
    for supplied in inputs:
        path = Path(supplied)
        if path.is_dir():
            path = path / "run-summary.json"
        if not path.is_file():
            raise ValueError(f"summary input does not exist: {path.name}")
        paths.append(path)
    return sorted(set(paths), key=lambda path: str(path.resolve()))


def _aggregate_summaries(inputs: list[Path]) -> dict:
    groups: dict[str, dict] = {}
    seen_run_ids = set()
    for path in _summary_paths(inputs):
        summary = _read_json(path)
        errors = validate_summary(summary)
        if errors:
            raise ValueError(
                f"invalid summary {path.name}: " + "; ".join(errors)
            )
        run_id = summary["runId"]
        if run_id in seen_run_ids:
            raise ValueError("aggregate contains a duplicate runId")
        seen_run_ids.add(run_id)
        execution_id = summary["executionId"]
        computed = recompute_comparability(summary)
        group = groups.setdefault(
            execution_id,
            {
                "executionId": execution_id,
                "comparabilityTuple": computed["comparabilityTuple"],
                "comparabilityKey": computed["comparabilityKey"],
                "certificationEligible": computed["certificationEligible"],
                "ineligibilityReasons": computed["ineligibilityReasons"],
                "attempts": [],
            },
        )
        if group["comparabilityTuple"] != computed["comparabilityTuple"]:
            raise ValueError("summaries in one execution have different comparability tuples")
        group["attempts"].append(summary)
    executions = []
    for execution_id in sorted(groups):
        group = groups[execution_id]
        group["attempts"].sort(key=lambda item: (item["attempt"], item["runId"]))
        attempt_numbers = [item["attempt"] for item in group["attempts"]]
        if len(attempt_numbers) != len(set(attempt_numbers)):
            raise ValueError("aggregate contains duplicate attempt numbers")
        executions.append(group)
    return {"schemaVersion": "1.0", "executions": executions}


class _UsageError(ValueError):
    pass


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise _UsageError(message)


def _build_parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(description="Create and validate ZMR run evidence.")
    subparsers = parser.add_subparsers(dest="action", required=True)

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--root", required=True, type=Path)
    init_parser.add_argument("--context-json", required=True)
    init_parser.add_argument("--index", required=True, type=Path)

    context_parser = subparsers.add_parser("context")
    context_parser.add_argument("--root", required=True, type=Path)
    context_parser.add_argument("--set-json", required=True)

    event_parser = subparsers.add_parser("event")
    event_parser.add_argument("--root", required=True, type=Path)
    event_parser.add_argument("--phase", required=True, choices=PHASES)
    event_parser.add_argument("--status", required=True, choices=_EVENT_STATUSES)
    event_parser.add_argument("--error-code")
    event_parser.add_argument("--summary")
    event_parser.add_argument("--command")
    event_parser.add_argument("--command-status", type=int)
    event_parser.add_argument("--artifact")

    command_parser = subparsers.add_parser("command")
    command_parser.add_argument("--root", required=True, type=Path)
    command_parser.add_argument("--phase", required=True, choices=PHASES)
    command_parser.add_argument("--name", required=True)
    command_parser.add_argument("--failure-code", required=True)
    command_parser.add_argument("--capture-stdout", action="store_true")
    command_parser.add_argument("command_argv", nargs=argparse.REMAINDER)

    external_parser = subparsers.add_parser("external")
    external_parser.add_argument("--root", required=True, type=Path)
    external_parser.add_argument("--phase", required=True, choices=PHASES)
    external_parser.add_argument("--name", required=True)
    external_parser.add_argument(
        "--outcome", required=True, choices=("success", "failure", "cancelled")
    )
    external_parser.add_argument("--failure-code", required=True)

    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--root", required=True, type=Path)
    finalize_parser.add_argument(
        "--status", required=True, choices=_TERMINAL_STATUSES
    )
    finalize_parser.add_argument(
        "--classification", choices=_TERMINAL_CLASSIFICATIONS
    )
    finalize_parser.add_argument("--phase", choices=PHASES)
    finalize_parser.add_argument("--error-code")
    finalize_parser.add_argument("--summary")
    finalize_parser.add_argument("--hint")
    finalize_parser.add_argument("--command-status", type=int)
    finalize_parser.add_argument("--trace")
    finalize_parser.add_argument("--report")

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--summary", required=True, type=Path)

    bundle_parser = subparsers.add_parser("validate-bundle")
    bundle_parser.add_argument("--root", required=True, type=Path)

    aggregate_parser = subparsers.add_parser("aggregate")
    aggregate_parser.add_argument(
        "--summary", required=True, action="append", type=Path
    )
    aggregate_parser.add_argument("--json", action="store_true")
    return parser


def _argument_root(argv: list[str]) -> Path | None:
    try:
        index = argv.index("--root")
        return Path(argv[index + 1])
    except (ValueError, IndexError):
        return None


def _print_json(value: Any) -> None:
    print(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def _parse_json_argument(value: str, label: str) -> dict:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{label} must be valid JSON: {exc.msg}") from exc
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} must be a JSON object")
    return parsed


def _dispatch(args: argparse.Namespace) -> int:
    if args.action == "init":
        context = _parse_json_argument(args.context_json, "--context-json")
        stored = _initialize_attempt(args.index, args.root, context)
        _print_json(stored)
        return 0
    if args.action == "context":
        patch = _parse_json_argument(args.set_json, "--set-json")
        _print_json(update_context(args.root, patch))
        return 0
    if args.action == "event":
        metadata = {
            "errorCode": args.error_code,
            "summary": args.summary,
            "command": args.command,
            "commandStatus": args.command_status,
            "artifact": args.artifact,
        }
        _print_json(_append_event(args.root, args.phase, args.status, **metadata))
        return 0
    if args.action == "command":
        command_argv = list(args.command_argv)
        if command_argv and command_argv[0] == "--":
            command_argv.pop(0)
        return_code = _run_command(
            args.root,
            args.phase,
            args.name,
            args.failure_code,
            command_argv,
            capture_stdout=args.capture_stdout,
        )
        return return_code if return_code >= 0 else 128 + -return_code
    if args.action == "external":
        return _record_external(
            args.root,
            args.phase,
            args.name,
            args.outcome,
            args.failure_code,
        )
    if args.action == "finalize":
        artifact_patch = {
            key: value
            for key, value in (("trace", args.trace), ("report", args.report))
            if value is not None
        }
        if artifact_patch:
            update_context(args.root, {"artifacts": artifact_patch})
        result = _finalize_attempt(
            args.root,
            args.status,
            classification=args.classification,
            phase=args.phase,
            error_code=args.error_code,
            summary_text=args.summary,
            hint=args.hint,
            command_status=args.command_status,
        )
        _print_json(result)
        return 0
    if args.action == "validate":
        summary = _read_json(args.summary)
        errors = validate_summary(summary)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        _print_json({"valid": True})
        return 0
    if args.action == "validate-bundle":
        errors = validate_bundle(args.root, secrets=_collect_secret_values())
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        _print_json({"valid": True})
        return 0
    if args.action == "aggregate":
        aggregate = _aggregate_summaries(args.summary)
        if args.json:
            _print_json(aggregate)
        else:
            for execution in aggregate["executions"]:
                print(
                    f"{execution['executionId']}: {len(execution['attempts'])} attempt(s)"
                )
        return 0
    raise _UsageError("unknown action")


def main(argv: list[str] | None = None) -> int:
    raw_arguments = list(sys.argv[1:] if argv is None else argv)
    root = _argument_root(raw_arguments)
    try:
        args = _build_parser().parse_args(raw_arguments)
        return _dispatch(args)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        diagnostic = sanitize_text(
            "error: " + str(exc),
            roots=_sanitization_roots(root),
            secrets=_collect_secret_values(),
        )
        print(diagnostic, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
