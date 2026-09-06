import Dispatch
import Foundation

/// Monotonic seconds. Used for every interval measurement in the send path —
/// wall-clock jumps (NTP, sleep/wake) must not be read as congestion.
enum MonotonicClock {
    static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
}

/// An outbound WebSocket frame: binary = video (init segment + fragments),
/// text = control/JSON (clipboard, pong).
enum WSFrame: Sendable {
    case binary(Data)
    case text(String)
}

/// A frame waiting on a client's socket, plus the bookkeeping the congestion
/// signal needs.
struct OutboundFrame: Sendable {
    let frame: WSFrame
    /// Monotonic time the frame entered the queue. The gap between this and the
    /// moment the socket write completes is our congestion signal (see
    /// `ClientConnection.recordWriteDelay`).
    let enqueuedAt: Double
    /// Media (video/audio) may be shed under congestion; control frames
    /// (codec config, clipboard, pong) may not.
    let isMedia: Bool
}

/// A single connected browser's outbound path.
///
/// Each client owns a shallow bounded queue. A slow socket never applies
/// backpressure to capture/encode or to other clients — but, unlike a plain
/// drop-oldest buffer, an overflow here is *reported*: discarding a P-frame
/// breaks the decoder's reference chain, so the broadcaster has to resynchronise
/// that client on a fresh keyframe rather than let it decode garbage.
final class ClientConnection: Identifiable, @unchecked Sendable {
    let id = UUID()

    /// Media frames queued before we shed. Deliberately shallow: on a LAN the
    /// queue absorbs one slow write, it is not a jitter buffer. Anything older
    /// is stale — the viewer wants "now", not a replay. (Was 90 ≈ 1.5 s at 60 fps,
    /// which is what turned a 1 s Wi-Fi blip into a multi-second fast-forward.)
    static let defaultMediaDepth = 6

    /// Control frames are never dropped for being stale, but a client that has
    /// stopped reading entirely must not grow the queue without bound.
    private static let controlHardCap = 256

    /// A socket write that took longer than this means the frames queued behind
    /// it are already stale; shed them and resync instead of playing them out.
    static let staleWriteThreshold = 0.15

    private let mediaDepth: Int
    private let lock = NSLock()
    private var queue: [OutboundFrame] = []
    private var waiter: CheckedContinuation<OutboundFrame?, Never>?
    private var finished = false
    private var cancelled = false
    private var peakWriteDelay: Double = 0

    /// Set once this client has been sent an init segment.
    /// Only mutated on the `Broadcaster` actor.
    var initSent = false
    /// Set once this client has received its first keyframe fragment. Until then
    /// we drop non-keyframe fragments so the decoder starts on an IDR.
    /// Only mutated on the `Broadcaster` actor.
    var hasReceivedKeyframe = false

    init(bufferDepth: Int = ClientConnection.defaultMediaDepth) {
        self.mediaDepth = bufferDepth
    }

