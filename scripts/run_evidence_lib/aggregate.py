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

from . import bounded_io
from . import constants as _limits
from .constants import *  # noqa: F401,F403
from .contracts import *  # noqa: F401,F403
from .contracts import _comparability_tuple
from .safe_io import *  # noqa: F401,F403

def _summary_paths(inputs: list[Path]) -> list[Path]:
    paths = []
    for supplied in inputs:
        path = Path(supplied).absolute()
        publication_root = _publication_root_for_path(path)
        with _rooted_io(publication_root, mutation=False):
            if _evidence_is_symlink(path):
                raise ValueError(f"summary input is a symlink: {path.name}")
            if _evidence_is_dir(path):
                path = path / "run-summary.json"
            if _evidence_is_symlink(path) or not _evidence_is_file(path):
                raise ValueError(f"summary input does not exist: {path.name}")
        paths.append(path)
    return sorted(set(paths), key=lambda path: str(path.absolute()))


def _aggregate_summaries(inputs: list[Path]) -> dict:
    if len(inputs) > _limits.MAX_AGGREGATE_SUMMARY_COUNT:
        raise ValueError(
            "aggregate summary count exceeds maximum "
            f"({_limits.MAX_AGGREGATE_SUMMARY_COUNT})"
        )
    groups: dict[str, dict] = {}
    seen_run_ids = set()
    inspected_bytes = 0
    for path in _summary_paths(inputs):
        publication_root = _publication_root_for_path(path)
        with _rooted_io(publication_root, mutation=False):
            metadata = _evidence_stat(path)
            if (
                inspected_bytes + metadata.st_size
                > _limits.MAX_AGGREGATE_INSPECTED_BYTES
            ):
                raise ValueError(
                    "aggregate input exceeds maximum inspected bytes "
                    f"({_limits.MAX_AGGREGATE_INSPECTED_BYTES})"
                )
            summary, byte_count = bounded_io._read_json_bounded(
                path, expected_metadata=metadata
            )
        inspected_bytes += byte_count
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
        raw_tuple = _comparability_tuple(summary)
        group = groups.setdefault(
            execution_id,
            {
                "executionId": execution_id,
                "comparabilityTuple": raw_tuple,
                "comparabilityKey": computed["comparabilityKey"],
                "certificationEligible": computed["certificationEligible"],
                "ineligibilityReasons": computed["ineligibilityReasons"],
                "attempts": [],
            },
        )
        if group["comparabilityTuple"] != raw_tuple:
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
