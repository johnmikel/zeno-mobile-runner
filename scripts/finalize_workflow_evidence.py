#!/usr/bin/env python3
"""Close hosted workflow evidence without weakening the terminal contract."""

from __future__ import annotations

import argparse
import hashlib
import sys
from dataclasses import dataclass
from pathlib import Path

from run_evidence_lib import bounded_io
from run_evidence_lib.bundle import validate_bundle
from run_evidence_lib.commands import (
    _record_external,
    _stream_record,
    _validate_command_name,
)
from run_evidence_lib.constants import (
    ERROR_CLASSIFICATION,
    MAX_LIFECYCLE_EVENT_STREAM_BYTES,
    MAX_STRUCTURED_JSON_BYTES,
    PHASES,
)
from run_evidence_lib.contracts import (
    _comparability_tuple,
    classify,
    validate_summary,
)
from run_evidence_lib.journal import (
    _attempt_root_relative,
    _commit_transaction_unlocked,
    _make_transaction,
    _recover_pending_transactions_unlocked,
    _request_fingerprint,
)
from run_evidence_lib.lifecycle import (
    _event_stream_candidate,
    _execution_for_run,
    _load_index,
    _utc_now,
)
from run_evidence_lib.receipts import (
    MAX_FINALIZE_RECEIPT_BYTES,
    _finalize_receipt_relative,
    _make_finalize_receipt,
)
from run_evidence_lib.sanitization import (
    _collect_secret_values,
    _sanitization_roots,
    _sanitize_value,
    sanitize_text,
)
from run_evidence_lib.safe_io import (
    _evidence_exists,
    _evidence_is_dir,
    _evidence_is_file,
    _evidence_is_symlink,
    _evidence_iterdir,
    _evidence_stat,
    _evidence_unlink,
    _exclusive_lock,
    _rooted_attempt_mutation,
    _rooted_io,
    _rooted_publication_mutation,
)
from run_evidence_lib.summaries import (
    _build_summary,
    _finalize_attempt,
    _sanitize_validation_errors,
)


OUTCOMES = ("success", "failure", "cancelled", "skipped")


@dataclass(frozen=True)
class StepOutcome:
    name: str
    outcome: str
    phase: str
    error_code: str


def _parse_step(value: str) -> StepOutcome:
    parts = value.split(":")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(
            "step must be step-id:outcome:phase:error-code"
        )
    name, outcome, phase, error_code = parts
    try:
        _validate_command_name(name)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if outcome not in OUTCOMES:
        raise argparse.ArgumentTypeError(
            "step outcome must be success, failure, cancelled, or skipped"
        )
    if phase not in PHASES:
        raise argparse.ArgumentTypeError("step phase must be a declared phase")
    if error_code not in ERROR_CLASSIFICATION:
        raise argparse.ArgumentTypeError("step error code must be registered")
    if outcome == "failure" and error_code == "run.cancelled":
        raise argparse.ArgumentTypeError(
            "failed step outcome cannot use run.cancelled"
        )
    if outcome == "cancelled":
        error_code = "run.cancelled"
    return StepOutcome(name, outcome, phase, error_code)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Finalize one hosted workflow evidence attempt"
    )
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument(
        "--step", action="append", required=True, type=_parse_step
    )
    return parser


def _publication_root(root: Path, index: Path) -> Path:
    root = root.absolute()
    index = index.absolute()
    if root.parent.name != "attempts" or root.name in ("", ".", ".."):
        raise ValueError("evidence root must be <publication>/attempts/<run-id>")
    publication = root.parent.parent
    expected_index = publication / "attempt-index.json"
    if index != expected_index:
        raise ValueError("attempt index must be the canonical sibling index")
    return publication


@_rooted_publication_mutation
def _recover_workflow_transactions(publication: Path) -> None:
    """Roll forward durable WALs before inspecting any projected evidence."""

    publication = Path(publication).absolute()
    with _exclusive_lock(publication / ".transactions.lock"):
        _recover_pending_transactions_unlocked(publication)


