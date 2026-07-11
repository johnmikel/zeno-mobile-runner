"""Subprocess and external-command capture cases."""

from .support import *  # noqa: F401,F403


class CommandCaptureTests(CommandTestCase):
    def test_unknown_failure_code_is_rejected_before_command_side_effects(self):
        events_before = (self.root / "bootstrap-events.jsonl").read_bytes()
        commands_before = sorted(path.name for path in (self.root / "commands").iterdir())
        with self.assertRaises(ValueError):
            run_evidence._run_command(
                self.root,
                "scenario.execute",
                "unknown-code",
                "unknown.failure",
                [sys.executable, "-c", "pass"],
            )
        self.assertEqual(
            (self.root / "bootstrap-events.jsonl").read_bytes(), events_before
        )
        self.assertEqual(
            sorted(path.name for path in (self.root / "commands").iterdir()),
            commands_before,
        )

    def test_sanitized_byte_expansion_never_exceeds_hard_log_limit(self):
        limit = 10 * 1024 * 1024
        bounded, truncated = run_evidence._bounded_log(b"x" * (limit + 1), limit)
        self.assertTrue(truncated)
        self.assertEqual(len(bounded), limit)

        compact, compact_truncated = run_evidence._bounded_log(
            b"<redacted>", limit + 1
        )
        self.assertFalse(compact_truncated)
        self.assertEqual(compact, b"<redacted>")

    def test_truncation_preserves_utf8_boundaries(self):
        half = 5 * 1024 * 1024
        content = b"a" * (half - 1) + "😀".encode() + b"middle" + b"z" * half
        bounded, truncated = run_evidence._bounded_log(content, len(content))
        self.assertTrue(truncated)
        self.assertLessEqual(len(bounded), 10 * 1024 * 1024)
        bounded.decode("utf-8")

    def test_invalid_utf8_expansion_records_sanitized_size_and_validates_bundle(self):
        raw_size = (10 * 1024 * 1024) // 3 + 1
        script = "import os,sys;os.write(1,b'\\xff'*int(sys.argv[1]))"
        result = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "scenario.execute",
            "--name",
            "invalid-utf8",
            "--failure-code",
            "runner.driver_protocol",
            "--capture-stdout",
            "--",
            sys.executable,
            "-c",
            script,
            str(raw_size),
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr[-1000:])
        self.assertEqual(len(result.stdout), raw_size)
        metadata = self.command_metadata()[0]
        stdout = metadata["stdout"]
        self.assertEqual(stdout["originalBytes"], raw_size)
        self.assertEqual(stdout["sanitizedBytes"], raw_size * 3)
        self.assertTrue(stdout["truncated"])
        stored = self.root / stdout["path"]
        self.assertLessEqual(stored.stat().st_size, 10 * 1024 * 1024)
        stored.read_bytes().decode("utf-8")

        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>safe</html>", encoding="utf-8")
        run_evidence._finalize_attempt(self.root, "passed", command_status=0)
        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])

    def test_success_captures_and_replays_stdout_stderr_separately(self):
        script = "import sys;sys.stdout.write('stdout-only');sys.stderr.write('stderr-only')"
        result = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "scenario.execute",
            "--name",
            "python-run",
            "--failure-code",
            "app.assertion_failed",
            "--",
            sys.executable,
            "-c",
            script,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"stdout-only")
        self.assertEqual(result.stderr, b"stderr-only")
        metadata = self.command_metadata()[0]
        self.assertEqual(metadata["source"], "subprocess")
        self.assertEqual(metadata["phase"], "scenario.execute")
        self.assertEqual(metadata["name"], "python-run")
        self.assertEqual(metadata["exitStatus"], 0)
        self.assertIsNone(metadata["signal"])
        self.assertFalse(metadata["stdout"]["truncated"])
        self.assertFalse(metadata["stderr"]["truncated"])
        self.assertEqual(
            (self.root / metadata["stdout"]["path"]).read_text(encoding="utf-8"),
            "stdout-only",
        )
        self.assertEqual(
            (self.root / metadata["stderr"]["path"]).read_text(encoding="utf-8"),
            "stderr-only",
        )
        events = self.read_events(self.root)
        self.assertEqual(events[-2]["status"], "started")
        self.assertEqual(events[-1]["status"], "passed")

    def test_nonzero_and_signal_preserve_child_outcome(self):
        failed = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "app.build",
            "--name",
            "nonzero",
            "--failure-code",
            "runner.unclassified",
            "--",
            sys.executable,
            "-c",
            "import sys;sys.exit(7)",
        )
        self.assertEqual(failed.returncode, 7)
        failed_metadata = self.command_metadata()[-1]
        self.assertEqual(failed_metadata["exitStatus"], 7)
        self.assertIsNone(failed_metadata["signal"])
        self.assertEqual(self.read_events(self.root)[-1]["status"], "failed")

        signalled = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "scenario.execute",
            "--name",
            "signalled",
            "--failure-code",
            "run.cancelled",
            "--",
            sys.executable,
            "-c",
            "import os,signal;os.kill(os.getpid(),signal.SIGTERM)",
        )
        self.assertEqual(signalled.returncode, 128 + signal.SIGTERM)
        signal_metadata = self.command_metadata()[-1]
        self.assertIsNone(signal_metadata["exitStatus"])
        self.assertEqual(signal_metadata["signal"], signal.SIGTERM)
        self.assertEqual(self.read_events(self.root)[-1]["status"], "cancelled")

    def test_interleaved_output_does_not_deadlock_and_names_never_overwrite(self):
        script = (
            "import os\n"
            "for i in range(2000):\n"
            " os.write(1,b'o'*1024);os.write(2,b'e'*1024)\n"
        )
        for _ in range(2):
            result = self.cli(
                "command",
                "--root",
                self.root,
                "--phase",
                "scenario.execute",
                "--name",
                "interleaved",
                "--failure-code",
                "runner.driver_protocol",
                "--capture-stdout",
                "--",
                sys.executable,
                "-c",
                script,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr[-1000:])
            self.assertEqual(len(result.stdout), 2000 * 1024)
            self.assertEqual(len(result.stderr), 2000 * 1024)
        metadata = self.command_metadata()
        self.assertEqual(len(metadata), 2)
        self.assertNotEqual(metadata[0]["stdout"]["path"], metadata[1]["stdout"]["path"])

    def test_exact_log_limit_and_one_byte_over_retain_bounded_head_and_tail(self):
        limit = 10 * 1024 * 1024
        for name, size, expected_truncated in (
            ("at-limit", limit, False),
            ("over-limit", limit + 1, True),
        ):
            script = (
                "import os,sys;size=int(sys.argv[1]);"
                "os.write(1,b'A'*size);os.write(2,b'B'*size)"
            )
            result = self.cli(
                "command",
                "--root",
                self.root,
                "--phase",
                "scenario.execute",
                "--name",
                name,
                "--failure-code",
                "runner.driver_protocol",
                "--capture-stdout",
                "--",
                sys.executable,
                "-c",
                script,
                str(size),
                timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stderr[-1000:])
            metadata = self.command_metadata()[-1]
            for stream in ("stdout", "stderr"):
                self.assertEqual(metadata[stream]["originalBytes"], size)
                self.assertEqual(metadata[stream]["truncated"], expected_truncated)
                stored = self.root / metadata[stream]["path"]
                self.assertEqual(stored.stat().st_size, limit if expected_truncated else size)
                self.assertEqual(metadata[stream]["storedBytes"], stored.stat().st_size)

    def test_capture_stdout_returns_raw_only_but_persists_and_replays_no_raw_secret(self):
        secret = "raw-capture-secret"
        url = "https://person:url-password@example.test/path"
        script = (
            "import os,sys;value=os.environ['API_TOKEN'];"
            "sys.stdout.write(value);sys.stderr.write(value+' '+sys.argv[-1])"
        )
        result = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "scenario.execute",
            "--name",
            "secret-capture",
            "--failure-code",
            "app.assertion_failed",
            "--capture-stdout",
            "--",
            sys.executable,
            "-c",
            script,
            "--api-token",
            secret,
            url,
            env={"API_TOKEN": secret, "PASSWORD": "url-password"},
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, secret.encode())
        self.assertNotIn(secret.encode(), result.stderr)
        self.assertNotIn(b"url-password", result.stderr)
        metadata = self.command_metadata()[0]
        persisted = (
            (self.root / metadata["stdout"]["path"]).read_text(encoding="utf-8")
            + (self.root / metadata["stderr"]["path"]).read_text(encoding="utf-8")
            + json.dumps(metadata)
        )
        self.assertNotIn(secret, persisted)
        self.assertNotIn("url-password", persisted)
        self.assertIn("<redacted>", persisted)

    def test_rejects_unsafe_command_name_without_creating_records(self):
        result = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "scenario.execute",
            "--name",
            "../escape",
            "--failure-code",
            "runner.unclassified",
            "--",
            sys.executable,
            "-c",
            "pass",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.command_metadata(), [])


