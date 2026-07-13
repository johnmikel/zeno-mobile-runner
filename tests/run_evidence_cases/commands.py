"""Subprocess and external-command capture cases."""

import base64
import io
import threading
import time

from .support import *  # noqa: F401,F403

try:
    import resource
except ImportError:  # pragma: no cover - non-POSIX portability
    resource = None


class CommandCaptureTests(CommandTestCase):
    def test_subprocess_metadata_is_bounded_before_event_or_spawn(self):
        events_path = self.root / "bootstrap-events.jsonl"
        events_before = events_path.read_bytes()
        commands_before = sorted((self.root / "commands").iterdir())

        with mock.patch.object(
            run_evidence.constants, "MAX_STRUCTURED_JSON_BYTES", 1
        ), mock.patch.object(
            run_evidence.commands.subprocess,
            "Popen",
            wraps=subprocess.Popen,
        ) as popen, self.assertRaisesRegex(
            ValueError, "command metadata exceeds 1 bytes"
        ):
            run_evidence._run_command(
                self.root,
                "scenario.execute",
                "bounded-command",
                "runner.unclassified",
                [sys.executable, "-c", "pass"],
            )

        self.assertEqual(popen.call_count, 0)
        self.assertEqual(events_path.read_bytes(), events_before)
        self.assertEqual(sorted((self.root / "commands").iterdir()), commands_before)

    @staticmethod
    def _process_is_running(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            pass
        status = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        return bool(status) and not status.startswith("Z")

    def _wait_for_processes_to_stop(self, pids, timeout):
        deadline = time.monotonic() + timeout
        survivors = list(pids)
        while survivors and time.monotonic() < deadline:
            survivors = [pid for pid in survivors if self._process_is_running(pid)]
            if survivors:
                time.sleep(0.05)
        return [pid for pid in survivors if self._process_is_running(pid)]

    def _kill_processes(self, pids):
        pids = list(dict.fromkeys(pids))
        for pid in reversed(pids):
            if self._process_is_running(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self._wait_for_processes_to_stop(pids, 2)

    @staticmethod
    def _descendant_pids(parent_pid):
        rows = subprocess.run(
            ["ps", "-axo", "pid=,ppid="],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.splitlines()
        children = {}
        for row in rows:
            try:
                pid_text, parent_text = row.split()
            except ValueError:
                continue
            children.setdefault(int(parent_text), []).append(int(pid_text))
        descendants = []
        pending = list(children.get(parent_pid, ()))
        while pending:
            pid = pending.pop()
            descendants.append(pid)
            pending.extend(children.get(pid, ()))
        return descendants

    @staticmethod
    def _kill_owned_process_groups(pids):
        for pid in set(pids):
            try:
                process_group = os.getpgid(pid)
            except ProcessLookupError:
                continue
            if process_group != pid or process_group == os.getpgrp():
                continue
            try:
                os.killpg(process_group, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def _assert_wrapper_signal_cleans_descendants(self, signal_number):
        pid_file = self.publication_root / f"signal-{signal_number}-pids.json"
        child_signal_file = self.publication_root / f"signal-{signal_number}-child.txt"
        grandchild_signal_file = (
            self.publication_root / f"signal-{signal_number}-grandchild.txt"
        )
        grandchild_ready_file = (
            self.publication_root / f"signal-{signal_number}-grandchild-ready"
        )
        early_child_pid_file = (
            self.publication_root / f"signal-{signal_number}-early-child-pid"
        )
        grandchild_script = (
            "import os,signal,sys,time\n"
            "def record(number,_frame):\n"
            " with open(sys.argv[1],'a',encoding='ascii') as handle:\n"
            "  handle.write(str(number)+'\\n')\n"
            "signal.signal(signal.SIGINT,record)\n"
            "signal.signal(signal.SIGTERM,record)\n"
            "with open(sys.argv[2],'w',encoding='ascii') as handle:\n"
            " handle.write('ready')\n"
            "while True: time.sleep(1)\n"
        )
        child_script = (
            "import json,os,signal,subprocess,sys,time\n"
            "def record(number,_frame):\n"
            " with open(sys.argv[3],'a',encoding='ascii') as handle:\n"
            "  handle.write(str(number)+'\\n')\n"
            "signal.signal(signal.SIGINT,record)\n"
            "signal.signal(signal.SIGTERM,record)\n"
            "with open(sys.argv[6],'w',encoding='ascii') as handle:\n"
            " handle.write(str(os.getpid()))\n"
            "grandchild=subprocess.Popen(\n"
            " [sys.executable,'-c',sys.argv[2],sys.argv[4],sys.argv[5]],\n"
            " stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,"
            "stderr=subprocess.DEVNULL)\n"
            "while not os.path.exists(sys.argv[5]): time.sleep(.01)\n"
            "os.write(1,b'child-ready\\n')\n"
            "os.write(2,b'child-error-ready\\n')\n"
            "temporary=sys.argv[1]+'.tmp'\n"
            "with open(temporary,'w',encoding='utf-8') as handle:\n"
            " json.dump({'child':os.getpid(),'grandchild':grandchild.pid},handle)\n"
            "os.replace(temporary,sys.argv[1])\n"
            "while True: time.sleep(1)\n"
        )
        wrapper = subprocess.Popen(
            [
                sys.executable,
                str(MODULE_PATH),
                "command",
                "--root",
                str(self.root),
                "--phase",
                "scenario.execute",
                "--name",
                f"wrapper-signal-{signal_number}",
                "--failure-code",
                "run.cancelled",
                "--",
                sys.executable,
                "-c",
                child_script,
                str(pid_file),
                grandchild_script,
                str(child_signal_file),
                str(grandchild_signal_file),
                str(grandchild_ready_file),
                str(early_child_pid_file),
            ],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        pids = []
        timed_out = False
        stdout = b""
        stderr = b""
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    payload = json.loads(pid_file.read_text(encoding="utf-8"))
                except (FileNotFoundError, json.JSONDecodeError):
                    if wrapper.poll() is not None:
                        break
                    time.sleep(0.05)
                    continue
                pids = [payload["child"], payload["grandchild"]]
                break
            self.assertEqual(len(pids), 2, "child PID handoff did not complete")
            self.assertTrue(all(self._process_is_running(pid) for pid in pids))

            os.kill(wrapper.pid, signal_number)
            try:
                stdout, stderr = wrapper.communicate(timeout=6)
            except subprocess.TimeoutExpired:
                timed_out = True
                wrapper.kill()
                stdout, stderr = wrapper.communicate(timeout=3)

            survivors = self._wait_for_processes_to_stop(pids, 1)
            events = self.read_events(self.root)
            metadata = self.command_metadata()
            observation = {
                "timedOut": timed_out,
                "returnCode": wrapper.returncode,
                "survivingDescendants": survivors,
                "eventStatuses": [event["status"] for event in events[-2:]],
                "cancelledEventCount": sum(
                    event["status"] == "cancelled" for event in events
                ),
                "metadataCount": len(metadata),
                "metadataSignal": metadata[0]["signal"] if metadata else None,
                "metadataExitStatus": (
                    metadata[0]["exitStatus"] if metadata else "missing"
                ),
                "forwardedSignals": [
                    int(path.read_text(encoding="ascii").splitlines()[0])
                    if path.exists()
                    else None
                    for path in (child_signal_file, grandchild_signal_file)
                ],
                "stdoutCaptured": b"child-ready" in stdout,
                "stderrCaptured": b"child-error-ready" in stderr,
            }
            self.assertEqual(
                observation,
                {
                    "timedOut": False,
                    "returnCode": 128 + signal_number,
                    "survivingDescendants": [],
                    "eventStatuses": ["started", "cancelled"],
                    "cancelledEventCount": 1,
                    "metadataCount": 1,
                    "metadataSignal": signal_number,
                    "metadataExitStatus": None,
                    "forwardedSignals": [signal_number, signal_number],
                    "stdoutCaptured": True,
                    "stderrCaptured": True,
                },
            )
        finally:
            cleanup_pids = list(pids)
            if wrapper.poll() is None:
                cleanup_pids.extend(self._descendant_pids(wrapper.pid))
            try:
                early_child_pid = int(
                    early_child_pid_file.read_text(encoding="ascii")
                )
            except (FileNotFoundError, ValueError):
                early_child_pid = None
            if early_child_pid is not None:
                cleanup_pids.extend(self._descendant_pids(early_child_pid))
                cleanup_pids.append(early_child_pid)
                try:
                    child_group = os.getpgid(early_child_pid)
                except ProcessLookupError:
                    child_group = None
                if child_group == early_child_pid and child_group != os.getpgrp():
                    try:
                        os.killpg(child_group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            self._kill_owned_process_groups(cleanup_pids)
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.communicate(timeout=3)
            self._kill_processes(set(cleanup_pids))

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "killpg"),
        "requires POSIX process groups",
    )
    def test_sigint_to_wrapper_cancels_and_reaps_child_process_group(self):
        self._assert_wrapper_signal_cleans_descendants(signal.SIGINT)

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "killpg"),
        "requires POSIX process groups",
    )
    def test_sigterm_to_wrapper_cancels_and_reaps_child_process_group(self):
        self._assert_wrapper_signal_cleans_descendants(signal.SIGTERM)

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "killpg"),
        "requires POSIX process groups",
    )
    def test_signal_during_descendant_pipe_drain_still_escalates(self):
        pid_file = self.publication_root / "drain-signal-pids.json"
        signal_file = self.publication_root / "drain-signal-grandchild.txt"
        ready_file = self.publication_root / "drain-signal-grandchild-ready"
        early_child_pid_file = self.publication_root / "drain-signal-child-pid"
        grandchild_script = (
            "import os,signal,sys,time\n"
            "def record(number,_frame):\n"
            " with open(sys.argv[1],'a',encoding='ascii') as handle:\n"
            "  handle.write(str(number)+'\\n')\n"
            "signal.signal(signal.SIGINT,record)\n"
            "signal.signal(signal.SIGTERM,record)\n"
            "with open(sys.argv[2],'w',encoding='ascii') as handle:\n"
            " handle.write('ready')\n"
            "os.write(1,b'grandchild-pipe-open\\n')\n"
            "os.write(2,b'grandchild-error-pipe-open\\n')\n"
            "while True: time.sleep(1)\n"
        )
        child_script = (
            "import json,os,subprocess,sys,time\n"
            "with open(sys.argv[5],'w',encoding='ascii') as handle:\n"
            " handle.write(str(os.getpid()))\n"
            "grandchild=subprocess.Popen("
            "[sys.executable,'-c',sys.argv[2],sys.argv[3],sys.argv[4]])\n"
            "while not os.path.exists(sys.argv[4]): time.sleep(.01)\n"
            "temporary=sys.argv[1]+'.tmp'\n"
            "with open(temporary,'w',encoding='utf-8') as handle:\n"
            " json.dump({'child':os.getpid(),'grandchild':grandchild.pid},handle)\n"
            "os.replace(temporary,sys.argv[1])\n"
            "os.write(1,b'child-exiting\\n')\n"
            "os.write(2,b'child-error-exiting\\n')\n"
        )
        wrapper = subprocess.Popen(
            [
                sys.executable,
                str(MODULE_PATH),
                "command",
                "--root",
                str(self.root),
                "--phase",
                "scenario.execute",
                "--name",
                "descendant-drain-signal",
                "--failure-code",
                "run.cancelled",
                "--",
                sys.executable,
                "-c",
                child_script,
                str(pid_file),
                grandchild_script,
                str(signal_file),
                str(ready_file),
                str(early_child_pid_file),
            ],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        pids = []
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    payload = json.loads(pid_file.read_text(encoding="utf-8"))
                except (FileNotFoundError, json.JSONDecodeError):
                    time.sleep(0.05)
                    continue
                pids = [payload["child"], payload["grandchild"]]
                break
            self.assertEqual(len(pids), 2)
            deadline = time.monotonic() + 3
            while self._process_is_running(pids[0]) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(self._process_is_running(pids[0]))
            self.assertTrue(self._process_is_running(pids[1]))
            self.assertIsNone(wrapper.poll(), "wrapper did not wait for open pipes")

            os.kill(wrapper.pid, signal.SIGTERM)
            stdout, stderr = wrapper.communicate(timeout=6)
            self.assertEqual(wrapper.returncode, 128 + signal.SIGTERM)
            self.assertEqual(self._wait_for_processes_to_stop(pids, 1), [])
            self.assertEqual(
                int(signal_file.read_text(encoding="ascii").splitlines()[0]),
                signal.SIGTERM,
            )
            metadata = self.command_metadata()
            self.assertEqual(len(metadata), 1)
            self.assertIsNone(metadata[0]["exitStatus"])
            self.assertEqual(metadata[0]["signal"], signal.SIGTERM)
            events = self.read_events(self.root)
            self.assertEqual(
                [event["status"] for event in events[-2:]],
                ["started", "cancelled"],
            )
            self.assertEqual(
                sum(event["status"] == "cancelled" for event in events), 1
            )
            self.assertIn(b"child-exiting", stdout)
            self.assertIn(b"grandchild-pipe-open", stdout)
            self.assertIn(b"child-error-exiting", stderr)
            self.assertIn(b"grandchild-error-pipe-open", stderr)
        finally:
            cleanup_pids = list(pids)
            if wrapper.poll() is None:
                cleanup_pids.extend(self._descendant_pids(wrapper.pid))
            try:
                child_group = int(
                    early_child_pid_file.read_text(encoding="ascii")
                )
            except (FileNotFoundError, ValueError):
                child_group = None
            if child_group is not None and child_group != os.getpgrp():
                try:
                    os.killpg(child_group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self._kill_owned_process_groups(cleanup_pids)
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.communicate(timeout=3)
            self._kill_processes(cleanup_pids)

    def test_streaming_sanitizer_redacts_values_straddling_carry_flush(self):
        carry = run_evidence._SANITIZATION_CARRY
        roots = {"workspace": "", "run_root": "", "home": ""}
        cases = (
            (b"very-secret-value", ["very-secret-value"], False),
            (b"https://person:password@example.test/resource", [], True),
        )
        for token, secrets, prefix_with_boundary in cases:
            prefix_size = carry - len(token) // 2
            prefix = b"x" * prefix_size
            if prefix_with_boundary:
                prefix = prefix[:-1] + b"!"
            suffix_size = carry - ((len(token) + 1) // 2) + 1
            raw = prefix + token + b"z" * suffix_size
            self.assertGreater(len(raw), carry * 2)
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=secrets
            )
            actual = sanitizer.feed(raw) + sanitizer.finish()
            expected = run_evidence.sanitize_text(
                raw.decode("utf-8"), roots=roots, secrets=secrets
            ).encode("utf-8")
            with self.subTest(token=token):
                self.assertEqual(actual, expected)
                self.assertNotIn(token, actual)

    def test_rfc3986_userinfo_subdelimiters_never_replay_or_persist(self):
        roots = {"workspace": "", "run_root": "", "home": ""}
        subdelimiters = b"!$&'()*+,;="
        credentials = tuple(
            b"https://user"
            + bytes((delimiter,))
            + b"param:password@example.test/"
            + str(index).encode("ascii")
            for index, delimiter in enumerate(subdelimiters)
        )
        redacted_credentials = tuple(
            b"https://example.test/" + str(index).encode("ascii")
            for index in range(len(subdelimiters))
        )
        raw = b"\n".join(credentials) + b"\n"
        expected = b"\n".join(redacted_credentials) + b"\n"

        whole = run_evidence.sanitize_text(
            raw.decode("utf-8"), roots=roots, secrets=[]
        ).encode("utf-8")
        sanitizer = run_evidence.StreamingSanitizer(
            roots=roots, secrets=[]
        )
        streamed = b"".join(sanitizer.feed(bytes((byte,))) for byte in raw)
        streamed += sanitizer.finish()

        for credential, redacted in zip(credentials, redacted_credentials):
            token = credential + b"\n"
            for split in range(len(token) + 1):
                sanitizer = run_evidence.StreamingSanitizer(
                    roots=roots, secrets=[]
                )
                actual = sanitizer.feed(token[:split])
                actual += sanitizer.feed(token[split:])
                actual += sanitizer.finish()
                with self.subTest(delimiter=credential[12:13], split=split):
                    self.assertEqual(actual, redacted + b"\n")

        stdout = io.BytesIO()
        stderr = io.BytesIO()
        script = (
            "import base64,os,sys;data=base64.b64decode(sys.argv[1]);"
            "os.write(1,data);os.write(2,data)"
        )
        return_code = run_evidence._run_command(
            self.root,
            "scenario.execute",
            "userinfo-subdelimiters",
            "runner.driver_protocol",
            [
                sys.executable,
                "-c",
                script,
                base64.b64encode(raw).decode("ascii"),
            ],
            stdout_stream=stdout,
            stderr_stream=stderr,
        )
        metadata = self.command_metadata()[-1]
        stored_stdout = (self.root / metadata["stdout"]["path"]).read_bytes()
        stored_stderr = (self.root / metadata["stderr"]["path"]).read_bytes()

        self.assertEqual(return_code, 0)
        for publishable in (
            whole,
            streamed,
            stdout.getvalue(),
            stderr.getvalue(),
            stored_stdout,
            stored_stderr,
        ):
            self.assertEqual(publishable, expected)
            for credential in credentials:
                self.assertNotIn(credential.split(b"@", 1)[0], publishable)

        carry = run_evidence._SANITIZATION_CARRY
        payload = b"sensitive-userinfo-" * ((carry * 2) // 19 + 1)
        for delimiter in subdelimiters:
            credential = (
                b"https://user"
                + bytes((delimiter,))
                + payload
                + b":password@example.test/path"
            )
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            actual = bytearray()
            for offset in range(0, len(credential), carry // 2):
                actual.extend(
                    sanitizer.feed(credential[offset : offset + carry // 2])
                )
            actual.extend(sanitizer.feed(b"\nsafe-tail"))
            actual.extend(sanitizer.finish())
            with self.subTest(overlong_delimiter=bytes((delimiter,))):
                self.assertEqual(bytes(actual), b"<redacted>\nsafe-tail")
                self.assertNotIn(payload[:1024], actual)
                self.assertNotIn(b":password@example.test", actual)

    def test_open_known_root_scan_is_linear_on_overlapping_invalid_matches(self):
        root = "/a" * 64 + "/a"

        def scan(repetitions):
            sanitizer = run_evidence.StreamingSanitizer(
                roots={"workspace": root, "run_root": "", "home": ""},
                secrets=[],
            )
            sanitizer._pending = (root + "x") * repetitions
            self.assertEqual(sanitizer._open_known_roots(), [])
            return len(sanitizer._pending), sanitizer._root_scan_work

        small_length, small_work = scan(32)
        large_length, large_work = scan(64)

        self.assertLessEqual(small_work, small_length * 4 + len(root) * 2)
        self.assertLessEqual(large_work, large_length * 4 + len(root) * 2)
        self.assertLessEqual(large_work, small_work * 2 + len(root) * 2)

    def test_streaming_sanitizer_redacts_overlong_credential_token_wholesale(self):
        carry = run_evidence._SANITIZATION_CARRY
        roots = {"workspace": "", "run_root": "", "home": ""}
        credential_prefix = b"https://user:"
        credential_payload = b"x" * (carry * 4 + 8192)
        unresolved = credential_prefix + credential_payload
        sanitizer = run_evidence.StreamingSanitizer(roots=roots, secrets=[])
        output = bytearray()
        chunk_size = carry // 2

        for offset in range(0, len(unresolved), chunk_size):
            emitted = sanitizer.feed(unresolved[offset : offset + chunk_size])
            self.assertFalse(
                credential_prefix in emitted,
                f"credential prefix leaked at offset {offset}",
            )
            self.assertFalse(
                credential_payload[:1024] in emitted,
                f"credential payload leaked at offset {offset}",
            )
            self.assertLessEqual(len(sanitizer._pending), carry * 2)
            output.extend(emitted)
        self.assertEqual(bytes(output), b"<redacted>")
        output.extend(sanitizer.feed(b"@example.test/path"))
        self.assertEqual(bytes(output), b"<redacted>")
        output.extend(sanitizer.feed(b"\nsafe-tail"))
        output.extend(sanitizer.finish())

        self.assertEqual(bytes(output), b"<redacted>\nsafe-tail")

    def test_overlong_safe_url_candidate_preserves_delimited_tail(self):
        carry = run_evidence._SANITIZATION_CARRY
        unresolved = b"https://" + b"x" * (carry * 2 + 1)
        roots = {"workspace": "", "run_root": "", "home": ""}

        for delimiter in (
            b" ",
            b"\t",
            b"\r",
            b"\n",
            b"\x00",
            b'"',
            b"<",
            b">",
            b"|",
            b"/",
        ):
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            redacted = sanitizer.feed(unresolved)
            tail = sanitizer.feed(delimiter + b"safe-tail")
            actual = redacted + tail + sanitizer.finish()
            expected_tail = run_evidence.sanitize_text(
                (delimiter + b"safe-tail").decode("utf-8"),
                roots=roots,
                secrets=[],
            ).encode("utf-8")
            with self.subTest(delimiter=delimiter):
                self.assertEqual(actual, b"<redacted>" + expected_tail)

        for userinfo_subdelimiter in (b"'", b",", b";"):
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            actual = sanitizer.feed(unresolved)
            actual += sanitizer.feed(userinfo_subdelimiter + b"safe-tail")
            actual += sanitizer.finish()
            with self.subTest(userinfo_subdelimiter=userinfo_subdelimiter):
                self.assertEqual(actual, b"<redacted>")

    def test_file_uri_and_unc_paths_are_redacted_streaming(self):
        roots = {"workspace": "", "run_root": "", "home": ""}
        short_paths = (
            b"file://localhost/etc/private.conf",
            b"file:/var/private/data.db",
            b"\\\\server\\share\\private.txt",
        )
        expected = b"<absolute-path>\n" * len(short_paths)
        raw = b"\n".join(short_paths) + b"\n"
        self.assertEqual(
            run_evidence.sanitize_text(
                raw.decode("utf-8"), roots=roots, secrets=[]
            ).encode("utf-8"),
            expected,
        )

        for split in range(len(raw) + 1):
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            actual = sanitizer.feed(raw[:split])
            actual += sanitizer.feed(raw[split:])
            actual += sanitizer.finish()
            with self.subTest(split=split):
                self.assertEqual(actual, expected)

        carry = run_evidence._SANITIZATION_CARRY
        payload = b"private-path-" * ((carry * 2) // 13 + 1)
        for prefix in (
            b"file://localhost/etc/",
            b"file:/var/private/",
            b"\\\\server\\share\\",
        ):
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            value = prefix + payload
            actual = bytearray()
            for offset in range(0, len(value), carry // 2):
                actual.extend(
                    sanitizer.feed(value[offset : offset + carry // 2])
                )
            actual.extend(sanitizer.feed(b"\nsafe-tail"))
            actual.extend(sanitizer.finish())
            with self.subTest(prefix=prefix):
                self.assertEqual(bytes(actual), b"<absolute-path>\nsafe-tail")
                self.assertNotIn(prefix, actual)
                self.assertNotIn(payload[:1024], actual)

    def test_file_uri_scheme_boundary_and_path_punctuation_are_exact(self):
        roots = {"workspace": "", "run_root": "", "home": ""}
        safe = (
            b"profile:///public/resource",
            b"xfile:///public/resource",
            b"my-file://authority/public/resource",
        )
        explicit_file_uris = (
            b"file:/",
            b"file:///",
            b"file://authority/",
        )
        punctuation = b"private!$&'()*+,;=:@?query#fragment"
        sensitive = explicit_file_uris + (
            b"file:/" + punctuation,
            b"file:///" + punctuation,
            b"file://authority/" + punctuation,
            b"/" + punctuation,
            b"C:\\private\\" + punctuation,
        )

        for value in safe:
            with self.subTest(safe=value):
                self.assertEqual(
                    run_evidence.sanitize_text(
                        value.decode("ascii"), roots=roots, secrets=[]
                    ).encode("ascii"),
                    value,
                )

        for value in sensitive:
            with self.subTest(sensitive=value):
                sanitized = run_evidence.sanitize_text(
                    value.decode("ascii"), roots=roots, secrets=[]
                ).encode("ascii")
                self.assertEqual(sanitized, b"<absolute-path>")
                scanner = run_evidence.bundle_scan._RawSemanticScanner(
                    roots={}, secrets=[]
                )
                scanner.feed(sanitized)
                self.assertNotIn("absolute_path", scanner.finish())

        raw = b"\n".join((*safe, *sensitive)) + b"\n"
        expected = b"\n".join(
            (*safe, *(b"<absolute-path>" for _value in sensitive))
        ) + b"\n"
        for split in range(len(raw) + 1):
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            actual = sanitizer.feed(raw[:split])
            actual += sanitizer.feed(raw[split:])
            actual += sanitizer.finish()
            with self.subTest(split=split):
                self.assertEqual(actual, expected)

    def test_overlong_punctuation_paths_redact_through_whitespace_boundaries(self):
        roots = {"workspace": "", "run_root": "", "home": ""}
        carry = run_evidence._SANITIZATION_CARRY
        segment = b"private!$&'()*+,;=:@?query#fragment/"
        payload = segment * ((carry * 2) // len(segment) + 2)

        for prefix in (
            b"file:/",
            b"file:///",
            b"file://authority/",
            b"/",
            b"C:\\private\\",
        ):
            for delimiter in (b"\v", b"\f"):
                sanitizer = run_evidence.StreamingSanitizer(
                    roots=roots, secrets=[]
                )
                output = bytearray()
                value = prefix + payload
                for offset in range(0, len(value), carry // 3):
                    output.extend(
                        sanitizer.feed(value[offset : offset + carry // 3])
                    )
                    self.assertLessEqual(len(sanitizer._pending), carry * 2)
                output.extend(sanitizer.feed(delimiter + b"safe-tail"))
                output.extend(sanitizer.finish())
                with self.subTest(prefix=prefix, delimiter=delimiter):
                    self.assertEqual(
                        bytes(output),
                        b"<absolute-path>" + delimiter + b"safe-tail",
                    )
                    scanner = run_evidence.bundle_scan._RawSemanticScanner(
                        roots={}, secrets=[]
                    )
                    scanner.feed(bytes(output))
                    self.assertNotIn("absolute_path", scanner.finish())

    def test_digit_heavy_unbounded_schemes_are_redacted_without_credential_leaks(self):
        carry = run_evidence._SANITIZATION_CARRY
        roots = {"workspace": "", "run_root": "", "home": ""}
        userinfo = b"user:scheme-password"

        for scheme in (
            b"a" + b"1" * 40,
            b"a" + b"1" * (carry * 2 + 8192),
        ):
            raw = scheme + b"://" + userinfo + b"@example.test/path\nsafe-tail"
            whole = run_evidence.sanitize_text(
                raw.decode("utf-8"), roots=roots, secrets=[]
            ).encode("utf-8")
            expected_whole = scheme + b"://example.test/path\nsafe-tail"
            self.assertEqual(whole, expected_whole)

            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            output = bytearray()
            for offset in range(0, len(scheme), 8192):
                output.extend(sanitizer.feed(scheme[offset : offset + 8192]))
                self.assertLessEqual(len(sanitizer._pending), carry * 2)
            for marker_byte in (b":", b"/", b"/"):
                output.extend(sanitizer.feed(marker_byte))
            output.extend(sanitizer.feed(userinfo + b"@example.test/path"))
            output.extend(sanitizer.feed(b"\nsafe-tail"))
            output.extend(sanitizer.finish())

            expected = expected_whole
            if len(scheme) > carry * 2:
                expected = scheme + b"<redacted>\nsafe-tail"
            with self.subTest(scheme_bytes=len(scheme)):
                self.assertEqual(bytes(output), expected)
                self.assertNotIn(userinfo, output)
                if len(scheme) > carry * 2:
                    self.assertNotIn(b"example.test", output)

    def test_overlong_absolute_path_families_are_redacted_wholesale(self):
        carry = run_evidence._SANITIZATION_CARRY
        roots = {"workspace": "", "run_root": "", "home": ""}
        payload = b"sensitive-path-" * ((carry * 2) // 15 + 1024)
        cases = (
            b"/private/",
            b"FiLe:///private/",
            b"C:\\private\\",
            b"D:/private/",
            b"\\\\server\\share\\",
        )

        for prefix in cases:
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            output = bytearray()
            for byte in prefix:
                output.extend(sanitizer.feed(bytes((byte,))))
            for offset in range(0, len(payload), carry // 2):
                output.extend(
                    sanitizer.feed(payload[offset : offset + carry // 2])
                )
                self.assertLessEqual(len(sanitizer._pending), carry * 2)
            output.extend(sanitizer.feed(b"\nsafe-tail"))
            output.extend(sanitizer.finish())
            with self.subTest(prefix=prefix):
                self.assertEqual(bytes(output), b"<absolute-path>\nsafe-tail")
                self.assertNotIn(payload[:1024], output)

    def test_overlong_absolute_path_preserves_delimiter_and_tail(self):
        carry = run_evidence._SANITIZATION_CARRY
        roots = {"workspace": "", "run_root": "", "home": ""}
        raw_path = b"/private/" + b"x" * (carry * 2 + 1)

        for delimiter in (
            b" ",
            b"\t",
            b"\r",
            b"\n",
            b"\v",
            b"\f",
            b"\x00",
            b'"',
            b"<",
            b">",
            b"|",
        ):
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            redacted = sanitizer.feed(raw_path)
            tail = sanitizer.feed(delimiter + b"safe-tail")
            actual = redacted + tail + sanitizer.finish()
            with self.subTest(delimiter=delimiter):
                self.assertEqual(
                    actual, b"<absolute-path>" + delimiter + b"safe-tail"
                )

    def test_overlong_known_roots_preserve_only_public_placeholders(self):
        carry = run_evidence._SANITIZATION_CARRY
        payload = b"private-child-" * ((carry * 2) // 14 + 1024)
        cases = (
            ("/workspace", b"/workspace/", b"${WORKSPACE}"),
            ("C:\\workspace", b"C:\\workspace\\", b"${WORKSPACE}"),
        )

        for root, prefix, placeholder in cases:
            roots = {"workspace": root, "run_root": "", "home": ""}
            sanitizer = run_evidence.StreamingSanitizer(
                roots=roots, secrets=[]
            )
            raw = prefix + payload
            output = bytearray()
            for offset in range(0, len(raw), carry // 2):
                output.extend(sanitizer.feed(raw[offset : offset + carry // 2]))
            output.extend(sanitizer.feed(b"\nsafe-tail"))
            output.extend(sanitizer.finish())
            with self.subTest(root=root):
                self.assertEqual(
                    bytes(output), placeholder + b"\nsafe-tail"
                )
                self.assertNotIn(root.encode("utf-8"), output)
                self.assertNotIn(payload[:1024], output)

        near_miss = b"/workspace-other/" + payload
        sanitizer = run_evidence.StreamingSanitizer(
            roots={"workspace": "/workspace", "run_root": "", "home": ""},
            secrets=[],
        )
        actual = sanitizer.feed(near_miss) + sanitizer.feed(b"\ntail")
        actual += sanitizer.finish()
        self.assertEqual(actual, b"<absolute-path>\ntail")

    def test_unbounded_scheme_and_paths_never_replay_or_persist(self):
        carry = run_evidence._SANITIZATION_CARRY
        payload_size = carry * 2 + 8192
        scheme = b"a" + b"1" * payload_size
        path_prefixes = (
            b"/private/",
            b"FiLe:///private/",
            b"C:\\private\\",
            b"D:/private/",
            b"\\\\server\\share\\",
        )
        script = (
            "import os,sys\n"
            "size=int(sys.argv[1]);payload=b'x'*size\n"
            "scheme=b'a'+b'1'*size\n"
            "paths=[b'/private/',b'FiLe:///private/',b'C:\\\\private\\\\',"
            "b'D:/private/',b'\\\\\\\\server\\\\share\\\\']\n"
            "content=b''.join(path+payload+b'\\n' for path in paths)\n"
            "content+=scheme+b'://user:password@example.test/path\\n'\n"
            "os.write(1,content);os.write(2,content)\n"
        )
        stdout = io.BytesIO()
        stderr = io.BytesIO()
        with mock.patch.object(
            run_evidence.commands, "_PIPE_READ_CHUNK_SIZE", carry // 2
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "unbounded-sensitive-tokens",
                "runner.driver_protocol",
                [sys.executable, "-c", script, str(payload_size)],
                stdout_stream=stdout,
                stderr_stream=stderr,
            )

        expected = b"<absolute-path>\n" * len(path_prefixes)
        expected += scheme + b"<redacted>\n"
        self.assertEqual(return_code, 0)
        self.assertEqual(stdout.getvalue(), expected)
        self.assertEqual(stderr.getvalue(), expected)
        metadata = self.command_metadata()[-1]
        stored_stdout = (self.root / metadata["stdout"]["path"]).read_bytes()
        stored_stderr = (self.root / metadata["stderr"]["path"]).read_bytes()
        raw_size = sum(
            len(prefix) + payload_size + 1 for prefix in path_prefixes
        )
        raw_size += len(scheme) + len(b"://user:password@example.test/path\n")
        self.assertEqual(metadata["stdout"]["originalBytes"], raw_size)
        self.assertEqual(metadata["stderr"]["originalBytes"], raw_size)
        self.assertEqual(
            metadata["stdout"]["sanitizedBytes"], len(expected)
        )
        self.assertEqual(
            metadata["stderr"]["sanitizedBytes"], len(expected)
        )
        self.assertEqual(stored_stdout, expected)
        self.assertEqual(stored_stderr, expected)
        for publishable in (
            stdout.getvalue(),
            stderr.getvalue(),
            stored_stdout,
            stored_stderr,
        ):
            self.assertNotIn(b"user:password", publishable)
            self.assertNotIn(b"example.test", publishable)
            self.assertNotIn(b"x" * 1024, publishable)
            for prefix in path_prefixes:
                self.assertNotIn(prefix, publishable)

    def test_unbounded_scheme_raw_capture_stays_raw_but_log_is_sanitized(self):
        carry = run_evidence._SANITIZATION_CARRY
        scheme = b"a" + b"1" * (carry * 2 + 8192)
        raw = scheme + b"://user:password@example.test/path"
        script = (
            "import os,sys;size=int(sys.argv[1]);"
            "os.write(1,b'a'+b'1'*size+b'://user:password@example.test/path')"
        )
        raw_stdout = io.BytesIO()
        with mock.patch.object(
            run_evidence.commands, "_PIPE_READ_CHUNK_SIZE", carry // 2
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "unbounded-scheme-raw-capture",
                "runner.driver_protocol",
                [sys.executable, "-c", script, str(len(scheme) - 1)],
                capture_stdout=True,
                stdout_stream=raw_stdout,
                stderr_stream=io.BytesIO(),
            )

        self.assertEqual(return_code, 0)
        self.assertEqual(raw_stdout.getvalue(), raw)
        metadata = self.command_metadata()[-1]
        stored_stdout = (self.root / metadata["stdout"]["path"]).read_bytes()
        self.assertEqual(metadata["stdout"]["originalBytes"], len(raw))
        self.assertEqual(
            metadata["stdout"]["sanitizedBytes"], len(stored_stdout)
        )
        self.assertEqual(stored_stdout, scheme + b"<redacted>")
        self.assertNotIn(b"user:password", stored_stdout)
        self.assertNotIn(b"example.test", stored_stdout)

    def test_overlong_credentials_never_replay_or_persist_in_command_logs(self):
        carry = run_evidence._SANITIZATION_CARRY
        payload_size = carry * 4 + 8192
        credential = (
            b"https://user:"
            + b"x" * payload_size
            + b"@example.test/path"
        )
        script = (
            "import os,sys\n"
            "credential=(b'https://user:'+b'x'*int(sys.argv[1])"
            "+b'@example.test/path')\n"
            "os.write(1,credential+b'\\nstdout-tail')\n"
            "os.write(2,credential+b'\\nstderr-tail')\n"
        )
        stdout = io.BytesIO()
        stderr = io.BytesIO()

        with mock.patch.object(
            run_evidence.commands, "_PIPE_READ_CHUNK_SIZE", carry // 2
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "overlong-credential",
                "runner.driver_protocol",
                [sys.executable, "-c", script, str(payload_size)],
                stdout_stream=stdout,
                stderr_stream=stderr,
            )

        self.assertEqual(return_code, 0)
        metadata = self.command_metadata()[-1]
        stored_stdout = (self.root / metadata["stdout"]["path"]).read_bytes()
        stored_stderr = (self.root / metadata["stderr"]["path"]).read_bytes()
        self.assertEqual(stdout.getvalue(), b"<redacted>\nstdout-tail")
        self.assertEqual(stderr.getvalue(), b"<redacted>\nstderr-tail")
        self.assertEqual(
            metadata["stdout"]["originalBytes"], len(credential) + 12
        )
        self.assertEqual(
            metadata["stderr"]["originalBytes"], len(credential) + 12
        )
        self.assertEqual(
            metadata["stdout"]["sanitizedBytes"], len(stdout.getvalue())
        )
        self.assertEqual(
            metadata["stderr"]["sanitizedBytes"], len(stderr.getvalue())
        )
        self.assertEqual(stored_stdout, stdout.getvalue())
        self.assertEqual(stored_stderr, stderr.getvalue())
        for publishable in (
            stdout.getvalue(),
            stderr.getvalue(),
            stored_stdout,
            stored_stderr,
        ):
            self.assertNotIn(credential, publishable)
            self.assertNotIn(b"https://user:", publishable)
            self.assertNotIn(b"example.test", publishable)

    def test_raw_capture_channel_does_not_change_persisted_overlong_redaction(self):
        carry = run_evidence._SANITIZATION_CARRY
        payload_size = carry * 4 + 8192
        credential = (
            b"https://user:"
            + b"x" * payload_size
            + b"@example.test/path"
        )
        script = (
            "import os,sys;os.write(1,b'https://user:'"
            "+b'x'*int(sys.argv[1])+b'@example.test/path')"
        )
        raw_stdout = io.BytesIO()

        with mock.patch.object(
            run_evidence.commands, "_PIPE_READ_CHUNK_SIZE", carry // 2
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "overlong-raw-capture",
                "runner.driver_protocol",
                [sys.executable, "-c", script, str(payload_size)],
                capture_stdout=True,
                stdout_stream=raw_stdout,
                stderr_stream=io.BytesIO(),
            )

        self.assertEqual(return_code, 0)
        self.assertEqual(raw_stdout.getvalue(), credential)
        metadata = self.command_metadata()[-1]
        stored_stdout = (self.root / metadata["stdout"]["path"]).read_bytes()
        self.assertEqual(stored_stdout, b"<redacted>")
        self.assertEqual(metadata["stdout"]["originalBytes"], len(credential))
        self.assertEqual(
            metadata["stdout"]["sanitizedBytes"], len(stored_stdout)
        )
        self.assertNotIn(credential, stored_stdout)
        self.assertNotIn(b"https://user:", stored_stdout)
        self.assertNotIn(b"example.test", stored_stdout)

    def test_capture_stdout_text_sink_decodes_split_utf8_incrementally(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(
            run_evidence.commands, "_PIPE_READ_CHUNK_SIZE", 1
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "text-capture",
                "runner.driver_protocol",
                [
                    sys.executable,
                    "-c",
                    "import os,time;data='😀'.encode();"
                    "[os.write(1,bytes([byte])) or time.sleep(.01) for byte in data]",
                ],
                capture_stdout=True,
                stdout_stream=stdout,
                stderr_stream=stderr,
            )
        self.assertEqual(return_code, 0)
        self.assertEqual(stdout.getvalue(), "😀")

    def test_capture_sink_failure_still_persists_terminal_evidence(self):
        class FailingSink:
            def write(self, _content):
                raise BrokenPipeError("capture sink closed")

            def flush(self):
                pass

        with self.assertRaisesRegex(BrokenPipeError, "capture sink closed"):
            run_evidence._run_command(
                self.root,
                "scenario.execute",
                "closed-capture",
                "runner.driver_protocol",
                [sys.executable, "-c", "import os;os.write(1,b'captured-output')"],
                capture_stdout=True,
                stdout_stream=FailingSink(),
                stderr_stream=io.BytesIO(),
            )
        metadata = self.command_metadata()
        self.assertEqual(len(metadata), 1)
        stdout_record = metadata[0]["stdout"]
        self.assertEqual(
            (self.root / stdout_record["path"]).read_bytes(), b"captured-output"
        )
        self.assertEqual(
            [event["status"] for event in self.read_events(self.root)[-2:]],
            ["started", "passed"],
        )

    def test_capture_stdout_is_forwarded_while_child_is_still_running(self):
        class SignallingBuffer:
            def __init__(self):
                self.data = bytearray()
                self.first_write = threading.Event()

            def write(self, content):
                if isinstance(content, str):
                    content = content.encode("utf-8")
                self.data.extend(content)
                self.first_write.set()
                return len(content)

            def flush(self):
                pass

        stdout = SignallingBuffer()
        stderr = io.BytesIO()
        outcome = {}

        def invoke():
            try:
                outcome["returnCode"] = run_evidence._run_command(
                    self.root,
                    "scenario.execute",
                    "direct-capture",
                    "runner.driver_protocol",
                    [
                        sys.executable,
                        "-c",
                        (
                            "import os,time;"
                            "os.write(1,b'first-chunk');"
                            "time.sleep(1.5);"
                            "os.write(1,b'-last-chunk')"
                        ),
                    ],
                    capture_stdout=True,
                    stdout_stream=stdout,
                    stderr_stream=stderr,
                )
            except BaseException as exc:  # surfaced after bounded cleanup
                outcome["error"] = exc

        worker = threading.Thread(target=invoke, daemon=True)
        worker.start()
        observed_while_running = stdout.first_write.wait(timeout=0.75)
        still_running_at_first_write = worker.is_alive()
        worker.join(timeout=5)
        self.assertFalse(worker.is_alive(), "command wrapper did not finish")
        if "error" in outcome:
            raise outcome["error"]
        self.assertTrue(observed_while_running)
        self.assertTrue(still_running_at_first_write)
        self.assertEqual(outcome["returnCode"], 0)
        self.assertEqual(bytes(stdout.data), b"first-chunk-last-chunk")

    def test_streaming_sanitization_handles_split_sensitive_and_utf8_sequences(self):
        secret = "boundary-secret"
        password = "boundary-password"
        raw = (
            b"prefix "
            + secret.encode("utf-8")
            + b" path="
            + str(self.root / "private" / "value.txt").encode("utf-8")
            + b" url=https://person:"
            + password.encode("utf-8")
            + b"@example.test/resource invalid="
            + b"\xe2(\xa1"
            + b" suffix"
        )
        pieces = [raw[index : index + 3] for index in range(0, len(raw), 3)]
        encoded = [base64.b64encode(piece).decode("ascii") for piece in pieces]
        script = (
            "import base64,os,sys,time\n"
            "for value in sys.argv[1:]:\n"
            " os.write(1,base64.b64decode(value));time.sleep(0.001)\n"
        )
        stdout = io.BytesIO()
        stderr = io.BytesIO()
        commands_module = run_evidence.commands
        with mock.patch.object(
            commands_module,
            "_collect_secret_values",
            return_value=[secret, password],
        ), mock.patch.object(
            commands_module, "_PIPE_READ_CHUNK_SIZE", 3, create=True
        ):
            return_code = run_evidence._run_command(
                self.root,
                "scenario.execute",
                "split-sanitization",
                "runner.driver_protocol",
                [sys.executable, "-c", script, *encoded],
                stdout_stream=stdout,
                stderr_stream=stderr,
            )
        self.assertEqual(return_code, 0)
        expected = run_evidence.sanitize_text(
            raw.decode("utf-8", errors="replace"),
            roots=run_evidence._sanitization_roots(self.root),
            secrets=[secret, password],
        ).encode("utf-8")
        metadata = self.command_metadata()[-1]
        stored = (self.root / metadata["stdout"]["path"]).read_bytes()
        self.assertEqual(metadata["stdout"]["originalBytes"], len(raw))
        self.assertEqual(metadata["stdout"]["sanitizedBytes"], len(expected))
        self.assertEqual(stdout.getvalue(), expected)
        self.assertEqual(stored, expected)
        stored.decode("utf-8")
        for sensitive in (secret.encode(), password.encode(), str(self.root).encode()):
            self.assertNotIn(sensitive, stored)
            self.assertNotIn(sensitive, stdout.getvalue())

    @unittest.skipUnless(
        os.name == "posix" and resource is not None and hasattr(resource, "RLIMIT_AS"),
        "requires POSIX RLIMIT_AS",
    )
    def test_combined_256_mib_output_stays_within_wrapper_address_space(self):
        chunk_size = 64 * 1024
        iterations = 2048
        bytes_per_stream = chunk_size * iterations
        address_space_headroom = 384 * 1024 * 1024
        if sys.platform == "darwin":
            current_virtual_bytes = int(
                subprocess.check_output(
                    ["ps", "-o", "vsz=", "-p", str(os.getpid())], text=True
                ).strip()
            ) * 1024
            address_space_limit = current_virtual_bytes + address_space_headroom
        else:
            address_space_limit = address_space_headroom
        script = (
            "import os,sys\n"
            "chunk=b'x'*int(sys.argv[1])\n"
            "for _ in range(int(sys.argv[2])):\n"
            " os.write(1,chunk);os.write(2,chunk)\n"
        )

        def limit_address_space():
            _soft, hard = resource.getrlimit(resource.RLIMIT_AS)
            resource.setrlimit(
                resource.RLIMIT_AS, (address_space_limit, hard)
            )

        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "command",
                "--root",
                str(self.root),
                "--phase",
                "scenario.execute",
                "--name",
                "bounded-stress",
                "--failure-code",
                "runner.driver_protocol",
                "--",
                sys.executable,
                "-c",
                script,
                str(chunk_size),
                str(iterations),
            ],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            preexec_fn=limit_address_space,
            timeout=120,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        metadata = self.command_metadata()[-1]
        for stream in ("stdout", "stderr"):
            record = metadata[stream]
            self.assertEqual(record["originalBytes"], bytes_per_stream)
            self.assertEqual(record["sanitizedBytes"], bytes_per_stream)
            self.assertTrue(record["truncated"])
            self.assertLessEqual(record["storedBytes"], 10 * 1024 * 1024)
            self.assertLessEqual(
                (self.root / record["path"]).stat().st_size, 10 * 1024 * 1024
            )
        self.assertFalse(
            any(path.suffix == ".tmp" for path in (self.root / "commands").iterdir())
        )

    def test_unknown_failure_code_is_rejected_before_command_side_effects(self):
        events_before = (self.root / "bootstrap-events.jsonl").read_bytes()
        commands_before = sorted(path.name for path in (self.root / "commands").iterdir())
        with self.assertRaises(ValueError):
            run_evidence._run_command(
                self.root,
                "scenario.execute",
                "unknown-code",
                "unknown.failure",
                [sys.executable, "-c", "pass"],
            )
        self.assertEqual(
            (self.root / "bootstrap-events.jsonl").read_bytes(), events_before
        )
        self.assertEqual(
            sorted(path.name for path in (self.root / "commands").iterdir()),
            commands_before,
        )

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
    def _external_root(self, suffix):
        context = valid_context(
            runId=f"external-{suffix}",
            executionId=f"external-execution-{suffix}",
        )
        root = self.attempt_root(context["runId"])
        run_evidence._initialize_attempt(self.index_path, root, context)
        report = root / "reports" / "run.html"
        report.parent.mkdir()
        report.write_text("<html>sanitized report</html>", encoding="utf-8")
        return root

    def test_external_metadata_json_is_bounded_before_lifecycle_mutation(self):
        root = self._external_root("metadata-bound")
        events_path = root / "bootstrap-events.jsonl"
        events_before = events_path.read_bytes()
        commands_before = sorted((root / "commands").iterdir())

        with mock.patch.object(
            run_evidence.constants, "MAX_STRUCTURED_JSON_BYTES", 1
        ), self.assertRaisesRegex(ValueError, "command metadata exceeds 1 bytes"):
            run_evidence._record_external(
                root,
                "app.build",
                "bounded-external",
                "success",
                "runner.unclassified",
                "Retry the hosted action",
            )

        self.assertEqual(events_path.read_bytes(), events_before)
        self.assertEqual(sorted((root / "commands").iterdir()), commands_before)

    def test_external_rejects_unknown_or_outcome_mismatched_codes_before_writes(self):
        cases = (
            ("failure", "unknown.failure"),
            ("failure", "run.cancelled"),
            ("cancelled", "app.assertion_failed"),
        )
        for index, (outcome, failure_code) in enumerate(cases, 1):
            context = valid_context(
                runId=f"invalid-external-{index}",
                executionId=f"invalid-execution-{index}",
            )
            root = self.attempt_root(context["runId"])
            run_evidence._initialize_attempt(self.index_path, root, context)
            events_before = (root / "bootstrap-events.jsonl").read_bytes()
            commands_before = sorted(path.name for path in (root / "commands").iterdir())
            with self.subTest(outcome=outcome, failure_code=failure_code):
                with self.assertRaises(ValueError):
                    run_evidence._record_external(
                        root,
                        "app.build",
                        "invalid-external",
                        outcome,
                        failure_code,
                        "Retry the hosted action",
                    )
                self.assertEqual(
                    (root / "bootstrap-events.jsonl").read_bytes(), events_before
                )
                self.assertEqual(
                    sorted(path.name for path in (root / "commands").iterdir()),
                    commands_before,
                )

        self.assertEqual(
            run_evidence._record_external(
                self.root,
                "app.build",
                "successful-fallback",
                "success",
                "app.assertion_failed",
                "No remediation is required",
            ),
            0,
        )

    def test_external_requires_remediation_and_sanitizes_metadata_and_logs(self):
        events_before = (self.root / "bootstrap-events.jsonl").read_bytes()
        missing = self.cli(
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
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(self.command_metadata(), [])
        self.assertEqual(
            (self.root / "bootstrap-events.jsonl").read_bytes(), events_before
        )

        secret = "external-remediation-secret"
        remediation = (
            f"Retry with {secret} after inspecting {self.root}/build and "
            f"{REPOSITORY_ROOT}/scripts and {Path.home()}/.cache and "
            "https://alice:password@example.test/job"
        )
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
            "--remediation",
            remediation,
            env={"EXTERNAL_TOKEN": secret},
        )
        self.assertEqual(result.returncode, 1)
        metadata = self.command_metadata()[0]
        self.assertEqual(metadata["source"], "github-action")
        self.assertEqual(metadata["outcome"], "failure")
        self.assertIsNone(metadata["exitStatus"])
        self.assertIsNone(metadata["signal"])
        stdout = (self.root / metadata["stdout"]["path"]).read_text(encoding="utf-8")
        stderr = (self.root / metadata["stderr"]["path"]).read_text(encoding="utf-8")
        self.assertEqual(metadata["remediation"], self.read_events(self.root)[-1]["summary"])
        self.assertIn(metadata["remediation"], stderr)
        self.assertNotIn(metadata["remediation"], stdout)
        persisted = json.dumps(metadata) + stdout + stderr
        self.assertNotIn(secret, persisted)
        self.assertNotIn("alice:password", persisted)
        self.assertNotIn(str(self.root), persisted)
        self.assertNotIn(str(REPOSITORY_ROOT), persisted)
        self.assertNotIn(str(Path.home()), persisted)
        self.assertIn("<redacted>", persisted)
        self.assertIn("${RUN_ROOT}", persisted)
        self.assertIn("${WORKSPACE}", persisted)
        self.assertIn("${HOME}", persisted)
        self.assertIn("https://example.test/job", persisted)
        self.assertIn("synthetic", stdout + stderr)
        self.assertIn("not captured", stdout + stderr)
        self.assertLessEqual(
            len(stderr.encode("utf-8")),
            run_evidence.MAX_EXTERNAL_REMEDIATION_BYTES + 256,
        )
        self.assertEqual(self.read_events(self.root)[-1]["status"], "failed")

    def test_external_remediation_is_bounded_before_any_write(self):
        self.assertEqual(run_evidence.MAX_EXTERNAL_REMEDIATION_BYTES, 4096)
        for index, remediation in enumerate(
            ("", "   ", 7, "x" * 4097, "é" * 2049),
            1,
        ):
            root = self._external_root(f"invalid-remediation-{index}")
            events_before = (root / "bootstrap-events.jsonl").read_bytes()
            commands_before = tuple((root / "commands").iterdir())
            with self.subTest(remediation=repr(remediation)):
                with self.assertRaises(ValueError):
                    run_evidence._record_external(
                        root,
                        "app.build",
                        "hosted-build",
                        "failure",
                        "infra.hosted_runner",
                        remediation,
                    )
                self.assertEqual(
                    (root / "bootstrap-events.jsonl").read_bytes(), events_before
                )
                self.assertEqual(tuple((root / "commands").iterdir()), commands_before)

        surrogate_root = self._external_root("invalid-remediation-surrogate")
        events_before = (surrogate_root / "bootstrap-events.jsonl").read_bytes()
        with self.assertRaisesRegex(ValueError, "valid UTF-8"):
            run_evidence._record_external(
                surrogate_root,
                "app.build",
                "hosted-build",
                "failure",
                "infra.hosted_runner",
                "\udcff",
            )
        self.assertEqual(
            (surrogate_root / "bootstrap-events.jsonl").read_bytes(), events_before
        )
        self.assertEqual(tuple((surrogate_root / "commands").iterdir()), ())

        for label, remediation in (
            ("ascii-exact", "x" * 4096),
            ("utf8-exact", "é" * 2048),
        ):
            root = self._external_root(label)
            with self.subTest(label=label):
                self.assertEqual(
                    len(remediation.encode("utf-8")),
                    run_evidence.MAX_EXTERNAL_REMEDIATION_BYTES,
                )
                self.assertEqual(
                    run_evidence._record_external(
                        root,
                        "app.build",
                        "hosted-build",
                        "success",
                        "infra.hosted_runner",
                        remediation,
                    ),
                    0,
                )
                self.assertEqual(
                    self.read_json(next((root / "commands").glob("*.json")))[
                        "remediation"
                    ],
                    remediation,
                )

    def test_external_success_failure_and_cancelled_are_complete_valid_records(self):
        cases = (
            ("success", "infra.hosted_runner", 0, "passed"),
            ("failure", "infra.hosted_runner", 1, "failed"),
            ("cancelled", "run.cancelled", 130, "cancelled"),
        )
        for outcome, failure_code, return_code, final_status in cases:
            root = self._external_root(outcome)
            remediation = f"Remediation for {outcome}"
            with self.subTest(outcome=outcome):
                self.assertEqual(
                    run_evidence._record_external(
                        root,
                        "app.build",
                        f"hosted-{outcome}",
                        outcome,
                        failure_code,
                        remediation,
                    ),
                    return_code,
                )
                metadata_path = next((root / "commands").glob("*.json"))
                metadata = self.read_json(metadata_path)
                self.assertEqual(metadata["remediation"], remediation)
                self.assertEqual(metadata["outcome"], outcome)
                terminal_command_event = self.read_events(root)[-1]
                self.assertEqual(terminal_command_event["status"], final_status)
                if outcome == "success":
                    self.assertNotIn("summary", terminal_command_event)
                    run_evidence._finalize_attempt(
                        root, "passed", command_status=None
                    )
                elif outcome == "failure":
                    self.assertEqual(terminal_command_event["summary"], remediation)
                    run_evidence._finalize_attempt(
                        root,
                        "failed",
                        phase="app.build",
                        error_code=failure_code,
                        summary_text=remediation,
                        hint="Retry the hosted action",
                        command_status=None,
                    )
                else:
                    self.assertEqual(terminal_command_event["summary"], remediation)
                    run_evidence._finalize_attempt(
                        root,
                        "cancelled",
                        summary_text=remediation,
                        hint="Retry the hosted action",
                        command_status=None,
                    )
                self.assertEqual(run_evidence.validate_bundle(root, secrets=[]), [])
