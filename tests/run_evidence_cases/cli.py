"""CLI and aggregate-summary cases."""

import io
import tracemalloc
from contextlib import redirect_stdout

from .support import *  # noqa: F401,F403


class CliAndAggregateTests(StorageTestCase):
    def cli(self, *arguments, env=None, text=True):
        environment = os.environ.copy()
        if env:
            environment.update(env)
        return subprocess.run(
            [sys.executable, str(MODULE_PATH), *map(str, arguments)],
            cwd=REPOSITORY_ROOT,
            env=environment,
            capture_output=True,
            text=text,
            timeout=30,
            check=False,
        )

    def test_json_arguments_use_strict_bounded_decoding(self):
        with self.assertRaisesRegex(ValueError, "duplicate object key"):
            run_evidence.cli._parse_json_argument(
                '{"fixtureId":"first","fixtureId":"second"}',
                "--context-json",
            )

        nested = '{"value":' * 257 + "null" + "}" * 257
        with self.assertRaisesRegex(
            ValueError, "nesting exceeds supported depth"
        ):
            run_evidence.cli._parse_json_argument(nested, "--context-json")

        for raw in ('{"value":NaN}', '{"value":Infinity}', '{"value":1e999}'):
            with self.subTest(raw=raw), self.assertRaisesRegex(
                ValueError, "non-finite JSON number"
            ):
                run_evidence.cli._parse_json_argument(raw, "--context-json")

        self.assertEqual(
            run_evidence.cli._parse_json_argument(
                '{"value":1.25}', "--context-json"
            ),
            {"value": 1.25},
        )
        with self.assertRaisesRegex(ValueError, "Out of range float values"):
            run_evidence._json_bytes({"value": float("nan")})

        exact = '{"value":"x"}'
        exact_bytes = len(exact.encode("utf-8"))
        with mock.patch.object(
            run_evidence.constants,
            "MAX_STRUCTURED_JSON_BYTES",
            exact_bytes,
        ):
            self.assertEqual(
                run_evidence.cli._parse_json_argument(
                    exact, "--context-json"
                ),
                {"value": "x"},
            )
        with mock.patch.object(
            run_evidence.constants,
            "MAX_STRUCTURED_JSON_BYTES",
            exact_bytes - 1,
        ), self.assertRaisesRegex(
            ValueError, "--context-json exceeds"
        ):
            run_evidence.cli._parse_json_argument(exact, "--context-json")

    def test_json_integer_and_float_tokens_have_exact_work_bounds(self):
        integer_limit = run_evidence.MAX_JSON_INTEGER_DIGITS
        float_limit = run_evidence.MAX_JSON_FLOAT_CHARACTERS
        set_digit_limit = getattr(sys, "set_int_max_str_digits", None)
        get_digit_limit = getattr(sys, "get_int_max_str_digits", None)
        previous_digit_limit = get_digit_limit() if get_digit_limit else None
        if set_digit_limit is not None:
            set_digit_limit(0)
        try:
            exact_integer = "9" * integer_limit
            parsed = run_evidence.bounded_io._decode_json_bytes(
                ('{"value":' + exact_integer + "}").encode("ascii")
            )
            self.assertIs(type(parsed["value"]), int)
            with self.assertRaisesRegex(
                ValueError,
                rf"JSON integer exceeds {integer_limit} digits",
            ):
                run_evidence.bounded_io._decode_json_bytes(
                    ('{"value":' + ("9" * (integer_limit + 1)) + "}").encode(
                        "ascii"
                    )
                )
            negative = run_evidence.bounded_io._decode_json_bytes(
                ('{"value":-' + exact_integer + "}").encode("ascii")
            )
            self.assertLess(negative["value"], 0)
        finally:
            if set_digit_limit is not None:
                set_digit_limit(previous_digit_limit)

        exact_float = "0." + ("1" * (float_limit - 2))
        parsed = run_evidence.bounded_io._decode_json_bytes(
            ('{"value":' + exact_float + "}").encode("ascii")
        )
        self.assertIs(type(parsed["value"]), float)
        with self.assertRaisesRegex(
            ValueError,
            rf"JSON float exceeds {float_limit} characters",
        ):
            run_evidence.bounded_io._decode_json_bytes(
                ('{"value":' + exact_float + "1}").encode("ascii")
            )

    def test_bounded_json_writer_is_canonical_native_and_budgeted(self):
        value = {
            "z": [None, True, False, 1, -0.0, "é\n\"\\"],
            "a": {"nested": "value"},
        }
        expected = run_evidence._json_bytes(value)
        self.assertEqual(
            run_evidence.bounded_io._json_bytes_bounded(
                value, maximum=len(expected)
            ),
            expected,
        )
        self.assertEqual(
            run_evidence.bounded_io._decode_json_bytes(expected), value
        )
        with self.assertRaisesRegex(ValueError, "exceeds"):
            run_evidence.bounded_io._json_bytes_bounded(
                value, maximum=len(expected) - 1
            )

        invalid = (
            {"value": (1, 2)},
            {"value": type("CustomList", (list,), {})([1])},
            {1: "non-string key"},
        )
        for candidate in invalid:
            with self.subTest(candidate=candidate), self.assertRaisesRegex(
                ValueError, "native JSON|keys must be strings"
            ):
                run_evidence.bounded_io._json_bytes_bounded(candidate)

    def test_bounded_json_writer_stops_escaped_and_shared_expansion(self):
        escaped = {"value": '"\\\n' * 400_000}
        shared = ["leaf"]
        for _index in range(20):
            shared = [shared, shared]

        with mock.patch.object(
            run_evidence.safe_io,
            "_json_bytes",
            side_effect=AssertionError("legacy full JSON dump was used"),
        ):
            for candidate in (escaped, shared):
                with self.subTest(
                    candidate_type=type(candidate)
                ), self.assertRaisesRegex(ValueError, "exceeds 1024 bytes"):
                    run_evidence.bounded_io._json_bytes_bounded(
                        candidate, maximum=1024
                    )

    def test_bounded_json_writer_stops_scanning_plain_strings_at_budget(self):
        pattern = run_evidence.bounded_io._JSON_ESCAPE_RE
        scanned_lengths = []

        class InstrumentedPattern:
            @staticmethod
            def finditer(value):
                scanned_lengths.append(len(value))
                return pattern.finditer(value)

        with mock.patch.object(
            run_evidence.bounded_io,
            "_JSON_ESCAPE_RE",
            InstrumentedPattern(),
        ), self.assertRaisesRegex(ValueError, "exceeds 1024 bytes"):
            run_evidence.bounded_io._json_bytes_bounded(
                "x" * 10_000_000, maximum=1024
            )

        self.assertTrue(scanned_lengths)
        self.assertLessEqual(
            sum(scanned_lengths),
            run_evidence.bounded_io._JSON_TEXT_CHUNK_CHARACTERS,
        )

    def test_bounded_json_writer_depth_round_trips_with_strict_reader(self):
        exact = None
        for _index in range(256):
            exact = [exact]
        encoded = run_evidence.bounded_io._json_bytes_bounded(
            exact, maximum=1024
        )
        self.assertEqual(
            run_evidence.bounded_io._decode_json_bytes(encoded), exact
        )

        too_deep = [exact]
        with self.assertRaisesRegex(
            ValueError, "nesting exceeds supported depth"
        ):
            run_evidence.bounded_io._json_bytes_bounded(
                too_deep, maximum=1024
            )

    def test_bounded_json_writer_admits_before_integer_sort_or_flat_graph_growth(self):
        huge_integer = 1 << 2_000_000
        previous_digit_limit = (
            sys.get_int_max_str_digits()
            if hasattr(sys, "get_int_max_str_digits")
            else None
        )
        if hasattr(sys, "set_int_max_str_digits"):
            sys.set_int_max_str_digits(0)
        try:
            with self.assertRaisesRegex(ValueError, "exceeds 1024 bytes"):
                run_evidence.bounded_io._json_bytes_bounded(
                    huge_integer, maximum=1024
                )
        finally:
            if previous_digit_limit is not None:
                sys.set_int_max_str_digits(previous_digit_limit)

        flat = [[] for _index in range(300_000)]
        tracemalloc.start()
        try:
            tracemalloc.reset_peak()
            with self.assertRaisesRegex(ValueError, "exceeds 1024 bytes"):
                run_evidence.bounded_io._json_bytes_bounded(
                    flat, maximum=1024
                )
            _current, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertLess(peak, 1024 * 1024)

        many_keys = {f"key-{index:06d}": 0 for index in range(300_000)}
        with mock.patch(
            "builtins.sorted",
            side_effect=AssertionError("oversized key set was sorted"),
        ) as sorter, self.assertRaisesRegex(ValueError, "exceeds 1024 bytes"):
            run_evidence.bounded_io._json_bytes_bounded(
                many_keys, maximum=1024
            )
        self.assertEqual(sorter.call_count, 0)

        cycle = []
        cycle.append(cycle)
        with self.assertRaisesRegex(ValueError, "circular JSON"):
            run_evidence.bounded_io._json_bytes_bounded(cycle, maximum=1024)

    def test_cli_init_context_event_finalize_and_validate_exit_contract(self):
        root = self.attempt_root("run-1")
        initialized = self.cli(
            "init",
            "--root",
            root,
            "--context-json",
            json.dumps(valid_context(runtimeVersion=None)),
            "--index",
            self.index_path,
        )
        self.assertEqual(initialized.returncode, 0, initialized.stderr)
        patched = self.cli(
            "context",
            "--root",
            root,
            "--set-json",
            json.dumps({"runtimeVersion": "18.5"}),
        )
        self.assertEqual(patched.returncode, 0, patched.stderr)
        event = self.cli(
            "event",
            "--root",
            root,
            "--phase",
            "device.acquire",
            "--status",
            "passed",
            "--summary",
            "Device acquired",
        )
        self.assertEqual(event.returncode, 0, event.stderr)
        finalized = self.cli(
            "finalize",
            "--root",
            root,
            "--status",
            "passed",
            "--command-status",
            "0",
        )
        self.assertEqual(finalized.returncode, 0, finalized.stderr)
        summary_path = root / "run-summary.json"
        valid = self.cli("validate", "--summary", summary_path)
        self.assertEqual(valid.returncode, 0, valid.stderr)

        duplicate = self.cli(
            "finalize", "--root", root, "--status", "passed"
        )
        self.assertNotEqual(duplicate.returncode, 0)
        damaged = self.read_json(summary_path)
        damaged["phase"] = "cleanup"
        summary_path.write_text(json.dumps(damaged), encoding="utf-8")
        invalid = self.cli("validate", "--summary", summary_path)
        self.assertNotEqual(invalid.returncode, 0)

    def test_active_session_requires_exact_pair_for_ordinary_mutations(self):
        root = self.attempt_root("session-bound")
        initialized = self.cli(
            "init",
            "--root",
            root,
            "--context-json",
            json.dumps(
                valid_context(runId="session-bound", runtimeVersion=None)
            ),
            "--index",
            self.index_path,
        )
        self.assertEqual(initialized.returncode, 0, initialized.stderr)
        claimed = self.cli(
            "session-claim",
            "--root",
            root,
            "--owner-pid",
            os.getpid(),
        )
        self.assertEqual(claimed.returncode, 0, claimed.stderr)
        session = json.loads(claimed.stdout)
        baseline = (root / "bootstrap-events.jsonl").read_bytes()

        missing = self.cli(
            "event",
            "--root",
            root,
            "--phase",
            "scenario.execute",
            "--status",
            "started",
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual((root / "bootstrap-events.jsonl").read_bytes(), baseline)

        partial = self.cli(
            "context",
            "--root",
            root,
            "--set-json",
            json.dumps({"runtimeVersion": "18.6"}),
            "--session-id",
            session["sessionId"],
        )
        self.assertNotEqual(partial.returncode, 0)
        self.assertIsNone(
            self.read_json(root / "run-context.json")["runtimeVersion"]
        )

        pair = (
            "--session-id",
            session["sessionId"],
            "--generation",
            str(session["generation"]),
        )
        event = self.cli(
            "event",
            "--root",
            root,
            "--phase",
            "scenario.execute",
            "--status",
            "started",
            *pair,
        )
        self.assertEqual(event.returncode, 0, event.stderr)
        context = self.cli(
            "context",
            "--root",
            root,
            "--set-json",
            json.dumps({"runtimeVersion": "18.6"}),
            *pair,
        )
        self.assertEqual(context.returncode, 0, context.stderr)
        external = self.cli(
            "external",
            "--root",
            root,
            "--phase",
            "report.generate",
            "--name",
            "hosted-report",
            "--outcome",
            "success",
            "--failure-code",
            "runner.report_failed",
            "--remediation",
            "Inspect hosted logs",
            *pair,
        )
        self.assertEqual(external.returncode, 0, external.stderr)

        closed = self.cli(
            "session-close", "--root", root, *pair
        )
        self.assertEqual(closed.returncode, 0, closed.stderr)
        after_close = self.cli(
            "event",
            "--root",
            root,
            "--phase",
            "cleanup",
            "--status",
            "started",
            *pair,
        )
        self.assertNotEqual(after_close.returncode, 0)
        legacy_finalize = self.cli(
            "finalize", "--root", root, "--status", "passed"
        )
        self.assertNotEqual(legacy_finalize.returncode, 0)

    def test_cli_diagnostics_are_sanitized(self):
        secret = "diagnostic-secret"
        root = self.attempt_root("run-1")
        root.mkdir(parents=True)
        result = self.cli(
            "init",
            "--root",
            root,
            "--context-json",
            json.dumps(valid_context(fixtureId=secret)),
            "--index",
            self.index_path,
            env={"API_TOKEN": secret, "GITHUB_WORKSPACE": str(self.publication_root)},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(secret, result.stderr)
        self.assertNotIn(str(self.publication_root), result.stderr)

    def test_cli_diagnostic_fails_closed_when_secret_snapshot_is_oversized(self):
        root = self.attempt_root("missing-secret-overflow")
        secrets = {
            f"ZMR_TEST_TOKEN_{index}": f"secret-value-{index:03d}"
            for index in range(run_evidence.MAX_SANITIZATION_SECRET_COUNT + 1)
        }

        result = self.cli(
            "validate-bundle",
            "--root",
            root,
            env=secrets,
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "error: diagnostic unavailable\n")
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn(str(MODULE_PATH), result.stderr)
        self.assertNotIn(str(REPOSITORY_ROOT), result.stderr)
        self.assertNotIn(str(root), result.stderr)
        for secret in secrets.values():
            self.assertNotIn(secret, result.stderr)

    def test_cli_diagnostic_fails_closed_when_root_snapshot_is_oversized(self):
        secret = "oversized-root-parser-secret"
        root = self.attempt_root("missing-root-overflow")
        oversized_workspace = "/" + (
            "w" * run_evidence.MAX_SANITIZATION_ROOT_TOTAL_BYTES
        )

        result = self.cli(
            secret,
            "--root",
            root,
            env={
                "GITHUB_WORKSPACE": oversized_workspace,
                "ZMR_TEST_TOKEN": secret,
            },
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "error: diagnostic unavailable\n")
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn(str(MODULE_PATH), result.stderr)
        self.assertNotIn(str(REPOSITORY_ROOT), result.stderr)
        self.assertNotIn(str(root), result.stderr)
        self.assertNotIn(oversized_workspace, result.stderr)
        self.assertNotIn(secret, result.stderr)

    def test_finalize_trace_retry_before_atomic_commit_creates_one_terminal_result(self):
        root = self.attempt_root("finalize-artifact-retry")
        context = valid_context(
            runId=root.name,
            executionId="finalize-artifact-retry-execution",
            artifacts={"trace": None, "report": "reports/run.html"},
        )
        initialized = self.cli(
            "init",
            "--root",
            root,
            "--context-json",
            json.dumps(context),
            "--index",
            self.index_path,
        )
        self.assertEqual(initialized.returncode, 0, initialized.stderr)

        crash_code = """
import importlib.util
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_crash", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.cli._finalize_attempt = lambda *args, **kwargs: os._exit(91)
raise SystemExit(module.main([
    "finalize",
    "--root", sys.argv[2],
    "--status", "passed",
    "--command-status", "0",
    "--trace", "traces/retry.json",
]))
"""
        crashed = subprocess.Popen(
            [sys.executable, "-c", crash_code, str(MODULE_PATH), str(root)],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            crash_stdout, crash_stderr = crashed.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            crashed.kill()
            crash_stdout, crash_stderr = crashed.communicate(timeout=5)
            self.fail(
                "crashing finalize child timed out: "
                + crash_stdout
                + crash_stderr
            )
        finally:
            if crashed.poll() is None:
                crashed.kill()
                crashed.wait(timeout=5)
        self.assertEqual(
            crashed.returncode,
            91,
            crash_stdout + crash_stderr,
        )
        self.assertFalse((root / "run-summary.json").exists())
        self.assertEqual(
            self.read_json(root / "run-context.json")["artifacts"]["trace"],
            None,
        )

        retried = self.cli(
            "finalize",
            "--root",
            root,
            "--status",
            "passed",
            "--command-status",
            "0",
            "--trace",
            "traces/retry.json",
        )

        self.assertEqual(retried.returncode, 0, retried.stderr)
        summary = json.loads(retried.stdout)
        self.assertEqual(summary, self.read_json(root / "run-summary.json"))
        self.assertEqual(
            [path.name for path in root.glob("run-summary*.json")],
            ["run-summary.json"],
        )
        matching_terminal_events = [
            event
            for event in self.read_events(root)
            if (event["phase"], event["status"])
            == (summary["phase"], summary["status"])
        ]
        self.assertEqual(len(matching_terminal_events), 1)

    def test_cli_finalize_keeps_requested_artifacts_during_context_interleaving(self):
        root = self.attempt_root("finalize-context-interleaving")
        run_evidence._initialize_attempt(
            self.index_path,
            root,
            valid_context(
                runId=root.name,
                executionId=root.name + "-execution",
                artifacts={"trace": None, "report": None},
            ),
        )
        original_finalize = run_evidence.cli._finalize_attempt

        def finalize_after_context_update(*args, **kwargs):
            run_evidence.update_context(
                root,
                {"artifacts": {"trace": "traces/interleaved.json"}},
            )
            return original_finalize(*args, **kwargs)

        output = io.StringIO()
        with mock.patch.object(
            run_evidence.cli,
            "_finalize_attempt",
            side_effect=finalize_after_context_update,
        ), redirect_stdout(output):
            return_code = run_evidence.main(
                [
                    "finalize",
                    "--root",
                    str(root),
                    "--status",
                    "passed",
                    "--command-status",
                    "0",
                    "--trace",
                    "traces/requested.json",
                ]
            )

        self.assertEqual(return_code, 0)
        summary = json.loads(output.getvalue())
        self.assertEqual(summary["artifacts"]["trace"], "traces/requested.json")
        self.assertEqual(
            self.read_json(root / "run-context.json")["artifacts"]["trace"],
            "traces/requested.json",
        )

    @unittest.skipUnless(
        os.name == "posix",
        "requires immediate POSIX process-death semantics",
    )
    def test_cli_finalize_retry_is_request_safe_at_wal_boundaries(self):
        crash_code = """
import importlib.util
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_evidence_crash", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
stage = sys.argv[3]
position = int(sys.argv[4])
def die_at_boundary(actual_stage, actual_position):
    transaction_root = Path(sys.argv[2]).parent.parent / ".transactions"
    finalize_prepared = any(transaction_root.glob("finalize-*.json"))
    if (finalize_prepared and actual_stage == stage
            and actual_position == position):
        os._exit(92)

module.journal._transaction_checkpoint = die_at_boundary
raise SystemExit(module.main([
    "finalize",
    "--root", sys.argv[2],
    "--status", "passed",
    "--command-status", "0",
    "--trace", "traces/final.json",
    "--report", "reports/final.html",
]))
"""
        for case_number, (stage, position) in enumerate(
            (
                ("prepared", -1),
                ("target", 0),
                ("target", 1),
                ("target", 2),
            ),
            1,
        ):
            with self.subTest(stage=stage, position=position):
                run_id = f"cli-finalize-wal-{case_number}"
                root = self.attempt_root(run_id)
                run_evidence._initialize_attempt(
                    self.index_path,
                    root,
                    valid_context(
                        runId=run_id,
                        executionId=run_id + "-execution",
                        artifacts={"trace": None, "report": None},
                    ),
                )
                crashed = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        crash_code,
                        str(MODULE_PATH),
                        str(root),
                        stage,
                        str(position),
                    ],
                    cwd=REPOSITORY_ROOT,
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(
                    crashed.returncode, 92, crashed.stdout + crashed.stderr
                )

                retried = self.cli(
                    "finalize",
                    "--root",
                    root,
                    "--status",
                    "passed",
                    "--command-status",
                    "0",
                    "--trace",
                    "traces/final.json",
                    "--report",
                    "reports/final.html",
                )
                self.assertEqual(retried.returncode, 0, retried.stderr)
                recovered = json.loads(retried.stdout)
                self.assertEqual(
                    recovered, self.read_json(root / "run-summary.json")
                )
                committed_summary_bytes = (
                    root / "run-summary.json"
                ).read_bytes()
                self.assertEqual(
                    recovered["artifacts"]["trace"], "traces/final.json"
                )
                self.assertEqual(
                    recovered["artifacts"]["report"], "reports/final.html"
                )
                self.assertEqual(
                    len(
                        [
                            event
                            for event in self.read_events(root)
                            if (event["phase"], event["status"])
                            == (recovered["phase"], recovered["status"])
                        ]
                    ),
                    1,
                )

                duplicate = self.cli(
                    "finalize",
                    "--root",
                    root,
                    "--status",
                    "passed",
                    "--command-status",
                    "0",
                    "--trace",
                    "traces/final.json",
                    "--report",
                    "reports/final.html",
                )
                self.assertEqual(duplicate.returncode, 0, duplicate.stderr)
                self.assertEqual(json.loads(duplicate.stdout), recovered)
                self.assertEqual(
                    (root / "run-summary.json").read_bytes(),
                    committed_summary_bytes,
                )

        root = self.attempt_root("cli-finalize-wal-mismatch")
        run_evidence._initialize_attempt(
            self.index_path,
            root,
            valid_context(
                runId=root.name,
                executionId=root.name + "-execution",
                artifacts={"trace": None, "report": None},
            ),
        )
        crashed = subprocess.run(
            [
                sys.executable,
                "-c",
                crash_code,
                str(MODULE_PATH),
                str(root),
                "prepared",
                "-1",
            ],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(crashed.returncode, 92, crashed.stdout + crashed.stderr)

        mismatched = self.cli(
            "finalize",
            "--root",
            root,
            "--status",
            "passed",
            "--command-status",
            "0",
            "--trace",
            "traces/different.json",
            "--report",
            "reports/final.html",
        )
        self.assertEqual(mismatched.returncode, 2)
        self.assertIn(
            "recovered transaction request fingerprint does not match retry",
            mismatched.stderr,
        )
        self.assertEqual(
            self.read_json(root / "run-context.json")["artifacts"],
            {
                "trace": "traces/final.json",
                "report": "reports/final.html",
            },
        )
        self.assertEqual(
            self.read_json(root / "run-summary.json")["artifacts"]["trace"],
            "traces/final.json",
        )
        receipt_path = root / "finalize-receipt.json"
        receipt_after_mismatch = receipt_path.read_bytes()
        corrected = self.cli(
            "finalize",
            "--root",
            root,
            "--status",
            "passed",
            "--command-status",
            "0",
            "--trace",
            "traces/final.json",
            "--report",
            "reports/final.html",
        )
        self.assertEqual(corrected.returncode, 0, corrected.stderr)
        self.assertEqual(
            json.loads(corrected.stdout),
            self.read_json(root / "run-summary.json"),
        )
        self.assertEqual(receipt_path.read_bytes(), receipt_after_mismatch)

    def test_aggregate_retains_all_attempts_and_is_deterministic(self):
        first = self.attempt_root("run-1")
        run_evidence._initialize_attempt(self.index_path, first, valid_context())
        first_summary = run_evidence._finalize_attempt(first, "passed")
        second_context = valid_context(runId="run-2", attempt=2)
        second = self.attempt_root("run-2")
        run_evidence._initialize_attempt(self.index_path, second, second_context)
        second_summary = run_evidence._finalize_attempt(
            second,
            "failed",
            phase="scenario.execute",
            error_code="app.assertion_failed",
            summary_text="Assertion failed",
            hint="Inspect report",
            command_status=1,
        )
        aggregate = run_evidence._aggregate_summaries(
            [second / "run-summary.json", first]
        )
        self.assertEqual(aggregate["schemaVersion"], "1.0")
        self.assertEqual(len(aggregate["executions"]), 1)
        attempts = aggregate["executions"][0]["attempts"]
        self.assertEqual([item["attempt"] for item in attempts], [1, 2])
        self.assertEqual(attempts, [first_summary, second_summary])

        cli = self.cli(
            "aggregate",
            "--summary",
            second / "run-summary.json",
            "--summary",
            first,
            "--json",
        )
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertEqual(json.loads(cli.stdout), aggregate)

    def test_aggregate_enforces_summary_count_before_reading_inputs(self):
        with mock.patch.object(
            run_evidence.constants, "MAX_AGGREGATE_SUMMARY_COUNT", 1
        ):
            with self.assertRaisesRegex(
                ValueError, r"aggregate summary count exceeds maximum \(1\)"
            ):
                run_evidence._aggregate_summaries(
                    [
                        Path(self.temporary.name) / "missing-first.json",
                        Path(self.temporary.name) / "missing-second.json",
                    ]
                )

    def test_aggregate_enforces_cumulative_structured_input_bytes(self):
        root = self.attempt_root("aggregate-byte-limit")
        run_evidence._initialize_attempt(
            self.index_path,
            root,
            valid_context(runId=root.name, executionId="aggregate-byte-execution"),
        )
        summary_path = root / "run-summary.json"
        run_evidence._finalize_attempt(root, "passed")

        with mock.patch.object(
            run_evidence.constants, "MAX_AGGREGATE_INSPECTED_BYTES", 1
        ):
            with self.assertRaisesRegex(
                ValueError, r"aggregate input exceeds maximum inspected bytes \(1\)"
            ):
                run_evidence._aggregate_summaries([summary_path])

    def test_cli_help_discloses_validation_resource_limits(self):
        result = self.cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for value in (
            run_evidence.MAX_BUNDLE_FILE_COUNT,
            run_evidence.MAX_BUNDLE_INSPECTED_BYTES,
            run_evidence.MAX_STRUCTURED_JSON_BYTES,
            run_evidence.MAX_JSONL_LINE_BYTES,
            run_evidence.MAX_AGGREGATE_SUMMARY_COUNT,
            run_evidence.MAX_AGGREGATE_INSPECTED_BYTES,
        ):
            self.assertIn(str(value), result.stdout)


if __name__ == "__main__":
    unittest.main()
