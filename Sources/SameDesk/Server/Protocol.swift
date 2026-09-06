import Foundation

/// JSON messages exchanged over the WebSocket (text frames). Binary frames are
/// always video (init segment / media fragments).
enum InputMessageType: String, Codable {
    case mousemove, mousedown, mouseup, wheel
    case keydown, keyup
    case text          // printable / IME text, injected via Unicode
    case clipboard     // clipboard text (both directions)
    case ping, pong    // latency probe
    case bitrate       // legacy: client-driven bitrate, now decided server-side
    case viewport      // client's displayed size, so capture can match it
    case keyframe      // client asks for a fresh IDR (e.g. after a decode error)
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InputMessageType(rawValue: raw) ?? .unknown
    }
}

/// One decoded inbound message. All optional so a single struct covers every
/// message kind.
struct InputMessage: Codable {
    let type: InputMessageType

    // Mouse / wheel (coordinates normalized 0–1).
    var x: Double?
    var y: Double?
    var button: Int?      // browser button: 0 left, 1 middle, 2 right
    var deltaX: Double?
    var deltaY: Double?

    // Relative pointer movement (pointer-lock mode), normalized to the displayed
    // video size so motion scale matches absolute mode.
    var dx: Double?
    var dy: Double?
    var rel: Bool?

    // Keyboard.
    var code: String?     // physical-key string, e.g. "KeyA", "Escape"
    var meta: Bool?
    var shift: Bool?
    var ctrl: Bool?
    var alt: Bool?

    // Text / clipboard payload.
    var text: String?

    // Ping/pong timestamp (ms since epoch, client clock).
    var t: Double?

    // Auto-tune target bitrate (Mbps). Legacy; ignored.
    var mbps: Double?

    // Client viewport in device pixels, for capture sizing.
    var w: Int?
    var h: Int?
}

/// Outbound JSON messages (server -> browser).
struct OutboundMessage: Codable {
    let type: String
    var text: String?    // clipboard payload
    var t: Double?       // echoed ping timestamp for RTT
    var s: Double?       // server wall-clock (ms) for clock-offset estimation
    var codec: String?   // video codec string for the client decoder ("config")
    var mbps: Double?    // current server-side bitrate target ("quality")

    static func clipboard(_ text: String) -> OutboundMessage {
        OutboundMessage(type: "clipboard", text: text)
    }
    static func pong(_ t: Double?) -> OutboundMessage {
        OutboundMessage(type: "pong", t: t, s: Date().timeIntervalSince1970 * 1000)
    }
    /// Sent as the first text frame on a new media socket so the browser knows
    /// which codec to configure its decoder for, before any binary segment.
    static func config(codec: String) -> OutboundMessage {
        OutboundMessage(type: "config", codec: codec)
    }
    /// Bitrate the server has settled on. Quality is decided server-side (the
    /// send-queue delay is only observable there), so the HUD reports this
    /// rather than a number the client picked for itself.
    static func quality(mbps: Double) -> OutboundMessage {
        OutboundMessage(type: "quality", mbps: mbps)
    }

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
