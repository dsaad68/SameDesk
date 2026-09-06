import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTLS
import HummingbirdWebSocket
import NIOCore
import NIOSSL

/// HTTPS + WSS server (Hummingbird 2.x).
///
/// Every entry point is token-gated:
///   - `GET /`   serves the client page (401 without a valid token).
///   - `GET /ws` upgrades to WebSocket (refuses the upgrade without a valid token).
///
/// The listener is bound to a SPECIFIC LAN IPv4 interface address — never
/// 0.0.0.0 and never ::/IPv6 — so it can't be reached over a globally-routable
/// address (see NetworkLockdown).
final class SameDeskServer {
    struct Config {
        let bindAddress: String       // specific LAN IPv4
        let port: Int
        let certPath: String
        let keyPath: String
    }

    private let broadcaster: Broadcaster
    private let tokenStore: TokenStore
    private let codecProvider: () -> String

    /// Called for each decoded input/keyboard/mouse/wheel message.
    var onInput: ((InputMessage) -> Void)?
    /// Called when a browser pushes clipboard text (Browser -> Mac).
    var onClipboard: ((String) -> Void)?
    /// Called when a client requests a fresh keyframe (e.g. after a decode error).
    var onRequestKeyframe: (() -> Void)?
    /// Called when a client reports the size it is displaying the stream at.
    var onViewport: ((UUID, Int, Int) -> Void)?

    private var serverTask: Task<Void, Error>?

    // pageConnectionNote: the page and script responses close their connection
    // instead of leaving it idle for keep-alive. Chrome will happily reuse an
    // idle HTTP/1.1 connection for a WebSocket handshake, and Hummingbird's
    // typed upgrader refuses to upgrade a connection that has already served
    // plain requests (it logs "Error handling upgrade result / Inappropriate
    // operation for state" and drops it). The browser's socket then fails and
    // the client sits in its reconnect loop until an attempt happens to land on
    // a fresh connection — a few seconds of "Reconnecting…" on every page load.
    // With nothing idle to reuse, every handshake gets its own connection.

    /// Kernel send-buffer ceiling per connection.
    ///
    /// macOS auto-tunes SO_SNDBUF into the megabytes, which hides congestion
    /// completely: `write` returns instantly while seconds of stale video pile
    /// up below us. Capping it keeps the write completion meaningful (it is our
    /// congestion signal) and bounds how much stale video a blip can strand.
    /// 256 KB still sustains hundreds of Mbps at LAN round-trip times.
    private static let sendBufferBytes: Int32 = 256 * 1024

    init(broadcaster: Broadcaster, tokenStore: TokenStore, codecProvider: @escaping () -> String) {
        self.broadcaster = broadcaster
        self.tokenStore = tokenStore
        self.codecProvider = codecProvider
    }

