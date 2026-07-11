import copy
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPOSITORY_ROOT / "scripts" / "run_evidence.py"
SPEC = importlib.util.spec_from_file_location("run_evidence", MODULE_PATH)
run_evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(run_evidence)

journal_module = run_evidence.journal
safe_io_module = run_evidence.safe_io


REVISION = "a" * 40
SCENARIO_DIGEST = "sha256:" + "b" * 64
APP_DIGEST = "sha256:" + "c" * 64


def valid_context(**patch):
    context = {
        "runId": "run-1",
        "executionId": "execution-1",
        "fixtureId": "fixture-ios",
        "fixtureVersion": "1",
        "candidateRevision": REVISION,
        "scenarioDigest": SCENARIO_DIGEST,
        "appBuildDigest": APP_DIGEST,
        "platform": "ios",
        "deviceClass": "ios-simulator",
        "runtimeVersion": "18.5",
        "timingMode": "cold-command",
        "runnerVersion": "0.2.17",
        "protocolVersion": "2026-04-28",
        "attempt": 1,
        "host": {
            "os": "macos",
            "arch": "arm64",
            "class": "github-macos-15-arm64",
            "ci": True,
        },
        "device": {"requested": "booted", "resolved": "simulator-udid"},
        "toolchain": {"xcode": "16.4", "zig": "0.16.0"},
        "artifacts": {"trace": None, "report": "reports/run.html"},
    }
    for key, value in patch.items():
        context[key] = value
    return context


def valid_summary(status="passed"):
    context = valid_context()
    computed = run_evidence.comparability(context)
    summary = {
        "schemaVersion": 1,
        "runId": context["runId"],
        "executionId": context["executionId"],
        "fixtureId": context["fixtureId"],
        "fixtureVersion": context["fixtureVersion"],
        "candidateRevision": context["candidateRevision"],
        "scenarioDigest": context["scenarioDigest"],
        "appBuildDigest": context["appBuildDigest"],
        "comparabilityKey": computed["comparabilityKey"],
        "certificationEligible": computed["certificationEligible"],
        "ineligibilityReasons": computed["ineligibilityReasons"],
        "status": status,
        "classification": "passed",
        "phase": "complete",
        "startedAt": "2026-07-11T10:00:00Z",
        "finishedAt": "2026-07-11T10:00:05.123Z",
        "durationMs": 5123,
        "attempt": context["attempt"],
        "firstAttempt": True,
        "platform": context["platform"],
        "deviceClass": context["deviceClass"],
        "runtimeVersion": context["runtimeVersion"],
        "timingMode": context["timingMode"],
        "runnerVersion": context["runnerVersion"],
        "protocolVersion": context["protocolVersion"],
        "commandStatus": 0,
        "host": context["host"],
        "device": context["device"],
        "toolchain": context["toolchain"],
        "artifacts": {
            "bootstrapEvents": "bootstrap-events.jsonl",
            "commands": "commands",
            "trace": None,
            "report": "reports/run.html",
        },
        "ciJobId": "device-smoke-ios",
    }
    if status == "failed":
        summary.update(
            classification="runner_failure",
            phase="shim.prewarm",
            errorCode="runner.ios_shim.readiness_timeout",
            summary="Shim readiness timed out",
            hint="Inspect command logs",
            commandStatus=None,
        )
    elif status == "cancelled":
        summary.update(
            classification="cancelled",
            phase="cleanup",
            errorCode="run.cancelled",
            summary="Run cancelled",
            hint="Retry when ready",
            commandStatus=None,
        )
    return summary


def valid_event(**patch):
    event = {
        "schemaVersion": 1,
        "seq": 1,
        "timestamp": "2026-07-11T10:00:00Z",
        "phase": "invocation",
        "status": "started",
    }
    event.update(patch)
    return event

class StorageTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.publication_root = Path(self.temporary.name) / "publication"
        self.publication_root.mkdir()
        self.index_path = self.publication_root / "attempt-index.json"

    def tearDown(self):
        self.temporary.cleanup()

    def attempt_root(self, run_id):
        return self.publication_root / "attempts" / run_id

    def create_attempt_root(self, run_id):
        root = self.attempt_root(run_id)
        root.mkdir(parents=True)
        return root

    def read_json(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def read_events(self, root):
        return [
            json.loads(line)
            for line in (root / "bootstrap-events.jsonl")
            .read_text(encoding="utf-8")
            .splitlines()
            if line.strip()
        ]

class CommandTestCase(StorageTestCase):
    def setUp(self):
        super().setUp()
        self.root = self.attempt_root("run-1")
        run_evidence._initialize_attempt(self.index_path, self.root, valid_context())

    def cli(self, *arguments, env=None, text=False, timeout=30):
        environment = os.environ.copy()
        if env:
            environment.update(env)
        return subprocess.run(
            [sys.executable, str(MODULE_PATH), *map(str, arguments)],
            cwd=REPOSITORY_ROOT,
            env=environment,
            capture_output=True,
            text=text,
            timeout=timeout,
            check=False,
        )

    def command_metadata(self):
        metadata_paths = sorted((self.root / "commands").glob("*.json"))
        return [self.read_json(path) for path in metadata_paths]
