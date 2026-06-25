import Foundation
import XCTest

final class ZMRShimUITestCase: XCTestCase {
    private let expoDevClientRecoveryTimeout: TimeInterval = 10

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
        if commandRequiresForeground(command), let foregroundError = ensureAppForeground(app: app) {
            return foregroundError
        }

        switch command.cmd {
        case "snapshot":
            return [
                "status": "ok",
                "viewport": ZMRShim.viewport(app: app).json,
                "nodes": ZMRShim.snapshot(app: app).map { $0.json }
            ]
        case "viewport":
            return [
                "status": "ok",
                "viewport": ZMRShim.viewport(app: app).json
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
            let element = resolveFastElement(selector: selector, app: app, preferredTypes: [])
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
            return acceptSystemAlert(
                buttonText: command.text ?? "Open",
                openedURL: command.url,
                expoDevClientFallback: command.expoDevClientFallback ?? false,
                app: app
            )
        default:
            return error("unknown.command", "unsupported command: \(command.cmd)")
        }
    }

    private func commandRequiresForeground(_ command: ZMRShimCommand) -> Bool {
        switch command.cmd {
        case "snapshot", "viewport", "query", "tap", "type", "eraseText", "hideKeyboard", "swipe", "settle":
            return true
        default:
            return false
        }
    }

