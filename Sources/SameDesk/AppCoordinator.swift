import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import os

/// Wires the whole app together: security pre-flight, cert minting, the
/// capture→encode→mux→broadcast pipeline, the server, and input/clipboard.
///
/// Lives on the main actor for UI-facing state; the hot media path runs off it
/// (see the ordered consumer task below and the encoder's own threads).
@MainActor
final class AppCoordinator {
    // Security / identity
    private let tokenStore = TokenStore.shared
    private let certManager = CertificateManager()

    // Pipeline
    private let broadcaster = Broadcaster()
    private var encoder: H264Encoder?
    private let muxer = FMP4Muxer()
    private var capturer: ScreenCapturer?
    private var frameConsumer: Task<Void, Never>?
    private var audioConsumer: Task<Void, Never>?
    /// Latest MSE codec string, written by the consumer task and read (sync) by
    /// the page handler. Locked because those run in different domains.
    private let codecHolder = OSAllocatedUnfairLock(initialState: "avc1.640033")

    // Input / clipboard
    private let inputController = InputController()
    private let clipboard = ClipboardSync()

    // Virtual display
    private let virtualDisplay = VirtualDisplayManager()
    private var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    // Server
    private var server: SameDeskServer?

    // Surfaced state for the menu.
    private(set) var advertisedHost: String = ""
    /// The Mac's `.local` name, offered as an alternative (IPv6-free LANs only).
    private(set) var alternateHost: String?
    private(set) var bindAddress: String = ""
    private(set) var securitySummary: String = "Not started"
    private(set) var isRunning = false

    /// Last capture / server failure, surfaced in diagnostics. Cleared on a fresh
    /// start; set when the corresponding pipeline stage throws.
    private(set) var lastCaptureError: String?
    private(set) var lastServerError: String?

    /// Observers notified whenever surfaced state changes (menu + settings UI).
    private var stateObservers: [() -> Void] = []

    func addStateObserver(_ observer: @escaping () -> Void) {
        stateObservers.append(observer)
    }

    // MARK: - Public actions

    func start() {
        Task { await startAsync() }
    }

