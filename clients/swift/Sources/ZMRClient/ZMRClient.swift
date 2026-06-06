import Foundation

public enum ZMRError: Error {
    case processNotStarted
    case invalidResponse
    case rpcError([String: Any])
}

public struct TraceDiscoverOptions {
    public var includeActions: Bool
    public var validate: Bool
    public var force: Bool
    public var name: String?
    public var appId: String?

    public init(
        includeActions: Bool = false,
        validate: Bool = false,
        force: Bool = false,
        name: String? = nil,
        appId: String? = nil
    ) {
        self.includeActions = includeActions
        self.validate = validate
        self.force = force
        self.name = name
        self.appId = appId
    }
}

public final class ZMRClient {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var nextID = 1

    public init(executable: String = "zmr", arguments: [String] = ["serve", "--transport", "stdio"]) {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdoutPipe.fileHandleForReading
    }

    public func start() throws {
        try process.run()
    }

    public func close() {
        _ = try? call("session.close")
        input.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }

    @discardableResult
    public func call(_ method: String, params: [String: Any]? = nil) throws -> Any {
        guard process.isRunning else { throw ZMRError.processNotStarted }
        let id = nextID
        nextID += 1

        var request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params {
            request["params"] = params
        }
        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        input.write(data)
        input.write(Data([0x0a]))

        let line = try readLineData()
        let object = try JSONSerialization.jsonObject(with: line, options: [])
        guard let response = object as? [String: Any] else { throw ZMRError.invalidResponse }
        if let error = response["error"] as? [String: Any] {
            throw ZMRError.rpcError(error)
        }
        guard let result = response["result"] else { throw ZMRError.invalidResponse }
        return result
    }

    public func createSession() throws {
        _ = try call("session.create")
    }

    public func snapshot() throws -> [String: Any] {
        guard let result = try call("observe.snapshot") as? [String: Any] else {
            throw ZMRError.invalidResponse
        }
        return result
    }

    public func semanticSnapshot() throws -> [String: Any] {
        guard let result = try call("observe.semanticSnapshot") as? [String: Any] else {
            throw ZMRError.invalidResponse
        }
        return result
    }

    public func assertHealthy(timeoutMs: Int? = nil) throws -> Bool {
        var params: [String: Any] = [:]
        if let timeoutMs {
            params["timeoutMs"] = timeoutMs
        }
        guard let result = try call("assert.healthy", params: params) as? Bool else {
            throw ZMRError.invalidResponse
        }
        return result
    }

    public func validateScenario(path: String) throws -> [String: Any] {
        guard let result = try call("scenario.validate", params: ["path": path]) as? [String: Any] else {
            throw ZMRError.invalidResponse
        }
        return result
    }

    public func discoverTrace(out: String, options: TraceDiscoverOptions = TraceDiscoverOptions()) throws -> [String: Any] {
        var params: [String: Any] = ["out": out]
        if options.includeActions {
            params["includeActions"] = true
        }
        if options.validate {
            params["validate"] = true
        }
        if options.force {
            params["force"] = true
        }
        if let name = options.name {
            params["name"] = name
        }
        if let appId = options.appId {
            params["appId"] = appId
        }
        guard let result = try call("trace.discover", params: params) as? [String: Any] else {
            throw ZMRError.invalidResponse
        }
        return result
    }

    public func explainTrace() throws -> [String: Any] {
        guard let result = try call("trace.explain", params: [:]) as? [String: Any] else {
            throw ZMRError.invalidResponse
        }
        return result
    }

    private func readLineData() throws -> Data {
        var data = Data()
        while true {
            let byte = output.readData(ofLength: 1)
            if byte.isEmpty {
                throw ZMRError.invalidResponse
            }
            if byte[0] == 0x0a {
                return data
            }
            data.append(byte)
        }
    }
}
