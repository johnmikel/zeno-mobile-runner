"""Comparability, classification, and schema-contract cases."""

from .support import *  # noqa: F401,F403


class ComparabilityTests(unittest.TestCase):
    def test_public_vocabularies_match_schema_contract(self):
        self.assertEqual(
            run_evidence.PHASES,
            (
                "invocation",
                "evidence.init",
                "device.acquire",
                "device.preflight",
                "device.boot",
                "app.build",
                "app.install",
                "shim.build",
                "shim.start",
                "shim.prewarm",
                "scenario.validate",
                "scenario.execute",
                "trace.finalize",
                "report.generate",
                "evidence.finalize",
                "cleanup",
                "complete",
            ),
        )
        self.assertEqual(
            run_evidence.COMPARABILITY_FIELDS,
            (
                "candidateRevision",
                "fixtureId",
                "fixtureVersion",
                "scenarioDigest",
                "appBuildDigest",
                "platform",
                "deviceClass",
                "runtimeVersion",
                "host.os",
                "host.arch",
                "host.class",
                "runnerVersion",
                "protocolVersion",
                "timingMode",
                "toolchain",
            ),
        )

    def test_complete_tuple_is_eligible_and_stable_across_insertion_order(self):
        context = valid_context()
        reversed_context = dict(reversed(list(context.items())))
        reversed_context["host"] = dict(reversed(list(context["host"].items())))
        reversed_context["toolchain"] = {"zig": "0.16.0", "xcode": "16.4"}

        result = run_evidence.comparability(context)
        reordered = run_evidence.comparability(reversed_context)

        self.assertTrue(result["certificationEligible"])
        self.assertEqual(result["ineligibilityReasons"], [])
        self.assertRegex(result["comparabilityKey"], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual(result, reordered)
        self.assertEqual(
            result["comparabilityTuple"]["host"],
            {"os": "macos", "arch": "arm64", "class": "github-macos-15-arm64"},
        )
        self.assertEqual(
            result["comparabilityTuple"]["toolchain"],
            {"xcode": "16.4", "zig": "0.16.0"},
        )

    def test_each_tuple_value_and_each_tool_version_changes_key(self):
        original = valid_context()
        baseline = run_evidence.comparability(original)["comparabilityKey"]
        mutations = {
            "candidateRevision": "d" * 40,
            "fixtureId": "fixture-2",
            "fixtureVersion": "2",
            "scenarioDigest": "sha256:" + "d" * 64,
            "appBuildDigest": "sha256:" + "e" * 64,
            "platform": "android",
            "deviceClass": "pixel-9",
            "runtimeVersion": "36",
            "runnerVersion": "0.2.18",
            "protocolVersion": "2026-07-11",
            "timingMode": "warm-session",
        }
        for field, value in mutations.items():
            changed = copy.deepcopy(original)
            changed[field] = value
            with self.subTest(field=field):
                self.assertNotEqual(
                    run_evidence.comparability(changed)["comparabilityKey"], baseline
                )
        for field in ("os", "arch", "class"):
            changed = copy.deepcopy(original)
            changed["host"][field] += "-different"
            with self.subTest(field="host." + field):
                self.assertNotEqual(
                    run_evidence.comparability(changed)["comparabilityKey"], baseline
                )
        changed = copy.deepcopy(original)
        changed["toolchain"]["zig"] = "0.17.0"
        self.assertNotEqual(run_evidence.comparability(changed)["comparabilityKey"], baseline)

    def test_missing_and_null_values_return_sorted_path_reasons(self):
        context = valid_context(
            candidateRevision=None,
            runtimeVersion=None,
            host={"os": "macos", "arch": None, "class": None, "ci": True},
            toolchain={"zig": None, "xcode": "16.4"},
        )
        del context["fixtureVersion"]
        result = run_evidence.comparability(context)
        self.assertIsNone(result["comparabilityKey"])
        self.assertFalse(result["certificationEligible"])
        self.assertEqual(
            result["ineligibilityReasons"],
            sorted(
                [
                    "$.candidateRevision",
                    "$.fixtureVersion",
                    "$.host.arch",
                    "$.host.class",
                    "$.runtimeVersion",
                    "$.toolchain.zig",
                ]
            ),
        )

    def test_empty_or_non_object_toolchain_is_ineligible(self):
        for toolchain in ({}, None, []):
            with self.subTest(toolchain=toolchain):
                result = run_evidence.comparability(valid_context(toolchain=toolchain))
                self.assertFalse(result["certificationEligible"])
                self.assertIn("$.toolchain", result["ineligibilityReasons"])

    def test_recompute_ignores_producer_comparability_claims(self):
        summary = valid_summary()
        expected = summary["comparabilityKey"]
        summary["comparabilityKey"] = "sha256:" + "f" * 64
        summary["certificationEligible"] = False
        summary["ineligibilityReasons"] = ["$.candidateRevision"]
        result = run_evidence.recompute_comparability(summary)
        self.assertEqual(result["comparabilityKey"], expected)
        self.assertTrue(result["certificationEligible"])
        self.assertEqual(result["ineligibilityReasons"], [])


class ClassificationTests(unittest.TestCase):
    def test_registry_contains_every_initial_code(self):
        expected = {
            "runner_failure": {
                "runner.unclassified",
                "runner.child_timeout",
                "runner.cleanup_failed",
                "runner.driver_protocol",
                "runner.ios_shim.build_failed",
                "runner.ios_shim.readiness_timeout",
                "runner.trace_failed",
                "runner.report_failed",
                "runner.evidence_invalid",
            },
            "configuration_failure": {
                "config.invalid",
                "config.app_artifact_missing",
                "config.device_selection",
                "config.signing",
                "config.unsupported_capability",
                "config.required_tool_missing",
            },
            "infrastructure_failure": {
                "infra.hosted_runner",
                "infra.device_unavailable",
                "infra.emulator_provision",
                "infra.simulator_provision",
                "infra.disk",
                "infra.network",
            },
            "app_failure": {
                "app.assertion_failed",
                "app.crashed",
                "app.launch_failed",
            },
            "cancelled": {"run.cancelled"},
        }
        grouped = {}
        for code, classification in run_evidence.ERROR_CLASSIFICATION.items():
            grouped.setdefault(classification, set()).add(code)
        self.assertEqual(grouped, expected)

    def test_every_class_and_precedence(self):
        cases = [
            (["runner.child_timeout"], ("runner_failure", "runner.child_timeout")),
            (["config.invalid"], ("configuration_failure", "config.invalid")),
            (["infra.disk"], ("infrastructure_failure", "infra.disk")),
            (["app.crashed"], ("app_failure", "app.crashed")),
            (["run.cancelled"], ("cancelled", "run.cancelled")),
            (
                ["app.assertion_failed", "runner.cleanup_failed"],
                ("runner_failure", "runner.cleanup_failed"),
            ),
            (
                ["run.cancelled", "infra.network", "config.signing"],
                ("configuration_failure", "config.signing"),
            ),
        ]
        for error_codes, expected in cases:
            with self.subTest(error_codes=error_codes):
                self.assertEqual(run_evidence.classify(error_codes), expected)

    def test_unknown_or_empty_is_unclassified_runner_failure(self):
        for codes in ([], ["unknown.code"], ["run.cancelled", "unknown.code"]):
            with self.subTest(codes=codes):
                self.assertEqual(
                    run_evidence.classify(codes),
                    ("runner_failure", "runner.unclassified"),
                )


class ValidationTests(unittest.TestCase):
    def assertPathError(self, errors, path):
        self.assertTrue(any(error.startswith(path + ":") for error in errors), errors)

    def test_representative_terminal_summaries_are_valid(self):
        for status in ("passed", "failed", "cancelled"):
            with self.subTest(status=status):
                self.assertEqual(run_evidence.validate_summary(valid_summary(status)), [])

    def test_summary_allows_unknown_ci_metadata(self):
        summary = valid_summary()
        summary["ci"] = {"job": "ios", "matrix": {"runner": "macos-15"}}
        self.assertEqual(run_evidence.validate_summary(summary), [])

    def test_summary_validates_required_types_formats_and_enums(self):
        mutations = {
            "schemaVersion": 2,
            "runId": "",
            "candidateRevision": "A" * 40,
            "scenarioDigest": "sha256:" + "b" * 63,
            "startedAt": "not-a-date",
            "finishedAt": "2026-13-40T10:00:00Z",
            "durationMs": -1,
            "attempt": 0,
            "platform": "windows",
            "timingMode": "hot",
            "phase": "unknown",
        }
        for field, value in mutations.items():
            summary = valid_summary()
            summary[field] = value
            with self.subTest(field=field):
                self.assertPathError(run_evidence.validate_summary(summary), "$." + field)

        boolean_version = valid_summary()
        boolean_version["schemaVersion"] = True
        self.assertPathError(
            run_evidence.validate_summary(boolean_version), "$.schemaVersion"
        )

    def test_datetime_validation_matches_committed_ajv_formats_semantics(self):
        accepted = (
            "2026-07-11t10:00:00z",
            "2026-07-11 10:00:00+01",
            "2026-07-11T10:00:00+0130",
            "2026-07-11T10:00:00.123+01:30",
            "2016-12-31T23:59:60Z",
            "2017-01-01T00:59:60+01:00",
        )
        rejected = (
            "2026-07-11T24:00:00Z",
            "2026-02-29T10:00:00Z",
            "2024-02-30T10:00:00Z",
            "2026-07-11T10:00:00",
            "2026-07-11T10:00:00+24:00",
            "2026-07-11T10:00:00+01:60",
            "2026-07-11T10:00:60Z",
            "2026-07-11T10:00:61Z",
            "2026-07-11  10:00:00Z",
        )
        for timestamp in accepted:
            with self.subTest(timestamp=timestamp, expected=True):
                summary = valid_summary()
                summary["startedAt"] = timestamp
                summary["finishedAt"] = timestamp
                self.assertEqual(run_evidence.validate_summary(summary), [])
                self.assertEqual(
                    run_evidence.validate_event(valid_event(timestamp=timestamp)), []
                )
        for timestamp in rejected:
            with self.subTest(timestamp=timestamp, expected=False):
                summary = valid_summary()
                summary["startedAt"] = timestamp
                self.assertPathError(
                    run_evidence.validate_summary(summary), "$.startedAt"
                )
                self.assertPathError(
                    run_evidence.validate_event(valid_event(timestamp=timestamp)),
                    "$.timestamp",
                )

    def test_json_integral_floats_match_schema_integer_semantics(self):
        summary = valid_summary()
        summary.update(
            schemaVersion=1.0,
            durationMs=1.0,
            attempt=1.0,
            commandStatus=0.0,
        )
        self.assertEqual(run_evidence.validate_summary(summary), [])
        event = valid_event(schemaVersion=1.0, seq=1.0, commandStatus=0.0)
        self.assertEqual(run_evidence.validate_event(event), [])

        invalid_numbers = (1.5, float("inf"), float("-inf"), float("nan"), True)
        for value in invalid_numbers:
            with self.subTest(value=value):
                summary = valid_summary()
                summary["durationMs"] = value
                self.assertPathError(
                    run_evidence.validate_summary(summary), "$.durationMs"
                )
                self.assertPathError(
                    run_evidence.validate_event(valid_event(seq=value)), "$.seq"
                )

    def test_first_attempt_is_exact(self):
        first = valid_summary()
        first["firstAttempt"] = False
        self.assertPathError(run_evidence.validate_summary(first), "$.firstAttempt")
        retry = valid_summary()
        retry["attempt"] = 2
        retry["firstAttempt"] = True
        self.assertPathError(run_evidence.validate_summary(retry), "$.firstAttempt")

    def test_terminal_conditionals_are_exact(self):
        passed = valid_summary()
        passed["errorCode"] = "runner.unclassified"
        passed["summary"] = "Unexpected"
        passed["hint"] = "Inspect logs"
        errors = run_evidence.validate_summary(passed)
        for field in ("errorCode", "summary", "hint"):
            self.assertPathError(errors, "$." + field)

        wrong_phase = valid_summary()
        wrong_phase["phase"] = "cleanup"
        self.assertPathError(run_evidence.validate_summary(wrong_phase), "$.phase")

        failed = valid_summary("failed")
        failed["classification"] = "passed"
        del failed["hint"]
        errors = run_evidence.validate_summary(failed)
        self.assertPathError(errors, "$.classification")
        self.assertPathError(errors, "$.hint")

        cancelled = valid_summary("cancelled")
        cancelled["errorCode"] = "runner.unclassified"
        self.assertPathError(run_evidence.validate_summary(cancelled), "$.errorCode")

    def test_failed_error_code_must_be_known_and_match_classification(self):
        unknown = valid_summary("failed")
        unknown["errorCode"] = "unknown.failure"
        self.assertPathError(run_evidence.validate_summary(unknown), "$.errorCode")

        mismatch = valid_summary("failed")
        mismatch["errorCode"] = "app.assertion_failed"
        mismatch["classification"] = "infrastructure_failure"
        errors = run_evidence.validate_summary(mismatch)
        self.assertPathError(errors, "$.classification")
        self.assertPathError(errors, "$.errorCode")

    def test_nested_objects_and_normalized_paths_are_validated(self):
        summary = valid_summary()
        summary["host"] = {"os": "macos", "arch": "arm64", "ci": True, "extra": 1}
        summary["device"] = {"requested": "booted", "resolved": "sim", "extra": 1}
        summary["toolchain"] = {}
        summary["artifacts"]["trace"] = "../trace.json"
        errors = run_evidence.validate_summary(summary)
        for path in (
            "$.host.class",
            "$.host.extra",
            "$.device.extra",
            "$.toolchain",
            "$.artifacts.trace",
        ):
            self.assertPathError(errors, path)

    def test_comparability_claim_must_equal_recomputation(self):
        summary = valid_summary()
        summary["comparabilityKey"] = "sha256:" + "f" * 64
        summary["certificationEligible"] = False
        summary["ineligibilityReasons"] = ["$.runtimeVersion"]
        errors = run_evidence.validate_summary(summary)
        for path in (
            "$.comparabilityKey",
            "$.certificationEligible",
            "$.ineligibilityReasons",
        ):
            self.assertPathError(errors, path)

    def test_validation_returns_sorted_errors_and_never_raises_for_bad_shapes(self):
        for value in (None, [], "x", {"schemaVersion": 1, "host": []}):
            with self.subTest(value=value):
                errors = run_evidence.validate_summary(value)
                self.assertTrue(errors)
                self.assertEqual(errors, sorted(set(errors)))

    def test_event_validates_schema_and_rejects_unknown_fields(self):
        self.assertEqual(run_evidence.validate_event(valid_event()), [])
        self.assertEqual(
            run_evidence.validate_event(
                valid_event(
                    seq=2,
                    phase="scenario.execute",
                    status="failed",
                    errorCode="app.assertion_failed",
                    summary="Expected title",
                    command="commands/2-run.json",
                    commandStatus=1,
                    artifact="commands/2-run.stderr.log",
                )
            ),
            [],
        )
        event = valid_event(
            schemaVersion=2,
            seq=0,
            timestamp="nope",
            phase="bad",
            status="done",
            artifact="../secret",
            metadata={"unexpected": True},
        )
        errors = run_evidence.validate_event(event)
        for path in (
            "$.schemaVersion",
            "$.seq",
            "$.timestamp",
            "$.phase",
            "$.status",
            "$.artifact",
            "$.metadata",
        ):
            self.assertPathError(errors, path)
        self.assertPathError(
            run_evidence.validate_event(valid_event(schemaVersion=True)),
            "$.schemaVersion",
        )
