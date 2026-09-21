import XCTest
@testable import UI

final class TrimRangeSelectorTests: XCTestCase {
    func testStartCannotCrossEndOrBounds() {
        let bounds = 0.0...10.0

        XCTAssertEqual(
            TrimRangeMath.clampedStart(-4, end: 7, bounds: bounds, minimumSelection: 0.1),
            0
        )
        XCTAssertEqual(
            TrimRangeMath.clampedStart(9, end: 7, bounds: bounds, minimumSelection: 0.1),
            6.9,
            accuracy: 0.0001
        )
    }

    func testEndCannotCrossStartOrBounds() {
        let bounds = 0.0...10.0

        XCTAssertEqual(
            TrimRangeMath.clampedEnd(14, start: 3, bounds: bounds, minimumSelection: 0.1),
            10
        )
        XCTAssertEqual(
            TrimRangeMath.clampedEnd(1, start: 3, bounds: bounds, minimumSelection: 0.1),
            3.1,
            accuracy: 0.0001
        )
    }

    func testMinimumSelectionShrinksForVeryShortClip() {
        let bounds = 0.0...0.04

        XCTAssertEqual(
            TrimRangeMath.clampedStart(0.03, end: 0.04, bounds: bounds, minimumSelection: 0.1),
            0
        )
        XCTAssertEqual(
            TrimRangeMath.clampedEnd(0.01, start: 0, bounds: bounds, minimumSelection: 0.1),
            0.04
        )
    }
}
