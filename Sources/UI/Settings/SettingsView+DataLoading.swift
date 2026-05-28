import AVFoundation
import Defaults
import ScreenCaptureKit

extension SettingsView {
    func loadMicrophones() {
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

    func refreshAudioApplicationsAfterWorkspaceChange() {
        Task {
            await loadAudioApplications()
            try? await Task.sleep(for: .milliseconds(700))
            await loadAudioApplications()
        }
    }

    func loadDisplays() async {
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
                updateAudioApplications(from: shareableContent.applications)

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
                audioApplications = []
                displayLoadError = error.localizedDescription
            }
        }
    }

    func loadAudioApplications() async {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await MainActor.run {
                updateAudioApplications(from: shareableContent.applications)
            }
        } catch {
            await MainActor.run {
                audioApplications = []
            }
        }
    }

    func updateAudioApplications(from applications: [SCRunningApplication]) {
        let currentSelection = perAppAudioBundleID
        audioApplications = applications
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

        if currentSelection.isEmpty || !audioApplications.contains(where: { $0.bundleID == currentSelection }) {
            perAppAudioBundleID = audioApplications.first?.bundleID ?? ""
        }
    }
}
