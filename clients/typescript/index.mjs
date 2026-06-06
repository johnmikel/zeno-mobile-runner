import { spawn } from "node:child_process";
import readline from "node:readline";

export class ZmrRpcError extends Error {
  constructor(error) {
    super(error?.message || "ZMR JSON-RPC error");
    this.name = "ZmrRpcError";
    this.code = error?.code;
    this.publicCode = error?.publicCode;
    this.data = error?.data;
  }
}

export function createZmrClient(options) {
  return new ZmrClient(options);
}

export class ZmrClient {
  #child;
  #nextId = 1;
  #pending = new Map();
  #closed = false;

  constructor(options) {
    if (!options?.command) throw new Error("createZmrClient requires command");
    this.#child = spawn(options.command, options.args ?? [], {
      cwd: options.cwd,
      env: options.env,
      stdio: ["pipe", "pipe", options.stderr ?? "inherit"],
    });

    const lines = readline.createInterface({ input: this.#child.stdout });
    lines.on("line", (line) => this.#handleLine(line));
    this.#child.on("error", (error) => this.#rejectAll(error));
    this.#child.on("exit", (code, signal) => {
      this.#closed = true;
      if (this.#pending.size > 0) {
        this.#rejectAll(new Error(`zmr process exited with ${signal ?? code}`));
      }
    });
  }

  request(method, params = {}) {
    if (this.#closed) return Promise.reject(new Error("zmr client is closed"));
    const id = this.#nextId++;
    const message = { jsonrpc: "2.0", id, method, params };
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject });
      this.#child.stdin.write(`${JSON.stringify(message)}\n`, (error) => {
        if (!error) return;
        this.#pending.delete(id);
        reject(error);
      });
    });
  }

  capabilities() {
    return this.request("runner.capabilities", {});
  }

  createSession() {
    return this.request("session.create", {});
  }

  closeSession() {
    return this.request("session.close", {});
  }

  devices() {
    return this.request("device.list", {});
  }

  launch() {
    return this.request("app.launch", {});
  }

  stop() {
    return this.request("app.stop", {});
  }

  clearState() {
    return this.request("app.clearState", {});
  }

  openLink(url) {
    return this.request("app.openLink", { url });
  }

  snapshot() {
    return this.request("observe.snapshot", {});
  }

  semanticSnapshot() {
    return this.request("observe.semanticSnapshot", {});
  }

  tap(selector) {
    return this.request("ui.tap", { selector });
  }

  typeText(text, options = {}) {
    return this.request("ui.type", { ...options, text });
  }

  eraseText(options = {}) {
    return this.request("ui.eraseText", options);
  }

  hideKeyboard() {
    return this.request("ui.hideKeyboard", {});
  }

  swipe(input) {
    return this.request("ui.swipe", input);
  }

  pressBack() {
    return this.request("ui.pressBack", {});
  }

  scrollUntilVisible(selector, options = {}) {
    return this.request("ui.scrollUntilVisible", { selector, ...options });
  }

  waitUntil(selector, options = {}) {
    return this.request("wait.until", { visible: selector, ...options });
  }

  waitAny(selectors, options = {}) {
    return this.request("wait.any", { selectors, ...options });
  }

  waitGone(selector, options = {}) {
    return this.request("wait.gone", { selector, ...options });
  }

  assertVisible(selector, options = {}) {
    return this.request("assert.visible", { selector, ...options });
  }

  assertNotVisible(selector, options = {}) {
    return this.request("assert.notVisible", { selector, ...options });
  }

  assertHealthy(options = {}) {
    return this.request("assert.healthy", options);
  }

  validateScenario(path) {
    return this.request("scenario.validate", { path });
  }

  exportTrace(out, options = {}) {
    return this.request("trace.export", { out, ...options });
  }

  traceEvents(afterSeq = 0, options = {}) {
    return this.request("trace.events", { afterSeq, ...options });
  }

  explainTrace() {
    return this.request("trace.explain", {});
  }

  discoverTrace(out, options = {}) {
    return this.request("trace.discover", { out, ...options });
  }

  exploreTrace(out, goal, options = {}) {
    return this.request("trace.explore", { out, goal, ...options });
  }

  async close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#child.stdin.end();
    if (this.#child.exitCode == null && this.#child.signalCode == null) {
      this.#child.kill();
    }
  }

  #handleLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      this.#rejectAll(error);
      return;
    }

    const pending = this.#pending.get(message.id);
    if (!pending) return;
    this.#pending.delete(message.id);
    if (message.error) {
      pending.reject(new ZmrRpcError(message.error));
    } else {
      pending.resolve(message.result);
    }
  }

  #rejectAll(error) {
    for (const pending of this.#pending.values()) {
      pending.reject(error);
    }
    this.#pending.clear();
  }
}
