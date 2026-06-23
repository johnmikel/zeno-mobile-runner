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
                guard element.exists else {
                    continue
                }
                let key = elementKey(type: type, element: element)
                guard !seen.contains(key) else {
                    continue
                }
                seen.insert(key)
                nodes.append(node(index: nodes.count, type: type, element: element))
            }
        }

        if nodes.isEmpty {
            nodes.append(node(index: 0, type: .application, element: app))
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

    private static func node(index: Int, type: XCUIElement.ElementType, element: XCUIElement) -> ZMRShimNode {
        let frame = element.frame
        return ZMRShimNode(
            id: stableId(index: index, element: element),
            type: String(describing: type),
            label: element.label,
            value: elementValue(element),
            identifier: element.identifier,
            bounds: ZMRShimBounds(
                x: Int(frame.origin.x),
                y: Int(frame.origin.y),
                width: Int(frame.size.width),
                height: Int(frame.size.height)
            ),
            enabled: element.isEnabled,
            visible: element.exists && !frame.isEmpty,
            selected: element.isSelected
        )
    }

    private static func elementValue(_ element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        if let value = element.value {
            return String(describing: value)
        }
        return ""
    }

    private static func stableId(index: Int, element: XCUIElement) -> String {
        if !element.identifier.isEmpty {
            return "id:\(element.identifier)"
        }
        if !element.label.isEmpty {
            return "label:\(element.label):\(index)"
        }
        return "index:\(index)"
    }

    private static func elementKey(type: XCUIElement.ElementType, element: XCUIElement) -> String {
        let frame = element.frame
        return [
            String(describing: type),
            element.identifier,
            element.label,
            elementValue(element),
            String(Int(frame.origin.x)),
            String(Int(frame.origin.y)),
            String(Int(frame.size.width)),
            String(Int(frame.size.height))
        ].joined(separator: "|")
    }
}
