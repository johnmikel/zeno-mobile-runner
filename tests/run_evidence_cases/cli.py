"""CLI and aggregate-summary cases."""

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


if __name__ == "__main__":
    unittest.main()
