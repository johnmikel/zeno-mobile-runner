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
