import SwiftUI
import AVFoundation
import Defaults
import Hotkeys
import KeyboardShortcuts
import ScreenCaptureKit
import ServiceManagement

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
    @Default(.systemAudioVolume) private var systemAudioVolume
    @Default(.microphoneVolume) private var microphoneVolume

    @Default(.memoryCapMB) private var memoryCapMB
    @Default(.queueDepth) private var queueDepth
    @Default(.playAudioCueOnSave) private var playAudioCueOnSave
    @Default(.showNotificationOnSave) private var showNotificationOnSave
    @Default(.watermarkSavedClips) private var watermarkSavedClips

    @State private var displays: [DisplayOption] = []
    @State private var microphones: [MicrophoneOption] = []
    @State private var launchAtLoginError: String?
    @State private var displayLoadError: String?

    private var dualDisplayOptions: [DisplayOption] {
        displays.filter { $0.id != captureDisplayID }
    }

    public init() {}

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            videoTab
                .tabItem { Label("Video", systemImage: "video") }

            audioTab
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }

            hotkeysTab
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }

            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .task {
            loadMicrophones()
            await loadDisplays()
            syncLaunchAtLoginState()
        }
        .onChange(of: qualityPresetRawValue) { _, newValue in
            applyQualityPresetIfNeeded(newValue)
        }
        .onChange(of: captureResolutionRawValue) { _, _ in
            markQualityPresetAsCustom()
        }
        .onChange(of: frameRate) { _, _ in
            markQualityPresetAsCustom()
        }
        .onChange(of: bitrateMbps) { _, _ in
            markQualityPresetAsCustom()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            applyLaunchAtLogin(newValue)
        }
        .onChange(of: captureModeRawValue) { _, _ in
            validateDisplay2Selection()
        }
        .onChange(of: captureDisplayID) { _, _ in
            validateDisplay2Selection()
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
                        Text("\(Int(bitrateMbps)) Mbps")
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $bitrateMbps, in: 10...50, step: 1)
                        .tint(AppTheme.accent)
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
                Label("Most changes apply automatically.", systemImage: "bolt.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Section {
                Toggle("Capture system audio", isOn: $captureSystemAudio)
                Toggle("Capture microphone", isOn: $captureMicrophone)
                Toggle("Exclude ReplayMac audio", isOn: $excludeOwnAppAudio)
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
                    .disabled(true)

                    Label("ReplayMac currently records from the macOS default input device.", systemImage: "info.circle")
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

                Stepper(value: $queueDepth, in: 3...10) {
                    Text("SCK queue depth: \(queueDepth)")
                }
            } header: {
                sectionHeader(icon: "cpu", title: "Performance")
            }

            Section {
                Toggle("Play audio cue on save", isOn: $playAudioCueOnSave)
                Toggle("Show notification on save", isOn: $showNotificationOnSave)
                Toggle("Watermark saved clips", isOn: $watermarkSavedClips)
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

        switch preset {
        case .performance:
            captureResolutionRawValue = CaptureResolution.half.rawValue
            frameRate = 30
            bitrateMbps = 15
        case .quality:
            captureResolutionRawValue = CaptureResolution.native.rawValue
            frameRate = 60
            bitrateMbps = 25
        case .ultra:
            captureResolutionRawValue = CaptureResolution.native.rawValue
            frameRate = 120
            bitrateMbps = 40
        case .custom:
            break
        }
    }

    private func markQualityPresetAsCustom() {
        if qualityPresetRawValue != QualityPreset.custom.rawValue {
            qualityPresetRawValue = QualityPreset.custom.rawValue
        }
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
                    name: "Display \(display.displayID) (\(display.width)x\(display.height))"
                )
            }

            await MainActor.run {
                displays = options
                displayLoadError = nil

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
            }
        } catch {
            await MainActor.run {
                displays = []
                displayLoadError = error.localizedDescription
            }
        }
    }
}

private struct DisplayOption: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct MicrophoneOption: Identifiable, Hashable {
    let id: String
    let name: String
}
