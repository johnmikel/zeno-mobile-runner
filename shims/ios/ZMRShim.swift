import Foundation
import XCTest

struct ZMRShimCommand: Decodable {
    let cmd: String
    let selector: String?
    let text: String?
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
    static func snapshot(app: XCUIApplication) -> [ZMRShimNode] {
        let queries: [(XCUIElement.ElementType, XCUIElementQuery)] = [
            (.button, app.buttons),
            (.staticText, app.staticTexts),
            (.textField, app.textFields),
            (.secureTextField, app.secureTextFields),
            (.textView, app.textViews),
            (.image, app.images),
            (.switch, app.switches),
            (.cell, app.cells),
            (.scrollView, app.scrollViews),
            (.table, app.tables),
            (.collectionView, app.collectionViews)
        ]

        var nodes: [ZMRShimNode] = []
        nodes.reserveCapacity(128)

        for (type, query) in queries {
            for element in query.allElementsBoundByIndex {
                guard nodes.count < 256 else {
                    return nodes
                }
                guard element.exists else {
                    continue
                }
                nodes.append(node(index: nodes.count, type: type, element: element))
            }
        }

        if nodes.isEmpty {
            nodes.append(node(index: 0, type: .application, element: app))
        }
        return nodes
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
}
