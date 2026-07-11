import copy
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPOSITORY_ROOT / "scripts" / "run_evidence.py"
SPEC = importlib.util.spec_from_file_location("run_evidence", MODULE_PATH)
run_evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(run_evidence)


REVISION = "a" * 40
SCENARIO_DIGEST = "sha256:" + "b" * 64
APP_DIGEST = "sha256:" + "c" * 64


def valid_context(**patch):
    context = {
        "runId": "run-1",
        "executionId": "execution-1",
        "fixtureId": "fixture-ios",
        "fixtureVersion": "1",
        "candidateRevision": REVISION,
        "scenarioDigest": SCENARIO_DIGEST,
        "appBuildDigest": APP_DIGEST,
        "platform": "ios",
        "deviceClass": "ios-simulator",
        "runtimeVersion": "18.5",
        "timingMode": "cold-command",
        "runnerVersion": "0.2.17",
        "protocolVersion": "2026-04-28",
        "attempt": 1,
        "host": {
            "os": "macos",
            "arch": "arm64",
            "class": "github-macos-15-arm64",
            "ci": True,
        },
        "device": {"requested": "booted", "resolved": "simulator-udid"},
        "toolchain": {"xcode": "16.4", "zig": "0.16.0"},
        "artifacts": {"trace": None, "report": "reports/run.html"},
    }
    for key, value in patch.items():
        context[key] = value
    return context


def valid_summary(status="passed"):
    context = valid_context()
    computed = run_evidence.comparability(context)
    summary = {
        "schemaVersion": 1,
        "runId": context["runId"],
        "executionId": context["executionId"],
        "fixtureId": context["fixtureId"],
        "fixtureVersion": context["fixtureVersion"],
        "candidateRevision": context["candidateRevision"],
        "scenarioDigest": context["scenarioDigest"],
        "appBuildDigest": context["appBuildDigest"],
        "comparabilityKey": computed["comparabilityKey"],
        "certificationEligible": computed["certificationEligible"],
        "ineligibilityReasons": computed["ineligibilityReasons"],
        "status": status,
        "classification": "passed",
        "phase": "complete",
        "startedAt": "2026-07-11T10:00:00Z",
        "finishedAt": "2026-07-11T10:00:05.123Z",
        "durationMs": 5123,
        "attempt": context["attempt"],
        "firstAttempt": True,
        "platform": context["platform"],
        "deviceClass": context["deviceClass"],
        "runtimeVersion": context["runtimeVersion"],
        "timingMode": context["timingMode"],
        "runnerVersion": context["runnerVersion"],
        "protocolVersion": context["protocolVersion"],
        "commandStatus": 0,
        "host": context["host"],
        "device": context["device"],
        "toolchain": context["toolchain"],
        "artifacts": {
            "bootstrapEvents": "bootstrap-events.jsonl",
            "commands": "commands",
            "trace": None,
            "report": "reports/run.html",
        },
        "ciJobId": "device-smoke-ios",
    }
    if status == "failed":
        summary.update(
            classification="runner_failure",
            phase="shim.prewarm",
            errorCode="runner.ios_shim.readiness_timeout",
            summary="Shim readiness timed out",
            hint="Inspect command logs",
            commandStatus=None,
        )
    elif status == "cancelled":
        summary.update(
            classification="cancelled",
            phase="cleanup",
            errorCode="run.cancelled",
            summary="Run cancelled",
            hint="Retry when ready",
            commandStatus=None,
        )
    return summary


def valid_event(**patch):
    event = {
        "schemaVersion": 1,
        "seq": 1,
        "timestamp": "2026-07-11T10:00:00Z",
        "phase": "invocation",
        "status": "started",
    }
    event.update(patch)
    return event


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


class StorageTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.publication_root = Path(self.temporary.name) / "publication"
        self.publication_root.mkdir()
        self.index_path = self.publication_root / "attempt-index.json"

    def tearDown(self):
        self.temporary.cleanup()

    def attempt_root(self, run_id):
        return self.publication_root / "attempts" / run_id

    def create_attempt_root(self, run_id):
        root = self.attempt_root(run_id)
        root.mkdir(parents=True)
        return root

    def read_json(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def read_events(self, root):
        return [
            json.loads(line)
            for line in (root / "bootstrap-events.jsonl")
            .read_text(encoding="utf-8")
            .splitlines()
            if line.strip()
        ]


class AttemptIndexTests(StorageTestCase):
    def test_registers_two_monotonic_attempts_with_normalized_summary_refs(self):
        first_context = valid_context()
        first_root = self.create_attempt_root("run-1")
        first_index = run_evidence.register_attempt(
            self.index_path, first_root, first_context
        )
        second_context = valid_context(runId="run-2", attempt=2)
        second_root = self.create_attempt_root("run-2")
        second_index = run_evidence.register_attempt(
            self.index_path, second_root, second_context
        )

        self.assertEqual(first_index["schemaVersion"], "1.0")
        self.assertEqual(len(second_index["executions"]), 1)
        execution = second_index["executions"][0]
        self.assertEqual(execution["executionId"], "execution-1")
        self.assertEqual(
            execution["comparabilityTuple"],
            run_evidence.comparability(first_context)["comparabilityTuple"],
        )
        self.assertEqual(
            execution["attempts"],
            [
                {
                    "runId": "run-1",
                    "attempt": 1,
                    "summary": "attempts/run-1/run-summary.json",
                },
                {
                    "runId": "run-2",
                    "attempt": 2,
                    "summary": "attempts/run-2/run-summary.json",
                },
            ],
        )
        self.assertEqual(self.read_json(self.index_path), second_index)

    def test_rejects_duplicate_run_ids_attempt_gaps_and_changed_retry_identity(self):
        first = valid_context()
        first_root = self.create_attempt_root("run-1")
        run_evidence.register_attempt(self.index_path, first_root, first)
        cases = [
            (
                first_root,
                valid_context(runId="run-1", attempt=2),
                "already registered",
            ),
            (
                self.create_attempt_root("run-3"),
                valid_context(runId="run-3", attempt=3),
                "next contiguous",
            ),
            (
                self.create_attempt_root("run-2"),
                valid_context(runId="run-2", attempt=2, fixtureVersion="2"),
                "comparability tuple differs",
            ),
        ]
        for root, context, message in cases:
            with self.subTest(context=context), self.assertRaisesRegex(
                ValueError, message
            ):
                run_evidence.register_attempt(self.index_path, root, context)

    def test_new_execution_must_start_at_attempt_one(self):
        root = self.create_attempt_root("other-run")
        context = valid_context(
            runId="other-run", executionId="other-execution", attempt=2
        )
        with self.assertRaises(ValueError):
            run_evidence.register_attempt(self.index_path, root, context)

    def test_rejects_attempt_roots_outside_or_not_matching_run_id(self):
        outside = Path(self.temporary.name) / "outside" / "run-1"
        outside.mkdir(parents=True)
        wrong = self.create_attempt_root("wrong-name")
        for root in (outside, wrong):
            with self.subTest(root=root), self.assertRaises(ValueError):
                run_evidence.register_attempt(self.index_path, root, valid_context())

    def test_rejects_corrupt_existing_index_invariants(self):
        root = self.create_attempt_root("run-2")
        context = valid_context(runId="run-2", attempt=2)
        corrupt_indexes = [
            {
                "schemaVersion": "1.0",
                "executions": [
                    {
                        "executionId": "execution-1",
                        "comparabilityTuple": run_evidence.comparability(
                            valid_context()
                        )["comparabilityTuple"],
                        "attempts": [
                            {
                                "runId": "run-1",
                                "attempt": 2,
                                "summary": "attempts/run-1/run-summary.json",
                            }
                        ],
                    }
                ],
            },
            {
                "schemaVersion": "1.0",
                "executions": [
                    {
                        "executionId": "execution-1",
                        "comparabilityTuple": run_evidence.comparability(
                            valid_context()
                        )["comparabilityTuple"],
                        "attempts": [
                            {
                                "runId": "run-1",
                                "attempt": 1,
                                "summary": "../run-summary.json",
                            },
                            {
                                "runId": "run-x",
                                "attempt": 1,
                                "summary": "attempts/run-x/run-summary.json",
                            },
                        ],
                    }
                ],
            },
        ]
        for value in corrupt_indexes:
            with self.subTest(value=value):
                self.index_path.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaises(ValueError):
                    run_evidence.register_attempt(self.index_path, root, context)


class LifecycleTests(StorageTestCase):
    def initialize(self, context=None):
        context = valid_context() if context is None else context
        root = self.attempt_root(context["runId"])
        run_evidence._initialize_attempt(self.index_path, root, context)
        return root

    def test_init_creates_context_commands_index_and_ordered_init_events(self):
        root = self.initialize()
        self.assertTrue((root / "commands").is_dir())
        stored = self.read_json(root / "run-context.json")
        self.assertEqual(stored["runId"], "run-1")
        self.assertRegex(stored["startedAt"], r"Z$")
        events = self.read_events(root)
        self.assertEqual([event["seq"] for event in events], [1, 2])
        self.assertEqual(
            [(event["phase"], event["status"]) for event in events],
            [("evidence.init", "started"), ("evidence.init", "passed")],
        )
        self.assertTrue(all(run_evidence.validate_event(event) == [] for event in events))
        index = self.read_json(self.index_path)
        self.assertEqual(index["executions"][0]["attempts"][0]["runId"], "run-1")

    def test_init_never_overwrites_existing_root_or_summary(self):
        existing = self.attempt_root("run-1")
        existing.mkdir(parents=True)
        marker = existing / "marker"
        marker.write_text("keep", encoding="utf-8")
        with self.assertRaises(FileExistsError):
            run_evidence._initialize_attempt(self.index_path, existing, valid_context())
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

        second = valid_context(runId="run-2", executionId="execution-2")
        second_root = self.attempt_root("run-2")
        second_root.mkdir(parents=True)
        (second_root / "run-summary.json").write_text("keep", encoding="utf-8")
        with self.assertRaises(FileExistsError):
            run_evidence._initialize_attempt(self.index_path, second_root, second)
        self.assertEqual(
            (second_root / "run-summary.json").read_text(encoding="utf-8"), "keep"
        )

    def test_failed_registration_removes_only_newly_created_attempt_tree(self):
        first = self.initialize()
        self.assertTrue(first.exists())
        invalid_retry = valid_context(runId="run-2", attempt=3)
        second = self.attempt_root("run-2")
        with self.assertRaises(ValueError):
            run_evidence._initialize_attempt(self.index_path, second, invalid_retry)
        self.assertFalse(second.exists())
        self.assertTrue(first.exists())

    def test_init_event_failure_rolls_back_registered_index_entry(self):
        root = self.attempt_root("run-1")
        with mock.patch.object(
            run_evidence, "_append_event", side_effect=OSError("injected event failure")
        ):
            with self.assertRaises(OSError):
                run_evidence._initialize_attempt(self.index_path, root, valid_context())
        self.assertFalse(root.exists())
        self.assertFalse(self.index_path.exists())

    def test_context_can_resolve_null_identity_once_and_updates_index(self):
        context = valid_context(runtimeVersion=None)
        root = self.initialize(context)
        updated = run_evidence.update_context(
            root,
            {
                "runtimeVersion": "18.5",
                "device": {"resolved": "resolved-simulator"},
                "artifacts": {"trace": "traces/run.json"},
            },
        )
        self.assertEqual(updated["runtimeVersion"], "18.5")
        self.assertEqual(updated["device"]["requested"], "booted")
        self.assertEqual(updated["device"]["resolved"], "resolved-simulator")
        self.assertEqual(updated["artifacts"]["trace"], "traces/run.json")
        index = self.read_json(self.index_path)
        self.assertEqual(
            index["executions"][0]["comparabilityTuple"]["runtimeVersion"], "18.5"
        )

        with self.assertRaises(ValueError):
            run_evidence.update_context(root, {"runtimeVersion": "18.6"})
        with self.assertRaises(ValueError):
            run_evidence.update_context(root, {"notAllowed": "x"})

    def test_context_resolution_atomically_updates_unfinalized_siblings(self):
        first_context = valid_context(runtimeVersion=None)
        first = self.initialize(first_context)
        second_context = valid_context(runId="run-2", attempt=2, runtimeVersion=None)
        second = self.attempt_root("run-2")
        run_evidence._initialize_attempt(self.index_path, second, second_context)

        run_evidence.update_context(second, {"runtimeVersion": "18.5"})

        self.assertEqual(
            self.read_json(first / "run-context.json")["runtimeVersion"], "18.5"
        )
        self.assertEqual(
            self.read_json(second / "run-context.json")["runtimeVersion"], "18.5"
        )
        self.assertEqual(
            self.read_json(self.index_path)["executions"][0]["comparabilityTuple"][
                "runtimeVersion"
            ],
            "18.5",
        )

    def test_finalized_identity_is_immutable(self):
        root = self.initialize()
        run_evidence._finalize_attempt(root, "passed")
        with self.assertRaises(ValueError):
            run_evidence.update_context(root, {"runtimeVersion": "18.6"})

    def test_append_event_is_monotonic_and_valid(self):
        root = self.initialize()
        event = run_evidence._append_event(
            root,
            "device.acquire",
            "passed",
            summary="Simulator acquired",
            artifact="commands/device.json",
        )
        self.assertEqual(event["seq"], 3)
        self.assertEqual(run_evidence.validate_event(event), [])
        events = self.read_events(root)
        self.assertEqual([item["seq"] for item in events], [1, 2, 3])

    def test_finalize_passed_once_and_terminal_event_matches(self):
        root = self.initialize()
        summary = run_evidence._finalize_attempt(root, "passed", command_status=0)
        self.assertEqual(run_evidence.validate_summary(summary), [])
        self.assertEqual(self.read_json(root / "run-summary.json"), summary)
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(summary["classification"], "passed")
        self.assertGreaterEqual(summary["durationMs"], 0)
        terminal = self.read_events(root)[-1]
        self.assertEqual(
            (terminal["phase"], terminal["status"]), ("complete", "passed")
        )
        with self.assertRaises(FileExistsError):
            run_evidence._finalize_attempt(root, "passed")

        before = (root / "bootstrap-events.jsonl").read_bytes()
        with self.assertRaises(ValueError):
            run_evidence._append_event(root, "cleanup", "passed")
        self.assertEqual((root / "bootstrap-events.jsonl").read_bytes(), before)

    def test_finalize_rejects_classification_that_disagrees_with_error_owner(self):
        root = self.initialize()
        with self.assertRaises(ValueError):
            run_evidence._finalize_attempt(
                root,
                "failed",
                classification="runner_failure",
                phase="scenario.execute",
                error_code="app.assertion_failed",
                summary_text="Assertion failed",
                hint="Inspect report",
                command_status=1,
            )
        self.assertFalse((root / "run-summary.json").exists())

    def test_unclassified_failed_finalize_allows_no_command_owner(self):
        root = self.initialize()
        summary = run_evidence._finalize_attempt(
            root,
            "failed",
            phase="scenario.execute",
            error_code="runner.unclassified",
            summary_text="Unexpected runner failure",
            hint="Inspect bootstrap events",
            command_status=None,
        )
        self.assertEqual(summary["classification"], "runner_failure")
        self.assertIsNone(summary["commandStatus"])
        self.assertEqual(run_evidence.validate_summary(summary), [])
        terminal = self.read_events(root)[-1]
        self.assertEqual(terminal["status"], "failed")
        self.assertEqual(terminal["errorCode"], "runner.unclassified")

    def test_cancelled_finalize_uses_exact_contract(self):
        root = self.initialize()
        summary = run_evidence._finalize_attempt(
            root,
            "cancelled",
            phase="cleanup",
            summary_text="Cancelled by request",
            hint="Retry when ready",
        )
        self.assertEqual(summary["classification"], "cancelled")
        self.assertEqual(summary["errorCode"], "run.cancelled")
        self.assertEqual(run_evidence.validate_summary(summary), [])

    def test_invalid_candidate_is_preserved_and_schema_valid_fallback_is_terminal(self):
        root = self.initialize()
        context_path = root / "run-context.json"
        damaged = self.read_json(context_path)
        damaged["platform"] = "not-a-platform"
        damaged["host"] = "not-an-object"
        context_path.write_text(json.dumps(damaged), encoding="utf-8")

        fallback = run_evidence._finalize_attempt(root, "passed")

        self.assertEqual(run_evidence.validate_summary(fallback), [])
        self.assertEqual(fallback["status"], "failed")
        self.assertEqual(fallback["classification"], "runner_failure")
        self.assertEqual(fallback["phase"], "evidence.finalize")
        self.assertEqual(fallback["errorCode"], "runner.evidence_invalid")
        self.assertTrue((root / "run-summary.invalid.json").is_file())
        diagnostics = self.read_json(root / "run-summary.invalid.errors.json")
        self.assertTrue(diagnostics["errors"])
        terminal = self.read_events(root)[-1]
        self.assertEqual(
            (terminal["phase"], terminal["status"], terminal["errorCode"]),
            ("evidence.finalize", "failed", "runner.evidence_invalid"),
        )


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


class CommandTestCase(StorageTestCase):
    def setUp(self):
        super().setUp()
        self.root = self.attempt_root("run-1")
        run_evidence._initialize_attempt(self.index_path, self.root, valid_context())

    def cli(self, *arguments, env=None, text=False, timeout=30):
        environment = os.environ.copy()
        if env:
            environment.update(env)
        return subprocess.run(
            [sys.executable, str(MODULE_PATH), *map(str, arguments)],
            cwd=REPOSITORY_ROOT,
            env=environment,
            capture_output=True,
            text=text,
            timeout=timeout,
            check=False,
        )

    def command_metadata(self):
        metadata_paths = sorted((self.root / "commands").glob("*.json"))
        return [self.read_json(path) for path in metadata_paths]


class CommandCaptureTests(CommandTestCase):
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
