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
        guard preset != .custom else {
            return bitrateSliderValue
        }

        let dimensions = effectiveVideoDimensions(resolutionRawValue: resolutionRawValue)
        let referencePixels = Double(2560 * 1440)
        let pixelScale = max(Double(dimensions.width * dimensions.height) / referencePixels, 0.25)
        let fpsScale = max(Double(frameRate) / 60.0, 0.5)
        let codecScale = videoCodecRawValue == VideoCodec.h264.rawValue ? 1.3 : 1.0

        let baseMbps: Double
        switch preset {
        case .performance:
            baseMbps = 18
        case .quality:
            baseMbps = 25
        case .ultra:
            baseMbps = 40
        case .custom:
            baseMbps = bitrateSliderValue
        }

        let recommendation = (baseMbps * pixelScale * fpsScale * codecScale).rounded()
        return min(max(recommendation, 10), 50)
    }

    func effectiveVideoDimensions(resolutionRawValue: String) -> (width: Int, height: Int) {
        let display1 = displays.first { $0.id == captureDisplayID } ?? displays.first
        let display2 = displays.first { $0.id == captureDisplayID2 }
        let nativeWidth = display1?.width ?? 2560
        let nativeHeight = display1?.height ?? 1440

        let singleDimensions: (width: Int, height: Int)
        switch resolutionRawValue {
        case CaptureResolution.half.rawValue:
            singleDimensions = (nativeWidth / 2, nativeHeight / 2)
        case CaptureResolution.custom.rawValue:
            singleDimensions = (customCaptureWidth, customCaptureHeight)
        default:
            singleDimensions = (nativeWidth, nativeHeight)
        }

        guard captureModeRawValue == CaptureMode.dualSideBySide.rawValue else {
            return singleDimensions
        }

        let secondNativeWidth = display2?.width ?? nativeWidth
        let secondNativeHeight = display2?.height ?? nativeHeight
        let secondDimensions: (width: Int, height: Int)
        switch resolutionRawValue {
        case CaptureResolution.half.rawValue:
            secondDimensions = (secondNativeWidth / 2, secondNativeHeight / 2)
        case CaptureResolution.custom.rawValue:
            secondDimensions = (customCaptureWidth, customCaptureHeight)
        default:
            secondDimensions = (secondNativeWidth, secondNativeHeight)
        }

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
}