class ExternalCaptureTests(CommandTestCase):
    def test_external_rejects_unknown_or_outcome_mismatched_codes_before_writes(self):
        cases = (
            ("failure", "unknown.failure"),
            ("failure", "run.cancelled"),
            ("cancelled", "app.assertion_failed"),
        )
        for index, (outcome, failure_code) in enumerate(cases, 1):
            context = valid_context(
                runId=f"invalid-external-{index}",
                executionId=f"invalid-execution-{index}",
            )
            root = self.attempt_root(context["runId"])
            run_evidence._initialize_attempt(self.index_path, root, context)
            events_before = (root / "bootstrap-events.jsonl").read_bytes()
            commands_before = sorted(path.name for path in (root / "commands").iterdir())
            with self.subTest(outcome=outcome, failure_code=failure_code):
                with self.assertRaises(ValueError):
                    run_evidence._record_external(
                        root,
                        "app.build",
                        "invalid-external",
                        outcome,
                        failure_code,
                    )
                self.assertEqual(
                    (root / "bootstrap-events.jsonl").read_bytes(), events_before
                )
                self.assertEqual(
                    sorted(path.name for path in (root / "commands").iterdir()),
                    commands_before,
                )

        self.assertEqual(
            run_evidence._record_external(
                self.root,
                "app.build",
                "successful-fallback",
                "success",
                "app.assertion_failed",
            ),
            0,
        )

    def test_external_records_honest_synthetic_metadata_and_bounded_logs(self):
        result = self.cli(
            "external",
            "--root",
            self.root,
            "--phase",
            "app.build",
            "--name",
            "hosted-build",
            "--outcome",
            "failure",
            "--failure-code",
            "infra.hosted_runner",
        )
        self.assertNotEqual(result.returncode, 0)
        metadata = self.command_metadata()[0]
        self.assertEqual(metadata["source"], "github-action")
        self.assertEqual(metadata["outcome"], "failure")
        self.assertIsNone(metadata["exitStatus"])
        self.assertIsNone(metadata["signal"])
        stdout = (self.root / metadata["stdout"]["path"]).read_text(encoding="utf-8")
        stderr = (self.root / metadata["stderr"]["path"]).read_text(encoding="utf-8")
        self.assertIn("synthetic", stdout + stderr)
        self.assertIn("not captured", stdout + stderr)
        self.assertLess(len(stdout) + len(stderr), 4096)
        self.assertEqual(self.read_events(self.root)[-1]["status"], "failed")
