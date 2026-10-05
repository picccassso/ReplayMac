import SwiftUI
import AppKit
import Defaults

public struct SettingsView: View {
    @Default(.bufferDurationSeconds) var bufferDurationSeconds
    @Default(.outputDirectoryPath) var outputDirectoryPath
    @Default(.launchAtLogin) var launchAtLogin
    @Default(.autoStartRecordingOnLaunch) var autoStartRecordingOnLaunch
    @Default(.resumeRecordingAfterWake) var resumeRecordingAfterWake
    @Default(.autoRecordGamesEnabled) var autoRecordGamesEnabled
    @Default(.autoRecordStopWhenGameCloses) var autoRecordStopWhenGameCloses
    @Default(.autoRecordGameBundleIDs) var autoRecordGameBundleIDs
    @Default(.autoRecordExcludedBundleIDs) var autoRecordExcludedBundleIDs

    @Default(.captureHDR) var captureHDR
    @Default(.videoCodec) var videoCodecRawValue
    @Default(.captureMode) var captureModeRawValue
    @Default(.captureDisplayID) var captureDisplayID
    @Default(.captureDisplayID2) var captureDisplayID2
    @Default(.captureDisplayPriorities) var captureDisplayPriorities
    @Default(.dualCaptureSaveMode) var dualCaptureSaveModeRawValue
    @Default(.captureResolution) var captureResolutionRawValue
    @Default(.customCaptureWidth) var customCaptureWidth
    @Default(.customCaptureHeight) var customCaptureHeight
    @Default(.frameRate) var frameRate
    @Default(.bitrateMbps) var bitrateMbps
    @Default(.qualityPreset) var qualityPresetRawValue

    @Default(.captureSystemAudio) var captureSystemAudio
    @Default(.captureMicrophone) var captureMicrophone
    @Default(.mergeAudioTracks) var mergeAudioTracks
    @Default(.microphoneID) var microphoneID
    @Default(.excludeOwnAppAudio) var excludeOwnAppAudio
    @Default(.perAppAudioEnabled) var perAppAudioEnabled
    @Default(.perAppAudioBundleID) var perAppAudioBundleID
    @Default(.systemAudioVolume) var systemAudioVolume
    @Default(.microphoneVolume) var microphoneVolume
    @Default(.isSystemAudioMuted) var isSystemAudioMuted
    @Default(.isMicrophoneMuted) var isMicrophoneMuted

    @Default(.memoryCapMB) var memoryCapMB
    @Default(.queueDepth) var queueDepth
    @Default(.playAudioCueOnSave) var playAudioCueOnSave
    @Default(.showNotificationOnSave) var showNotificationOnSave
    @Default(.clipFilenameTemplate) var clipFilenameTemplate
    @Default(.clipDateFormat) var clipDateFormat
    @Default(.clipTimeFormat) var clipTimeFormat
    @Default(.longBufferEnabled) var longBufferEnabled
    @Default(.longBufferDurationMinutes) var longBufferDurationMinutes
    @Default(.longBufferWarningAccepted) var longBufferWarningAccepted
    @Default(.captureProfilesJSON) var captureProfilesJSON

    @State var displays: [DisplayOption] = []
    @State var audioApplications: [AudioApplicationOption] = []
    @State var microphones: [MicrophoneOption] = []
    @State var captureProfiles: [CaptureProfile] = []
    @State var selectedProfileID: UUID?
    @State var newProfileName = ""
    @State var selectedProfileNameDraft = ""
    @State var profileErrorMessage: String?
    @State var launchAtLoginError: String?
    @State var displayLoadError: String?
    @State var bitrateSliderValue = Defaults[.bitrateMbps]
    @State var bitrateSliderIsEditing = false
    @State var isApplyingQualityPreset = false
    @Binding var selectedTab: SettingsTab
    var isVisible: Bool

    public init(selectedTab: Binding<SettingsTab>, isVisible: Bool = true) {
        self._selectedTab = selectedTab
        self.isVisible = isVisible
    }

    public var body: some View {
        Group {
            switch selectedTab {
            case .general: generalTab
            case .video: videoTab
            case .audio: audioTab
            case .profiles: profilesTab
            case .hotkeys: hotkeysTab
            case .advanced: advancedTab
            }
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: isVisible) { _, _ in refreshAudioLevelPreview() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshAudioApplicationsAfterWorkspaceChange()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshAudioApplicationsAfterWorkspaceChange()
        }
        .task {
            loadCaptureProfiles()
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
            validateCaptureResolutionSelection()
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: captureDisplayID) { _, _ in
            validateDisplay2Selection()
            validateCaptureResolutionSelection()
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: captureDisplayID2) { _, _ in
            validateCaptureResolutionSelection()
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: captureDisplayPriorities) { _, newValue in
            if let first = newValue.first(where: { !$0.isEmpty }), captureDisplayID != first {
                captureDisplayID = first
            }
            validateCaptureResolutionSelection()
            updateBitrateForCurrentPresetIfNeeded()
        }
        .onChange(of: dualCaptureSaveModeRawValue) { _, _ in
            updateBitrateForCurrentPresetIfNeeded()
        }
    }
}
