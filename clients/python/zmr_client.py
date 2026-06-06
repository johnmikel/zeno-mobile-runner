import json
import subprocess
import threading


class ZmrRpcError(RuntimeError):
    def __init__(self, error):
        super().__init__(error.get("message", "ZMR JSON-RPC error"))
        self.code = error.get("code")
        self.public_code = error.get("publicCode")
        self.data = error.get("data")


class ZmrClient:
    def __init__(self, command, args=None, cwd=None, env=None, stderr=None):
        self._process = subprocess.Popen(
            [command, *(args or [])],
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._next_id = 1
        self._lock = threading.Lock()
        self._closed = False

    def request(self, method, params=None):
        with self._lock:
            if self._closed:
                raise RuntimeError("zmr client is closed")
            request_id = self._next_id
            self._next_id += 1
            line = json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": method,
                    "params": params or {},
                },
                separators=(",", ":"),
            )
            self._process.stdin.write(line + "\n")
            self._process.stdin.flush()

            response_line = self._process.stdout.readline()
            if response_line == "":
                code = self._process.poll()
                raise RuntimeError(f"zmr process exited with {code}")
            response = json.loads(response_line)
            if response.get("id") != request_id:
                raise RuntimeError(f"unexpected JSON-RPC response id {response.get('id')!r}")
            if "error" in response:
                raise ZmrRpcError(response["error"])
            return response.get("result")

    def capabilities(self):
        return self.request("runner.capabilities")

    def create_session(self):
        return self.request("session.create")

    def close_session(self):
        return self.request("session.close")

    def devices(self):
        return self.request("device.list")

    def launch(self):
        return self.request("app.launch")

    def stop(self):
        return self.request("app.stop")

    def clear_state(self):
        return self.request("app.clearState")

    def open_link(self, url):
        return self.request("app.openLink", {"url": url})

    def snapshot(self):
        return self.request("observe.snapshot")

    def semantic_snapshot(self):
        return self.request("observe.semanticSnapshot")

    def tap(self, selector):
        return self.request("ui.tap", {"selector": selector})

    def type_text(self, text, selector=None):
        params = {"text": text}
        if selector is not None:
            params["selector"] = selector
        return self.request("ui.type", params)

    def erase_text(self, selector=None, max_chars=None):
        params = {}
        if selector is not None:
            params["selector"] = selector
        if max_chars is not None:
            params["maxChars"] = max_chars
        return self.request("ui.eraseText", params)

    def hide_keyboard(self):
        return self.request("ui.hideKeyboard")

    def swipe(self, x1, y1, x2, y2, duration_ms=None):
        params = {"x1": x1, "y1": y1, "x2": x2, "y2": y2}
        if duration_ms is not None:
            params["durationMs"] = duration_ms
        return self.request("ui.swipe", params)

    def press_back(self):
        return self.request("ui.pressBack")

    def scroll_until_visible(self, selector, direction=None, timeout_ms=None):
        params = {"selector": selector}
        if direction is not None:
            params["direction"] = direction
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        return self.request("ui.scrollUntilVisible", params)

    def wait_until(self, selector, timeout_ms=None):
        params = {"visible": selector}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        return self.request("wait.until", params)

    def wait_any(self, selectors, timeout_ms=None):
        params = {"selectors": selectors}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        return self.request("wait.any", params)

    def wait_gone(self, selector, timeout_ms=None):
        params = {"selector": selector}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        return self.request("wait.gone", params)

    def assert_visible(self, selector, timeout_ms=None):
        params = {"selector": selector}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        return self.request("assert.visible", params)

    def assert_not_visible(self, selector, timeout_ms=None):
        params = {"selector": selector}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        return self.request("assert.notVisible", params)

    def assert_healthy(self, timeout_ms=None):
        params = {}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        return self.request("assert.healthy", params)

    def export_trace(self, out, redact=False, omit_screenshots=False):
        return self.request(
            "trace.export",
            {
                "out": out,
                "redact": redact,
                "omitScreenshots": omit_screenshots,
            },
        )

    def trace_events(self, after_seq=0, limit=None):
        params = {"afterSeq": after_seq}
        if limit is not None:
            params["limit"] = limit
        return self.request("trace.events", params)

    def discover_trace(self, out, include_actions=False, validate=False, force=False, name=None, app_id=None):
        params = {
            "out": out,
            "includeActions": include_actions,
            "validate": validate,
            "force": force,
        }
        if name is not None:
            params["name"] = name
        if app_id is not None:
            params["appId"] = app_id
        return self.request("trace.discover", params)

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._process.stdin:
            self._process.stdin.close()
        if self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=2)
        if self._process.stdout:
            self._process.stdout.close()
        if self._process.stderr:
            self._process.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        self.close()
        return False
