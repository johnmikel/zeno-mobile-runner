"""Bounded descriptor-relative readers for untrusted evidence files."""

from __future__ import annotations

import json
import os
import stat
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from . import constants as _limits
from . import safe_io


class _EntryLimitExceeded(ValueError):
    """Raised before a hostile directory tree can grow traversal state."""


_MAX_JSON_NESTING_DEPTH = 256


def _validate_json_nesting(
    value: Any, maximum: int = _MAX_JSON_NESTING_DEPTH
) -> None:
    """Validate JSON depth iteratively with memory bounded by nesting depth."""

    if not isinstance(maximum, int) or isinstance(maximum, bool) or maximum < 1:
        raise ValueError("JSON nesting limit must be a positive integer")
    current = value
    depth = 0
    parents: list[tuple[Iterator[Any], int]] = []
    while True:
        children: Iterator[Any] | None = None
        if isinstance(current, list):
            children = iter(current)
        elif isinstance(current, dict):
            children = iter(current.values())
        if children is not None:
            try:
                child = next(children)
            except StopIteration:
                pass
            else:
                if depth >= maximum:
                    raise ValueError("nesting exceeds supported depth")
                parents.append((children, depth))
                current = child
                depth += 1
                continue
        while parents:
            siblings, parent_depth = parents[-1]
            try:
                current = next(siblings)
            except StopIteration:
                parents.pop()
                continue
            depth = parent_depth + 1
            break
        else:
            return


def _decode_json_bytes(content: bytes) -> Any:
    """Strictly decode one JSON document and enforce deterministic depth."""

    try:
        value = json.loads(content.decode("utf-8"))
    except RecursionError as exc:
        raise ValueError("nesting exceeds supported depth") from exc
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(str(exc)) from exc
    _validate_json_nesting(value)
    return value


@contextmanager
def _rooted_regular_descriptor(
    path: Path,
    *,
    expected_identity: tuple[int, int] | None = None,
    expected_metadata: os.stat_result | None = None,
) -> Iterator[tuple[int, os.stat_result]]:
    """Open one rooted regular file without following a path component."""

    authority = safe_io._active_rooted_io()
    parent, name, parent_relative, relative = authority._parent(path)
    descriptor = -1
    try:
        safe_io._rooted_io_checkpoint("read", "before_open", authority.path(relative))
        safe_io._rooted_io_checkpoint(
            "read_json", "before_open", authority.path(relative)
        )
        authority._validate_directory(parent_relative, parent)
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent,
        )
        os.set_inheritable(descriptor, False)
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise authority._error("evidence read target is not a regular file")
        identity = (opened.st_dev, opened.st_ino)
        if expected_identity is not None and identity != expected_identity:
            raise authority._error("evidence file changed while scanning")
        if expected_metadata is not None and (
            identity != (expected_metadata.st_dev, expected_metadata.st_ino)
            or opened.st_size != expected_metadata.st_size
            or opened.st_mtime_ns != expected_metadata.st_mtime_ns
            or opened.st_ctime_ns != expected_metadata.st_ctime_ns
        ):
            raise authority._error("evidence file changed while scanning")
        yield descriptor, opened
        authority._validate_directory(parent_relative, parent)
        visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
        finished = os.fstat(descriptor)
        if (
            not stat.S_ISREG(visible.st_mode)
            or (visible.st_dev, visible.st_ino) != identity
            or (finished.st_dev, finished.st_ino) != identity
            or finished.st_size != opened.st_size
            or finished.st_mtime_ns != opened.st_mtime_ns
            or finished.st_ctime_ns != opened.st_ctime_ns
        ):
            raise authority._error("evidence file changed while scanning")
    except OSError as exc:
        raise authority._error("descriptor-relative read failed", exc) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def _iter_regular_chunks(
    path: Path,
    *,
    chunk_bytes: int | None = None,
    expected_identity: tuple[int, int] | None = None,
    expected_metadata: os.stat_result | None = None,
) -> Iterator[bytes]:
    """Yield bounded chunks from a rooted regular file."""

    size = _limits._BUNDLE_SCAN_CHUNK_BYTES if chunk_bytes is None else chunk_bytes
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise ValueError("chunk size must be a positive integer")
    with _rooted_regular_descriptor(
        Path(path),
        expected_identity=expected_identity,
        expected_metadata=expected_metadata,
    ) as (descriptor, _metadata):
        while True:
            chunk = os.read(descriptor, size)
            if not chunk:
                break
            yield chunk