    func startAsync() async {
        guard !isRunning else { return }
        lastCaptureError = nil
        lastServerError = nil

        // 1. Permissions.
        guard await Permissions.ensureScreenRecording() else {
            securitySummary = "Screen Recording permission required"
            notify()
            return
        }
        Permissions.ensureAccessibility(prompt: true)

        // 2. Headless / virtual display.
        if Settings.shared.headlessVirtualDisplay && VirtualDisplayManager.hasNoPhysicalDisplay {
            if let id = virtualDisplay.createIfNeeded() {
                activeDisplayID = id
            } else {
                // Private API unavailable — fall back to whatever display exists.
                activeDisplayID = CGMainDisplayID()
            }
        } else {
            activeDisplayID = CGMainDisplayID()
        }
        inputController.targetDisplayID = activeDisplayID

        // 3. Resolve LAN IPv4 + run the lockdown pre-flight.
        guard let iface = NetworkLockdown.primaryInterface() else {
            securitySummary = "No LAN IPv4 interface found"
            notify()
            return
        }
        bindAddress = iface.ipv4
        let preflight = NetworkLockdown.preflight(bindAddress: iface.ipv4, interfaceName: iface.name)
        securitySummary = preflight.summary
        guard preflight.safe else {
            // Refuse to start if we'd be reachable on a global address.
            presentBlockingAlert(title: "SameDesk refused to start",
                                 message: preflight.failureReason ?? preflight.summary)
            notify()
            return
        }

        // 4. TLS certificate (mkcert). We bind IPv4-only (a hard security
        //    requirement), so the canonical, always-reliable address is the LAN
        //    IPv4 — that's what Copy URL hands out. We still mint the cert for
        //    the Mac's real `.local` name and `samedesk.local` as SANs so users
        //    on an IPv6-free LAN can connect by name (a `.local` name resolves
        //    to BOTH IPv4 and IPv6; browsers prefer IPv6 via Happy Eyeballs, and
        //    nothing answers there because we don't bind IPv6 — hence IP first).
        let resolvableHost = Hostname.resolvableLocalHost
        let primaryHost = iface.ipv4
        let sanHosts = [resolvableHost, "samedesk.local"].compactMap { $0 }
        let identity: CertificateManager.Identity
        do {
            identity = try certManager.ensureCertificate(forIPv4: iface.ipv4,
                                                         hostnames: sanHosts,
                                                         primaryHost: primaryHost)
        } catch {
            presentBlockingAlert(title: "Certificate error", message: "\(error)")
            notify()
            return
        }
        advertisedHost = identity.localHostname
        alternateHost = resolvableHost

        // 5. Encoder + ordered consumer pipeline.
        let encoder = H264Encoder(bitrate: Settings.shared.bitrateBps,
                                  codec: Settings.shared.useHEVC ? .hevc : .h264)
        self.encoder = encoder
        startFrameConsumer(encoder: encoder)

        // 6. Capture.
        let capturer = ScreenCapturer(encoder: encoder)
        capturer.deltaEncodingEnabled = Settings.shared.deltaEncoding
        capturer.audioEnabled = Settings.shared.audioEnabled
        if Settings.shared.downscaleEnabled {
            capturer.downscale = Settings.shared.downscaleSize
        }
        self.capturer = capturer
        startAudioConsumer(capturer: capturer)
        do {
            try await capturer.start(displayID: activeDisplayID)
        } catch {
            lastCaptureError = "\(error)"
            presentBlockingAlert(title: "Capture error", message: "\(error)")
            notify()
            return
        }

        // A new client needs an IDR to sync. Request a forced keyframe and also
        // re-emit the cached frame, so a client connecting to an idle screen
        // (delta encoding skips unchanged frames) still gets video.
        await broadcaster.setKeyframeRequester { [weak encoder, weak capturer] in
            encoder?.requestKeyframe()
            capturer?.emitKeyframeFromCache()
        }

        // 7. Input + clipboard wiring.
        clipboard.onLocalChange = { [weak self] text in
            guard let self else { return }
            Task { await self.broadcaster.broadcastText(OutboundMessage.clipboard(text).jsonString()) }
        }
        clipboard.start()

        // 8. Server.
        let codecHolder = self.codecHolder
        let server = SameDeskServer(broadcaster: broadcaster, tokenStore: tokenStore,
                                    codecProvider: { codecHolder.withLock { $0 } })
        server.onInput = { [weak self] msg in self?.inputController.handle(msg) }
        server.onClipboard = { [weak self] text in self?.clipboard.applyRemoteText(text) }
        server.onRequestKeyframe = { [weak encoder, weak capturer] in
            encoder?.requestKeyframe()
            capturer?.emitKeyframeFromCache()
        }
        server.onSetBitrate = { [weak self] mbps in
            // Connection auto-tune: clamp to a sane window and apply live. We do
            // NOT persist this (it's transient adaptation, not a user setting).
            let bps = Int(min(max(mbps, 0.5), 40) * 1_000_000)
            Task { @MainActor in self?.encoder?.setBitrate(bps) }
        }
        do {
            try server.start(config: .init(bindAddress: iface.ipv4, port: Settings.shared.port,
                                           certPath: identity.certURL.path, keyPath: identity.keyURL.path))
        } catch {
            lastServerError = "\(error)"
            presentBlockingAlert(title: "Server error", message: "\(error)")
            notify()
            return
        }
        self.server = server

        isRunning = true
        notify()
    }

    func stop() {
        Task { await stopAsync() }
    }

    func stopAsync() async {
        await server?.stop(); server = nil
        clipboard.stop()
        await capturer?.stop(); capturer = nil
        frameConsumer?.cancel(); frameConsumer = nil
        audioConsumer?.cancel(); audioConsumer = nil
        encoder?.invalidate(); encoder = nil
        virtualDisplay.tearDown()
        muxer.reset()
        isRunning = false
        notify()
    }

    /// Restart the listener (e.g. after a settings change). Tells connected
    /// browsers to reload first — so they recover automatically instead of
    /// needing a manual refresh. `navigateURL` is passed when the port changed
    /// (the old URL is stale); otherwise clients just reload their current URL.
    func restart(navigateURL: String? = nil) {
        Task {
            // Ask clients to reload, then give the message a moment to flush
            // before we tear the listener down.
            let msg = OutboundMessage(type: "reload", text: navigateURL, t: nil, s: nil).jsonString()
            await broadcaster.broadcastText(msg)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await stopAsync()
            await startAsync()
        }
    }

