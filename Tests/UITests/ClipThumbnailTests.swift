import XCTest
@testable import UI

@MainActor
final class ClipThumbnailTests: XCTestCase {
    func testCardSitsInBottomLeftOfVisibleFrame() {
        let visible = CGRect(x: 1440, y: 80, width: 1920, height: 1000)
        let frame = ClipThumbnailPanelController.frame(for: CGSize(width: 260, height: 160), in: visible)

        XCTAssertEqual(frame.origin, CGPoint(x: 1440 + ClipThumbnailPanelController.screenInset,
                                             y: 80 + ClipThumbnailPanelController.screenInset))
        XCTAssertEqual(frame.size, CGSize(width: 260, height: 160))
        XCTAssertTrue(visible.contains(frame))
    }

    func testAutoHideDelayKeepsCardUntilDismissedForZero() {
        XCTAssertEqual(ClipThumbnailPanelController.autoHideDelay(seconds: 6), .seconds(6))
        XCTAssertEqual(ClipThumbnailPanelController.autoHideDelay(seconds: 4), .seconds(4))
        XCTAssertNil(ClipThumbnailPanelController.autoHideDelay(seconds: 0))
    }

    func testDurationSliderMapsLastStopToUntilDismissed() {
        typealias Panel = ClipThumbnailPanelController
        XCTAssertEqual(Panel.storedSeconds(forSliderValue: 1), 1)
        XCTAssertEqual(Panel.storedSeconds(forSliderValue: 10), 10)
        XCTAssertEqual(Panel.storedSeconds(forSliderValue: Panel.sliderRange.upperBound), 0)

        XCTAssertEqual(Panel.sliderValue(forStoredSeconds: 6), 6)
        XCTAssertEqual(Panel.sliderValue(forStoredSeconds: 0), Panel.sliderRange.upperBound)
        XCTAssertEqual(Panel.sliderValue(forStoredSeconds: 30), 10)

        XCTAssertEqual(Panel.durationLabel(forStoredSeconds: 1), "1 second")
        XCTAssertEqual(Panel.durationLabel(forStoredSeconds: 6), "6 seconds")
        XCTAssertEqual(Panel.durationLabel(forStoredSeconds: 0), "Until dismissed")
    }

    func testResolveLastClipReturnsRecordedClipWithoutTouchingPasteboard() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let clip = tempDir.appendingPathComponent("Clip.mp4")
        try Data("clip".utf8).write(to: clip)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unchanged", forType: .string)

        let controller = StatusItemController()
        controller.setLastClip(clip)

        XCTAssertEqual(controller.resolveLastClipURL()?.standardizedFileURL, clip.standardizedFileURL)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")
    }
}
