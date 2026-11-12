import XCTest
@testable import UI

final class MemoryPressurePolicyTests: XCTestCase {
    /// Warnings are routine on a small Mac under load, so only critical
    /// pressure costs the user any of their replay.
    func testOnlyCriticalPressureShortensTheReplay() {
        for seconds in [5, 15, 30, 120, 300] {
            XCTAssertEqual(MemoryPressurePolicy.replaySeconds(configured: seconds, level: .normal), seconds)
            XCTAssertEqual(MemoryPressurePolicy.replaySeconds(configured: seconds, level: .warning), seconds)
        }
    }

    func testCriticalPressureHalvesTheReplayDownToAFloor() {
        XCTAssertEqual(MemoryPressurePolicy.replaySeconds(configured: 300, level: .critical), 150)
        XCTAssertEqual(MemoryPressurePolicy.replaySeconds(configured: 30, level: .critical), 15)
        // Never below the floor...
        XCTAssertEqual(MemoryPressurePolicy.replaySeconds(configured: 15, level: .critical), 10)
        // ...and never longer than what was asked for.
        XCTAssertEqual(MemoryPressurePolicy.replaySeconds(configured: 5, level: .critical), 5)
    }
}
