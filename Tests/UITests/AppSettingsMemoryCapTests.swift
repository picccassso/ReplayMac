import Defaults
import XCTest
@testable import UI

final class AppSettingsMemoryCapTests: XCTestCase {
    func testSingleDisplayAllocatesOneVideoBufferShare() {
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: false,
            isSeparateDualSave: false,
            captureSystemAudio: true,
            captureMicrophone: true,
            totalCapMB: 1024
        )

        XCTAssertGreaterThanOrEqual(caps.videoPerBuffer, 32 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(caps.audioPerBuffer, 8 * 1024 * 1024)

        let totalBytes = Int(1024 * 1024 * 1024)
        let allocated = caps.videoPerBuffer + (caps.audioPerBuffer * 2)
        XCTAssertLessThanOrEqual(allocated, totalBytes)
    }

    /// Only buffers that fill share the cap: side-by-side encodes one
    /// composite stream, separate files one stream per display. Splitting
    /// three ways regardless left most of the cap unused in dual mode.
    func testDualDisplaySplitsVideoAcrossTheBuffersInUse() {
        func caps(dual: Bool, separate: Bool) -> (videoPerBuffer: Int, audioPerBuffer: Int) {
            AppSettings.ringBufferMemoryCaps(
                isDualMode: dual,
                isSeparateDualSave: separate,
                captureSystemAudio: true,
                captureMicrophone: false,
                totalCapMB: 1536
            )
        }
        let single = caps(dual: false, separate: false)
        let sideBySide = caps(dual: true, separate: false)
        let separate = caps(dual: true, separate: true)

        XCTAssertEqual(sideBySide.videoPerBuffer, single.videoPerBuffer)
        XCTAssertEqual(separate.videoPerBuffer, single.videoPerBuffer / 2, accuracy: 1)
        XCTAssertEqual(separate.audioPerBuffer, single.audioPerBuffer)
        // The save mode means nothing outside dual capture.
        XCTAssertEqual(caps(dual: false, separate: true).videoPerBuffer, single.videoPerBuffer)
    }

    func testAudioDisabledStillReturnsAudioCapFloor() {
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: false,
            isSeparateDualSave: false,
            captureSystemAudio: false,
            captureMicrophone: false,
            totalCapMB: 512
        )

