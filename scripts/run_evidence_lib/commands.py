"""Subprocess and external-command evidence capture."""

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
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

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


class BoundedHeadTail:
    """Retain at most the first and last halves of a sanitized byte stream."""

    def __init__(self) -> None:
        self._head = bytearray()
        self._tail = bytearray()
        self._total_bytes = 0

    def feed(self, chunk: bytes) -> None:
        if not isinstance(chunk, bytes):
            raise TypeError("bounded collector accepts bytes")
        self._total_bytes += len(chunk)
        head_remaining = _LOG_HALF - len(self._head)
        if head_remaining > 0:
            self._head.extend(chunk[:head_remaining])
            chunk = chunk[head_remaining:]
        if chunk:
            self._tail.extend(chunk)
            overflow = len(self._tail) - _LOG_HALF
            if overflow > 0:
                del self._tail[:overflow]

    def finish(self) -> tuple[bytes, int, bool]:
        truncated = self._total_bytes > _LOG_LIMIT
        if not truncated:
            return bytes(self._head + self._tail), self._total_bytes, False

        head = bytes(self._head)
        try:
            head.decode("utf-8")
        except UnicodeDecodeError as exc:
            head = head[: exc.start]
        tail_start = 0
        while tail_start < len(self._tail) and self._tail[tail_start] & 0xC0 == 0x80:
            tail_start += 1
        tail = bytes(self._tail[tail_start:])
        tail.decode("utf-8")
        return head + tail, self._total_bytes, True


class _CaptureStreamWriter:
    """Write raw bytes immediately, preserving UTF-8 for text-only sinks."""

    def __init__(self, stream: Any) -> None:
        binary_stream = getattr(stream, "buffer", None)
        self._stream = stream if binary_stream is None else binary_stream
        self._binary: bool | None = True if binary_stream is not None else None
        self._decoder: Any = None
        self.error: BaseException | None = None

    def write(self, chunk: bytes) -> None:
        if self.error is not None or not chunk:
            return
        try:
            if self._binary is not False:
                try:
                    self._stream.write(chunk)
                    self._binary = True
                except TypeError:
                    if self._binary is True:
                        raise
                    self._binary = False
                    self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
                    text = self._decoder.decode(chunk, final=False)
                    if text:
                        self._stream.write(text)
            else:
                text = self._decoder.decode(chunk, final=False)
                if text:
                    self._stream.write(text)
            self._stream.flush()
        except BaseException as exc:
            self.error = exc

    def finish(self) -> None:
        if self.error is not None:
            return
        try:
            if self._binary is False:
                text = self._decoder.decode(b"", final=True)
                if text:
                    self._stream.write(text)
            self._stream.flush()
        except BaseException as exc:
            self.error = exc


class _PipeCapture:
    """Drain, sanitize, and bound one child pipe without retaining raw output."""

    def __init__(
        self,
        *,
        roots: dict[str, str],
        secrets: list[str],
        raw_stream: Any = None,
    ) -> None:
        self.original_bytes = 0
        self.collector = BoundedHeadTail()
        self.sanitizer = StreamingSanitizer(roots=roots, secrets=secrets)
        self.raw_writer = (
            _CaptureStreamWriter(raw_stream) if raw_stream is not None else None
        )
        self.error: BaseException | None = None

    def _accept(self, chunk: bytes) -> None:
        self.original_bytes += len(chunk)
        self.collector.feed(self.sanitizer.feed(chunk))
        if self.raw_writer is not None:
            self.raw_writer.write(chunk)

    def drain(self, pipe: Any) -> None:
        processing = True
        read_chunk = getattr(pipe, "read1", pipe.read)
        try:
            while True:
                chunk = read_chunk(_PIPE_READ_CHUNK_SIZE)
                if not chunk:
                    break
                if processing:
                    try:
                        self._accept(chunk)
                    except BaseException as exc:
                        self.error = exc
                        processing = False
                else:
                    self.original_bytes += len(chunk)
            if processing:
                try:
                    self.collector.feed(self.sanitizer.finish())
                except BaseException as exc:
                    self.error = exc
        except BaseException as exc:
            self.error = self.error or exc
        finally:
            if self.raw_writer is not None:
                self.raw_writer.finish()
            pipe.close()

    def accept_complete(self, content: bytes) -> None:
        self._accept(content)
        self.collector.feed(self.sanitizer.finish())
        if self.raw_writer is not None:
            self.raw_writer.finish()

    @property
    def stream_error(self) -> BaseException | None:
        if self.raw_writer is None:
            return None
        return self.raw_writer.error