def _iter_rooted_tree(
    root: Path, *, maximum_directories: int
) -> Iterator[tuple[Path, os.stat_result]]:
    """Walk a rooted tree without following links or materializing directories.

    The directory cap is independent from the public file cap.  This prevents a
    hostile empty-directory fanout from exhausting traversal memory without
    charging legitimate directory layout against the file allowance.
    """

    if (
        not isinstance(maximum_directories, int)
        or isinstance(maximum_directories, bool)
        or maximum_directories < 1
    ):
        raise ValueError("maximum directory count must be a positive integer")
    authority = safe_io._active_rooted_io()
    root = Path(root)
    root_relative = authority._relative(root)
    root_metadata = authority.stat(root)
    if root_metadata is None or not stat.S_ISDIR(root_metadata.st_mode):
        raise authority._error("bundle traversal root is not a directory")
    pending = [(root_relative, (root_metadata.st_dev, root_metadata.st_ino))]
    directories = 1
    while pending:
        directory_relative, expected_identity = pending.pop()
        try:
            descriptor = authority._open_directory_unchecked(directory_relative)
        except FileNotFoundError as exc:
            raise authority._error("bundle directory disappeared", exc) from exc
        try:
            authority._validate_directory(directory_relative, descriptor)
            if authority._identity(descriptor) != expected_identity:
                raise authority._error("bundle directory binding changed")
            with os.scandir(descriptor) as iterator:
                for entry in iterator:
                    name = entry.name
                    if name in ("", ".", "..") or "/" in name or "\x00" in name:
                        raise authority._error("bundle entry name is not normalized")
                    child_relative = (
                        f"{directory_relative}/{name}"
                        if directory_relative
                        else name
                    )
                    metadata = os.stat(
                        name, dir_fd=descriptor, follow_symlinks=False
                    )
                    child_identity = (metadata.st_dev, metadata.st_ino)
                    yield authority.path(child_relative), metadata
                    authority._validate_directory(directory_relative, descriptor)
                    visible = os.stat(
                        name, dir_fd=descriptor, follow_symlinks=False
                    )
                    if (visible.st_dev, visible.st_ino) != child_identity:
                        raise authority._error("bundle entry binding changed")
                    if stat.S_ISDIR(metadata.st_mode):
                        directories += 1
                        if directories > maximum_directories:
                            raise _EntryLimitExceeded
                        pending.append((child_relative, child_identity))
            authority._validate_directory(directory_relative, descriptor)
        except OSError as exc:
            raise authority._error(
                "descriptor-relative bundle traversal failed", exc
            ) from exc
        finally:
            os.close(descriptor)


def _has_pending_transaction_entries(root: Path) -> bool:
    """Inspect only whether the publication transaction directory is non-empty."""

    authority = safe_io._active_rooted_io()
    transaction_directory = Path(root).parent.parent / ".transactions"
    metadata = authority.stat(transaction_directory, missing_ok=True)
    if metadata is None:
        return False
    if not stat.S_ISDIR(metadata.st_mode):
        return True
    relative = authority._relative(transaction_directory)
    descriptor = authority._open_directory_unchecked(relative)
    try:
        authority._validate_directory(relative, descriptor)
        with os.scandir(descriptor) as entries:
            pending = next(entries, None) is not None
        authority._validate_directory(relative, descriptor)
        return pending
    finally:
        os.close(descriptor)


