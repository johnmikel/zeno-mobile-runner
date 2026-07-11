"""Terminal summary aggregation."""

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

from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .safe_io import *  # noqa: F401,F403

def _summary_paths(inputs: list[Path]) -> list[Path]:
    paths = []
    for supplied in inputs:
        path = Path(supplied)
        if path.is_dir():
            path = path / "run-summary.json"
        if not path.is_file():
            raise ValueError(f"summary input does not exist: {path.name}")
        paths.append(path)
    return sorted(set(paths), key=lambda path: str(path.resolve()))


def _aggregate_summaries(inputs: list[Path]) -> dict:
    groups: dict[str, dict] = {}
    seen_run_ids = set()
    for path in _summary_paths(inputs):
        summary = _read_json(path)
        errors = validate_summary(summary)
        if errors:
            raise ValueError(
                f"invalid summary {path.name}: " + "; ".join(errors)
            )
        run_id = summary["runId"]
        if run_id in seen_run_ids:
            raise ValueError("aggregate contains a duplicate runId")
        seen_run_ids.add(run_id)
        execution_id = summary["executionId"]
        computed = recompute_comparability(summary)
        group = groups.setdefault(
            execution_id,
            {
                "executionId": execution_id,
                "comparabilityTuple": computed["comparabilityTuple"],
                "comparabilityKey": computed["comparabilityKey"],
                "certificationEligible": computed["certificationEligible"],
                "ineligibilityReasons": computed["ineligibilityReasons"],
                "attempts": [],
            },
        )
        if group["comparabilityTuple"] != computed["comparabilityTuple"]:
            raise ValueError("summaries in one execution have different comparability tuples")
        group["attempts"].append(summary)
    executions = []
    for execution_id in sorted(groups):
        group = groups[execution_id]
        group["attempts"].sort(key=lambda item: (item["attempt"], item["runId"]))
        attempt_numbers = [item["attempt"] for item in group["attempts"]]
        if len(attempt_numbers) != len(set(attempt_numbers)):
            raise ValueError("aggregate contains duplicate attempt numbers")
        executions.append(group)
    return {"schemaVersion": "1.0", "executions": executions}

__all__ = (
    "_summary_paths",
    "_aggregate_summaries",
)
