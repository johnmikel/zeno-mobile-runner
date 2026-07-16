"""Trusted process-group anchor and platform-stable process observations."""

from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import select
import signal
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

from . import command_state, safe_io
from .sanitization import StreamingSanitizer


_PROTOCOL_LIMIT = 64 * 1024
SANITIZED_STREAM_LIMIT = 10 * 1024 * 1024
RAW_CAPTURE_LIMIT = 1 * 1024 * 1024
CAPTURE_ENVELOPE_LIMIT = 3 * 1024 * 1024
_STREAM_LIMIT = SANITIZED_STREAM_LIMIT
_STREAM_HALF = SANITIZED_STREAM_LIMIT // 2
_SETTLEMENT_SECONDS = 0.05


class CaptureFailure(RuntimeError):
    """A raw capture or its anonymous transport failed closed."""


def _linux_start_ticks_from_stat(content: str) -> str:
    """Return proc stat field 22 without being confused by ')' in comm."""

    if not isinstance(content, str):
        raise ValueError("process stat record must be text")
    close = content.rfind(")")
    if close < 1 or close + 2 > len(content) or content[close + 1] != " ":
        raise ValueError("process stat record is malformed")
    fields = content[close + 2 :].split()
    if len(fields) <= 19 or not fields[19].isdigit():
        raise ValueError("process stat start ticks are malformed")
    return fields[19]


