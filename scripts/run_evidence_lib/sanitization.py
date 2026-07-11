"""Secret, path, and command argument sanitization."""

from __future__ import annotations

import argparse
import base64
import binascii
import codecs
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


class StreamingSanitizer:
    """Incrementally decode and sanitize a byte stream with bounded carry.

    The carry keeps split UTF-8 sequences and ordinary sensitive values together
    across pipe reads.  Complete delimited tokens are preferred as flush points;
    an undelimited stream is still bounded by flushing its safe prefix.
    """

    _DELIMITERS = " \t\r\n\x00\"'<>|,;"

    def __init__(self, *, roots: dict[str, str], secrets: list[str]) -> None:
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._roots = roots
        self._secrets = secrets
        configured_width = max(
            (
                len(value)
                for value in (*roots.values(), *secrets)
                if isinstance(value, str)
            ),
            default=0,
        )
        self._carry = max(_SANITIZATION_CARRY, configured_width + 1)
        self._pending = ""
        self._finished = False

    def _flush_prefix(self) -> bytes:
        if len(self._pending) <= self._carry * 2:
            return b""
        flush_limit = len(self._pending) - self._carry
        split = max(
            (
                self._pending.rfind(delimiter, 0, flush_limit) + 1
                for delimiter in self._DELIMITERS
            ),
            default=0,
        )
        if split == 0:
            split = flush_limit
        split = self._include_crossing_redactions(split)
        prefix = self._pending[:split]
        self._pending = self._pending[split:]
        return sanitize_text(
            prefix, roots=self._roots, secrets=self._secrets
        ).encode("utf-8")

    def _include_crossing_redactions(self, split: int) -> int:
        """Move a flush point past any complete redaction that straddles it."""

        while True:
            expanded = split
            for secret in self._secrets:
                if not isinstance(secret, str) or not secret:
                    continue
                search_start = max(0, split - len(secret) + 1)
                search_end = min(len(self._pending), split + len(secret) - 1)
                position = self._pending.find(
                    secret, search_start, search_end
                )
                while position != -1 and position < split:
                    end = position + len(secret)
                    if end > split:
                        expanded = max(expanded, end)
                    position = self._pending.find(
                        secret, position + 1, search_end
                    )
            credential_start = max(0, split - self._carry)
            credential_end = min(len(self._pending), split + self._carry)
            if self._pending.find("://", credential_start, credential_end) != -1:
                for match in _CREDENTIAL_URL_RE.finditer(
                    self._pending, credential_start, credential_end
                ):
                    if match.start() < split < match.end():
                        expanded = max(expanded, match.end())
            if expanded == split:
                return split
            split = expanded

    def feed(self, chunk: bytes) -> bytes:
        if self._finished:
            raise ValueError("cannot feed a finished sanitizer")
        if not isinstance(chunk, bytes):
            raise TypeError("streaming sanitizer accepts bytes")
        self._pending += self._decoder.decode(chunk, final=False)
        return self._flush_prefix()

    def finish(self) -> bytes:
        if self._finished:
            return b""
        self._finished = True
        self._pending += self._decoder.decode(b"", final=True)
        content = sanitize_text(
            self._pending, roots=self._roots, secrets=self._secrets
        ).encode("utf-8")
        self._pending = ""
        return content


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
    "StreamingSanitizer",
    "_repository_root",
    "_sanitization_roots",
    "_sanitize_value",
    "_credential_flag",
    "_sanitize_argv",
)
