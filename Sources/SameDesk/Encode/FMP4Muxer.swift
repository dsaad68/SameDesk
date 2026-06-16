import CoreMedia
import Foundation

/// Minimal hand-rolled fragmented-MP4 (ISO-BMFF) muxer, codec-agnostic over
/// H.264 and HEVC.
///
/// MSE's `SourceBuffer` (and the WebCodecs demux on the client) need fMP4 / a
/// decoder config record — not bare NAL units. So we build:
///   - an **init segment** (`ftyp` + `moov`) once we have the codec config from
///     the first IDR. The `moov` carries an `avc1`/`avcC` (H.264) or
///     `hvc1`/`hvcC` (HEVC) sample entry, taken straight from VideoToolbox's
///     format-description extension atoms.
///   - a **media fragment** (`moof` + `mdat`) per encoded frame, reusing the
///     length-prefixed NALs verbatim in the `mdat`.
///
/// There is no off-the-shelf Swift package for this, hence the from-scratch
/// box writer below. Only the boxes a browser actually needs are emitted.
final class FMP4Muxer {
    static let timescale: UInt32 = 90_000   // 90 kHz, standard for video
    private let trackID: UInt32 = 1

    private var sequenceNumber: UInt32 = 0
    private var baseMediaDecodeTime: UInt64 = 0
    private var lastPTS: CMTime?

    enum SampleCodec { case h264, hevc }

    // Cached codec config record + dimensions, refreshed on each keyframe.
    private(set) var codec: SampleCodec = .h264
    /// The decoder configuration record bytes (avcC for H.264, hvcC for HEVC),
    /// pulled directly from the encoded format description's extension atoms.
    private var configRecord: Data = Data()
    private(set) var width: Int32 = 0
    private(set) var height: Int32 = 0

    /// True once we have a config record and dimensions (can build init segment).
    var isReady: Bool { !configRecord.isEmpty && width > 0 }

