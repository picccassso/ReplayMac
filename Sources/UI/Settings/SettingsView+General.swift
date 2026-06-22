import SwiftUI
import AppKit
import Defaults
import ServiceManagement
import Save

extension SettingsView {
    var generalTab: some View {
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
                }
                .buttonStyle(.link)
                .disabled(clipFilenameTemplate == FilenameTemplate.default)
            } header: {
                sectionHeader(icon: "textformat", title: "Clip File Names")
            } footer: {
                Text("Applied to new clips. \"\(FilenameTemplate.tokens[0].token)\" uses the app that was in front when you saved.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Auto-start recording on launch", isOn: $autoStartRecordingOnLaunch)
                Toggle("Resume recording after wake", isOn: $resumeRecordingAfterWake)
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

    private var filenamePreview: String {
        FilenameTemplate.resolve(template: clipFilenameTemplate, appName: "Rocket League")
    }

    func chooseOutputDirectory() {
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
