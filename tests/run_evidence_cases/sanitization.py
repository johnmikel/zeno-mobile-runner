"""Secret, path, and argument sanitization cases."""

from .support import *  # noqa: F401,F403


class SanitizationTests(unittest.TestCase):
    def test_sanitize_text_redacts_secrets_roots_absolute_paths_and_url_credentials(self):
        roots = {
            "workspace": "/srv/work/repository",
            "run_root": "/srv/run/evidence",
            "home": "/Users/tester",
        }
        value = (
            "secret=top-secret workspace=/srv/work/repository/src/file.swift "
            "run=/srv/run/evidence/commands/a.log home=/Users/tester/.config "
            "other=/private/tmp/raw.txt windows=C:\\private\\raw.txt "
            "file=file:///private/tmp/uri.txt labelled=path:/var/tmp/label.txt "
            "url=https://alice:hunter2@example.test/resource "
            "token-url=https://opaque-token@example.test/resource"
        )
        sanitized = run_evidence.sanitize_text(
            value, roots=roots, secrets=["top-secret", "hunter2"]
        )
        self.assertNotIn("top-secret", sanitized)
        self.assertNotIn("hunter2", sanitized)
        self.assertNotIn("/srv/work/repository", sanitized)
        self.assertNotIn("/srv/run/evidence", sanitized)
        self.assertNotIn("/Users/tester", sanitized)
        self.assertNotIn("/private/tmp/raw.txt", sanitized)
        self.assertNotIn("C:\\private\\raw.txt", sanitized)
        self.assertNotIn("file:///private/tmp/uri.txt", sanitized)
        self.assertNotIn("path:/var/tmp/label.txt", sanitized)
        self.assertIn("${WORKSPACE}/src/file.swift", sanitized)
        self.assertIn("${RUN_ROOT}/commands/a.log", sanitized)
        self.assertIn("${HOME}/.config", sanitized)
        self.assertIn("<absolute-path>", sanitized)
        self.assertNotRegex(sanitized, r"https://[^/@\s]+:[^/@\s]+@")
        self.assertNotIn("opaque-token", sanitized)
        self.assertNotIn("<redacted>@", sanitized)
        self.assertIn("https://example.test/resource", sanitized)

    def test_root_replacement_observes_boundaries_and_long_secret_first(self):
        sanitized = run_evidence.sanitize_text(
            "/worktree/a /work/a abc123 abc",
            roots={"workspace": "/work", "run_root": "/run", "home": "/home/u"},
            secrets=["abc", "abc123"],
        )
        self.assertIn("<absolute-path>", sanitized)
        self.assertIn("${WORKSPACE}/a", sanitized)
        self.assertEqual(sanitized.count("<redacted>"), 2)

    def test_sensitive_environment_segments_and_custom_exact_names_are_collected(self):
        environment = {
            "API_TOKEN": "token-value",
            "db_password": "password-value",
            "HTTP_AUTHORIZATION_HEADER": "auth-value",
            "MONKEY": "not-secret",
            "CUSTOM_ONE": "custom-value",
            "ZMR_EVIDENCE_SECRET_NAMES": "CUSTOM_ONE,EXACT_MISSING",
        }
        values = run_evidence._collect_secret_values(environment)
        self.assertEqual(
            set(values),
            {"token-value", "password-value", "auth-value", "custom-value"},
        )

    def test_secret_collection_fails_closed_at_shared_scan_limits(self):
        exact_count = {
            f"API_TOKEN_{index}": f"secret-{index}" for index in range(64)
        }
        self.assertEqual(
            len(run_evidence._collect_secret_values(exact_count)), 64
        )

        over_count = dict(exact_count)
        over_count["API_TOKEN_64"] = "secret-64"
        with self.assertRaisesRegex(
            ValueError, "public-safety scan inputs exceed supported limits"
        ):
            run_evidence._collect_secret_values(over_count)

        class StopsAfterLimit(dict):
            def items(self):
                for index in range(65):
                    yield f"API_TOKEN_{index}", f"secret-{index}"
                raise AssertionError("collector read beyond the secret limit")

        with self.assertRaisesRegex(
            ValueError, "public-safety scan inputs exceed supported limits"
        ):
            run_evidence._collect_secret_values(StopsAfterLimit())

        with self.assertRaisesRegex(
            ValueError, "public-safety scan inputs exceed supported limits"
        ):
            run_evidence._collect_secret_values(
                {"API_TOKEN": "s" * (128 * 1024 + 1)}
            )

        exact_multibyte = "é" * (64 * 1024)
        self.assertLess(len(exact_multibyte), 128 * 1024)
        self.assertEqual(len(exact_multibyte.encode("utf-8")), 128 * 1024)
        self.assertEqual(
            run_evidence._collect_secret_values(
                {"API_TOKEN": exact_multibyte}
            ),
            [exact_multibyte],
        )
        with self.assertRaisesRegex(
            ValueError, "public-safety scan inputs exceed supported limits"
        ):
            run_evidence._collect_secret_values(
                {"API_TOKEN": exact_multibyte + "é"}
            )

        exact_aggregate = {
            "API_TOKEN_A": "a" * (128 * 1024),
            "API_TOKEN_B": "b" * (128 * 1024),
        }
        self.assertEqual(
            len(run_evidence._collect_secret_values(exact_aggregate)), 2
        )
        over_aggregate = dict(exact_aggregate)
        over_aggregate["API_TOKEN_C"] = "c"
        with self.assertRaisesRegex(
            ValueError, "public-safety scan inputs exceed supported limits"
        ):
            run_evidence._collect_secret_values(over_aggregate)

    def test_sanitization_roots_fail_closed_at_shared_scan_limits(self):
        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_WORKSPACE": "w" * (32 * 1024),
                "HOME": "h" * (32 * 1024),
            },
            clear=False,
        ):
            roots = run_evidence._sanitization_roots()
        self.assertEqual(
            sum(len(value.encode("utf-8")) for value in roots.values()),
            64 * 1024,
        )

        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_WORKSPACE": "w" * (32 * 1024 + 1),
                "HOME": "h" * (32 * 1024),
            },
            clear=False,
        ), self.assertRaisesRegex(
            ValueError, "public-safety scan inputs exceed supported limits"
        ):
            run_evidence._sanitization_roots()

    def test_public_sanitizers_fail_closed_on_over_limit_inputs(self):
        roots = {"workspace": "", "run_root": "", "home": ""}
        exact = [f"secret-{index}" for index in range(64)]
        self.assertEqual(
            run_evidence.sanitize_text(
                "public value", roots=roots, secrets=exact
            ),
            "public value",
        )
        self.assertEqual(
            run_evidence._sanitize_value(
                {"value": "public value"}, roots=roots, secrets=exact
            ),
            {"value": "public value"},
        )

        over = exact + ["secret-64"]
        for sanitize in (
            lambda: run_evidence.sanitize_text(
                "public value", roots=roots, secrets=over
            ),
            lambda: run_evidence._sanitize_value(
                {"value": "public value"}, roots=roots, secrets=over
            ),
        ):
            with self.subTest(sanitize=sanitize), self.assertRaisesRegex(
                ValueError, "public-safety scan inputs exceed supported limits"
            ):
                sanitize()

        with self.assertRaises(TypeError):
            run_evidence.sanitize_text(
                "public value",
                roots=roots,
                secrets=over,
                _inputs_validated=True,
            )

    def test_root_only_drive_paths_are_redacted_across_every_split(self):
        roots = {"workspace": "", "run_root": "", "home": ""}
        for value in ("C:/", "p:/", "x:\\", "\\\\"):
            raw = value.encode("ascii")
            self.assertEqual(
                run_evidence.sanitize_text(value, roots=roots, secrets=[]),
                "<absolute-path>",
            )
            for split in range(len(raw) + 1):
                sanitizer = run_evidence.StreamingSanitizer(
                    roots=roots, secrets=[]
                )
                sanitized = (
                    sanitizer.feed(raw[:split])
                    + sanitizer.feed(raw[split:])
                    + sanitizer.finish()
                )
                with self.subTest(value=value, split=split):
                    self.assertEqual(sanitized, b"<absolute-path>")

        ordinary_uri = "custom://host/public"
        self.assertEqual(
            run_evidence.sanitize_text(
                ordinary_uri, roots=roots, secrets=[]
            ),
            ordinary_uri,
        )

    def test_argv_redacts_credential_flags_equals_forms_and_urls(self):
        argv = [
            "tool",
            "--token",
            "not-in-environment",
            "--password=also-unknown",
            "--normal",
            "visible",
            "https://user:pass@example.test/x",
        ]
        sanitized = run_evidence._sanitize_argv(
            argv,
            roots={"workspace": "/workspace", "run_root": "/run", "home": "/home/u"},
            secrets=[],
        )
        self.assertEqual(sanitized[2], "<redacted>")
        self.assertEqual(sanitized[3], "--password=<redacted>")
        self.assertEqual(sanitized[5], "visible")
        self.assertNotIn("user:pass", sanitized[6])


