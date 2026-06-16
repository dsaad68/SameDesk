import CoreMedia
import Foundation
@testable import SameDesk
import XCTest

/// Exercises the hand-rolled fragmented-MP4 muxer through its public surface: we
/// feed it a real H.264 format description (carrying an avcC atom), then assert
/// the init segment and fragments have the ISO-BMFF box structure a browser's
/// MSE / WebCodecs path needs.
final class FMP4MuxerTests: XCTestCase {
    // A minimal but structurally valid AVCDecoderConfigurationRecord (avcC) with
    // zero parameter sets — enough for the muxer, which embeds it verbatim and
    // derives the codec string from bytes [1...3].
    private let avcC = Data([
        0x01,       // configurationVersion
        0x64,       // AVCProfileIndication (High)
        0x00,       // profile_compatibility
        0x1F,       // AVCLevelIndication (level 3.1)
        0xFF,       // 6 reserved bits | lengthSizeMinusOne = 3 (4-byte NAL length)
        0xE0,       // 3 reserved bits | numOfSequenceParameterSets = 0
        0x00        // numOfPictureParameterSets = 0
    ])

    private func makeH264Format(width: Int32, height: Int32) throws -> CMFormatDescription {
        let atoms: [String: Any] = ["avcC": avcC]
        let ext: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms
        ]
        var fd: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: width, height: height,
            extensions: ext as CFDictionary,
            formatDescriptionOut: &fd
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(fd)
    }

    func testNotReadyBeforeParameterSets() {
        let muxer = FMP4Muxer()
        XCTAssertFalse(muxer.isReady)
        XCTAssertNil(muxer.buildInitSegment())
    }

    func testUpdateParameterSetsBecomesReady() throws {
        let muxer = FMP4Muxer()
        let changed = muxer.updateParameterSets(from: try makeH264Format(width: 1920, height: 1080))
        XCTAssertTrue(changed)
        XCTAssertTrue(muxer.isReady)
        XCTAssertEqual(muxer.codec, .h264)
        XCTAssertEqual(muxer.width, 1920)
        XCTAssertEqual(muxer.height, 1080)
        XCTAssertEqual(muxer.codecString, "avc1.64001F")   // from avcC[1...3]
        // A second identical update is a no-op (no init-segment churn).
        XCTAssertFalse(muxer.updateParameterSets(from: try makeH264Format(width: 1920, height: 1080)))
    }

    func testInitSegmentBoxStructure() throws {
        let muxer = FMP4Muxer()
        muxer.updateParameterSets(from: try makeH264Format(width: 1280, height: 720))
        let seg = try XCTUnwrap(muxer.buildInitSegment())

        XCTAssertEqual(topLevelBoxes(seg).map(\.type), ["ftyp", "moov"])
        // The moov must carry the avc1 sample entry, the avcC, and our brand.
        XCTAssertTrue(contains(seg, "avc1"))
        XCTAssertTrue(contains(seg, "avcC"))
        XCTAssertTrue(contains(seg, "SameDesk"))
    }

    func testFragmentStructureAndSequence() throws {
        let muxer = FMP4Muxer()
        muxer.updateParameterSets(from: try makeH264Format(width: 640, height: 480))
        muxer.reset()
        let payload = Data([0x00, 0x00, 0x00, 0x04, 0x65, 0x01, 0x02, 0x03])

        let f1 = muxer.buildFragment(avccData: payload, isKeyframe: true,
                                     pts: CMTime(value: 0, timescale: 600))
        let f2 = muxer.buildFragment(avccData: payload, isKeyframe: false,
                                     pts: CMTime(value: 10, timescale: 600))

        XCTAssertEqual(topLevelBoxes(f1).map(\.type), ["moof", "mdat"])
        XCTAssertEqual(topLevelBoxes(f2).map(\.type), ["moof", "mdat"])
        XCTAssertNotNil(f1.range(of: payload))   // payload carried verbatim in mdat
    }

    // MARK: - Minimal ISO-BMFF box walker (test-only)

    private struct Box {
        let type: String
        let size: Int
    }

    private func topLevelBoxes(_ data: Data) -> [Box] {
        var boxes: [Box] = []
        var i = data.startIndex
        while i + 8 <= data.endIndex {
            let size = Int(be32(data, at: i))
            let type = String(bytes: data[(i + 4)..<(i + 8)], encoding: .ascii) ?? "????"
            guard size >= 8, i + size <= data.endIndex else { break }
            boxes.append(Box(type: type, size: size))
            i += size
        }
        return boxes
    }

    private func be32(_ d: Data, at i: Data.Index) -> UInt32 {
        (UInt32(d[i]) << 24) | (UInt32(d[i + 1]) << 16) | (UInt32(d[i + 2]) << 8) | UInt32(d[i + 3])
    }

    private func contains(_ d: Data, _ fourCC: String) -> Bool {
        d.range(of: Data(fourCC.utf8)) != nil
    }
}
