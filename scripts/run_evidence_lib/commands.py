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

from . import bounded_io
from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .sanitization import *  # noqa: F401,F403
from .sanitization import _owned_plain_text, _utf8_byte_length
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


def _own_command_scalar(value: Any, *, diagnostic: str) -> str:
    """Copy a command scalar without invoking string-subclass overrides."""

    try:
        return _owned_plain_text(
            value, maximum_characters=MAX_COMMAND_ARG_BYTES
        )
    except ValueError as exc:
        raise ValueError(diagnostic) from exc


def _own_command_argv(argv: Any) -> list[str]:
    """Admit one bounded native argv snapshot before command side effects."""

    if not isinstance(argv, list):
        raise ValueError("command argv must be a list")
    owned: list[str] = []
    aggregate_bytes = 0
    for index, raw in enumerate(list.__iter__(argv)):
        if index >= MAX_COMMAND_ARGV_COUNT:
            raise ValueError(
                f"command argv exceeds {MAX_COMMAND_ARGV_COUNT} arguments"
            )
        try:
            argument = _owned_plain_text(
                raw, maximum_characters=MAX_COMMAND_ARG_BYTES
            )
        except ValueError as exc:
            raise ValueError(
                "command argv must contain only bounded strings"
            ) from exc
        if not argument:
            raise ValueError(
                "command argv must contain at least one non-empty argument"
            )
        if "\x00" in argument:
            raise ValueError("command argv must not contain embedded NUL")
        try:
            argument_bytes = len(argument.encode("utf-8"))
        except UnicodeEncodeError as exc:
            raise ValueError("command argv must contain valid UTF-8") from exc
        if argument_bytes > MAX_COMMAND_ARG_BYTES:
            raise ValueError(
                "command argv argument exceeds "
                f"{MAX_COMMAND_ARG_BYTES} UTF-8 bytes"
            )
        aggregate_bytes += argument_bytes
        if aggregate_bytes > MAX_COMMAND_ARGV_BYTES:
            raise ValueError(
                f"command argv exceeds {MAX_COMMAND_ARGV_BYTES} UTF-8 bytes"
            )
        owned.append(argument)
    if not owned:
        raise ValueError("command argv must contain at least one non-empty argument")
    return owned


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
        self.complete = False

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
            self.complete = self.error is None

    def accept_complete(self, content: bytes) -> None:
        self._accept(content)
        self.collector.feed(self.sanitizer.finish())
        if self.raw_writer is not None:
            self.raw_writer.finish()
        self.complete = True

    @property
    def stream_error(self) -> BaseException | None:
        if self.raw_writer is None:
            return None
        return self.raw_writer.error


def _drain_pipe_capture(capture: _PipeCapture, pipe: Any) -> None:
    """Keep exceptions raised outside ``_PipeCapture.drain`` observable."""

    try:
        capture.drain(pipe)
    except BaseException as exc:
        capture.error = capture.error or exc
        try:
            pipe.close()
        except BaseException as close_exc:
            capture.error = capture.error or close_exc


class _CommandCleanupFailure(RuntimeError):
    """The owned child group could not be quiesced without escalation."""


