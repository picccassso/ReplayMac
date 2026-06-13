import SwiftUI

extension SettingsView {
    var profilesTab: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Profile name", text: $newProfileName)
                    Button {
                        saveCurrentSettingsAsProfile()
                    } label: {
                        Label("Save Current", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                sectionHeader(icon: "plus.rectangle.on.rectangle", title: "Create")
            }

            Section {
                if captureProfiles.isEmpty {
                    Text("No profiles saved yet.")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    List(selection: $selectedProfileID) {
                        ForEach(captureProfiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                Text(profile.summary)
                                    .font(.system(size: 12, weight: .regular, design: .rounded))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .padding(.vertical, 4)
                            .tag(profile.id)
                        }
                    }
                    .frame(minHeight: 180)
                }

                HStack {
                    Button {
                        applySelectedProfile()
                    } label: {
                        Label("Apply", systemImage: "checkmark.circle")
                    }
                    .disabled(selectedProfile == nil)

                    Button {
                        overwriteSelectedProfile()
                    } label: {
                        Label("Update From Current Settings", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(selectedProfile == nil)

                    Spacer()

                    Button(role: .destructive) {
                        deleteSelectedProfile()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedProfile == nil)
                }
            } header: {
                sectionHeader(icon: "rectangle.stack", title: "Saved Profiles")
            }

            if let selectedProfile {
                Section {
                    HStack(spacing: 8) {
                        TextField("Profile name", text: $selectedProfileNameDraft)
                        Button {
                            renameSelectedProfile()
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .disabled(!canRenameSelectedProfile)
                    }

                    ProfileDetailRow(label: "Video", value: selectedProfile.videoDetail)
                    ProfileDetailRow(label: "Capture", value: selectedProfile.captureDetail)
                    ProfileDetailRow(label: "Audio", value: selectedProfile.audioDetail)
                    ProfileDetailRow(label: "Buffer", value: selectedProfile.bufferDetail)
                } header: {
                    sectionHeader(icon: "info.circle", title: "Selected Profile")
                }
            }

            if let profileErrorMessage {
                Section {
                    Label(profileErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedProfileID) { _, _ in
            syncSelectedProfileNameDraft()
        }
        .onAppear {
            syncSelectedProfileNameDraft()
        }
    }

    var selectedProfile: CaptureProfile? {
        guard let selectedProfileID else { return nil }
        return captureProfiles.first { $0.id == selectedProfileID }
    }

    var canRenameSelectedProfile: Bool {
        guard let selectedProfile else { return false }
        let trimmed = selectedProfileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != selectedProfile.name
    }

    func loadCaptureProfiles() {
        guard let data = captureProfilesJSON.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([CaptureProfile].self, from: data) else {
            captureProfiles = []
            return
        }
        captureProfiles = profiles.sorted { $0.updatedAt > $1.updatedAt }
        selectedProfileID = selectedProfileID ?? captureProfiles.first?.id
        syncSelectedProfileNameDraft()
    }

    func persistCaptureProfiles() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(captureProfiles)
            captureProfilesJSON = String(decoding: data, as: UTF8.self)
            profileErrorMessage = nil
        } catch {
            profileErrorMessage = "Could not save profiles: \(error.localizedDescription)"
        }
    }

    func saveCurrentSettingsAsProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let profile = makeProfile(named: name, id: UUID(), createdAt: Date())
        captureProfiles.insert(profile, at: 0)
        selectedProfileID = profile.id
        selectedProfileNameDraft = profile.name
        newProfileName = ""
        persistCaptureProfiles()
    }

    func overwriteSelectedProfile() {
        guard let selectedProfile else { return }
        let replacement = makeProfile(
            named: selectedProfile.name,
            id: selectedProfile.id,
            createdAt: selectedProfile.createdAt
        )

        if let index = captureProfiles.firstIndex(where: { $0.id == selectedProfile.id }) {
            captureProfiles[index] = replacement
            captureProfiles.sort { $0.updatedAt > $1.updatedAt }
            selectedProfileID = replacement.id
            selectedProfileNameDraft = replacement.name
            persistCaptureProfiles()
        }
    }

    func renameSelectedProfile() {
        guard let selectedProfile else { return }
        let name = selectedProfileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if let index = captureProfiles.firstIndex(where: { $0.id == selectedProfile.id }) {
            captureProfiles[index].name = name
            captureProfiles[index].updatedAt = Date()
            captureProfiles.sort { $0.updatedAt > $1.updatedAt }
            selectedProfileID = selectedProfile.id
            selectedProfileNameDraft = name
            persistCaptureProfiles()
        }
    }

    func deleteSelectedProfile() {
        guard let selectedProfileID else { return }
        captureProfiles.removeAll { $0.id == selectedProfileID }
        self.selectedProfileID = captureProfiles.first?.id
        syncSelectedProfileNameDraft()
        persistCaptureProfiles()
    }

    func applySelectedProfile() {
        guard let profile = selectedProfile else { return }

        isApplyingQualityPreset = true

        videoCodecRawValue = profile.videoCodecRawValue
        captureModeRawValue = profile.captureModeRawValue
        captureDisplayID = profile.captureDisplayID
        captureDisplayID2 = profile.captureDisplayID2
        dualCaptureSaveModeRawValue = profile.dualCaptureSaveModeRawValue
        captureResolutionRawValue = profile.captureResolutionRawValue
        customCaptureWidth = profile.customCaptureWidth
        customCaptureHeight = profile.customCaptureHeight
        frameRate = profile.frameRate
        bitrateMbps = profile.bitrateMbps
        bitrateSliderValue = profile.bitrateMbps
        qualityPresetRawValue = profile.qualityPresetRawValue

        captureSystemAudio = profile.captureSystemAudio
        captureMicrophone = profile.captureMicrophone
        mergeAudioTracks = profile.mergeAudioTracks ?? true
        microphoneID = profile.microphoneID
        excludeOwnAppAudio = profile.excludeOwnAppAudio
        perAppAudioEnabled = profile.perAppAudioEnabled
        perAppAudioBundleID = profile.perAppAudioBundleID
        systemAudioVolume = profile.systemAudioVolume
        microphoneVolume = profile.microphoneVolume

        memoryCapMB = profile.memoryCapMB
        queueDepth = profile.queueDepth
        longBufferEnabled = profile.longBufferEnabled
        longBufferDurationMinutes = profile.longBufferDurationMinutes

        finishApplyingQualityPresetOnNextRunLoop()
    }

    func makeProfile(named name: String, id: UUID, createdAt: Date) -> CaptureProfile {
        CaptureProfile(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: Date(),
            videoCodecRawValue: videoCodecRawValue,
            captureModeRawValue: captureModeRawValue,
            captureDisplayID: captureDisplayID,
            captureDisplayID2: captureDisplayID2,
            dualCaptureSaveModeRawValue: dualCaptureSaveModeRawValue,
            captureResolutionRawValue: captureResolutionRawValue,
            customCaptureWidth: customCaptureWidth,
            customCaptureHeight: customCaptureHeight,
            frameRate: frameRate,
            bitrateMbps: bitrateMbps,
            qualityPresetRawValue: qualityPresetRawValue,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: captureMicrophone,
            mergeAudioTracks: mergeAudioTracks,
            microphoneID: microphoneID,
            excludeOwnAppAudio: excludeOwnAppAudio,
            perAppAudioEnabled: perAppAudioEnabled,
            perAppAudioBundleID: perAppAudioBundleID,
            systemAudioVolume: systemAudioVolume,
            microphoneVolume: microphoneVolume,
            memoryCapMB: memoryCapMB,
            queueDepth: queueDepth,
            longBufferEnabled: longBufferEnabled,
            longBufferDurationMinutes: longBufferDurationMinutes
        )
    }

    func syncSelectedProfileNameDraft() {
        selectedProfileNameDraft = selectedProfile?.name ?? ""
    }
}

private struct ProfileDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(AppTheme.textSecondary)
            Text(value)
            Spacer()
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }
}

private extension CaptureProfile {
    var videoDetail: String {
        "\(videoCodecRawValue.uppercased()) · \(captureResolutionRawValue) · \(frameRate) fps · \(Int(bitrateMbps)) Mbps"
    }

    var captureDetail: String {
        if captureModeRawValue == CaptureMode.dualSideBySide.rawValue {
            return "Dual display · \(dualCaptureSaveModeRawValue)"
        }
        return "Single display"
    }

    var audioDetail: String {
        let system = !captureSystemAudio ? "Off" : (perAppAudioEnabled ? "Selected app" : "All apps")
        let mic = captureMicrophone ? "Mic on" : "Mic off"
        let merge = (mergeAudioTracks ?? true) ? "Merged" : "Separate tracks"
        return "\(system) · \(mic) · \(merge)"
    }

    var bufferDetail: String {
        let longBuffer = longBufferEnabled ? "\(longBufferDurationMinutes)m long buffer" : "Long buffer off"
        return "\(Int(memoryCapMB)) MB cap · queue \(queueDepth) · \(longBuffer)"
    }
}
