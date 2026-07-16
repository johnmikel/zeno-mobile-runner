"""Structured zmr run-outcome sidecar validation and consumption cases."""

from __future__ import annotations

import json
import os
import sys

from scripts.run_evidence_lib import command_state

from . import support


COMMAND_ID = "d" * 32


class RunOutcomeTests(support.CommandTestCase):
    def setUp(self):
        super().setUp()
        self.session = self._claim()
        (self.root / "run-outcomes").mkdir(exist_ok=True)
        (self.root / "traces").mkdir()
        (self.root / "traces" / "run.zmrtrace").mkdir()
        (self.root / "traces" / "run.zmrtrace" / "trace.jsonl").write_text(
            '{"event":"scenario-start"}\n', encoding="utf-8"
        )
        (self.root / "reports").mkdir()
        (self.root / "reports" / "run.html").write_text("report", encoding="utf-8")

    def _claim(self):
        result = self.cli(
            "session-claim",
            "--root",
            self.root,
            "--owner-pid",
            os.getpid(),
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def _supervise(self, status=1, command_id=COMMAND_ID):
        result = self.cli(
            "command-supervise",
            "--root",
            self.root,
            "--command-id",
            command_id,
            "--session-id",
            self.session["sessionId"],
            "--generation",
            self.session["generation"],
            "--phase",
            "scenario.execute",
            "--name",
            "zmr-run",
            "--failure-code",
            "runner.unclassified",
            "--failure-policy",
            "handled",
            "--stop-policy",
            "none",
            "--mode",
            "foreground",
            "--stdin-policy",
            "devnull",
            "--",
            sys.executable,
            "-c",
            f"raise SystemExit({status})",
            text=True,
        )
        self.assertEqual(result.returncode, status, result.stderr)

    def _sidecar(self, **patch):
        value = {
            "schemaVersion": 1,
            "status": "failed",
            "failureOwner": "app",
            "errorCode": "app.assertion_failed",
            "phase": "scenario.execute",
            "summary": "Scenario assertion failed while the driver remained healthy",
            "hint": "Inspect the trace failure and app state",
            "trace": "traces/run.zmrtrace",
            "report": None,
            "childStatus": 1,
            "iosShim": {
                "targetKind": "simulator",
                "mode": "generated",
                "digest": "sha256:" + "a" * 64,
            },
        }
        value.update(patch)
        return value

    def _write(self, value, command_id=COMMAND_ID):
        path = self.root / "run-outcomes" / f"{command_id}.json"
        path.write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        return path

    def _consume(self, command_id=COMMAND_ID, env=None):
        return self.cli(
            "consume-outcome",
            "--root",
            self.root,
            "--session-id",
            self.session["sessionId"],
            "--path",
            f"run-outcomes/{command_id}.json",
            text=True,
            env=env,
        )

    def _finalize_session(self):
        closed = self.cli(
            "session-close",
            "--root",
            self.root,
            "--session-id",
            self.session["sessionId"],
            "--generation",
            self.session["generation"],
            text=True,
        )
        self.assertEqual(closed.returncode, 0, closed.stderr)
        finalized = self.cli(
            "session-finalize",
            "--root",
            self.root,
            "--session-id",
            self.session["sessionId"],
            "--generation",
            self.session["generation"],
            text=True,
        )
        self.assertEqual(finalized.returncode, 0, finalized.stderr)

    def test_valid_sidecar_binds_command_registers_artifacts_and_terminal_owner(self):
        self._supervise()
        self._write(self._sidecar())

        result = self._consume()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "consumed": f"run-outcomes/{COMMAND_ID}.json",
                "status": "failed",
            },
        )

        context = self.read_json(self.root / "run-context.json")
        self.assertEqual(context["artifacts"]["trace"], "traces/run.zmrtrace")
        events = self.read_events(self.root)
        outcome_events = [
            event
            for event in events
            if event.get("artifact") == f"run-outcomes/{COMMAND_ID}.json"
        ]
        self.assertEqual(len(outcome_events), 1)
        self.assertEqual(outcome_events[0]["status"], "failed")
        self.assertEqual(outcome_events[0]["errorCode"], "app.assertion_failed")

        intent = command_state.read_terminal_intent(self.root)
        self.assertEqual(intent["primary"]["classification"], "app_failure")
        self.assertIsNone(intent["primary"]["commandStatus"])

        replay = self._consume()
        self.assertEqual(replay.returncode, 0, replay.stderr)
        self.assertEqual(
            len(
                [
                    event
                    for event in self.read_events(self.root)
                    if event.get("artifact")
                    == f"run-outcomes/{COMMAND_ID}.json"
                ]
            ),
            1,
        )

        self._finalize_session()
        bundle = self.cli("validate-bundle", "--root", self.root, text=True)
        self.assertEqual(bundle.returncode, 0, bundle.stderr)

        sidecar = self._sidecar(childStatus=0)
        self._write(sidecar)
        tampered = self.cli("validate-bundle", "--root", self.root, text=True)
        self.assertEqual(tampered.returncode, 1)
        self.assertIn("childStatus disagrees", tampered.stderr)

    def test_passed_sidecar_preserves_zero_status_without_borrower_pass_intent(self):
        self._supervise(status=0)
        self._write(
            self._sidecar(
                status="passed",
                failureOwner="none",
                errorCode=None,
                phase="complete",
                summary=None,
                hint=None,
                childStatus=0,
            )
        )

        result = self._consume()
        self.assertEqual(result.returncode, 0, result.stderr)
        intent = command_state.read_terminal_intent(self.root)
        self.assertIsNone(intent["primary"])

    def test_unknown_mismatched_and_secret_sidecars_become_evidence_invalid(self):
        cases = (
            self._sidecar(unexpected=True),
            self._sidecar(childStatus=0),
            self._sidecar(summary="leaked-token-value"),
        )
        for index, value in enumerate(cases):
            with self.subTest(index=index):
                if index:
                    self.tearDown()
                    self.setUp()
                self._supervise()
                self._write(value)
                result = self._consume(
                    env={"ZMR_SECRET_TEST_TOKEN": "leaked-token-value"}
                )
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("leaked-token-value", result.stderr)
                intent = command_state.read_terminal_intent(self.root)
                self.assertEqual(
                    intent["primary"]["errorCode"], "runner.evidence_invalid"
                )
                self.assertFalse(
                    (self.root / "run-outcomes" / f"{COMMAND_ID}.json").exists()
                )
                self._finalize_session()
                bundle = self.cli(
                    "validate-bundle", "--root", self.root, text=True
                )
                self.assertEqual(bundle.returncode, 0, bundle.stderr)

    def test_missing_oversized_and_symlink_sidecars_are_rejected_boundedly(self):
        self._supervise()
        missing = self._consume()
        self.assertEqual(missing.returncode, 2)

        self.tearDown()
        self.setUp()
        self._supervise()
        path = self.root / "run-outcomes" / f"{COMMAND_ID}.json"
        path.write_bytes(b"{" + b" " * (64 * 1024) + b"}")
        oversized = self._consume()
        self.assertEqual(oversized.returncode, 2)
        self.assertFalse(path.exists())

        self.tearDown()
        self.setUp()
        self._supervise()
        target = self.root / "outside.json"
        target.write_text(json.dumps(self._sidecar()), encoding="utf-8")
        (self.root / "run-outcomes" / f"{COMMAND_ID}.json").symlink_to(target)
        linked = self._consume()
        self.assertEqual(linked.returncode, 2)
        self.assertFalse(
            (self.root / "run-outcomes" / f"{COMMAND_ID}.json").exists()
        )
        self.assertTrue(target.exists())
