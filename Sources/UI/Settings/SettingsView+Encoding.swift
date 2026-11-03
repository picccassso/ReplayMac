import SwiftUI
import Defaults

extension SettingsView {
    var bitrateValueLabel: String {
        "\(Int(bitrateSliderValue)) Mbps"
    }

    var bitrateScopeLabel: String {
        if captureModeRawValue == CaptureMode.dualSideBySide.rawValue,
           dualCaptureSaveModeRawValue == DualCaptureSaveMode.separateFiles.rawValue {
            return "Applies per display file"
        }
        return "Applies to the saved video stream"
    }

    var recommendedBitrateLabel: String {
        "Recommended: \(Int(recommendedBitrateMbps())) Mbps"
    }

    var isAtRecommendedBitrate: Bool {
        Int(bitrateSliderValue.rounded()) == Int(recommendedBitrateMbps())
    }

    func applyQualityPresetIfNeeded(_ presetRawValue: String) {
        guard let preset = QualityPreset(rawValue: presetRawValue) else {
            return
        }

        isApplyingQualityPreset = true

        switch preset {
        case .performance:
            captureResolutionRawValue = CaptureResolution.half.rawValue
            frameRate = 30
            bitrateMbps = recommendedBitrateMbps(
                preset: .performance,
                resolutionRawValue: CaptureResolution.half.rawValue,
                frameRate: 30
            )
        case .quality:
            captureResolutionRawValue = CaptureResolution.native.rawValue
            frameRate = 60
            bitrateMbps = recommendedBitrateMbps(
                preset: .quality,
                resolutionRawValue: CaptureResolution.native.rawValue,
                frameRate: 60
            )
        case .ultra:
            captureResolutionRawValue = CaptureResolution.native.rawValue
            frameRate = 120
            bitrateMbps = recommendedBitrateMbps(
                preset: .ultra,
                resolutionRawValue: CaptureResolution.native.rawValue,
                frameRate: 120
            )
        case .custom:
            break
        }

        bitrateSliderValue = bitrateMbps
        finishApplyingQualityPresetOnNextRunLoop()
    }

    func markQualityPresetAsCustomIfNeeded() {
        if !isApplyingQualityPreset && qualityPresetRawValue != QualityPreset.custom.rawValue {
            qualityPresetRawValue = QualityPreset.custom.rawValue
        }
    }

    func updateBitrateForCurrentPresetIfNeeded() {
        guard let preset = QualityPreset(rawValue: qualityPresetRawValue),
              preset != .custom,
              !isApplyingQualityPreset else {
            return
        }

        isApplyingQualityPreset = true
        bitrateMbps = recommendedBitrateMbps(
            preset: preset,
            resolutionRawValue: captureResolutionRawValue,
            frameRate: frameRate
        )
        bitrateSliderValue = bitrateMbps
        finishApplyingQualityPresetOnNextRunLoop()
    }

    func finishApplyingQualityPresetOnNextRunLoop() {
        Task { @MainActor in
            isApplyingQualityPreset = false
        }
    }

    var resolvedPriorityDisplay: DisplayOption? {
        for priority in captureDisplayPriorities where !priority.isEmpty {
            if let match = connectedDisplay(matching: priority) {
                return match
            }
        }
        return connectedDisplay(matching: captureDisplayID) ?? connectedDisplays.first
    }

    var selectedCaptureDisplays: [DisplayOption] {
        let display1 = resolvedPriorityDisplay
        guard captureModeRawValue == CaptureMode.dualSideBySide.rawValue else {
            return display1.map { [$0] } ?? []
        }

        let display2 = connectedDisplay(matching: captureDisplayID2)
        return [display1, display2].compactMap { $0 }
    }

    var isRetinaResolutionAvailable: Bool {
        selectedCaptureDisplays.contains { $0.hasRetinaOutput }
    }

    var captureResolutionOptions: [CaptureResolution] {
        CaptureResolution.allCases.filter { resolution in
            (resolution != .retina || isRetinaResolutionAvailable)
                && (AppSettings.isFeatureEnabled(.proVideo) || resolution != .custom)
        }
    }