    func start(config: Config) throws {
        let router = Router(context: BasicWebSocketRequestContext.self)

        // GET / — the client page.
        //
        // Auth is via an HttpOnly session cookie, not a token in the URL. Pairing
        // folds in here: a request carrying a valid `?token=` sets the cookie and
        // 303-redirects to the clean `/`, so the token leaves the address bar and
        // browser history. Subsequent loads (and the WS handshakes) authenticate
        // on the cookie alone. The token stays the single source of truth — the
        // cookie just carries it, so regenerating it invalidates paired browsers.
        let tokenStore = self.tokenStore
        router.get("/") { request, _ -> Response in
            if let queryToken = Self.queryToken(from: request), tokenStore.isValid(queryToken) {
                var headers = HTTPFields()
                headers[.setCookie] = Self.sessionCookie(token: queryToken)
                headers[.location] = "/"
                return Response(status: .seeOther, headers: headers)
            }
            guard tokenStore.isValid(Self.cookieToken(from: request)) else {
                return Response(status: .unauthorized)
            }
            var headers = HTTPFields()
            headers[.contentType] = "text/html; charset=utf-8"
            headers[.connection] = "close"   // see pageConnectionNote
            return Response(status: .ok, headers: headers,
                            body: .init(byteBuffer: ByteBuffer(string: ClientAssets.html)))
        }

        // GET /client.js — the client script. NOT token-gated: the browser
        // fetches it from the page's <script> tag without the token query, and
        // it carries no secrets (the access token lives only in the URL the user
        // opens). Every privileged endpoint (/ws, /input) stays token-gated.
        router.get("/client.js") { _, _ -> Response in
            var headers = HTTPFields()
            headers[.contentType] = "application/javascript; charset=utf-8"
            headers[.connection] = "close"   // see pageConnectionNote
            return Response(status: .ok, headers: headers,
                            body: .init(byteBuffer: ByteBuffer(string: ClientAssets.js)))
        }

        // GET /ws — token-gated WebSocket upgrade.
        router.ws(
            "/ws",
            shouldUpgrade: { request, _ in
                // Auth via the session cookie (sent automatically on the handshake)
                // or a token query as a fallback. Refuse the upgrade otherwise.
                guard tokenStore.isValid(Self.authToken(from: request)) else { return .dontUpgrade }
                return .upgrade(HTTPFields())
            },
            onUpgrade: { [weak self] inbound, outbound, _ in
                guard let self else { return }
                await self.handleMediaConnection(inbound: inbound, outbound: outbound)
            }
        )

        // GET /audio — audio only, on its own socket. Sharing the video socket
        // meant every sample queued behind whatever keyframe happened to be in
        // flight, and a congested video queue shed audio buffers as clicks.
        router.ws(
            "/audio",
            shouldUpgrade: { request, _ in
                guard tokenStore.isValid(Self.authToken(from: request)) else { return .dontUpgrade }
                return .upgrade(HTTPFields())
            },
            onUpgrade: { [weak self] inbound, outbound, _ in
                guard let self else { return }
                await self.handleAudioConnection(inbound: inbound, outbound: outbound)
            }
        )

        // GET /input — a SEPARATE token-gated WebSocket carrying only input,
        // clipboard, ping/pong and control. Keeping it off the video socket
        // means clicks/keys never queue behind video frames (TCP is one ordered
        // stream), and RTT measured here reflects true input latency.
        router.ws(
            "/input",
            shouldUpgrade: { request, _ in
                guard tokenStore.isValid(Self.authToken(from: request)) else { return .dontUpgrade }
                return .upgrade(HTTPFields())
            },
            onUpgrade: { [weak self] inbound, outbound, _ in
                guard let self else { return }
                await self.handleInputConnection(inbound: inbound, outbound: outbound)
            }
        )

        // TLS over HTTP/1 with WebSocket upgrade.
        let tlsConfig = try Self.makeTLSConfig(certPath: config.certPath, keyPath: config.keyPath)

        let app = Application(
            router: router,
            server: try .tls(.http1WebSocketUpgrade(webSocketRouter: router), tlsConfiguration: tlsConfig),
            configuration: .init(
                address: .hostname(config.bindAddress, port: config.port),
                serverName: "SameDesk"
            ),
            onServerRunning: { channel in
                // Darwin copies the listening socket's buffer sizes onto every
                // accepted socket, so setting it once here covers all clients.
                // Best-effort: if the option is refused we lose signal quality,
                // not correctness — the shallow per-client queue and the
                // stale-write purge still bound how far behind a client can get.
                do {
                    try await channel.setOption(ChannelOptions.socketOption(.so_sndbuf),
                                                value: SameDeskServer.sendBufferBytes).get()
                } catch {
                    NSLog("SameDesk: could not set SO_SNDBUF: \(error)")
                }
            }
        )

        serverTask = Task {
            try await app.runService()
        }
    }

    /// Stop the listener and WAIT for it to fully release the socket before
    /// returning, so a subsequent restart can rebind the same port without a
    /// "Already closed" / bind race.
    func stop() async {
        serverTask?.cancel()
        _ = try? await serverTask?.value
        serverTask = nil
    }

    // MARK: - Connection lifecycle