class _ChildSignalController:
    """Own wrapper signals while a POSIX child process group is active."""

    _FORWARDED_SIGNALS = (signal.SIGINT, signal.SIGTERM)

    def __init__(self) -> None:
        self.child: subprocess.Popen | None = None
        self.process_group_id: int | None = None
        self.received_signal: int | None = None
        self._deadline: float | None = None
        self._kill_sent = False
        self._outcome_frozen = False
        self._previous_handlers: dict[int, Any] = {}
        self.forward_errors: list[BaseException] = []
        self._group_enabled = os.name == "posix" and hasattr(os, "killpg")
        self._enabled = (
            self._group_enabled
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
        if self._group_enabled:
            self.process_group_id = child.pid
            if child.pid <= 1 or child.pid == os.getpgrp():
                raise RuntimeError("new-session child process group is unsafe")
            try:
                observed_group = os.getpgid(child.pid)
                observed_session = os.getsid(child.pid)
            except ProcessLookupError:
                if child.poll() is None:
                    raise RuntimeError(
                        "new-session child identity disappeared before ownership"
                    )
            else:
                if observed_group != child.pid or observed_session != child.pid:
                    raise RuntimeError(
                        "new-session child did not own its process group and session"
                    )
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
            self._send_owned_process_group(signal_number)
        except ProcessLookupError:
            pass
        except BaseException as exc:
            self.forward_errors.append(exc)

    def _confirm_live_leader_identity(self) -> None:
        if (
            not self._group_enabled
            or self.child is None
            or self.process_group_id is None
            or self.child.poll() is not None
        ):
            return
        try:
            observed_group = os.getpgid(self.child.pid)
            observed_session = os.getsid(self.child.pid)
        except ProcessLookupError:
            if self.child.poll() is None:
                raise RuntimeError(
                    "live child identity disappeared before group signal"
                )
            return
        if (
            observed_group != self.process_group_id
            or observed_session != self.process_group_id
        ):
            raise RuntimeError(
                "refusing to signal a reused child process-group identity"
            )

    def _send_owned_process_group(self, signal_number: int) -> None:
        if self.child is None:
            raise RuntimeError("signal controller has no child")
        if self._group_enabled:
            if self.process_group_id is None:
                raise RuntimeError("signal controller has no owned process group")
            self._confirm_live_leader_identity()
            os.killpg(self.process_group_id, signal_number)
            return
        self.child.send_signal(signal_number)

    def _owned_process_group_exists(self) -> bool:
        if self.child is None:
            return False
        if not self._group_enabled:
            return self.child.poll() is None
        if self.process_group_id is None:
            raise RuntimeError("signal controller has no owned process group")
        try:
            os.killpg(self.process_group_id, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def _send_cleanup_signal(self, *, force: bool) -> None:
        if self.child is None:
            raise RuntimeError("signal controller has no child")
        if self._group_enabled:
            self._send_owned_process_group(
                signal.SIGKILL if force else signal.SIGTERM
            )
        elif force:
            self.child.kill()
        else:
            self.child.terminate()

    def _wait_for_owned_group_exit(self, deadline: float) -> bool:
        while True:
            if self.child is not None:
                self.child.poll()
            if not self._owned_process_group_exists():
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(_CHILD_WAIT_POLL_SECONDS, remaining))

    def _reap_child_before(self, deadline: float) -> None:
        if self.child is None or self.child.poll() is not None:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("child process was not reaped before cleanup deadline")
        try:
            self.child.wait(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                "child process was not reaped before cleanup deadline"
            ) from exc

    def terminate_owned_process_group(self) -> bool:
        """TERM, then KILL if needed, and reap the exact spawned child.

        Return whether SIGKILL escalation was required. A caller may treat that
        bounded escalation as a runner cleanup failure even when it succeeded.
        """

        if self.child is None:
            raise RuntimeError("signal controller has no child")
        if not self._owned_process_group_exists():
            self._reap_child_before(
                time.monotonic() + _CHILD_SIGNAL_GRACE_SECONDS
            )
            return False

        cleanup_failures: list[BaseException] = []
        try:
            self._send_cleanup_signal(force=False)
        except ProcessLookupError:
            pass
        except BaseException as exc:
            cleanup_failures.append(exc)
        term_deadline = time.monotonic() + _CHILD_SIGNAL_GRACE_SECONDS
        try:
            group_exited = self._wait_for_owned_group_exit(term_deadline)
        except BaseException as exc:
            cleanup_failures.append(exc)
            group_exited = False
        if group_exited:
            try:
                self._reap_child_before(term_deadline)
            except BaseException as exc:
                cleanup_failures.append(exc)
            if cleanup_failures:
                raise _CommandCleanupFailure(
                    "owned process-group TERM cleanup failed"
                ) from cleanup_failures[0]
            return False

        try:
            self._send_cleanup_signal(force=True)
        except ProcessLookupError:
            pass
        except BaseException as exc:
            cleanup_failures.append(exc)
        kill_deadline = time.monotonic() + _CHILD_SIGNAL_GRACE_SECONDS
        try:
            group_exited = self._wait_for_owned_group_exit(kill_deadline)
        except BaseException as exc:
            cleanup_failures.append(exc)
            group_exited = False
        try:
            self._reap_child_before(kill_deadline)
        except BaseException as exc:
            cleanup_failures.append(exc)
        if not group_exited:
            cleanup_failures.append(
                RuntimeError(
                    "owned process group survived bounded SIGKILL cleanup"
                )
            )
        if cleanup_failures:
            raise _CommandCleanupFailure(
                "owned process-group SIGKILL cleanup failed"
            ) from cleanup_failures[0]
        return True

    def _service_escalation(self) -> None:
        if (
            self.received_signal is not None
            and self._deadline is not None
            and not self._kill_sent
            and time.monotonic() >= self._deadline
        ):
            self._kill_sent = True
            self._send_to_group(signal.SIGKILL)

    def wait_for_completion(
        self,
        readers: tuple[threading.Thread, ...],
        captures: tuple[_PipeCapture, ...] = (),
    ) -> int:
        del readers
        if self.child is None:
            raise RuntimeError("signal controller has no child")
        while True:
            for capture in captures:
                if capture.stream_error is not None:
                    raise capture.stream_error
                if capture.error is not None:
                    raise capture.error
            child_status = self.child.poll()
            if child_status is not None:
                return child_status
            if self._enabled:
                self._service_escalation()
                if self.forward_errors:
                    raise RuntimeError(
                        "failed to signal the owned child process group"
                    ) from self.forward_errors[0]
            time.sleep(_CHILD_WAIT_POLL_SECONDS)

    @property
    def kill_sent(self) -> bool:
        return self._kill_sent

    def freeze_outcome(self, child_status: int) -> int:
        self._outcome_frozen = True
        if self.received_signal is not None:
            return -self.received_signal
        return child_status

    def freeze_runner_failure(self) -> None:
        self._outcome_frozen = True


def _close_child_pipe(pipe: Any, failures: list[BaseException]) -> None:
    if pipe is None or getattr(pipe, "closed", False):
        return
    try:
        pipe.close()
    except BaseException as exc:
        failures.append(exc)


def _cleanup_spawned_child(
    child: subprocess.Popen,
    reader_bindings: tuple[tuple[threading.Thread, Any], ...],
    started_readers: tuple[threading.Thread, ...],
    signal_controller: _ChildSignalController,
) -> bool:
    """Bound cleanup for every exception after a successful ``Popen``."""

    failures: list[BaseException] = []
    started_ids = {id(reader) for reader in started_readers}
    for reader, pipe in reader_bindings:
        if id(reader) not in started_ids:
            _close_child_pipe(pipe, failures)

    escalated = False
    try:
        escalated = signal_controller.terminate_owned_process_group()
    except BaseException as exc:
        failures.append(exc)

    if failures and child.poll() is None:
        try:
            child.kill()
            child.wait(timeout=_CHILD_SIGNAL_GRACE_SECONDS)
        except BaseException as exc:
            failures.append(exc)

    join_deadline = time.monotonic() + _CHILD_SIGNAL_GRACE_SECONDS
    for reader in started_readers:
        try:
            reader.join(timeout=max(0.0, join_deadline - time.monotonic()))
        except BaseException as exc:
            failures.append(exc)

    for pipe in (child.stdout, child.stderr):
        _close_child_pipe(pipe, failures)

    retry_deadline = time.monotonic() + _CHILD_SIGNAL_GRACE_SECONDS
    for reader in started_readers:
        try:
            if reader.is_alive():
                reader.join(
                    timeout=max(0.0, retry_deadline - time.monotonic())
                )
            if reader.is_alive():
                failures.append(
                    RuntimeError(f"reader thread {reader.name!r} did not stop")
                )
        except BaseException as exc:
            failures.append(exc)

    if child.poll() is None:
        try:
            child.kill()
            child.wait(timeout=_CHILD_SIGNAL_GRACE_SECONDS)
        except BaseException as exc:
            failures.append(exc)

    if failures:
        kinds = ", ".join(type(failure).__name__ for failure in failures)
        raise _CommandCleanupFailure(
            f"command child cleanup failed ({kinds})"
        ) from failures[0]
    return escalated


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


def _preflight_started_and_terminal_events(
    root: Path,
    phase: str,
    expected_next_sequence: int,
    *,
    roots: dict[str, str],
    secrets: Any,
    terminal_status: str | None = None,
    terminal_metadata: dict[str, Any] | None = None,
    reserve_maximum_terminal_line: bool = False,
) -> None:
    """Prove both lifecycle records fit before a command can have effects."""

    events = _read_bootstrap_events(root)
    if len(events) + 1 != expected_next_sequence:
        raise RuntimeError("command event sequence changed while locked")
    _started, started_content, started_events = _event_stream_candidate(
        root,
        phase,
        "started",
        events=events,
        _roots_snapshot=roots,
        _secrets_snapshot=secrets,
    )
    if reserve_maximum_terminal_line:
        if terminal_status is not None or terminal_metadata is not None:
            raise RuntimeError("maximum terminal reservation cannot be exact")
        reserved_size = len(started_content) + MAX_JSONL_LINE_BYTES + 1
        if reserved_size > MAX_LIFECYCLE_EVENT_STREAM_BYTES:
            raise ValueError(
                "bootstrap event stream exceeds "
                f"{MAX_LIFECYCLE_EVENT_STREAM_BYTES} bytes"
            )
        return
    if terminal_status is None or terminal_metadata is None:
        raise RuntimeError("exact terminal reservation is incomplete")
    _event_stream_candidate(
        root,
        phase,
        terminal_status,
        events=started_events,
        _roots_snapshot=roots,
        _secrets_snapshot=secrets,
        **terminal_metadata,
    )


def _runner_failure_summary(
    name: str,
    error: BaseException,
    *,
    roots: dict[str, str],
    secrets: list[str],
) -> str:
    try:
        detail = str(error)
    except BaseException:
        detail = "unprintable failure"
    prefix = (
        f"Runner failed while supervising command {name}: "
        f"{type(error).__name__}: "
    )
    sanitizer = StreamingSanitizer(roots=roots, secrets=secrets)
    stored = bytearray()
    for part in (prefix, detail):
        for offset in range(0, len(part), 4096):
            sanitized = sanitizer.feed(
                part[offset : offset + 4096].encode(
                    "utf-8", errors="replace"
                )
            )
            remaining = MAX_COMMAND_ARG_BYTES - len(stored)
            if len(sanitized) >= remaining:
                stored.extend(sanitized[:remaining])
                return bytes(stored).decode("utf-8", errors="ignore")
            stored.extend(sanitized)
    sanitized = sanitizer.finish()
    stored.extend(sanitized[: MAX_COMMAND_ARG_BYTES - len(stored)])
    return bytes(stored).decode("utf-8", errors="ignore")


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
    name = _own_command_scalar(
        name, diagnostic="command name must be a safe slug"
    )
    phase = _own_command_scalar(
        phase, diagnostic="command phase must be a declared phase"
    )
    failure_code = _own_command_scalar(
        failure_code, diagnostic="failure code must be non-empty"
    )
    argv = _own_command_argv(argv)
    _validate_command_name(name)
    if phase not in PHASES:
        raise ValueError("command phase must be a declared phase")
    if not isinstance(failure_code, str) or not failure_code:
        raise ValueError("failure code must be non-empty")
    if failure_code not in ERROR_CLASSIFICATION:
        raise ValueError("failure code must be registered")
    if failure_code in SUPERVISOR_ONLY_FAILURE_CODES:
        raise ValueError("failure code is reserved for command supervision")
    if _evidence_exists(root / "run-summary.json"):
        raise ValueError("cannot run a command after finalization")
    commands_root = root / "commands"
    if not _evidence_is_dir(commands_root) or _evidence_is_symlink(commands_root):
        raise ValueError("attempt commands directory is missing or unsafe")

    roots = _sanitization_roots(root)
    secrets = _collect_secret_values()
    sanitized_argv = _sanitize_argv(argv, roots=roots, secrets=secrets)
    next_sequence = len(_read_bootstrap_events(root)) + 1
    stem = f"{next_sequence:06d}-{name}"
    stdout_relative = f"commands/{stem}.stdout.log"
    stderr_relative = f"commands/{stem}.stderr.log"
    metadata_relative = f"commands/{stem}.json"
    maximum_counter = 10**20
    maximum_failure_code = max(
        failure_code,
        "runner.command_supervisor_lost",
        "runner.capture_failed",
        "runner.cleanup_failed",
        key=lambda candidate: len(candidate.encode("utf-8")),
    )
    def preflight_stream(path: str) -> dict[str, Any]:
        return {
            "path": path,
            "originalBytes": maximum_counter,
            "sanitizedBytes": maximum_counter,
            "storedBytes": _LOG_LIMIT,
            "truncated": True,
        }
    preflight_metadata = {
        "schemaVersion": 1,
        "source": "subprocess",
        "argv": sanitized_argv,
        "phase": phase,
        "name": name,
        "failureCode": maximum_failure_code,
        "configuredFailureCode": failure_code,
        "captureComplete": False,
        "supervisorFailure": False,
        "exitStatus": maximum_counter,
        "signal": maximum_counter,
        "stdout": preflight_stream(stdout_relative),
        "stderr": preflight_stream(stderr_relative),
    }
    bounded_io._json_bytes_bounded(
        preflight_metadata, label="command metadata"
    )
    _preflight_started_and_terminal_events(
        root,
        phase,
        next_sequence,
        roots=roots,
        secrets=secrets,
        reserve_maximum_terminal_line=True,
    )
    started = _append_event_during_lifecycle(
        root,
        phase,
        "started",
        _roots_snapshot=roots,
        _secrets_snapshot=secrets,
    )
    if started["seq"] != next_sequence:
        raise RuntimeError("command event sequence changed while locked")

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
    runner_error: BaseException | None = None
    runner_traceback: Any = None
    runner_cause: BaseException | None = None
    capture_failed = False
    terminal_failure_code = failure_code
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
        reader_bindings_list: list[tuple[threading.Thread, Any]] = []
        started_readers_list: list[threading.Thread] = []
        try:
            signal_controller.attach(child)
            stdout_reader = threading.Thread(
                target=_drain_pipe_capture,
                args=(stdout_capture, child.stdout),
                name=f"evidence-{name}-stdout",
                daemon=True,
            )
            reader_bindings_list.append((stdout_reader, child.stdout))
            stderr_reader = threading.Thread(
                target=_drain_pipe_capture,
                args=(stderr_capture, child.stderr),
                name=f"evidence-{name}-stderr",
                daemon=True,
            )
            reader_bindings_list.append((stderr_reader, child.stderr))
            readers = (stdout_reader, stderr_reader)
            for reader in readers:
                reader.start()
                started_readers_list.append(reader)
            return_code = signal_controller.wait_for_completion(
                readers, (stdout_capture, stderr_capture)
            )
            cleanup_escalated = (
                signal_controller.terminate_owned_process_group()
            )
            join_deadline = time.monotonic() + _CHILD_SIGNAL_GRACE_SECONDS
            for reader in readers:
                reader.join(
                    timeout=max(0.0, join_deadline - time.monotonic())
                )
            if any(reader.is_alive() for reader in readers):
                raise RuntimeError(
                    "command reader did not stop after process-group cleanup"
                )
            if cleanup_escalated or signal_controller.kill_sent:
                raise _CommandCleanupFailure(
                    "foreground process-group cleanup required SIGKILL"
                )
            reader_errors = [
                capture.error
                for capture in (stdout_capture, stderr_capture)
                if capture.error is not None
            ]
            if reader_errors:
                raise reader_errors[0]
            stream_errors = [
                capture.stream_error
                for capture in (stdout_capture, stderr_capture)
                if capture.stream_error is not None
            ]
            if stream_errors:
                capture_failed = True
                raise stream_errors[0]
        except BaseException as exc:
            capture_failed = any(
                capture.stream_error is exc
                for capture in (stdout_capture, stderr_capture)
            )
            runner_error = exc
            runner_traceback = exc.__traceback__
            cleanup_failed = isinstance(exc, _CommandCleanupFailure)
            cleanup_escalated = False
            try:
                cleanup_escalated = _cleanup_spawned_child(
                    child,
                    tuple(reader_bindings_list),
                    tuple(started_readers_list),
                    signal_controller,
                )
            except BaseException as cleanup_exc:
                cleanup_failed = True
                if hasattr(cleanup_exc, "add_note"):
                    cleanup_exc.add_note(
                        "while handling original supervision failure "
                        f"{type(exc).__name__}"
                    )
                runner_error = cleanup_exc
                runner_traceback = cleanup_exc.__traceback__
                runner_cause = exc
            else:
                if cleanup_escalated:
                    cleanup_failed = True
                    runner_error = _CommandCleanupFailure(
                        "command process cleanup required SIGKILL after "
                        f"{type(exc).__name__}"
                    )
                    runner_traceback = None
                    runner_cause = exc
            terminal_failure_code = (
                "runner.cleanup_failed"
                if cleanup_failed
                else "runner.capture_failed"
                if capture_failed
                else "runner.command_supervisor_lost"
            )
            return_code = child.poll()

    if runner_error is None:
        stream_errors = [
            capture.stream_error
            for capture in (stdout_capture, stderr_capture)
            if capture.stream_error is not None
        ]
        if stream_errors:
            runner_error = stream_errors[0]
            runner_traceback = runner_error.__traceback__
            terminal_failure_code = "runner.capture_failed"

    if runner_error is None:
        return_code = signal_controller.freeze_outcome(return_code)
    else:
        signal_controller.freeze_runner_failure()

    stored_stdout, sanitized_stdout_size, stdout_truncated = (
        stdout_capture.collector.finish()
    )
    stored_stderr, sanitized_stderr_size, stderr_truncated = (
        stderr_capture.collector.finish()
    )
    exit_status = (
        return_code
        if isinstance(return_code, int) and return_code >= 0
        else None
    )
    signal_number = (
        -return_code
        if isinstance(return_code, int) and return_code < 0
        else None
    )
    capture_complete = (
        stdout_capture.complete
        and stderr_capture.complete
        and stdout_capture.stream_error is None
        and stderr_capture.stream_error is None
    )
    metadata = {
        "schemaVersion": 1,
        "source": "subprocess",
        "argv": sanitized_argv,
        "phase": phase,
        "name": name,
        "failureCode": terminal_failure_code,
        "configuredFailureCode": failure_code,
        "captureComplete": capture_complete,
        "supervisorFailure": runner_error is not None,
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
    metadata_content = bounded_io._json_bytes_bounded(
        metadata, label="command metadata"
    )
    _atomic_write_bytes(root / stdout_relative, stored_stdout)
    _atomic_write_bytes(root / stderr_relative, stored_stderr)
    _atomic_write_bytes(root / metadata_relative, metadata_content)

    if runner_error is not None:
        event_status = "failed"
        event_metadata = {
            "errorCode": terminal_failure_code,
            "summary": _runner_failure_summary(
                name, runner_error, roots=roots, secrets=secrets
            ),
            "command": metadata_relative,
            "artifact": metadata_relative,
        }
        if exit_status is not None:
            event_metadata["commandStatus"] = exit_status
    elif return_code == 0:
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
    _append_event_during_lifecycle(
        root,
        phase,
        event_status,
        _roots_snapshot=roots,
        _secrets_snapshot=secrets,
        **event_metadata,
    )

    try:
        if not capture_stdout:
            _replay_bytes(stdout_stream, stored_stdout)
        _replay_bytes(stderr_stream, stored_stderr)
    except BaseException:
        if runner_error is None:
            raise
    if runner_error is not None:
        if runner_cause is not None:
            raise runner_error from runner_cause
        raise runner_error.with_traceback(runner_traceback)
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
    remediation: str,
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
    if failure_code in SUPERVISOR_ONLY_FAILURE_CODES:
        raise ValueError("failure code is reserved for command supervision")
    if outcome == "cancelled" and failure_code != "run.cancelled":
        raise ValueError("cancelled external outcome requires run.cancelled")
    if outcome == "failure" and failure_code == "run.cancelled":
        raise ValueError("failed external outcome cannot use run.cancelled")
    if not isinstance(remediation, str) or not remediation.strip():
        raise ValueError("external remediation must be a non-empty string")
    roots = _sanitization_roots(root)
    secrets = _collect_secret_values()
    sanitized_remediation = sanitize_text(
        remediation,
        roots=roots,
        secrets=secrets,
    )
    if not sanitized_remediation.strip():
        raise ValueError("external remediation must be non-empty after sanitization")
    remediation_bytes = _utf8_byte_length(sanitized_remediation)
    if remediation_bytes is None:
        raise ValueError("external remediation must contain valid UTF-8")
    if remediation_bytes > MAX_EXTERNAL_REMEDIATION_BYTES:
        raise ValueError(
            "external remediation exceeds maximum "
            f"({MAX_EXTERNAL_REMEDIATION_BYTES} UTF-8 bytes)"
        )
    if _evidence_exists(root / "run-summary.json"):
        raise ValueError("cannot record an external command after finalization")
    commands_root = root / "commands"
    if not _evidence_is_dir(commands_root) or _evidence_is_symlink(commands_root):
        raise ValueError("attempt commands directory is missing or unsafe")

    next_sequence = len(_read_bootstrap_events(root)) + 1
    stem = f"{next_sequence:06d}-{name}"
    stdout_relative = f"commands/{stem}.stdout.log"
    stderr_relative = f"commands/{stem}.stderr.log"
    metadata_relative = f"commands/{stem}.json"
    stdout_content = (
        "synthetic external command record. Hosted log content was not captured; "
        "consult the workflow provider for authoritative output.\n"
    ).encode("utf-8")
    stderr_content = (
        f"synthetic outcome: {outcome}. This record does not claim hosted log capture.\n"
        f"remediation: {sanitized_remediation}\n"
    ).encode("utf-8")
    metadata = {
        "schemaVersion": 1,
        "source": "github-action",
        "argv": [],
        "phase": phase,
        "name": name,
        "failureCode": failure_code,
        "outcome": outcome,
        "remediation": sanitized_remediation,
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
    metadata_content = bounded_io._json_bytes_bounded(
        metadata, label="command metadata"
    )
    event_status = {
        "success": "passed",
        "failure": "failed",
        "cancelled": "cancelled",
    }[outcome]
    event_metadata = {"command": metadata_relative, "artifact": metadata_relative}
    if outcome != "success":
        event_metadata.update(
            errorCode=failure_code,
            summary=sanitized_remediation,
        )
    _preflight_started_and_terminal_events(
        root,
        phase,
        next_sequence,
        roots=roots,
        secrets=secrets,
        terminal_status=event_status,
        terminal_metadata=event_metadata,
    )
    started = _append_event_during_lifecycle(
        root,
        phase,
        "started",
        _roots_snapshot=roots,
        _secrets_snapshot=secrets,
    )
    if started["seq"] != next_sequence:
        raise RuntimeError("external command event sequence changed while locked")
    _atomic_write_bytes(root / stdout_relative, stdout_content)
    _atomic_write_bytes(root / stderr_relative, stderr_content)
    _atomic_write_bytes(root / metadata_relative, metadata_content)
    _append_event_during_lifecycle(
        root,
        phase,
        event_status,
        _roots_snapshot=roots,
        _secrets_snapshot=secrets,
        **event_metadata,
    )
    return {"success": 0, "failure": 1, "cancelled": 130}[outcome]


@_rooted_attempt_mutation
def _record_external(
    root: Path,
    phase: str,
    name: str,
    outcome: str,
    failure_code: str,
    remediation: str,
) -> int:
    root = Path(root)
    _recover_pending_transactions(_publication_root_for_attempt(root))
    with _exclusive_lock(root / ".lifecycle.lock"):
        return _record_external_during_lifecycle(
            root, phase, name, outcome, failure_code, remediation
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
