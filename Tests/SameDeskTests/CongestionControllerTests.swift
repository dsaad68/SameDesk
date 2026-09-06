@testable import SameDesk
import XCTest

/// The bitrate policy is pure logic, so it is tested directly rather than
/// through a live socket.
final class CongestionControllerTests: XCTestCase {
    private func makeController(maxBps: Int = 8_000_000) -> CongestionController {
        CongestionController(config: .init(minBps: 1_000_000, maxBps: maxBps))
    }

    func testStartsAtCeiling() {
        XCTAssertEqual(makeController().targetBps, 8_000_000)
    }

    func testBacksOffOnQueueingDelay() {
        var controller = makeController()
        let new = controller.update(peakWriteDelay: 0.25)
        XCTAssertEqual(new, 4_800_000)
        XCTAssertEqual(controller.targetBps, 4_800_000)
    }

    func testRepeatedCongestionKeepsCuttingDownToFloor() {
        var controller = makeController()
        for _ in 0..<20 { _ = controller.update(peakWriteDelay: 0.5) }
        XCTAssertEqual(controller.targetBps, 1_000_000)
    }

    func testHoldsAfterDecreaseBeforeProbingUp() {
        var controller = makeController()
        _ = controller.update(peakWriteDelay: 0.25)
        let afterCut = controller.targetBps
        // Hold ticks: no increase even though the link now looks clean.
        for _ in 0..<4 { XCTAssertNil(controller.update(peakWriteDelay: 0.001)) }
        XCTAssertEqual(controller.targetBps, afterCut)
    }

    func testProbesUpAfterSustainedCleanTicks() {
        var controller = makeController()
        _ = controller.update(peakWriteDelay: 0.25)
        let afterCut = controller.targetBps
        for _ in 0..<4 { _ = controller.update(peakWriteDelay: 0.001) }   // hold
        for _ in 0..<4 { _ = controller.update(peakWriteDelay: 0.001) }   // clean
        XCTAssertGreaterThan(controller.targetBps, afterCut)
    }

    func testNeverExceedsCeiling() {
        var controller = makeController()
        for _ in 0..<200 { _ = controller.update(peakWriteDelay: 0.0) }
        XCTAssertEqual(controller.targetBps, 8_000_000)
    }

    func testMiddlingDelayHoldsSteady() {
        var controller = makeController()
        _ = controller.update(peakWriteDelay: 0.25)
        let afterCut = controller.targetBps
        for _ in 0..<20 { _ = controller.update(peakWriteDelay: 0.05) }
        XCTAssertEqual(controller.targetBps, afterCut)
    }

    func testLoweringCeilingLowersTarget() {
        var controller = makeController()
        XCTAssertEqual(controller.setCeiling(2_000_000), 2_000_000)
        XCTAssertEqual(controller.targetBps, 2_000_000)
    }

    func testRaisingCeilingDoesNotJumpTarget() {
        var controller = makeController(maxBps: 2_000_000)
        _ = controller.setCeiling(20_000_000)
        XCTAssertEqual(controller.targetBps, 2_000_000)
    }
}
