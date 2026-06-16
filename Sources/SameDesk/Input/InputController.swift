import AppKit
import CoreGraphics
import Foundation

/// Decodes input JSON from the browser and injects it as `CGEvent`s on the
/// `.cghidEventTap` (requires Accessibility + a disabled sandbox).
///
/// Coordinates arrive normalized 0–1 relative to the captured display and are
/// mapped onto that display's global pixel bounds.
final class InputController {
    /// The display whose bounds normalized coordinates map onto.
    var targetDisplayID: CGDirectDisplayID = CGMainDisplayID()

    private let eventSource = CGEventSource(stateID: .hidSystemState)

    // Mouse state for drag / click-count tracking.
    private var buttonsDown: Set<CGMouseButton> = []
    private var lastClickTime: TimeInterval = 0
    private var lastClickButton: CGMouseButton?
    private var clickCount: Int = 0
    private var lastMouseLocation: CGPoint = .zero
    /// Running cursor position for pointer-lock (relative) movement.
    private var relCursor: CGPoint?

    // MARK: - Entry point

    /// Handle one decoded input message. Runs on a server task; `CGEvent`
    /// posting is thread-safe to call from any thread.
    func handle(_ message: InputMessage) {
        switch message.type {
        case .mousemove, .mousedown, .mouseup:
            handleMouse(message)
        case .wheel:
            handleWheel(message)
        case .keydown:
            handleKey(message, down: true)
        case .keyup:
            handleKey(message, down: false)
        case .text:
            handleText(message)
        case .clipboard, .ping, .pong, .bitrate, .keyframe, .unknown:
            break // handled elsewhere / ignored here
        }
    }

    // MARK: - Mouse

    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(targetDisplayID)
        let x = bounds.origin.x + CGFloat(max(0, min(1, nx))) * bounds.width
        let y = bounds.origin.y + CGFloat(max(0, min(1, ny))) * bounds.height
        return CGPoint(x: x, y: y)
    }

    private func cgButton(_ browserButton: Int?) -> CGMouseButton {
        switch browserButton {
        case 1: return .center
        case 2: return .right
        default: return .left
        }
    }

    private func handleMouse(_ m: InputMessage) {
        let point: CGPoint
        if m.rel == true, m.type == .mousemove {
            // Pointer-lock relative move: accumulate normalized deltas onto the
            // running cursor, clamped to the display bounds.
            let bounds = CGDisplayBounds(targetDisplayID)
            var cursor = relCursor ?? lastMouseLocation
            if relCursor == nil, lastMouseLocation == .zero {
                cursor = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            cursor.x += CGFloat(m.dx ?? 0) * bounds.width
            cursor.y += CGFloat(m.dy ?? 0) * bounds.height
            cursor.x = min(max(cursor.x, bounds.minX), bounds.maxX - 1)
            cursor.y = min(max(cursor.y, bounds.minY), bounds.maxY - 1)
            relCursor = cursor
            point = cursor
        } else {
            guard let nx = m.x, let ny = m.y else { return }
            point = screenPoint(nx: nx, ny: ny)
            relCursor = point   // keep relative cursor in sync for seamless switch
        }
        lastMouseLocation = point
        let button = cgButton(m.button)

        switch m.type {
        case .mousedown:
            updateClickCount(for: button)
            buttonsDown.insert(button)
            postMouse(type: downEventType(button), point: point, button: button)

        case .mouseup:
            buttonsDown.remove(button)
            postMouse(type: upEventType(button), point: point, button: button)

        case .mousemove:
            // If a button is held, this is a DRAG (left/right/center dragged),
            // not a plain move — otherwise drags don't register.
            if let held = buttonsDown.first {
                postMouse(type: dragEventType(held), point: point, button: held)
            } else {
                postMouse(type: .mouseMoved, point: point, button: .left)
            }

        default:
            break
        }
    }

    private func updateClickCount(for button: CGMouseButton) {
        let now = Date().timeIntervalSinceReferenceDate
        let doubleClickInterval = 0.5
        if lastClickButton == button, (now - lastClickTime) < doubleClickInterval {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickButton = button
    }

    private func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        if type == downEventType(button) || type == upEventType(button) {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }

    private func downEventType(_ b: CGMouseButton) -> CGEventType {
        switch b {
        case .right: return .rightMouseDown
        case .center: return .otherMouseDown
        default: return .leftMouseDown
        }
    }
    private func upEventType(_ b: CGMouseButton) -> CGEventType {
        switch b {
        case .right: return .rightMouseUp
        case .center: return .otherMouseUp
        default: return .leftMouseUp
        }
    }
    private func dragEventType(_ b: CGMouseButton) -> CGEventType {
        switch b {
        case .right: return .rightMouseDragged
        case .center: return .otherMouseDragged
        default: return .leftMouseDragged
        }
    }

    // MARK: - Scroll & pinch

    private func handleWheel(_ m: InputMessage) {
        let dx = Int32((m.deltaX ?? 0).rounded())
        let dy = Int32((m.deltaY ?? 0).rounded())

        // Pinch-to-zoom: browsers report trackpad pinch as a wheel event with
        // ctrlKey=true. There is no public CGEvent magnify-gesture API, so we
        // map it to Cmd+scroll, which most apps and macOS zoom honor.
        if m.ctrl == true {
            guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                                      wheelCount: 1, wheel1: -dy, wheel2: 0, wheel3: 0) else { return }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
            return
        }

        // Note wheel deltas are inverted to match natural scrolling direction.
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                                  wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private func modifierFlags(_ m: InputMessage) -> CGEventFlags {
        var flags: CGEventFlags = []
        if m.meta == true { flags.insert(.maskCommand) }
        if m.shift == true { flags.insert(.maskShift) }
        if m.ctrl == true { flags.insert(.maskControl) }
        if m.alt == true { flags.insert(.maskAlternate) }
        return flags
    }

    private func handleKey(_ m: InputMessage, down: Bool) {
        guard let code = m.code, let vk = KeyMap.virtualKey(for: code) else { return }
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: vk, keyDown: down) else { return }
        event.flags = modifierFlags(m)
        event.post(tap: .cghidEventTap)
    }

    /// Printable text / IME / non-Latin input. Prefer Unicode injection over
    /// keycode synthesis (which assumes a US layout and breaks for accented or
    /// composed characters).
    private func handleText(_ m: InputMessage) {
        guard let text = m.text, !text.isEmpty else { return }
        let utf16 = Array(text.utf16)
        // A keyDown carrying the Unicode string, followed by keyUp, types the
        // characters regardless of the host keyboard layout.
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