def _read_valid_terminal(root: Path, index: Path) -> dict | None:
    publication = _publication_root(root, index)
    root = root.absolute()
    with _rooted_io(publication, mutation=False):
        summary_path = root / "run-summary.json"
        if not _evidence_exists(summary_path):
            return None
        if _evidence_is_symlink(summary_path) or not _evidence_is_file(
            summary_path
        ):
            raise ValueError("terminal summary is unsafe")
        metadata = _evidence_stat(summary_path)
        try:
            summary, _content = bounded_io._read_json_bounded(
                summary_path, expected_metadata=metadata
            )
        except (OSError, UnicodeError, ValueError):
            return None
        if validate_summary(summary):
            return None

    errors = validate_bundle(root, secrets=_collect_secret_values())
    if errors:
        return None
    return summary


@_rooted_attempt_mutation
def _discard_uncommitted_invalid_summary(root: Path) -> dict | None:
    """Remove only an invalid summary that has no durable finalize artifacts."""

    root = Path(root).absolute()
    summary_path = root / "run-summary.json"
    if not _evidence_exists(summary_path):
        return None
    required = (
        root / "run-context.json",
        root / "bootstrap-events.jsonl",
        root / "commands",
        root.parent.parent / "attempt-index.json",
    )
    if not all(
        _evidence_is_dir(path) if path.name == "commands" else _evidence_is_file(path)
        for path in required
    ):
        raise ValueError(
            "invalid terminal summary is not part of an initialized attempt"
        )
    durable_terminal_artifacts = (
        root / "finalize-receipt.json",
        root / "run-summary.invalid.json",
        root / "run-summary.invalid.errors.json",
    )
    if any(_evidence_exists(path) for path in durable_terminal_artifacts):
        raise ValueError(
            "invalid terminal summary has durable finalize artifacts and "
            "cannot be repaired"
        )
    if _evidence_is_symlink(summary_path) or not _evidence_is_file(summary_path):
        raise ValueError("invalid terminal summary is unsafe")
    metadata = _evidence_stat(summary_path)
    try:
        candidate, _content = bounded_io._read_json_bounded(
            summary_path, expected_metadata=metadata
        )
    except (OSError, UnicodeError, ValueError):
        if metadata.st_size > MAX_STRUCTURED_JSON_BYTES:
            candidate = {
                "invalidJsonSizeBytes": metadata.st_size,
                "structuredJsonLimitBytes": MAX_STRUCTURED_JSON_BYTES,
            }
        else:
            content = bounded_io._read_bounded_bytes(
                summary_path,
                MAX_STRUCTURED_JSON_BYTES,
                expected_metadata=metadata,
            )
            candidate = {
                "invalidJsonSha256": (
                    "sha256:" + hashlib.sha256(content).hexdigest()
                )
            }
    else:
        candidate = _sanitize_value(
            candidate,
            roots=_sanitization_roots(root),
            secrets=_collect_secret_values(),
        )
        if not isinstance(candidate, dict):
            candidate = {"invalidSummaryValue": candidate}
    if not validate_summary(candidate):
        candidate = {"uncommittedTerminalSummary": candidate}
    _evidence_unlink(
        summary_path,
        expected_identity=(metadata.st_dev, metadata.st_ino),
    )
    return candidate


@_rooted_attempt_mutation
def _replace_invalid_diagnostic_pair(root: Path, candidate: dict) -> None:
    """Atomically bind the sanitized original invalid candidate to fallback."""

    root = Path(root).absolute()
    publication = root.parent.parent
    attempt_relative = _attempt_root_relative(publication, root)
    roots = _sanitization_roots(root)
    secrets = _collect_secret_values()
    candidate_errors = list(validate_summary(candidate))
    index = _load_index(publication / "attempt-index.json")
    execution = _execution_for_run(index, root.name)
    if _comparability_tuple(candidate) != execution["comparabilityTuple"]:
        candidate_errors.append(
            "$.comparabilityTuple: context disagrees with the registered execution"
        )
    diagnostics = _sanitize_validation_errors(
        candidate_errors,
        roots=roots,
        secrets=secrets,
    )
    if not diagnostics:
        raise ValueError(
            "invalid summary diagnostic candidate unexpectedly validates"
        )

    summary_path = root / "run-summary.json"
    summary_metadata = _evidence_stat(summary_path)
    summary, _summary_size = bounded_io._read_json_bounded(
        summary_path, expected_metadata=summary_metadata
    )
    summary_content = bounded_io._read_bounded_bytes(
        summary_path,
        MAX_STRUCTURED_JSON_BYTES,
        expected_metadata=summary_metadata,
    )
    request_fingerprint = summary.get("finalizeRequestFingerprint")
    if not isinstance(request_fingerprint, str):
        raise ValueError(
            "fallback summary is missing its finalize request fingerprint"
        )

    targets = [
        (
            attempt_relative + "/run-summary.invalid.json",
            bounded_io._json_bytes_bounded(
                candidate, label="run-summary.invalid.json"
            ),
        ),
        (
            attempt_relative + "/run-summary.invalid.errors.json",
            bounded_io._json_bytes_bounded(
                {"errors": diagnostics},
                label="run-summary.invalid.errors.json",
            ),
        ),
        (
            attempt_relative + "/bootstrap-events.jsonl",
            bounded_io._read_bounded_bytes(
                root / "bootstrap-events.jsonl",
                MAX_LIFECYCLE_EVENT_STREAM_BYTES,
            ),
        ),
        (attempt_relative + "/run-summary.json", summary_content),
        (
            _finalize_receipt_relative(attempt_relative),
            bounded_io._read_bounded_bytes(
                root / "finalize-receipt.json",
                MAX_FINALIZE_RECEIPT_BYTES,
            ),
        ),
    ]
    with _exclusive_lock(publication / ".transactions.lock"):
        _recover_pending_transactions_unlocked(publication)
        transaction = _make_transaction(
            publication,
            "finalize",
            root,
            [attempt_relative],
            targets,
            request_fingerprint=request_fingerprint,
        )
        _commit_transaction_unlocked(publication, transaction)


