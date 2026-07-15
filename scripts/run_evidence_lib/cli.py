"""Command-line parsing and dispatch."""

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

from . import bounded_io
from . import constants as _limits
from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .sanitization import *  # noqa: F401,F403
from .safe_io import *  # noqa: F401,F403
from .journal import *  # noqa: F401,F403
from .lifecycle import *  # noqa: F401,F403
from .summaries import *  # noqa: F401,F403
from .commands import *  # noqa: F401,F403
from .bundle import *  # noqa: F401,F403
from .aggregate import *  # noqa: F401,F403

_DIAGNOSTIC_UNAVAILABLE = "error: diagnostic unavailable"


class _UsageError(ValueError):
    pass


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise _UsageError(message)


def _build_parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(
        description="Create and validate ZMR run evidence.",
        epilog=(
            EVIDENCE_MUTATION_REQUIREMENT
            + ". Validation limits: "
            + f"{_limits.MAX_BUNDLE_FILE_COUNT} bundle files, "
            + f"{_limits.MAX_BUNDLE_INSPECTED_BYTES} inspected bundle bytes, "
            + f"{_limits.MAX_STRUCTURED_JSON_BYTES} bytes per JSON document, "
            + f"{_limits.MAX_JSONL_LINE_BYTES} bytes per JSONL line, "
            + f"{_limits.MAX_AGGREGATE_SUMMARY_COUNT} aggregate summaries, and "
            + f"{_limits.MAX_AGGREGATE_INSPECTED_BYTES} aggregate input bytes."
        ),
    )
    subparsers = parser.add_subparsers(dest="action", required=True)

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--root", required=True, type=Path)
    init_parser.add_argument("--context-json", required=True)
    init_parser.add_argument("--index", required=True, type=Path)

    context_parser = subparsers.add_parser("context")
    context_parser.add_argument("--root", required=True, type=Path)
    context_parser.add_argument("--set-json", required=True)

    event_parser = subparsers.add_parser("event")
    event_parser.add_argument("--root", required=True, type=Path)
    event_parser.add_argument("--phase", required=True, choices=PHASES)
    event_parser.add_argument("--status", required=True, choices=_EVENT_STATUSES)
    event_parser.add_argument("--error-code")
    event_parser.add_argument("--summary")
    event_parser.add_argument("--command")
    event_parser.add_argument("--command-status", type=int)
    event_parser.add_argument("--artifact")

    command_parser = subparsers.add_parser("command")
    command_parser.add_argument("--root", required=True, type=Path)
    command_parser.add_argument("--phase", required=True, choices=PHASES)
    command_parser.add_argument("--name", required=True)
    command_parser.add_argument("--failure-code", required=True)
    command_parser.add_argument("--capture-stdout", action="store_true")
    command_parser.add_argument("command_argv", nargs=argparse.REMAINDER)

    subparsers.add_parser("command-id")

    supervise_parser = subparsers.add_parser("command-supervise")
    supervise_parser.add_argument("--root", required=True, type=Path)
    supervise_parser.add_argument("--command-id", required=True)
    supervise_parser.add_argument("--session-id", required=True)
    supervise_parser.add_argument("--generation", required=True, type=int)
    supervise_parser.add_argument("--phase", required=True, choices=PHASES)
    supervise_parser.add_argument("--name", required=True)
    supervise_parser.add_argument("--failure-code", required=True)
    supervise_parser.add_argument(
        "--failure-policy", required=True, choices=("terminal", "handled")
    )
    supervise_parser.add_argument(
        "--stop-policy", required=True, choices=("none", "expected-term")
    )
    supervise_parser.add_argument(
        "--mode",
        required=True,
        choices=("foreground", "background", "capture-stdout", "capture-both"),
    )
    supervise_parser.add_argument(
        "--stdin-policy", required=True, choices=("devnull", "inherit")
    )
    supervise_parser.add_argument("--capture-fd", type=int)
    supervise_parser.add_argument("command_argv", nargs=argparse.REMAINDER)

    status_parser = subparsers.add_parser("command-status")
    status_parser.add_argument("--root", required=True, type=Path)
    status_parser.add_argument("--command-id", required=True)
    status_parser.add_argument("--session-id", required=True)
    status_parser.add_argument("--generation", required=True, type=int)
    status_parser.add_argument("--wait", action="store_true")

    external_parser = subparsers.add_parser("external")
    external_parser.add_argument("--root", required=True, type=Path)
    external_parser.add_argument("--phase", required=True, choices=PHASES)
    external_parser.add_argument("--name", required=True)
    external_parser.add_argument(
        "--outcome", required=True, choices=("success", "failure", "cancelled")
    )
    external_parser.add_argument("--failure-code", required=True)
    external_parser.add_argument(
        "--remediation",
        required=True,
        help=(
            "sanitized recovery guidance "
            f"(maximum {MAX_EXTERNAL_REMEDIATION_BYTES} UTF-8 bytes)"
        ),
    )

    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--root", required=True, type=Path)
    finalize_parser.add_argument(
        "--status", required=True, choices=_TERMINAL_STATUSES
    )
    finalize_parser.add_argument(
        "--classification", choices=_TERMINAL_CLASSIFICATIONS
    )
    finalize_parser.add_argument("--phase", choices=PHASES)
    finalize_parser.add_argument("--error-code")
    finalize_parser.add_argument("--summary")
    finalize_parser.add_argument("--hint")
    finalize_parser.add_argument("--command-status", type=int)
    finalize_parser.add_argument("--trace")
    finalize_parser.add_argument("--report")

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--summary", required=True, type=Path)

    bundle_parser = subparsers.add_parser("validate-bundle")
    bundle_parser.add_argument("--root", required=True, type=Path)

    aggregate_parser = subparsers.add_parser("aggregate")
    aggregate_parser.add_argument(
        "--summary", required=True, action="append", type=Path
    )
    aggregate_parser.add_argument("--json", action="store_true")
    return parser


