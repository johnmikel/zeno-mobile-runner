#!/usr/bin/env python3
"""Generate deterministic release-readiness run-summary fixtures."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "scripts"))

from run_evidence_lib.contracts import _comparability_tuple, comparability  # noqa: E402


def summary(
    execution_id: str,
    attempt: int,
    *,
    status: str = "passed",
    classification: str = "passed",
    revision: str | None = "a" * 40,
    runtime: str = "18.5",
) -> dict:
    run_id = f"{execution_id}-attempt-{attempt}"
    value = {
        "schemaVersion": 1,
        "runId": run_id,
        "executionId": execution_id,
        "fixtureId": "release-certification-ios",
        "fixtureVersion": "1",
        "candidateRevision": revision,
        "scenarioDigest": "sha256:" + "b" * 64,
        "appBuildDigest": "sha256:" + "c" * 64,
        "comparabilityKey": None,
        "certificationEligible": False,
        "ineligibilityReasons": [],
        "status": status,
        "classification": classification,
        "phase": "complete" if status == "passed" else "scenario.execute",
        "startedAt": "2026-07-16T12:00:00Z",
        "finishedAt": "2026-07-16T12:00:01Z",
        "durationMs": 1000,
        "attempt": attempt,
        "firstAttempt": attempt == 1,
        "platform": "ios",
        "deviceClass": "ios-simulator",
        "runtimeVersion": runtime,
        "timingMode": "cold-command",
        "runnerVersion": "1.0.0",
        "protocolVersion": "2026-04-28",
        "commandStatus": 0 if status == "passed" else 1,
        "host": {
            "os": "macos",
            "arch": "arm64",
            "class": "github-macos-15-arm64",
            "ci": True,
        },
        "device": {"requested": "booted", "resolved": "simulator-udid"},
        "toolchain": {"xcode": "16.4", "zig": "0.16.0"},
        "artifacts": {
            "bootstrapEvents": "bootstrap-events.jsonl",
            "commands": "commands",
            "trace": None,
            "report": None,
        },
    }
    if status != "passed":
        codes = {
            "app_failure": "app.assertion_failed",
            "runner_failure": "runner.unclassified",
        }
        value.update(
            errorCode=codes[classification],
            summary="Deterministic fixture failure",
            hint="Inspect the fixture evidence",
        )
    computed = comparability(value)
    value.update(computed)
    return value


def write_publication(root: Path, executions: list[list[dict]]) -> None:
    if root.exists():
        shutil.rmtree(root)
    (root / "attempts").mkdir(parents=True)
    index = {"schemaVersion": "1.0", "executions": []}
    for attempts in executions:
        first = attempts[0]
        entry = {
            "executionId": first["executionId"],
            "comparabilityTuple": _comparability_tuple(first),
            "attempts": [],
        }
        for value in attempts:
            attempt_root = root / "attempts" / value["runId"]
            attempt_root.mkdir()
            (attempt_root / "run-summary.json").write_text(
                json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            entry["attempts"].append(
                {
                    "runId": value["runId"],
                    "attempt": value["attempt"],
                    "summary": f"attempts/{value['runId']}/run-summary.json",
                }
            )
        index["executions"].append(entry)
    (root / "attempt-index.json").write_text(
        json.dumps(index, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def generate(root: Path, mode: str, count: int | None) -> None:
    if mode == "ready":
        write_publication(
            root,
            [
                [
                    summary("logical-1", 1, status="failed", classification="app_failure"),
                    summary("logical-1", 2),
                ],
                [summary("logical-2", 1)],
            ],
        )
        return
    if mode == "runner":
        write_publication(
            root,
            [
                [
                    summary("logical-1", 1, status="failed", classification="runner_failure"),
                    summary("logical-1", 2),
                ],
                [summary("logical-2", 1)],
            ],
        )
        return
    if mode == "minimum":
        if count is None or count < 1:
            raise SystemExit("minimum mode requires a positive count")
        write_publication(
            root,
            [[summary(f"logical-{number}", 1)] for number in range(1, count + 1)],
        )
        return
    if mode == "mismatched-key":
        value = summary("logical-1", 1)
        value["comparabilityKey"] = "sha256:" + "f" * 64
        write_publication(root, [[value]])
        return
    if mode == "incomplete":
        write_publication(root, [[summary("logical-1", 1, revision=None)]])
        return
    if mode == "mixed":
        write_publication(
            root,
            [
                [summary("logical-1", 1)],
                [summary("logical-2", 1, revision="d" * 40)],
            ],
        )
        return

    base = [
        summary("logical-1", 1),
        summary("logical-1", 2),
    ]
    write_publication(root, [base])
    index_path = root / "attempt-index.json"
    index = json.loads(index_path.read_text(encoding="utf-8"))
    attempts = index["executions"][0]["attempts"]
    if mode == "duplicate-run-id":
        duplicate = dict(attempts[1])
        duplicate["runId"] = attempts[0]["runId"]
        duplicate["summary"] = attempts[0]["summary"]
        attempts[1] = duplicate
    elif mode == "missing-attempt-one":
        attempts[0]["attempt"] = 2
    elif mode == "nonmonotonic-attempts":
        attempts[1]["attempt"] = 3
    elif mode == "changed-retry-identity":
        retry_path = root / attempts[1]["summary"]
        retry = json.loads(retry_path.read_text(encoding="utf-8"))
        retry["runtimeVersion"] = "18.6"
        retry.update(comparability(retry))
        retry_path.write_text(
            json.dumps(retry, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
    elif mode == "path-escape":
        attempts[0]["summary"] = "../outside.json"
    elif mode == "indexed-missing-summary":
        (root / attempts[1]["summary"]).unlink()
    elif mode == "unindexed-summary":
        extra = summary("logical-extra", 1)
        extra_root = root / "attempts" / extra["runId"]
        extra_root.mkdir()
        (extra_root / "run-summary.json").write_text(
            json.dumps(extra, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
    else:
        raise SystemExit(f"unknown fixture mode: {mode}")
    index_path.write_text(
        json.dumps(index, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: generate-release-run-evidence.py ROOT MODE [COUNT]")
    generate(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else None)