    /// Queue a frame for this client.
    ///
    /// - Returns: `false` if a media frame had to be discarded to make room. The
    ///   caller must then treat the client as desynchronised — a gap in the
    ///   stream is not something the decoder can recover from on its own.
    @discardableResult
    func enqueue(_ frame: WSFrame, isMedia: Bool = true) -> Bool {
        let item = OutboundFrame(frame: frame, enqueuedAt: MonotonicClock.now, isMedia: isMedia)

        lock.lock()
        guard !finished else { lock.unlock(); return true }

        // Hand straight to a waiting consumer — the common, uncongested case.
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: item)
            return true
        }

        queue.append(item)
        var overflowed = false
        while queue.count > mediaDepth, let index = queue.firstIndex(where: { $0.isMedia }) {
            queue.remove(at: index)
            overflowed = true
        }
        if queue.count > Self.controlHardCap {
            queue.removeFirst(queue.count - Self.controlHardCap)
        }
        lock.unlock()
        return !overflowed
    }

    /// Await the next frame to write. Single consumer (the socket task).
    /// Returns nil once the connection is finished or the consumer is cancelled.
    func next() async -> OutboundFrame? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<OutboundFrame?, Never>) in
                lock.lock()
                if !queue.isEmpty {
                    let item = queue.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: item)
                } else if finished || cancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter()
        }
    }

    /// Discard every queued media frame. Called when the client has fallen far
    /// enough behind that the backlog is worthless; it resyncs on a keyframe.
    @discardableResult
    func purgeMedia() -> Bool {
        lock.lock()
        let before = queue.count
        queue.removeAll { $0.isMedia }
        let dropped = queue.count != before
        lock.unlock()
        return dropped
    }

    /// Record how long a frame sat between being queued and the kernel accepting
    /// it. Returns true if that delay says the client is falling behind.
    func recordWriteDelay(_ seconds: Double) -> Bool {
        lock.lock()
        peakWriteDelay = max(peakWriteDelay, seconds)
        lock.unlock()
        return seconds > Self.staleWriteThreshold
    }

    /// Read and reset the worst write delay seen since the last call.
    func drainPeakWriteDelay() -> Double {
        lock.lock()
        let peak = peakWriteDelay
        peakWriteDelay = 0
        lock.unlock()
        return peak
    }

    var queuedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    func finish() {
        lock.lock()
        finished = true
        queue.removeAll()
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }

    private func cancelWaiter() {
        lock.lock()
        cancelled = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }
}

