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

_CREDENTIAL_TOKEN_DECISION_RE = re.compile(r"[/@\s\x00\"'<>|,;]")
_SCHEME_CHARACTERS = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+.-"
)


def _utf8_byte_length(value: Any) -> int | None:
    """Return strict UTF-8 size, or None for non-strings and lone surrogates."""

    if not isinstance(value, str):
        return None
    try:
        return len(value.encode("utf-8"))
    except UnicodeEncodeError:
        return None


def _credential_scheme_start(value: str, marker: int) -> int | None:
    start = marker
    while start > 0 and value[start - 1] in _SCHEME_CHARACTERS:
        start -= 1
    if start == marker:
        return None
    first = value[start]
    if not (("A" <= first <= "Z") or ("a" <= first <= "z")):
        return None
    return start


def _credential_url_spans(value: str):
    """Yield non-overlapping credential URL spans in linear token space."""

    search_from = 0
    while True:
        marker = value.find("://", search_from)
        if marker < 0:
            return
        scheme_start = _credential_scheme_start(value, marker)
        decision = _CREDENTIAL_TOKEN_DECISION_RE.search(value, marker + 3)
        if (
            scheme_start is not None
            and decision is not None
            and decision.group(0) == "@"
        ):
            yield scheme_start, decision.end(), value[scheme_start : marker + 3]
            search_from = decision.end()
        else:
            search_from = marker + 3