class PersistenceSanitizationTests(CommandTestCase):
    def test_invalid_summary_diagnostics_are_sanitized_deduplicated_and_bounded(self):
        report = self.root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>sanitized report</html>", encoding="utf-8")
        secret = "invalid-summary-diagnostic-secret"
        unsafe = (
            f"secret={secret} workspace={REPOSITORY_ROOT}/src "
            f"run={self.root}/commands home={Path.home()}/.cache "
            "url=https://alice:password@example.test/diagnostic"
        )
        original_validate = run_evidence.summaries.validate_summary

        def injected_validation(summary):
            if summary.get("errorCode") == "runner.evidence_invalid":
                return original_validate(summary)
            return (
                [unsafe, unsafe, "!" * 10_000, "\udcff", 7, ""]
                + [f"synthetic diagnostic {index}" for index in range(300)]
            )

        with mock.patch.dict(
            os.environ, {"DIAGNOSTIC_TOKEN": secret}, clear=False
        ), mock.patch.object(
            run_evidence.summaries,
            "validate_summary",
            side_effect=injected_validation,
        ):
            summary = run_evidence._finalize_attempt(
                self.root,
                "failed",
                phase="scenario.execute",
                error_code="runner.unclassified",
                summary_text=unsafe,
                hint=unsafe,
                command_status=None,
            )

        diagnostics = self.read_json(
            self.root / "run-summary.invalid.errors.json"
        )["errors"]
        self.assertEqual(diagnostics, sorted(set(diagnostics)))
        self.assertLessEqual(len(diagnostics), 256)
        self.assertTrue(
            all(len(value.encode("utf-8")) <= 4096 for value in diagnostics)
        )
        self.assertTrue(any("truncated" in value for value in diagnostics))
        self.assertIn(
            "$: validation returned a non-Unicode scalar diagnostic",
            diagnostics,
        )
        self.assertIn("$: validation returned an empty diagnostic", diagnostics)
        self.assertIn("7", diagnostics)
        persisted = "".join(
            path.read_text(encoding="utf-8")
            for path in (
                self.root / "bootstrap-events.jsonl",
                self.root / "run-summary.json",
                self.root / "run-summary.invalid.json",
                self.root / "run-summary.invalid.errors.json",
            )
        )
        for raw in (
            secret,
            str(REPOSITORY_ROOT),
            str(self.root),
            str(Path.home()),
            "alice:password",
        ):
            self.assertNotIn(raw, persisted)
        for replacement in (
            "<redacted>",
            "${WORKSPACE}",
            "${RUN_ROOT}",
            "${HOME}",
            "https://example.test/diagnostic",
        ):
            self.assertIn(replacement, persisted)
        self.assertEqual(summary["errorCode"], "runner.evidence_invalid")
        self.assertEqual(run_evidence.validate_bundle(self.root, secrets=[secret]), [])