    // MARK: - Menu-driven settings

    func regenerateToken() {
        tokenStore.regenerate()
        notify()
    }

    func setPort(_ port: Int) {
        Settings.shared.port = port
        // Port changed -> the old URL is stale, so send clients the new one.
        restart(navigateURL: fullURLWithToken)
    }

    func setBitrate(_ bps: Int) {
        Settings.shared.bitrateBps = bps
        encoder?.setBitrate(bps)
        notify()
    }

    func setDeltaEncoding(_ on: Bool) {
        Settings.shared.deltaEncoding = on
        capturer?.deltaEncodingEnabled = on   // live
        notify()
    }

    func setHeadless(_ on: Bool) {
        Settings.shared.headlessVirtualDisplay = on
        // Requires a capture restart to (de)allocate the virtual display.
        if isRunning { restart() } else { notify() }
    }

    func setHEVC(_ on: Bool) {
        Settings.shared.useHEVC = on
        // Changing the codec needs a fresh encoder + init segment, so restart.
        if isRunning { restart() } else { notify() }
    }

    func setAudio(_ on: Bool) {
        Settings.shared.audioEnabled = on
        // capturesAudio is fixed at stream creation, so restart to apply.
        if isRunning { restart() } else { notify() }
    }

    /// Set the capture downscale target. `nil` disables downscaling (native
    /// capture). The downscale is wired into the capturer at stream creation, so
    /// changing it restarts the pipeline.
    func setDownscale(_ size: (width: Int, height: Int)?) {
        if let size {
            Settings.shared.downscaleEnabled = true
            Settings.shared.downscaleSize = size
        } else {
            Settings.shared.downscaleEnabled = false
        }
        if isRunning { restart() } else { notify() }
    }

    // MARK: - Surfaced values

    var token: String { tokenStore.token }

    /// Whether mkcert is installed (surfaced in onboarding).
    var isMkcertInstalled: Bool { certManager.isMkcertInstalled }

    var displayHost: String {
        // Canonical address is the LAN IPv4 we bind (reliable; IPv6-safe).
        advertisedHost.isEmpty ? bindAddress : advertisedHost
    }

    var baseURL: String {
        "https://\(displayHost):\(Settings.shared.port)"
    }

    var fullURLWithToken: String {
        "\(baseURL)/?token=\(token)"
    }

    /// The `.local` variant, for users on an IPv6-free LAN. nil if unavailable.
    var alternateURLWithToken: String? {
        guard let alternateHost else { return nil }
        return "https://\(alternateHost):\(Settings.shared.port)/?token=\(token)"
    }

    func copyURLToPasteboard() { copyToPasteboard(fullURLWithToken) }

    func copyAlternateURLToPasteboard() {
        if let url = alternateURLWithToken { copyToPasteboard(url) }
    }