def _redact_credential_urls(value: str) -> str:
    if "://" not in value or "@" not in value:
        return value
    parts: list[str] = []
    cursor = 0
    for start, end, scheme in _credential_url_spans(value):
        parts.extend((value[cursor:start], scheme))
        cursor = end
    if not parts:
        return value
    parts.append(value[cursor:])
    return "".join(parts)

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
    text = _redact_credential_urls(text)
    for secret in sorted(
        {secret for secret in secrets if isinstance(secret, str) and secret},
        key=lambda item: (-len(item), item),
    ):
        text = text.replace(secret, "<redacted>")
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
    across pipe reads.  Complete delimited tokens are preferred as flush points.
    Overlong sensitive tokens are replaced wholesale while their remainder is
    discarded with constant state.  Arbitrarily long URL schemes are tracked
    without retaining them; unrelated undelimited streams are still bounded by
    flushing their safe prefix.
    """

    _DELIMITERS = " \t\r\n\x00\"'<>|,;"
    _CREDENTIAL_DECISION_RE = _CREDENTIAL_TOKEN_DECISION_RE
    _TOKEN_DELIMITER_RE = re.compile(r"[\s\x00\"'<>|,;]")
    _SCHEME_CONTINUATION_RE = re.compile(r"[A-Za-z0-9+.-]*\Z")
    _TRAILING_SCHEME_CHARS_RE = re.compile(r"[A-Za-z0-9+.-]+\Z")

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
        self._sensitive_token_state: str | None = None
        self._streamed_scheme_prefix = False
        self._finished = False

    @staticmethod
    def _is_ascii_letter(value: str) -> bool:
        return ("A" <= value <= "Z") or ("a" <= value <= "z")

    def _advance_streamed_scheme_prefix(self, content: str) -> None:
        """Track an unbounded scheme prefix using constant metadata."""

        if not content:
            return
        if self._streamed_scheme_prefix and self._SCHEME_CONTINUATION_RE.fullmatch(
            content
        ):
            return
        suffix = self._TRAILING_SCHEME_CHARS_RE.search(content)
        self._streamed_scheme_prefix = bool(
            suffix is not None
            and self._is_ascii_letter(suffix.group(0)[0])
        )

    def _open_known_roots(self) -> list[tuple[int, int, str]]:
        matches: list[tuple[int, int, str]] = []
        for priority, (key, replacement) in enumerate(
            (
                ("workspace", "${WORKSPACE}"),
                ("run_root", "${RUN_ROOT}"),
                ("home", "${HOME}"),
            )
        ):
            root = str(self._roots.get(key, ""))
            candidates = {root.rstrip("/\\")}
            if "\\" in root:
                candidates.add(root.replace("\\", "/").rstrip("/"))
            for candidate in sorted(candidates, key=len, reverse=True):
                if not candidate:
                    continue
                start = self._pending.find(candidate)
                while start >= 0:
                    before_ok = start == 0 or self._pending[start - 1] not in (
                        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                        "abcdefghijklmnopqrstuvwxyz"
                        "0123456789_.-"
                    )
                    end = start + len(candidate)
                    after_ok = end == len(self._pending) or self._pending[
                        end
                    ] in "/\\ \t\r\n\x00\"'<>|,;"
                    if (
                        before_ok
                        and after_ok
                        and self._TOKEN_DELIMITER_RE.search(
                            self._pending, end
                        )
                        is None
                    ):
                        matches.append((start, priority, replacement))
                    start = self._pending.find(candidate, start + 1)
        return matches

    def _open_absolute_path(self) -> tuple[int, str] | None:
        if "/" not in self._pending and "\\" not in self._pending:
            return None

        candidates = self._open_known_roots()

        for priority, pattern in enumerate(
            (_FILE_URL_RE, _WINDOWS_ABSOLUTE_RE, _POSIX_ABSOLUTE_RE),
            start=3,
        ):
            for match in pattern.finditer(self._pending):
                if match.end() == len(self._pending):
                    candidates.append(
                        (match.start(), priority, "<absolute-path>")
                    )
        if not candidates:
            return None
        start, _priority, marker = min(candidates)
        return start, marker

    def _begin_sensitive_token(
        self, start: int, marker: str, state: str
    ) -> bytes:
        prefix_end = self._include_crossing_redactions(start)
        prefix = self._pending[:prefix_end]
        self._pending = ""
        self._sensitive_token_state = state
        self._streamed_scheme_prefix = False
        return (
            sanitize_text(
                prefix, roots=self._roots, secrets=self._secrets
            ).encode("utf-8")
            + marker.encode("utf-8")
        )

    def _activate_streamed_scheme(self) -> tuple[bytes, str] | None:
        if not self._streamed_scheme_prefix or "://" not in self._pending:
            return None
        marker = self._pending.find("://")
        scheme_tail = self._pending[:marker]
        if self._SCHEME_CONTINUATION_RE.fullmatch(scheme_tail) is None:
            return None
        remainder = self._pending[marker + 3 :]
        emitted = sanitize_text(
            scheme_tail, roots=self._roots, secrets=self._secrets
        ).encode("utf-8") + b"<redacted>"
        self._pending = ""
        self._sensitive_token_state = "credential_confirmed"
        self._streamed_scheme_prefix = False
        return emitted, remainder

    def _pending_credential_start(self) -> int | None:
        token_start = max(
            (self._pending.rfind(delimiter) + 1 for delimiter in self._DELIMITERS),
            default=0,
        )
        token = self._pending[token_start:]
        search_from = 0
        while True:
            marker = token.find("://", search_from)
            if marker < 0:
                return None
            scheme_start = _credential_scheme_start(token, marker)
            decision = self._CREDENTIAL_DECISION_RE.search(token, marker + 3)
            if scheme_start is not None and decision is None:
                return token_start + scheme_start
            search_from = marker + 3

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
        open_path = self._open_absolute_path()
        if open_path is not None and open_path[0] < split:
            path_start, marker = open_path
            return self._begin_sensitive_token(
                path_start, marker, "absolute_path"
            )
        credential_start = self._pending_credential_start()
        if credential_start is not None and credential_start < split:
            if len(self._pending) - credential_start > self._carry * 2:
                return self._begin_sensitive_token(
                    credential_start,
                    "<redacted>",
                    "credential_candidate",
                )
            split = credential_start
        split = self._include_crossing_redactions(split)
        prefix = self._pending[:split]
        self._pending = self._pending[split:]
        self._advance_streamed_scheme_prefix(prefix)
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
            if "://" in self._pending and "@" in self._pending:
                for start, end, _scheme in _credential_url_spans(
                    self._pending
                ):
                    if start >= split:
                        break
                    if end > split:
                        expanded = max(expanded, end)
            if expanded == split:
                return split
            split = expanded

    def _discard_sensitive_token(self, content: str) -> str:
        """Discard a redacted token without retaining its unbounded remainder."""

        while content and self._sensitive_token_state is not None:
            if self._sensitive_token_state == "credential_candidate":
                decision = self._CREDENTIAL_DECISION_RE.search(content)
                if decision is None:
                    return ""
                marker = decision.group(0)
                if marker == "@":
                    self._sensitive_token_state = "credential_confirmed"
                    content = content[decision.end() :]
                    continue
                self._sensitive_token_state = None
                self._streamed_scheme_prefix = False
                return content[decision.start() :]

            delimiter = self._TOKEN_DELIMITER_RE.search(content)
            if delimiter is None:
                return ""
            self._sensitive_token_state = None
            self._streamed_scheme_prefix = False
            return content[delimiter.start() :]
        return content

    def _process_text(self, content: str) -> bytes:
        emitted: list[bytes] = []
        pending_limit = self._carry * 2
        while content:
            if self._sensitive_token_state is not None:
                content = self._discard_sensitive_token(content)
                if not content:
                    break

            take = min(len(content), pending_limit + 1 - len(self._pending))
            self._pending += content[:take]
            content = content[take:]
            streamed_scheme = self._activate_streamed_scheme()
            if streamed_scheme is not None:
                streamed, remainder = streamed_scheme
                emitted.append(streamed)
                content = remainder + content
                continue
            flushed = self._flush_prefix()
            if flushed:
                emitted.append(flushed)
        return b"".join(emitted)

    def feed(self, chunk: bytes) -> bytes:
        if self._finished:
            raise ValueError("cannot feed a finished sanitizer")
        if not isinstance(chunk, bytes):
            raise TypeError("streaming sanitizer accepts bytes")
        return self._process_text(self._decoder.decode(chunk, final=False))

    def finish(self) -> bytes:
        if self._finished:
            return b""
        self._finished = True
        emitted = self._process_text(self._decoder.decode(b"", final=True))
        if self._sensitive_token_state is not None:
            self._sensitive_token_state = None
            self._pending = ""
            return emitted
        content = sanitize_text(
            self._pending, roots=self._roots, secrets=self._secrets
        ).encode("utf-8")
        self._pending = ""
        return emitted + content


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
