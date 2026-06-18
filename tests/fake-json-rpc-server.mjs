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
      version: "0.2.10",
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
        "scenario.validate",
        "trace.events",
        "trace.explain",
        "trace.explore",
        "trace.discover",
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
  } else if (method === "trace.explain") {
    result = {
      ok: true,
      traceDir: "traces/client",
      scenario: "client session",
      status: "failed",
      appId: "com.example.mobiletest",
      durationMs: 100,
      eventCount: 4,
      snapshotCount: 1,
      failedStepIndex: 2,
      error: "WaitTimeout",
      diagnostic: {
        kind: "wait.visible",
        status: "timeout",
        snapshotId: "snapshot-7",
        visibleTexts: ["Home", "Retry"],
      },
      lastEvent: "scenario.end",
      nextCommands: [
        "zmr report traces/client --out traces/client/report.html --junit traces/client/junit.xml",
        "zmr explain traces/client --json",
        "zmr export traces/client --out traces/client.zmrtrace --redact",
      ],
    };
  } else if (method === "trace.discover") {
    result = {
      ok: true,
      mode: "discover",
      schemaVersion: 1,
      runnerVersion: "0.2.10",
      protocolVersion: "2026-04-28",
      out: request.params?.out ?? ".zmr/discovered/client.json",
      traceDir: "traces/client",
      sourceSnapshot: "traces/client/artifacts/snapshot-1.json",
      name: request.params?.name ?? "Client discovery",
      appId: request.params?.appId ?? "com.example.mobiletest",
      selectorCount: 1,
      stepCount: 4,
      replay: { enabled: Boolean(request.params?.includeActions), eventCount: 2, stepCount: request.params?.includeActions ? 1 : 0, skippedEventCount: request.params?.includeActions ? 1 : 0 },
      warnings: ["draft requires human review before commit"],
      validated: Boolean(request.params?.validate),
      validation: request.params?.validate ? { ok: true, path: request.params?.out ?? ".zmr/discovered/client.json", name: request.params?.name ?? "Client discovery", appId: request.params?.appId ?? "com.example.mobiletest", stepCount: 4 } : null,
      nextCommands: [
        `zmr validate --json ${request.params?.out ?? ".zmr/discovered/client.json"}`,
        `zmr run ${request.params?.out ?? ".zmr/discovered/client.json"} --json --trace-dir traces/client`,
      ],
    };
  } else if (method === "trace.explore") {
    result = {
      ok: true,
      mode: "explore",
      schemaVersion: 1,
      runnerVersion: "0.2.10",
      protocolVersion: "2026-04-28",
      out: request.params?.out ?? ".zmr/discovered/client-explore.json",
      traceDir: "traces/client",
      sourceSnapshot: "traces/client/artifacts/snapshot-1.json",
      name: request.params?.name ?? "Client exploration",
      appId: request.params?.appId ?? "com.example.mobiletest",
      selectorCount: 1,
      stepCount: 4,
      replay: { enabled: Boolean(request.params?.includeActions), eventCount: 2, stepCount: request.params?.includeActions ? 1 : 0, skippedEventCount: request.params?.includeActions ? 1 : 0 },
      warnings: ["draft requires human review before commit"],
      validated: Boolean(request.params?.validate),
      validation: request.params?.validate ? { ok: true, path: request.params?.out ?? ".zmr/discovered/client-explore.json", name: request.params?.name ?? "Client exploration", appId: request.params?.appId ?? "com.example.mobiletest", stepCount: 4 } : null,
      nextCommands: [
        `zmr validate --json ${request.params?.out ?? ".zmr/discovered/client-explore.json"}`,
        `zmr run ${request.params?.out ?? ".zmr/discovered/client-explore.json"} --json --trace-dir traces/client`,
      ],
      goal: request.params?.goal ?? null,
      autonomous: false,
      reviewRequired: true,
      guardrails: [
        "writes from existing trace evidence only",
        "does not crawl the app",
        "does not discover credentials or secrets",
        "requires human review before commit",
      ],
    };
  } else if (method === "scenario.validate") {
    result = {
      ok: true,
      path: request.params?.path ?? ".zmr/discovered/client.json",
      name: request.params?.path?.includes("python") ? "Python discovery" : "Client discovery",
      appId: "com.example.mobiletest",
      stepCount: 4,
      nextCommands: [`zmr run ${request.params?.path ?? ".zmr/discovered/client.json"} --json --trace-dir traces/zmr-run`],
    };
  } else {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, error: { code: -32601, message: "method not found" } }) + "\n");
    return;
  }

  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, result }) + "\n");
});