def _read_bounded_bytes(
    path: Path,
    maximum: int,
    *,
    expected_metadata: os.stat_result | None = None,
) -> bytes:
    """Read at most ``maximum`` bytes, rejecting before an unbounded allocation."""

    path = Path(path)
    if (
        not isinstance(maximum, int)
        or isinstance(maximum, bool)
        or maximum < 0
    ):
        raise ValueError("structured JSON limit must be a non-negative integer")
    if safe_io._ACTIVE_ROOTED_IO.get() is not None:
        chunks = _iter_regular_chunks(path, expected_metadata=expected_metadata)
        metadata = safe_io._evidence_stat(path)
        if metadata.st_size > maximum:
            raise ValueError(f"structured JSON exceeds {maximum} bytes")
    else:
        handle = path.open("rb")
        metadata = os.fstat(handle.fileno())
        if metadata.st_size > maximum:
            handle.close()
            raise ValueError(f"structured JSON exceeds {maximum} bytes")

        def direct_chunks() -> Iterator[bytes]:
            with handle:
                while True:
                    chunk = handle.read(_limits._BUNDLE_SCAN_CHUNK_BYTES)
                    if not chunk:
                        break
                    yield chunk

        chunks = direct_chunks()

    content = bytearray()
    for chunk in chunks:
        if len(content) + len(chunk) > maximum:
            raise ValueError(f"structured JSON exceeds {maximum} bytes")
        content.extend(chunk)
    return bytes(content)


def _read_json_bounded(
    path: Path,
    maximum: int | None = None,
    *,
    expected_metadata: os.stat_result | None = None,
) -> tuple[Any, int]:
    """Parse one strictly decoded JSON document and return its input byte count."""

    limit = _limits.MAX_STRUCTURED_JSON_BYTES if maximum is None else maximum
    try:
        content = _read_bounded_bytes(
            Path(path), limit, expected_metadata=expected_metadata
        )
    except ValueError as exc:
        if str(exc).startswith("structured JSON exceeds"):
            raise
        raise ValueError(f"invalid JSON file {Path(path).name}: {exc}") from exc
    try:
        return _decode_json_bytes(content), len(content)
    except ValueError as exc:
        raise ValueError(f"invalid JSON file {Path(path).name}: {exc}") from exc


def _iter_bounded_jsonl_lines(
    path: Path,
    maximum: int | None = None,
    *,
    expected_metadata: os.stat_result | None = None,
) -> Iterator[tuple[int, bytes | None]]:
    """Yield JSONL lines; ``None`` marks a line discarded after exceeding its cap."""

    limit = _limits.MAX_JSONL_LINE_BYTES if maximum is None else maximum
    buffered = bytearray()
    line_number = 1
    discarding = False
    for chunk in _iter_regular_chunks(
        Path(path), expected_metadata=expected_metadata
    ):
        offset = 0
        while offset < len(chunk):
            newline = chunk.find(b"\n", offset)
            end = len(chunk) if newline < 0 else newline
            piece = chunk[offset:end]
            if not discarding:
                if len(buffered) + len(piece) > limit:
                    buffered.clear()
                    discarding = True
                else:
                    buffered.extend(piece)
            if newline < 0:
                break
            yield line_number, None if discarding else bytes(buffered)
            line_number += 1
            buffered.clear()
            discarding = False
            offset = newline + 1
    if discarding or buffered:
        yield line_number, None if discarding else bytes(buffered)


__all__ = (
    "_EntryLimitExceeded",
    "_MAX_JSON_NESTING_DEPTH",
    "_validate_json_nesting",
    "_decode_json_bytes",
    "_rooted_regular_descriptor",
    "_iter_regular_chunks",
    "_iter_rooted_tree",
    "_has_pending_transaction_entries",
    "_read_bounded_bytes",
    "_read_json_bounded",
    "_iter_bounded_jsonl_lines",
)
