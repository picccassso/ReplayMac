import SwiftUI
import AppKit
import Branding
import Defaults
import ServiceManagement
import Save

extension SettingsView {
    var generalTab: some View {
        Form {
            Section {
                Stepper(value: $bufferDurationSeconds, in: 15...300, step: 5) {
                    Text("Buffer duration: \(bufferDurationSeconds) seconds")
                }
            } header: {
                Text("Replay")
            }

            Section {
                LabeledContent("Output directory") {
                    HStack(spacing: 10) {
                        Text(
                            outputDirectoryPath.isEmpty
                                ? "No folder selected"
                                : UserHome.abbreviateForDisplay(outputDirectoryPath)
                        )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(AppTheme.textSecondary)
                            .help(outputDirectoryPath.isEmpty ? "No folder selected" : outputDirectoryPath)
                        Button("Choose…") {
                            chooseOutputDirectory()
                        }
                    }
                }
            } header: {
                Text("Storage")
            }

            Section {
                TextField("File name template", text: $clipFilenameTemplate)
                    .textFieldStyle(.roundedBorder)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Preview")
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text("\(filenamePreview).mp4")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(.callout, design: .monospaced))
                }

                Picker("Date format", selection: $clipDateFormat) {
                    ForEach(FilenameTemplate.dateFormats, id: \.self) { pattern in
                        Text(FilenameTemplate.example(for: pattern)).tag(pattern)
                    }
                }

                Picker("Time format", selection: $clipTimeFormat) {
                    ForEach(FilenameTemplate.timeFormats, id: \.self) { pattern in
                        Text(FilenameTemplate.example(for: pattern)).tag(pattern)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(FilenameTemplate.tokens, id: \.token) { entry in
                        HStack(spacing: 8) {
                            Text(entry.token)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppTheme.accent)
                            Text(entry.description)
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }

                Button("Reset to Default") {
                    clipFilenameTemplate = FilenameTemplate.default
                    clipDateFormat = FilenameTemplate.defaultDateFormat
                    clipTimeFormat = FilenameTemplate.defaultTimeFormat
                }
                .buttonStyle(.link)
                .disabled(
                    clipFilenameTemplate == FilenameTemplate.default
                        && clipDateFormat == FilenameTemplate.defaultDateFormat
                        && clipTimeFormat == FilenameTemplate.defaultTimeFormat
                )
            } header: {
                Text("Clip File Names")
            } footer: {
                Text("Applied to new clips. \"\(FilenameTemplate.tokens[0].token)\" uses the app that was in front when you saved.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Picker("Open window to", selection: $mainWindowStartPage) {
                    ForEach(MainWindowStartPage.allCases) { page in
                        Text(page.title).tag(page.rawValue)
                    }
                }
                .help("The page shown when you open \(AppBranding.name) from the Dock or at launch. The menu bar's Clip Library and Settings items always go to their own pages.")
                Toggle("Auto-start recording on launch", isOn: $autoStartRecordingOnLaunch)
                    .disabled(autoRecordGamesEnabled)
                Toggle("Resume recording after wake", isOn: $resumeRecordingAfterWake)
            } header: {
                Text("Startup")
            } footer: {
                if autoRecordGamesEnabled {
                    Text("Auto-start is off while “Automatically record while playing games” is on — the app stays idle and records only when a game is running.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            gamesSection

            if let launchAtLoginError {
                Section {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var filenamePreview: String {
        FilenameTemplate.resolve(
            template: clipFilenameTemplate,
            appName: "Rocket League",
            dateFormat: clipDateFormat,
            timeFormat: clipTimeFormat
        )
    }

    func chooseOutputDirectory() {
        if let path = OutputDirectoryAccess.promptUserToChoose() {
            outputDirectoryPath = path
        }
    }

    func syncLaunchAtLoginState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func applyLaunchAtLogin(_ enabled: Bool) {
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
}