        XCTAssertGreaterThanOrEqual(caps.audioPerBuffer, 8 * 1024 * 1024)
    }

    /// Audio fills at a fixed rate and video usually under its bitrate, so
    /// audio is sized from the window: whenever the cap can afford it, every
    /// audio buffer holds the whole retained window plus the keyframe margin,
    /// at any bitrate, and the buffers never add up to more than the cap.
    func testAudioBuffersHoldTheWholeWindowWhenTheCapAllows() {
        for capMB in [256.0, 512, 1024, 1408, 1536, 4096] {
            for retained in [18.0, 33, 123, 303] {
                for (system, mic) in [(true, false), (false, true), (true, true)] {
                    for (dual, separate) in [(false, false), (true, false), (true, true)] {
                        let caps = AppSettings.ringBufferMemoryCaps(
                            isDualMode: dual,
                            isSeparateDualSave: separate,
                            captureSystemAudio: system,
                            captureMicrophone: mic,
                            retainedSeconds: retained,
                            totalCapMB: capMB
                        )
                        let sources = (system ? 1 : 0) + (mic ? 1 : 0)
                        let videoBuffers = AppSettings.activeVideoBufferCount(isDualMode: dual, isSeparateDualSave: separate)
                        let need = (retained + AppSettings.audioKeyframeMarginSeconds) * AppSettings.audioRingBufferBytesPerSecond
                        let total = Int(capMB * 1024 * 1024)
                        let label = "cap=\(capMB) retained=\(retained) system=\(system) mic=\(mic) dual=\(dual) separate=\(separate)"
                        if Int(need) * sources + 32 * 1024 * 1024 * videoBuffers <= total {
                            XCTAssertGreaterThanOrEqual(Double(caps.audioPerBuffer), need - 1, label)
                        }
                        XCTAssertLessThanOrEqual(videoBuffers * caps.videoPerBuffer + caps.audioPerBuffer * sources, total + 1, label)
                    }
                }
            }
        }
    }

    /// The setup that produced 13 s of silence: a 5 minute buffer with both
    /// audio sources at a 1408 MB cap held only about 288 s of audio.
    func testFiveMinuteBufferWithBothAudioSourcesFitsBelowDefaultCap() {
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: false,
            isSeparateDualSave: false,
            captureSystemAudio: true,
            captureMicrophone: true,
            retainedSeconds: 303,
            totalCapMB: 1408
        )
        let audioSeconds = Double(caps.audioPerBuffer) / AppSettings.audioRingBufferBytesPerSecond
        XCTAssertGreaterThanOrEqual(audioSeconds, 303)
    }

    func testAudioRingBufferRateMatchesStereo16BitPCM() {
        XCTAssertEqual(AppSettings.audioRingBufferBytesPerSecond, 48_000 * 2 * Double(MemoryLayout<Int16>.size))
    }

    func testDefaultMemoryCapScalesWithPhysicalMemory() {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        XCTAssertEqual(AppSettings.defaultMemoryCapMB(physicalMemoryBytes: 8 * gigabyte), 768)
        XCTAssertEqual(AppSettings.defaultMemoryCapMB(physicalMemoryBytes: 16 * gigabyte), 1536)
        XCTAssertEqual(AppSettings.defaultMemoryCapMB(physicalMemoryBytes: 64 * gigabyte), 1536)
        // Never below what a default buffer needs, however small the Mac.
        XCTAssertEqual(AppSettings.defaultMemoryCapMB(physicalMemoryBytes: 4 * gigabyte), 512)
        // Always a value the Memory cap slider can show.
        for gigabytes: UInt64 in [4, 8, 12, 16, 18, 24, 32, 36, 48, 64, 96, 128] {
            let cap = AppSettings.defaultMemoryCapMB(physicalMemoryBytes: gigabytes * gigabyte)
            XCTAssertEqual(cap.truncatingRemainder(dividingBy: ReplayMemoryEstimate.memoryCapStepMB), 0, "\(gigabytes) GB")
            XCTAssertTrue(ReplayMemoryEstimate.memoryCapRangeMB.contains(cap), "\(gigabytes) GB")
        }
    }

    /// On an 8 GB Mac the default cap still holds the default 30 s buffer many
    /// times over, at any bitrate the slider offers.
    func testDefaultCapOnEightGigabytesHoldsTheDefaultBuffer() {
        let cap = AppSettings.defaultMemoryCapMB(physicalMemoryBytes: 8 * 1024 * 1024 * 1024)
        let estimate = ReplayMemoryEstimate.make(
            bufferSeconds: Defaults.Keys.bufferDurationSeconds.defaultValue,
            bitrateMbps: BitrateGuide.sliderRange.upperBound,
            isDualMode: false,
            isSeparateDualSave: false,
            captureSystemAudio: true,
            captureMicrophone: true,
            memoryCapMB: cap
        )
        XCTAssertFalse(estimate.isCapLimited)
    }

    func testInitialBitrateFollowsTheDisplaySize() {
        // 1440p is what the flat 25 Mbps default was tuned for.
        XCTAssertEqual(AppSettings.initialBitrateMbps(displayWidth: 2560, displayHeight: 1440), 25)
        // A MacBook Air's default scaled display needs far less.
        XCTAssertEqual(AppSettings.initialBitrateMbps(displayWidth: 1470, displayHeight: 956), 10)
        XCTAssertEqual(AppSettings.initialBitrateMbps(displayWidth: 1920, displayHeight: 1080), 14)
        // Always what Settings itself would recommend for that size.
        XCTAssertEqual(
            AppSettings.initialBitrateMbps(displayWidth: 3840, displayHeight: 2160),
            BitrateGuide(width: 3840, height: 2160, frameRate: 60, isH264SDR: false).recommendedMbps
        )
        // No display to measure: keep the stock default.
        XCTAssertEqual(AppSettings.initialBitrateMbps(displayWidth: 0, displayHeight: 0), Defaults.Keys.bitrateMbps.defaultValue)
    }

    func testRetinaPixelDimensionUsesBackingScale() {
        XCTAssertEqual(AppSettings.retinaPixelDimension(for: 1512, pointPixelScale: 2.0), 3024)
    }

    func testRetinaPixelDimensionFallsBackToCurrentSizeForOneTimesDisplays() {
        XCTAssertEqual(AppSettings.retinaPixelDimension(for: 1920, pointPixelScale: 1.0), 1920)
        XCTAssertEqual(AppSettings.retinaPixelDimension(for: 1920, pointPixelScale: 0.0), 1920)
    }

    func testRetinaPixelDimensionIsCappedAtDisplayPixelSize() {
        XCTAssertEqual(
            AppSettings.retinaPixelDimension(
                for: 3024,
                pointPixelScale: 2.0,
                maxPixelDimension: 3024
            ),
            3024
        )
    }

    func testAudioRingBufferHeadroomMatchesVideoRingBufferHeadroom() {
        XCTAssertGreaterThanOrEqual(
            AppSettings.ringBufferHeadroomSeconds, 2.0,
            "Audio and video ring buffer headroom must be at least one full GOP interval (~2s)"
        )
        XCTAssertEqual(
            AppSettings.ringBufferTimeCapSeconds,
            TimeInterval(AppSettings.bufferDurationSeconds) + AppSettings.ringBufferHeadroomSeconds
        )
    }
}
