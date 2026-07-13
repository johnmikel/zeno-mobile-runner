"""Canonical JSON, atomic files, and advisory locks."""

from __future__ import annotations

import contextvars
import errno
import fnmatch
import functools
import inspect
import json
import os
import secrets
import stat
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

if os.name == "posix":
    import fcntl

from .constants import *  # noqa: F401,F403


ROOTED_IO_CONTAINMENT_ERROR = "evidence rooted I/O containment changed"


class RootedIOError(ValueError):
    """A trusted evidence root or one of its directory bindings changed."""


def _replace_supports_dir_fds() -> bool:
    try:
        parameters = inspect.signature(os.replace).parameters
    except (TypeError, ValueError):
        return False
    return "src_dir_fd" in parameters and "dst_dir_fd" in parameters


POSIX_SAFE_DIRFD_AVAILABLE = bool(
    os.name == "posix"
    and sys.version_info >= MINIMUM_PYTHON
    and all(
        hasattr(os, name)
        for name in ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC")
    )
    and all(
        function in os.supports_dir_fd
        for function in (os.open, os.stat, os.mkdir, os.unlink)
    )
    and os.listdir in os.supports_fd
    and os.scandir in os.supports_fd
    and _replace_supports_dir_fds()
)


def _require_mutation_capability() -> None:
    if not POSIX_SAFE_DIRFD_AVAILABLE:
        raise RuntimeError(EVIDENCE_MUTATION_REQUIREMENT)


_ACTIVE_ROOTED_IO: contextvars.ContextVar[Any] = contextvars.ContextVar(
    "run_evidence_rooted_io", default=None)

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
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def _rooted_io_checkpoint(operation: str, phase: str, path: Path) -> None:
    """No-op fault seam for deterministic containment-race tests."""


