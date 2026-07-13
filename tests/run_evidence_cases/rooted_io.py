"""Descriptor-rooted evidence I/O containment cases."""

import io
import shutil

from .support import *  # noqa: F401,F403


_CONTAINMENT_DIAGNOSTIC = "evidence rooted I/O containment changed"


class RootedIOContainmentTests(CommandTestCase):
    @staticmethod
    def _tree_snapshot(root):
        snapshot = {}
        for path in sorted(Path(root).rglob("*")):
            relative = path.relative_to(root).as_posix()
            snapshot[relative] = (
                "symlink"
                if path.is_symlink()
                else "directory"
                if path.is_dir()
                else path.read_bytes()
            )
        return snapshot

    def test_mutation_capability_is_public_and_fails_before_side_effects(self):
        self.assertEqual(run_evidence.MINIMUM_PYTHON, (3, 10))
        self.assertEqual(
            run_evidence.EVIDENCE_MUTATION_CAPABILITY, "posix-safe-dirfd"
        )
        self.assertTrue(run_evidence.POSIX_SAFE_DIRFD_AVAILABLE)
        before = self._tree_snapshot(self.publication_root)
        new_root = self.attempt_root("unsupported-run")
        new_context = valid_context(runId="unsupported-run")
        operations = (
            lambda: run_evidence._initialize_attempt(
                self.index_path, new_root, new_context
            ),
            lambda: run_evidence.register_attempt(
                self.index_path, new_root, new_context
            ),
            lambda: run_evidence.update_context(
                self.root, {"artifacts": {"trace": "trace.json"}}
            ),
            lambda: run_evidence._append_event(
                self.root, "scenario.execute", "started"
            ),
            lambda: run_evidence._record_external(
                self.root,
                "app.build",
                "unsupported-external",
                "success",
                "runner.unclassified",
                "No remediation is required",
            ),
            lambda: run_evidence._run_command(
                self.root,
                "scenario.execute",
                "unsupported-command",
                "runner.driver_protocol",
                [sys.executable, "-c", "pass"],
            ),
            lambda: run_evidence._finalize_attempt(self.root, "passed"),
            lambda: run_evidence._recover_pending_transactions(
                self.publication_root
            ),
        )
        with mock.patch.object(
            run_evidence.safe_io, "POSIX_SAFE_DIRFD_AVAILABLE", False
        ):
            for operation in operations:
                with self.subTest(operation=operation):
                    with self.assertRaisesRegex(
                        RuntimeError,
                        "evidence mutation requires POSIX safe-dirfd primitives",
                    ):
                        operation()
                    self.assertEqual(
                        self._tree_snapshot(self.publication_root), before
                    )
            validation_errors = run_evidence.validate_bundle(
                self.root, secrets=[]
            )
            self.assertTrue(
                any(
                    "POSIX safe-dirfd capability is unavailable" in error
                    for error in validation_errors
                ),
                validation_errors,
            )

    def test_help_discloses_mutation_capability_requirement(self):
        result = subprocess.run(
            [sys.executable, str(MODULE_PATH), "--help"],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("POSIX safe-dirfd primitives", result.stdout)
        self.assertIn("Python >= 3.10", result.stdout)

    def test_root_descriptor_is_cloexec_and_closed_with_scope(self):
        with run_evidence._rooted_io(self.publication_root) as authority:
            descriptor = authority.descriptor
            self.assertFalse(os.get_inheritable(descriptor))
            probe = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    (
                        "import os,sys\n"
                        "try: os.fstat(int(sys.argv[1]))\n"
                        "except OSError: raise SystemExit(0)\n"
                        "raise SystemExit(19)\n"
                    ),
                    str(descriptor),
                ],
                close_fds=False,
                check=False,
            )
            self.assertEqual(probe.returncode, 0)
        with self.assertRaises(OSError):
            os.fstat(descriptor)

    def test_atomic_temporary_mode_is_0600_under_restrictive_umask(self):
        target = self.publication_root / "mode-probe.json"
        observed_modes = []

        def checkpoint(operation, phase, path):
            if (
                operation == "atomic_write"
                and phase == "before_replace"
                and Path(path) == target
            ):
                temporary = next(target.parent.glob(f".{target.name}.*.tmp"))
                observed_modes.append(temporary.stat().st_mode & 0o777)

        previous_umask = os.umask(0o777)
        try:
            with run_evidence._rooted_io(self.publication_root):
                with mock.patch.object(
                    run_evidence.safe_io,
                    "_rooted_io_checkpoint",
                    side_effect=checkpoint,
                ):
                    run_evidence._atomic_write_bytes(target, b"{}\n")
        finally:
            os.umask(previous_umask)
        self.assertEqual(observed_modes, [0o600])
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def _swap_directory(self, directory, target_path, *, mirror_temporary):
        directory = Path(directory)
        target_path = Path(target_path)
        relative_target = target_path.relative_to(directory)
        relocated = directory.with_name(directory.name + ".trusted-relocated")
        external = Path(self.temporary.name) / (
            "external-" + directory.name.replace(".", "dot")
        )
        external.mkdir(parents=True)
        external_target = external / relative_target
        external_target.parent.mkdir(parents=True, exist_ok=True)
        sentinel = b"external-target-must-remain-untouched"
        external_target.write_bytes(sentinel)

        directory.rename(relocated)
        directory.symlink_to(external, target_is_directory=True)
        if mirror_temporary:
            trusted_parent = relocated / relative_target.parent
            external_parent = external / relative_target.parent
            candidates = sorted(
                trusted_parent.glob(f".{target_path.name}.*.tmp")
            )
            self.assertEqual(
                len(candidates), 1, "atomic temporary was not visible at checkpoint"
            )
            shutil.copyfile(candidates[0], external_parent / candidates[0].name)
        return relocated, external_target, sentinel

    @staticmethod
    def _restore_directory(directory, relocated):
        directory = Path(directory)
        if directory.is_symlink():
            directory.unlink()
        if relocated.exists():
            relocated.rename(directory)

    def _assert_atomic_swap_rejected(self, directory, predicate, operation):
        swapped = {}

        def checkpoint(io_operation, phase, path):
            if swapped or io_operation != "atomic_write" or phase != "before_replace":
                return
            if not predicate(Path(path)):
                return
            relocated, external_target, sentinel = self._swap_directory(
                directory, path, mirror_temporary=True
            )
            swapped.update(
                relocated=relocated,
                external_target=external_target,
                sentinel=sentinel,
            )

        observed_error = None
        try:
            with mock.patch.object(
                run_evidence.safe_io,
                "_rooted_io_checkpoint",
                side_effect=checkpoint,
            ):
                operation()
        except Exception as exc:  # exact rooted error is asserted below
            observed_error = str(exc)
        finally:
            if swapped:
                self._restore_directory(directory, swapped["relocated"])

        self.assertTrue(swapped, "fault checkpoint did not reach the target operation")
        self.assertTrue(swapped["external_target"].is_file())
        self.assertEqual(
            swapped["external_target"].read_bytes(), swapped["sentinel"]
        )
        self.assertIsNotNone(observed_error)
        self.assertIn(_CONTAINMENT_DIAGNOSTIC, observed_error)

    def test_context_target_write_rejects_attempt_directory_swap(self):
        self._assert_atomic_swap_rejected(
            self.root,
            lambda path: path.name == "run-context.json",
            lambda: run_evidence.update_context(
                self.root, {"artifacts": {"trace": "traces/run.json"}}
            ),
        )

    def test_event_target_write_rejects_attempt_directory_swap(self):
        self._assert_atomic_swap_rejected(
            self.root,
            lambda path: path.name == "bootstrap-events.jsonl",
            lambda: run_evidence._append_event(
                self.root, "scenario.execute", "started"
            ),
        )

    def test_summary_target_write_rejects_attempt_directory_swap(self):
        self._assert_atomic_swap_rejected(
            self.root,
            lambda path: path.name == "run-summary.json",
            lambda: run_evidence._finalize_attempt(self.root, "passed"),
        )

    def test_command_log_write_rejects_commands_directory_swap(self):
        commands_root = self.root / "commands"
        self._assert_atomic_swap_rejected(
            commands_root,
            lambda path: path.name.endswith(".stdout.log"),
            lambda: run_evidence._run_command(
                self.root,
                "scenario.execute",
                "rooted-log",
                "runner.driver_protocol",
                [sys.executable, "-c", "import os;os.write(1,b'bounded-log')"],
                stdout_stream=io.BytesIO(),
                stderr_stream=io.BytesIO(),
            ),
        )

    def test_journal_write_rejects_transaction_directory_swap(self):
        transaction_root = self.publication_root / ".transactions"
        self._assert_atomic_swap_rejected(
            transaction_root,
            lambda path: path.parent.name == ".transactions",
            lambda: run_evidence.update_context(
                self.root, {"artifacts": {"trace": "traces/run.json"}}
            ),
        )

    def test_journal_unlink_rejects_transaction_directory_swap(self):
        transaction_root = self.publication_root / ".transactions"
        swapped = {}

        def checkpoint(operation, phase, path):
            if swapped or operation != "journal" or phase != "before_unlink":
                return
            relocated, external_target, sentinel = self._swap_directory(
                transaction_root, path, mirror_temporary=False
            )
            swapped.update(
                relocated=relocated,
                external_target=external_target,
                sentinel=sentinel,
            )

        observed_error = None
        try:
            with mock.patch.object(
                run_evidence.safe_io,
                "_rooted_io_checkpoint",
                side_effect=checkpoint,
            ):
                run_evidence.update_context(
                    self.root, {"artifacts": {"trace": "traces/run.json"}}
                )
        except Exception as exc:
            observed_error = str(exc)
        finally:
            if swapped:
                self._restore_directory(transaction_root, swapped["relocated"])

        self.assertTrue(swapped)
        self.assertTrue(swapped["external_target"].is_file())
        self.assertEqual(
            swapped["external_target"].read_bytes(), swapped["sentinel"]
        )
        self.assertIsNotNone(observed_error)
        self.assertIn(_CONTAINMENT_DIAGNOSTIC, observed_error)

    def test_journal_unlink_revalidates_verified_attempt_parent(self):
        swapped = {}

        def checkpoint(operation, phase, path):
            if swapped or operation != "journal" or phase != "before_unlink":
                return
            relocated, external_target, sentinel = self._swap_directory(
                self.root,
                self.root / "run-context.json",
                mirror_temporary=False,
            )
            swapped.update(
                relocated=relocated,
                external_target=external_target,
                sentinel=sentinel,
            )

        observed_error = None
        try:
            with mock.patch.object(
                run_evidence.safe_io,
                "_rooted_io_checkpoint",
                side_effect=checkpoint,
            ):
                run_evidence.update_context(
                    self.root, {"artifacts": {"trace": "traces/run.json"}}
                )
        except Exception as exc:
            observed_error = str(exc)
        finally:
            if swapped:
                self._restore_directory(self.root, swapped["relocated"])

        self.assertTrue(swapped)
        self.assertTrue(swapped["external_target"].is_file())
        self.assertEqual(
            swapped["external_target"].read_bytes(), swapped["sentinel"]
        )
        self.assertIsNotNone(observed_error)
        self.assertIn(_CONTAINMENT_DIAGNOSTIC, observed_error)

    def test_bundle_read_rejects_attempt_root_swap_without_reading_external(self):
        run_evidence._finalize_attempt(self.root, "passed")
        external = Path(self.temporary.name) / "external-bundle"
        shutil.copytree(self.root, external)
        secret = "external-read-proof-secret"
        (external / "external-proof.txt").write_text(secret, encoding="utf-8")
        relocated = self.root.with_name(self.root.name + ".trusted-relocated")
        swapped = False

        def checkpoint(operation, phase, path):
            nonlocal swapped
            if (
                swapped
                or operation != "read_json"
                or phase != "before_open"
                or Path(path).name != "run-summary.json"
            ):
                return
            self.root.rename(relocated)
            self.root.symlink_to(external, target_is_directory=True)
            swapped = True

        try:
            with mock.patch.object(
                run_evidence.safe_io,
                "_rooted_io_checkpoint",
                side_effect=checkpoint,
            ):
                errors = run_evidence.validate_bundle(self.root, secrets=[secret])
        finally:
            if swapped:
                self._restore_directory(self.root, relocated)

        self.assertTrue(swapped)
        self.assertTrue(
            any(_CONTAINMENT_DIAGNOSTIC in error for error in errors), errors
        )
        self.assertFalse(
            any("contains a current known secret value" in error for error in errors),
            errors,
        )
