import Foundation

/// An outbound WebSocket frame: binary = video (init segment + fragments),
/// text = control/JSON (clipboard, pong).
enum WSFrame: Sendable {
    case binary(Data)
    case text(String)
}

/// A single connected browser's outbound video path.
///
/// Each client has its own bounded queue. If a client is slow, we drop the
/// OLDEST media for THAT client only — a slow socket never applies backpressure
/// to capture/encode or to other clients. `AsyncStream.Continuation` with a
/// `.bufferingNewest(n)` policy gives us exactly that drop-oldest behavior.
final class ClientConnection: Identifiable {
    let id = UUID()

    let stream: AsyncStream<WSFrame>
    private let continuation: AsyncStream<WSFrame>.Continuation

    /// Set once this client has been sent an init segment.
    var initSent = false
    /// Set once this client has received its first keyframe fragment. Until then
    /// we drop non-keyframe fragments so MSE starts on an IDR.
    var hasReceivedKeyframe = false

    init(bufferDepth: Int = 90) {
        var cont: AsyncStream<WSFrame>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(bufferDepth)) { c in
            cont = c
        }
        self.continuation = cont
    }

    func enqueue(_ frame: WSFrame) {
        continuation.yield(frame)
    }

    func finish() {
        continuation.finish()
    }
}

/// Owns the connected-client list and fans encoded media out to each client.
///
/// This is genuinely shared mutable state, so it is an `actor`. The capture/
/// encode hot path does NOT run through it — it only calls `broadcast(...)` to
/// hand off finished fragments, and the per-client AsyncStream buffering absorbs
/// any slowness. New clients trigger a forced keyframe via `onClientNeedsKeyframe`.
actor Broadcaster {
    private var clients: [UUID: ClientConnection] = [:]        // media (video/audio)
    private var inputClients: [UUID: ClientConnection] = [:]   // input/control socket
    private var latestInitSegment: Data?

    /// Called when a new client connects and needs an IDR to sync. Wired to the
    /// encoder's `requestKeyframe()`.
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

        for client in clients.values {
            if isKeyframe {
                if !client.initSent, let initSeg = latestInitSegment {
                    client.enqueue(.binary(Self.taggedVideo(initSeg, captureTimeMs: captureTimeMs)))
                    client.initSent = true
                }
                guard client.initSent else { continue } // no init yet -> wait
                client.enqueue(.binary(Self.taggedVideo(fragment, captureTimeMs: captureTimeMs)))
                client.hasReceivedKeyframe = true
            } else if client.hasReceivedKeyframe {
                client.enqueue(.binary(Self.taggedVideo(fragment, captureTimeMs: captureTimeMs)))
            }
        }
    }

    /// Broadcast an audio payload to all clients. Audio is independent of the
    /// video keyframe state, so it goes to every connected client.
    func broadcastAudio(_ payload: Data) {
        let frame = WSFrame.binary(Self.tagged(1, payload))
        for client in clients.values { client.enqueue(frame) }
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
    /// The client uses captureTimeMs (plus a clock offset) for the glass-to-glass
    /// latency readout.
    private static func taggedVideo(_ data: Data, captureTimeMs: Double) -> Data {
        var d = Data(capacity: data.count + 9)
        d.append(0)
        var be = captureTimeMs.bitPattern.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        d.append(data)
        return d
    }

    /// Broadcast a text (JSON) control message (clipboard / reload) to all
    /// INPUT clients except an optional origin. Control rides the input socket,
    /// not the video socket, so it's never queued behind frames.
    func broadcastText(_ text: String, except originID: UUID? = nil) {
        for (id, client) in inputClients where id != originID {
            client.enqueue(.text(text))
        }
    }
}