def _argument_root(argv: list[str]) -> Path | None:
    try:
        index = argv.index("--root")
        return Path(argv[index + 1])
    except (ValueError, IndexError):
        return None


def _print_json(value: Any) -> None:
    print(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def _parse_json_argument(value: str, label: str) -> dict:
    try:
        encoded = value.encode("utf-8")
    except UnicodeError as exc:
        raise ValueError(f"{label} must be valid UTF-8 JSON") from exc
    if len(encoded) > _limits.MAX_STRUCTURED_JSON_BYTES:
        raise ValueError(
            f"{label} exceeds {_limits.MAX_STRUCTURED_JSON_BYTES} UTF-8 bytes"
        )
    try:
        parsed = bounded_io._decode_json_bytes(encoded)
    except ValueError as exc:
        raise ValueError(f"{label} must be valid JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} must be a JSON object")
    return parsed


def _dispatch(args: argparse.Namespace) -> int:
    if args.action == "command-id":
        print(new_command_id())
        return 0
    if args.action == "init":
        context = _parse_json_argument(args.context_json, "--context-json")
        stored = _initialize_attempt(args.index, args.root, context)
        _print_json(stored)
        return 0
    if args.action == "context":
        patch = _parse_json_argument(args.set_json, "--set-json")
        _print_json(update_context(args.root, patch))
        return 0
    if args.action == "event":
        metadata = {
            "errorCode": args.error_code,
            "summary": args.summary,
            "command": args.command,
            "commandStatus": args.command_status,
            "artifact": args.artifact,
        }
        _print_json(_append_event(args.root, args.phase, args.status, **metadata))
        return 0
    if args.action == "command":
        command_argv = list(args.command_argv)
        if command_argv and command_argv[0] == "--":
            command_argv.pop(0)
        return_code = _run_command(
            args.root,
            args.phase,
            args.name,
            args.failure_code,
            command_argv,
            capture_stdout=args.capture_stdout,
        )
        return return_code if return_code >= 0 else 128 + -return_code
    if args.action == "command-supervise":
        command_argv = list(args.command_argv)
        if command_argv and command_argv[0] == "--":
            command_argv.pop(0)
        state = supervise_command(
            args.root,
            args.session_id,
            args.generation,
            args.command_id,
            args.phase,
            args.name,
            args.failure_code,
            args.failure_policy,
            args.stop_policy,
            args.mode,
            args.stdin_policy,
            command_argv,
            capture_fd=args.capture_fd,
        )
        return state["outcome"]["shellVisibleStatus"]
    if args.action == "command-status":
        _print_json(
            command_status(
                args.root,
                args.session_id,
                args.generation,
                args.command_id,
                wait=args.wait,
            )
        )
        return 0
    if args.action == "external":
        return _record_external(
            args.root,
            args.phase,
            args.name,
            args.outcome,
            args.failure_code,
            args.remediation,
        )
    if args.action == "finalize":
        artifact_patch = {
            key: value
            for key, value in (("trace", args.trace), ("report", args.report))
            if value is not None
        }
        result = _finalize_attempt(
            args.root,
            args.status,
            classification=args.classification,
            phase=args.phase,
            error_code=args.error_code,
            summary_text=args.summary,
            hint=args.hint,
            command_status=args.command_status,
            artifact_patch=artifact_patch or None,
        )
        _print_json(result)
        return 0
    if args.action == "validate":
        summary_path = args.summary.absolute()
        publication_root = _publication_root_for_path(summary_path)
        with _rooted_io(publication_root, mutation=False):
            if _evidence_is_symlink(summary_path) or not _evidence_is_file(
                summary_path
            ):
                raise ValueError("summary input is missing or unsafe")
            metadata = _evidence_stat(summary_path)
            summary, _summary_bytes = bounded_io._read_json_bounded(
                summary_path, expected_metadata=metadata
            )
        errors = validate_summary(summary)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        _print_json({"valid": True})
        return 0
    if args.action == "validate-bundle":
        errors = validate_bundle(args.root, secrets=_collect_secret_values())
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        _print_json({"valid": True})
        return 0
    if args.action == "aggregate":
        aggregate = _aggregate_summaries(args.summary)
        if args.json:
            _print_json(aggregate)
        else:
            for execution in aggregate["executions"]:
                print(
                    f"{execution['executionId']}: {len(execution['attempts'])} attempt(s)"
                )
        return 0
    raise _UsageError("unknown action")


def main(argv: list[str] | None = None) -> int:
    raw_arguments = list(sys.argv[1:] if argv is None else argv)
    root = _argument_root(raw_arguments)
    try:
        args = _build_parser().parse_args(raw_arguments)
        return _dispatch(args)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        try:
            roots = _sanitization_roots(root)
            secrets = _collect_secret_values()
            diagnostic = sanitize_text(
                "error: " + str(exc),
                roots=roots,
                secrets=secrets,
            )
        except Exception:
            print(_DIAGNOSTIC_UNAVAILABLE, file=sys.stderr)
            return 2
        print(diagnostic, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

__all__ = (
    "_UsageError",
    "_ArgumentParser",
    "_build_parser",
    "_argument_root",
    "_print_json",
    "_parse_json_argument",
    "_dispatch",
    "main",
)
