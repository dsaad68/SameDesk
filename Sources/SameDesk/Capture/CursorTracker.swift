import AppKit
import CoreGraphics
import Dispatch
import Foundation

/// Cursor position and shape, sent on the input socket so the browser can draw
/// the pointer itself.
struct CursorMessage: Codable {
    var type = "cursor"
    /// Position and geometry as fractions of the captured display's bounds, so
    /// the client needs to know nothing about capture resolution or scaling.
    var x: Double
    var y: Double
    var hx: Double          // hotspot within the image
    var hy: Double
    var w: Double
    var h: Double
    /// Base64 PNG. Sent only when the shape actually changes — the position
    /// update that carries it is otherwise identical.
    var png: String?

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Tracks the system cursor so the browser can render it locally.
///
/// Compositing the cursor into the video costs a full round trip before the user
/// sees their own pointer move, and every move dirties the frame — so an idle
/// screen encodes a P-frame just because the mouse twitched. Sending position and
/// shape over the input socket instead lets the client paint the pointer at the
/// local mouse position immediately (zero latency, by construction), and leaves
/// the video stream genuinely idle when nothing else changes.
///
/// This is what Moonlight, Steam Link, RDP and Citrix all do; it is the single
/// largest improvement in how responsive a remote desktop *feels*.
@MainActor
final class CursorTracker {
    /// Called with a ready-to-send JSON message whenever the cursor moves or
    /// changes shape.
    var onUpdate: ((String) -> Void)?

    /// The display whose bounds positions are normalised against. Must match the
    /// display being captured (and the one `InputController` injects into).
    var targetDisplayID: CGDirectDisplayID = CGMainDisplayID()

    /// Position is cheap to read, so poll it at roughly frame rate.
    private static let positionInterval = 1.0 / 60.0
    /// Rasterising the cursor is not cheap, so sample the shape less often. A
    /// cursor that changes as you cross a window edge still updates well within
    /// the time it takes to notice.
    private static let shapeInterval = 0.1

    private var timer: DispatchSourceTimer?
    private var lastPoint: CGPoint?
    private var lastShapeCheck: Double = 0
    private var lastShapeFingerprint: Int?
    private var pendingPNG: String?

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.positionInterval, repeating: Self.positionInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastPoint = nil
        lastShapeFingerprint = nil
        pendingPNG = nil
    }

    private func tick() {
        guard let onUpdate else { return }
        let bounds = CGDisplayBounds(targetDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        // CGEvent's location is in global display coordinates with a top-left
        // origin — the same space CGDisplayBounds uses, and the same one
        // InputController maps browser coordinates back into.
        guard let point = CGEvent(source: nil)?.location else { return }

        let now = MonotonicClock.now
        var shapeChanged = false
        if now - lastShapeCheck > Self.shapeInterval {
            lastShapeCheck = now
            shapeChanged = refreshShape()
        }

        let moved = lastPoint.map { abs($0.x - point.x) > 0.01 || abs($0.y - point.y) > 0.01 } ?? true
        guard moved || shapeChanged else { return }
        lastPoint = point

        guard let shape = currentShape else { return }
        let message = CursorMessage(
            x: (point.x - bounds.origin.x) / bounds.width,
            y: (point.y - bounds.origin.y) / bounds.height,
            hx: shape.hotSpot.x / bounds.width,
            hy: shape.hotSpot.y / bounds.height,
            w: shape.size.width / bounds.width,
            h: shape.size.height / bounds.height,
            png: shapeChanged ? pendingPNG : nil
        )
        onUpdate(message.jsonString())
    }

    private struct Shape {
        let size: CGSize
        let hotSpot: CGPoint
    }

    private var currentShape: Shape?

    /// Re-read the system cursor. Returns true when the shape changed and the
    /// next message should carry a new image.
    private func refreshShape() -> Bool {
        guard let cursor = NSCursor.currentSystem, let tiff = cursor.image.tiffRepresentation else {
            return false
        }
        // Cheap fingerprint: rasterising to PNG on every sample would be wasteful
        // when the pointer spends most of its life as the same arrow.
        var hasher = Hasher()
        hasher.combine(tiff.count)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        hasher.combine(cursor.image.size.width)
        hasher.combine(cursor.image.size.height)
        let fingerprint = hasher.finalize()
        currentShape = Shape(size: cursor.image.size, hotSpot: cursor.hotSpot)
        guard fingerprint != lastShapeFingerprint else { return false }
        lastShapeFingerprint = fingerprint

        guard let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        pendingPNG = png.base64EncodedString()
        return true
    }
}
