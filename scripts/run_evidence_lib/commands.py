"""Subprocess and external-command evidence capture."""

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
from .contracts import *  # noqa: F401,F403
from .sanitization import *  # noqa: F401,F403
from .safe_io import *  # noqa: F401,F403
from .journal import *  # noqa: F401,F403
from .lifecycle import *  # noqa: F401,F403

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

__all__ = (
    "_validate_command_name",
    "_bounded_log",
    "_stream_record",
    "_replay_bytes",
    "_run_command_during_lifecycle",
    "_run_command",
    "_record_external_during_lifecycle",
    "_record_external",
)
