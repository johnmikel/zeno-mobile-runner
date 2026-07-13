"""Evidence bundle validation cases."""

try:
    import resource
except ImportError:  # pragma: no cover - non-POSIX portability
    resource = None
import tracemalloc

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

    def test_command_link_projection_does_not_retain_invalid_large_strings(self):
        large = "x" * 100_000
        projection = run_evidence.bundle._command_link_projection(
            {
                "source": large,
                "failureCode": large,
                "phase": large,
                "exitStatus": 0,
                "signal": None,
                "outcome": large,
            }
        )
        self.assertEqual(
            projection,
            {
                "source": None,
                "failureCode": None,
                "phase": None,
                "exitStatus": 0,
                "signal": None,
                "outcome": None,
            },
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

    def test_valid_json_escape_sequences_do_not_become_raw_windows_paths(self):
        self.make_bundle()
        artifact = self.root / "escaped-script.json"
        artifact.write_text(
            json.dumps({"script": "os.write(1, b'\\xff')"}), encoding="utf-8"
        )
        summary_path = self.root / "run-summary.json"
        summary = self.read_json(summary_path)
        summary["artifacts"]["report"] = artifact.name
        summary_path.write_text(json.dumps(summary), encoding="utf-8")

        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])

    def test_deep_bounded_json_is_scanned_without_recursive_python_walk(self):
        self.make_bundle()
        artifact = self.root / "deep-structure.json"
        depth = 200
        artifact.write_text("[" * depth + '"safe"' + "]" * depth, encoding="utf-8")
        summary_path = self.root / "run-summary.json"
        summary = self.read_json(summary_path)
        summary["artifacts"]["report"] = artifact.name
        summary_path.write_text(json.dumps(summary), encoding="utf-8")

        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])

    def test_bundle_artifacts_are_streamed_without_whole_file_reader(self):
        secret = "streamed-artifact-secret"
        self.make_bundle()
        binary = self.root / "large-trace.bin"
        extensionless = self.root / "extensionless-report"
        binary.write_bytes(b"\x00\xff" + secret.encode("utf-8") + b"\x00" * 4096)
        extensionless.write_text("safe extensionless artifact", encoding="utf-8")

        original = run_evidence.bundle._evidence_read_bytes

        def reject_whole_artifact_read(path):
            if Path(path) in (binary, extensionless):
                raise AssertionError("publishable artifact was read in full")
            return original(path)

        with mock.patch.object(
            run_evidence.bundle,
            "_evidence_read_bytes",
            side_effect=reject_whole_artifact_read,
        ):
            errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        self.assertIn(
            "large-trace.bin: contains a current known secret value", errors
        )

    def test_bundle_file_and_inspected_byte_limits_fail_deterministically(self):
        self.make_bundle()
        with mock.patch.object(
            run_evidence.constants, "MAX_BUNDLE_FILE_COUNT", 1
        ):
            file_errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertEqual(
            [error for error in file_errors if "file count" in error],
            ["$: publishable bundle exceeds maximum file count (1)"],
        )

        with mock.patch.object(
            run_evidence.constants, "MAX_BUNDLE_INSPECTED_BYTES", 1
        ):
            byte_errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertEqual(
            [error for error in byte_errors if "inspected bytes" in error],
            ["$: publishable bundle exceeds maximum inspected bytes (1)"],
        )

    def test_bundle_file_limit_counts_files_without_charging_directories(self):
        self.make_bundle()
        existing_files = sum(1 for path in self.root.rglob("*") if path.is_file())
        (self.root / "empty-directory").mkdir()

        with mock.patch.object(
            run_evidence.constants, "MAX_BUNDLE_FILE_COUNT", existing_files
        ):
            at_limit = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertFalse(any("file count" in error for error in at_limit), at_limit)

        (self.root / "one-file-over").write_bytes(b"safe")
        with mock.patch.object(
            run_evidence.constants, "MAX_BUNDLE_FILE_COUNT", existing_files
        ):
            over_limit = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertEqual(
            [error for error in over_limit if "file count" in error],
            [
                "$: publishable bundle exceeds maximum file count "
                f"({existing_files})"
            ],
        )

    def test_structured_json_and_jsonl_lines_have_explicit_byte_limits(self):
        self.make_bundle()
        with mock.patch.object(
            run_evidence.constants, "MAX_STRUCTURED_JSON_BYTES", 32
        ):
            json_errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(
            any("run-summary.json: structured JSON exceeds 32 bytes" == error
                for error in json_errors),
            json_errors,
        )

        with mock.patch.object(
            run_evidence.constants, "MAX_JSONL_LINE_BYTES", 16
        ):
            jsonl_errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertTrue(
            any(
                error.startswith("bootstrap-events.jsonl:1: JSONL line exceeds 16 bytes")
                for error in jsonl_errors
            ),
            jsonl_errors,
        )

    def test_large_event_log_is_validated_without_retaining_every_decoded_event(self):
        self.make_bundle()
        events_path = self.root / "bootstrap-events.jsonl"
        original_events = self.read_events(self.root)
        terminal = original_events[-1]
        sequence = 0
        with events_path.open("w", encoding="utf-8") as handle:
            for event in original_events[:-1]:
                sequence += 1
                event["seq"] = sequence
                handle.write(json.dumps(event, separators=(",", ":")) + "\n")
            for _ in range(30_000):
                sequence += 1
                handle.write(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "seq": sequence,
                            "timestamp": "2026-07-13T00:00:00.000Z",
                            "phase": "scenario.validate",
                            "status": "skipped",
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                )
            sequence += 1
            terminal["seq"] = sequence
            handle.write(json.dumps(terminal, separators=(",", ":")) + "\n")

        tracemalloc.start()
        try:
            errors = run_evidence.validate_bundle(self.root, secrets=[])
            _current, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(errors, [])
        self.assertLess(peak, 12 * 1024 * 1024)

    def test_validation_diagnostics_are_deduplicated_and_bounded(self):
        self.make_bundle()
        events_path = self.root / "bootstrap-events.jsonl"
        events_path.write_text("not-json\n" * 5_000, encoding="utf-8")

        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertLessEqual(len(errors), 4_097)
        self.assertIn(
            "$: validation diagnostics exceed maximum (4096)", errors
        )

    @unittest.skipUnless(
        os.name == "posix" and resource is not None and hasattr(resource, "RLIMIT_AS"),
        "requires POSIX RLIMIT_AS",
    )
    def test_large_artifact_validation_stays_within_bounded_address_space(self):
        self.make_bundle()
        artifact = self.root / "large-extensionless-artifact"
        with artifact.open("wb") as handle:
            handle.truncate(128 * 1024 * 1024)

        address_space_headroom = 192 * 1024 * 1024
        if sys.platform == "darwin":
            current_virtual_bytes = int(
                subprocess.check_output(
                    ["ps", "-o", "vsz=", "-p", str(os.getpid())], text=True
                ).strip()
            ) * 1024
            address_space_limit = current_virtual_bytes + address_space_headroom
        else:
            address_space_limit = address_space_headroom

        def limit_address_space():
            _soft, hard = resource.getrlimit(resource.RLIMIT_AS)
            resource.setrlimit(resource.RLIMIT_AS, (address_space_limit, hard))

        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "validate-bundle",
                "--root",
                str(self.root),
            ],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            preexec_fn=limit_address_space,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])

    def test_streaming_scan_detects_patterns_split_across_chunk_boundaries(self):
        self.make_bundle()
        secret = "split-known-secret"
        markers = {
            "split-secret": secret,
            "split-url": "https://user:password@example.test/path",
            "split-path": "/private/tmp/raw-path",
            "split-deny": "cod" + "ex",
        }
        chunk_size = run_evidence._BUNDLE_SCAN_CHUNK_BYTES
        for name, marker in markers.items():
            prefix_size = chunk_size - max(1, len(marker.encode("utf-8")) // 2)
            prefix = b"x" * prefix_size
            if name == "split-path":
                prefix = prefix[:-1] + b" "
            (self.root / name).write_bytes(
                prefix + marker.encode("utf-8") + b"\n"
            )

        errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)
        self.assertIn("split-secret: contains a current known secret value", joined)
        self.assertIn("split-url: contains a credential URL", joined)
        self.assertIn("split-path: contains a raw absolute path", joined)
        self.assertIn("split-deny: contains a public safety deny pattern", joined)

    def test_streaming_scan_carry_expands_for_long_known_secret(self):
        self.make_bundle()
        secret = "s" * (run_evidence._BUNDLE_SCAN_OVERLAP_BYTES + 257) + "-tail"
        prefix_size = run_evidence._BUNDLE_SCAN_CHUNK_BYTES - 97
        artifact = self.root / "long-known-secret"
        artifact.write_bytes(
            b"x" * prefix_size + secret.encode("utf-8") + b"\n"
        )

        original = run_evidence.bundle._evidence_read_bytes

        def reject_whole_artifact_read(path):
            if Path(path) == artifact:
                raise AssertionError("long secret artifact was read in full")
            return original(path)

        with mock.patch.object(
            run_evidence.bundle,
            "_evidence_read_bytes",
            side_effect=reject_whole_artifact_read,
        ):
            errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        self.assertIn(
            "long-known-secret: contains a current known secret value", errors
        )

    def test_long_sensitive_tokens_fail_closed_but_unrelated_binary_streams(self):
        self.make_bundle()
        token_size = run_evidence._BUNDLE_SCAN_OVERLAP_BYTES + 1024
        (self.root / "long-credential-url").write_bytes(
            b"https://user:" + b"p" * token_size + b"@example.test"
        )
        (self.root / "long-absolute-path").write_bytes(
            b"/private/tmp/" + b"p" * token_size
        )
        (self.root / "unrelated-binary").write_bytes(b"\x80" * (token_size * 2))

        errors = run_evidence.validate_bundle(self.root, secrets=[])
        semantic_limit_errors = [
            error for error in errors if "semantic token exceeds scan limit" in error
        ]
        self.assertEqual(
            semantic_limit_errors,
            [
                "long-absolute-path: semantic token exceeds scan limit",
                "long-credential-url: semantic token exceeds scan limit",
            ],
        )
        self.assertFalse(
            any(error.startswith("unrelated-binary:") for error in errors), errors
        )


from .bundle_integrity import BundleIntegrityTests  # noqa: E402,F401