class _RootedIO:
    """Descriptor-relative authority for one visible publication root."""

    def __init__(self, root: Path) -> None:
        if not POSIX_SAFE_DIRFD_AVAILABLE:
            raise RootedIOError(f"{ROOTED_IO_CONTAINMENT_ERROR}: "
                                "POSIX safe-dirfd capability is unavailable")
        self.root = Path(root).absolute()
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        try:
            self.descriptor = os.open(self.root, flags)
        except OSError as exc:
            raise RootedIOError(
                f"{ROOTED_IO_CONTAINMENT_ERROR}: publication root is unavailable"
            ) from exc
        os.set_inheritable(self.descriptor, False)
        metadata = os.fstat(self.descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            os.close(self.descriptor)
            raise RootedIOError(
                f"{ROOTED_IO_CONTAINMENT_ERROR}: publication root is not a directory"
            )
        self.identity = (metadata.st_dev, metadata.st_ino)

    def close(self) -> None:
        descriptor = getattr(self, "descriptor", -1)
        if descriptor >= 0:
            self.descriptor = -1
            os.close(descriptor)

    def __enter__(self) -> "_RootedIO":
        return self

    def __exit__(self, _exc_type: Any, _exc: Any, _traceback: Any) -> None:
        self.close()

    def _error(self, detail: str, cause: BaseException | None = None) -> RootedIOError:
        error = RootedIOError(f"{ROOTED_IO_CONTAINMENT_ERROR}: {detail}")
        if cause is not None:
            error.__cause__ = cause
        return error

    def _relative(self, path: Path | str) -> str:
        candidate = Path(path)
        if candidate.is_absolute():
            try:
                candidate = candidate.absolute().relative_to(self.root)
            except ValueError as exc:
                raise self._error("path escapes the publication root", exc)
        parts = candidate.parts
        if any(part in ("", ".", "..") or "/" in part or "\x00" in part for part in parts):
            raise self._error("path is not normalized")
        return "/".join(parts)

    def path(self, relative: str) -> Path:
        return self.root.joinpath(*relative.split("/")) if relative else self.root

    @staticmethod
    def _identity(descriptor: int) -> tuple[int, int]:
        metadata = os.fstat(descriptor)
        return metadata.st_dev, metadata.st_ino

    def _duplicate_root(self) -> int:
        descriptor = os.dup(self.descriptor)
        os.set_inheritable(descriptor, False)
        return descriptor

    def _open_directory_unchecked(self, relative: str) -> int:
        descriptor = self._duplicate_root()
        try:
            for component in relative.split("/") if relative else ():
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=descriptor,
                )
                os.set_inheritable(next_descriptor, False)
                os.close(descriptor)
                descriptor = next_descriptor
            return descriptor
        except FileNotFoundError:
            os.close(descriptor)
            raise
        except OSError as exc:
            os.close(descriptor)
            raise self._error("directory traversal is unsafe", exc)

    def revalidate_root(self) -> None:
        try:
            visible = os.stat(self.root, follow_symlinks=False)
        except OSError as exc:
            raise self._error("publication root path is unavailable", exc)
        if (
            not stat.S_ISDIR(visible.st_mode)
            or (visible.st_dev, visible.st_ino) != self.identity
            or self._identity(self.descriptor) != self.identity
        ):
            raise self._error("publication root identity changed")

    def _validate_directory(self, relative: str, descriptor: int) -> None:
        self.revalidate_root()
        try:
            visible_descriptor = self._open_directory_unchecked(relative)
        except FileNotFoundError as exc:
            raise self._error("trusted directory binding disappeared", exc)
        try:
            if self._identity(visible_descriptor) != self._identity(descriptor):
                raise self._error("trusted directory binding changed")
        finally:
            os.close(visible_descriptor)

    def _parent(self, path: Path | str) -> tuple[int, str, str, str]:
        relative = self._relative(path)
        if not relative:
            raise self._error("operation requires a child path")
        components = relative.split("/")
        parent_relative = "/".join(components[:-1])
        try:
            descriptor = self._open_directory_unchecked(parent_relative)
        except FileNotFoundError as exc:
            raise self._error("trusted parent directory is missing", exc)
        return descriptor, components[-1], parent_relative, relative

    def stat(self, path: Path | str, *, missing_ok: bool = False) -> os.stat_result | None:
        relative = self._relative(path)
        if not relative:
            self.revalidate_root()
            return os.fstat(self.descriptor)
        try:
            parent, name, parent_relative, _relative = self._parent(path)
        except RootedIOError as exc:
            if missing_ok and isinstance(exc.__cause__, FileNotFoundError):
                return None
            raise
        try:
            _rooted_io_checkpoint("stat", "before_stat", self.path(relative))
            self._validate_directory(parent_relative, parent)
            try:
                metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                if missing_ok:
                    return None
                raise
            self._validate_directory(parent_relative, parent)
            return metadata
        except OSError as exc:
            if isinstance(exc, FileNotFoundError) and missing_ok:
                return None
            raise self._error("descriptor-relative stat failed", exc)
        finally:
            os.close(parent)

    def exists(self, path: Path | str) -> bool:
        return self.stat(path, missing_ok=True) is not None

    def is_file(self, path: Path | str) -> bool:
        metadata = self.stat(path, missing_ok=True)
        return metadata is not None and stat.S_ISREG(metadata.st_mode)

    def is_directory(self, path: Path | str) -> bool:
        metadata = self.stat(path, missing_ok=True)
        return metadata is not None and stat.S_ISDIR(metadata.st_mode)

    def is_symlink(self, path: Path | str) -> bool:
        metadata = self.stat(path, missing_ok=True)
        return metadata is not None and stat.S_ISLNK(metadata.st_mode)

    def read_bytes(self, path: Path | str) -> bytes:
        parent, name, parent_relative, relative = self._parent(path)
        descriptor = -1
        try:
            _rooted_io_checkpoint("read", "before_open", self.path(relative))
            _rooted_io_checkpoint("read_json", "before_open", self.path(relative))
            self._validate_directory(parent_relative, parent)
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=parent,
            )
            os.set_inheritable(descriptor, False)
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise self._error("evidence read target is not a regular file")
            chunks = []
            while True:
                chunk = os.read(descriptor, 64 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            self._validate_directory(parent_relative, parent)
            return b"".join(chunks)
        except OSError as exc:
            raise self._error("descriptor-relative read failed", exc)
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            os.close(parent)

    def read_text(self, path: Path | str) -> str:
        return self.read_bytes(path).decode("utf-8")

    def list_names(self, path: Path | str) -> list[str]:
        relative = self._relative(path)
        try:
            descriptor = self._open_directory_unchecked(relative)
        except FileNotFoundError:
            raise
        try:
            _rooted_io_checkpoint("list", "before_list", self.path(relative))
            self._validate_directory(relative, descriptor)
            names = os.listdir(descriptor)
            self._validate_directory(relative, descriptor)
            return sorted(names)
        except OSError as exc:
            raise self._error("descriptor-relative directory listing failed", exc)
        finally:
            os.close(descriptor)

    def ensure_directory(self, path: Path | str, mode: int = 0o700) -> None:
        relative = self._relative(path)
        descriptor = self._duplicate_root()
        traversed = []
        try:
            for component in relative.split("/") if relative else ():
                traversed.append(component)
                child_relative = "/".join(traversed)
                try:
                    next_descriptor = os.open(
                        component,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=descriptor,
                    )
                except FileNotFoundError:
                    parent_relative = "/".join(traversed[:-1])
                    _rooted_io_checkpoint(
                        "mkdir", "before_mkdir", self.path(child_relative)
                    )
                    self._validate_directory(parent_relative, descriptor)
                    os.mkdir(component, mode=mode, dir_fd=descriptor)
                    os.fsync(descriptor)
                    next_descriptor = os.open(
                        component,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=descriptor,
                    )
                except OSError as exc:
                    raise self._error("required directory is unsafe", exc)
                os.set_inheritable(next_descriptor, False)
                os.close(descriptor)
                descriptor = next_descriptor
            self._validate_directory(relative, descriptor)
        finally:
            os.close(descriptor)

    def unlink(self, path: Path | str, *, missing_ok: bool = False) -> None:
        parent, name, parent_relative, relative = self._parent(path)
        try:
            _rooted_io_checkpoint("unlink", "before_unlink", self.path(relative))
            self._validate_directory(parent_relative, parent)
            try:
                os.unlink(name, dir_fd=parent)
            except FileNotFoundError:
                if not missing_ok:
                    raise
                return
            os.fsync(parent)
            self._validate_directory(parent_relative, parent)
        except OSError as exc:
            raise self._error("descriptor-relative unlink failed", exc)
        finally:
            os.close(parent)

    def atomic_write(self, path: Path | str, content: bytes, mode: int = 0o600) -> None:
        parent, name, parent_relative, relative = self._parent(path)
        temporary_name = ""
        descriptor = -1
        try:
            self._validate_directory(parent_relative, parent)
            for _attempt in range(128):
                temporary_name = f".{name}.{secrets.token_hex(4)}.tmp"
                try:
                    descriptor = os.open(
                        temporary_name,
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | os.O_NOFOLLOW
                        | os.O_CLOEXEC,
                        0o600,
                        dir_fd=parent,
                    )
                    break
                except FileExistsError:
                    continue
            if descriptor < 0:
                raise FileExistsError("could not allocate atomic temporary")
            os.set_inheritable(descriptor, False)
            os.fchmod(descriptor, mode)
            view = memoryview(content)
            while view:
                written = os.write(descriptor, view)
                view = view[written:]
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = -1
            _rooted_io_checkpoint("atomic_write", "before_replace", self.path(relative))
            self._validate_directory(parent_relative, parent)
            os.replace(
                temporary_name,
                name,
                src_dir_fd=parent,
                dst_dir_fd=parent,
            )
            temporary_name = ""
            os.fsync(parent)
            self._validate_directory(parent_relative, parent)
        except RootedIOError:
            raise
        except OSError as exc:
            raise self._error("descriptor-relative atomic write failed", exc)
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            if temporary_name:
                try:
                    os.unlink(temporary_name, dir_fd=parent)
                except FileNotFoundError:
                    pass
            os.close(parent)

    @contextmanager
    def lock(self, path: Path | str, timeout: float = 5.0):
        parent, name, parent_relative, relative = self._parent(path)
        descriptor = -1
        locked = False
        deadline = time.monotonic() + min(max(timeout, 0.0), 5.0)
        try:
            _rooted_io_checkpoint("lock", "before_open", self.path(relative))
            self._validate_directory(parent_relative, parent)
            descriptor = os.open(
                name,
                os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=parent,
            )
            os.set_inheritable(descriptor, False)
            metadata = os.fstat(descriptor)
            visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or (visible.st_dev, visible.st_ino)
                != (metadata.st_dev, metadata.st_ino)
            ):
                raise self._error("lock file binding changed")
            if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
                raise self._error("lock file has an unsafe owner")
            os.fchmod(descriptor, 0o600)
            while not locked:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    locked = True
                except OSError as exc:
                    if exc.errno not in (errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK):
                        raise
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"timed out acquiring lock {name}") from exc
                    time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
            self._validate_directory(parent_relative, parent)
            visible = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (visible.st_dev, visible.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise self._error("lock file changed while waiting")
            os.ftruncate(descriptor, 0)
            os.lseek(descriptor, 0, os.SEEK_SET)
            os.write(descriptor, str(os.getpid()).encode("ascii"))
            os.fsync(descriptor)
            yield
            self._validate_directory(parent_relative, parent)
        finally:
            if locked:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            if descriptor >= 0:
                os.close(descriptor)
            os.close(parent)


@contextmanager
def _rooted_io(publication_root: Path, *, mutation: bool = True):
    if mutation:
        _require_mutation_capability()
    root = Path(publication_root).absolute()
    active = _ACTIVE_ROOTED_IO.get()
    if active is not None:
        if active.root != root:
            raise RootedIOError(
                f"{ROOTED_IO_CONTAINMENT_ERROR}: nested publication root differs"
            )
        active.revalidate_root()
        yield active
        return
    authority = _RootedIO(root)
    token = _ACTIVE_ROOTED_IO.set(authority)
    try:
        yield authority
        authority.revalidate_root()
    finally:
        _ACTIVE_ROOTED_IO.reset(token)
        authority.close()


def _active_rooted_io() -> _RootedIO:
    authority = _ACTIVE_ROOTED_IO.get()
    if authority is None:
        raise RuntimeError("evidence I/O requires an active rooted publication scope")
    return authority


def _publication_root_for_path(path: Path) -> Path:
    absolute = Path(path).absolute()
    parts = absolute.parts
    if "attempts" in parts:
        index = len(parts) - 1 - tuple(reversed(parts)).index("attempts")
        return Path(*parts[:index])
    if absolute.parent.name == ".transactions":
        return absolute.parent.parent
    return absolute.parent


def _evidence_exists(path: Path) -> bool:
    return _active_rooted_io().exists(path)


def _evidence_is_file(path: Path) -> bool:
    return _active_rooted_io().is_file(path)


def _evidence_is_dir(path: Path) -> bool:
    return _active_rooted_io().is_directory(path)


def _evidence_is_symlink(path: Path) -> bool:
    return _active_rooted_io().is_symlink(path)


def _evidence_stat(path: Path) -> os.stat_result:
    metadata = _active_rooted_io().stat(path)
    assert metadata is not None
    return metadata


def _evidence_read_bytes(path: Path) -> bytes:
    return _active_rooted_io().read_bytes(path)


def _evidence_read_text(path: Path) -> str:
    return _active_rooted_io().read_text(path)


def _evidence_iterdir(path: Path) -> list[Path]:
    return [Path(path) / name for name in _active_rooted_io().list_names(path)]


def _evidence_glob(path: Path, pattern: str) -> list[Path]:
    return [
        candidate
        for candidate in _evidence_iterdir(path)
        if fnmatch.fnmatch(candidate.name, pattern)
    ]


def _evidence_rglob(path: Path) -> list[Path]:
    found = []
    pending = [Path(path)]
    while pending:
        directory = pending.pop()
        for candidate in _evidence_iterdir(directory):
            found.append(candidate)
            if _evidence_is_dir(candidate) and not _evidence_is_symlink(candidate):
                pending.append(candidate)
    return found


def _evidence_mkdir(path: Path, mode: int = 0o700) -> None:
    _active_rooted_io().ensure_directory(path, mode)


def _evidence_unlink(path: Path, *, missing_ok: bool = False) -> None:
    _active_rooted_io().unlink(path, missing_ok=missing_ok)


def _rooted_publication_mutation(function):
    @functools.wraps(function)
    def wrapped(publication_root, *args, **kwargs):
        with _rooted_io(Path(publication_root), mutation=True):
            return function(publication_root, *args, **kwargs)

    return wrapped


def _rooted_index_mutation(function):
    @functools.wraps(function)
    def wrapped(index_path, *args, **kwargs):
        with _rooted_io(Path(index_path).absolute().parent, mutation=True):
            return function(index_path, *args, **kwargs)

    return wrapped


def _rooted_attempt_mutation(function):
    @functools.wraps(function)
    def wrapped(root, *args, **kwargs):
        publication_root = Path(root).absolute().parent.parent
        with _rooted_io(publication_root, mutation=True):
            return function(root, *args, **kwargs)

    return wrapped


def _rooted_attempt_read(function):
    @functools.wraps(function)
    def wrapped(root, *args, **kwargs):
        publication_root = Path(root).absolute().parent.parent
        try:
            with _rooted_io(publication_root, mutation=False):
                return function(root, *args, **kwargs)
        except RootedIOError as exc:
            return [str(exc)]

    return wrapped


def _fsync_directory(path: Path) -> None:
    authority = _active_rooted_io()
    relative = authority._relative(path)
    descriptor = authority._open_directory_unchecked(relative)
    try:
        authority._validate_directory(relative, descriptor)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_write_bytes(path: Path, content: bytes, mode: int = 0o600) -> None:
    _active_rooted_io().atomic_write(Path(path), content, mode)


def _atomic_write_json(path: Path, value: Any) -> None:
    _atomic_write_bytes(path, _json_bytes(value))


def _read_json(path: Path) -> Any:
    try:
        if _ACTIVE_ROOTED_IO.get() is not None:
            content = _evidence_read_text(Path(path))
            return json.loads(content)
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

    if _ACTIVE_ROOTED_IO.get() is None:
        with _rooted_io(_publication_root_for_path(Path(path)), mutation=True):
            with _active_rooted_io().lock(Path(path), timeout):
                yield
        return
    with _active_rooted_io().lock(Path(path), timeout):
        yield


__all__ = (
    "ROOTED_IO_CONTAINMENT_ERROR",
    "RootedIOError",
    "POSIX_SAFE_DIRFD_AVAILABLE",
    "_require_mutation_capability",
    "_utc_now",
    "_json_bytes",
    "_rooted_io_checkpoint",
    "_RootedIO",
    "_rooted_io",
    "_active_rooted_io",
    "_publication_root_for_path",
    "_evidence_exists",
    "_evidence_is_file",
    "_evidence_is_dir",
    "_evidence_is_symlink",
    "_evidence_stat",
    "_evidence_read_bytes",
    "_evidence_read_text",
    "_evidence_iterdir",
    "_evidence_glob",
    "_evidence_rglob",
    "_evidence_mkdir",
    "_evidence_unlink",
    "_rooted_publication_mutation",
    "_rooted_index_mutation",
    "_rooted_attempt_mutation",
    "_rooted_attempt_read",
    "_fsync_directory",
    "_atomic_write_bytes",
    "_atomic_write_json",
    "_read_json",
    "_exclusive_lock",
)