    /// Displays attached right now, excluding placeholders for saved-but-disconnected
    /// selections — resolution math must never be driven by a placeholder's size.
    var connectedDisplays: [DisplayOption] {
        displays.filter(\.isConnected)
    }

    func connectedDisplay(matching id: String) -> DisplayOption? {
        connectedDisplays.first { $0.id == id }
    }

    func validateCaptureResolutionSelection() {
        guard !connectedDisplays.isEmpty else { return }

        if captureResolutionRawValue == CaptureResolution.retina.rawValue,
           !isRetinaResolutionAvailable {
            captureResolutionRawValue = CaptureResolution.native.rawValue
        }
    }

    var effectiveVideoDimensionsLabel: String {
        let dimensions = effectiveVideoDimensions(resolutionRawValue: captureResolutionRawValue)
        return "Output: \(dimensions.width) × \(dimensions.height)"
    }

    var dualResolutionDetailLabel: String? {
        guard captureModeRawValue == CaptureMode.dualSideBySide.rawValue else {
            return nil
        }

        let display1 = connectedDisplay(matching: captureDisplayID) ?? connectedDisplays.first
        let display2 = connectedDisplay(matching: captureDisplayID2)
        let dimensions1 = dimensions(
            for: display1,
            fallback: nil,
            resolutionRawValue: captureResolutionRawValue
        )
        let dimensions2 = dimensions(
            for: display2,
            fallback: display1,
            resolutionRawValue: captureResolutionRawValue
        )

        if dualCaptureSaveModeRawValue == DualCaptureSaveMode.separateFiles.rawValue {
            return "Separate files: Display 1 \(dimensions1.width) × \(dimensions1.height), Display 2 \(dimensions2.width) × \(dimensions2.height)."
        }

        return "Side-by-side combines Display 1 \(dimensions1.width) × \(dimensions1.height) + Display 2 \(dimensions2.width) × \(dimensions2.height)."
    }

    var customResolutionAspectLabel: String? {
        guard captureResolutionRawValue == CaptureResolution.custom.rawValue else {
            return nil
        }

        let display = connectedDisplay(matching: captureDisplayID) ?? connectedDisplays.first
        guard let display, display.width > 0, display.height > 0, customCaptureHeight > 0 else {
            return nil
        }

        let displayAspect = Double(display.width) / Double(display.height)
        let customAspect = Double(customCaptureWidth) / Double(customCaptureHeight)
        guard abs(displayAspect - customAspect) > 0.02 else {
            return nil
        }

        let matchedHeight = Int((Double(customCaptureWidth) / displayAspect).rounded())
        return "Tip: this does not match the display aspect. \(customCaptureWidth) × \(matchedHeight) would preserve the selected display shape."
    }

    var resolutionHelpLabel: String {
        switch CaptureResolution(rawValue: captureResolutionRawValue) {
        case .native:
            return "Current uses the logical size macOS reports for the display."
        case .retina:
            if captureModeRawValue == CaptureMode.dualSideBySide.rawValue {
                return "Retina applies per display. HiDPI displays use backing pixels; non-Retina displays stay at their current size."
            }
            return "Retina keeps your Mac UI size the same but records up to the display's backing pixel size when available."
        case .half:
            return "Half records at half of the current logical display size."
        case .custom:
            if captureModeRawValue == CaptureMode.dualSideBySide.rawValue {
                return "Custom forces each display stream to the exact width and height you choose, rescaling each capture if needed."
            }
            return "Custom forces the saved video to the exact width and height you choose, rescaling the capture if needed."
        case .none:
            return "Output size is based on the selected display and resolution mode."
        }
    }

    func handleBitrateSliderEditingChanged(_ isEditing: Bool) {
        bitrateSliderIsEditing = isEditing

        if !isEditing {
            commitBitrateSliderValue()
        }
    }

    func commitBitrateSliderValue() {
        let committedValue = Double(Int(bitrateSliderValue.rounded()))
        bitrateSliderValue = committedValue

        guard bitrateMbps != committedValue else { return }
        bitrateMbps = committedValue
    }

