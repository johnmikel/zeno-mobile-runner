import os
import shutil
import sys
import unittest


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))

from zmr_client import ZmrClient, ZmrRpcError  # noqa: E402


class PythonClientTest(unittest.TestCase):
    def test_drives_stdio_json_rpc_session(self):
        node = shutil.which("node")
        self.assertIsNotNone(node)
        client = ZmrClient(
            node,
            [os.path.join(ROOT, "tests", "fake-json-rpc-server.mjs")],
        )
        try:
            capabilities = client.capabilities()
            self.assertEqual(capabilities["protocolVersion"], "2026-04-28")
            self.assertIn("observe.snapshot", capabilities["methods"])
            self.assertIn("assert.healthy", capabilities["methods"])
            self.assertIn("scenario.validate", capabilities["methods"])
            self.assertIn("trace.explain", capabilities["methods"])
            self.assertIn("trace.explore", capabilities["methods"])
            self.assertIn("trace.discover", capabilities["methods"])
            self.assertFalse(capabilities["iosPreview"])
            self.assertEqual(capabilities["platformSupport"]["ios"]["status"], "supported")
            self.assertEqual(capabilities["platformSupport"]["ios"]["deviceTypes"], ["simulator", "physical"])
            self.assertTrue(capabilities["platformSupport"]["ios"]["physicalDevices"])

            session = client.create_session()
            self.assertEqual(session["sessionId"], "default")

            devices = client.devices()
            self.assertEqual(devices[0], {"serial": "fake-device-1", "state": "device", "ready": True})
            self.assertEqual(devices[1], {"serial": "fake-ios-disconnected", "state": "disconnected", "ready": False})

            self.assertTrue(client.open_link("exampleapp://python-client"))
            self.assertTrue(client.wait_until({"text": "Home"}, timeout_ms=1000))
            self.assertTrue(client.assert_healthy(timeout_ms=1000))

            snapshot = client.snapshot()
            self.assertEqual(snapshot["activePackage"], "com.example.mobiletest")
            self.assertEqual(snapshot["nodes"][0]["text"], "Home")

            semantic_snapshot = client.semantic_snapshot()
            self.assertEqual(semantic_snapshot["nodes"][0]["role"], "button")
            self.assertEqual(semantic_snapshot["nodes"][0]["recommendedAction"], "tap")

            exported = client.export_trace("traces/python-client.zmrtrace", redact=True, omit_screenshots=True)
            self.assertTrue(exported["redacted"])
            self.assertTrue(exported["omitScreenshots"])

            events = client.trace_events(0, limit=10)
            self.assertEqual(events["nextSeq"], 2)
            self.assertEqual(events["events"][0]["kind"], "rpc.request")

            explanation = client.explain_trace()
            self.assertEqual(explanation["traceDir"], "traces/client")
            self.assertEqual(explanation["scenario"], "client session")
            self.assertEqual(explanation["status"], "failed")
            self.assertEqual(explanation["error"], "WaitTimeout")
            self.assertEqual(explanation["diagnostic"]["kind"], "wait.visible")
            self.assertEqual(explanation["diagnostic"]["visibleTexts"], ["Home", "Retry"])
            self.assertIn("zmr explain traces/client --json", explanation["nextCommands"])

            discovered = client.discover_trace(
                ".zmr/discovered/python-client.json",
                include_actions=True,
                validate=True,
                force=True,
                name="Python discovery",
            )
            self.assertEqual(discovered["mode"], "discover")
            self.assertEqual(discovered["out"], ".zmr/discovered/python-client.json")
            self.assertTrue(discovered["validated"])

            explored = client.explore_trace(
                ".zmr/discovered/python-client-explore.json",
                "find python client smoke",
                include_actions=True,
                validate=True,
                force=True,
                name="Python exploration",
            )
            self.assertEqual(explored["mode"], "explore")
            self.assertEqual(explored["goal"], "find python client smoke")
            self.assertEqual(explored["out"], ".zmr/discovered/python-client-explore.json")
            self.assertTrue(explored["reviewRequired"])
            self.assertFalse(explored["autonomous"])
            self.assertIn("requires human review before commit", explored["guardrails"])

            validation = client.validate_scenario(".zmr/discovered/python-client.json")
            self.assertTrue(validation["ok"])
            self.assertEqual(validation["name"], "Python discovery")
        finally:
            client.close()

    def test_raises_json_rpc_errors_with_details(self):
        node = shutil.which("node")
        self.assertIsNotNone(node)
        client = ZmrClient(
            node,
            [os.path.join(ROOT, "tests", "fake-json-rpc-server.mjs")],
        )
        try:
            with self.assertRaises(ZmrRpcError) as caught:
                client.request("missing.method", {})
            self.assertEqual(caught.exception.code, -32601)
            self.assertEqual(str(caught.exception), "method not found")
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
