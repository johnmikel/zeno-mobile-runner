"""Secret, path, and command argument sanitization."""

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

from .constants import *  # noqa: F401,F403

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

__all__ = (
    "_collect_secret_values",
    "_replace_root",
    "sanitize_text",
    "_repository_root",
    "_sanitization_roots",
    "_sanitize_value",
    "_credential_flag",
    "_sanitize_argv",
)
