import AudioToolbox
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import ScreenCaptureKit

/// Captures the main (or a chosen) display via ScreenCaptureKit and feeds frames
/// to the encoder. Frames are dropped when the encoder is busy (no backlog), and
/// optionally skipped entirely when nothing changed (delta encoding).
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let encoder: H264Encoder
    private let sampleQueue = DispatchQueue(label: "com.samedesk.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.samedesk.audio", qos: .userInitiated)

    /// When true, skip encoding frames whose `dirtyRects` is empty / status not
    /// complete (idle screen -> near-zero bandwidth). When false, encode at a
    /// steady cadence.
    var deltaEncodingEnabled: Bool = true

    /// Capture system audio alongside video.
    var audioEnabled: Bool = false

    /// Composite the cursor into the captured frames. Off when the browser draws
    /// the cursor itself (see `CursorTracker`), which is both lower latency and
    /// cheaper — a bare mouse move stops dirtying the frame at all.
    var showsCursor: Bool = true

    /// Delivered for each audio buffer, ready to send on the audio socket:
    /// `[format:1][channels:1][reserved:2][sampleRate:4 BE][interleaved PCM…]`.
    /// The 8-byte header keeps the samples 2- and 4-byte aligned for the client.
    /// Format 1 is Int16; 0 (Float32) is reserved for a client that asks for it.
    var onAudio: ((Data) -> Void)?

    /// Optional downscale (pixel count dominates encode cost).
    var downscale: (width: Int, height: Int)?

    /// Last complete frame, retained so we can re-emit it as a keyframe when a
    /// new client connects while the screen is idle (delta encoding would
    /// otherwise skip every frame, leaving the new client with no video).
    private var lastPixelBuffer: CVPixelBuffer?

    /// Static-screen refinement. Delta encoding skips unchanged frames, which
    /// leaves the LAST frame of a burst of motion — encoded under motion, at
    /// motion quality — frozen on screen. Re-submitting the cached frame a
    /// couple of times once things settle lets the encoder spend a full frame
    /// budget on a near-zero residual, and the text sharpens back up. The frames
    /// cost almost nothing precisely because nothing changed.
    private static let refinementFrames = 2
    private static let settleDelay = 0.08      // motion must have stopped this long
    private static let refinementSpacing = 0.06 // give rate control a fresh budget
    private var refinementsRemaining = 0
    private var lastChangeTime: Double = 0
    private var lastRefinementTime: Double = 0
    private var refinementTimer: DispatchSourceTimer?

    init(encoder: H264Encoder) {
        self.encoder = encoder
        super.init()
    }

    /// Force the cached frame through the encoder as a keyframe. Called when a
    /// client connects so it syncs even on a static screen.
    func emitKeyframeFromCache() {
        sampleQueue.async { [weak self] in
            guard let self, let buffer = self.lastPixelBuffer, !self.encoder.isEncoding else { return }
            self.encoder.requestKeyframe()
            self.encoder.encode(pixelBuffer: buffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    // MARK: - Lifecycle

    func start(displayID: CGDirectDisplayID? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let display: SCDisplay
        if let displayID, let match = content.displays.first(where: { $0.displayID == displayID }) {
            display = match
        } else if let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) {
            display = main
        } else if let first = content.displays.first {
            display = first
        } else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // 4:2:0 is what the hardware encoder consumes. Capturing BGRA made
        // VideoToolbox convert every single frame before it could start work;
        // asking ScreenCaptureKit for 420v hands the encoder what it wants.
        // (Apple's own guidance: BGRA for on-screen display, 420v for encoding.)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // We drop frames when the encoder is full rather than let them back up,
        // so depth is not latency here — it is headroom. It has to cover the
        // frames the encoder holds in flight plus the one we cache for
        // keyframe-on-connect, or ScreenCaptureKit starves waiting for surfaces.
        config.queueDepth = 5
        config.showsCursor = showsCursor

        if let downscale {
            config.width = downscale.width
            config.height = downscale.height
        } else {
            // Capture at the display's POINT resolution by default, capped to a
            // 2560 px long edge. Native Retina backing is ~4x the pixels, which
            // makes the encoder drop frames (stutter) on a busy screen; point
            // resolution is plenty sharp and keeps 60 fps comfortably. Users who
            // want pixel-perfect text can pick a higher downscale size.
            let (w, h) = Self.cappedDimensions(width: display.width, height: display.height, maxEdge: 2560)
            config.width = w
            config.height = h
        }
        config.scalesToFit = true

        if audioEnabled {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true   // don't capture our own output
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if audioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        startRefinementTimer()
    }

    func stop() async {
        refinementTimer?.cancel()
        refinementTimer = nil
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    /// Drives static-screen refinement. A timer rather than the capture callback,
    /// because an idle screen delivers frames at only a frame or two per second —
    /// far too slow to sharpen the picture while the user is still looking at it.
    private func startRefinementTimer() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.refineIfSettled() }
        refinementTimer = timer
        timer.resume()
    }

    /// Runs on `sampleQueue`, so it shares the capture callback's state without
    /// locking.
    private func refineIfSettled() {
        guard deltaEncodingEnabled, refinementsRemaining > 0,
              let buffer = lastPixelBuffer, !encoder.isEncoding else { return }
        let now = MonotonicClock.now
        guard now - lastChangeTime > Self.settleDelay,
              now - lastRefinementTime > Self.refinementSpacing else { return }
        lastRefinementTime = now
        refinementsRemaining -= 1
        encoder.encode(pixelBuffer: buffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Scale dimensions down so the long edge is at most `maxEdge`, preserving
    /// aspect ratio. (Dimensions are forced even so H.264 is happy.)
    static func cappedDimensions(width: Int, height: Int, maxEdge: Int) -> (Int, Int) {
        let longest = max(width, height)
        var w = width, h = height
        if longest > maxEdge {
            let scale = Double(maxEdge) / Double(longest)
            w = Int((Double(width) * scale).rounded())
            h = Int((Double(height) * scale).rounded())
        }
        // Round to even numbers (required by H.264 4:2:0 chroma subsampling).
        return (w - (w % 2), h - (h % 2))
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        if type == .audio { handleAudio(sampleBuffer); return }
        guard type == .screen else { return }

        // Read SCStreamFrameInfo from the attachments.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else {
            return
        }

        // Frame status must be complete; .idle/.blank/.suspended carry no usable
        // pixels and should never be encoded.
        if let statusRaw = attachments[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw) {
            guard status == .complete else { return }
        }

        // Delta encoding: skip frames with no damage. H.264 can't encode
        // arbitrary changed sub-rects as independent regions (that's VNC/RFB) —
        // the real win is (1) skipping unchanged frames entirely, and (2)
        // letting P-frames encode only the changed macroblocks. (1) is here.
        if deltaEncodingEnabled {
            // Use a lenient [Any] cast: the element dictionaries don't always
            // bridge to [String: Any], and a failed cast here would silently
            // gate every frame (near-zero video even when the screen changes).
            let dirtyRects = attachments[.dirtyRects] as? [Any] ?? []
            if dirtyRects.isEmpty { return }
            // Something changed: arm the refinement pass for when it stops.
            lastChangeTime = MonotonicClock.now
            refinementsRemaining = Self.refinementFrames
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Cache the most recent complete frame for keyframe-on-connect re-emit.
        lastPixelBuffer = pixelBuffer

        // Drop if encoder busy — never queue/backlog.
        if encoder.isEncoding { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder.encode(pixelBuffer: pixelBuffer, pts: pts)
    }

    // MARK: - Audio

    /// Convert a ScreenCaptureKit audio buffer (Float32 PCM) into an interleaved
    /// Float32 LE payload with a small header, and hand it to `onAudio`.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let onAudio,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0, channels <= 8 else { return }
        let sampleRate = UInt32(asbd.mSampleRate)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard isFloat, frames > 0 else { return }   // SCK delivers Float32 PCM

        var blockBuffer: CMBlockBuffer?
        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(abl.unsafeMutablePointer) }
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }

        // Build interleaved Int16 [frame0 ch0, frame0 ch1, frame1 ch0, …].
        // Float32 PCM was 3.1 Mbps of uncompressed audio sharing the link with
        // video; 16-bit is half that and indistinguishable for desktop audio.
        // (Opus would be ~25x smaller again — worth doing, but it needs codec
        // negotiation with the client, so it is deliberately not folded in here.)
        var interleaved = [Int16](repeating: 0, count: frames * channels)
        func clamp(_ sample: Float32) -> Int16 {
            Int16(max(-32_768, min(32_767, (sample * 32_767).rounded())))
        }
        if nonInterleaved {
            for ch in 0..<min(channels, abl.count) {
                guard let data = abl[ch].mData else { continue }
                let src = data.bindMemory(to: Float32.self, capacity: frames)
                for f in 0..<frames { interleaved[f * channels + ch] = clamp(src[f]) }
            }
        } else if let data = abl[0].mData {
            let src = data.bindMemory(to: Float32.self, capacity: frames * channels)
            for i in 0..<(frames * channels) { interleaved[i] = clamp(src[i]) }
        }

        // Header: format(1) + channels(1) + reserved(2) + sampleRate(4 BE), then
        // PCM. 8 bytes keeps the samples aligned for a typed-array view.
        var payload = Data(capacity: 8 + interleaved.count * 2)
        payload.append(1)                       // format: Int16
        payload.append(UInt8(channels))
        payload.append(contentsOf: [0, 0])
        payload.append(UInt8((sampleRate >> 24) & 0xFF))
        payload.append(UInt8((sampleRate >> 16) & 0xFF))
        payload.append(UInt8((sampleRate >> 8) & 0xFF))
        payload.append(UInt8(sampleRate & 0xFF))
        interleaved.withUnsafeBytes { payload.append(contentsOf: $0) }
        onAudio(payload)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SameDesk: capture stopped with error: \(error)")
        self.stream = nil
    }

    enum CaptureError: Error { case noDisplay }
}