def _linux_parent_pid_from_stat(content: str) -> int:
    """Return proc stat field 4 without trusting the parenthesized name."""

    if not isinstance(content, str):
        raise ValueError("process stat record must be text")
    close = content.rfind(")")
    if close < 1 or close + 2 > len(content) or content[close + 1] != " ":
        raise ValueError("process stat record is malformed")
    fields = content[close + 2 :].split()
    if len(fields) <= 1 or not fields[1].isdigit():
        raise ValueError("process stat parent pid is malformed")
    parent = int(fields[1])
    if parent < 0:
        raise ValueError("process stat parent pid is invalid")
    return parent


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class ProcessBackend:
    """Fail-closed Linux/macOS process identity and group probes."""

    def __init__(self) -> None:
        self._platform = sys.platform
        self._boot_id: str | None = None
        self._libproc: Any = None

    def _linux_identity(self, pid: int) -> str:
        if self._boot_id is None:
            boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(
                encoding="ascii"
            ).strip()
            if not boot_id or any(character.isspace() for character in boot_id):
                raise ValueError("Linux boot identity is malformed")
            self._boot_id = boot_id
        try:
            stat_content = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        except FileNotFoundError as exc:
            raise ProcessLookupError(pid) from exc
        return f"linux:{self._boot_id}:{_linux_start_ticks_from_stat(stat_content)}"

    def _macos_identity(self, pid: int) -> str:
        if self._libproc is None:
            library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            library.proc_pidinfo.argtypes = [
                ctypes.c_int,
                ctypes.c_int,
                ctypes.c_uint64,
                ctypes.c_void_p,
                ctypes.c_int,
            ]
            library.proc_pidinfo.restype = ctypes.c_int
            self._libproc = library
        info = _ProcBSDInfo()
        size = ctypes.sizeof(info)
        result = self._libproc.proc_pidinfo(
            pid, 3, 0, ctypes.byref(info), size
        )
        if result == 0:
            error = ctypes.get_errno()
            if error in (errno.ESRCH, errno.ENOENT, 0):
                raise ProcessLookupError(pid)
            raise OSError(error, os.strerror(error))
        if result != size or info.pbi_pid != pid:
            raise ValueError("macOS process identity observation is incomplete")
        return f"macos:{info.pbi_start_tvsec}:{info.pbi_start_tvusec}"

    def current_identity(self, pid: int) -> str:
        if type(pid) is not int or pid < 1:
            raise ValueError("process pid must be positive")
        if self._platform.startswith("linux"):
            return self._linux_identity(pid)
        if self._platform == "darwin":
            return self._macos_identity(pid)
        raise RuntimeError("stable process identity is unavailable on this platform")

    def parent_pid(self, pid: int) -> int:
        """Observe one process parent using the same platform identity source."""

        if type(pid) is not int or pid < 1:
            raise ValueError("process pid must be positive")
        if self._platform.startswith("linux"):
            try:
                content = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
            except FileNotFoundError as exc:
                raise ProcessLookupError(pid) from exc
            return _linux_parent_pid_from_stat(content)
        if self._platform == "darwin":
            if self._libproc is None:
                self._macos_identity(pid)
            info = _ProcBSDInfo()
            size = ctypes.sizeof(info)
            result = self._libproc.proc_pidinfo(
                pid, 3, 0, ctypes.byref(info), size
            )
            if result == 0:
                error = ctypes.get_errno()
                if error in (errno.ESRCH, errno.ENOENT, 0):
                    raise ProcessLookupError(pid)
                raise OSError(error, os.strerror(error))
            if result != size or info.pbi_pid != pid:
                raise ValueError("macOS parent process observation is incomplete")
            return int(info.pbi_ppid)
        raise RuntimeError("process ancestry is unavailable on this platform")

    def predecessor_absent(self, pid: int, birth_identity: str) -> bool:
        if not isinstance(birth_identity, str) or not birth_identity:
            raise ValueError("process birth identity must be non-empty")
        try:
            current = self.current_identity(pid)
        except ProcessLookupError:
            return True
        return current != birth_identity

    def group_probe(self, pgid: int) -> str:
        if type(pgid) is not int or pgid < 1:
            raise ValueError("process group id must be positive")
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return "absent"
        except PermissionError:
            return "present"
        return "present"

    def group_members(self, pgid: int) -> list[int]:
        if type(pgid) is not int or pgid < 1:
            raise ValueError("process group id must be positive")
        members: list[int] = []
        if self._platform.startswith("linux"):
            observed = 0
            with os.scandir("/proc") as entries:
                for entry in entries:
                    if not entry.name.isdigit():
                        continue
                    observed += 1
                    if observed > 131072:
                        raise ValueError("Linux process enumeration exceeds its limit")
                    pid = int(entry.name)
                    try:
                        content = Path(entry.path, "stat").read_text(
                            encoding="ascii"
                        )
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                    close = content.rfind(")")
                    fields = content[close + 2 :].split() if close >= 1 else []
                    if len(fields) <= 2 or not fields[2].isdigit():
                        raise ValueError("Linux process group observation is malformed")
                    if int(fields[2]) == pgid:
                        members.append(pid)
            return sorted(set(members))
        if self._platform == "darwin":
            if self._libproc is None:
                self._macos_identity(os.getpid())
            self._libproc.proc_listpids.argtypes = [
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_void_p,
                ctypes.c_int,
            ]
            self._libproc.proc_listpids.restype = ctypes.c_int
            capacity = 131072
            buffer = (ctypes.c_int * capacity)()
            size = ctypes.sizeof(buffer)
            result = self._libproc.proc_listpids(1, 0, buffer, size)
            if result <= 0 or result >= size:
                raise OSError("macOS process enumeration failed")
            for index in range(result // ctypes.sizeof(ctypes.c_int)):
                pid = int(buffer[index])
                if pid < 1:
                    continue
                try:
                    if os.getpgid(pid) == pgid:
                        members.append(pid)
                except (ProcessLookupError, PermissionError):
                    continue
            return sorted(set(members))
        raise RuntimeError("process group membership is unavailable")


def prove_group_absent(
    anchor: dict[str, Any],
    *,
    group_lease_free: bool,
    backend: Any,
    settle: Callable[[], None] | None = None,
) -> bool:
    """Require lease, birth identity, and two settled ESRCH-equivalent probes."""

    if group_lease_free is not True:
        raise TimeoutError("command group lease is still held")
    required = {"pid", "birthIdentity", "sid", "pgid"}
    if not isinstance(anchor, dict) or not required.issubset(anchor):
        raise ValueError("command anchor observation is incomplete")
    if anchor["pid"] != anchor["sid"] or anchor["pid"] != anchor["pgid"]:
        raise ValueError("command anchor identity is inconsistent")
    if backend.predecessor_absent(
        anchor["pid"], anchor["birthIdentity"]
    ) is not True:
        raise ValueError("command anchor identity is still present")
    first = backend.group_probe(anchor["pgid"])
    if first != "absent":
        raise ValueError("command process group is still present")
    if settle is None:
        time.sleep(_SETTLEMENT_SECONDS)
    else:
        settle()
    second = backend.group_probe(anchor["pgid"])
    if second != "absent":
        raise ValueError("command process group absence was not stable")
    return True


def _canonical_message(value: Any) -> bytes:
    try:
        content = (
            json.dumps(
                value,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        raise ValueError("anchor protocol message is not encodable") from exc
    if len(content) > _PROTOCOL_LIMIT:
        raise ValueError("anchor protocol message exceeds its limit")
    return content


def _capture_payload(content: bytes | None) -> dict[str, Any] | None:
    if content is None:
        return None
    if type(content) is not bytes:
        raise CaptureFailure("raw capture payload must be bytes")
    if len(content) > RAW_CAPTURE_LIMIT:
        raise CaptureFailure("raw capture payload exceeds its limit")
    if b"\x00" in content:
        raise CaptureFailure("raw capture payload contains NUL")
    return {
        "base64": base64.b64encode(content).decode("ascii"),
        "decodedBytes": len(content),
        "sha256": "sha256:" + hashlib.sha256(content).hexdigest(),
    }


def encode_capture_envelope(
    command_id: str,
    shell_status: int,
    *,
    stdout: bytes | None,
    stderr: bytes | None,
    capture_complete: bool,
) -> bytes:
    """Encode the only raw-output representation allowed across the CLI boundary."""

    try:
        command_id = command_state._identifier(command_id, "commandId")
    except ValueError as exc:
        raise CaptureFailure("capture envelope commandId is invalid") from exc
    if type(shell_status) is not int or not 0 <= shell_status <= 255:
        raise CaptureFailure("capture envelope shellStatus is invalid")
    if type(capture_complete) is not bool:
        raise CaptureFailure("capture envelope captureComplete must be a boolean")
    if not capture_complete and (stdout is not None or stderr is not None):
        raise CaptureFailure("incomplete capture envelope cannot contain payloads")
    envelope = {
        "schemaVersion": 1,
        "commandId": command_id,
        "shellStatus": shell_status,
        "stdout": _capture_payload(stdout),
        "stderr": _capture_payload(stderr),
        "captureComplete": capture_complete,
    }
    try:
        content = json.dumps(
            envelope,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        raise CaptureFailure("capture envelope is not encodable") from exc
    if len(content) > CAPTURE_ENVELOPE_LIMIT:
        raise CaptureFailure("capture envelope exceeds its limit")
    return content


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise CaptureFailure("capture envelope contains a duplicate field")
        value[key] = item
    return value


def _decode_capture_payload(value: Any, label: str) -> bytes | None:
    if value is None:
        return None
    if type(value) is not dict or set(value) != {
        "base64",
        "decodedBytes",
        "sha256",
    }:
        raise CaptureFailure(f"capture envelope {label} fields are not exact")
    encoded = value["base64"]
    decoded_bytes = value["decodedBytes"]
    digest = value["sha256"]
    if type(encoded) is not str or not encoded.isascii():
        raise CaptureFailure(f"capture envelope {label} base64 is invalid")
    if (
        type(decoded_bytes) is not int
        or not 0 <= decoded_bytes <= RAW_CAPTURE_LIMIT
    ):
        raise CaptureFailure(f"capture envelope {label} length is invalid")
    if (
        type(digest) is not str
        or len(digest) != 71
        or not digest.startswith("sha256:")
        or any(character not in "0123456789abcdef" for character in digest[7:])
    ):
        raise CaptureFailure(f"capture envelope {label} digest is invalid")
    try:
        content = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise CaptureFailure(f"capture envelope {label} base64 is malformed") from exc
    if len(content) != decoded_bytes:
        raise CaptureFailure(f"capture envelope {label} length disagrees")
    if b"\x00" in content:
        raise CaptureFailure(f"capture envelope {label} contains NUL")
    if digest != "sha256:" + hashlib.sha256(content).hexdigest():
        raise CaptureFailure(f"capture envelope {label} digest disagrees")
    return content


def decode_capture_envelope(
    content: bytes, *, expected_command_id: str
) -> dict[str, Any]:
    """Strictly decode and verify a bounded capture envelope."""

    if type(content) is not bytes or not content:
        raise CaptureFailure("capture envelope must be non-empty bytes")
    if len(content) > CAPTURE_ENVELOPE_LIMIT:
        raise CaptureFailure("capture envelope exceeds its limit")
    try:
        content.decode("ascii")
        value = json.loads(content, object_pairs_hook=_unique_json_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureFailure("capture envelope is malformed ASCII JSON") from exc
    expected_fields = {
        "schemaVersion",
        "commandId",
        "shellStatus",
        "stdout",
        "stderr",
        "captureComplete",
    }
    if type(value) is not dict or set(value) != expected_fields:
        raise CaptureFailure("capture envelope fields are not exact")
    if value["schemaVersion"] != 1 or type(value["schemaVersion"]) is not int:
        raise CaptureFailure("capture envelope schemaVersion is invalid")
    try:
        expected = command_state._identifier(
            expected_command_id, "expected commandId"
        )
    except ValueError as exc:
        raise CaptureFailure("expected capture commandId is invalid") from exc
    if value["commandId"] != expected:
        raise CaptureFailure("capture envelope commandId disagrees")
    shell_status = value["shellStatus"]
    if type(shell_status) is not int or not 0 <= shell_status <= 255:
        raise CaptureFailure("capture envelope shellStatus is invalid")
    if value["captureComplete"] is not True:
        raise CaptureFailure("capture envelope is incomplete")
    return {
        "schemaVersion": 1,
        "commandId": expected,
        "shellStatus": shell_status,
        "stdout": _decode_capture_payload(value["stdout"], "stdout"),
        "stderr": _decode_capture_payload(value["stderr"], "stderr"),
        "captureComplete": True,
    }


def _validate_capture_transport(descriptor: int) -> None:
    if type(descriptor) is not int or descriptor < 3:
        raise CaptureFailure("capture transport descriptor is invalid")
    try:
        metadata = os.fstat(descriptor)
    except OSError as exc:
        raise CaptureFailure("capture transport descriptor is not live") from exc
    if not (stat.S_ISFIFO(metadata.st_mode) or stat.S_ISSOCK(metadata.st_mode)):
        raise CaptureFailure("capture transport must be an anonymous pipe or socket")


def write_capture_envelope(descriptor: int, content: bytes) -> None:
    """Write one verified envelope only to a dedicated anonymous channel."""

    _validate_capture_transport(descriptor)
    if type(content) is not bytes or not content:
        raise CaptureFailure("capture envelope must be non-empty bytes")
    if len(content) > CAPTURE_ENVELOPE_LIMIT:
        raise CaptureFailure("capture envelope exceeds its limit")
    try:
        content.decode("ascii")
        _write_all(descriptor, content)
    except (UnicodeDecodeError, BrokenPipeError, OSError) as exc:
        raise CaptureFailure("capture envelope transport failed") from exc


def _write_all(descriptor: int, content: bytes) -> None:
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise BrokenPipeError("anchor protocol write made no progress")
        view = view[written:]


def _send_message(descriptor: int, value: Any) -> bool:
    try:
        _write_all(descriptor, _canonical_message(value))
    except (BrokenPipeError, OSError):
        return False
    return True


def _read_request(descriptor: int) -> dict[str, Any]:
    chunks = bytearray()
    while True:
        chunk = os.read(descriptor, min(8192, _PROTOCOL_LIMIT + 1 - len(chunks)))
        if not chunk:
            break
        chunks.extend(chunk)
        if len(chunks) > _PROTOCOL_LIMIT:
            raise ValueError("anchor request exceeds its limit")
    try:
        value = json.loads(bytes(chunks))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError("anchor request is malformed") from exc
    if not isinstance(value, dict):
        raise ValueError("anchor request must be an object")
    return value


def _set_close_on_exec(descriptor: int) -> None:
    flags = fcntl.fcntl(descriptor, fcntl.F_GETFD)
    fcntl.fcntl(descriptor, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)


def _redirect_anchor_streams() -> None:
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
    finally:
        if devnull > 2:
            os.close(devnull)


def _wait_status_to_return_code(status: int) -> int:
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return -os.WTERMSIG(status)
    raise RuntimeError("child wait status is not terminal")


def _anchor_entry(control_fd: int, result_fd: int, request_fd: int) -> int:
    backend = ProcessBackend()
    request = _read_request(request_fd)
    os.close(request_fd)
    expected_keys = {
        "root",
        "commandId",
        "groupLeaseIdentity",
        "argv",
        "stdinPolicy",
    }
    if set(request) != expected_keys:
        raise ValueError("anchor request fields are not exact")
    root = Path(request["root"]).absolute()
    command_id = request["commandId"]
    group_identity = request["groupLeaseIdentity"]
    argv = request["argv"]
    stdin_policy = request["stdinPolicy"]
    if (
        not isinstance(command_id, str)
        or not isinstance(group_identity, str)
        or not isinstance(argv, list)
        or not argv
        or not all(isinstance(item, str) and item for item in argv)
        or stdin_policy not in ("devnull", "inherit")
    ):
        raise ValueError("anchor request values are invalid")

    authority = safe_io._RootedIO(root.parent.parent)
    group_path = (
        root
        / ".evidence-control"
        / "commands"
        / command_id
        / "group.lease"
    )
    lease_context = authority.lease(group_path, timeout=0.0)
    lease = lease_context.__enter__()
    try:
        if lease.identity != group_identity:
            raise ValueError("anchor group lease identity changed")
        pid = os.getpid()
        birth_identity = backend.current_identity(pid)
        sid = os.getsid(0)
        pgid = os.getpgid(0)
        if pid != sid or pid != pgid:
            raise ValueError("trusted anchor is not its session and group leader")

        term_seen = [False]

        def observe_term(_signum: int, _frame: Any) -> None:
            term_seen[0] = True

        signal.signal(signal.SIGTERM, observe_term)
        signal.signal(signal.SIGINT, observe_term)
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)
        if not _send_message(
            result_fd,
            {
                "type": "anchored",
                "pid": pid,
                "birthIdentity": birth_identity,
                "sid": sid,
                "pgid": pgid,
                "groupLeaseIdentity": lease.identity,
                "controlProtocolVersion": 1,
            },
        ):
            return 125

        instruction = os.read(control_fd, 1)
        if instruction != b"G":
            return 0 if instruction == b"" else 125

        exec_gate_read, exec_gate_write = os.pipe()
        exec_error_read, exec_error_write = os.pipe()
        _set_close_on_exec(exec_error_write)
        child_pid = os.fork()
        if child_pid == 0:
            try:
                signal.signal(signal.SIGTERM, signal.SIG_DFL)
                signal.signal(signal.SIGINT, signal.SIG_DFL)
                signal.signal(signal.SIGPIPE, signal.SIG_DFL)
                os.close(exec_gate_write)
                os.close(exec_error_read)
                os.close(control_fd)
                os.close(result_fd)
                if os.read(exec_gate_read, 1) != b"G":
                    os._exit(125)
                os.close(exec_gate_read)
                if stdin_policy == "devnull":
                    devnull = os.open(os.devnull, os.O_RDONLY)
                    try:
                        os.dup2(devnull, 0)
                    finally:
                        if devnull > 2:
                            os.close(devnull)
                os.execvpe(argv[0], argv, os.environ.copy())
            except BaseException as exc:
                error = {
                    "errno": getattr(exc, "errno", None),
                    "message": str(exc)[:4096],
                }
                try:
                    _write_all(exec_error_write, _canonical_message(error))
                except BaseException:
                    pass
                os._exit(127)

        os.close(exec_gate_read)
        os.close(exec_error_write)
        child_identity = backend.current_identity(child_pid)
        _write_all(exec_gate_write, b"G")
        os.close(exec_gate_write)
        _redirect_anchor_streams()

        exec_error = bytearray()
        while True:
            chunk = os.read(exec_error_read, 8192)
            if not chunk:
                break
            exec_error.extend(chunk)
            if len(exec_error) > _PROTOCOL_LIMIT:
                raise ValueError("exec handshake exceeds its limit")
        os.close(exec_error_read)
        if exec_error:
            try:
                diagnostic = json.loads(bytes(exec_error).decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                diagnostic = {"errno": None, "message": "exec handshake failed"}
            _send_message(
                result_fd,
                {
                    "type": "exec_failure",
                    "pid": child_pid,
                    "diagnostic": diagnostic,
                    "timestamp": safe_io._utc_now(),
                },
            )
        else:
            _send_message(
                result_fd,
                {
                    "type": "running",
                    "pid": child_pid,
                    "birthIdentity": child_identity,
                    "execAcknowledgedAt": safe_io._utc_now(),
                },
            )

        _waited_pid, wait_status = os.waitpid(child_pid, 0)
        return_code = _wait_status_to_return_code(wait_status)
        finished_at = safe_io._utc_now()
        remaining = [member for member in backend.group_members(pgid) if member != pid]
        if remaining:
            os.killpg(pgid, signal.SIGTERM)
            deadline = time.monotonic() + 2.0
            while remaining and time.monotonic() < deadline:
                time.sleep(0.02)
                remaining = [
                    member
                    for member in backend.group_members(pgid)
                    if member != pid
                ]
        if remaining:
            _send_message(
                result_fd,
                {
                    "type": "cleanup_required",
                    "returnCode": return_code,
                    "finishedAt": finished_at,
                },
            )
            while True:
                signal.pause()
        _send_message(
            result_fd,
            {
                "type": "outcome",
                "returnCode": return_code,
                "finishedAt": finished_at,
            },
        )
        acknowledgement = os.read(control_fd, 1)
        if acknowledgement == b"A":
            return 0
        if acknowledgement not in (b"",):
            return 125
        while not term_seen[0]:
            signal.pause()
        return 0
    finally:
        try:
            lease_context.__exit__(None, None, None)
        finally:
            authority.close()


class _BoundedStream:
    """Sanitize a whole stream while retaining bounded logs and optional raw bytes."""

    def __init__(
        self,
        *,
        roots: dict[str, str] | None = None,
        secrets: list[str] | None = None,
        capture_raw: bool = False,
    ) -> None:
        self.original_bytes = 0
        self._sanitized_bytes = 0
        self._head = bytearray()
        self._tail = bytearray()
        self._sanitizer = StreamingSanitizer(
            roots={} if roots is None else dict(roots),
            secrets=[] if secrets is None else list(secrets),
        )
        self._capture_raw = capture_raw
        self._raw = bytearray()
        self._raw_failure: str | None = None
        self._finished = False
        self.error: BaseException | None = None
        self._lock = threading.Lock()

    def _accept_sanitized(self, content: bytes) -> None:
        self._sanitized_bytes += len(content)
        remaining = _STREAM_HALF - len(self._head)
        if remaining > 0:
            self._head.extend(content[:remaining])
            content = content[remaining:]
        if content:
            self._tail.extend(content)
            if len(self._tail) > _STREAM_HALF:
                del self._tail[: len(self._tail) - _STREAM_HALF]

    def accept(self, content: bytes) -> None:
        if type(content) is not bytes:
            raise TypeError("command stream chunks must be bytes")
        with self._lock:
            if self._finished:
                raise RuntimeError("command stream is already finished")
            self.original_bytes += len(content)
            if self._capture_raw and self._raw_failure is None:
                if b"\x00" in content:
                    self._raw.clear()
                    self._raw_failure = "raw capture contains NUL"
                elif len(self._raw) + len(content) > RAW_CAPTURE_LIMIT:
                    self._raw.clear()
                    self._raw_failure = "raw capture exceeds its limit"
                else:
                    self._raw.extend(content)
            self._accept_sanitized(self._sanitizer.feed(content))

    def discard(self, byte_count: int) -> None:
        """Count bytes after a sanitizer failure while continuing to drain."""

        with self._lock:
            self.original_bytes += byte_count
            self._raw.clear()
            self._raw_failure = "raw capture processing failed"

    def fail(self, error: BaseException) -> None:
        with self._lock:
            self.error = self.error or error
            self._raw.clear()
            self._raw_failure = "raw capture processing failed"
            self._finished = True

    def finish(self) -> None:
        with self._lock:
            if self._finished:
                return
            self._accept_sanitized(self._sanitizer.finish())
            self._finished = True

    def _stored_unlocked(self) -> bytes:
        if not self._finished:
            raise RuntimeError("command stream has not finished")
        if self._sanitized_bytes <= _STREAM_LIMIT:
            return bytes(self._head + self._tail)
        head = bytes(self._head)
        try:
            head.decode("utf-8")
        except UnicodeDecodeError as exc:
            head = head[: exc.start]
        tail_start = 0
        while (
            tail_start < len(self._tail)
            and self._tail[tail_start] & 0xC0 == 0x80
        ):
            tail_start += 1
        tail = bytes(self._tail[tail_start:])
        tail.decode("utf-8")
        return head + tail

    def stored(self) -> tuple[bytes, dict[str, Any]]:
        with self._lock:
            content = self._stored_unlocked()
            return content, {
                "originalBytes": self.original_bytes,
                "sanitizedBytes": self._sanitized_bytes,
                "storedBytes": len(content),
                "truncated": self._sanitized_bytes > _STREAM_LIMIT,
            }

    @property
    def content(self) -> bytes:
        return self.stored()[0]

    def raw_content(self) -> bytes:
        with self._lock:
            if not self._finished:
                raise RuntimeError("command stream has not finished")
            if not self._capture_raw:
                raise CaptureFailure("raw capture was not requested")
            if self.error is not None:
                raise CaptureFailure("raw capture processing failed") from self.error
            if self._raw_failure is not None:
                raise CaptureFailure(self._raw_failure)
            return bytes(self._raw)


def _drain_stream(stream: Any, collector: _BoundedStream) -> None:
    processing = True
    try:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            if processing:
                try:
                    collector.accept(chunk)
                except BaseException as exc:
                    collector.fail(exc)
                    processing = False
            else:
                collector.discard(len(chunk))
        if processing:
            try:
                collector.finish()
            except BaseException as exc:
                collector.fail(exc)
    finally:
        stream.close()


class TrustedAnchor:
    """Supervisor-side client for one trusted anchor process."""

    def __init__(
        self,
        process: subprocess.Popen,
        control_fd: int,
        result_fd: int,
        anchor_record: dict[str, Any],
        stdout_collector: _BoundedStream,
        stderr_collector: _BoundedStream,
        readers: tuple[threading.Thread, threading.Thread],
    ) -> None:
        self._process = process
        self._control_fd: int | None = control_fd
        self._result_fd: int | None = result_fd
        self._result_buffer = bytearray()
        self.anchor_record = anchor_record
        self._stdout_collector = stdout_collector
        self._stderr_collector = stderr_collector
        self._readers = readers
        self._outcome: dict[str, Any] | None = None
        self._closed = False

    @classmethod
    def launch(
        cls,
        *,
        root: Path,
        command_id: str,
        group_lease_identity: str,
        argv: list[str],
        stdin_policy: str,
        roots: dict[str, str] | None = None,
        secrets: list[str] | None = None,
        capture_stdout_raw: bool = False,
        capture_stderr_raw: bool = False,
        timeout: float = 5.0,
    ) -> "TrustedAnchor":
        if stdin_policy not in ("devnull", "inherit"):
            raise ValueError("anchor stdin policy is invalid")
        control_read, control_write = os.pipe()
        result_read, result_write = os.pipe()
        request_read, request_write = os.pipe()
        process: subprocess.Popen | None = None
        try:
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "scripts.run_evidence_lib.command_supervisor",
                    "--anchor",
                    str(control_read),
                    str(result_write),
                    str(request_read),
                ],
                stdin=(
                    subprocess.DEVNULL
                    if stdin_policy == "devnull"
                    else None
                ),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                close_fds=True,
                pass_fds=(control_read, result_write, request_read),
                start_new_session=True,
            )
            os.close(control_read)
            control_read = -1
            os.close(result_write)
            result_write = -1
            os.close(request_read)
            request_read = -1
            request = {
                "root": str(Path(root).absolute()),
                "commandId": command_id,
                "groupLeaseIdentity": group_lease_identity,
                "argv": list(argv),
                "stdinPolicy": stdin_policy,
            }
            _write_all(request_write, _canonical_message(request))
            os.close(request_write)
            request_write = -1
            assert process.stdout is not None
            assert process.stderr is not None
            stdout_collector = _BoundedStream(
                roots=roots,
                secrets=secrets,
                capture_raw=capture_stdout_raw,
            )
            stderr_collector = _BoundedStream(
                roots=roots,
                secrets=secrets,
                capture_raw=capture_stderr_raw,
            )
            readers = (
                threading.Thread(
                    target=_drain_stream,
                    args=(process.stdout, stdout_collector),
                    name=f"anchor-{process.pid}-stdout",
                    daemon=True,
                ),
                threading.Thread(
                    target=_drain_stream,
                    args=(process.stderr, stderr_collector),
                    name=f"anchor-{process.pid}-stderr",
                    daemon=True,
                ),
            )
            for reader in readers:
                reader.start()
            temporary = cls(
                process,
                control_write,
                result_read,
                {},
                stdout_collector,
                stderr_collector,
                readers,
            )
            message = temporary._read_message(timeout)
            if message.get("type") != "anchored":
                raise RuntimeError("trusted anchor did not report anchored state")
            expected = {
                "type",
                "pid",
                "birthIdentity",
                "sid",
                "pgid",
                "groupLeaseIdentity",
                "controlProtocolVersion",
            }
            if set(message) != expected:
                raise RuntimeError("trusted anchor report fields are not exact")
            if (
                message["pid"] != process.pid
                or message["sid"] != process.pid
                or message["pgid"] != process.pid
                or message["groupLeaseIdentity"] != group_lease_identity
                or message["controlProtocolVersion"] != 1
            ):
                raise RuntimeError("trusted anchor report is inconsistent")
            observed = ProcessBackend().current_identity(process.pid)
            if message["birthIdentity"] != observed:
                raise RuntimeError("trusted anchor birth identity changed")
            temporary.anchor_record = {
                key: value for key, value in message.items() if key != "type"
            }
            return temporary
        except BaseException:
            for descriptor in (
                control_read,
                control_write,
                result_read,
                result_write,
                request_read,
                request_write,
            ):
                if descriptor >= 0:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
            raise

    @property
    def pid(self) -> int:
        return self._process.pid

    @property
    def stdout(self) -> bytes:
        return self._stdout_collector.content

    @property
    def stderr(self) -> bytes:
        return self._stderr_collector.content

    @property
    def stdout_record(self) -> dict[str, Any]:
        return self._stdout_collector.stored()[1]

    @property
    def stderr_record(self) -> dict[str, Any]:
        return self._stderr_collector.stored()[1]

    def raw_stdout(self) -> bytes:
        return self._stdout_collector.raw_content()

    def raw_stderr(self) -> bytes:
        return self._stderr_collector.raw_content()

    def poll(self) -> int | None:
        return self._process.poll()

    def _read_message(self, timeout: float) -> dict[str, Any]:
        if self._result_fd is None:
            raise EOFError("anchor result channel is closed")
        deadline = time.monotonic() + timeout
        while True:
            newline = self._result_buffer.find(b"\n")
            if newline >= 0:
                line = bytes(self._result_buffer[:newline])
                del self._result_buffer[: newline + 1]
                try:
                    value = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    raise RuntimeError("anchor protocol response is malformed") from exc
                if not isinstance(value, dict):
                    raise RuntimeError("anchor protocol response must be an object")
                return value
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("anchor protocol response timed out")
            ready, _write, _error = select.select(
                [self._result_fd], [], [], remaining
            )
            if not ready:
                raise TimeoutError("anchor protocol response timed out")
            chunk = os.read(self._result_fd, 8192)
            if not chunk:
                raise EOFError("anchor result channel closed")
            self._result_buffer.extend(chunk)
            if len(self._result_buffer) > _PROTOCOL_LIMIT:
                raise RuntimeError("anchor protocol response exceeds its limit")

    def start(self, timeout: float = 5.0) -> dict[str, Any]:
        if self._control_fd is None:
            raise RuntimeError("anchor control channel is closed")
        _write_all(self._control_fd, b"G")
        message = self._read_message(timeout)
        if message.get("type") not in ("running", "exec_failure"):
            raise RuntimeError("anchor did not report an exec handshake")
        if message["type"] == "running":
            expected = {"type", "pid", "birthIdentity", "execAcknowledgedAt"}
            if set(message) != expected:
                raise RuntimeError("positive exec handshake fields are not exact")
            return {key: value for key, value in message.items() if key != "type"}
        return message

    def wait(self, timeout: float = 30.0) -> dict[str, Any]:
        if self._outcome is None:
            message = self._read_message(timeout)
            if set(message) != {"type", "returnCode", "finishedAt"} or message.get(
                "type"
            ) not in ("outcome", "cleanup_required"):
                raise RuntimeError("anchor outcome report is not exact")
            if type(message["returnCode"]) is not int:
                raise RuntimeError("anchor outcome return code is invalid")
            self._outcome = {
                "returnCode": message["returnCode"],
                "finishedAt": message["finishedAt"],
                "cleanupRequired": message["type"] == "cleanup_required",
            }
        deadline = time.monotonic() + timeout
        for reader in self._readers:
            reader.join(timeout=max(0.0, deadline - time.monotonic()))
        if any(reader.is_alive() for reader in self._readers):
            raise TimeoutError("command streams did not close")
        return dict(self._outcome)

    def wait_streams(self, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        for reader in self._readers:
            reader.join(timeout=max(0.0, deadline - time.monotonic()))
        if any(reader.is_alive() for reader in self._readers):
            raise TimeoutError("command streams did not close")

    def acknowledge(self) -> None:
        if self._control_fd is None:
            raise RuntimeError("anchor control channel is closed")
        _write_all(self._control_fd, b"A")
        os.close(self._control_fd)
        self._control_fd = None

    def abandon_supervision(self) -> None:
        if self._control_fd is not None:
            os.close(self._control_fd)
            self._control_fd = None

    def wait_anchor(self, timeout: float = 5.0) -> int:
        return self._process.wait(timeout=timeout)

    def abort(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.abandon_supervision()
        if self._process.poll() is None:
            try:
                os.killpg(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self._process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self._process.wait(timeout=5.0)
        if self._result_fd is not None:
            try:
                os.close(self._result_fd)
            except OSError:
                pass
            self._result_fd = None
        for reader in self._readers:
            reader.join(timeout=1.0)


class DurableCommandSupervisor:
    """Advance one prepared command through its trusted anchor to exited."""

    def __init__(
        self,
        *,
        root: Path,
        session_id: str,
        generation: int,
        command_id: str,
        supervisor_lease: command_state.CommandLayoutReservation,
        argv: list[str],
        checkpoint: Callable[[str, dict[str, Any]], None] | None = None,
        argv_projector: Callable[[list[str]], list[str]] | None = None,
        capture_mode: str = "foreground",
        capture_fd: int | None = None,
        roots: dict[str, str] | None = None,
        secrets: list[str] | None = None,
        grace_seconds: float = 2.0,
    ) -> None:
        if capture_mode not in (
            "foreground",
            "background",
            "capture-stdout",
            "capture-both",
        ):
            raise ValueError("command capture mode is invalid")
        raw_capture_requested = capture_mode in (
            "capture-stdout",
            "capture-both",
        )
        if raw_capture_requested:
            if capture_fd is None:
                raise CaptureFailure("raw capture requires its anonymous result pipe")
            _validate_capture_transport(capture_fd)
        elif capture_fd is not None:
            raise CaptureFailure("non-capture command cannot receive a result pipe")
        self.root = Path(root).absolute()
        self.session_id = session_id
        self.generation = generation
        self.command_id = command_id
        self.supervisor_lease = supervisor_lease
        self.argv = list(argv)
        self.checkpoint = checkpoint
        self.argv_projector = argv_projector
        self.capture_mode = capture_mode
        self._capture_fd = capture_fd
        self.roots = {} if roots is None else dict(roots)
        self.secrets = [] if secrets is None else list(secrets)
        self.grace_seconds = grace_seconds
        self._anchor: TrustedAnchor | None = None
        self._coordination = threading.Lock()
        self._outcome_observed = threading.Event()
        self._kill_authorized = False

    def _close_capture_transport(self) -> None:
        if self._capture_fd is None:
            return
        descriptor = self._capture_fd
        self._capture_fd = None
        try:
            os.close(descriptor)
        except OSError:
            pass

    def _emit_raw_capture(
        self,
        shell_status: int,
        *,
        stdout: bytes,
        stderr: bytes,
    ) -> None:
        if self.capture_mode not in ("capture-stdout", "capture-both"):
            return
        if self._capture_fd is None:
            raise CaptureFailure("raw capture result pipe is closed")
        content = encode_capture_envelope(
            self.command_id,
            shell_status,
            stdout=stdout,
            stderr=stderr if self.capture_mode == "capture-both" else None,
            capture_complete=True,
        )
        write_capture_envelope(self._capture_fd, content)

    @staticmethod
    def _capture_failure_candidate(candidate: dict[str, Any]) -> dict[str, Any]:
        failed = json.loads(json.dumps(candidate))
        failed["outcome"] = {
            "kind": "supervisor_failure",
            "errorCode": "runner.capture_failed",
            "exitStatus": None,
            "signal": None,
            "shellVisibleStatus": 125,
            "failedAt": safe_io._utc_now(),
        }
        failed["capture"]["captureComplete"] = False
        failed["capture"]["stdout"]["truncated"] = True
        failed["capture"]["stderr"]["truncated"] = True
        return failed

    def _checkpoint(self, stage: str, state: dict[str, Any]) -> None:
        if self.checkpoint is not None:
            self.checkpoint(stage, state)

    def _transition(self, candidate: dict[str, Any]) -> dict[str, Any]:
        return command_state.transition_command_state(
            self.root,
            self.session_id,
            self.generation,
            candidate,
            supervisor_lease=self.supervisor_lease,
        )

    def _current(self) -> dict[str, Any]:
        return command_state.read_command_state(
            self.root, self.command_id, self.session_id
        )

    def _authorize_kill_after_grace(self) -> None:
        if self._outcome_observed.wait(self.grace_seconds):
            return
        with self._coordination:
            anchor = self._anchor
            if anchor is None or anchor.poll() is not None:
                return
            state = self._current()
            if state["stage"] not in (
                "anchor_stop_requested",
                "stop_requested",
            ):
                return
            if state["stopIntent"]["killAuthorizedAt"] is None:
                candidate = json.loads(json.dumps(state))
                candidate["stopIntent"]["killAuthorizedAt"] = safe_io._utc_now()
                state = self._transition(candidate)
            self._kill_authorized = True
            os.killpg(anchor.pid, signal.SIGKILL)

    def request_stop(self, kind: str) -> dict[str, Any]:
        if kind not in ("expected", "cancel"):
            raise ValueError("command stop kind must be expected or cancel")
        with self._coordination:
            anchor = self._anchor
            if anchor is None:
                raise ValueError("command anchor is not ready")
            state = self._current()
            if kind == "expected" and state["request"]["stopPolicy"] != "expected-term":
                raise ValueError("expected stop requires expected-term policy")
            if state["stage"] == "anchored":
                target_stage = "anchor_stop_requested"
            elif state["stage"] == "running":
                target_stage = "stop_requested"
            elif state["stage"] in (
                "anchor_stop_requested",
                "stop_requested",
            ):
                if state["stopIntent"]["kind"] != kind:
                    raise ValueError("command already has a different stop request")
                return state
            else:
                raise ValueError("command is not stoppable")
            candidate = json.loads(json.dumps(state))
            candidate["stage"] = target_stage
            candidate["stopIntent"] = {
                "kind": kind,
                "requestedAt": safe_io._utc_now(),
                "killAuthorizedAt": None,
            }
            state = self._transition(candidate)
            os.killpg(anchor.pid, signal.SIGTERM)
            escalation = threading.Thread(
                target=self._authorize_kill_after_grace,
                name=f"command-{self.command_id}-grace",
                daemon=True,
            )
            escalation.start()
            return state

    def _persist_cleanup_kill_and_signal(self) -> dict[str, Any]:
        with self._coordination:
            anchor = self._anchor
            if anchor is None:
                raise ValueError("command anchor is not ready")
            state = self._current()
            if state["stage"] == "running":
                candidate = json.loads(json.dumps(state))
                candidate["stage"] = "stop_requested"
                candidate["stopIntent"] = {
                    "kind": "cancel",
                    "requestedAt": safe_io._utc_now(),
                    "killAuthorizedAt": None,
                }
                state = self._transition(candidate)
            if state["stage"] != "stop_requested":
                raise ValueError("cleanup escalation requires a running command")
            if state["stopIntent"]["killAuthorizedAt"] is None:
                candidate = json.loads(json.dumps(state))
                candidate["stopIntent"]["killAuthorizedAt"] = safe_io._utc_now()
                state = self._transition(candidate)
            self._kill_authorized = True
            os.killpg(anchor.pid, signal.SIGKILL)
            return state

    def _normal_outcome(
        self, state: dict[str, Any], return_code: int, finished_at: str
    ) -> dict[str, Any]:
        stop_intent = state["stopIntent"]
        if stop_intent is None:
            shell_status = return_code if return_code >= 0 else 128 - return_code
        elif stop_intent["killAuthorizedAt"] is not None:
            shell_status = 125
        elif stop_intent["kind"] == "expected":
            shell_status = 0
        else:
            shell_status = 130
        return {
            "kind": "exit" if return_code >= 0 else "signal",
            "exitStatus": return_code if return_code >= 0 else None,
            "signal": -return_code if return_code < 0 else None,
            "shellVisibleStatus": shell_status,
            "finishedAt": finished_at,
        }

    def _run(self) -> dict[str, Any]:
        state = self._current()
        if state["stage"] != "prepared":
            raise ValueError("durable command supervision requires prepared state")
        projected_argv = (
            list(self.argv)
            if self.argv_projector is None
            else self.argv_projector(list(self.argv))
        )
        if (
            type(projected_argv) is not list
            or not all(type(item) is str for item in projected_argv)
            or state["request"]["sanitizedArgv"] != projected_argv
        ):
            raise ValueError("supervisor argv disagrees with the prepared request")
        anchor = TrustedAnchor.launch(
            root=self.root,
            command_id=self.command_id,
            group_lease_identity=state["anchorReservation"][
                "groupLeaseIdentity"
            ],
            argv=self.argv,
            stdin_policy=state["request"]["stdinPolicy"],
            roots=self.roots,
            secrets=self.secrets,
            capture_stdout_raw=self.capture_mode
            in ("capture-stdout", "capture-both"),
            capture_stderr_raw=self.capture_mode == "capture-both",
        )
        with self._coordination:
            self._anchor = anchor
        try:
            candidate = json.loads(json.dumps(state))
            candidate["stage"] = "anchored"
            candidate["anchor"] = dict(anchor.anchor_record)
            state = self._transition(candidate)
            self._checkpoint("after_anchored", state)

            current = self._current()
            handshake = None
            if current["stage"] == "anchor_stop_requested":
                anchor.abandon_supervision()
                anchor.wait_anchor(timeout=5.0)
                anchor.wait_streams(timeout=5.0)
                self._outcome_observed.set()
                stdout_content, stdout_record = anchor._stdout_collector.stored()
                stderr_content, stderr_record = anchor._stderr_collector.stored()
                current = command_state.write_command_recovery_spools(
                    self.root,
                    self.session_id,
                    self.generation,
                    self.command_id,
                    stdout_content,
                    stderr_content,
                    supervisor_lease=self.supervisor_lease,
                )
                stop_intent = current["stopIntent"]
                escalated = stop_intent["killAuthorizedAt"] is not None
                candidate = json.loads(json.dumps(current))
                candidate.update(
                    stage="exited",
                    outcome={
                        "kind": "stopped_before_ack",
                        "requestKind": stop_intent["kind"],
                        "graceExpired": escalated,
                        "escalated": escalated,
                        "shellVisibleStatus": (
                            125
                            if escalated
                            else (0 if stop_intent["kind"] == "expected" else 130)
                        ),
                        "stoppedAt": safe_io._utc_now(),
                    },
                    capture={
                        "captureComplete": True,
                        "stdout": stdout_record,
                        "stderr": stderr_record,
                    },
                )
                raw_stdout = b""
                raw_stderr = b""
                raw_from_anchor = True
            else:
                handshake = anchor.start()

            if handshake is None:
                pass
            elif handshake.get("type") == "exec_failure":
                outcome_report = anchor.wait()
                self._outcome_observed.set()
                diagnostic = _canonical_message(handshake["diagnostic"])[
                    :_STREAM_LIMIT
                ]
                stdout_content = b""
                diagnostic_collector = _BoundedStream(
                    roots=self.roots, secrets=self.secrets
                )
                diagnostic_collector.accept(diagnostic)
                diagnostic_collector.finish()
                stderr_content, stderr_record = diagnostic_collector.stored()
                _unused_stdout, stdout_record = anchor._stdout_collector.stored()
                raw_stdout = b""
                raw_stderr = diagnostic
                raw_from_anchor = False
                current = command_state.write_command_recovery_spools(
                    self.root,
                    self.session_id,
                    self.generation,
                    self.command_id,
                    stdout_content,
                    stderr_content,
                    supervisor_lease=self.supervisor_lease,
                )
                candidate = json.loads(json.dumps(current))
                candidate.update(
                    stage="exited",
                    outcome={
                        "kind": "exec_failure",
                        "exitStatus": 127,
                        "signal": None,
                        "shellVisibleStatus": 127,
                        "execFailedAt": handshake["timestamp"],
                    },
                    capture={
                        "captureComplete": True,
                        "stdout": stdout_record,
                        "stderr": stderr_record,
                    },
                )
            else:
                candidate = json.loads(json.dumps(state))
                candidate["stage"] = "running"
                candidate["child"] = handshake
                state = self._transition(candidate)
                self._checkpoint("after_running", state)
                try:
                    outcome_report = anchor.wait()
                except EOFError:
                    authorized = self._current()
                    external_kill_authorized = (
                        authorized["stage"]
                        in ("anchor_stop_requested", "stop_requested")
                        and authorized["stopIntent"] is not None
                        and authorized["stopIntent"]["killAuthorizedAt"]
                        is not None
                    )
                    if not self._kill_authorized and not external_kill_authorized:
                        raise
                    self._kill_authorized = True
                    anchor.wait_streams()
                    outcome_report = {
                        "returnCode": -signal.SIGKILL,
                        "finishedAt": safe_io._utc_now(),
                        "cleanupRequired": False,
                    }
                self._outcome_observed.set()
                if outcome_report.get("cleanupRequired") is True:
                    self._persist_cleanup_kill_and_signal()
                    anchor.wait_anchor(timeout=5.0)
                    anchor.wait_streams(timeout=5.0)
                stdout_content, stdout_record = anchor._stdout_collector.stored()
                stderr_content, stderr_record = anchor._stderr_collector.stored()
                current = command_state.write_command_recovery_spools(
                    self.root,
                    self.session_id,
                    self.generation,
                    self.command_id,
                    stdout_content,
                    stderr_content,
                    supervisor_lease=self.supervisor_lease,
                )
                candidate = json.loads(json.dumps(current))
                normal_outcome = self._normal_outcome(
                    current,
                    outcome_report["returnCode"],
                    outcome_report["finishedAt"],
                )
                candidate.update(
                    stage="exited",
                    outcome=normal_outcome,
                    capture={
                        "captureComplete": True,
                        "stdout": stdout_record,
                        "stderr": stderr_record,
                    },
                )
                raw_stdout = b""
                raw_stderr = b""
                raw_from_anchor = True

            try:
                if (
                    anchor._stdout_collector.error is not None
                    or anchor._stderr_collector.error is not None
                ):
                    raise CaptureFailure("sanitized command capture failed")
                if raw_from_anchor and self.capture_mode in (
                    "capture-stdout",
                    "capture-both",
                ):
                    raw_stdout = anchor.raw_stdout()
                if raw_from_anchor and self.capture_mode == "capture-both":
                    raw_stderr = anchor.raw_stderr()
                self._emit_raw_capture(
                    candidate["outcome"]["shellVisibleStatus"],
                    stdout=raw_stdout,
                    stderr=raw_stderr,
                )
            except CaptureFailure:
                candidate = self._capture_failure_candidate(candidate)
            state = self._transition(candidate)
            self._checkpoint("after_exited", state)
            if anchor.poll() is None:
                anchor.acknowledge()
            anchor.wait_anchor(timeout=5.0)
            self._checkpoint("after_ack", state)
            return state
        finally:
            self._outcome_observed.set()
            try:
                anchor.abort()
            finally:
                self._close_capture_transport()

    def run(self) -> dict[str, Any]:
        if threading.current_thread() is not threading.main_thread():
            try:
                return self._run()
            finally:
                self._close_capture_transport()
        previous = {
            number: signal.getsignal(number)
            for number in (signal.SIGINT, signal.SIGTERM)
        }
        cancellation_started = threading.Event()
        cancellation_error: list[BaseException] = []

        def persist_cancellation() -> None:
            deadline = time.monotonic() + 5.0
            while not self._outcome_observed.is_set():
                try:
                    self.request_stop("cancel")
                except ValueError as exc:
                    if "anchor is not ready" not in str(exc):
                        cancellation_error.append(exc)
                        return
                    if time.monotonic() >= deadline:
                        cancellation_error.append(exc)
                        return
                    time.sleep(0.01)
                    continue
                except BaseException as exc:
                    cancellation_error.append(exc)
                return

        def handle_owner_signal(_number: int, _frame: Any) -> None:
            if cancellation_started.is_set():
                return
            cancellation_started.set()
            threading.Thread(
                target=persist_cancellation,
                name=f"command-{self.command_id}-owner-signal",
                daemon=True,
            ).start()

        for number in previous:
            signal.signal(number, handle_owner_signal)
        try:
            result = self._run()
            if cancellation_error:
                raise cancellation_error[0]
            return result
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
            self._close_capture_transport()


def _acquire_free_group_lease(
    root: Path, command_id: str, expected_identity: str
) -> tuple[Any, Any, Any]:
    authority = safe_io._RootedIO(Path(root).absolute().parent.parent)
    context = authority.lease(
        Path(root)
        / ".evidence-control"
        / "commands"
        / command_id
        / "group.lease",
        timeout=0.0,
    )
    try:
        lease = context.__enter__()
    except BaseException:
        authority.close()
        raise
    if lease.identity != expected_identity:
        try:
            context.__exit__(None, None, None)
        finally:
            authority.close()
        raise ValueError("recovery group lease identity changed")
    return authority, context, lease


def _release_group_lease(authority: Any, context: Any) -> None:
    try:
        context.__exit__(None, None, None)
    finally:
        authority.close()


def _verify_live_anchor(anchor: dict[str, Any], backend: Any) -> None:
    first = backend.current_identity(anchor["pid"])
    if first != anchor["birthIdentity"]:
        raise ValueError("command anchor birth identity changed")
    try:
        sid = os.getsid(anchor["pid"])
        pgid = os.getpgid(anchor["pid"])
    except ProcessLookupError as exc:
        raise ValueError("command anchor disappeared during verification") from exc
    if sid != anchor["sid"] or pgid != anchor["pgid"]:
        raise ValueError("command anchor session or group changed")
    members = backend.group_members(anchor["pgid"])
    if anchor["pid"] not in members:
        raise ValueError("command anchor is not a verified group member")
    second = backend.current_identity(anchor["pid"])
    if second != first:
        raise ValueError("command anchor identity changed during verification")


def _wait_for_group_lease(
    root: Path,
    command_id: str,
    expected_identity: str,
    timeout: float,
) -> tuple[Any, Any, Any]:
    deadline = time.monotonic() + timeout
    while True:
        try:
            return _acquire_free_group_lease(
                root, command_id, expected_identity
            )
        except TimeoutError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(min(0.02, max(0.0, deadline - time.monotonic())))


def _incomplete_capture(root: Path, command_id: str) -> dict[str, Any]:
    command_root = (
        Path(root)
        / ".evidence-control"
        / "commands"
        / command_id
    )
    authority = safe_io._RootedIO(Path(root).absolute().parent.parent)
    try:
        stdout = authority.read_bytes(command_root / "stdout.recovery")
        stderr = authority.read_bytes(command_root / "stderr.recovery")
    finally:
        authority.close()

    def stream(content: bytes) -> dict[str, Any]:
        return {
            "originalBytes": len(content),
            "sanitizedBytes": len(content),
            "storedBytes": len(content),
            "truncated": True,
        }

    return {
        "captureComplete": False,
        "stdout": stream(stdout),
        "stderr": stream(stderr),
    }


def _persist_recovery_stop(
    claim: command_state.CommandRecoveryClaim, kind: str = "cancel"
) -> dict[str, Any]:
    state = claim.state
    if state["stage"] == "anchored":
        target = "anchor_stop_requested"
    elif state["stage"] == "running":
        target = "stop_requested"
    elif state["stage"] in ("anchor_stop_requested", "stop_requested"):
        return state
    else:
        raise ValueError("orphaned command is not stoppable")
    candidate = json.loads(json.dumps(state))
    candidate["stage"] = target
    candidate["stopIntent"] = {
        "kind": kind,
        "requestedAt": safe_io._utc_now(),
        "killAuthorizedAt": None,
    }
    return claim.transition(candidate)


def _authorize_recovery_kill(
    claim: command_state.CommandRecoveryClaim,
) -> dict[str, Any]:
    state = claim.state
    if state["stage"] not in ("anchor_stop_requested", "stop_requested"):
        raise ValueError("orphaned command has no stop request")
    if state["stopIntent"]["killAuthorizedAt"] is not None:
        return state
    candidate = json.loads(json.dumps(state))
    candidate["stopIntent"]["killAuthorizedAt"] = safe_io._utc_now()
    return claim.transition(candidate)


def _quiesce_recovery_group(
    root: Path,
    command_id: str,
    claim: command_state.CommandRecoveryClaim,
    backend: Any,
    *,
    persist_stop: bool,
) -> dict[str, Any]:
    state = claim.state
    anchor = state["anchor"]
    if anchor is None:
        raise ValueError("orphaned command has no anchor identity")
    expected_group_identity = state["anchorReservation"][
        "groupLeaseIdentity"
    ]
    group_claim: tuple[Any, Any, Any] | None = None
    try:
        group_claim = _acquire_free_group_lease(
            root, command_id, expected_group_identity
        )
    except TimeoutError:
        _verify_live_anchor(anchor, backend)
        if persist_stop:
            state = _persist_recovery_stop(claim)
        try:
            os.killpg(anchor["pgid"], signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            group_claim = _wait_for_group_lease(
                root,
                command_id,
                expected_group_identity,
                2.0,
            )
        except TimeoutError:
            if persist_stop:
                state = _authorize_recovery_kill(claim)
            _verify_live_anchor(anchor, backend)
            os.killpg(anchor["pgid"], signal.SIGKILL)
            group_claim = _wait_for_group_lease(
                root,
                command_id,
                expected_group_identity,
                5.0,
            )
    assert group_claim is not None
    authority, context, _lease = group_claim
    try:
        deadline = time.monotonic() + 2.0
        while backend.predecessor_absent(
            anchor["pid"], anchor["birthIdentity"]
        ) is not True:
            if time.monotonic() >= deadline:
                raise ValueError(
                    "command anchor retained its identity after lease release"
                )
            time.sleep(0.01)
        prove_group_absent(
            anchor,
            group_lease_free=True,
            backend=backend,
        )
    finally:
        _release_group_lease(authority, context)
    return claim.state


def recover_command(
    root: Path,
    session_id: str,
    generation: int,
    command_id: str,
    *,
    process_backend: Any | None = None,
) -> dict[str, Any]:
    """Recover one lost supervisor, prove group death, and materialize once."""

    backend = ProcessBackend() if process_backend is None else process_backend
    initial = command_state.read_command_state(root, command_id, session_id)
    if initial["stage"] == "committed":
        from . import commands

        return commands.verify_committed_command_materialization(
            root, session_id, generation, command_id
        )
    claim = command_state.claim_command_recovery(
        root,
        session_id,
        generation,
        command_id,
        process_backend=backend,
    )
    try:
        state = claim.state
        if state["stage"] in ("materialized", "exited"):
            if state["anchor"] is not None:
                _quiesce_recovery_group(
                    root,
                    command_id,
                    claim,
                    backend,
                    persist_stop=False,
                )
            from . import commands

            return commands.materialize_command(
                root,
                session_id,
                generation,
                command_id,
                supervisor_lease=claim,
            )

        if state["stage"] == "prepared":
            from . import commands

            commands.repair_command_started_event(
                root,
                session_id,
                generation,
                command_id,
                supervisor_lease=claim,
            )
            candidate = json.loads(json.dumps(state))
            candidate.update(
                stage="exited",
                outcome={
                    "kind": "supervisor_failure",
                    "errorCode": "runner.command_supervisor_lost",
                    "exitStatus": None,
                    "signal": None,
                    "shellVisibleStatus": 125,
                    "failedAt": safe_io._utc_now(),
                },
                capture=_incomplete_capture(root, command_id),
            )
            claim.transition(candidate)
        else:
            state = _quiesce_recovery_group(
                root,
                command_id,
                claim,
                backend,
                persist_stop=True,
            )
            candidate = json.loads(json.dumps(state))
            candidate.update(
                stage="exited",
                outcome={
                    "kind": "supervisor_failure",
                    "errorCode": "runner.command_supervisor_lost",
                    "exitStatus": None,
                    "signal": None,
                    "shellVisibleStatus": 125,
                    "failedAt": safe_io._utc_now(),
                },
                capture=_incomplete_capture(root, command_id),
            )
            claim.transition(candidate)

        from . import commands

        return commands.materialize_command(
            root,
            session_id,
            generation,
            command_id,
            supervisor_lease=claim,
        )
    finally:
        claim.close()


def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--anchor", action="store_true")
    parser.add_argument("control_fd", type=int)
    parser.add_argument("result_fd", type=int)
    parser.add_argument("request_fd", type=int)
    arguments = parser.parse_args(argv)
    if not arguments.anchor:
        raise ValueError("command supervisor internal mode is required")
    return _anchor_entry(
        arguments.control_fd, arguments.result_fd, arguments.request_fd
    )


if __name__ == "__main__":  # pragma: no cover - exercised via subprocess
    try:
        _status = _main()
    except BaseException:
        _status = 125
    raise SystemExit(_status)
