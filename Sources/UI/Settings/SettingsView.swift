import SwiftUI
import AppKit
import Defaults

public extension Notification.Name {
    static let replayMacSettingsShouldOpenGeneral = Notification.Name("replayMacSettingsShouldOpenGeneral")
}

public struct SettingsView: View {
    @Default(.bufferDurationSeconds) var bufferDurationSeconds
    @Default(.outputDirectoryPath) var outputDirectoryPath
    @Default(.launchAtLogin) var launchAtLogin
    @Default(.autoStartRecordingOnLaunch) var autoStartRecordingOnLaunch

    @Default(.videoCodec) var videoCodecRawValue
    @Default(.captureMode) var captureModeRawValue
    @Default(.captureDisplayID) var captureDisplayID
    @Default(.captureDisplayID2) var captureDisplayID2
    @Default(.dualCaptureSaveMode) var dualCaptureSaveModeRawValue
    @Default(.captureResolution) var captureResolutionRawValue
    @Default(.customCaptureWidth) var customCaptureWidth
    @Default(.customCaptureHeight) var customCaptureHeight
    @Default(.frameRate) var frameRate
    @Default(.bitrateMbps) var bitrateMbps
    @Default(.qualityPreset) var qualityPresetRawValue

    @Default(.captureSystemAudio) var captureSystemAudio
    @Default(.captureMicrophone) var captureMicrophone
    @Default(.microphoneID) var microphoneID
    @Default(.excludeOwnAppAudio) var excludeOwnAppAudio
    @Default(.perAppAudioEnabled) var perAppAudioEnabled
    @Default(.perAppAudioBundleID) var perAppAudioBundleID
    @Default(.systemAudioVolume) var systemAudioVolume
    @Default(.microphoneVolume) var microphoneVolume

    @Default(.memoryCapMB) var memoryCapMB
    @Default(.queueDepth) var queueDepth
    @Default(.playAudioCueOnSave) var playAudioCueOnSave
    @Default(.showNotificationOnSave) var showNotificationOnSave
    @Default(.longBufferEnabled) var longBufferEnabled
    @Default(.longBufferDurationMinutes) var longBufferDurationMinutes
    @Default(.longBufferWarningAccepted) var longBufferWarningAccepted

    @State var displays: [DisplayOption] = []
    @State var audioApplications: [AudioApplicationOption] = []
    @State var microphones: [MicrophoneOption] = []
    @State var launchAtLoginError: String?
    @State var displayLoadError: String?
    @State var bitrateSliderValue = Defaults[.bitrateMbps]
    @State var bitrateSliderIsEditing = false
    @State var isApplyingQualityPreset = false
    @State var selectedTab = SettingsTab.general

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
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshAudioApplicationsAfterWorkspaceChange()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshAudioApplicationsAfterWorkspaceChange()
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
}
