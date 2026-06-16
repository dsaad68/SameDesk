import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// One encoded frame, as length-prefixed NAL units (AVCC for H.264, HVCC for
/// HEVC — both length-prefixed, exactly what the fMP4 muxer needs, no Annex-B
/// conversion).
struct EncodedFrame {
    let avccData: Data
    let isKeyframe: Bool
    /// Presentation timestamp from the capture sample buffer.
    let pts: CMTime
    /// Only populated on keyframes — carries the parameter sets / config record
    /// + dimensions for the muxer to (re)build its init segment.
    let formatDescription: CMFormatDescription?
}

/// Video codec selection.
enum VideoCodec {
    case h264
    case hevc

    var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    var profileLevel: CFString {
        switch self {
        // High/auto for H.264; Main/auto for HEVC (8-bit 4:2:0, broadest
        // hardware-decode support including Safari + WebCodecs).
        case .h264: return kVTProfileLevel_H264_High_AutoLevel
        case .hevc: return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }
}

/// VideoToolbox video encoder, real-time, no B-frames. Encodes H.264 (High,
/// auto-level) or HEVC/H.265 (Main, auto-level — ~2x compression, so sharper at
/// the same bitrate). HEVC falls back to H.264 if the hardware can't encode it.
///
/// Concurrency: `encode(...)` is meant to be called synchronously from the
/// `SCStreamOutput` callback. A single in-flight flag drops frames while the
/// encoder is busy so we never backlog. Finished frames are delivered on the
/// VideoToolbox output thread via `onEncodedFrame`.
final class H264Encoder {
    /// Delivered on VideoToolbox's output thread. Keep the handler cheap; it
    /// should hand off to the muxer/broadcaster and return.
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0

    /// Requested codec, and the one actually in use after any HEVC->H.264
    /// fallback. The muxer/client detect the real codec from the encoded format,
    /// so this is informational.
    private let requestedCodec: VideoCodec
    private(set) var effectiveCodec: VideoCodec

    /// True while a frame is being encoded. Guarded by an unfair lock so the
    /// capture thread can test-and-skip cheaply.
    private let inFlight = OSAllocatedUnfairLock(initialState: false)

    /// Set when a new client connects: the next submitted frame is forced to be
    /// an IDR so new clients sync immediately without periodic-IDR bitrate spikes.
    private let forceKeyframeFlag = OSAllocatedUnfairLock(initialState: false)

    private var bitrate: Int

    init(bitrate: Int, codec: VideoCodec = .h264) {
        self.bitrate = bitrate
        self.requestedCodec = codec
        self.effectiveCodec = codec
    }

    deinit { invalidate() }

    var isEncoding: Bool {
        inFlight.withLock { $0 }
    }

    /// Request that the next encoded frame be a keyframe (IDR).
    func requestKeyframe() {
        forceKeyframeFlag.withLock { $0 = true }
    }

    /// Update target bitrate live (menu change). Cheap — sets the property on the
    /// running session.
    func setBitrate(_ bps: Int) {
        bitrate = bps
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bps))
        // Allow generous short-term bursts (2x over 1s) so keyframes and motion
        // scenes aren't hard-throttled — a tight cap starves them and shows up
        // as quality drops / stutter. The per-client drop-oldest queues absorb
        // any burst the LAN can't take instantly.
        let limits = [bps / 4, 1] as CFArray   // up to bps*2 bits over 1s
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    // MARK: - Session lifecycle

    private func ensureSession(width: Int32, height: Int32) -> VTCompressionSession? {
        if let session, self.width == width, self.height == height {
            return session
        }
        invalidate()

        func create(_ codec: VideoCodec) -> (OSStatus, VTCompressionSession?) {
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: codec.cmCodecType,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,     // using the block-based EncodeFrame variant
                refcon: nil,
                compressionSessionOut: &s
            )
            return (st, s)
        }

        var (status, newSession) = create(requestedCodec)
        if status != noErr || newSession == nil, requestedCodec == .hevc {
            // Hardware can't encode HEVC here — fall back to H.264.
            NSLog("SameDesk: HEVC encode unavailable (\(status)); falling back to H.264.")
            effectiveCodec = .h264
            (status, newSession) = create(.h264)
        } else {
            effectiveCodec = requestedCodec
        }
        guard status == noErr, let session = newSession else {
            NSLog("SameDesk: VTCompressionSessionCreate failed: \(status)")
            return nil
        }

        configure(session)
        self.session = session
        self.width = width
        self.height = height
        return session
    }

    private func configure(_ session: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // No B-frames: zero added latency, and NALs stay in decode order.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // Emit each frame as soon as it's encoded — no look-ahead buffering.
        // This is the single biggest motion-to-photon latency lever.
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1))
        // H.264 High / HEVC Main, both auto-level. (Baseline 3.0 caps at ~720p
        // and would break on a normal Mac display; these also compress better.)
        set(kVTCompressionPropertyKey_ProfileLevel, effectiveCodec.profileLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 4, 1] as CFArray)
        // Effectively NO periodic IDRs: a periodic keyframe is many× larger than
        // a P-frame and spikes the bitrate, causing a regular hiccup (was ~every
        // 240 frames ≈ 4–6s). We instead force a keyframe on demand — on connect,
        // and when a client reports a decode error (see keyframe-request path).
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 600_000))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 600.0))
        // H.264 entropy: CABAC is allowed by High profile and compresses better.
        // (HEVC has no equivalent property; CABAC is mandatory there.)
        if effectiveCodec == .h264 {
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 60))

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        width = 0
        height = 0
    }

    // MARK: - Encode

    /// Submit a frame. Returns immediately. Drops the frame if the encoder is
    /// still busy with the previous one (never backlogs).
    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        // Drop if busy.
        let shouldEncode = inFlight.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard shouldEncode else { return }

        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard let session = ensureSession(width: w, height: h) else {
            inFlight.withLock { $0 = false }
            return
        }

        var frameProps: CFDictionary?
        if forceKeyframeFlag.withLock({ flag -> Bool in
            defer { flag = false }
            return flag
        }) {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            defer { self.inFlight.withLock { $0 = false } }
            guard status == noErr, let sampleBuffer else { return }
            self.handleEncoded(sampleBuffer)
        }

        if status != noErr {
            inFlight.withLock { $0 = false }
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { return }

        let avcc = Data(bytes: dataPointer, count: totalLength)
        let isKeyframe = Self.sampleIsKeyframe(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let format = isKeyframe ? CMSampleBufferGetFormatDescription(sampleBuffer) : nil

        onEncodedFrame?(EncodedFrame(avccData: avcc, isKeyframe: isKeyframe, pts: pts, formatDescription: format))
    }

    private static func sampleIsKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else {
            return true // no attachments -> treat as sync
        }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        // A sync sample (keyframe) is one where kCMSampleAttachmentKey_NotSync
        // is absent or false.
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        if let raw = CFDictionaryGetValue(dict, key) {
            let notSync = unsafeBitCast(raw, to: CFBoolean.self)
            return !CFBooleanGetValue(notSync)
        }
        return true
    }
}
