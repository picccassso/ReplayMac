import SwiftUI
import AppKit
import Capture
import Defaults
import UniformTypeIdentifiers

extension SettingsView {
    var gamesSection: some View {
        Section {
            Toggle("Automatically record while playing games", isOn: $autoRecordGamesEnabled)

            if autoRecordGamesEnabled {
                gameAutoRecordDisclaimer

                Toggle("Stop recording when the game closes", isOn: $autoRecordStopWhenGameCloses)

                manualGamesSubSection

                excludedAppsSubSection
            }
        } header: {
            sectionHeader(icon: "gamecontroller", title: "Games")
        } footer: {
            Text("Most games are detected automatically via macOS game categorization. You can manually include unlisted games or exclude background launchers and tools.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// Explains the idle-until-game behaviour so users don't assume the feature
    /// records in the background the whole time it's switched on.
    private var gameAutoRecordDisclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .font(.system(size: 15))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("How this works")
                    .font(.callout.weight(.semibold))
                Text(gameAutoRecordDisclaimerBody)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
                .fill(AppTheme.accent.opacity(0.12))
        )
    }

    private var gameAutoRecordDisclaimerBody: String {
        let base = "The app does not record or buffer in the background while this is on. "
            + "It stays idle until you open a game, then starts recording from scratch."
        if autoRecordStopWhenGameCloses {
            return base + " When the game closes, recording stops."
        }
        return base + " Recording keeps going after the game closes until you stop it."
    }

    private var manualGamesSubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Included Games")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Menu {
                    let running = addableRunningApps(excluding: autoRecordGameBundleIDs)
                    if !running.isEmpty {
                        Section("Running Applications") {
                            ForEach(running) { app in
                                Button(app.name) { addManualGame(app.bundleID) }
                            }
                        }
                    }
                    Button("Choose Application from Disk…") {
                        promptToChooseApp { bundleID in
                            addManualGame(bundleID)
                        }
                    }
                } label: {
                    Label("Add Game…", systemImage: "plus")
                }
            }

            if autoRecordGameBundleIDs.isEmpty {
                Text("No additional games added. Games with an App Store category are detected automatically.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                ForEach(autoRecordGameBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text(gameDisplayName(for: bundleID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            removeManualGame(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from the games list")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var excludedAppsSubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Excluded Applications")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Menu {
                    Section("Popular Presets") {
                        ForEach(GameAutoRecordPresets.defaultExclusionPresets) { preset in
                            Button(preset.name) {
                                addExclusionPreset(preset)
                            }
                            .disabled(isPresetFullyExcluded(preset))
                        }
                    }

                    let running = addableRunningApps(excluding: autoRecordExcludedBundleIDs)
                    if !running.isEmpty {
                        Section("Running Applications") {
                            ForEach(running) { app in
                                Button(app.name) { addExcludedApp(app.bundleID) }
                            }
                        }
                    }

                    Section {
                        Button("Choose Application from Disk…") {
                            promptToChooseApp { bundleID in
                                addExcludedApp(bundleID)
                            }
                        }
                    }
                } label: {
                    Label("Exclude App…", systemImage: "plus")
                }
            }

            if autoRecordExcludedBundleIDs.isEmpty {
                Text("No applications excluded. Exclude game launchers (like Epic Games Launcher) or idle tools to prevent auto-recording.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                ForEach(autoRecordExcludedBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(systemName: "nosign")
                            .foregroundStyle(.orange)
                        Text(gameDisplayName(for: bundleID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            removeExcludedApp(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from excluded applications")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    func isPresetFullyExcluded(_ preset: GameAutoRecordPresets.Preset) -> Bool {
        let excluded = Set(autoRecordExcludedBundleIDs)
        return preset.bundleIDs.allSatisfy { excluded.contains($0) }
    }

    /// Currently running foreground apps that aren't already on the excluded/included list (and
    /// aren't this app), for the app pickers.
    func addableRunningApps(excluding: [String]) -> [AudioApplicationOption] {
        let existing = Set(excluding)
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AudioApplicationOption? in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != ownID,
                      !existing.contains(bundleID),
                      seen.insert(bundleID).inserted else {
                    return nil
                }
                return AudioApplicationOption(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves a stored bundle id to a readable name, checking running apps,
    /// the app bundle on disk, known presets, or falling back to the raw bundle ID.
    func gameDisplayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
            return url.deletingPathExtension().lastPathComponent
        }
        if let preset = GameAutoRecordPresets.defaultExclusionPresets.first(where: { $0.bundleIDs.contains(bundleID) }) {
            return preset.name
        }
        return bundleID
    }

    func addManualGame(_ bundleID: String) {
        guard !autoRecordGameBundleIDs.contains(bundleID) else { return }
        autoRecordGameBundleIDs.append(bundleID)
    }

    func removeManualGame(_ bundleID: String) {
        autoRecordGameBundleIDs.removeAll { $0 == bundleID }
    }

    func addExclusionPreset(_ preset: GameAutoRecordPresets.Preset) {
        for bundleID in preset.bundleIDs {
            if !autoRecordExcludedBundleIDs.contains(bundleID) {
                autoRecordExcludedBundleIDs.append(bundleID)
            }
        }
    }

    func addExcludedApp(_ bundleID: String) {
        guard !autoRecordExcludedBundleIDs.contains(bundleID) else { return }
        autoRecordExcludedBundleIDs.append(bundleID)
    }

    func removeExcludedApp(_ bundleID: String) {
        autoRecordExcludedBundleIDs.removeAll { $0 == bundleID }
    }

    func promptToChooseApp(onSelect: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")

        if panel.runModal() == .OK, let selectedURL = panel.url {
            if let bundle = Bundle(url: selectedURL), let bundleID = bundle.bundleIdentifier {
                onSelect(bundleID)
            }
        }
    }
}

