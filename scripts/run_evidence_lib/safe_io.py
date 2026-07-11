"""Canonical JSON, atomic files, and advisory locks."""

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
    """Acquire a process-owned advisory lock for at most five seconds.

    Lifecycle callers acquire the publication transaction lock first, then the
    index lock, then any attempt-local locks.
    """

    lock_path = Path(path)
    deadline = time.monotonic() + min(max(timeout, 0.0), 5.0)
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOINHERIT"):
        flags |= os.O_NOINHERIT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(lock_path, flags, 0o600)
    locked = False
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"lock path {lock_path.name} must be a regular file")
        if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
            raise ValueError(f"lock path {lock_path.name} has an unsafe owner")
        path_metadata = os.stat(lock_path, follow_symlinks=False)
        if (
            not stat.S_ISREG(path_metadata.st_mode)
            or path_metadata.st_dev != metadata.st_dev
            or path_metadata.st_ino != metadata.st_ino
        ):
            raise ValueError(f"lock path {lock_path.name} changed during acquisition")
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, 0o600)
        else:
            os.chmod(lock_path, 0o600)
        if os.name == "nt" and metadata.st_size < 1:
            os.write(descriptor, b"\0")
            os.fsync(descriptor)

        while not locked:
            try:
                if os.name == "nt":
                    os.lseek(descriptor, 0, os.SEEK_SET)
                    msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
            except (BlockingIOError, OSError) as exc:
                if os.name != "nt" and getattr(exc, "errno", None) not in (
                    errno.EACCES,
                    errno.EAGAIN,
                    errno.EWOULDBLOCK,
                ):
                    raise
                if time.monotonic() >= deadline:
                    raise TimeoutError(
                        f"timed out acquiring lock {lock_path.name}"
                    ) from exc
                time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))

        acquired_path_metadata = os.stat(lock_path, follow_symlinks=False)
        if (
            not stat.S_ISREG(acquired_path_metadata.st_mode)
            or acquired_path_metadata.st_dev != metadata.st_dev
            or acquired_path_metadata.st_ino != metadata.st_ino
        ):
            raise ValueError(f"lock path {lock_path.name} changed while waiting")
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.write(descriptor, str(os.getpid()).encode("ascii"))
        os.fsync(descriptor)
        yield
    finally:
        if locked:
            if os.name == "nt":
                os.lseek(descriptor, 0, os.SEEK_SET)
                msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


__all__ = (
    "_utc_now",
    "_json_bytes",
    "_fsync_directory",
    "_atomic_write_bytes",
    "_atomic_write_json",
    "_read_json",
    "_exclusive_lock",
)
