"""Subprocess and external-command capture cases."""

import base64
import io
import threading

from .support import *  # noqa: F401,F403

try:
    import resource
except ImportError:  # pragma: no cover - non-POSIX portability
    resource = None


class CommandCaptureTests(CommandTestCase):
    def test_streaming_sanitizer_redacts_values_straddling_carry_flush(self):
        carry = run_evidence._SANITIZATION_CARRY
        roots = {"workspace": "", "run_root": "", "home": ""}
        cases = (
            (b"very-secret-value", ["very-secret-value"], False),
            (b"https://person:password@example.test/resource", [], True),
        )
        for token, secrets, prefix_with_boundary in cases:
            prefix_size = carry - len(token) // 2
            prefix = b"x" * prefix_size
            if prefix_with_boundary:
                prefix = prefix[:-1] + b"!"
            suffix_size = carry - ((len(token) + 1) // 2) + 1
            raw = prefix + token + b"z" * suffix_size
            self.assertGreater(len(raw), carry * 2)
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=secrets
            )
            actual = sanitizer.feed(raw) + sanitizer.finish()
            expected = run_evidence.sanitize_text(
                raw.decode("utf-8"), roots=roots, secrets=secrets
            ).encode("utf-8")
            with self.subTest(token=token):
                self.assertEqual(actual, expected)
                self.assertNotIn(token, actual)

    def test_capture_stdout_text_sink_decodes_split_utf8_incrementally(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(
            run_evidence.commands, "_PIPE_READ_CHUNK_SIZE", 1
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "text-capture",
                "runner.driver_protocol",
                [
                    sys.executable,
                    "-c",
                    "import os,time;data='😀'.encode();"
                    "[os.write(1,bytes([byte])) or time.sleep(.01) for byte in data]",
                ],
                capture_stdout=True,
                stdout_stream=stdout,
                stderr_stream=stderr,
            )
        self.assertEqual(return_code, 0)
        self.assertEqual(stdout.getvalue(), "😀")

    def test_capture_sink_failure_still_persists_terminal_evidence(self):
        class FailingSink:
            def write(self, _content):
                raise BrokenPipeError("capture sink closed")

            def flush(self):
                pass

        with self.assertRaisesRegex(BrokenPipeError, "capture sink closed"):
            run_evidence._run_command(
                self.root,
                "scenario.execute",
                "closed-capture",
                "runner.driver_protocol",
                [sys.executable, "-c", "import os;os.write(1,b'captured-output')"],
                capture_stdout=True,
                stdout_stream=FailingSink(),
                stderr_stream=io.BytesIO(),
            )
        metadata = self.command_metadata()
        self.assertEqual(len(metadata), 1)
        stdout_record = metadata[0]["stdout"]
        self.assertEqual(
            (self.root / stdout_record["path"]).read_bytes(), b"captured-output"
        )
        self.assertEqual(
            [event["status"] for event in self.read_events(self.root)[-2:]],
            ["started", "passed"],
        )

    def test_capture_stdout_is_forwarded_while_child_is_still_running(self):
        class SignallingBuffer:
            def __init__(self):
                self.data = bytearray()
                self.first_write = threading.Event()

            def write(self, content):
                if isinstance(content, str):
                    content = content.encode("utf-8")
                self.data.extend(content)
                self.first_write.set()
                return len(content)

            def flush(self):
                pass

        stdout = SignallingBuffer()
        stderr = io.BytesIO()
        outcome = {}

        def invoke():
            try:
                outcome["returnCode"] = run_evidence._run_command(
                    self.root,
                    "scenario.execute",
                    "direct-capture",
                    "runner.driver_protocol",
                    [
                        sys.executable,
                        "-c",
                        (
                            "import os,time;"
                            "os.write(1,b'first-chunk');"
                            "time.sleep(1.5);"
                            "os.write(1,b'-last-chunk')"
                        ),
                    ],
                    capture_stdout=True,
                    stdout_stream=stdout,
                    stderr_stream=stderr,
                )
            except BaseException as exc:  # surfaced after bounded cleanup
                outcome["error"] = exc

        worker = threading.Thread(target=invoke, daemon=True)
        worker.start()
        observed_while_running = stdout.first_write.wait(timeout=0.75)
        still_running_at_first_write = worker.is_alive()
        worker.join(timeout=5)
        self.assertFalse(worker.is_alive(), "command wrapper did not finish")
        if "error" in outcome:
            raise outcome["error"]
        self.assertTrue(observed_while_running)
        self.assertTrue(still_running_at_first_write)
        self.assertEqual(outcome["returnCode"], 0)
        self.assertEqual(bytes(stdout.data), b"first-chunk-last-chunk")

    def test_streaming_sanitization_handles_split_sensitive_and_utf8_sequences(self):
        secret = "boundary-secret"
        password = "boundary-password"
        raw = (
            b"prefix "
            + secret.encode("utf-8")
            + b" path="
            + str(self.root / "private" / "value.txt").encode("utf-8")
            + b" url=https://person:"
            + password.encode("utf-8")
            + b"@example.test/resource invalid="
            + b"\xe2(\xa1"
            + b" suffix"
        )
        pieces = [raw[index : index + 3] for index in range(0, len(raw), 3)]
        encoded = [base64.b64encode(piece).decode("ascii") for piece in pieces]
        script = (
            "import base64,os,sys,time\n"
            "for value in sys.argv[1:]:\n"
            " os.write(1,base64.b64decode(value));time.sleep(0.001)\n"
        )
        stdout = io.BytesIO()
        stderr = io.BytesIO()
        commands_module = run_evidence.commands
        with mock.patch.object(
            commands_module,
            "_collect_secret_values",
            return_value=[secret, password],
        ), mock.patch.object(
            commands_module, "_PIPE_READ_CHUNK_SIZE", 3, create=True
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "split-sanitization",
                "runner.driver_protocol",
                [sys.executable, "-c", script, *encoded],
                stdout_stream=stdout,
                stderr_stream=stderr,
            )
        self.assertEqual(return_code, 0)
        expected = run_evidence.sanitize_text(
            raw.decode("utf-8", errors="replace"),
            roots=run_evidence._sanitization_roots(self.root),
            secrets=[secret, password],
        ).encode("utf-8")
        metadata = self.command_metadata()[-1]
        stored = (self.root / metadata["stdout"]["path"]).read_bytes()
        self.assertEqual(metadata["stdout"]["originalBytes"], len(raw))
        self.assertEqual(metadata["stdout"]["sanitizedBytes"], len(expected))
        self.assertEqual(stdout.getvalue(), expected)
        self.assertEqual(stored, expected)
        stored.decode("utf-8")
        for sensitive in (secret.encode(), password.encode(), str(self.root).encode()):
            self.assertNotIn(sensitive, stored)
            self.assertNotIn(sensitive, stdout.getvalue())

    @unittest.skipUnless(
        os.name == "posix" and resource is not None and hasattr(resource, "RLIMIT_AS"),
        "requires POSIX RLIMIT_AS",
    )
    def test_combined_256_mib_output_stays_within_wrapper_address_space(self):
        chunk_size = 64 * 1024
        iterations = 2048
        bytes_per_stream = chunk_size * iterations
        address_space_headroom = 384 * 1024 * 1024
        if sys.platform == "darwin":
            current_virtual_bytes = int(
                subprocess.check_output(
                    ["ps", "-o", "vsz=", "-p", str(os.getpid())], text=True
                ).strip()
            ) * 1024
            address_space_limit = current_virtual_bytes + address_space_headroom
        else:
            address_space_limit = address_space_headroom
        script = (
            "import os,sys\n"
            "chunk=b'x'*int(sys.argv[1])\n"
            "for _ in range(int(sys.argv[2])):\n"
            " os.write(1,chunk);os.write(2,chunk)\n"
        )

        def limit_address_space():
            _soft, hard = resource.getrlimit(resource.RLIMIT_AS)
            resource.setrlimit(
                resource.RLIMIT_AS, (address_space_limit, hard)
            )

        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "command",
                "--root",
                str(self.root),
                "--phase",
                "scenario.execute",
                "--name",
                "bounded-stress",
                "--failure-code",
                "runner.driver_protocol",
                "--",
                sys.executable,
                "-c",
                script,
                str(chunk_size),
                str(iterations),
            ],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            preexec_fn=limit_address_space,
            timeout=120,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        metadata = self.command_metadata()[-1]
        for stream in ("stdout", "stderr"):
            record = metadata[stream]
            self.assertEqual(record["originalBytes"], bytes_per_stream)
            self.assertEqual(record["sanitizedBytes"], bytes_per_stream)
            self.assertTrue(record["truncated"])
            self.assertLessEqual(record["storedBytes"], 10 * 1024 * 1024)
            self.assertLessEqual(
                (self.root / record["path"]).stat().st_size, 10 * 1024 * 1024
            )
        self.assertFalse(
            any(path.suffix == ".tmp" for path in (self.root / "commands").iterdir())
        )

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
