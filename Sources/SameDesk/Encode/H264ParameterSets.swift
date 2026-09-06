import Foundation

/// Rewrites an H.264 decoder configuration record so browser decoders emit one
/// frame per chunk we hand them.
///
/// VideoToolbox's hardware H.264 encoder signals `pic_order_cnt_type = 0` and
/// omits the VUI bitstream restriction. With no restriction present a decoder
/// must fall back to the reorder window implied by the level — up to 16 frames —
/// and is entitled to hold decoded pictures back before outputting them, in case
/// a later picture turns out to precede them. Chrome's hardware decoder does
/// exactly that: a fixed 2-16 frame (33-267 ms at 60 fps) latency floor that no
/// amount of network tuning can remove, and one that does not show up anywhere
/// in a bitrate or RTT graph.
///
/// We never emit B-frames (`AllowFrameReordering` is off), so the honest
/// signalling is `max_num_reorder_frames = 0` — the decoder may then output each
/// picture the moment it is decoded. WebRTC solves the same problem the same way
/// in `sps_vui_rewriter.cc`.
///
/// Everything here is total: any malformed or unexpected input returns nil and
/// the caller keeps the encoder's original record. A stream with a few frames of
/// avoidable latency is a far better outcome than one a browser cannot decode.
enum H264ParameterSets {
    /// Rewrite the SPS VUI inside an `avcC` record. Returns nil when the record
    /// already signals no reordering, or when anything about it is unexpected.
    static func rewritingForLowLatencyDecode(_ record: Data) -> Data? {
        let bytes = [UInt8](record)
        // avcC: version(1) profile(1) compat(1) level(1) lengthSize(1) numSPS(1)
        // then [uint16 length + SPS]..., then the PPS list.
        guard bytes.count > 6, bytes[0] == 1 else { return nil }
        let spsCount = Int(bytes[5] & 0x1F)
        guard spsCount > 0 else { return nil }

        var offset = 6
        var parameterSets: [[UInt8]] = []
        var changed = false
        for _ in 0..<spsCount {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard length > 1, offset + length <= bytes.count else { return nil }
            let sps = Array(bytes[offset..<(offset + length)])
            offset += length
            if let rewritten = rewrite(sps: sps) {
                parameterSets.append(rewritten)
                changed = true
            } else {
                parameterSets.append(sps)
            }
        }
        guard changed else { return nil }

        var out = Data(bytes[0..<6])
        for sps in parameterSets {
            out.append(UInt8((sps.count >> 8) & 0xFF))
            out.append(UInt8(sps.count & 0xFF))
            out.append(contentsOf: sps)
        }
        // The PPS list (and any high-profile extension) is copied verbatim.
        out.append(contentsOf: bytes[offset...])
        return out
    }

    // MARK: - SPS rewrite

    private static func rewrite(sps nal: [UInt8]) -> [UInt8]? {
        guard let header = nal.first, header & 0x1F == 7 else { return nil }
        let rbsp = removingEmulationPrevention(Array(nal.dropFirst()))
        guard let info = try? parse(rbsp: rbsp) else { return nil }
        // Already signalling no reordering — nothing to gain.
        if let reorder = info.maxNumReorderFrames, reorder == 0 { return nil }

        var writer = BitWriter()
        if info.vuiPresent {
            // vui_parameters() ends with bitstream_restriction, so copying up to
            // the end of pic_struct_present_flag keeps every other VUI field and
            // drops only the part we are replacing.
            guard let picStructEnd = info.picStructEndBitPosition else { return nil }
            writer.copyBits(from: rbsp, count: picStructEnd)
        } else {
            writer.copyBits(from: rbsp, count: info.vuiFlagBitPosition)
            writer.flag(true)                     // vui_parameters_present_flag
            // aspect_ratio, overscan, video_signal_type, chroma_loc, timing,
            // nal_hrd, vcl_hrd, pic_struct: all absent. No low_delay_hrd_flag
            // follows, because both HRD flags are zero.
            for _ in 0..<8 { writer.flag(false) }
        }
        writer.flag(true)                         // bitstream_restriction_flag
        writer.flag(true)                         // motion_vectors_over_pic_boundaries_flag
        writer.ue(0)                              // max_bytes_per_pic_denom (0 = no limit)
        writer.ue(0)                              // max_bits_per_mb_denom (0 = no limit)
        writer.ue(16)                             // log2_max_mv_length_horizontal
        writer.ue(16)                             // log2_max_mv_length_vertical
        writer.ue(0)                              // max_num_reorder_frames — the whole point
        writer.ue(max(info.maxNumRefFrames, 1))   // max_dec_frame_buffering (>= ref frames)
        writer.appendTrailingBits()
        return [header] + addingEmulationPrevention(writer.bytes())
    }