def _remediation(step: StepOutcome) -> str:
    if step.outcome == "success":
        return f"Hosted workflow step {step.name} completed successfully"
    if step.outcome == "cancelled":
        return (
            f"Hosted workflow step {step.name} was cancelled; retry the workflow"
        )
    return (
        f"Hosted workflow step {step.name} failed; inspect the authoritative "
        "workflow provider log"
    )


def _recorded_step_names(root: Path) -> set[str]:
    root = root.absolute()
    with _rooted_io(root.parent.parent, mutation=False):
        commands = root / "commands"
        if not _evidence_is_dir(commands) or _evidence_is_symlink(commands):
            raise ValueError("attempt commands directory is missing or unsafe")
        names = set()
        for path in _evidence_iterdir(commands):
            if path.suffix != ".json":
                continue
            if _evidence_is_symlink(path) or not _evidence_is_file(path):
                raise ValueError("command metadata is unsafe")
            metadata, _size = bounded_io._read_json_bounded(
                path, expected_metadata=_evidence_stat(path)
            )
            name = metadata.get("name") if isinstance(metadata, dict) else None
            if isinstance(name, str):
                names.add(name)
        return names


def _record_steps(root: Path, steps: list[StepOutcome]) -> None:
    recorded = _recorded_step_names(root)
    for step in steps:
        if step.outcome == "skipped" or step.name in recorded:
            continue
        _record_external(
            root,
            step.phase,
            step.name,
            step.outcome,
            step.error_code,
            _remediation(step),
        )
        recorded.add(step.name)


def _mapped_terminal(steps: list[StepOutcome]) -> dict | None:
    failures = [step for step in steps if step.outcome == "failure"]
    cancellations = [step for step in steps if step.outcome == "cancelled"]
    if failures:
        classification, primary_code = classify(
            [step.error_code for step in failures]
        )
        owner = next(step for step in failures if step.error_code == primary_code)
        return {
            "name": owner.name,
            "outcome": owner.outcome,
            "status": "failed",
            "classification": classification,
            "phase": owner.phase,
            "error_code": primary_code,
            "summary_text": f"Hosted workflow step {owner.name} failed",
            "hint": (
                "Inspect the synthetic command record and hosted workflow log"
            ),
            "remediation": _remediation(owner),
        }
    if cancellations:
        owner = cancellations[0]
        return {
            "name": owner.name,
            "outcome": owner.outcome,
            "status": "cancelled",
            "classification": "cancelled",
            "phase": owner.phase,
            "error_code": "run.cancelled",
            "summary_text": f"Hosted workflow step {owner.name} was cancelled",
            "hint": "Retry the workflow when capacity is available",
            "remediation": _remediation(owner),
        }
    return None