class _ChildSignalController:
    """Own wrapper signals while a POSIX child process group is active."""

    _FORWARDED_SIGNALS = (signal.SIGINT, signal.SIGTERM)

    def __init__(self) -> None:
        self.child: subprocess.Popen | None = None
        self.received_signal: int | None = None
        self._deadline: float | None = None
        self._kill_sent = False
        self._outcome_frozen = False
        self._previous_handlers: dict[int, Any] = {}
        self.forward_errors: list[OSError] = []
        self._enabled = (
            os.name == "posix"
            and hasattr(os, "killpg")
            and threading.current_thread() is threading.main_thread()
        )

    def __enter__(self) -> "_ChildSignalController":
        if self._enabled:
            for signal_number in self._FORWARDED_SIGNALS:
                self._previous_handlers[signal_number] = signal.getsignal(
                    signal_number
                )
                signal.signal(signal_number, self._handle_signal)
        return self

    def __exit__(self, _exc_type: Any, _exc: Any, _traceback: Any) -> None:
        if self._enabled:
            for signal_number, handler in self._previous_handlers.items():
                signal.signal(signal_number, handler)

    def attach(self, child: subprocess.Popen) -> None:
        self.child = child
        if self.received_signal is not None:
            self._begin_forwarding(self.received_signal)

    def _handle_signal(self, signal_number: int, _frame: Any) -> None:
        if self._outcome_frozen:
            return
        if self.received_signal is None:
            self.received_signal = signal_number
        if self.child is not None:
            self._begin_forwarding(signal_number)

    def _begin_forwarding(self, signal_number: int) -> None:
        if self._deadline is None:
            self._deadline = time.monotonic() + _CHILD_SIGNAL_GRACE_SECONDS
        self._send_to_group(signal_number)

    def _send_to_group(self, signal_number: int) -> None:
        if self.child is None:
            return
        try:
            os.killpg(self.child.pid, signal_number)
        except ProcessLookupError:
            pass
        except OSError as exc:
            self.forward_errors.append(exc)

    def _service_escalation(self) -> None:
        if (
            self.received_signal is not None
            and self._deadline is not None
            and not self._kill_sent
            and time.monotonic() >= self._deadline
        ):
            self._kill_sent = True
            self._send_to_group(signal.SIGKILL)

    def wait_for_completion(self, readers: tuple[threading.Thread, ...]) -> int:
        if self.child is None:
            raise RuntimeError("signal controller has no child")
        if not self._enabled:
            child_status = self.child.wait()
            for reader in readers:
                reader.join()
            return child_status

        while True:
            child_status = self.child.poll()
            active_readers = [reader for reader in readers if reader.is_alive()]
            if child_status is not None and not active_readers:
                return child_status
            self._service_escalation()
            if active_readers:
                per_reader_wait = _CHILD_WAIT_POLL_SECONDS / len(active_readers)
                for reader in active_readers:
                    reader.join(timeout=per_reader_wait)
            else:
                time.sleep(_CHILD_WAIT_POLL_SECONDS)

    def freeze_outcome(self, child_status: int) -> int:
        self._outcome_frozen = True
        if self.received_signal is not None:
            return -self.received_signal
        return child_status


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