    private struct SPSInfo {
        var maxNumRefFrames: UInt32
        var vuiFlagBitPosition: Int
        var vuiPresent: Bool
        /// Bit position just past `pic_struct_present_flag` (VUI present only).
        var picStructEndBitPosition: Int?
        /// nil when the SPS carries no bitstream restriction at all.
        var maxNumReorderFrames: UInt32?
    }

    fileprivate enum ParseError: Error { case malformed }

    /// Profiles that carry the chroma/bit-depth/scaling-list block (7.3.2.1.1).
    private static let profilesWithChromaInfo: Set<UInt32> =
        [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    private static func parse(rbsp: [UInt8]) throws -> SPSInfo {
        var r = BitReader(bytes: rbsp)
        let profileIDC = try r.u(8)
        _ = try r.u(8)                            // constraint flags + reserved
        _ = try r.u(8)                            // level_idc
        _ = try r.ue()                            // seq_parameter_set_id

        if profilesWithChromaInfo.contains(profileIDC) {
            let chromaFormatIDC = try r.ue()
            if chromaFormatIDC == 3 { _ = try r.u(1) }   // separate_colour_plane_flag
            _ = try r.ue()                        // bit_depth_luma_minus8
            _ = try r.ue()                        // bit_depth_chroma_minus8
            _ = try r.u(1)                        // qpprime_y_zero_transform_bypass_flag
            if try r.flag() {                     // seq_scaling_matrix_present_flag
                let listCount = chromaFormatIDC != 3 ? 8 : 12
                for i in 0..<listCount {
                    if try r.flag() { try skipScalingList(&r, size: i < 6 ? 16 : 64) }
                }
            }
        }

        _ = try r.ue()                            // log2_max_frame_num_minus4
        let pocType = try r.ue()
        if pocType == 0 {
            _ = try r.ue()                        // log2_max_pic_order_cnt_lsb_minus4
        } else if pocType == 1 {
            _ = try r.u(1)                        // delta_pic_order_always_zero_flag
            _ = try r.se()                        // offset_for_non_ref_pic
            _ = try r.se()                        // offset_for_top_to_bottom_field
            let cycleLength = try r.ue()
            guard cycleLength <= 255 else { throw ParseError.malformed }
            for _ in 0..<cycleLength { _ = try r.se() }
        }

        let maxNumRefFrames = try r.ue()
        _ = try r.u(1)                            // gaps_in_frame_num_value_allowed_flag
        _ = try r.ue()                            // pic_width_in_mbs_minus1
        _ = try r.ue()                            // pic_height_in_map_units_minus1
        let frameMBSOnly = try r.flag()
        if !frameMBSOnly { _ = try r.u(1) }       // mb_adaptive_frame_field_flag
        _ = try r.u(1)                            // direct_8x8_inference_flag
        if try r.flag() {                         // frame_cropping_flag
            for _ in 0..<4 { _ = try r.ue() }
        }

        var info = SPSInfo(maxNumRefFrames: maxNumRefFrames,
                           vuiFlagBitPosition: r.position,
                           vuiPresent: false,
                           picStructEndBitPosition: nil,
                           maxNumReorderFrames: nil)
        info.vuiPresent = try r.flag()
        if info.vuiPresent {
            if try r.flag() {                     // aspect_ratio_info_present_flag
                if try r.u(8) == 255 { _ = try r.u(16); _ = try r.u(16) }   // Extended_SAR
            }
            if try r.flag() { _ = try r.u(1) }    // overscan
            if try r.flag() {                     // video_signal_type_present_flag
                _ = try r.u(3)                    // video_format
                _ = try r.u(1)                    // video_full_range_flag
                if try r.flag() {                 // colour_description_present_flag
                    _ = try r.u(8); _ = try r.u(8); _ = try r.u(8)
                }
            }
            if try r.flag() { _ = try r.ue(); _ = try r.ue() }              // chroma_loc
            if try r.flag() { _ = try r.u(32); _ = try r.u(32); _ = try r.u(1) }  // timing
            let nalHRD = try r.flag()
            if nalHRD { try skipHRD(&r) }
            let vclHRD = try r.flag()
            if vclHRD { try skipHRD(&r) }
            if nalHRD || vclHRD { _ = try r.u(1) }  // low_delay_hrd_flag
            _ = try r.u(1)                          // pic_struct_present_flag
            info.picStructEndBitPosition = r.position
            if try r.flag() {                       // bitstream_restriction_flag
                _ = try r.u(1)                      // motion_vectors_over_pic_boundaries
                _ = try r.ue()                      // max_bytes_per_pic_denom
                _ = try r.ue()                      // max_bits_per_mb_denom
                _ = try r.ue()                      // log2_max_mv_length_horizontal
                _ = try r.ue()                      // log2_max_mv_length_vertical
                info.maxNumReorderFrames = try r.ue()
                _ = try r.ue()                      // max_dec_frame_buffering
            }
        }

        // We must land exactly on rbsp_trailing_bits (a 1 then zeros to the byte
        // boundary). Anything else means we misparsed, and rewriting a bitstream
        // we do not understand is how you ship a stream nobody can decode.
        let remaining = r.bitsLeft
        guard remaining > 0, remaining <= 8 else { throw ParseError.malformed }
        guard try r.u(1) == 1 else { throw ParseError.malformed }
        while r.bitsLeft > 0 {
            guard try r.u(1) == 0 else { throw ParseError.malformed }
        }
        return info
    }

    private static func skipScalingList(_ r: inout BitReader, size: Int) throws {
        var lastScale = 8, nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = try r.se()
                nextScale = (lastScale + Int(delta) + 256) % 256
            }
            if nextScale != 0 { lastScale = nextScale }
        }
    }

    private static func skipHRD(_ r: inout BitReader) throws {
        let cpbCount = try r.ue() + 1
        guard cpbCount <= 32 else { throw ParseError.malformed }
        _ = try r.u(4)                            // bit_rate_scale
        _ = try r.u(4)                            // cpb_size_scale
        for _ in 0..<cpbCount {
            _ = try r.ue()                        // bit_rate_value_minus1
            _ = try r.ue()                        // cpb_size_value_minus1
            _ = try r.u(1)                        // cbr_flag
        }
        for _ in 0..<4 { _ = try r.u(5) }         // the four *_length_minus1 fields
    }

    // MARK: - RBSP escaping

    /// Strip emulation-prevention bytes (00 00 03 -> 00 00) to get the raw RBSP.
    static func removingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if index + 2 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 3 {
                out.append(0); out.append(0)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    /// Re-insert emulation-prevention bytes so the RBSP is a legal NAL payload.
    static func addingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        var zeros = 0
        for byte in bytes {
            if zeros == 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

// MARK: - Bit plumbing

private struct BitReader {
    let bytes: [UInt8]
    private(set) var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var bitsLeft: Int { bytes.count * 8 - position }

    mutating func u(_ count: Int) throws -> UInt32 {
        guard count <= 32, bitsLeft >= count else { throw H264ParameterSets.ParseError.malformed }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[position >> 3]
            let bit = (byte >> (7 - UInt8(position & 7))) & 1
            value = (value << 1) | UInt32(bit)
            position += 1
        }
        return value
    }

    mutating func flag() throws -> Bool { try u(1) == 1 }

    /// Unsigned Exp-Golomb.
    mutating func ue() throws -> UInt32 {
        var zeros = 0
        while true {
            if try u(1) == 1 { break }
            zeros += 1
            guard zeros <= 31 else { throw H264ParameterSets.ParseError.malformed }
        }
        guard zeros > 0 else { return 0 }
        let suffix = try u(zeros)
        let value = (UInt64(1) << UInt64(zeros)) - 1 + UInt64(suffix)
        guard value <= UInt64(UInt32.max) else { throw H264ParameterSets.ParseError.malformed }
        return UInt32(value)
    }

    /// Signed Exp-Golomb.
    mutating func se() throws -> Int32 {
        let k = try ue()
        guard k < UInt32(Int32.max) else { throw H264ParameterSets.ParseError.malformed }
        return k % 2 == 1 ? Int32((k + 1) / 2) : -Int32(k / 2)
    }
}

private struct BitWriter {
    private var bits: [UInt8] = []

    mutating func flag(_ on: Bool) { bits.append(on ? 1 : 0) }

    mutating func u(_ value: UInt32, _ count: Int) {
        guard count > 0 else { return }
        for shift in stride(from: count - 1, through: 0, by: -1) {
            bits.append(UInt8((value >> UInt32(shift)) & 1))
        }
    }

    mutating func ue(_ value: UInt32) {
        let coded = UInt64(value) + 1
        let width = 64 - coded.leadingZeroBitCount
        for _ in 0..<(width - 1) { bits.append(0) }
        for shift in stride(from: width - 1, through: 0, by: -1) {
            bits.append(UInt8((coded >> UInt64(shift)) & 1))
        }
    }

    /// Copy the first `count` bits of an RBSP verbatim. The caller has already
    /// parsed that far, so the buffer is known to hold them.
    mutating func copyBits(from bytes: [UInt8], count: Int) {
        bits.reserveCapacity(bits.count + count)
        for position in 0..<count {
            let byte = bytes[position >> 3]
            bits.append((byte >> (7 - UInt8(position & 7))) & 1)
        }
    }

    mutating func appendTrailingBits() {
        bits.append(1)
        while bits.count % 8 != 0 { bits.append(0) }
    }

    func bytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bits.count / 8)
        var index = 0
        while index + 8 <= bits.count {
            var byte: UInt8 = 0
            for offset in 0..<8 { byte = (byte << 1) | bits[index + offset] }
            out.append(byte)
            index += 8
        }
        return out
    }
}
