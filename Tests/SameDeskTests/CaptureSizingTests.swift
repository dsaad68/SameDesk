@testable import SameDesk
import XCTest
/// Capture sizing snaps requested viewports onto a ladder so a window drag does
/// not reconfigure the capture stream continuously.
final class CaptureSizingTests: XCTestCase {
    func testSnapsUpToTheNextLadderStep() {
        XCTAssertEqual(ScreenCapturer.ladderEdge(forRequested: 900, cap: 2560), 1280)
        XCTAssertEqual(ScreenCapturer.ladderEdge(forRequested: 1281, cap: 2560), 1600)
        XCTAssertEqual(ScreenCapturer.ladderEdge(forRequested: 1920, cap: 2560), 1920)
    }

    func testNeverExceedsTheCap() {
        XCTAssertEqual(ScreenCapturer.ladderEdge(forRequested: 4000, cap: 1920), 1920)
        XCTAssertEqual(ScreenCapturer.ladderEdge(forRequested: 1900, cap: 1600), 1600)
    }

    /// A client that has not reported yet must not shrink anything.
    func testUnknownViewportKeepsTheCap() {
        XCTAssertEqual(ScreenCapturer.ladderEdge(forRequested: 0, cap: 2560), 2560)
    }

    func testCappedDimensionsPreserveAspectAndStayEven() {
        let (w, h) = ScreenCapturer.cappedDimensions(width: 3024, height: 1964, maxEdge: 1920)
        XCTAssertEqual(w, 1920)
        XCTAssertEqual(h % 2, 0)
        XCTAssertEqual(Double(w) / Double(h), 3024.0 / 1964.0, accuracy: 0.01)
    }
}