    /// Refresh the codec config from a keyframe's format description. Returns
    /// true if it changed (init segment must be rebuilt/resent).
    ///
    /// We read the ready-made `avcC`/`hvcC` atom that VideoToolbox attaches,
    /// rather than parsing parameter sets by hand — robust for both codecs and
    /// self-describing (the presence of `hvcC` tells us it's HEVC).
    @discardableResult
    func updateParameterSets(from format: CMFormatDescription) -> Bool {
        guard let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else { return false }

        let newCodec: SampleCodec
        let record: Data
        if let hvcC = atoms["hvcC"] as? Data {
            newCodec = .hevc; record = hvcC
        } else if let avcC = atoms["avcC"] as? Data {
            newCodec = .h264; record = avcC
        } else {
            return false
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let changed = record != configRecord || newCodec != codec
            || dims.width != width || dims.height != height
        configRecord = record
        codec = newCodec
        width = dims.width
        height = dims.height
        return changed
    }

    /// The MSE/WebCodecs codec string matching the encoded stream.
    var codecString: String {
        switch codec {
        case .h264:
            // avcC: [0]=version, [1]=profile, [2]=compat flags, [3]=level.
            guard configRecord.count >= 4 else { return "avc1.640033" }
            return String(format: "avc1.%02X%02X%02X", configRecord[1], configRecord[2], configRecord[3])
        case .hevc:
            return Self.hevcCodecString(configRecord) ?? "hvc1.1.6.L93.B0"
        }
    }

    /// Build the `hvc1.*` codec string from an hvcC config record per ISO 14496-15.
    private static func hevcCodecString(_ r: Data) -> String? {
        guard r.count >= 13 else { return nil }
        let b1 = r[1]
        let profileSpace = (b1 >> 6) & 0x3
        let tierFlag = (b1 >> 5) & 0x1
        let profileIdc = b1 & 0x1F
        let compat = (UInt32(r[2]) << 24) | (UInt32(r[3]) << 16) | (UInt32(r[4]) << 8) | UInt32(r[5])
        let level = r[12]

        // Compatibility flags are written with reversed bit order.
        var x = compat, rev: UInt32 = 0
        for _ in 0..<32 { rev = (rev << 1) | (x & 1); x >>= 1 }

        let spacePrefix = profileSpace == 0 ? "" : String(UnicodeScalar(UInt8(0x40 + profileSpace)))
        let tierChar = tierFlag == 0 ? "L" : "H"

        // Constraint bytes (6), trailing zero bytes trimmed.
        var cons = Array(r[6..<12])
        while let last = cons.last, last == 0 { cons.removeLast() }
        let consStr = cons.map { String(format: "%02X", $0) }.joined(separator: ".")

        var s = "hvc1.\(spacePrefix)\(profileIdc).\(String(rev, radix: 16, uppercase: true)).\(tierChar)\(level)"
        if !consStr.isEmpty { s += ".\(consStr)" }
        return s
    }

    /// Reset fragment state (used when (re)starting the stream).
    func reset() {
        sequenceNumber = 0
        baseMediaDecodeTime = 0
        lastPTS = nil
    }

    // MARK: - Init segment

    func buildInitSegment() -> Data? {
        guard isReady else { return nil }
        var data = Data()
        data.append(makeFtyp())
        data.append(makeMoov())
        return data
    }

    // MARK: - Media fragment

    /// Wrap one encoded frame (AVCC length-prefixed NALs) as a `moof`+`mdat`
    /// fragment. `duration` is derived from inter-frame PTS deltas.
    func buildFragment(avccData: Data, isKeyframe: Bool, pts: CMTime) -> Data {
        let duration = sampleDuration(for: pts)
        sequenceNumber += 1

        let sampleSize = UInt32(avccData.count)
        let moof = makeMoof(sequenceNumber: sequenceNumber,
                            baseMediaDecodeTime: baseMediaDecodeTime,
                            sampleDuration: duration,
                            sampleSize: sampleSize,
                            isKeyframe: isKeyframe)
        let mdat = box("mdat", avccData)

        baseMediaDecodeTime += UInt64(duration)

        var fragment = Data()
        fragment.append(moof)
        fragment.append(mdat)
        return fragment
    }

    private func sampleDuration(for pts: CMTime) -> UInt32 {
        defer { lastPTS = pts }
        guard let last = lastPTS else {
            return Self.timescale / 60   // assume 60fps for the first frame
        }
        let deltaSeconds = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, last)))
        let ticks = UInt32((deltaSeconds * Double(Self.timescale)).rounded())
        // Clamp to a sane range so a long idle gap (delta encoding) doesn't make
        // the player stall on one enormous sample duration.
        return min(max(ticks, 1), Self.timescale)  // 1 tick .. 1 second
    }

    // MARK: - Box builders

    private func makeFtyp() -> Data {
        var body = Data()
        body.append(fourCC("isom"))               // major brand
        body.append(uint32(0x0000_0200))          // minor version
        body.append(fourCC("isom"))
        body.append(fourCC("iso2"))
        body.append(fourCC("avc1"))
        body.append(fourCC("mp41"))
        return box("ftyp", body)
    }

    private func makeMoov() -> Data {
        var body = Data()
        body.append(makeMvhd())
        body.append(makeTrak())
        body.append(makeMvex())
        return box("moov", body)
    }

    private func makeMvhd() -> Data {
        var b = Data()
        b.append(uint32(0))                       // version + flags
        b.append(uint32(0))                       // creation time
        b.append(uint32(0))                       // modification time
        b.append(uint32(Self.timescale))          // timescale
        b.append(uint32(0))                       // duration (0 = unknown/fragmented)
        b.append(uint32(0x0001_0000))             // rate 1.0
        b.append(uint16(0x0100))                  // volume 1.0
        b.append(uint16(0))                       // reserved
        b.append(uint32(0)); b.append(uint32(0))  // reserved
        b.append(unityMatrix())
        for _ in 0..<6 { b.append(uint32(0)) }    // pre_defined
        b.append(uint32(0xFFFF_FFFF))             // next track ID
        return box("mvhd", b)
    }

    private func makeTrak() -> Data {
        var b = Data()
        b.append(makeTkhd())
        b.append(makeMdia())
        return box("trak", b)
    }

    private func makeTkhd() -> Data {
        var b = Data()
        b.append(uint32(0x0000_0007))             // version 0, flags: enabled|in movie|in preview
        b.append(uint32(0))                       // creation
        b.append(uint32(0))                       // modification
        b.append(uint32(trackID))                 // track ID
        b.append(uint32(0))                       // reserved
        b.append(uint32(0))                       // duration
        b.append(uint32(0)); b.append(uint32(0))  // reserved
        b.append(uint16(0))                       // layer
        b.append(uint16(0))                       // alternate group
        b.append(uint16(0))                       // volume (0 for video)
        b.append(uint16(0))                       // reserved
        b.append(unityMatrix())
        b.append(uint32(UInt32(width) << 16))     // width (16.16 fixed)
        b.append(uint32(UInt32(height) << 16))    // height (16.16 fixed)
        return box("tkhd", b)
    }

    private func makeMdia() -> Data {
        var b = Data()
        b.append(makeMdhd())
        b.append(makeHdlr())
        b.append(makeMinf())
        return box("mdia", b)
    }

    private func makeMdhd() -> Data {
        var b = Data()
        b.append(uint32(0))                       // version + flags
        b.append(uint32(0))                       // creation
        b.append(uint32(0))                       // modification
        b.append(uint32(Self.timescale))          // timescale
        b.append(uint32(0))                       // duration
        b.append(uint16(0x55C4))                  // language 'und'
        b.append(uint16(0))                       // pre_defined
        return box("mdhd", b)
    }

    private func makeHdlr() -> Data {
        var b = Data()
        b.append(uint32(0))                       // version + flags
        b.append(uint32(0))                       // pre_defined
        b.append(fourCC("vide"))                  // handler type
        b.append(uint32(0)); b.append(uint32(0)); b.append(uint32(0)) // reserved
        b.append(Data("SameDesk".utf8))
        b.append(uint8(0))                        // null-terminated name
        return box("hdlr", b)
    }

    private func makeMinf() -> Data {
        var b = Data()
        b.append(makeVmhd())
        b.append(makeDinf())
        b.append(makeStbl())
        return box("minf", b)
    }

    private func makeVmhd() -> Data {
        var b = Data()
        b.append(uint32(0x0000_0001))             // version 0, flags 1
        b.append(uint16(0))                       // graphics mode
        b.append(uint16(0)); b.append(uint16(0)); b.append(uint16(0)) // opcolor
        return box("vmhd", b)
    }

    private func makeDinf() -> Data {
        var dref = Data()
        dref.append(uint32(0))                    // version + flags
        dref.append(uint32(1))                    // entry count
        var url = Data()
        url.append(uint32(0x0000_0001))           // version 0, flags 1 (self-contained)
        dref.append(box("url ", url))
        return box("dinf", box("dref", dref))
    }

    private func makeStbl() -> Data {
        var b = Data()
        b.append(makeStsd())
        b.append(emptyFullBoxWithCount("stts"))   // 0 entries
        b.append(emptyFullBoxWithCount("stsc"))
        b.append(makeStsz())
        b.append(emptyFullBoxWithCount("stco"))
        return box("stbl", b)
    }

    private func makeStsz() -> Data {
        var b = Data()
        b.append(uint32(0))                       // version + flags
        b.append(uint32(0))                       // sample size (0 = per-sample)
        b.append(uint32(0))                       // sample count
        return box("stsz", b)
    }

    private func emptyFullBoxWithCount(_ type: String) -> Data {
        var b = Data()
        b.append(uint32(0))                       // version + flags
        b.append(uint32(0))                       // entry count
        return box(type, b)
    }

    private func makeStsd() -> Data {
        var b = Data()
        b.append(uint32(0))                       // version + flags
        b.append(uint32(1))                       // entry count
        b.append(makeSampleEntry())
        return box("stsd", b)
    }

    private func makeSampleEntry() -> Data {
        var b = Data()
        // SampleEntry header
        for _ in 0..<6 { b.append(uint8(0)) }     // reserved
        b.append(uint16(1))                       // data reference index
        // VisualSampleEntry
        b.append(uint16(0))                       // pre_defined
        b.append(uint16(0))                       // reserved
        for _ in 0..<3 { b.append(uint32(0)) }    // pre_defined
        b.append(uint16(UInt16(width)))           // width
        b.append(uint16(UInt16(height)))          // height
        b.append(uint32(0x0048_0000))             // horiz resolution 72dpi
        b.append(uint32(0x0048_0000))             // vert resolution 72dpi
        b.append(uint32(0))                       // reserved
        b.append(uint16(1))                       // frame count
        // compressor name: 32-byte fixed pascal string
        var name = [UInt8](repeating: 0, count: 32)
        let label = Array((codec == .hevc ? "SameDesk H.265" : "SameDesk H.264").utf8)
        name[0] = UInt8(label.count)
        for (i, c) in label.enumerated() where i + 1 < 32 { name[i + 1] = c }
        b.append(Data(name))
        b.append(uint16(0x0018))                  // depth 24
        b.append(uint16(0xFFFF))                  // pre_defined -1
        // Codec config box: VideoToolbox already gave us the exact avcC/hvcC.
        b.append(box(codec == .hevc ? "hvcC" : "avcC", configRecord))
        return box(codec == .hevc ? "hvc1" : "avc1", b)
    }

    private func makeMvex() -> Data {
        var trex = Data()
        trex.append(uint32(0))                    // version + flags
        trex.append(uint32(trackID))              // track ID
        trex.append(uint32(1))                    // default sample description index
        trex.append(uint32(0))                    // default sample duration
        trex.append(uint32(0))                    // default sample size
        trex.append(uint32(0))                    // default sample flags
        return box("mvex", box("trex", trex))
    }

    // MARK: - Fragment boxes

    private func makeMoof(sequenceNumber: UInt32, baseMediaDecodeTime: UInt64,
                          sampleDuration: UInt32, sampleSize: UInt32, isKeyframe: Bool) -> Data {
        // mfhd
        var mfhd = Data()
        mfhd.append(uint32(0))                    // version + flags
        mfhd.append(uint32(sequenceNumber))

        // traf = tfhd + tfdt + trun
        var tfhd = Data()
        // flags 0x020000 = default-base-is-moof only. Per-sample duration/size/
        // flags are carried in trun, so no default-* fields appear here.
        tfhd.append(uint32(0x0002_0000))
        tfhd.append(uint32(trackID))

        var tfdt = Data()
        tfdt.append(uint32(0x0100_0000))          // version 1
        tfdt.append(uint64(baseMediaDecodeTime))

        // trun: one sample.
        // flags: 0x000001 data-offset, 0x000100 duration, 0x000200 size,
        //        0x000400 flags present.
        var trun = Data()
        let trunFlags: UInt32 = 0x0000_0001 | 0x0000_0100 | 0x0000_0200 | 0x0000_0400
        trun.append(uint32(trunFlags))
        trun.append(uint32(1))                    // sample count
        // data offset is patched after we know the moof size (below).
        let dataOffsetIndex = trun.count
        trun.append(uint32(0))                    // placeholder data offset
        trun.append(uint32(sampleDuration))
        trun.append(uint32(sampleSize))
        // per-sample flags: keyframe => sync (depends_on=2, non_sync=0).
        let sampleFlags: UInt32 = isKeyframe ? 0x0200_0000 : 0x0101_0000
        trun.append(uint32(sampleFlags))

        var traf = Data()
        traf.append(box("tfhd", tfhd))
        traf.append(box("tfdt", tfdt))
        let trunBox = box("trun", trun)
        traf.append(trunBox)
        let trafBox = box("traf", traf)

        var moofBody = Data()
        moofBody.append(box("mfhd", mfhd))
        moofBody.append(trafBox)
        var moof = box("moof", moofBody)

        // Patch trun data_offset = moof size + 8 (mdat header) so it points at
        // the first byte of sample data inside the following mdat.
        let dataOffset = UInt32(moof.count + 8)
        // Locate the data-offset field within the assembled moof:
        // moof(8) + mfhd(box) + traf header(8) + tfhd(box) + tfdt(box) + trun header(8) + flags(4) + count(4)
        let offsetInMoof = 8 + box("mfhd", mfhd).count + 8
            + box("tfhd", tfhd).count + box("tfdt", tfdt).count
            + 8 + dataOffsetIndex
        moof.replaceSubrange(offsetInMoof..<(offsetInMoof + 4), with: uint32(dataOffset))
        return moof
    }

    // MARK: - Primitive byte helpers

    private func box(_ type: String, _ body: Data) -> Data {
        var data = Data()
        data.append(uint32(UInt32(body.count + 8)))
        data.append(fourCC(type))
        data.append(body)
        return data
    }

    private func fourCC(_ s: String) -> Data { Data(s.utf8) }
    private func uint8(_ v: UInt8) -> Data { Data([v]) }
    private func uint16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private func uint32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    private func uint64(_ v: UInt64) -> Data {
        var d = Data()
        d.append(uint32(UInt32((v >> 32) & 0xFFFF_FFFF)))
        d.append(uint32(UInt32(v & 0xFFFF_FFFF)))
        return d
    }
    private func unityMatrix() -> Data {
        var d = Data()
        let m: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        for v in m { d.append(uint32(v)) }
        return d
    }
}
