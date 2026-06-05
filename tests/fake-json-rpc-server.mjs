#!/usr/bin/env node
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin });

rl.on("line", (line) => {
  if (!line.trim()) return;
  const request = JSON.parse(line);
  const method = request.method;
  let result;
  if (method === "runner.capabilities") {
    result = {
      name: "zmr",
      version: "0.1.4",
      protocolVersion: "2026-04-28",
      protocol: {
        version: "2026-04-28",
        minimumCompatibleVersion: "2026-04-28",
        stability: "dev-preview",
        breakingChangePolicy: "version-and-changelog",
      },
      platforms: ["android", "ios"],
      platformSupport: {
        android: { status: "supported", deviceTypes: ["emulator", "physical"], automation: ["adb", "uiautomator", "android-shim"] },
        ios: { status: "supported", deviceTypes: ["simulator", "physical"], automation: ["simctl", "devicectl", "xctest-shim"], physicalDevices: true },
      },
      iosPreview: false,
      transports: ["stdio", "tcp"],
      methods: [
        "runner.capabilities",
        "device.list",
        "session.create",
        "session.close",
        "app.launch",
        "app.stop",
        "app.openLink",
        "app.clearState",
        "observe.snapshot",
        "observe.semanticSnapshot",
        "ui.tap",
        "ui.type",
        "ui.eraseText",
        "ui.hideKeyboard",
        "ui.swipe",
        "ui.pressBack",
        "ui.scrollUntilVisible",
        "wait.until",
        "wait.any",
        "wait.gone",
        "assert.visible",
        "assert.notVisible",
        "assert.healthy",
        "trace.events",
        "trace.export",
      ],
    };
  } else if (method === "device.list") {
    result = [
      { serial: "fake-device-1", state: "device", ready: true },
      { serial: "fake-ios-disconnected", state: "disconnected", ready: false },
    ];
  } else if (method === "session.create") {
    result = { sessionId: "default" };
  } else if (method === "session.close") {
    result = true;
  } else if (method === "app.launch") {
    result = true;
  } else if (method === "app.stop") {
    result = true;
  } else if (method === "app.openLink") {
    result = true;
  } else if (method === "app.clearState") {
    result = true;
  } else if (method === "ui.tap") {
    result = true;
  } else if (method === "ui.type") {
    result = true;
  } else if (method === "ui.eraseText") {
    result = true;
  } else if (method === "ui.hideKeyboard") {
    result = true;
  } else if (method === "ui.swipe") {
    result = true;
  } else if (method === "ui.pressBack") {
    result = true;
  } else if (method === "ui.scrollUntilVisible") {
    result = true;
  } else if (method === "wait.until") {
    result = true;
  } else if (method === "wait.any") {
    result = true;
  } else if (method === "wait.gone") {
    result = true;
  } else if (method === "assert.visible") {
    result = true;
  } else if (method === "assert.notVisible") {
    result = true;
  } else if (method === "assert.healthy") {
    result = true;
  } else if (method === "observe.snapshot") {
    result = {
      id: "snapshot-1",
      timestampMs: 1,
      viewport: { width: 720, height: 1280 },
      activePackage: "com.example.mobiletest",
      activeActivity: ".MainActivity",
      nodes: [{ stableId: "title", className: "Text", text: "Home", bounds: { x: 0, y: 0, width: 100, height: 44 }, enabled: true, visible: true, selected: false }],
    };
  } else if (method === "observe.semanticSnapshot") {
    result = {
      id: "snapshot-1",
      timestampMs: 1,
      viewport: { width: 720, height: 1280 },
      activePackage: "com.example.mobiletest",
      activeActivity: ".MainActivity",
      focusedNodeId: null,
      nodes: [
        {
          id: "title",
          role: "button",
          name: "Home",
          selector: { text: "Home" },
          source: { className: "Button", resourceId: null, text: "Home", contentDesc: null },
          bounds: { x: 0, y: 0, width: 100, height: 44, centerX: 50, centerY: 22 },
          enabled: true,
          visible: true,
          selected: false,
          interactive: true,
          recommendedAction: "tap",
        },
      ],
      summary: { nodeCount: 1, interactiveCount: 1, visibleText: ["Home"] },
    };
  } else if (method === "trace.export") {
    result = {
      traceDir: "traces/client",
      out: request.params?.out ?? "traces/client.zmrtrace",
      redacted: Boolean(request.params?.redact || request.params?.omitScreenshots),
      omitScreenshots: Boolean(request.params?.omitScreenshots),
    };
  } else if (method === "trace.events") {
    result = {
      traceDir: "traces/client",
      afterSeq: request.params?.afterSeq ?? 0,
      nextSeq: 2,
      latestSeq: 2,
      events: [
        { seq: 1, timestampMs: 1, kind: "rpc.request", payload: { method: "session.create", id: 1 } },
        { seq: 2, timestampMs: 2, kind: "rpc.response", payload: { method: "session.create", id: 1 } },
      ],
    };
  } else {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, error: { code: -32601, message: "method not found" } }) + "\n");
    return;
  }

  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, result }) + "\n");
});
