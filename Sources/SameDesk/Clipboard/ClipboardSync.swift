import AppKit
import Foundation

/// Two-way plain-text clipboard sync.
///
///  - Mac -> Browser: poll `NSPasteboard.changeCount`; on change, push the new
///    text to all clients (via `onLocalChange`).
///  - Browser -> Mac: `applyRemoteText(_:)` writes to `NSPasteboard`.
///
/// The single shared mutable value (the last text we observed/wrote) is guarded
/// by a lock so the poll timer and the WS handler don't race.
final class ClipboardSync {
    /// Called on the main thread when the local pasteboard changes. The payload
    /// is the new text to broadcast to browsers.
    var onLocalChange: ((String) -> Void)?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private let lock = NSLock()
    private var lastValue: String = ""
    private var timer: Timer?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        guard let text = pasteboard.string(forType: .string) else { return }

        // Don't echo back a value we just wrote from a remote client.
        lock.lock()
        let isEcho = (text == lastValue)
        lastValue = text
        lock.unlock()
        guard !isEcho else { return }

        onLocalChange?(text)
    }

    /// Apply text received from a browser to the Mac pasteboard.
    func applyRemoteText(_ text: String) {
        lock.lock()
        lastValue = text
        lock.unlock()

        DispatchQueue.main.async {
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
            // Keep our changeCount baseline in sync so the next poll doesn't
            // treat our own write as a local change to rebroadcast.
            self.lastChangeCount = self.pasteboard.changeCount
        }
    }
}
