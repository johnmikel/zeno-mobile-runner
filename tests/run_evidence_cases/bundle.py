"""Evidence bundle validation cases."""

from .support import *  # noqa: F401,F403


class BundleValidationTests(CommandTestCase):
    def make_bundle(self, command_status=0):
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>apparently sanitized report</html>", encoding="utf-8")
        result = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "scenario.execute",
            "--name",
            "bundle-command",
            "--failure-code",
            "app.assertion_failed",
            "--",
            sys.executable,
            "-c",
            "print('bundle-output')",
        )
        self.assertEqual(result.returncode, 0)
        return run_evidence._finalize_attempt(
            self.root, "passed", command_status=command_status
        )

    def make_failed_bundle(self):
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>sanitized report</html>", encoding="utf-8")
        result = self.cli(
            "command",
            "--root",
            self.root,
            "--phase",
            "scenario.execute",
            "--name",
            "failed-command",
            "--failure-code",
            "app.assertion_failed",
            "--",
            sys.executable,
            "-c",
            "import sys;sys.exit(7)",
        )
        self.assertEqual(result.returncode, 7)
        return run_evidence._finalize_attempt(
            self.root,
            "failed",
            phase="scenario.execute",
            error_code="app.assertion_failed",
            summary_text="Assertion failed",
            hint="Inspect report",
            command_status=7,
        )

    def test_valid_bundle_checks_summary_events_and_command_records(self):
        self.make_bundle()
        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])
        cli = self.cli("validate-bundle", "--root", self.root)
        self.assertEqual(cli.returncode, 0, cli.stderr)

        comparison_term = "app" + "ium"
        (self.root / "reports" / "run.html").write_text(
            comparison_term, encoding="utf-8"
        )
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("deny pattern" in error for error in errors), errors)

    def test_canonical_url_redaction_passes_bundle_credential_scan(self):
        self.make_bundle()
        sanitized = run_evidence.sanitize_text(
            "https://user:password@example.test/x https://opaque@example.test/y",
            roots={"workspace": "", "run_root": "", "home": ""},
            secrets=[],
        )
        (self.root / "reports" / "run.html").write_text(
            sanitized, encoding="utf-8"
        )
        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])

    def test_command_event_requires_exact_metadata_reference(self):
        self.make_bundle()
        events_path = self.root / "bootstrap-events.jsonl"
        events = self.read_events(self.root)
        command_terminal = next(
            event
            for event in events
            if event.get("command") and event["status"] == "passed"
        )
        command_terminal["command"] = "arbitrary command text"
        events_path.write_text(
            "".join(json.dumps(event) + "\n" for event in events), encoding="utf-8"
        )
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("metadata reference" in error for error in errors), errors)

    def test_failed_command_event_and_metadata_semantics_are_linked(self):
        self.make_failed_bundle()
        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])
        metadata_path = sorted((self.root / "commands").glob("*.json"))[0]
        metadata = self.read_json(metadata_path)
        metadata.update(
            phase="app.build",
            failureCode="runner.unclassified",
            exitStatus=9,
        )
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        joined = "\n".join(errors)
        self.assertIn("phase", joined)
        self.assertIn("failureCode", joined)
        self.assertIn("exitStatus", joined)
        self.assertIn("commandStatus", joined)

    def test_detects_event_sequence_and_terminal_tampering(self):
        self.make_bundle()
        events_path = self.root / "bootstrap-events.jsonl"
        events = self.read_events(self.root)
        events[1]["seq"] = 9
        events[-1]["phase"] = "cleanup"
        events_path.write_text(
            "".join(json.dumps(event) + "\n" for event in events), encoding="utf-8"
        )
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("sequence" in error for error in errors), errors)
        self.assertTrue(any("terminal" in error for error in errors), errors)

    def test_detects_missing_records_metadata_mismatch_and_path_traversal(self):
        self.make_bundle()
        metadata_path = sorted((self.root / "commands").glob("*.json"))[0]
        metadata = self.read_json(metadata_path)
        metadata["stdout"]["storedBytes"] += 1
        metadata["stderr"]["path"] = "../outside.log"
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("storedBytes" in error for error in errors), errors)
        self.assertTrue(any("normalized" in error or "escape" in error for error in errors), errors)
        metadata_path.unlink()
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("command record" in error for error in errors), errors)

    def test_requires_command_ownership_and_source_specific_metadata(self):
        self.make_bundle()
        metadata_path = sorted((self.root / "commands").glob("*.json"))[0]
        metadata = self.read_json(metadata_path)
        del metadata["failureCode"]
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        summary_path = self.root / "run-summary.json"
        summary = self.read_json(summary_path)
        summary["commandStatus"] = 9
        summary_path.write_text(json.dumps(summary), encoding="utf-8")
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("failureCode" in error for error in errors), errors)
        self.assertTrue(any("commandStatus" in error for error in errors), errors)

    def test_external_metadata_requires_honest_outcome_and_limitation(self):
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>sanitized report</html>", encoding="utf-8")
        run_evidence._record_external(
            self.root,
            "app.build",
            "external-build",
            "success",
            "infra.hosted_runner",
        )
        run_evidence._finalize_attempt(self.root, "passed", command_status=None)
        metadata_path = sorted((self.root / "commands").glob("*.json"))[0]
        metadata = self.read_json(metadata_path)
        del metadata["outcome"]
        del metadata["limitation"]
        metadata["exitStatus"] = 0
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("outcome" in error for error in errors), errors)
        self.assertTrue(any("limitation" in error for error in errors), errors)
        self.assertTrue(any("exitStatus" in error for error in errors), errors)

    def test_rejects_symlinked_command_logs(self):
        self.make_bundle()
        metadata = self.command_metadata()[0]
        stdout_path = self.root / metadata["stdout"]["path"]
        outside = Path(self.temporary.name) / "outside.log"
        outside.write_text("outside", encoding="utf-8")
        stdout_path.unlink()
        stdout_path.symlink_to(outside)
        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(any("symlink" in error for error in errors), errors)

    def test_scans_context_logs_and_diagnostics_for_secrets_paths_urls_and_deny_terms(self):
        secret = "bundle-secret-value"
        self.make_bundle()
        context_path = self.root / "run-context.json"
        forbidden = "cod" + "ex"
        context_path.write_text(
            json.dumps(
                {
                    "leak": secret,
                    "path": "/private/tmp/leak.txt",
                    "url": "https://user:password@example.test/x",
                    "deny": forbidden,
                }
            ),
            encoding="utf-8",
        )
        errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)
        self.assertIn("secret", joined)
        self.assertIn("absolute path", joined)
        self.assertIn("credential URL", joined)
        self.assertIn("deny pattern", joined)

    def test_scans_binary_and_extensionless_referenced_artifacts(self):
        secret = "binary-bundle-secret"
        self.make_bundle()
        binary = self.root / "trace.bin"
        extensionless = self.root / "published-artifact"
        binary.write_bytes(b"\x00\xff" + secret.encode() + b"\x00")
        denied = "cod" + "ex"
        extensionless.write_bytes(
            (
                "path=/private/tmp/raw credential=https://user:pass@example.test/x "
                + denied
            ).encode()
        )
        summary_path = self.root / "run-summary.json"
        summary = self.read_json(summary_path)
        summary["artifacts"]["trace"] = "trace.bin"
        summary["artifacts"]["report"] = "published-artifact"
        summary_path.write_text(json.dumps(summary), encoding="utf-8")
        errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)
        self.assertIn("trace.bin: contains a current known secret value", joined)
        self.assertIn("published-artifact: contains a raw absolute path", joined)
        self.assertIn("published-artifact: contains a credential URL", joined)
        self.assertIn("published-artifact: contains a public safety deny pattern", joined)

    def test_scans_recursive_json_object_keys_for_every_semantic_category(self):
        secret = "clé-secret-key"
        self.make_bundle()
        artifact = self.root / "key-artifact.json"
        deny_key = "cod" + "ex"
        artifact.write_text(
            json.dumps(
                {
                    "nested": {
                        secret: "safe",
                        "/private/tmp/key-path": "safe",
                        "https://user:password@example.test/key": "safe",
                        deny_key: "safe",
                    }
                }
            ),
            encoding="utf-8",
        )
        summary_path = self.root / "run-summary.json"
        summary = self.read_json(summary_path)
        summary["artifacts"]["report"] = "key-artifact.json"
        summary_path.write_text(json.dumps(summary), encoding="utf-8")

        errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)
        self.assertIn("key-artifact.json: contains a current known secret value", joined)
        self.assertIn("key-artifact.json: contains a raw absolute path", joined)
        self.assertIn("key-artifact.json: contains a credential URL", joined)
        self.assertIn("key-artifact.json: contains a public safety deny pattern", joined)
