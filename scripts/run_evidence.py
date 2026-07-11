#!/usr/bin/env python3
"""Compatibility facade for the dependency-free run-evidence implementation."""

from __future__ import annotations

import os
import sys
from pathlib import Path


_SCRIPT_DIRECTORY = str(Path(__file__).resolve().parent)
if _SCRIPT_DIRECTORY not in sys.path:
    sys.path.insert(0, _SCRIPT_DIRECTORY)

from run_evidence_lib import *  # noqa: E402,F403
from run_evidence_lib import __all__  # noqa: E402,F401


if __name__ == "__main__":
    raise SystemExit(main())
