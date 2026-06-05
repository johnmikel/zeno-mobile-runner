import Foundation
import XCTest

final class ZMRShimUITestCase: XCTestCase {
    func testRunZMRCommand() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = makeApplication(bundleIdentifier: shimRuntimeValue("ZMR_APP_BUNDLE_ID", environment: environment))

        if shimRuntimeValue("ZMR_SHIM_MODE", environment: environment) == "server" {
            guard let serverDir = shimRuntimeValue("ZMR_SHIM_SERVER_DIR", environment: environment) else {
                throw ZMRShimError.missingEnvironment
            }
            try runServer(serverDir: serverDir, app: app)
            return
        }

        guard let requestFile = shimRuntimeValue("ZMR_SHIM_REQUEST_FILE", environment: environment),
              let responseFile = shimRuntimeValue("ZMR_SHIM_RESPONSE_FILE", environment: environment) else {
            throw ZMRShimError.missingEnvironment
        }

        try process(requestAt: requestFile, responseAt: responseFile, app: app)
    }

    private func runServer(serverDir: String, app: XCUIApplication) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: serverDir, withIntermediateDirectories: true)

        let readyFile = path(in: serverDir, named: "ready")
        let stopFile = path(in: serverDir, named: "stop")
        _ = fileManager.createFile(atPath: readyFile, contents: Data(), attributes: nil)

        var idleDeadline = Date().addingTimeInterval(900)
        while Date() < idleDeadline {
            if fileManager.fileExists(atPath: stopFile) {
                break
            }

            let requestNames = try fileManager.contentsOfDirectory(atPath: serverDir)
                .filter { $0.hasPrefix("request-") && $0.hasSuffix(".json") }
                .sorted()

            if requestNames.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            for requestName in requestNames {
                let requestID = requestName
                    .dropFirst("request-".count)
                    .dropLast(".json".count)
                let requestFile = path(in: serverDir, named: requestName)
                let responseFile = path(in: serverDir, named: "response-\(requestID).json")

                try process(requestAt: requestFile, responseAt: responseFile, app: app)
                try? fileManager.removeItem(atPath: requestFile)
                idleDeadline = Date().addingTimeInterval(900)
            }
        }
    }

    private func process(requestAt requestFile: String, responseAt responseFile: String, app: XCUIApplication) throws {
        let response = responseFor(requestAt: requestFile, app: app)
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let responseURL = URL(fileURLWithPath: responseFile)
        let temporaryURL = URL(fileURLWithPath: "\(responseFile).tmp")
        try responseData.write(to: temporaryURL, options: [.atomic])
        if FileManager.default.fileExists(atPath: responseFile) {
            try FileManager.default.removeItem(at: responseURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: responseURL)
    }

    private func responseFor(requestAt requestFile: String, app: XCUIApplication) -> [String: Any] {
        do {
            let requestData = try Data(contentsOf: URL(fileURLWithPath: requestFile))
            let command = try JSONDecoder().decode(ZMRShimCommand.self, from: requestData)
            return run(command: command, app: app)
        } catch {
            return self.error("invalid.request", "\(error)")
        }
    }

    private func path(in directory: String, named name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    private func shimRuntimeValue(_ key: String, environment: [String: String]) -> String? {
        if let value = environment[key], !value.isEmpty, !value.hasPrefix("$(") {
            return value
        }
        if let value = Bundle(for: Self.self).object(forInfoDictionaryKey: key) as? String,
           !value.isEmpty,
           !value.hasPrefix("$(") {
            return value
        }
        return nil
    }

    private func makeApplication(bundleIdentifier: String?) -> XCUIApplication {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return XCUIApplication(bundleIdentifier: bundleIdentifier)
        }
        return XCUIApplication()
    }

    private func run(command: ZMRShimCommand, app: XCUIApplication) -> [String: Any] {
        switch command.cmd {
        case "snapshot":
            return [
                "status": "ok",
                "nodes": ZMRShim.snapshot(app: app).map { $0.json }
            ]
        case "screenshot":
            let screenshot = XCUIScreen.main.screenshot()
            return [
                "status": "ok",
                "format": "png",
                "base64": screenshot.pngRepresentation.base64EncodedString()
            ]
        case "query":
            guard let selector = command.selector else {
                return error("invalid.query", "query requires selector")
            }
            guard let parts = selectorParts(selector) else {
                return error("selector.unsupported", "unsupported selector: \(selector)")
            }
            guard isFastQueryable(parts: parts) else {
                return error("selector.unsupported", "unsupported query selector: \(selector)")
            }
            let element = resolveElement(selector: selector, app: app, preferredTypes: [])
            return [
                "status": "ok",
                "exists": element?.exists ?? false,
                "hittable": element?.isHittable ?? false
            ]
        case "tap":
            if let selector = command.selector {
                return tap(selector: selector, app: app)
            }
            guard let x = command.x, let y = command.y else {
                return error("invalid.tap", "tap requires x and y")
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: x, dy: y))
                .tap()
            return ok()
        case "type":
            if let selector = command.selector {
                return typeText(selector: selector, text: command.text ?? "", app: app)
            }
            app.typeText(command.text ?? "")
            return ok()
        case "eraseText":
            let count = Int(command.maxChars ?? 0)
            if let selector = command.selector {
                return eraseText(selector: selector, count: count, app: app)
            }
            if count > 0 {
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
            }
            return ok()
        case "hideKeyboard":
            return hideKeyboard(app: app)
        case "swipe":
            guard let x1 = command.x1, let y1 = command.y1, let x2 = command.x2, let y2 = command.y2 else {
                return error("invalid.swipe", "swipe requires x1, y1, x2, and y2")
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: x1, dy: y1))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: x2, dy: y2))
            start.press(forDuration: 0.01, thenDragTo: end)
            return ok()
        case "pressBack":
            XCUIDevice.shared.press(.home)
            return ok()
        case "settle":
            let timeout = TimeInterval(command.durationMs ?? 1000) / 1000.0
            _ = app.wait(for: app.state, timeout: timeout)
            return ok()
        case "appState":
            return ["status": "ok", "state": app.state.rawValue]
        case "acceptSystemAlert":
            return acceptSystemAlert(buttonText: command.text ?? "Open")
        default:
            return error("unknown.command", "unsupported command: \(command.cmd)")
        }
    }

    private func ok() -> [String: Any] {
        ["status": "ok"]
    }

    private func error(_ code: String, _ message: String) -> [String: Any] {
        ["status": "error", "code": code, "message": message]
    }

    private func acceptSystemAlert(buttonText: String) -> [String: Any] {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var labels = [buttonText, "Open", "Allow", "OK", "Continue"]
        labels = labels.reduce(into: [String]()) { unique, label in
            if !label.isEmpty && !unique.contains(label) {
                unique.append(label)
            }
        }

        var acceptedCount = 0
        var lastAcceptedLabel = ""
        for _ in 0..<3 {
            var tapped = false
            for label in labels {
                let button = springboard.buttons[label].firstMatch
                if button.waitForExistence(timeout: 2), button.isHittable {
                    button.tap()
                    acceptedCount += 1
                    lastAcceptedLabel = label
                    tapped = true
                    Thread.sleep(forTimeInterval: 1.0)
                    break
                }
            }
            if !tapped {
                break
            }
        }

        if acceptedCount > 0 {
            return ["status": "ok", "accepted": true, "label": lastAcceptedLabel, "count": acceptedCount]
        }
        return ["status": "ok", "accepted": false, "count": 0]
    }

    private func hideKeyboard(app: XCUIApplication) -> [String: Any] {
        guard app.keyboards.firstMatch.exists else {
            return ok()
        }

        let keyboard = app.keyboards.firstMatch
        let dismissKeyNames = [
            "Done",
            "done",
            "Return",
            "return",
            "Go",
            "go",
            "Next",
            "next",
            "Search",
            "search",
            "Send",
            "send"
        ]

        for keyName in dismissKeyNames {
            if tapKeyboardElement(keyboard.buttons[keyName]) {
                return ok()
            }
            if tapKeyboardElement(keyboard.keys[keyName]) {
                return ok()
            }
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        if app.keyboards.firstMatch.waitForNonExistence(timeout: 1) {
            return ok()
        }

        return error("keyboard.dismiss_failed", "keyboard did not expose a known dismiss key")
    }

    private func tapKeyboardElement(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else {
            return false
        }
        element.tap()
        return true
    }

    private func tap(selector: String, app: XCUIApplication) -> [String: Any] {
        guard selectorParts(selector) != nil else {
            return error("selector.unsupported", "unsupported selector: \(selector)")
        }
        guard let element = resolveElement(selector: selector, app: app, preferredTypes: [.button]) else {
            return error("selector.not_found", "selector did not match: \(selector)")
        }
        if !element.isHittable {
            return error("selector.not_hittable", "selector matched a non-hittable element: \(selector)")
        }
        element.tap()
        return ok()
    }

    private func typeText(selector: String, text: String, app: XCUIApplication) -> [String: Any] {
        guard selectorParts(selector) != nil else {
            return error("selector.unsupported", "unsupported selector: \(selector)")
        }
        guard let element = resolveElement(selector: selector, app: app, preferredTypes: [.textField, .secureTextField, .textView]) else {
            return error("selector.not_found", "selector did not match: \(selector)")
        }
        if !element.isHittable {
            return error("selector.not_hittable", "selector matched a non-hittable element: \(selector)")
        }
        element.tap()
        app.typeText(text)
        return ok()
    }

    private func eraseText(selector: String, count: Int, app: XCUIApplication) -> [String: Any] {
        guard selectorParts(selector) != nil else {
            return error("selector.unsupported", "unsupported selector: \(selector)")
        }
        guard let element = resolveElement(selector: selector, app: app, preferredTypes: [.textField, .secureTextField, .textView]) else {
            return error("selector.not_found", "selector did not match: \(selector)")
        }
        if !element.isHittable {
            return error("selector.not_hittable", "selector matched a non-hittable element: \(selector)")
        }
        element.tap()
        if count > 0 {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        }
        return ok()
    }

    private func resolveElement(selector: String, app: XCUIApplication, preferredTypes: [XCUIElement.ElementType] = []) -> XCUIElement? {
        if let fast = resolveFastElement(selector: selector, app: app, preferredTypes: preferredTypes), fast.exists {
            return fast
        }

        return resolveBroadElement(selector: selector, app: app)
    }

    private func resolveBroadElement(selector: String, app: XCUIApplication) -> XCUIElement? {
        guard let parts = selectorParts(selector) else {
            return nil
        }

        let query: XCUIElementQuery?
        switch parts.field {
        case "text", "label":
            let predicate = parts.contains
                ? NSPredicate(format: "label CONTAINS[c] %@", parts.value)
                : NSPredicate(format: "label == %@", parts.value)
            query = app.descendants(matching: .any).matching(predicate)
        case "identifier", "resourceId":
            let predicate = parts.contains
                ? NSPredicate(format: "identifier CONTAINS[c] %@", parts.value)
                : NSPredicate(format: "identifier == %@", parts.value)
            query = app.descendants(matching: .any).matching(predicate)
        case "value":
            let predicate = parts.contains
                ? NSPredicate(format: "value CONTAINS[c] %@", parts.value)
                : NSPredicate(format: "value == %@", parts.value)
            query = app.descendants(matching: .any).matching(predicate)
        case "id":
            if parts.value.hasPrefix("id:") {
                let identifier = String(parts.value.dropFirst("id:".count))
                query = app.descendants(matching: .any).matching(identifier: identifier)
            } else if parts.value.hasPrefix("label:") {
                let label = String(parts.value.dropFirst("label:".count))
                query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
            } else {
                query = nil
            }
        default:
            query = nil
        }

        guard let element = query?.firstMatch, element.exists else {
            return nil
        }
        return element
    }

    private func resolveFastElement(selector: String, app: XCUIApplication, preferredTypes: [XCUIElement.ElementType]) -> XCUIElement? {
        guard let parts = selectorParts(selector) else {
            return nil
        }

        switch parts.field {
        case "text", "label":
            let queries = fastTextQueries(app: app, preferredTypes: preferredTypes)
            if parts.contains {
                let predicate = NSPredicate(format: "label CONTAINS[c] %@", parts.value)
                return firstExistingElement(queries: queries.map { $0.matching(predicate) })
            }
            let predicate = NSPredicate(format: "label == %@", parts.value)
            return firstExistingElement(queries: queries.map { $0.matching(predicate) })
        case "identifier", "resourceId":
            let queries = fastIdentifierQueries(app: app, preferredTypes: preferredTypes, contains: parts.contains)
            if parts.contains {
                let predicate = NSPredicate(format: "identifier CONTAINS[c] %@", parts.value)
                return firstExistingElement(queries: queries.map { $0.matching(predicate) })
            }
            return firstExistingElement(queries: queries.map { $0.matching(identifier: parts.value) })
        case "value":
            let queries = fastTextQueries(app: app, preferredTypes: preferredTypes)
            let predicate = parts.contains
                ? NSPredicate(format: "value CONTAINS[c] %@", parts.value)
                : NSPredicate(format: "value == %@", parts.value)
            return firstExistingElement(queries: queries.map { $0.matching(predicate) })
        case "type", "id":
            return nil
        default:
            return nil
        }
    }

    private func fastTextQueries(app: XCUIApplication, preferredTypes: [XCUIElement.ElementType]) -> [XCUIElementQuery] {
        var queries: [XCUIElementQuery] = []
        if !preferredTypes.isEmpty {
            queries.append(contentsOf: preferredTypes.map { app.descendants(matching: $0) })
        }
        queries.append(contentsOf: [
            app.buttons,
            app.staticTexts,
            app.textFields,
            app.secureTextFields,
            app.textViews,
            app.images
        ])
        return queries
    }

    private func fastIdentifierQueries(
        app: XCUIApplication,
        preferredTypes: [XCUIElement.ElementType],
        contains: Bool
    ) -> [XCUIElementQuery] {
        var queries = fastTextQueries(app: app, preferredTypes: preferredTypes)
        if !contains {
            queries.append(app.otherElements)
        }
        return queries
    }

    private func firstExistingElement(queries: [XCUIElementQuery]) -> XCUIElement? {
        for query in queries {
            let element = query.firstMatch
            if element.exists {
                return element
            }
        }
        return nil
    }

    private func isFastQueryable(parts: (field: String, value: String, contains: Bool)) -> Bool {
        switch parts.field {
        case "text", "label", "identifier", "resourceId", "value":
            return true
        default:
            return false
        }
    }

    private func matches(selector: String, element: XCUIElement) -> Bool {
        guard element.exists, let parts = selectorParts(selector) else {
            return false
        }

        let actual: String
        switch parts.field {
        case "text", "label":
            actual = element.label
        case "identifier", "resourceId":
            actual = element.identifier
        case "id":
            actual = stableId(element: element)
        case "value":
            actual = element.value as? String ?? ""
        case "type":
            actual = String(describing: element.elementType)
        default:
            return false
        }

        if parts.contains {
            return actual.localizedCaseInsensitiveContains(parts.value)
        }
        return actual == parts.value
    }

    private func selectorParts(_ selector: String) -> (field: String, value: String, contains: Bool)? {
        let supportedPrefixes = [
            ("textContains=", "text", true),
            ("labelContains=", "label", true),
            ("identifierContains=", "identifier", true),
            ("resourceIdContains=", "resourceId", true),
            ("valueContains=", "value", true),
            ("type=", "type", false),
            ("text=", "text", false),
            ("label=", "label", false),
            ("identifier=", "identifier", false),
            ("resourceId=", "resourceId", false),
            ("id=", "id", false),
            ("value=", "value", false)
        ]

        for (prefix, field, contains) in supportedPrefixes {
            if selector.hasPrefix(prefix) {
                let value = String(selector.dropFirst(prefix.count))
                return value.isEmpty ? nil : (field, value, contains)
            }
        }
        return nil
    }

    private func stableId(element: XCUIElement) -> String {
        if !element.identifier.isEmpty {
            return "id:\(element.identifier)"
        }
        if !element.label.isEmpty {
            return "label:\(element.label)"
        }
        return String(describing: element.elementType)
    }
}

enum ZMRShimError: Error {
    case missingEnvironment
}

private extension ZMRShimBounds {
    var json: [String: Any] {
        [
            "x": x,
            "y": y,
            "width": width,
            "height": height
        ]
    }
}

private extension ZMRShimNode {
    var json: [String: Any] {
        [
            "id": id,
            "type": type,
            "label": label,
            "identifier": identifier,
            "bounds": bounds.json,
            "enabled": enabled,
            "visible": visible,
            "selected": selected
        ]
    }
}