/// Owns the connected-client list and fans encoded media out to each client.
///
/// This is genuinely shared mutable state, so it is an `actor`. The capture/
/// encode hot path does NOT run through it — it only calls `broadcast(...)` to
/// hand off finished fragments, and each client's bounded queue absorbs any
/// slowness. When a client's queue overflows or its socket stalls, the client is
/// resynchronised on a fresh keyframe via `onClientNeedsKeyframe`.
actor Broadcaster {
    private var clients: [UUID: ClientConnection] = [:]        // media (video/audio)
    private var inputClients: [UUID: ClientConnection] = [:]   // input/control socket
    private var latestInitSegment: Data?
    private var lastKeyframeRequest: Double = 0

    /// Minimum gap between keyframe requests triggered by congestion. A keyframe
    /// is many times the size of a P-frame, so asking for one on every dropped
    /// frame would deepen the very congestion we are recovering from.
    private static let keyframeRequestInterval = 0.4

    /// Called when a client needs an IDR to (re)sync. Wired to the encoder's
    /// `requestKeyframe()`.
    var onClientNeedsKeyframe: (() -> Void)?

    var clientCount: Int { clients.count }

    func setKeyframeRequester(_ requester: @escaping () -> Void) {
        onClientNeedsKeyframe = requester
    }

    func add(_ client: ClientConnection) {
        clients[client.id] = client
        // Force a keyframe so this client (and its init segment) sync fast.
        onClientNeedsKeyframe?()
    }

    func remove(_ id: UUID) {
        clients[id]?.finish()
        clients[id] = nil
    }

    func addInput(_ client: ClientConnection) {
        inputClients[client.id] = client
    }

    func removeInput(_ id: UUID) {
        inputClients[id]?.finish()
        inputClients[id] = nil
    }

    /// Cache/refresh the init segment (called when parameter sets change). Does
    /// not itself send anything — clients receive it lazily on the next keyframe.
    func updateInitSegment(_ data: Data) {
        latestInitSegment = data
    }

    /// Broadcast one media fragment to all clients.
    ///
    /// On a keyframe we (a) make sure each client has its init segment, then
    /// (b) send the IDR fragment and mark the client synced. Non-keyframe
    /// fragments only go to already-synced clients.
    func broadcast(fragment: Data, isKeyframe: Bool, initSegment: Data?, captureTimeMs: Double) {
        if let initSegment { latestInitSegment = initSegment }
        guard !clients.isEmpty else { return }

        // Build the wire payload once and share it across clients.
        let fragmentFrame = WSFrame.binary(Self.taggedVideo(fragment, captureTimeMs: captureTimeMs))
        var initFrame: WSFrame?
        if isKeyframe, let initSegment = latestInitSegment {
            initFrame = .binary(Self.taggedVideo(initSegment, captureTimeMs: captureTimeMs))
        }

        var needsKeyframe = false
        for client in clients.values {
            if isKeyframe {
                if !client.initSent {
                    guard let initFrame else { continue }   // no init yet -> wait
                    guard deliver(initFrame, to: client) else { needsKeyframe = true; continue }
                    client.initSent = true
                }
                guard deliver(fragmentFrame, to: client) else { needsKeyframe = true; continue }
                client.hasReceivedKeyframe = true
            } else if client.hasReceivedKeyframe {
                if !deliver(fragmentFrame, to: client) { needsKeyframe = true }
            }
        }
        if needsKeyframe { requestKeyframeThrottled() }
    }

    /// Broadcast an audio payload to all clients. Audio is independent of the
    /// video keyframe state, so it goes to every connected client.
    func broadcastAudio(_ payload: Data) {
        guard !clients.isEmpty else { return }
        let frame = WSFrame.binary(Self.tagged(1, payload))
        var needsKeyframe = false
        for client in clients.values where !deliver(frame, to: client) {
            needsKeyframe = true
        }
        if needsKeyframe { requestKeyframeThrottled() }
    }

    /// Reported by a client's socket task when a write took long enough that
    /// whatever is queued behind it is stale. Shed the backlog and resync.
    func clientFellBehind(_ id: UUID) {
        guard let client = clients[id], client.initSent || client.hasReceivedKeyframe else { return }
        markDesynced(client)
        requestKeyframeThrottled()
    }

    /// Worst enqueue→write delay across all clients since the last call. This is
    /// the input to the bitrate controller.
    func drainPeakWriteDelay() -> Double {
        var peak = 0.0
        for client in clients.values { peak = max(peak, client.drainPeakWriteDelay()) }
        return peak
    }

    /// Deepest per-client queue right now (diagnostics only).
    func maxQueuedFrameCount() -> Int {
        clients.values.reduce(0) { max($0, $1.queuedFrameCount) }
    }

    /// Enqueue for one client, resynchronising it if the queue overflowed.
    /// - Returns: false if the client was desynchronised by this delivery.
    private func deliver(_ frame: WSFrame, to client: ClientConnection) -> Bool {
        guard client.enqueue(frame) else {
            markDesynced(client)
            return false
        }
        return true
    }

    /// Drop this client back to "needs a fresh start": shed the stale backlog and
    /// require both a new init segment and a new IDR before sending deltas again.
    private func markDesynced(_ client: ClientConnection) {
        client.purgeMedia()
        client.initSent = false
        client.hasReceivedKeyframe = false
    }

    private func requestKeyframeThrottled() {
        let now = MonotonicClock.now
        guard now - lastKeyframeRequest > Self.keyframeRequestInterval else { return }
        lastKeyframeRequest = now
        onClientNeedsKeyframe?()
    }

    /// Prepend a 1-byte stream tag (0 = video, 1 = audio) so the client can
    /// route binary messages.
    private static func tagged(_ tag: UInt8, _ data: Data) -> Data {
        var d = Data(capacity: data.count + 1)
        d.append(tag)
        d.append(data)
        return d
    }

    /// Video frame header: [tag=0][captureTimeMs: Float64 big-endian] + payload.
    /// The client uses captureTimeMs (plus a clock offset) both for the
    /// glass-to-glass readout and to decide when it has fallen behind live.
    private static func taggedVideo(_ data: Data, captureTimeMs: Double) -> Data {
        var d = Data(capacity: data.count + 9)
        d.append(0)
        var be = captureTimeMs.bitPattern.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        d.append(data)
        return d
    }

    /// Broadcast a text (JSON) control message (clipboard / reload / quality) to
    /// all INPUT clients except an optional origin. Control rides the input
    /// socket, not the video socket, so it is never queued behind frames.
    func broadcastText(_ text: String, except originID: UUID? = nil) {
        for (id, client) in inputClients where id != originID {
            client.enqueue(.text(text), isMedia: false)
        }
    }
}