    /// Whether the tokenized URL can be shared via AirDrop right now.
    var canAirDropURL: Bool {
        guard isRunning, let url = URL(string: fullURLWithToken) else { return false }
        return NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: [url]) ?? false
    }

    /// Share the full tokenized URL (recipient gets a clickable link) via the
    /// system AirDrop sharing service.
    func shareURLViaAirDrop() {
        guard let url = URL(string: fullURLWithToken),
              let service = NSSharingService(named: .sendViaAirDrop) else { return }
        // A menu-bar (accessory) app isn't active; AirDrop's picker needs the
        // app frontmost to present.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    // MARK: - Diagnostics

    /// Copy a one-shot diagnostics snapshot to the pasteboard (menu + Settings).
    func copyDiagnosticsToPasteboard() async {
        await copyToPasteboard(diagnosticsReport())
    }

    /// A plain-text snapshot of everything useful for debugging a connection: the
    /// bind/URL, codec/bitrate/display, permission + cert state, client count, and
    /// the last capture/server error. Deliberately token-free so it's safe to share.
    func diagnosticsReport() async -> String {
        let clients = await broadcaster.clientCount
        let (dw, dh) = displayPixelSize()
        let codec = codecHolder.withLock { $0 }
        let port = Settings.shared.port
        let bitrateMbps = Double(Settings.shared.bitrateBps) / 1_000_000
        let downscale = Settings.shared.downscaleEnabled
            ? "\(Settings.shared.downscaleSize.width)×\(Settings.shared.downscaleSize.height)" : "off"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let iso = ISO8601DateFormatter()

        let certLine: String
        if let minted = certManager.certificateMintedAt {
            let days = Int(Date().timeIntervalSince(minted) / 86_400)
            certLine = "minted \(days)d ago (\(iso.string(from: minted)))"
        } else {
            certLine = "none minted yet"
        }
        func mark(_ ok: Bool) -> String { ok ? "granted" : "MISSING" }

        return """
        SameDesk diagnostics — \(iso.string(from: Date()))

        Server:    \(isRunning ? "running" : "stopped")
        Bind:      \(bindAddress.isEmpty ? "—" : bindAddress):\(port)
        Status:    \(securitySummary)
        URL:       \(baseURL)
        Clients:   \(clients) connected

        Codec:     \(Settings.shared.useHEVC ? "HEVC" : "H.264") (\(codec))
        Bitrate:   \(String(format: "%.0f", bitrateMbps)) Mbps target
        Delta:     \(Settings.shared.deltaEncoding ? "on" : "off")
        Display:   \(dw)×\(dh)  (downscale: \(downscale))
        Audio:     \(Settings.shared.audioEnabled ? "on" : "off")

        Screen Recording: \(mark(Permissions.hasScreenRecording))
        Accessibility:    \(mark(Permissions.hasAccessibility))
        TLS cert:  \(certLine)

        Last capture error: \(lastCaptureError ?? "—")
        Last server error:  \(lastServerError ?? "—")

        App:       SameDesk \(version) · \(ProcessInfo.processInfo.operatingSystemVersionString) · arm64
        """
    }

    /// Native pixel dimensions of the display we capture (falls back to point size).
    private func displayPixelSize() -> (Int, Int) {
        guard let mode = CGDisplayCopyDisplayMode(activeDisplayID) else {
            return (CGDisplayPixelsWide(activeDisplayID), CGDisplayPixelsHigh(activeDisplayID))
        }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    // MARK: - Internals

    private func startAudioConsumer(capturer: ScreenCapturer) {
        // Ordered handoff from the audio capture queue to the broadcaster actor,
        // so audio buffers reach clients in capture order (avoids clicks). Drops
        // oldest under congestion.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(16))
        capturer.onAudio = { payload in continuation.yield(payload) }
        let broadcaster = self.broadcaster
        audioConsumer = Task.detached {
            for await payload in stream { await broadcaster.broadcastAudio(payload) }
        }
    }

    private func startFrameConsumer(encoder: H264Encoder) {
        // Ordered handoff from the VideoToolbox output thread to a single
        // consumer that owns the muxer and awaits the broadcaster in order.
        let (stream, continuation) = AsyncStream<EncodedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(8))
        encoder.onEncodedFrame = { frame in continuation.yield(frame) }

        let muxer = self.muxer
        let broadcaster = self.broadcaster
        let codecHolder = self.codecHolder
        frameConsumer = Task.detached {
            for await frame in stream {
                if frame.isKeyframe, let fmt = frame.formatDescription {
                    muxer.updateParameterSets(from: fmt)
                    codecHolder.withLock { $0 = muxer.codecString }
                }
                guard muxer.isReady else { continue }
                let fragment = muxer.buildFragment(avccData: frame.avccData,
                                                   isKeyframe: frame.isKeyframe, pts: frame.pts)
                // On a keyframe, hand a fresh init segment along so the
                // broadcaster can lazily deliver it to newly-connected clients.
                let initSeg: Data? = frame.isKeyframe ? muxer.buildInitSegment() : nil
                let captureTimeMs = Date().timeIntervalSince1970 * 1000
                await broadcaster.broadcast(fragment: fragment, isKeyframe: frame.isKeyframe,
                                            initSegment: initSeg, captureTimeMs: captureTimeMs)
            }
        }
    }

    private func notify() { for observer in stateObservers { observer() } }

    private func presentBlockingAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