    func recommendedBitrateMbps() -> Double {
        recommendedBitrateMbps(
            preset: QualityPreset(rawValue: qualityPresetRawValue) ?? .quality,
            resolutionRawValue: captureResolutionRawValue,
            frameRate: frameRate
        )
    }

    func recommendedBitrateMbps(
        preset: QualityPreset,
        resolutionRawValue: String,
        frameRate: Int
    ) -> Double {
        let dimensions = effectiveVideoDimensions(resolutionRawValue: resolutionRawValue)
        return BitrateGuide.recommendedMbps(
            preset: preset,
            width: dimensions.width,
            height: dimensions.height,
            frameRate: frameRate,
            isH264SDR: isH264SDR
        )
    }

    var isH264SDR: Bool {
        !hdrCaptureEnabled && videoCodecRawValue == VideoCodec.h264.rawValue
    }

    var bitrateGuide: BitrateGuide {
        let dimensions = effectiveVideoDimensions(resolutionRawValue: captureResolutionRawValue)
        return BitrateGuide(
            width: dimensions.width,
            height: dimensions.height,
            frameRate: frameRate,
            isH264SDR: isH264SDR
        )
    }

    func applyRecommendedBitrate() {
        applyBitrate(recommendedBitrateMbps())
    }

    func applyBitrate(_ mbps: Double) {
        bitrateSliderValue = mbps
        bitrateMbps = mbps
    }

    var bitrateExplainerContext: BitrateExplainerContext {
        let dimensions = effectiveVideoDimensions(resolutionRawValue: captureResolutionRawValue)
        return BitrateExplainerContext(
            width: dimensions.width,
            height: dimensions.height,
            frameRate: frameRate,
            guide: bitrateGuide
        )
    }

    func effectiveVideoDimensions(resolutionRawValue: String) -> (width: Int, height: Int) {
        let display1 = connectedDisplay(matching: captureDisplayID) ?? connectedDisplays.first
        let display2 = connectedDisplay(matching: captureDisplayID2)
        let singleDimensions = dimensions(
            for: display1,
            fallback: nil,
            resolutionRawValue: resolutionRawValue
        )

        guard captureModeRawValue == CaptureMode.dualSideBySide.rawValue else {
            return singleDimensions
        }

        let secondDimensions = dimensions(
            for: display2,
            fallback: display1,
            resolutionRawValue: resolutionRawValue
        )

        if dualCaptureSaveModeRawValue == DualCaptureSaveMode.separateFiles.rawValue {
            return singleDimensions.width * singleDimensions.height >= secondDimensions.width * secondDimensions.height
                ? singleDimensions
                : secondDimensions
        }

        return (
            width: singleDimensions.width + secondDimensions.width,
            height: max(singleDimensions.height, secondDimensions.height)
        )
    }

    func dimensions(
        for display: DisplayOption?,
        fallback: DisplayOption?,
        resolutionRawValue: String
    ) -> (width: Int, height: Int) {
        let resolvedDisplay = display ?? fallback
        let width = resolvedDisplay?.width ?? 2560
        let height = resolvedDisplay?.height ?? 1440

        switch resolutionRawValue {
        case CaptureResolution.half.rawValue:
            return (width / 2, height / 2)
        case CaptureResolution.retina.rawValue:
            return (
                AppSettings.retinaPixelDimension(
                    for: width,
                    pointPixelScale: resolvedDisplay?.pointPixelScale ?? 1.0,
                    maxPixelDimension: resolvedDisplay?.pixelWidth
                ),
                AppSettings.retinaPixelDimension(
                    for: height,
                    pointPixelScale: resolvedDisplay?.pointPixelScale ?? 1.0,
                    maxPixelDimension: resolvedDisplay?.pixelHeight
                )
            )
        case CaptureResolution.custom.rawValue:
            return (customCaptureWidth, customCaptureHeight)
        default:
            return (width, height)
        }
    }
}