    /// Video/audio connection: drains the broadcaster's per-client queue to the
    /// socket. The client sends nothing here; we still read inbound to detect
    /// close.
    private func handleMediaConnection(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        let client = ClientConnection()
        let broadcaster = self.broadcaster
        // First frame on this socket: tell the client which codec to set up.
        // Enqueued BEFORE broadcaster.add() can push any binary init segment, so
        // the client always learns the codec before the first fragment arrives.
        client.enqueue(.text(OutboundMessage.config(codec: codecProvider()).jsonString()), isMedia: false)
        await broadcaster.add(client)
        defer { Task { await broadcaster.remove(client.id) } }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var previousWasKeyframe = false
                while let item = await client.next() {
                    // How long this frame waited for the previous write to be
                    // accepted by the kernel: queueing delay on the link, the
                    // signal the bitrate controller runs on. Measured BEFORE the
                    // write so a frame's own transmission time does not count —
                    // a keyframe legitimately takes 100 ms+ to push over Wi-Fi.
                    let waited = MonotonicClock.now - item.enqueuedAt
                    do {
                        switch item.frame {
                        case .binary(let data):
                            try await outbound.write(.binary(ByteBuffer(data: data)))
                        case .text(let text):
                            try await outbound.write(.text(text))
                        }
                    } catch {
                        break // socket dead; drop this client
                    }
                    guard item.isMedia else { continue }
                    // The frame behind a keyframe waited for the keyframe's bytes,
                    // not for a congested link. Counting it would make every
                    // keyframe read as congestion, cut bitrate, and ask for
                    // another keyframe — a storm that ends in a blurry stream.
                    let followsKeyframe = previousWasKeyframe
                    previousWasKeyframe = item.isKeyframe
                    if !followsKeyframe { client.recordQueueDelay(waited) }
                }
            }
            group.addTask {
                do { for try await _ in inbound.messages(maxSize: 1 << 20) {} } catch {}
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Audio connection: write-only, and deliberately independent of the video
    /// stream's keyframe state and congestion handling.
    private func handleAudioConnection(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        let client = ClientConnection()
        let broadcaster = self.broadcaster
        await broadcaster.addAudio(client)
        defer { Task { await broadcaster.removeAudio(client.id) } }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let item = await client.next() {
                    do {
                        if case .binary(let data) = item.frame {
                            try await outbound.write(.binary(ByteBuffer(data: data)))
                        }
                    } catch {
                        break
                    }
                }
            }
            group.addTask {
                do { for try await _ in inbound.messages(maxSize: 1 << 20) {} } catch {}
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Input/control connection: reads input/clipboard/ping/bitrate from the
    /// client and writes pong/clipboard/reload back. Registered as an "input
    /// client" so downstream control (clipboard, reload) reaches it.
    private func handleInputConnection(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        let client = ClientConnection()
        await broadcaster.addInput(client)
        defer { Task { await broadcaster.removeInput(client.id) } }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let item = await client.next() {
                    do {
                        if case .text(let text) = item.frame {
                            try await outbound.write(.text(text))
                        }
                    } catch {
                        break
                    }
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                do {
                    for try await message in inbound.messages(maxSize: 1 << 20) {
                        if case .text(let text) = message {
                            await self.handleText(text, client: client)
                        }
                    }
                } catch {
                    // connection closed
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func handleText(_ text: String, client: ClientConnection) async {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(InputMessage.self, from: data) else { return }

        switch message.type {
        case .ping:
            let pong = OutboundMessage.pong(message.t).jsonString()
            client.enqueue(.text(pong), isMedia: false)
        case .clipboard:
            if let clip = message.text {
                onClipboard?(clip)
                // Mirror to other clients so all sessions stay in sync.
                await broadcaster.broadcastText(OutboundMessage.clipboard(clip).jsonString(), except: client.id)
            }
        case .keyframe:
            onRequestKeyframe?()
        case .viewport:
            if let width = message.w, let height = message.h {
                onViewport?(client.id, width, height)
            }
        case .bitrate, .pong, .unknown:
            // `bitrate` is legacy: quality is now decided server-side from the
            // measured send-queue delay, so a stale cached client asking for a
            // rate can no longer fight the controller.
            break
        default:
            onInput?(message)
        }
    }

    // MARK: - Helpers

    private static func queryToken(from request: Request) -> String? {
        request.uri.queryParameters["token"].map(String.init)
    }

    /// Auth credential for the WebSocket upgrades: the session cookie (the common
    /// case after pairing), or a token query as a fallback (e.g. a non-browser
    /// client connecting directly).
    private static func authToken(from request: Request) -> String? {
        cookieToken(from: request) ?? queryToken(from: request)
    }

    private static func cookieToken(from request: Request) -> String? {
        sessionToken(fromCookieHeader: request.headers[.cookie])
    }

    /// Extract the `sd_session` value from a raw `Cookie:` header. Pure (no
    /// `Request` dependency) so it's unit-testable.
    static func sessionToken(fromCookieHeader header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0] == "sd_session" else { continue }
            return kv[1]
        }
        return nil
    }

    /// The pairing cookie. HttpOnly (JS/XSS can't read it), Secure (TLS-only),
    /// SameSite=Strict (never sent cross-site). No Max-Age, so it's a session
    /// cookie — closing the browser clears it; re-open the tokenized URL to pair
    /// again. The token is URL-safe base64, so it needs no cookie escaping.
    static func sessionCookie(token: String) -> String {
        "sd_session=\(token); Path=/; Secure; HttpOnly; SameSite=Strict"
    }

    private static func makeTLSConfig(certPath: String, keyPath: String) throws -> TLSConfiguration {
        let certs = try NIOSSLCertificate.fromPEMFile(certPath).map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: certs, privateKey: .privateKey(key))
        config.applicationProtocols = ["http/1.1"]
        return config
    }
}
