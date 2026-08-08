import Foundation
import XCTest

struct ZMRShimCommand: Decodable {
    let cmd: String
    let selector: String?
    let text: String?
    let url: String?
    let expoDevClientFallback: Bool?
    let x: Int?
    let y: Int?
    let x1: Int?
    let y1: Int?
    let x2: Int?
    let y2: Int?
    let durationMs: UInt?
    let maxChars: UInt?
}

struct ZMRShimBounds: Encodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct ZMRShimViewport: Encodable {
    let width: Int
    let height: Int
}

struct ZMRShimNode: Encodable {
    let id: String
    let type: String
    let label: String
    let value: String
    let identifier: String
    let bounds: ZMRShimBounds
    let enabled: Bool
    let visible: Bool
    let selected: Bool
    let focused: Bool
    let checked: Bool
}

enum ZMRShim {
    static func viewport(app: XCUIApplication) -> ZMRShimViewport {
        let frame = app.frame
        return ZMRShimViewport(width: Int(frame.size.width), height: Int(frame.size.height))
    }

    static func snapshot(app: XCUIApplication) -> [ZMRShimNode] {
        let types: [XCUIElement.ElementType] = [
            .button,
            .staticText,
            .textField,
            .secureTextField,
            .textView,
            .image,
            .switch,
            .cell,
            .scrollView,
            .table,
            .collectionView,
            .other
        ]
        let queries = types.flatMap { type in snapshotQueries(app: app, type: type) }

        var nodes: [ZMRShimNode] = []
        var seen = Set<String>()
        nodes.reserveCapacity(128)

        for (type, query) in queries {
            for element in query.allElementsBoundByIndex {
                guard nodes.count < 256 else {
                    return nodes
                }
                // Capture every attribute in one atomic snapshot. Reading .label /
                // .frame / .isEnabled / .isSelected straight off a live XCUIElement
                // re-resolves the underlying query once per property, and if the
                // hierarchy shifted since allElementsBoundByIndex bound these
                // proxies, XCUITest raises "Failed to get matching snapshot: No
                // matches found for Element at index N". That is an XCTest failure
                // rather than a Swift error, so it cannot be caught at the call
                // site: it fails the whole test case, tears down the shim server
                // mid-session, and reaches the runner as IosXCTestShimServerExited
                // with an empty visibleTexts list. React Native re-renders
                // constantly and Fast Refresh guarantees it, so this fires on
                // ordinary apps. snapshot() throws instead, so an element that
                // disappears mid-walk costs one skipped node, not the session.
                guard let captured = try? element.snapshot() else {
                    continue
                }
                let key = elementKey(type: type, snapshot: captured)
                guard !seen.contains(key) else {
                    continue
                }
                seen.insert(key)
                nodes.append(node(index: nodes.count, type: type, snapshot: captured))
            }
        }

        if nodes.isEmpty, let captured = try? app.snapshot() {
            nodes.append(node(index: 0, type: .application, snapshot: captured))
        }
        return nodes
    }

    private static func snapshotQueries(app: XCUIApplication, type: XCUIElement.ElementType) -> [(XCUIElement.ElementType, XCUIElementQuery)] {
        if type == .other {
            let hasIdentifier = NSPredicate(format: "identifier != %@", "")
            return [
                (type, app.windows.descendants(matching: type).matching(hasIdentifier)),
                (type, app.descendants(matching: type).matching(hasIdentifier))
            ]
        }

        return [
            (type, app.windows.descendants(matching: type)),
            (type, app.descendants(matching: type))
        ]
    }

    private static func node(index: Int, type: XCUIElement.ElementType, snapshot: XCUIElementSnapshot) -> ZMRShimNode {
        let frame = snapshot.frame
        return ZMRShimNode(
            id: stableId(index: index, snapshot: snapshot),
            type: String(describing: type),
            label: snapshot.label,
            value: elementValue(snapshot),
            identifier: snapshot.identifier,
            bounds: ZMRShimBounds(
                x: Int(frame.origin.x),
                y: Int(frame.origin.y),
                width: Int(frame.size.width),
                height: Int(frame.size.height)
            ),
            enabled: snapshot.isEnabled,
            // A successful capture already means the element existed at capture
            // time, so the old element.exists check is folded in here.
            visible: !frame.isEmpty,
            selected: snapshot.isSelected,
            // Public XCUIElementAttributes. `checked` has no public iOS
            // equivalent, so selectors using it stay Android-only rather than
            // silently reporting false here.
            focused: snapshot.hasFocus,
            checked: isChecked(type: type, snapshot: snapshot)
        )
    }

    /// UIKit has no general "checked" attribute, and none is exposed publicly.
    /// For the controls where the idea is meaningful -- switches and toggles --
    /// the accessibility value is "1" when on, so report that and leave
    /// everything else false rather than inventing a state.
    private static func isChecked(type: XCUIElement.ElementType, snapshot: XCUIElementSnapshot) -> Bool {
        switch type {
        case .switch, .toggle:
            return elementValue(snapshot) == "1"
        default:
            return false
        }
    }

    private static func elementValue(_ snapshot: XCUIElementSnapshot) -> String {
        if let value = snapshot.value as? String {
            return value
        }
        if let value = snapshot.value {
            return String(describing: value)
        }
        return ""
    }

    private static func stableId(index: Int, snapshot: XCUIElementSnapshot) -> String {
        if !snapshot.identifier.isEmpty {
            return "id:\(snapshot.identifier)"
        }
        if !snapshot.label.isEmpty {
            return "label:\(snapshot.label):\(index)"
        }
        return "index:\(index)"
    }

    private static func elementKey(type: XCUIElement.ElementType, snapshot: XCUIElementSnapshot) -> String {
        let frame = snapshot.frame
        return [
            String(describing: type),
            snapshot.identifier,
            snapshot.label,
            elementValue(snapshot),
            String(Int(frame.origin.x)),
            String(Int(frame.origin.y)),
            String(Int(frame.size.width)),
            String(Int(frame.size.height))
        ].joined(separator: "|")
    }
}
