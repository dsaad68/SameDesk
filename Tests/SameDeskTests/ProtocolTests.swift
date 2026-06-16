@testable import SameDesk
import XCTest

/// Wire-format tests for the JSON exchanged with the browser. These guard the
/// decoder's unknown-type fallback, optional-field handling, and the outbound
/// factory methods (which the client parses verbatim).
final class ProtocolTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode(_ json: String) throws -> InputMessage {
        try decoder.decode(InputMessage.self, from: Data(json.utf8))
    }

    func testDecodeMouseMove() throws {
        let m = try decode(#"{"type":"mousemove","x":0.5,"y":0.25,"button":0}"#)
        XCTAssertEqual(m.type, .mousemove)
        XCTAssertEqual(m.x, 0.5)
        XCTAssertEqual(m.y, 0.25)
        XCTAssertEqual(m.button, 0)
        XCTAssertNil(m.code)
    }

    func testDecodeKeydownWithModifiers() throws {
        let m = try decode(#"{"type":"keydown","code":"KeyA","meta":true,"shift":false}"#)
        XCTAssertEqual(m.type, .keydown)
        XCTAssertEqual(m.code, "KeyA")
        XCTAssertEqual(m.meta, true)
        XCTAssertEqual(m.shift, false)
        XCTAssertNil(m.ctrl)
    }

    func testDecodeRelativePointer() throws {
        let m = try decode(#"{"type":"mousemove","dx":-3.5,"dy":2,"rel":true}"#)
        XCTAssertEqual(m.dx, -3.5)
        XCTAssertEqual(m.dy, 2)
        XCTAssertEqual(m.rel, true)
    }

    func testUnknownTypeMapsToUnknown() throws {
        XCTAssertEqual(try decode(#"{"type":"frobnicate"}"#).type, .unknown)
        XCTAssertEqual(try decode(#"{"type":""}"#).type, .unknown)
    }

    func testAllKnownTypesDecode() throws {
        let cases: [(String, InputMessageType)] = [
            ("mousemove", .mousemove), ("mousedown", .mousedown), ("mouseup", .mouseup),
            ("wheel", .wheel), ("keydown", .keydown), ("keyup", .keyup),
            ("text", .text), ("clipboard", .clipboard), ("ping", .ping),
            ("pong", .pong), ("bitrate", .bitrate), ("keyframe", .keyframe)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(try decode("{\"type\":\"\(raw)\"}").type, expected, "type \(raw)")
        }
    }

    func testOutboundConfigOmitsNilFields() throws {
        let json = OutboundMessage.config(codec: "avc1.640028").jsonString()
        XCTAssertTrue(json.contains("\"type\":\"config\""))
        XCTAssertTrue(json.contains("\"codec\":\"avc1.640028\""))
        XCTAssertFalse(json.contains("\"text\""))
        XCTAssertFalse(json.contains("\"t\""))

        let back = try decoder.decode(OutboundMessage.self, from: Data(json.utf8))
        XCTAssertEqual(back.type, "config")
        XCTAssertEqual(back.codec, "avc1.640028")
    }

    func testOutboundClipboardRoundTrip() throws {
        let text = "hello\nworld 🌍"
        let json = OutboundMessage.clipboard(text).jsonString()
        let back = try decoder.decode(OutboundMessage.self, from: Data(json.utf8))
        XCTAssertEqual(back.type, "clipboard")
        XCTAssertEqual(back.text, text)
    }

    func testOutboundPongCarriesTimestamps() {
        let m = OutboundMessage.pong(123)
        XCTAssertEqual(m.type, "pong")
        XCTAssertEqual(m.t, 123)
        XCTAssertNotNil(m.s)   // server wall-clock for offset estimation
    }

    func testJSONStringIsValidJSON() throws {
        let json = OutboundMessage.pong(1).jsonString()
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "pong")
    }
}
