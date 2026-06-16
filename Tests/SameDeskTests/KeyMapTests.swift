import CoreGraphics
@testable import SameDesk
import XCTest

/// The browser sends physical-key strings (`KeyboardEvent.code`); these lock in
/// a representative slice of the mapping to macOS virtual keycodes plus the
/// unknown-key contract.
final class KeyMapTests: XCTestCase {
    func testKnownKeys() {
        XCTAssertEqual(KeyMap.virtualKey(for: "KeyA"), 0x00)
        XCTAssertEqual(KeyMap.virtualKey(for: "KeyZ"), 0x06)
        XCTAssertEqual(KeyMap.virtualKey(for: "Enter"), 0x24)
        XCTAssertEqual(KeyMap.virtualKey(for: "Escape"), 0x35)
        XCTAssertEqual(KeyMap.virtualKey(for: "Space"), 0x31)
        XCTAssertEqual(KeyMap.virtualKey(for: "ArrowUp"), 0x7E)
        XCTAssertEqual(KeyMap.virtualKey(for: "ArrowLeft"), 0x7B)
        XCTAssertEqual(KeyMap.virtualKey(for: "F1"), 0x7A)
        XCTAssertEqual(KeyMap.virtualKey(for: "MetaLeft"), 0x37)
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(KeyMap.virtualKey(for: ""))
        XCTAssertNil(KeyMap.virtualKey(for: "Foo"))
        XCTAssertNil(KeyMap.virtualKey(for: "keya"))   // case-sensitive
    }

    func testDeleteAliases() {
        // Both Delete and ForwardDelete intentionally resolve to the same key.
        XCTAssertEqual(KeyMap.virtualKey(for: "Delete"), 0x75)
        XCTAssertEqual(KeyMap.virtualKey(for: "ForwardDelete"), 0x75)
    }

    func testTableIsPlausible() {
        XCTAssertGreaterThan(KeyMap.table.count, 60)
        for (name, code) in KeyMap.table {
            XCTAssertLessThanOrEqual(code, 0x7F, "\(name) -> \(code) out of virtual-keycode range")
        }
    }
}
