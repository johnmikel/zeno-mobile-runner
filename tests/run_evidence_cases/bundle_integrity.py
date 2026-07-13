"""Adversarial integrity cases for publishable evidence bundles."""

import hashlib
import shutil
import time

try:
    import resource
except ImportError:  # pragma: no cover - non-POSIX portability
    resource = None

from .support import *  # noqa: F401,F403


class BundleIntegrityTests(CommandTestCase):
    def make_bundle(self):
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
            "integrity-command",
            "--failure-code",
            "app.assertion_failed",
            "--",
            sys.executable,
            "-c",
            "print('safe-output')",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return run_evidence._finalize_attempt(
            self.root, "passed", command_status=0
        )

    def tamper_json(self, path, original, mutate):
        candidate = copy.deepcopy(original)
        mutate(candidate)
        path.write_text(json.dumps(candidate), encoding="utf-8")
        try:
            return run_evidence.validate_bundle(self.root, secrets=[])
        finally:
            path.write_text(json.dumps(original), encoding="utf-8")

    @staticmethod
    def deep_document(total_bytes, depth=2_000):
        framing = (2 * depth) + 2
        return (
            ("[" * depth)
            + '"'
            + ("x" * (total_bytes - framing))
            + '"'
            + ("]" * depth)
        ).encode("utf-8")

    def test_nested_file_and_directory_names_are_scanned_without_echoing_tokens(self):
        self.make_bundle()
        secret = "opaque-sensitive-name"
        denied = "cod" + "ex"
        cases = (
            ("secret directory", secret, secret),
            ("secret file", f"safe/{secret}.txt", secret),
            ("deny directory", denied, denied),
            ("deny file", f"safe/{denied}.txt", denied),
        )
        for label, relative, hidden in cases:
            with self.subTest(label=label):
                scan_root = self.root / "name-scan"
                target = scan_root / relative
                try:
                    if relative.endswith(".txt"):
                        target.parent.mkdir(parents=True)
                        target.write_bytes(b"safe")
                    else:
                        target.mkdir(parents=True)
                    errors = run_evidence.validate_bundle(
                        self.root, secrets=[secret]
                    )
                    joined = "\n".join(errors)
                    self.assertIn("unsafe publishable entry name", joined)
                    self.assertNotIn(hidden, joined)
                    self.assertNotIn("raw absolute path", joined)
                finally:
                    shutil.rmtree(scan_root)

    def test_unsafe_entry_name_never_leaks_through_secondary_diagnostics(self):
        self.make_bundle()
        secret = "secret-entry-name-token"
        denied = "cod" + "ex"
        (self.root / f"{secret}.json").write_bytes(b"not-json")
        (self.root / "commands" / f"{secret}-command.json").write_bytes(
            b"not-json"
        )
        outside = Path(self.temporary.name) / "outside"
        outside.write_bytes(b"outside")
        (self.root / f"{denied}-unsafe-link").symlink_to(outside)

        errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)
        self.assertIn("unsafe publishable entry name", joined)
        self.assertNotIn(secret, joined)
        self.assertNotIn(denied, joined)
        self.assertNotIn("invalid JSON", joined)
        self.assertNotIn("symlink", joined)

    def test_unsafe_entry_name_fanout_still_counts_toward_file_limit(self):
        self.make_bundle()
        secret = "unsafe-fanout-secret"
        existing = sum(1 for path in self.root.rglob("*") if not path.is_dir())
        for index in range(3):
            (self.root / f"{secret}-{index}.bin").write_bytes(b"safe")

        with mock.patch.object(
            run_evidence.constants, "MAX_BUNDLE_FILE_COUNT", existing + 2
        ):
            errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)
        self.assertIn("publishable bundle exceeds maximum file count", joined)
        self.assertNotIn(secret, joined)

    def test_windows_absolute_and_control_character_names_fail_generically(self):
        self.make_bundle()
        windows_name = r"C:\Users\alice\private.log"
        drive_tree_name = "D:/private.log"
        control_name = "line\nbreak.log"
        (self.root / windows_name).write_bytes(b"safe")
        (self.root / "D:").mkdir()
        (self.root / drive_tree_name).write_bytes(b"safe")
        (self.root / control_name).write_bytes(b"safe")

        errors = run_evidence.validate_bundle(self.root, secrets=[])
        joined = "\n".join(errors)
        self.assertIn("unsafe publishable entry name", joined)
        self.assertNotIn(windows_name, joined)
        self.assertNotIn(drive_tree_name, joined)
        self.assertNotIn(control_name, joined)
        for unsafe_name in (
            windows_name,
            drive_tree_name,
            control_name,
            "surrogate-\udcff.log",
        ):
            with self.subTest(unsafe_name=repr(unsafe_name)):
                name_errors = []
                self.assertTrue(
                    run_evidence.bundle_scan._scan_publishable_entry_name(
                        unsafe_name, [], name_errors
                    )
                )
                self.assertNotIn(unsafe_name, "\n".join(name_errors))

    def test_unsafe_attempt_root_name_fails_without_reflection(self):
        self.make_bundle()
        unsafe_name = "run\nunsafe"
        unsafe_root = self.publication_root / "attempts" / unsafe_name
        shutil.copytree(self.root, unsafe_root)

        errors = run_evidence.validate_bundle(unsafe_root, secrets=[])
        joined = "\n".join(errors)
        self.assertIn("unsafe publishable entry name", joined)
        self.assertNotIn(unsafe_name, joined)

    def test_summary_requires_canonical_bootstrap_and_command_artifacts(self):
        self.make_bundle()
        shutil.copyfile(
            self.root / "bootstrap-events.jsonl", self.root / "alternate-events.jsonl"
        )
        (self.root / "alternate-commands").mkdir()
        summary_path = self.root / "run-summary.json"
        summary = self.read_json(summary_path)
        summary["artifacts"].update(
            bootstrapEvents="alternate-events.jsonl",
            commands="alternate-commands",
        )
        summary_path.write_text(json.dumps(summary), encoding="utf-8")

        errors = run_evidence.validate_bundle(self.root, secrets=[])
        joined = "\n".join(errors)
        self.assertIn(
            "run-summary.json.artifacts.bootstrapEvents: must equal "
            "bootstrap-events.jsonl",
            joined,
        )
        self.assertIn(
            "run-summary.json.artifacts.commands: must equal commands", joined
        )

    def test_command_stream_paths_are_distinct_and_exact_to_metadata_stem(self):
        self.make_bundle()
        metadata_path = sorted((self.root / "commands").glob("*.json"))[0]
        original = self.read_json(metadata_path)
        expected_stdout = f"commands/{metadata_path.stem}.stdout.log"
        expected_stderr = f"commands/{metadata_path.stem}.stderr.log"

        outside = copy.deepcopy(original)
        outside["stdout"]["path"] = "reports/run.html"
        metadata_path.write_text(json.dumps(outside), encoding="utf-8")
        joined = "\n".join(run_evidence.validate_bundle(self.root, secrets=[]))
        self.assertIn("stdout.path: must be under commands/", joined)
        self.assertIn(f"stdout.path: must equal {expected_stdout}", joined)

        shared = copy.deepcopy(original)
        shared["stderr"]["path"] = shared["stdout"]["path"]
        metadata_path.write_text(json.dumps(shared), encoding="utf-8")
        joined = "\n".join(run_evidence.validate_bundle(self.root, secrets=[]))
        self.assertIn("stdout.path and stderr.path: must be distinct", joined)
        self.assertIn(f"stderr.path: must equal {expected_stderr}", joined)

    def test_terminal_event_human_summary_must_match_run_summary(self):
        self.make_bundle()
        events_path = self.root / "bootstrap-events.jsonl"
        events = self.read_events(self.root)
        events[-1]["summary"] = "tampered human-facing summary"
        events_path.write_text(
            "".join(json.dumps(event) + "\n" for event in events),
            encoding="utf-8",
        )

        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertIn(
            "bootstrap-events.jsonl: terminal event disagrees with summary", errors
        )

    def test_bundle_rejects_between_scan_and_validation_replacement(self):
        self.make_bundle()
        summary_path = self.root / "run-summary.json"
        original_scan = run_evidence.bundle._scan_publishable_files

        def replace_summary_after_scan(root, secrets, errors):
            result = original_scan(root, secrets, errors)
            summary_path.write_bytes(summary_path.read_bytes() + b" ")
            return result

        with mock.patch.object(
            run_evidence.bundle,
            "_scan_publishable_files",
            side_effect=replace_summary_after_scan,
        ):
            errors = run_evidence.validate_bundle(self.root, secrets=[])

        self.assertIn(
            "$: publishable bundle changed during validation", errors
        )

    def test_summary_timing_is_bound_to_context_event_and_exact_delta(self):
        self.make_bundle()
        summary_path = self.root / "run-summary.json"
        original = self.read_json(summary_path)
        cases = (
            (
                lambda value: value.update(
                    startedAt="2000-01-01T00:00:00.000Z"
                ),
                "run-summary.json.startedAt: disagrees with run-context.json",
            ),
            (
                lambda value: value.update(
                    finishedAt=value["startedAt"], durationMs=0
                ),
                "bootstrap-events.jsonl: terminal event timestamp disagrees with "
                "run-summary.json.finishedAt",
            ),
            (
                lambda value: value.update(durationMs=value["durationMs"] + 1),
                "run-summary.json.durationMs: must equal the exact "
                "startedAt/finishedAt delta",
            ),
        )
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                errors = self.tamper_json(summary_path, original, mutate)
                self.assertIn(expected, errors)

    def test_summary_artifacts_are_exact_context_projection_and_regular_files(self):
        self.make_bundle()
        summary_path = self.root / "run-summary.json"
        context_path = self.root / "run-context.json"
        original_summary = self.read_json(summary_path)
        original_context = self.read_json(context_path)
        alternate_report = self.root / "reports" / "alternate.html"
        alternate_report.write_text("safe alternate report", encoding="utf-8")

        errors = self.tamper_json(
            summary_path,
            original_summary,
            lambda value: value["artifacts"].update(
                report="reports/alternate.html"
            ),
        )
        self.assertIn(
            "run-summary.json.artifacts: disagrees with run-context.json", errors
        )

        invalid_context = copy.deepcopy(original_context)
        invalid_context["artifacts"]["screenshots"] = "screenshots"
        context_path.write_text(json.dumps(invalid_context), encoding="utf-8")
        try:
            errors = run_evidence.validate_bundle(self.root, secrets=[])
        finally:
            context_path.write_text(
                json.dumps(original_context), encoding="utf-8"
            )
        self.assertIn(
            "run-context.json.artifacts: contains unsupported fields", errors
        )

        trace_directory = self.root / "traces" / "directory-target"
        trace_directory.mkdir(parents=True)
        context = copy.deepcopy(original_context)
        summary = copy.deepcopy(original_summary)
        context["artifacts"]["trace"] = "traces/directory-target"
        summary["artifacts"]["trace"] = "traces/directory-target"
        context_path.write_text(json.dumps(context), encoding="utf-8")
        summary_path.write_text(json.dumps(summary), encoding="utf-8")
        try:
            errors = run_evidence.validate_bundle(self.root, secrets=[])
        finally:
            context_path.write_text(
                json.dumps(original_context), encoding="utf-8"
            )
            summary_path.write_text(
                json.dumps(original_summary), encoding="utf-8"
            )
        self.assertIn(
            "run-summary.json.artifacts.trace: referenced path must be a file",
            errors,
        )

    def test_attempt_index_decoded_strings_are_safety_scanned_without_attempt_walk(self):
        self.make_bundle()
        secret = "index-only-known-secret"
        index_path = self.publication_root / "attempt-index.json"
        index = self.read_json(index_path)
        index["executions"].append(
            {
                "executionId": secret,
                "comparabilityTuple": {
                    "fixtureId": "https://user:password@example.test/private",
                    "fixtureVersion": "/private/host/workspace",
                },
                "attempts": [
                    {
                        "runId": "unrelated-run",
                        "attempt": 1,
                        "summary": (
                            "attempts/unrelated-run/run-summary.json"
                        ),
                    }
                ],
            }
        )
        index_path.write_text(json.dumps(index), encoding="utf-8")

        errors = run_evidence.validate_bundle(self.root, secrets=[secret])

        self.assertIn(
            "attempt-index.json: contains a current known secret value", errors
        )
        self.assertIn("attempt-index.json: contains a credential URL", errors)
        self.assertIn("attempt-index.json: contains a raw absolute path", errors)
        self.assertFalse((self.root.parent / "unrelated-run").exists())

    def test_attempt_index_rejects_duplicate_object_keys_without_echoing_values(self):
        self.make_bundle()
        secret = "index-duplicate-known-secret"
        index_path = self.publication_root / "attempt-index.json"
        index = self.read_json(index_path)
        execution_id = index["executions"][0]["executionId"]
        encoded_key = json.dumps("executionId")
        encoded_value = json.dumps(execution_id)
        original_member = f"{encoded_key}:{encoded_value}"
        duplicate_member = (
            f"{encoded_key}:{json.dumps(secret)},{original_member}"
        )
        content = json.dumps(index, separators=(",", ":"))
        self.assertIn(original_member, content)
        index_path.write_text(
            content.replace(original_member, duplicate_member, 1),
            encoding="utf-8",
        )

        errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)

        self.assertIn("attempt-index.json", joined)
        self.assertIn("duplicate object key", joined)
        self.assertNotIn(secret, joined)

    def test_attempt_structured_file_rejects_nested_duplicate_object_keys(self):
        self.make_bundle()
        secret = "artifact-duplicate-known-secret"
        artifact = self.root / "duplicate-artifact.json"
        artifact.write_text(
            '{"outer":{"value":'
            + json.dumps(secret)
            + ',"value":"safe"}}',
            encoding="utf-8",
        )

        errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        joined = "\n".join(errors)

        self.assertIn("duplicate-artifact.json", joined)
        self.assertIn("duplicate object key", joined)
        self.assertNotIn(secret, joined)

    def test_attempt_index_replacement_after_scan_is_rejected(self):
        self.make_bundle()
        index_path = self.publication_root / "attempt-index.json"
        original_scan = run_evidence.bundle._scan_publishable_files

        def replace_index_after_scan(root, secrets, errors):
            result = original_scan(root, secrets, errors)
            index_path.write_bytes(index_path.read_bytes() + b" ")
            return result

        with mock.patch.object(
            run_evidence.bundle,
            "_scan_publishable_files",
            side_effect=replace_index_after_scan,
        ):
            errors = run_evidence.validate_bundle(self.root, secrets=[])

        self.assertIn(
            "$: publishable bundle changed during validation", errors
        )

    def test_finalize_receipt_is_bound_to_summary_digest(self):
        self.make_bundle()
        receipt_path = self.root / "finalize-receipt.json"
        self.assertTrue(receipt_path.is_file())
        receipt = self.read_json(receipt_path)
        receipt["resultSha256"] = "sha256:" + ("0" * 64)
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

        errors = run_evidence.validate_bundle(self.root, secrets=[])

        self.assertIn(
            "finalize-receipt.json: finalize receipt result hash "
            "disagrees with summary",
            errors,
        )

    def test_finalize_receipt_request_fingerprint_is_bound_to_summary(self):
        self.make_bundle()
        receipt_path = self.root / "finalize-receipt.json"
        summary_path = self.root / "run-summary.json"
        receipt = self.read_json(receipt_path)
        summary = self.read_json(summary_path)
        self.assertEqual(
            summary["finalizeRequestFingerprint"],
            receipt["requestFingerprint"],
        )

        receipt["requestFingerprint"] = "sha256:" + "0" * 64
        receipt_path.write_bytes(run_evidence._json_bytes(receipt))

        errors = run_evidence.validate_bundle(self.root, secrets=[])

        self.assertTrue(
            any("request fingerprint disagrees" in error for error in errors),
            errors,
        )

    def test_finalize_summary_request_binding_cannot_be_rebound_by_result_hash(self):
        self.make_bundle()
        receipt_path = self.root / "finalize-receipt.json"
        summary_path = self.root / "run-summary.json"
        receipt = self.read_json(receipt_path)
        summary = self.read_json(summary_path)
        summary["finalizeRequestFingerprint"] = "sha256:" + "0" * 64
        summary_content = run_evidence._json_bytes(summary)
        summary_path.write_bytes(summary_content)
        receipt["resultSha256"] = (
            "sha256:" + hashlib.sha256(summary_content).hexdigest()
        )
        receipt_path.write_bytes(run_evidence._json_bytes(receipt))

        errors = run_evidence.validate_bundle(self.root, secrets=[])

        self.assertTrue(
            any("request fingerprint disagrees" in error for error in errors),
            errors,
        )

    def test_receiptless_legacy_summary_remains_bundle_compatible(self):
        self.make_bundle()
        summary_path = self.root / "run-summary.json"
        summary = self.read_json(summary_path)
        summary.pop("finalizeRequestFingerprint", None)
        summary_path.write_bytes(run_evidence._json_bytes(summary))
        (self.root / "finalize-receipt.json").unlink()

        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])

    def test_lone_surrogate_json_is_reported_without_exception(self):
        self.make_bundle()
        (self.root / "surrogate.json").write_bytes(b'{"value":"\\udcff"}')

        errors = run_evidence.validate_bundle(self.root, secrets=[])

        self.assertIn(
            "surrogate.json: contains non-Unicode scalar text", errors
        )

    def test_bounded_json_decoder_rejects_duplicate_keys_at_every_object_depth(self):
        secret = "decoder-duplicate-known-secret"
        documents = (
            f'{{"value":"{secret}","value":"safe"}}',
            f'{{"outer":{{"value":"{secret}","value":"safe"}}}}',
            f'[{{"outer":{{"value":"{secret}","value":"safe"}}}}]',
        )

        for depth, document in enumerate(documents):
            with self.subTest(document_depth=depth):
                with self.assertRaises(ValueError) as raised:
                    run_evidence.bounded_io._decode_json_bytes(
                        document.encode("utf-8")
                    )
                self.assertEqual(str(raised.exception), "duplicate object key")
                self.assertNotIn(secret, str(raised.exception))

    def test_scanner_inputs_are_accepted_at_caps_and_rejected_beyond_them(self):
        self.make_bundle()
        diagnostic = "$: public-safety scan inputs exceed supported limits"
        scan = run_evidence.bundle_scan
        count_cap = scan._MAX_SCAN_SECRET_COUNT
        term_cap = scan._MAX_SCAN_TERM_BYTES
        total_cap = scan._MAX_SCAN_SECRET_TOTAL_BYTES
        root_cap = scan._MAX_SCAN_ROOT_TOTAL_BYTES

        at_count_cap = [f"absent-secret-{index:02d}" for index in range(count_cap)]
        self.assertEqual(
            run_evidence.validate_bundle(self.root, secrets=at_count_cap), []
        )
        self.assertIn(
            diagnostic,
            run_evidence.validate_bundle(
                self.root, secrets=at_count_cap + ["one-too-many"]
            ),
        )
        self.assertEqual(
            run_evidence.validate_bundle(self.root, secrets=["s" * term_cap]),
            [],
        )
        self.assertIn(
            diagnostic,
            run_evidence.validate_bundle(
                self.root, secrets=["s" * (term_cap + 1)]
            ),
        )
        self.assertIn(
            diagnostic,
            run_evidence.validate_bundle(
                self.root,
                secrets=[
                    chr(ord("a") + index) * (total_cap // 2)
                    for index in range(3)
                ],
            ),
        )

        scanner = scan._RawSemanticScanner(
            roots={"workspace": "r" * root_cap}, secrets=[]
        )
        self.assertLessEqual(scanner.carry_bytes, term_cap + 4)
        with self.assertRaisesRegex(
            ValueError, "public-safety scan inputs exceed supported limits"
        ):
            scan._RawSemanticScanner(
                roots={"workspace": "r" * (root_cap + 1)}, secrets=[]
            )

    def test_summary_root_and_context_identity_are_reconciled(self):
        self.make_bundle()
        summary_path = self.root / "run-summary.json"
        context_path = self.root / "run-context.json"
        summary = self.read_json(summary_path)
        context = self.read_json(context_path)
        cases = (
            (
                summary_path,
                summary,
                lambda value: value.update(runId="other-run"),
                "run-summary.json.runId: must match attempt root name",
            ),
            (
                context_path,
                context,
                lambda value: value.update(runId="other-run"),
                "run-context.json.runId: must match attempt root name",
            ),
            (
                summary_path,
                summary,
                lambda value: value.update(executionId="other-execution"),
                "run-summary.json.executionId: disagrees with run-context.json",
            ),
            (
                summary_path,
                summary,
                lambda value: value.update(attempt=2, firstAttempt=False),
                "run-summary.json.attempt: disagrees with run-context.json",
            ),
            (
                summary_path,
                summary,
                lambda value: value.update(fixtureId="other-fixture"),
                "run-summary.json.fixtureId: disagrees with run-context.json",
            ),
            (
                summary_path,
                summary,
                lambda value: value["host"].update({"class": "other-host"}),
                "run-summary.json.host: disagrees with run-context.json",
            ),
        )
        for path, original, mutate, expected in cases:
            with self.subTest(expected=expected):
                errors = self.tamper_json(path, original, mutate)
                self.assertIn(expected, errors)

    def test_attempt_root_must_be_under_canonical_attempts_parent(self):
        self.make_bundle()
        wrong_root = self.publication_root / "wrong-parent" / self.root.name
        shutil.copytree(self.root, wrong_root)

        errors = run_evidence.validate_bundle(wrong_root, secrets=[])
        self.assertIn(
            "$: attempt root must equal publication/attempts/<runId>", errors
        )

    def test_attempt_index_registration_is_exact_and_matches_raw_context_tuple(self):
        self.make_bundle()
        index_path = self.publication_root / "attempt-index.json"
        index = self.read_json(index_path)
        cases = (
            (
                lambda value: value["executions"][0].update(
                    executionId="other-execution"
                ),
                "attempt-index.json: registration executionId disagrees with context",
            ),
            (
                lambda value: value["executions"][0]["comparabilityTuple"].update(
                    candidateRevision="d" * 40
                ),
                "attempt-index.json: raw comparability tuple disagrees with context",
            ),
            (
                lambda value: value["executions"][0]["attempts"][0].update(
                    summary="./attempts/run-1/run-summary.json"
                ),
                "attempt-index.json: summary reference is not normalized",
            ),
            (
                lambda value: value["executions"][0]["attempts"].append(
                    {
                        "runId": "run-1",
                        "attempt": 2,
                        "summary": "attempts/run-1/run-summary.json",
                    }
                ),
                "attempt-index.json: runId must have exactly one registration",
            ),
        )
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                errors = self.tamper_json(index_path, index, mutate)
                self.assertIn(expected, errors)

    def test_deep_json_is_normalized_for_artifacts_summary_metadata_and_jsonl(self):
        self.make_bundle()
        metadata_path = sorted((self.root / "commands").glob("*.json"))[0]
        cases = (
            (self.root / "deep-arbitrary.json", None, 1024 * 1024),
            (
                self.root / "run-summary.json",
                (self.root / "run-summary.json").read_bytes(),
                1024 * 1024,
            ),
            (metadata_path, metadata_path.read_bytes(), 1024 * 1024),
            (
                self.root / "bootstrap-events.jsonl",
                (self.root / "bootstrap-events.jsonl").read_bytes(),
                240 * 1024,
            ),
        )
        for path, original, size in cases:
            with self.subTest(path=path.name):
                try:
                    path.write_bytes(self.deep_document(size) + (b"\n" if path.suffix == ".jsonl" else b""))
                    try:
                        errors = run_evidence.validate_bundle(self.root, secrets=[])
                    except RecursionError as exc:
                        self.fail(f"RecursionError escaped validation: {exc}")
                    self.assertTrue(
                        any("nesting exceeds supported depth" in error for error in errors),
                        errors,
                    )
                finally:
                    if original is None:
                        path.unlink(missing_ok=True)
                    else:
                        path.write_bytes(original)

    def test_validate_bundle_cli_reports_deep_json_without_traceback(self):
        self.make_bundle()
        artifact = self.root / "deep-cli-artifact.json"
        artifact.write_bytes(self.deep_document(1024 * 1024))

        result = self.cli("validate-bundle", "--root", self.root)
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        self.assertEqual(result.returncode, 1, output)
        self.assertIn("nesting exceeds supported depth", output)
        self.assertNotIn("Traceback", output)
        self.assertNotIn("RecursionError", output)

    def test_validate_bundle_cli_accepts_relative_attempt_root(self):
        self.make_bundle()
        relative_root = os.path.relpath(self.root, REPOSITORY_ROOT)

        result = self.cli("validate-bundle", "--root", relative_root)
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")

        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(json.loads(result.stdout), {"valid": True})

    def test_empty_or_missing_transaction_directory_is_publishable(self):
        self.make_bundle()
        transactions = self.publication_root / ".transactions"
        self.assertTrue(transactions.is_dir())
        self.assertEqual(list(transactions.iterdir()), [])
        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])

        transactions.rmdir()
        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[]), [])
        self.assertFalse(transactions.exists())

    def test_pending_transaction_preflight_is_read_only_and_precedes_bundle_scan(self):
        self.make_bundle()
        transactions = self.publication_root / ".transactions"
        oversized = transactions / "pending-oversized.json"
        with oversized.open("wb") as handle:
            handle.truncate(512 * 1024 * 1024)
        before = oversized.stat()

        with mock.patch.object(
            run_evidence.bundle,
            "_scan_publishable_files",
            side_effect=AssertionError("attempt scan started before WAL preflight"),
        ):
            errors = run_evidence.validate_bundle(self.root, secrets=[])

        self.assertEqual(
            errors,
            ["transactions: pending transaction state prevents publication"],
        )
        after = oversized.stat()
        self.assertEqual((after.st_ino, after.st_size), (before.st_ino, before.st_size))

    def test_excessive_pending_transaction_count_is_rejected_without_deletion(self):
        self.make_bundle()
        transactions = self.publication_root / ".transactions"
        count = 5_000
        for index in range(count):
            (transactions / f"pending-{index:05d}.json").touch()

        with mock.patch.object(
            run_evidence.bundle,
            "_scan_publishable_files",
            side_effect=AssertionError("attempt scan started before WAL preflight"),
        ):
            errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertEqual(
            errors,
            ["transactions: pending transaction state prevents publication"],
        )
        self.assertEqual(sum(1 for _ in transactions.iterdir()), count)

    @unittest.skipUnless(
        os.name == "posix" and resource is not None and hasattr(resource, "RLIMIT_AS"),
        "requires POSIX RLIMIT_AS",
    )
    def test_oversized_pending_journal_stays_within_bounded_address_space(self):
        self.make_bundle()
        journal = self.publication_root / ".transactions" / "pending-huge.json"
        with journal.open("wb") as handle:
            handle.truncate(512 * 1024 * 1024)

        headroom = 128 * 1024 * 1024
        if sys.platform == "darwin":
            virtual = int(
                subprocess.check_output(
                    ["ps", "-o", "vsz=", "-p", str(os.getpid())], text=True
                ).strip()
            ) * 1024
            address_limit = virtual + headroom
        else:
            address_limit = headroom

        def limit_address_space():
            _soft, hard = resource.getrlimit(resource.RLIMIT_AS)
            resource.setrlimit(resource.RLIMIT_AS, (address_limit, hard))

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
            timeout=30,
            check=False,
        )
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        self.assertEqual(result.returncode, 1, output)
        self.assertIn("pending transaction state prevents publication", output)
        self.assertNotIn("Traceback", output)
        self.assertEqual(journal.stat().st_size, 512 * 1024 * 1024)

    def test_unbounded_uri_schemes_and_absolute_paths_fail_closed_across_chunks(self):
        self.make_bundle()
        chunk = run_evidence._BUNDLE_SCAN_CHUNK_BYTES
        assignment = b"prefix="
        scheme = b"a" + (b"1" * ((2 * chunk) - len(assignment) - 2))
        artifacts = {
            "long-digit-scheme": assignment
            + scheme
            + b"://user:password@example.test/private",
            "long-file-url": b"file:///private/" + (b"f" * (2 * chunk)),
            "long-posix-path": b"/private/tmp/" + (b"p" * (2 * chunk)),
            "long-windows-path": b"C:\\private\\" + (b"w" * (2 * chunk)),
            "long-unc-path": b"\\\\server\\share\\" + (b"u" * (2 * chunk)),
            "unrelated-digit-binary": (b"9" * (2 * chunk)) + (b"\x80" * chunk),
        }
        for name, content in artifacts.items():
            (self.root / name).write_bytes(content)

        errors = run_evidence.validate_bundle(self.root, secrets=[])
        joined = "\n".join(errors)
        for name in artifacts:
            if name == "unrelated-digit-binary":
                self.assertFalse(
                    any(error.startswith(name + ":") for error in errors), errors
                )
                continue
            self.assertIn(f"{name}: semantic token exceeds scan limit", errors)
        self.assertIn("long-digit-scheme: contains a credential URL", joined)
        for name in (
            "long-file-url",
            "long-posix-path",
            "long-windows-path",
            "long-unc-path",
        ):
            self.assertIn(f"{name}: contains a raw absolute path", errors)

    def test_structured_long_scheme_scan_is_linear_and_detects_credentials(self):
        self.make_bundle()
        chunk = run_evidence._BUNDLE_SCAN_CHUNK_BYTES
        scheme = "a" + ("1" * (2 * chunk))
        artifact = self.root / "long-structured-url.json"
        artifact.write_text(
            json.dumps(
                {
                    "credential": (
                        f"prefix={scheme}://user:password@example.test/path"
                    ),
                    "worstCaseNoDelimiter": "a" * (2 * chunk),
                }
            ),
            encoding="utf-8",
        )

        try:
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
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            self.fail("structured credential scan exceeded its linear-time budget")
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        self.assertEqual(result.returncode, 1, output)
        self.assertIn("long-structured-url.json: contains a credential URL", output)
        self.assertIn("semantic token exceeds scan limit", output)

    def test_nested_credential_url_in_one_raw_token_is_detected(self):
        self.make_bundle()
        artifact = self.root / "nested-credential-token"
        artifact.write_bytes(
            b"outer://host/path(https://user:password@example.test/private)"
        )

        errors = run_evidence.validate_bundle(self.root, secrets=[])
        self.assertIn("nested-credential-token: contains a credential URL", errors)

    def test_nested_credential_candidates_restart_across_punctuation(self):
        punctuation = b"!%*+-.:_~()[]{}"
        for location in (b"authority", b"path"):
            for value in punctuation:
                with self.subTest(location=location, punctuation=chr(value)):
                    if location == b"authority":
                        content = (
                            b"outer://host"
                            + bytes((value,))
                            + b"https://user:pass@example.test"
                        )
                    else:
                        content = (
                            b"outer://host/path"
                            + bytes((value,))
                            + b"https://user:pass@example.test"
                        )
                    scanner = run_evidence.bundle_scan._RawSemanticScanner(
                        roots={}, secrets=[]
                    )
                    scanner.feed(content)
                    self.assertIn("credential_url", scanner.finish())

    def test_delimiter_dense_raw_scan_reuses_predecessor_state(self):
        predecessor_set = getattr(
            run_evidence.bundle_scan,
            "_POSIX_DISALLOWED_PREDECESSORS",
            None,
        )
        self.assertIsInstance(predecessor_set, frozenset)
        scanner = run_evidence.bundle_scan._RawSemanticScanner(
            roots={}, secrets=[]
        )
        payload = b"x " * (16 * 1024 * 1024)
        started = time.monotonic()
        for offset in range(0, len(payload), 64 * 1024):
            scanner.feed(payload[offset : offset + (64 * 1024)])
        flags = scanner.finish()
        elapsed = time.monotonic() - started
        self.assertEqual(flags, set())
        self.assertLess(elapsed, 5.0)
