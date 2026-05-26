import SwiftUI
import AVFoundation
import Defaults
import Hotkeys
import KeyboardShortcuts
import ScreenCaptureKit
import ServiceManagement

public extension Notification.Name {
    static let replayMacSettingsShouldOpenGeneral = Notification.Name("replayMacSettingsShouldOpenGeneral")
}

public struct SettingsView: View {
    @Default(.bufferDurationSeconds) private var bufferDurationSeconds
    @Default(.outputDirectoryPath) private var outputDirectoryPath
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.autoStartRecordingOnLaunch) private var autoStartRecordingOnLaunch

    @Default(.videoCodec) private var videoCodecRawValue
    @Default(.captureMode) private var captureModeRawValue
    @Default(.captureDisplayID) private var captureDisplayID
    @Default(.captureDisplayID2) private var captureDisplayID2
    @Default(.dualCaptureSaveMode) private var dualCaptureSaveModeRawValue
    @Default(.captureResolution) private var captureResolutionRawValue
    @Default(.customCaptureWidth) private var customCaptureWidth
    @Default(.customCaptureHeight) private var customCaptureHeight
    @Default(.frameRate) private var frameRate
    @Default(.bitrateMbps) private var bitrateMbps
    @Default(.qualityPreset) private var qualityPresetRawValue

    @Default(.captureSystemAudio) private var captureSystemAudio
    @Default(.captureMicrophone) private var captureMicrophone
    @Default(.microphoneID) private var microphoneID
    @Default(.excludeOwnAppAudio) private var excludeOwnAppAudio
    @Default(.perAppAudioEnabled) private var perAppAudioEnabled
    @Default(.perAppAudioBundleID) private var perAppAudioBundleID
    @Default(.systemAudioVolume) private var systemAudioVolume
    @Default(.microphoneVolume) private var microphoneVolume

    @Default(.memoryCapMB) private var memoryCapMB
    @Default(.queueDepth) private var queueDepth
    @Default(.playAudioCueOnSave) private var playAudioCueOnSave
    @Default(.showNotificationOnSave) private var showNotificationOnSave
    @Default(.longBufferEnabled) private var longBufferEnabled
    @Default(.longBufferDurationMinutes) private var longBufferDurationMinutes
    @Default(.longBufferWarningAccepted) private var longBufferWarningAccepted

    @State private var displays: [DisplayOption] = []
    @State private var audioApplications: [AudioApplicationOption] = []
    @State private var microphones: [MicrophoneOption] = []
    @State private var launchAtLoginError: String?
    @State private var displayLoadError: String?
    @State private var bitrateSliderValue = Defaults[.bitrateMbps]
    @State private var bitrateSliderIsEditing = false
    @State private var isApplyingQualityPreset = false
    @State private var selectedTab = SettingsTab.general

    private var dualDisplayOptions: [DisplayOption] {
        displays.filter { $0.id != captureDisplayID }
    }

    private var systemAudioModeBinding: Binding<SystemAudioMode> {
        Binding(
            get: {
                if !captureSystemAudio {
                    return .off
                }
                return perAppAudioEnabled ? .selectedApp : .allApps
            },
            set: { mode in
                switch mode {
                case .off:
                    captureSystemAudio = false
                    perAppAudioEnabled = false
                case .allApps:
                    captureSystemAudio = true
                    perAppAudioEnabled = false
                case .selectedApp:
                    captureSystemAudio = true
                    perAppAudioEnabled = true
                }
            }
        )
    }

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            videoTab
                .tabItem { Label("Video", systemImage: "video") }
                .tag(SettingsTab.video)

            audioTab
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.audio)

            hotkeysTab
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsTab.hotkeys)

            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .onAppear {
            selectedTab = .general
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayMacSettingsShouldOpenGeneral)) { _ in
            selectedTab = .general
        }
        .task {
            loadMicrophones()
            await loadDisplays()
            syncLaunchAtLoginState()
        }
        .onChange(of: qualityPresetRawValue) { _, newValue in
            applyQualityPresetIfNeeded(newValue)
        }
        .onChange(of: videoCodecRawValue) { _, _ in
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: captureResolutionRawValue) { _, _ in
            markQualityPresetAsCustomIfNeeded()
        }
        .onChange(of: frameRate) { _, _ in
            markQualityPresetAsCustomIfNeeded()
        }
        .onChange(of: bitrateMbps) { _, newValue in
            if !bitrateSliderIsEditing {
                bitrateSliderValue = newValue
            }
            markQualityPresetAsCustomIfNeeded()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            applyLaunchAtLogin(newValue)
        }
        .onChange(of: captureModeRawValue) { _, _ in
            validateDisplay2Selection()
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: captureDisplayID) { _, _ in
            validateDisplay2Selection()
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: captureDisplayID2) { _, _ in
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: dualCaptureSaveModeRawValue) { _, _ in
            updateBitrateForCurrentPresetIfNeeded()
        }
    }

    private func validateDisplay2Selection() {
        let remaining = displays.filter { $0.id != captureDisplayID }
        if !remaining.contains(where: { $0.id == captureDisplayID2 }) {
            captureDisplayID2 = remaining.first?.id ?? ""
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                Stepper(value: $bufferDurationSeconds, in: 15...300, step: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .foregroundStyle(AppTheme.accent)
                        Text("Buffer duration: \(bufferDurationSeconds) seconds")
                    }
                }
            } header: {
                sectionHeader(icon: "clock.arrow.circlepath", title: "Replay")
            }

            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Output directory")
                    Spacer()
                    Text(outputDirectoryPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Button("Choose Folder…") {
                    chooseOutputDirectory()
                }
                .buttonStyle(AccentButtonStyle())
            } header: {
                sectionHeader(icon: "folder", title: "Storage")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Auto-start recording on launch", isOn: $autoStartRecordingOnLaunch)
            } header: {
                sectionHeader(icon: "power", title: "Startup")
            }

            if let launchAtLoginError {
                Section {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var videoTab: some View {
        Form {
            Section {
                Picker("Codec", selection: $videoCodecRawValue) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec.rawValue)
                    }
                }

                Picker("Capture mode", selection: $captureModeRawValue) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                if displays.isEmpty {
                    HStack {
                        Text("Capture source")
                        Spacer()
                        Text(displayLoadError ?? "No displays available yet")
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    Picker("Display 1", selection: $captureDisplayID) {
                        ForEach(displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }

                    if captureModeRawValue == CaptureMode.dualSideBySide.rawValue {
                        Picker("Display 2", selection: $captureDisplayID2) {
                            ForEach(dualDisplayOptions) { display in
                                Text(display.name).tag(display.id)
                            }
                        }

                        Picker("Save dual recording as", selection: $dualCaptureSaveModeRawValue) {
                            ForEach(DualCaptureSaveMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                    }
                }
            } header: {
                sectionHeader(icon: "camera", title: "Capture")
            }

            Section {
                Picker("Resolution", selection: $captureResolutionRawValue) {
                    ForEach(CaptureResolution.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                if captureResolutionRawValue == CaptureResolution.custom.rawValue {
                    Stepper(value: $customCaptureWidth, in: 640...7680, step: 16) {
                        Text("Custom width: \(customCaptureWidth)")
                    }
                    Stepper(value: $customCaptureHeight, in: 360...4320, step: 16) {
                        Text("Custom height: \(customCaptureHeight)")
                    }
                }

                Picker("Frame rate", selection: $frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text(bitrateValueLabel)
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(
                        value: $bitrateSliderValue,
                        in: 10...50,
                        step: 1,
                        onEditingChanged: handleBitrateSliderEditingChanged
                    )
                        .tint(AppTheme.accent)
                    HStack(spacing: 8) {
                        Label(bitrateScopeLabel, systemImage: "info.circle")
                        Spacer()
                        Text(recommendedBitrateLabel)
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
                }

                Picker("Quality preset", selection: $qualityPresetRawValue) {
                    ForEach(QualityPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
            } header: {
                sectionHeader(icon: "film.stack", title: "Encoding")
            }

            Section {
                Label("Encoding changes apply automatically and reset the video replay buffer.", systemImage: "bolt.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            }

            Section {
                Toggle("Extended replay buffer", isOn: longBufferToggleBinding)

                Picker("Long buffer duration", selection: $longBufferDurationMinutes) {
                    ForEach(LongBufferDuration.allCases) { duration in
                        Text(duration.title).tag(duration.rawValue)
                    }
                }
                .disabled(!longBufferEnabled)

                Label(longBufferWarningText, systemImage: "externaldrive.badge.timemachine")
                    .foregroundStyle(longBufferEnabled ? .orange : AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            } header: {
                sectionHeader(icon: "clock.badge.exclamationmark", title: "Long Buffer")
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Section {
                Picker("System audio", selection: systemAudioModeBinding) {
                    ForEach(SystemAudioMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if systemAudioModeBinding.wrappedValue == .selectedApp {
                    if audioApplications.isEmpty {
                        HStack {
                            Text("Audio app")
                            Spacer()
                            Text("No capturable apps detected")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    } else {
                        Picker("Audio app", selection: $perAppAudioBundleID) {
                            ForEach(audioApplications) { app in
                                Text(app.name).tag(app.bundleID)
                            }
                        }
                    }

                    Label(selectedAppAudioHelpText, systemImage: "info.circle")
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(size: 12, design: .rounded))
                }

                Toggle("Capture microphone", isOn: $captureMicrophone)
                Toggle("Exclude ReplayMac audio", isOn: $excludeOwnAppAudio)
                    .disabled(systemAudioModeBinding.wrappedValue == .off)
            } header: {
                sectionHeader(icon: "waveform", title: "Sources")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("System audio volume")
                        Spacer()
                        Text("\(Int(systemAudioVolume * 100))%")
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $systemAudioVolume, in: 0...1, step: 0.05)
                        .tint(AppTheme.accent)
                }
                .disabled(!captureSystemAudio)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Microphone volume")
                        Spacer()
                        Text("\(Int(microphoneVolume * 100))%")
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $microphoneVolume, in: 0...1, step: 0.05)
                        .tint(AppTheme.accent)
                }
                .disabled(!captureMicrophone)
            } header: {
                sectionHeader(icon: "speaker.wave.2", title: "Levels")
            }

            Section {
                if microphones.isEmpty {
                    HStack {
                        Text("Mic device")
                        Spacer()
                        Text("No microphones detected")
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    Picker("Mic device", selection: $microphoneID) {
                        ForEach(microphones) { microphone in
                            Text(microphone.name).tag(microphone.id)
                        }
                    }

                    Label("Changing mic restarts the mic track; recording continues.", systemImage: "info.circle")
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(size: 12, design: .rounded))
                }
            } header: {
                sectionHeader(icon: "mic", title: "Microphone")
            }

            Section {
                Label("Audio source changes apply automatically.", systemImage: "bolt.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeysTab: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Save clip", name: .saveClip)
                KeyboardShortcuts.Recorder("Start/stop recording", name: .toggleRecording)
            } header: {
                sectionHeader(icon: "bolt.fill", title: "Primary")
            }

            Section {
                KeyboardShortcuts.Recorder("Save last 15 seconds", name: .saveLast15Seconds)
                KeyboardShortcuts.Recorder("Save last 60 seconds", name: .saveLast60Seconds)
            } header: {
                sectionHeader(icon: "stopwatch", title: "Quick Presets")
            }
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Memory cap")
                        Spacer()
                        Text(memoryCapLabel)
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $memoryCapMB, in: 256...4096, step: 64)
                        .tint(AppTheme.accent)
                }

                Label("Total memory shared across all replay buffers. Lower values evict oldest footage sooner.", systemImage: "info.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))

                Stepper(value: $queueDepth, in: 3...10) {
                    Text("SCK queue depth: \(queueDepth)")
                }
            } header: {
                sectionHeader(icon: "cpu", title: "Performance")
            }

            Section {
                Toggle("Play audio cue on save", isOn: $playAudioCueOnSave)
                Toggle("Show notification on save", isOn: $showNotificationOnSave)
            } header: {
                sectionHeader(icon: "speaker.wave.2.bubble.left", title: "Feedback")
            }
        }
        .formStyle(.grouped)
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.bottom, 2)
    }

    private var memoryCapLabel: String {
        if memoryCapMB >= 1024 {
            return String(format: "%.1f GB", memoryCapMB / 1024)
        }
        return "\(Int(memoryCapMB)) MB"
    }

    private var bitrateValueLabel: String {
        "\(Int(bitrateSliderValue)) Mbps"
    }

    private var bitrateScopeLabel: String {
        if captureModeRawValue == CaptureMode.dualSideBySide.rawValue,
           dualCaptureSaveModeRawValue == DualCaptureSaveMode.separateFiles.rawValue {
            return "Applies per display file"
        }
        return "Applies to the saved video stream"
    }

    private var recommendedBitrateLabel: String {
        "Recommended: \(Int(recommendedBitrateMbps())) Mbps"
    }

    private var selectedAppAudioHelpText: String {
        let appName = audioApplications.first { $0.bundleID == perAppAudioBundleID }?.name ?? "the selected app"
        return "Only \(appName) audio will be recorded. If \(appName) is unavailable, no system audio is captured."
    }

    private var longBufferToggleBinding: Binding<Bool> {
        Binding(
            get: { longBufferEnabled },
            set: { newValue in
                if newValue {
                    longBufferWarningAccepted = true
                }
                longBufferEnabled = newValue
            }
        )
    }

    private var longBufferWarningText: String {
        let duration = LongBufferDuration(rawValue: longBufferDurationMinutes) ?? .fiveMinutes
        let estimatedGB = estimatedLongBufferDiskGB(minutes: duration.rawValue)
        return "Opt-in only. Uses temporary disk space while recording, writes continuously to the SSD, and may use about \(estimatedGB) GB at your current bitrate before old segments rotate."
    }

    private func estimatedLongBufferDiskGB(minutes: Int) -> String {
        let videoMbps = bitrateMbps
        let audioMbps = (systemAudioModeBinding.wrappedValue == .off ? 0 : 0.2) + (captureMicrophone ? 0.2 : 0)
        let totalMbps = videoMbps + audioMbps
        let bytes = totalMbps * 1_000_000 / 8 * Double(minutes * 60)
        return String(format: "%.1f", bytes / 1_000_000_000)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Clip Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: outputDirectoryPath, directoryHint: .isDirectory)

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        let path = selectedURL.standardizedFileURL.path(percentEncoded: false)
        outputDirectoryPath = path
        Defaults[.outputDirectoryPath] = path
        UserDefaults.standard.set(path, forKey: "outputDirectoryPath")
        UserDefaults.standard.synchronize()
    }

    private func applyQualityPresetIfNeeded(_ presetRawValue: String) {
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

    private func markQualityPresetAsCustomIfNeeded() {
        if !isApplyingQualityPreset && qualityPresetRawValue != QualityPreset.custom.rawValue {
            qualityPresetRawValue = QualityPreset.custom.rawValue
        }
    }

    private func updateBitrateForCurrentPresetIfNeeded() {
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

    private func finishApplyingQualityPresetOnNextRunLoop() {
        Task { @MainActor in
            isApplyingQualityPreset = false
        }
    }

    private func handleBitrateSliderEditingChanged(_ isEditing: Bool) {
        bitrateSliderIsEditing = isEditing

        if !isEditing {
            commitBitrateSliderValue()
        }
    }

    private func commitBitrateSliderValue() {
        let committedValue = Double(Int(bitrateSliderValue.rounded()))
        bitrateSliderValue = committedValue

        guard bitrateMbps != committedValue else { return }
        bitrateMbps = committedValue
    }

    private func recommendedBitrateMbps() -> Double {
        recommendedBitrateMbps(
            preset: QualityPreset(rawValue: qualityPresetRawValue) ?? .quality,
            resolutionRawValue: captureResolutionRawValue,
            frameRate: frameRate
        )
    }

    private func recommendedBitrateMbps(
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

    private func effectiveVideoDimensions(resolutionRawValue: String) -> (width: Int, height: Int) {
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

    private func syncLaunchAtLoginState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Launch at login update failed: \(error.localizedDescription)"
            launchAtLogin.toggle()
        }
    }

    private func loadMicrophones() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        microphones = discoverySession.devices.map {
            MicrophoneOption(id: $0.uniqueID, name: $0.localizedName)
        }

        if microphones.isEmpty {
            microphoneID = ""
        } else if !microphones.contains(where: { $0.id == microphoneID }) {
            microphoneID = microphones[0].id
        }
    }

    private func loadDisplays() async {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let options = shareableContent.displays.map { display in
                DisplayOption(
                    id: String(display.displayID),
                    name: "Display \(display.displayID) (\(display.width)x\(display.height))",
                    width: Int(display.width),
                    height: Int(display.height)
                )
            }

            await MainActor.run {
                displays = options
                displayLoadError = nil
                audioApplications = shareableContent.applications
                    .compactMap { app in
                        let bundleID = app.bundleIdentifier
                        guard !bundleID.isEmpty else {
                            return nil
                        }
                        return AudioApplicationOption(
                            bundleID: bundleID,
                            name: app.applicationName.isEmpty ? bundleID : app.applicationName
                        )
                    }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                if options.isEmpty {
                    captureDisplayID = ""
                    captureDisplayID2 = ""
                } else {
                    if !options.contains(where: { $0.id == captureDisplayID }) {
                        captureDisplayID = options[0].id
                    }

                    let remainingForDisplay2 = options.filter { $0.id != captureDisplayID }
                    if !remainingForDisplay2.contains(where: { $0.id == captureDisplayID2 }) {
                        captureDisplayID2 = remainingForDisplay2.first?.id ?? ""
                    }
                }

                if perAppAudioBundleID.isEmpty || !audioApplications.contains(where: { $0.bundleID == perAppAudioBundleID }) {
                    perAppAudioBundleID = audioApplications.first?.bundleID ?? ""
                }
            }
        } catch {
            await MainActor.run {
                displays = []
                audioApplications = []
                displayLoadError = error.localizedDescription
            }
        }
    }
}

private enum SettingsTab: Hashable {
    case general
    case video
    case audio
    case hotkeys
    case advanced
}

private enum SystemAudioMode: String, CaseIterable, Identifiable {
    case off
    case allApps
    case selectedApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .allApps:
            return "All apps"
        case .selectedApp:
            return "Selected app only"
        }
    }
}

private struct DisplayOption: Identifiable, Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int
}

private struct MicrophoneOption: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct AudioApplicationOption: Identifiable, Hashable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}
