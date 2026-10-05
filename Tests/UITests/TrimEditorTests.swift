import XCTest
import AppKit
import AVFoundation
@testable import UI

final class TrimEditorTests: XCTestCase {
    func testTimeFormatsAndClamping() throws {
        XCTAssertEqual(TrimTime.parse(" 125.3 "), 125.3)
        XCTAssertEqual(TrimTime.parse("02:05.3"), 125.3)
        XCTAssertEqual(TrimTime.parse("1:02:05.3"), 3725.3)
        XCTAssertEqual(TrimTime.label(3725.3), "62:05.3")
        let proposed = try XCTUnwrap(TrimTime.parse("999:59.9"))
        XCTAssertEqual(TrimRangeMath.clampedStart(proposed, end: 10, bounds: 0...30,
                                                  minimumSelection: 0.1), 9.9, accuracy: 0.001)
        XCTAssertEqual(TrimRangeMath.clampedEnd(proposed, start: 3, bounds: 0...30,
                                                minimumSelection: 0.1), 30)
    }

    func testInvalidTimesAreRejected() {
        for text in ["", " ", "abc", "-1", "nan", "inf", "1:60", "1::2", "1:",
                     ":2", "1:2:3:4", "1.5:02", "2e3", "1:02:60", "1,2", "1..2"] {
            XCTAssertNil(TrimTime.parse(text), text)
        }
    }

    func testEditingFullSourceCanSeekBeyondPreviousSelection() {
        // A previous selected preview was 10...20. During editing the item and
        // origin return to the full source before seeking an endpoint outside it.
        XCTAssertEqual(TrimPreviewPosition.seconds(sourceSeconds: 25, previewSourceStart: 0), 25)
        XCTAssertEqual(TrimPreviewPosition.seconds(sourceSeconds: 5, previewSourceStart: 0), 5)
        XCTAssertEqual(TrimPreviewPosition.seconds(sourceSeconds: 15, previewSourceStart: 10), 5)
    }

    func testGIFSamplingCapsFramesAndDistributesEstimateAcrossSelection() throws {
        let plan = try GIFSamplingPlan(start: 10, end: 110)
        XCTAssertEqual(plan.times.count, 300)
        XCTAssertEqual(plan.interval, 1.0 / 3.0, accuracy: 0.001)
        let sample = plan.estimateTimes()
        XCTAssertEqual(sample.count, 12)
        XCTAssertEqual(sample.first, plan.times.first)
        XCTAssertEqual(sample.last, plan.times.last)
        XCTAssertEqual(Set(sample.map(\.value)).count, 12)
        XCTAssertTrue(zip(sample, sample.dropFirst()).allSatisfy { $0.seconds < $1.seconds })
    }

    func testShortGIFUsesAllFramesAndTinyRangeHasUniqueTicks() throws {
        let short = try GIFSamplingPlan(start: 0, end: 0.5)
        XCTAssertEqual(short.times.count, 6)
        XCTAssertEqual(short.estimateTimes(), short.times)
        let tiny = try GIFSamplingPlan(start: 0, end: 0.0001, frameRate: 100_000)
        XCTAssertEqual(tiny.times.count, 1)
        XCTAssertThrowsError(try GIFSamplingPlan(start: 1, end: 1))
        XCTAssertThrowsError(try GIFSamplingPlan(start: .nan, end: 2))
        XCTAssertThrowsError(try GIFSamplingPlan(start: 1e100, end: 2e100))
        let exactFrames = try GIFSamplingPlan(start: 0, end: 8)
        XCTAssertEqual(exactFrames.times.map(\.value), (0..<96).map { Int64($0 * 50) })
    }

    func testNewEstimateAndCancellationRejectStaleResults() {
        var generation = GIFEstimateGeneration()
        let first = generation.begin()
        XCTAssertTrue(generation.accepts(first))
        let second = generation.begin()
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
        generation.invalidate()
        XCTAssertFalse(generation.accepts(second))
    }

    @MainActor
    func testRestoredWindowIsKeptOnScreen() {
        let screen = NSRect(x: 1920, y: 100, width: 1280, height: 720)
        let restored = MainWindowGeometry.visibleFrame(
            NSRect(x: -3000, y: 3000, width: 1800, height: 900), within: screen)
        XCTAssertEqual(restored, screen)
        let smaller = MainWindowGeometry.visibleFrame(
            NSRect(x: 4000, y: -100, width: 960, height: 640), within: screen)
        XCTAssertTrue(screen.contains(smaller))
    }
}