def _execute_command_during_lifecycle(
    root: Path,
    phase: str,
    name: str,
    failure_code: str,
    argv: list[str],
    *,
    signal_controller: _ChildSignalController,
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
    if _evidence_exists(root / "run-summary.json"):
        raise ValueError("cannot run a command after finalization")
    commands_root = root / "commands"
    if not _evidence_is_dir(commands_root) or _evidence_is_symlink(commands_root):
        raise ValueError("attempt commands directory is missing or unsafe")

    roots = _sanitization_roots(root)
    secrets = _collect_secret_values()
    sanitized_argv = _sanitize_argv(argv, roots=roots, secrets=secrets)
    started = _append_event_during_lifecycle(root, phase, "started")
    stem = f"{started['seq']:06d}-{name}"
    stdout_relative = f"commands/{stem}.stdout.log"
    stderr_relative = f"commands/{stem}.stderr.log"
    metadata_relative = f"commands/{stem}.json"

    if stdout_stream is None:
        stdout_stream = sys.stdout
    if stderr_stream is None:
        stderr_stream = sys.stderr
    stdout_capture = _PipeCapture(
        roots=roots,
        secrets=secrets,
        raw_stream=stdout_stream if capture_stdout else None,
    )
    stderr_capture = _PipeCapture(roots=roots, secrets=secrets)

    popen_options = {"start_new_session": True} if os.name == "posix" else {}
    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
            **popen_options,
        )
    except OSError as exc:
        stdout_capture.accept_complete(b"")
        stderr_capture.accept_complete(
            str(exc).encode("utf-8", errors="replace")
        )
        return_code = 127
    else:
        signal_controller.attach(child)
        stdout_reader = threading.Thread(
            target=stdout_capture.drain,
            args=(child.stdout,),
            name=f"evidence-{name}-stdout",
        )
        stderr_reader = threading.Thread(
            target=stderr_capture.drain,
            args=(child.stderr,),
            name=f"evidence-{name}-stderr",
        )
        readers = (stdout_reader, stderr_reader)
        for reader in readers:
            reader.start()
        return_code = signal_controller.wait_for_completion(readers)
        reader_errors = [
            capture.error
            for capture in (stdout_capture, stderr_capture)
            if capture.error is not None
        ]
        if reader_errors:
            raise reader_errors[0]
    return_code = signal_controller.freeze_outcome(return_code)

    stored_stdout, sanitized_stdout_size, stdout_truncated = (
        stdout_capture.collector.finish()
    )
    stored_stderr, sanitized_stderr_size, stderr_truncated = (
        stderr_capture.collector.finish()
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
            stdout_capture.original_bytes,
            sanitized_stdout_size,
            stored_stdout,
            stdout_truncated,
        ),
        "stderr": _stream_record(
            stderr_relative,
            stderr_capture.original_bytes,
            sanitized_stderr_size,
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

    if not capture_stdout:
        _replay_bytes(stdout_stream, stored_stdout)
    _replay_bytes(stderr_stream, stored_stderr)
    if stdout_capture.stream_error is not None:
        raise stdout_capture.stream_error
    return return_code


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
    signal_controller = _ChildSignalController()
    with signal_controller:
        return _execute_command_during_lifecycle(
            root,
            phase,
            name,
            failure_code,
            argv,
            signal_controller=signal_controller,
            capture_stdout=capture_stdout,
            stdout_stream=stdout_stream,
            stderr_stream=stderr_stream,
        )


@_rooted_attempt_mutation
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
    if _evidence_exists(root / "run-summary.json"):
        raise ValueError("cannot record an external command after finalization")
    commands_root = root / "commands"
    if not _evidence_is_dir(commands_root) or _evidence_is_symlink(commands_root):
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


@_rooted_attempt_mutation
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
    "BoundedHeadTail",
    "_stream_record",
    "_replay_bytes",
    "_run_command_during_lifecycle",
    "_run_command",
    "_record_external_during_lifecycle",
    "_record_external",
)