    private func ensureAppForeground(app: XCUIApplication) -> [String: Any]? {
        if app.state != .runningForeground {
            app.activate()
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if app.state == .runningForeground {
                return nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return error(
            "app.not_foreground",
            "target app did not become foreground; state=\(app.state.rawValue)"
        )
    }

    private func ok() -> [String: Any] {
        ["status": "ok"]
    }

    private func error(_ code: String, _ message: String) -> [String: Any] {
        ["status": "error", "code": code, "message": message]
    }

    private func acceptSystemAlert(
        buttonText: String,
        openedURL: String?,
        expoDevClientFallback: Bool,
        app: XCUIApplication
    ) -> [String: Any] {
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
            // One existence probe on the alert container keeps the no-dialog
            // path to a single short wait instead of a per-label wait, so the
            // best-effort accept after every openLink stays cheap.
            guard springboard.alerts.firstMatch.waitForExistence(timeout: 2) else {
                break
            }
            var tapped = false
            for label in labels {
                let button = springboard.buttons[label].firstMatch
                if button.exists, button.isHittable {
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

        let expoDeepLinkSelection = acceptExpoDevClientDeepLink(
            openedURL: openedURL,
            expoDevClientFallback: expoDevClientFallback,
            app: app
        )
        if expoDeepLinkSelection.accepted {
            acceptedCount += 1
            lastAcceptedLabel = expoDeepLinkSelection.label
        }

        let expoHomeSelection = resumeExpoDevClientHome(app: app)
        if expoHomeSelection.accepted {
            acceptedCount += 1
            lastAcceptedLabel = expoHomeSelection.label
        }

        if acceptedCount > 0 {
            return ["status": "ok", "accepted": true, "label": lastAcceptedLabel, "count": acceptedCount]
        }
        return ["status": "ok", "accepted": false, "count": 0]
    }

    private func acceptExpoDevClientDeepLink(
        openedURL: String?,
        expoDevClientFallback: Bool,
        app: XCUIApplication
    ) -> (accepted: Bool, label: String) {
        let predicate = NSPredicate(
            format: "label != '' AND label != %@ AND label != %@ AND label != %@ AND NOT label CONTAINS[c] %@ AND NOT label BEGINSWITH[c] %@ AND NOT label CONTAINS[c] %@",
            "Deep link received:",
            "Select an app to open it:",
            "Go back",
            "://",
            "Note:",
            "next app you open"
        )

        if app.staticTexts["Deep link received:"].waitForExistence(timeout: 1) {
            if tapFirstMatchingExpoCandidate(
                app: app,
                queries: [app.buttons, app.cells, app.staticTexts],
                predicate: predicate
            ) {
                return (true, "expo-dev-client-deep-link")
            }
        }

        if expoDevClientFallback,
           isCustomSchemeURL(openedURL),
           !isExpoDevClientURL(openedURL) {
            return waitForExpoDevClientRecovery(app: app, deepLinkPredicate: predicate)
        }

        return (false, "")
    }

    private func waitForExpoDevClientRecovery(
        app: XCUIApplication,
        deepLinkPredicate: NSPredicate
    ) -> (accepted: Bool, label: String) {
        let deadline = Date().addingTimeInterval(expoDevClientRecoveryTimeout)
        while Date() < deadline {
            if app.staticTexts["Deep link received:"].exists,
               tapExpoDevClientDeepLinkCandidateFallback(app: app, predicate: deepLinkPredicate) {
                return (true, "expo-dev-client-deep-link-candidate")
            }

            let homeSelection = resumeExpoDevClientHome(app: app)
            if homeSelection.accepted {
                return homeSelection
            }

            Thread.sleep(forTimeInterval: 0.2)
        }

        return (false, "")
    }

    private func isExpoDevClientDeepLinkTarget(label: String) -> Bool {
        if label.isEmpty {
            return false
        }

        let rejectedExactLabels = [
            "Deep link received:",
            "Select an app to open it:",
            "Go back"
        ]
        if rejectedExactLabels.contains(label) {
            return false
        }

        if label.contains("://") || label.hasPrefix("Note:") || label.contains("next app you open") {
            return false
        }

        return true
    }

    private func resumeExpoDevClientHome(app: XCUIApplication) -> (accepted: Bool, label: String) {
        guard app.staticTexts["Development servers"].waitForExistence(timeout: 1) else {
            return (false, "")
        }

        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", " http://", " https://")
        if tapFirstMatchingExpoCandidate(
            app: app,
            queries: [app.buttons, app.cells, app.staticTexts],
            predicate: predicate
        ) {
            return (true, "expo-dev-client-home")
        }

        return (false, "")
    }

    private func isExpoDevClientProjectTarget(label: String) -> Bool {
        if label.isEmpty {
            return false
        }

        let rejectedExactLabels = [
            "Development servers",
            "Recently opened",
            "Fetch development servers",
            "Enter URL manually"
        ]
        if rejectedExactLabels.contains(label) {
            return false
        }

        if label.hasPrefix("http://") || label.hasPrefix("https://") {
            return false
        }

        return label.contains(" http://") || label.contains(" https://")
    }

    private func tapFirstMatchingExpoCandidate(
        app: XCUIApplication,
        queries: [XCUIElementQuery],
        predicate: NSPredicate
    ) -> Bool {
        for query in queries {
            let matching = query.matching(predicate)
            for candidateIndex in 0..<6 {
                let element = matching.element(boundBy: candidateIndex)
                guard element.exists else {
                    break
                }

                if tapMatchedExpoCandidate(element: element, app: app) {
                    return true
                }
            }
        }

        return false
    }

    private func tapMatchedExpoCandidate(element: XCUIElement, app: XCUIApplication) -> Bool {
        if element.isHittable {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
            return true
        }

        let visibleFrame = element.frame.intersection(app.frame)
        guard !visibleFrame.isNull,
              !visibleFrame.isEmpty,
              app.frame.width > 0,
              app.frame.height > 0 else {
            return false
        }

        let normalizedX = (visibleFrame.midX - app.frame.minX) / app.frame.width
        let normalizedY = (visibleFrame.midY - app.frame.minY) / app.frame.height
        guard normalizedX >= 0,
              normalizedX <= 1,
              normalizedY >= 0,
              normalizedY <= 1 else {
            return false
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedY)).tap()
        Thread.sleep(forTimeInterval: 1.0)
        return true
    }

    private func isCustomSchemeURL(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return value.contains("://") && !value.hasPrefix("http://") && !value.hasPrefix("https://")
    }

    private func isExpoDevClientURL(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return value.hasPrefix("exp+") && value.contains("://expo-development-client/")
    }

    private func tapExpoDevClientDeepLinkCandidateFallback(app: XCUIApplication, predicate: NSPredicate) -> Bool {
        tapFirstMatchingExpoCandidate(
            app: app,
            queries: [app.buttons, app.cells, app.staticTexts],
            predicate: predicate
        )
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

        let queries: [XCUIElementQuery]
        switch parts.field {
        case "text", "label":
            let predicate = parts.contains
                ? NSPredicate(format: "label CONTAINS[c] %@", parts.value)
                : NSPredicate(format: "label == %@", parts.value)
            queries = allDescendantQueries(app: app, type: .any).map { $0.matching(predicate) }
        case "identifier", "resourceId":
            let predicate = parts.contains
                ? NSPredicate(format: "identifier CONTAINS[c] %@", parts.value)
                : NSPredicate(format: "identifier == %@", parts.value)
            queries = allDescendantQueries(app: app, type: .any).map { $0.matching(predicate) }
        case "value":
            let predicate = parts.contains
                ? NSPredicate(format: "value CONTAINS[c] %@", parts.value)
                : NSPredicate(format: "value == %@", parts.value)
            queries = allDescendantQueries(app: app, type: .any).map { $0.matching(predicate) }
        case "id":
            if parts.value.hasPrefix("id:") {
                let identifier = String(parts.value.dropFirst("id:".count))
                queries = allDescendantQueries(app: app, type: .any).map { $0.matching(identifier: identifier) }
            } else if parts.value.hasPrefix("label:") {
                let label = String(parts.value.dropFirst("label:".count))
                let predicate = NSPredicate(format: "label == %@", label)
                queries = allDescendantQueries(app: app, type: .any).map { $0.matching(predicate) }
            } else {
                queries = []
            }
        default:
            queries = []
        }

        return firstExistingElement(queries: queries)
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
            queries.append(contentsOf: preferredTypes.flatMap { allDescendantQueries(app: app, type: $0) })
        }
        queries.append(contentsOf: [
            app.windows.descendants(matching: .button),
            app.windows.descendants(matching: .staticText),
            app.windows.descendants(matching: .textField),
            app.windows.descendants(matching: .secureTextField),
            app.windows.descendants(matching: .textView),
            app.windows.descendants(matching: .image),
            app.buttons,
            app.staticTexts,
            app.textFields,
            app.secureTextFields,
            app.textViews,
            app.images
        ])
        return queries
    }

    private func allDescendantQueries(app: XCUIApplication, type: XCUIElement.ElementType) -> [XCUIElementQuery] {
        [
            app.windows.descendants(matching: type),
            app.descendants(matching: type)
        ]
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

private extension ZMRShimViewport {
    var json: [String: Any] {
        [
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
