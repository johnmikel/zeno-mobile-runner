import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import url from "node:url";

const root = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "..");

test("typescript reference client drives a stdio JSON-RPC session", async () => {
  const clientModule = await import(url.pathToFileURL(path.join(root, "clients", "typescript", "index.mjs")));
  const client = clientModule.createZmrClient({
    command: process.execPath,
    args: [path.join(root, "tests", "fake-json-rpc-server.mjs")],
  });

  try {
    const capabilities = await client.capabilities();
    assert.equal(capabilities.protocolVersion, "2026-04-28");
    assert.ok(capabilities.methods.includes("observe.snapshot"));
    assert.ok(capabilities.methods.includes("assert.healthy"));
    assert.ok(capabilities.methods.includes("scenario.validate"));
    assert.ok(capabilities.methods.includes("trace.discover"));
    assert.equal(capabilities.iosPreview, false);
    assert.equal(capabilities.platformSupport.ios.status, "supported");
    assert.deepEqual(capabilities.platformSupport.ios.deviceTypes, ["simulator", "physical"]);
    assert.equal(capabilities.platformSupport.ios.physicalDevices, true);

    const session = await client.createSession();
    assert.equal(session.sessionId, "default");

    const devices = await client.devices();
    assert.deepEqual(devices, [
      { serial: "fake-device-1", state: "device", ready: true },
      { serial: "fake-ios-disconnected", state: "disconnected", ready: false },
    ]);

    assert.equal(await client.openLink("exampleapp://client"), true);
    assert.equal(await client.waitUntil({ text: "Home" }, { timeoutMs: 1000 }), true);
    assert.equal(await client.assertHealthy({ timeoutMs: 1000 }), true);

    const snapshot = await client.snapshot();
    assert.equal(snapshot.activePackage, "com.example.mobiletest");
    assert.equal(snapshot.nodes[0].text, "Home");

    const semanticSnapshot = await client.semanticSnapshot();
    assert.equal(semanticSnapshot.nodes[0].role, "button");
    assert.equal(semanticSnapshot.nodes[0].recommendedAction, "tap");

    const exported = await client.exportTrace("traces/client.zmrtrace", { redact: true, omitScreenshots: true });
    assert.equal(exported.redacted, true);
    assert.equal(exported.omitScreenshots, true);

    const events = await client.traceEvents(0, { limit: 10 });
    assert.equal(events.nextSeq, 2);
    assert.equal(events.events[0].kind, "rpc.request");

    const discovered = await client.discoverTrace(".zmr/discovered/client.json", {
      includeActions: true,
      validate: true,
      force: true,
      name: "Client discovery",
    });
    assert.equal(discovered.mode, "discover");
    assert.equal(discovered.out, ".zmr/discovered/client.json");
    assert.equal(discovered.validated, true);

    const validation = await client.validateScenario(".zmr/discovered/client.json");
    assert.equal(validation.ok, true);
    assert.equal(validation.name, "Client discovery");
  } finally {
    await client.close();
  }
});

test("typescript reference client rejects JSON-RPC errors with public details", async () => {
  const clientModule = await import(url.pathToFileURL(path.join(root, "clients", "typescript", "index.mjs")));
  const client = clientModule.createZmrClient({
    command: process.execPath,
    args: [path.join(root, "tests", "fake-json-rpc-server.mjs")],
  });

  try {
    await assert.rejects(
      () => client.request("missing.method", {}),
      (error) => {
        assert.equal(error.code, -32601);
        assert.equal(error.message, "method not found");
        return true;
      },
    );
  } finally {
    await client.close();
  }
});