def _should_supersede_terminal(terminal: dict, mapped: dict | None) -> bool:
    if mapped is None:
        return False
    if (
        terminal.get("status") == mapped["status"]
        and terminal.get("classification") == mapped["classification"]
        and terminal.get("phase") == mapped["phase"]
        and terminal.get("errorCode") == mapped["error_code"]
    ):
        return False
    if terminal["status"] == "passed":
        return True
    if mapped["status"] == "failed" and terminal["status"] == "cancelled":
        return True
    if terminal["status"] == "failed":
        if terminal.get("errorCode") == "runner.evidence_invalid":
            return False
        return mapped["phase"] in ("cleanup", "evidence.finalize")
    return False


@_rooted_attempt_mutation
def _supersede_terminal(root: Path, mapped: dict) -> dict:
    """Atomically append a later hosted failure and replace the terminal view."""

    root = Path(root).absolute()
    publication = root.parent.parent
    attempt_relative = _attempt_root_relative(publication, root)
    index_path = publication / "attempt-index.json"
    with _exclusive_lock(publication / ".transactions.lock"):
        _recover_pending_transactions_unlocked(publication)
        with _exclusive_lock(index_path.with_name(index_path.name + ".lock")):
            with _exclusive_lock(root / ".lifecycle.lock"):
                with _exclusive_lock(root / ".events.lock"):
                    roots = _sanitization_roots(root)
                    secrets = _collect_secret_values()
                    context, _context_size = bounded_io._read_json_bounded(
                        root / "run-context.json"
                    )
                    previous, _previous_size = bounded_io._read_json_bounded(
                        root / "run-summary.json"
                    )
                    previous_content = bounded_io._json_bytes_bounded(
                        previous, label="previous terminal summary"
                    )
                    summary_text = sanitize_text(
                        mapped["summary_text"], roots=roots, secrets=secrets
                    )
                    hint = sanitize_text(
                        mapped["hint"], roots=roots, secrets=secrets
                    )
                    remediation = sanitize_text(
                        mapped["remediation"], roots=roots, secrets=secrets
                    )
                    stdout_content = (
                        "synthetic external command record. Hosted log content was "
                        "not captured; consult the workflow provider for "
                        "authoritative output.\n"
                    ).encode("utf-8")
                    stderr_content = (
                        f"synthetic outcome: {mapped['outcome']}. This record does "
                        "not claim hosted log capture.\n"
                        f"remediation: {remediation}\n"
                    ).encode("utf-8")
                    _started, _started_content, started_events = (
                        _event_stream_candidate(
                            root,
                            mapped["phase"],
                            "started",
                            _roots_snapshot=roots,
                            _secrets_snapshot=secrets,
                        )
                    )
                    stem = f"{_started['seq']:06d}-{mapped['name']}"
                    stdout_relative = f"commands/{stem}.stdout.log"
                    stderr_relative = f"commands/{stem}.stderr.log"
                    metadata_relative = f"commands/{stem}.json"
                    metadata = {
                        "schemaVersion": 1,
                        "source": "github-action",
                        "argv": [],
                        "phase": mapped["phase"],
                        "name": mapped["name"],
                        "failureCode": mapped["error_code"],
                        "outcome": mapped["outcome"],
                        "remediation": remediation,
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
                        "limitation": (
                            "Synthetic metadata only; hosted log content was not "
                            "captured."
                        ),
                    }
                    metadata_content = bounded_io._json_bytes_bounded(
                        metadata, label="command metadata"
                    )
                    event_status = {
                        "failure": "failed",
                        "cancelled": "cancelled",
                    }[mapped["outcome"]]
                    _external_event, _external_content, external_events = (
                        _event_stream_candidate(
                            root,
                            mapped["phase"],
                            event_status,
                            events=started_events,
                            _roots_snapshot=roots,
                            _secrets_snapshot=secrets,
                            command=metadata_relative,
                            artifact=metadata_relative,
                            commandStatus=None,
                            errorCode=mapped["error_code"],
                            summary=remediation,
                        )
                    )
                    request = {
                        "context": context,
                        "externalCommand": metadata,
                        "supersedes": {
                            "finalizeRequestFingerprint": previous.get(
                                "finalizeRequestFingerprint"
                            ),
                            "status": previous.get("status"),
                            "errorCode": previous.get("errorCode"),
                            "resultSha256": (
                                "sha256:"
                                + hashlib.sha256(previous_content).hexdigest()
                            ),
                        },
                        "terminal": {
                            "status": mapped["status"],
                            "classification": mapped["classification"],
                            "phase": mapped["phase"],
                            "errorCode": mapped["error_code"],
                            "summary": summary_text,
                            "hint": hint,
                            "commandStatus": None,
                        },
                    }
                    request_fingerprint = _request_fingerprint(
                        publication, "finalize", root, request
                    )
                    finished_at = _utc_now()
                    terminal = _build_summary(
                        context,
                        mapped["status"],
                        classification=mapped["classification"],
                        phase=mapped["phase"],
                        error_code=mapped["error_code"],
                        summary_text=summary_text,
                        hint=hint,
                        command_status=None,
                        finished_at=finished_at,
                        finalize_request_fingerprint=request_fingerprint,
                    )
                    errors = validate_summary(terminal)
                    if errors:
                        raise ValueError(
                            "superseding terminal summary is invalid: "
                            + "; ".join(errors)
                        )
                    summary_content = bounded_io._json_bytes_bounded(
                        terminal, label="terminal summary"
                    )
                    _event, event_content, _events = _event_stream_candidate(
                        root,
                        terminal["phase"],
                        terminal["status"],
                        events=external_events,
                        _timestamp=terminal["finishedAt"],
                        _roots_snapshot=roots,
                        _secrets_snapshot=secrets,
                        commandStatus=None,
                        errorCode=terminal["errorCode"],
                        summary=terminal["summary"],
                    )
                    targets = [
                        (
                            attempt_relative + "/" + stdout_relative,
                            stdout_content,
                        ),
                        (
                            attempt_relative + "/" + stderr_relative,
                            stderr_content,
                        ),
                        (
                            attempt_relative + "/" + metadata_relative,
                            metadata_content,
                        ),
                        (
                            attempt_relative + "/bootstrap-events.jsonl",
                            event_content,
                        ),
                        (
                            attempt_relative + "/run-summary.json",
                            summary_content,
                        ),
                        (
                            _finalize_receipt_relative(attempt_relative),
                            _make_finalize_receipt(
                                attempt_relative,
                                request_fingerprint,
                                summary_content,
                            ),
                        ),
                    ]
                    transaction = _make_transaction(
                        publication,
                        "finalize",
                        root,
                        [attempt_relative],
                        targets,
                        request_fingerprint=request_fingerprint,
                    )
                    _commit_transaction_unlocked(publication, transaction)
                    return terminal


