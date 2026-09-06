@testable import SameDesk
import XCTest

/// The VUI rewrite edits a live bitstream, so it is tested against real encoder
/// output: the `avcC` records below were lifted from x264-encoded MP4s, and the
/// expected results were produced by an independent implementation of the same
/// algorithm and checked to re-parse cleanly.
final class H264ParameterSetsTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// x264 High profile, 1080p, VUI carrying timing info and a bitstream
    /// restriction of max_num_reorder_frames = 2.
    private let realWorldHighProfile =
        "0164001fffe1001c6764001fac728440a02ff970110000030001000003003c0f1831846001000668e84394b22c"
    private let realWorldHighProfileRewritten =
        "0164001fffe1001c6764001fac728440a02ff970110000030001000003003c0f0884611801000668e84394b22c"

    /// A second real record, different level and reference-frame count.
    private let realWorldOther =
        "01640028ffe1001b67640028acd940780227e5c044000003000400000300f03c60c65801000668ebe24b22c0fdf8f800"
    private let realWorldOtherRewritten =
        "01640028ffe1001b67640028acd940780227e5c044000003000400000300f03c22119601000668ebe24b22c0fdf8f800"

    /// The shape VideoToolbox produces: High profile with no VUI at all, which
    /// is what leaves a browser decoder free to buffer up to 16 frames.
    private let noVUI = "01640033ffe1000b67640033ac2ca80780226401000468ebe240"
    private let noVUIRewritten = "01640033ffe1000f67640033ac2ca8078022680784423501000468ebe240"

    func testRewritesRealWorldRecord() {
        let out = H264ParameterSets.rewritingForLowLatencyDecode(data(realWorldHighProfile))
        XCTAssertEqual(out.map(hex), realWorldHighProfileRewritten)
    }

    func testRewritesSecondRealWorldRecord() {
        let out = H264ParameterSets.rewritingForLowLatencyDecode(data(realWorldOther))
        XCTAssertEqual(out.map(hex), realWorldOtherRewritten)
    }

    /// With no VUI present we have to synthesise one, so the SPS grows and the
    /// avcC length prefix has to be rewritten with it.
    func testAddsVUIWhenAbsent() {
        let out = H264ParameterSets.rewritingForLowLatencyDecode(data(noVUI))
        XCTAssertEqual(out.map(hex), noVUIRewritten)
        XCTAssertEqual(out?.count, data(noVUIRewritten).count)
    }

    /// Rewriting is idempotent: the output already signals no reordering, so a
    /// second pass reports nothing to do.
    func testIsIdempotent() {
        for record in [realWorldHighProfile, realWorldOther, noVUI] {
            guard let once = H264ParameterSets.rewritingForLowLatencyDecode(data(record)) else {
                return XCTFail("expected a rewrite for \(record)")
            }
            XCTAssertNil(H264ParameterSets.rewritingForLowLatencyDecode(once))
        }
    }

    /// The PPS list after the SPS must survive byte-for-byte.
    func testPreservesParameterSetTail() {
        let input = data(realWorldHighProfile)
        guard let out = H264ParameterSets.rewritingForLowLatencyDecode(input) else {
            return XCTFail("expected a rewrite")
        }
        let tail = "01000668e84394b22c"
        XCTAssertTrue(hex(out).hasSuffix(tail))
        XCTAssertTrue(hex(input).hasSuffix(tail))
    }

    /// Anything we do not fully understand is left alone rather than mangled.
    func testMalformedInputIsLeftAlone() {
        XCTAssertNil(H264ParameterSets.rewritingForLowLatencyDecode(Data()))
        XCTAssertNil(H264ParameterSets.rewritingForLowLatencyDecode(Data([1, 0x64, 0, 0x1F])))
        // Right header, truncated SPS payload.
        XCTAssertNil(H264ParameterSets.rewritingForLowLatencyDecode(
            data("0164001fffe1001c6764001fac72")))
        // A record claiming version 2.
        XCTAssertNil(H264ParameterSets.rewritingForLowLatencyDecode(
            data("0264001fffe1001c6764001fac728440a02ff970110000030001000003003c0f1831846001000668e84394b22c")))
        // Random bytes in place of the SPS.
        XCTAssertNil(H264ParameterSets.rewritingForLowLatencyDecode(
            data("0164001fffe10004deadbeef01000668e84394b22c")))
    }

    func testEmulationPreventionRoundTrip() {
        let cases: [[UInt8]] = [
            [0, 0, 0], [0, 0, 1], [0, 0, 3], [0x67, 0, 0, 2, 0xFF], [0, 0, 0, 0, 0],
        ]
        for raw in cases {
            let escaped = H264ParameterSets.addingEmulationPrevention(raw)
            XCTAssertEqual(H264ParameterSets.removingEmulationPrevention(escaped), raw)
        }
    }
}
