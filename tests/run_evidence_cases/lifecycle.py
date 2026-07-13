"""Attempt registration and lifecycle cases."""

from .support import *  # noqa: F401,F403


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
            run_evidence.contracts._comparability_tuple(first_context),
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

    def test_retry_registration_rejects_every_comparability_tuple_category(self):
        first_root = self.create_attempt_root("run-1")
        run_evidence.register_attempt(self.index_path, first_root, valid_context())
        cases = (
            ("candidateRevision", "candidateRevision", "d" * 40),
            ("fixtureId", "fixtureId", "fixture-2"),
            ("fixtureVersion", "fixtureVersion", "2"),
            ("scenarioDigest", "scenarioDigest", "sha256:" + "d" * 64),
            ("appBuildDigest", "appBuildDigest", "sha256:" + "e" * 64),
            ("platform", "platform", "android"),
            ("deviceClass", "deviceClass", "pixel-9"),
            ("runtimeVersion", "runtimeVersion", "36"),
            ("host.os", "host.os", "linux"),
            ("host.arch", "host.arch", "x86_64"),
            ("host.class", "host.class", "self-hosted-linux"),
            ("runnerVersion", "runnerVersion", "0.2.18"),
            ("protocolVersion", "protocolVersion", "2026-07-12"),
            ("timingMode", "timingMode", "warm-session"),
            ("toolchain", "toolchain.zig", "0.17.0"),
            ("toolchain.membership", "toolchain.swift", "6.0"),
        )
        self.assertEqual(
            {label for label, _path, _value in cases},
            set(run_evidence.COMPARABILITY_FIELDS) | {"toolchain.membership"},
        )
        for index, (label, path, value) in enumerate(cases, 1):
            context = valid_context(runId=f"retry-{index}", attempt=2)
            target = context
            parts = path.split(".")
            for part in parts[:-1]:
                target = target[part]
            target[parts[-1]] = value
            root = self.create_attempt_root(context["runId"])
            index_before = self.index_path.read_bytes()
            with self.subTest(category=label), self.assertRaisesRegex(
                ValueError, "comparability tuple differs"
            ):
                run_evidence.register_attempt(self.index_path, root, context)
            self.assertEqual(self.index_path.read_bytes(), index_before)

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
                        "comparabilityTuple": (
                            run_evidence.contracts._comparability_tuple(
                                valid_context()
                            )
                        ),
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
                        "comparabilityTuple": (
                            run_evidence.contracts._comparability_tuple(
                                valid_context()
                            )
                        ),
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

    def test_init_preparation_failure_leaves_no_attempt_or_index(self):
        root = self.attempt_root("run-1")
        with self.assertRaises(ValueError):
            run_evidence._initialize_attempt(
                self.index_path, root, valid_context(attempt=0)
            )
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

    def test_public_app_digest_resolution_updates_index_and_final_key(self):
        root = self.initialize(valid_context(appBuildDigest=None))
        initial_claims = run_evidence.comparability(
            self.read_json(root / "run-context.json")
        )
        self.assertFalse(initial_claims["certificationEligible"])
        self.assertIn("$.appBuildDigest", initial_claims["ineligibilityReasons"])

        updated = run_evidence.update_context(
            root, {"appBuildDigest": APP_DIGEST}
        )
        expected_claims = run_evidence.comparability(updated)
        self.assertTrue(expected_claims["certificationEligible"])
        self.assertEqual(expected_claims["ineligibilityReasons"], [])
        self.assertEqual(
            self.read_json(self.index_path)["executions"][0][
                "comparabilityTuple"
            ]["appBuildDigest"],
            APP_DIGEST,
        )

        summary = run_evidence._finalize_attempt(root, "passed")
        self.assertEqual(summary["comparabilityKey"], expected_claims["comparabilityKey"])
        self.assertTrue(summary["certificationEligible"])
        self.assertEqual(summary["ineligibilityReasons"], [])

    def test_identical_context_patch_returns_current_stored_context(self):
        root = self.initialize(valid_context(runtimeVersion=None))
        applied = run_evidence.update_context(root, {"runtimeVersion": "18.5"})
        stored_before_retry = (root / "run-context.json").read_bytes()

        retried = run_evidence.update_context(root, {"runtimeVersion": "18.5"})

        self.assertEqual(retried, applied)
        self.assertEqual(retried, self.read_json(root / "run-context.json"))
        self.assertEqual(
            (root / "run-context.json").read_bytes(), stored_before_retry
        )

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
        finished_at = "2026-07-11T10:00:01.000Z"
        independently_sampled_event_time = "2026-07-11T10:00:02.000Z"
        with mock.patch.object(
            run_evidence.summaries, "_utc_now", return_value=finished_at
        ), mock.patch.object(
            run_evidence.lifecycle,
            "_utc_now",
            return_value=independently_sampled_event_time,
        ):
            summary = run_evidence._finalize_attempt(
                root, "passed", command_status=0
            )
        self.assertEqual(run_evidence.validate_summary(summary), [])
        self.assertEqual(self.read_json(root / "run-summary.json"), summary)
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(summary["classification"], "passed")
        self.assertGreaterEqual(summary["durationMs"], 0)
        terminal = self.read_events(root)[-1]
        self.assertEqual(
            (terminal["phase"], terminal["status"]), ("complete", "passed")
        )
        self.assertEqual(terminal["timestamp"], summary["finishedAt"])
        self.assertEqual(
            run_evidence._finalize_attempt(root, "passed", command_status=0),
            summary,
        )
        with self.assertRaisesRegex(ValueError, "request fingerprint"):
            run_evidence._finalize_attempt(root, "passed")

        before = (root / "bootstrap-events.jsonl").read_bytes()
        with self.assertRaises(ValueError):
            run_evidence._append_event(root, "cleanup", "passed")
        self.assertEqual((root / "bootstrap-events.jsonl").read_bytes(), before)

    def test_finalize_summary_size_cap_is_exact_and_precedes_writes(self):
        finished_at = "2026-07-11T10:00:01.000Z"
        finalize_arguments = {
            "classification": "app_failure",
            "phase": "scenario.execute",
            "error_code": "app.assertion_failed",
            "summary_text": "Assertion failed",
            "hint": "Inspect the report",
            "command_status": 1,
        }
        exact_context = valid_context(
            runId="summary-bound-a",
            executionId="summary-bound-a-execution",
        )
        exact_root = self.attempt_root(exact_context["runId"])
        run_evidence._initialize_attempt(
            self.index_path, exact_root, exact_context
        )
        over_context = valid_context(
            runId="summary-bound-b",
            executionId="summary-bound-b-execution",
        )
        over_root = self.attempt_root(over_context["runId"])
        run_evidence._initialize_attempt(
            self.index_path, over_root, over_context
        )
        expected = run_evidence._build_summary(
            self.read_json(exact_root / "run-context.json"),
            "failed",
            finished_at=finished_at,
            **finalize_arguments,
        )
        exact_size = len(run_evidence._json_bytes(expected))

        with mock.patch.object(
            run_evidence.summaries,
            "MAX_STRUCTURED_JSON_BYTES",
            exact_size,
        ), mock.patch.object(
            run_evidence.journal,
            "MAX_STRUCTURED_JSON_BYTES",
            exact_size,
        ), mock.patch.object(
            run_evidence.summaries, "_utc_now", return_value=finished_at
        ):
            finalized = run_evidence._finalize_attempt(
                exact_root, "failed", **finalize_arguments
            )
            retried = run_evidence._finalize_attempt(
                exact_root, "failed", **finalize_arguments
            )
        self.assertEqual(len(run_evidence._json_bytes(finalized)), exact_size)
        self.assertEqual(retried, finalized)

        events_before = (over_root / "bootstrap-events.jsonl").read_bytes()
        with mock.patch.object(
            run_evidence.summaries,
            "MAX_STRUCTURED_JSON_BYTES",
            exact_size - 1,
        ), mock.patch.object(
            run_evidence.summaries, "_utc_now", return_value=finished_at
        ), self.assertRaisesRegex(ValueError, "terminal summary exceeds"):
            run_evidence._finalize_attempt(
                over_root, "failed", **finalize_arguments
            )
        self.assertEqual(
            (over_root / "bootstrap-events.jsonl").read_bytes(), events_before
        )
        self.assertFalse((over_root / "run-summary.json").exists())
        self.assertFalse((over_root / "finalize-receipt.json").exists())
        transaction_root = self.publication_root / ".transactions"
        self.assertEqual(
            list(transaction_root.iterdir()) if transaction_root.exists() else [],
            [],
        )

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