def _finalize_from_steps(root: Path, steps: list[StepOutcome]) -> dict:
    mapped = _mapped_terminal(steps)
    if mapped is not None:
        return _finalize_attempt(
            root,
            mapped["status"],
            classification=mapped["classification"],
            phase=mapped["phase"],
            error_code=mapped["error_code"],
            summary_text=mapped["summary_text"],
            hint=mapped["hint"],
        )

    # A hosted job is not evidence of a successful ZMR run. Deliberately make
    # this candidate non-canonical so the evidence engine emits its immutable,
    # validated evidence-invalid fallback and diagnostic pair.
    return _finalize_attempt(
        root,
        "failed",
        classification="runner_failure",
        phase="invocation",
        error_code="runner.evidence_invalid",
        summary_text="Workflow completed without a terminal run summary",
        hint="Inspect workflow finalization and the generated diagnostics",
    )


def run(root: Path, index: Path, steps: list[StepOutcome]) -> int:
    publication = _publication_root(root, index)
    _recover_workflow_transactions(publication)
    names = [step.name for step in steps]
    if len(names) != len(set(names)):
        raise ValueError("workflow step mappings must use unique step ids")
    terminal = _read_valid_terminal(root, index)
    if terminal is not None:
        mapped = _mapped_terminal(steps)
        if _should_supersede_terminal(terminal, mapped):
            assert mapped is not None
            terminal = _supersede_terminal(root, mapped)
            errors = validate_bundle(root, secrets=_collect_secret_values())
            if errors:
                raise ValueError(
                    "superseded evidence bundle is invalid: "
                    + "; ".join(errors)
                )
        return 0 if terminal["status"] == "passed" else 1

    invalid_candidate = _discard_uncommitted_invalid_summary(root)
    _record_steps(root, steps)
    terminal = _finalize_from_steps(root, steps)
    if invalid_candidate is not None:
        _replace_invalid_diagnostic_pair(root, invalid_candidate)
    errors = validate_bundle(root, secrets=_collect_secret_values())
    if errors:
        raise ValueError("final evidence bundle is invalid: " + "; ".join(errors))
    return 0 if terminal["status"] == "passed" else 1


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return run(args.root, args.index, args.step)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"workflow evidence finalization failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
