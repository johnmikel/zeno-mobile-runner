import XCTest
@testable import ZMRClient

final class ZMRClientTests: XCTestCase {
    func testDrivesFakeJsonRpcSession() throws {
        let root = repoRoot()
        let server = root.appendingPathComponent("tests/fake-json-rpc-server.mjs").path
        let client = ZMRClient(executable: "node", arguments: [server])
        try client.start()
        defer { client.close() }

        guard let capabilities = try client.call("runner.capabilities") as? [String: Any] else {
            return XCTFail("capabilities response was not an object")
        }
        XCTAssertEqual(capabilities["protocolVersion"] as? String, "2026-04-28")
        let methods = capabilities["methods"] as? [String]
        XCTAssertEqual(methods?.contains("assert.healthy"), true)
        XCTAssertEqual(methods?.contains("trace.explain"), true)

        XCTAssertEqual(try client.assertHealthy(timeoutMs: 1000), true)
        let snapshot = try client.snapshot()
        XCTAssertEqual(snapshot["activePackage"] as? String, "com.example.mobiletest")

        let discovered = try client.discoverTrace(
            out: ".zmr/discovered/swift-client.json",
            options: TraceDiscoverOptions(
                includeActions: true,
                validate: true,
                force: true,
                name: "Swift discovery",
                appId: "com.example.swift"
            )
        )
        XCTAssertEqual(discovered["ok"] as? Bool, true)
        XCTAssertEqual(discovered["mode"] as? String, "discover")
        XCTAssertEqual(discovered["out"] as? String, ".zmr/discovered/swift-client.json")
        XCTAssertEqual(discovered["appId"] as? String, "com.example.swift")
        XCTAssertEqual(discovered["validated"] as? Bool, true)
        let replay = discovered["replay"] as? [String: Any]
        XCTAssertEqual(replay?["stepCount"] as? Int, 1)
        let discoveredValidation = discovered["validation"] as? [String: Any]
        XCTAssertEqual(discoveredValidation?["ok"] as? Bool, true)

        let explored = try client.exploreTrace(
            out: ".zmr/discovered/swift-client-explore.json",
            goal: "find swift client smoke",
            options: TraceDiscoverOptions(
                includeActions: true,
                validate: true,
                force: true,
                name: "Swift exploration",
                appId: "com.example.swift"
            )
        )
        XCTAssertEqual(explored["ok"] as? Bool, true)
        XCTAssertEqual(explored["mode"] as? String, "explore")
        XCTAssertEqual(explored["goal"] as? String, "find swift client smoke")
        XCTAssertEqual(explored["out"] as? String, ".zmr/discovered/swift-client-explore.json")
        XCTAssertEqual(explored["reviewRequired"] as? Bool, true)
        XCTAssertEqual(explored["autonomous"] as? Bool, false)
        XCTAssertTrue((explored["guardrails"] as? [String])?.contains("requires human review before commit") == true)

        let explanation = try client.explainTrace()
        XCTAssertEqual(explanation["traceDir"] as? String, "traces/client")
        XCTAssertEqual(explanation["scenario"] as? String, "client session")
        XCTAssertEqual(explanation["status"] as? String, "failed")
        XCTAssertEqual(explanation["error"] as? String, "WaitTimeout")
        let diagnostic = explanation["diagnostic"] as? [String: Any]
        XCTAssertEqual(diagnostic?["kind"] as? String, "wait.visible")
        XCTAssertEqual(diagnostic?["visibleTexts"] as? [String], ["Home", "Retry"])
        XCTAssertTrue((explanation["nextCommands"] as? [String])?.contains("zmr explain traces/client --json") == true)

        let validation = try client.validateScenario(path: ".zmr/discovered/swift-client.json")
        XCTAssertEqual(validation["ok"] as? Bool, true)
        XCTAssertEqual(validation["path"] as? String, ".zmr/discovered/swift-client.json")
        XCTAssertEqual(validation["stepCount"] as? Int, 4)
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
