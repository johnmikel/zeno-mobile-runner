"""Public vocabularies and evidence limits."""

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

__all__ = (
    "PHASES",
    "COMPARABILITY_FIELDS",
    "_ERROR_GROUPS",
    "ERROR_CLASSIFICATION",
    "_CLASSIFICATION_PRECEDENCE",
    "_EVENT_STATUSES",
    "_TERMINAL_STATUSES",
    "_TERMINAL_CLASSIFICATIONS",
    "_FAILURE_CLASSIFICATIONS",
    "_REVISION_RE",
    "_DIGEST_RE",
    "_TOOL_NAME_RE",
    "_REASON_RE",
    "_AJV_DATE_RE",
    "_AJV_TIME_RE",
    "_SCHEME_RE",
    "_CREDENTIAL_URL_RE",
    "_FILE_URL_RE",
    "_POSIX_ABSOLUTE_RE",
    "_WINDOWS_ABSOLUTE_RE",
    "_SENSITIVE_NAME_SEGMENTS",
    "_LOG_LIMIT",
    "_LOG_HALF",
    "_COMMAND_SLUG_RE",
)
