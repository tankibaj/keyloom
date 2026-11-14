import XCTest
@testable import Keyloom

final class LibraryWindowMetricsTests: XCTestCase {
    func testTheMinimumFitsSidebarListAndEditorWithTheAssistanceBar() {
        let metrics = LibraryWindowMetrics.self
        XCTAssertGreaterThanOrEqual(metrics.minimumSize.width, 860)
        XCTAssertGreaterThanOrEqual(metrics.minimumSize.height, 640)
    }

    /// Measured: at 860 pt the detail toolbar overflowed and hid Revert and Save; at 1020 all of it fits.
    func testTheMinimumWidthKeepsTheWholeToolbarOutOfTheOverflowMenu() {
        XCTAssertGreaterThanOrEqual(LibraryWindowMetrics.minimumSize.width, 1020)
    }

    func testASavedSmallFrameIsGrownToTheMinimumNeverShrunk() {
        let minimum = LibraryWindowMetrics.minimumSize
        XCTAssertEqual(LibraryWindowMetrics.clamped(CGSize(width: 700, height: 520)), CGSize(width: minimum.width, height: minimum.height))
        XCTAssertEqual(LibraryWindowMetrics.clamped(CGSize(width: 400, height: 300)), minimum)
        XCTAssertEqual(LibraryWindowMetrics.clamped(CGSize(width: 1400, height: 900)), CGSize(width: 1400, height: 900))
    }
}
