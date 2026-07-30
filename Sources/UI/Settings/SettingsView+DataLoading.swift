import AVFoundation
import AppKit
import Capture
import CoreGraphics
import Defaults
@preconcurrency import ScreenCaptureKit

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
            await MainActor.run {
                let connected = shareableContent.displays.map { display -> DisplayOption in
                    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    let pointPixelScale = max(Double(filter.pointPixelScale), 1.0)
                    let displayID = CGDirectDisplayID(display.displayID)
                    let displayMode = CGDisplayCopyDisplayMode(displayID)
                    let pixelWidth = max(CGDisplayPixelsWide(displayID), displayMode?.pixelWidth ?? 0)
                    let pixelHeight = max(CGDisplayPixelsHigh(displayID), displayMode?.pixelHeight ?? 0)

                    return DisplayOption(
                        id: DisplayIdentity.stableKey(for: displayID),
                        name: displayName(for: displayID, width: Int(display.width), height: Int(display.height)),
                        width: Int(display.width),
                        height: Int(display.height),
                        pointPixelScale: pointPixelScale,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight,
                        isConnected: true
                    )
                }

                // A selection that isn't attached right now stays selected. Overwriting it
                // here is what used to lose the user's screen choice whenever a display ID
                // changed or an external monitor was slow to wake after login.
                migrateLegacyDisplaySelections(connected: connected)
                displays = connected + placeholdersForDisconnectedSelections(connected: connected)
                displayLoadError = nil
                updateAudioApplications(from: shareableContent.applications)

                if captureDisplayID.isEmpty, let first = connected.first {
                    captureDisplayID = first.id
                }
                if captureDisplayID2.isEmpty,
                   let firstOther = connected.first(where: { $0.id != captureDisplayID }) {
                    captureDisplayID2 = firstOther.id
                }

                if !displays.isEmpty {
                    validateCaptureResolutionSelection()
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

    /// Rewrite raw-`CGDirectDisplayID` selections saved by older builds into stable keys,
    /// while the display they point at is still attached to identify it.
    func migrateLegacyDisplaySelections(connected: [DisplayOption]) {
        guard !connected.isEmpty else { return }
        let online = DisplayIdentity.onlineDisplayIDs()

        if let migrated = DisplayIdentity.migratedKey(forLegacyValue: captureDisplayID, among: online) {
            captureDisplayID = migrated
        }
        if let migrated = DisplayIdentity.migratedKey(forLegacyValue: captureDisplayID2, among: online) {
            captureDisplayID2 = migrated
        }
    }

    /// Entries standing in for selected displays that aren't attached right now, so the
    /// picker keeps showing the user's choice instead of silently jumping to another screen.
    func placeholdersForDisconnectedSelections(connected: [DisplayOption]) -> [DisplayOption] {
        let connectedIDs = Set(connected.map(\.id))
        let selections = [captureDisplayID, captureDisplayID2]
            .filter { !$0.isEmpty && !connectedIDs.contains($0) }

        return Array(Set(selections)).sorted().map { id in
            DisplayOption(
                id: id,
                name: "Previously selected display (not connected)",
                width: 1920,
                height: 1080,
                pointPixelScale: 1,
                pixelWidth: 1920,
                pixelHeight: 1080,
                isConnected: false
            )
        }
    }

    func displayName(for displayID: CGDirectDisplayID, width: Int, height: Int) -> String {
        let localizedName = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }?.localizedName

        let label = localizedName ?? (CGDisplayIsBuiltin(displayID) != 0 ? "Built-in Display" : "Display \(displayID)")
        return "\(label) (\(width)x\(height) logical)"
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
