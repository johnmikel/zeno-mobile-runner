"""Bounded descriptor-relative readers for untrusted evidence files."""

from __future__ import annotations

import json
import math
import os
import re
import stat
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from . import constants as _limits
from . import safe_io


class _EntryLimitExceeded(ValueError):
    """Raised before a hostile directory tree can grow traversal state."""


_MAX_JSON_NESTING_DEPTH = 256
_JSON_TEXT_CHUNK_CHARACTERS = 16 * 1024
_JSON_ESCAPE_RE = re.compile(r'[\x00-\x1f"\\]')
_JSON_SHORT_ESCAPES = {
    '"': b'\\"',
    "\\": b"\\\\",
    "\b": b"\\b",
    "\f": b"\\f",
    "\n": b"\\n",
    "\r": b"\\r",
    "\t": b"\\t",
}


def _reject_duplicate_object_pairs(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    """Build one JSON object while rejecting ambiguous duplicate members."""

    value: dict[str, Any] = {}
    for key, member in pairs:
        if key in value:
            raise ValueError("duplicate object key")
        value[key] = member
    return value


def _reject_non_finite_constant(_value: str) -> Any:
    raise ValueError("non-finite JSON number")


def _validate_json_nesting(
    value: Any,
    maximum: int = _MAX_JSON_NESTING_DEPTH,
    *,
    maximum_work: int | None = None,
) -> None:
    """Validate native JSON using memory proportional only to active depth."""

    if not isinstance(maximum, int) or isinstance(maximum, bool) or maximum < 1:
        raise ValueError("JSON nesting limit must be a positive integer")
    if maximum_work is not None and (
        not isinstance(maximum_work, int)
        or isinstance(maximum_work, bool)
        or maximum_work < 1
    ):
        raise ValueError("JSON work limit must be a positive integer")
    active: set[int] = set()
    work = 0
    stack: list[tuple[str, Any, int]] = [("enter", value, 0)]
    while stack:
        action, current, depth = stack.pop()
        if action == "exit":
            active.remove(current)
            continue
        if action == "next":
            iterator, identity = current
            try:
                child = next(iterator)
            except StopIteration:
                continue
            work += 1
            if maximum_work is not None and work > maximum_work:
                raise ValueError("JSON graph exceeds supported work")
            if depth >= maximum:
                raise ValueError("nesting exceeds supported depth")
            stack.append(("next", (iterator, identity), depth))
            stack.append(("enter", child, depth + 1))
            continue

        value_type = type(current)
        if current is None or value_type in (bool, int, str):
            continue
        if value_type is float:
            if not math.isfinite(current):
                raise ValueError("non-finite JSON number")
            continue
        if value_type not in (list, dict):
            raise ValueError("JSON value must use native JSON types")
        identity = id(current)
        if identity in active:
            raise ValueError("circular JSON container reference")
        active.add(identity)
        if value_type is dict:
            for key in current:
                work += 1
                if maximum_work is not None and work > maximum_work:
                    raise ValueError("JSON graph exceeds supported work")
                if type(key) is not str:
                    raise ValueError("JSON object keys must be strings")
            children = iter(current.values())
        else:
            children = iter(current)
        stack.append(("exit", identity, depth))
        stack.append(("next", (children, identity), depth))


def _decode_json_bytes(content: bytes) -> Any:
    """Strictly decode one JSON document and enforce deterministic depth."""

    try:
        value = json.loads(
            content.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_object_pairs,
            parse_constant=_reject_non_finite_constant,
        )
    except RecursionError as exc:
        raise ValueError("nesting exceeds supported depth") from exc
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(str(exc)) from exc
    _validate_json_nesting(value, maximum_work=max(1, len(content) + 1))
    return value


class _BoundedCanonicalJSONWriter:
    """Emit canonical UTF-8 JSON while retaining at most the admitted bytes."""

    def __init__(self, maximum: int, label: str) -> None:
        self._maximum = maximum
        self._label = label
        self._content = bytearray()

    @property
    def remaining(self) -> int:
        return self._maximum - len(self._content)

    def _raise_limit(self) -> None:
        raise ValueError(f"{self._label} exceeds {self._maximum} bytes")

    def _write(self, content: bytes) -> None:
        if len(self._content) + len(content) > self._maximum:
            self._raise_limit()
        self._content.extend(content)

    def _write_text_span(self, value: str, start: int, end: int) -> None:
        while start < end:
            chunk_end = min(end, start + _JSON_TEXT_CHUNK_CHARACTERS)
            try:
                encoded = value[start:chunk_end].encode("utf-8")
            except UnicodeEncodeError as exc:
                raise ValueError("JSON string is not valid UTF-8") from exc
            self._write(encoded)
            start = chunk_end

    def _write_string(self, value: str) -> None:
        self._write(b'"')
        chunk_start = 0
        while chunk_start < len(value):
            chunk_end = min(
                len(value),
                chunk_start
                + min(
                    _JSON_TEXT_CHUNK_CHARACTERS,
                    max(1, self.remaining + 1),
                ),
            )
            chunk = value[chunk_start:chunk_end]
            cursor = 0
            for match in _JSON_ESCAPE_RE.finditer(chunk):
                self._write_text_span(chunk, cursor, match.start())
                character = match.group(0)
                escaped = _JSON_SHORT_ESCAPES.get(character)
                if escaped is None:
                    escaped = f"\\u{ord(character):04x}".encode("ascii")
                self._write(escaped)
                cursor = match.end()
            self._write_text_span(chunk, cursor, len(chunk))
            chunk_start = chunk_end
        self._write(b'"')

    def _string_size_bounded(self, value: str, maximum: int) -> int:
        total = 2
        if total > maximum:
            return maximum + 1
        chunk_start = 0
        while chunk_start < len(value):
            chunk_end = min(
                len(value),
                chunk_start
                + min(
                    _JSON_TEXT_CHUNK_CHARACTERS,
                    max(1, maximum - total + 1),
                ),
            )
            chunk = value[chunk_start:chunk_end]
            cursor = 0
            for match in _JSON_ESCAPE_RE.finditer(chunk):
                try:
                    total += len(chunk[cursor : match.start()].encode("utf-8"))
                except UnicodeEncodeError as exc:
                    raise ValueError("JSON string is not valid UTF-8") from exc
                if total > maximum:
                    return maximum + 1
                total += 2 if match.group(0) in _JSON_SHORT_ESCAPES else 6
                if total > maximum:
                    return maximum + 1
                cursor = match.end()
            try:
                total += len(chunk[cursor:].encode("utf-8"))
            except UnicodeEncodeError as exc:
                raise ValueError("JSON string is not valid UTF-8") from exc
            if total > maximum:
                return maximum + 1
            chunk_start = chunk_end
        return total

    def _preflight_dict_sort(self, mapping: dict[str, Any]) -> None:
        minimum = 1  # Closing brace.
        for index, key in enumerate(mapping):
            if type(key) is not str:
                raise ValueError("JSON object keys must be strings")
            key_size = self._string_size_bounded(
                key, max(0, self.remaining - minimum)
            )
            minimum += key_size + 2  # Colon plus the smallest JSON value.
            if index:
                minimum += 1
            if minimum > self.remaining:
                self._raise_limit()

    def encode(self, value: Any) -> bytes:
        active: set[int] = set()
        stack: list[tuple[str, Any, int]] = [("value", value, 0)]
        while stack:
            action, current, depth = stack.pop()
            if action == "exit":
                active.remove(current)
                continue
            if action == "list-next":
                iterator, first = current
                try:
                    child = next(iterator)
                except StopIteration:
                    self._write(b"]")
                    continue
                if not first:
                    self._write(b",")
                if depth >= _MAX_JSON_NESTING_DEPTH:
                    raise ValueError("nesting exceeds supported depth")
                stack.append(("list-next", (iterator, False), depth))
                stack.append(("value", child, depth + 1))
                continue
            if action == "dict-next":
                iterator, mapping, first = current
                try:
                    key = next(iterator)
                except StopIteration:
                    self._write(b"}")
                    continue
                if not first:
                    self._write(b",")
                self._write_string(key)
                self._write(b":")
                if depth >= _MAX_JSON_NESTING_DEPTH:
                    raise ValueError("nesting exceeds supported depth")
                stack.append(
                    ("dict-next", (iterator, mapping, False), depth)
                )
                stack.append(("value", mapping[key], depth + 1))
                continue

            value_type = type(current)
            if current is None:
                self._write(b"null")
            elif value_type is bool:
                self._write(b"true" if current else b"false")
            elif value_type is int:
                bit_length = current.bit_length()
                minimum_digits = (
                    1
                    if bit_length == 0
                    else ((bit_length - 1) * 30102) // 100000 + 1
                )
                if minimum_digits + (1 if current < 0 else 0) > self.remaining:
                    self._raise_limit()
                try:
                    encoded_integer = str(current).encode("ascii")
                except ValueError as exc:
                    raise ValueError("JSON integer is too large") from exc
                self._write(encoded_integer)
            elif value_type is float:
                if not math.isfinite(current):
                    raise ValueError("non-finite JSON number")
                self._write(repr(current).encode("ascii"))
            elif value_type is str:
                self._write_string(current)
            elif value_type is list:
                identity = id(current)
                if identity in active:
                    raise ValueError("circular JSON container reference")
                active.add(identity)
                self._write(b"[")
                stack.append(("exit", identity, depth))
                stack.append(("list-next", (iter(current), True), depth))
            elif value_type is dict:
                identity = id(current)
                if identity in active:
                    raise ValueError("circular JSON container reference")
                active.add(identity)
                self._write(b"{")
                self._preflight_dict_sort(current)
                stack.append(("exit", identity, depth))
                stack.append(
                    (
                        "dict-next",
                        (iter(sorted(current)), current, True),
                        depth,
                    )
                )
            else:
                raise ValueError("JSON value must use native JSON types")
        self._write(b"\n")
        return bytes(self._content)


def _json_bytes_bounded(
    value: Any,
    maximum: int | None = None,
    *,
    label: str = "structured JSON",
) -> bytes:
    """Canonically encode one JSON value within a deterministic byte budget."""

    limit = _limits.MAX_STRUCTURED_JSON_BYTES if maximum is None else maximum
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
        raise ValueError("structured JSON limit must be a non-negative integer")
    return _BoundedCanonicalJSONWriter(limit, label).encode(value)


def _jsonl_line_bytes_bounded(
    value: Any,
    maximum: int | None = None,
    *,
    label: str = "JSONL line",
) -> bytes:
    """Encode canonical JSONL while applying the public cap to its payload."""

    limit = _limits.MAX_JSONL_LINE_BYTES if maximum is None else maximum
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
        raise ValueError("JSONL line limit must be a non-negative integer")
    try:
        content = _json_bytes_bounded(
            value,
            maximum=limit + 1,
            label=label,
        )
    except ValueError as exc:
        if str(exc) == f"{label} exceeds {limit + 1} bytes":
            raise ValueError(f"{label} exceeds {limit} bytes") from exc
        raise
    if not content.endswith(b"\n"):
        raise RuntimeError("canonical JSON encoding must end with a newline")
    if len(content) - 1 > limit:
        raise ValueError(f"{label} exceeds {limit} bytes")
    return content


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
    "_json_bytes_bounded",
    "_jsonl_line_bytes_bounded",
    "_rooted_regular_descriptor",
    "_iter_regular_chunks",
    "_iter_rooted_tree",
    "_has_pending_transaction_entries",
    "_read_bounded_bytes",
    "_read_json_bounded",
    "_iter_bounded_jsonl_lines",
)
