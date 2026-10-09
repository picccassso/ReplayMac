import SwiftUI
import AppKit
import Defaults
import CompanionServer

public struct CompanionSettingsView: View {
    @Default(.companionServerEnabled) private var companionServerEnabled
    @Default(.companionServerPort) private var companionServerPort
    @Default(.companionHideSensitiveInfo) private var hideSensitiveInfo
    @ObservedObject private var server = CompanionServer.shared
    @ObservedObject private var pairingManager = CompanionPairingManager.shared

    @State private var portDraft: String = ""
    @State private var isPortInvalid: Bool = false
    @FocusState private var isPortFocused: Bool
    @State private var showRevokeAllAlert = false

    public init() {}

    public var body: some View {
        Form {
            serverStatusSection
            networkSection
            pairedDevicesSection
        }
        .formStyle(.grouped)
        .alert("Revoke All Paired Devices?", isPresented: $showRevokeAllAlert) {
            Button("Revoke All", role: .destructive) {
                pairingManager.revokeAllDevices()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All paired phones and tablets will be disconnected and will need to request authorization again to reconnect.")
        }
        .onAppear {
            portDraft = String(companionServerPort)
        }
        .onChange(of: companionServerPort) { _, newPort in
            if !isPortFocused {
                portDraft = String(newPort)
            }
        }
        .onChange(of: companionServerEnabled) { _, enabled in
            if enabled {
                do {
                    try server.start(port: UInt16(companionServerPort))
                } catch {
                    print("Failed to start companion server: \(error)")
                }
            } else {
                server.stop()
            }
        }
    }

    // MARK: - Server Status Hero Card

    private var serverStatusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                ServerStatusDot(isRunning: server.isRunning)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(server.isRunning ? "Companion Server Active" : "Companion Server Stopped")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))

                        if server.isRunning {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(AppTheme.success)
                                    .frame(width: 6, height: 6)
                                Text(server.connectedClientsCount == 1 ? "1 connected" : "\(server.connectedClientsCount) connected")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(AppTheme.success)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.success.opacity(0.12), in: Capsule())
                        }
                    }

                    Text(server.isRunning
                        ? "Listening for connections on port \(String(companionServerPort))"
                        : "Enable the companion server to connect phones and tablets")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer(minLength: 12)

                Toggle("", isOn: $companionServerEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Server Status")
        }
    }

    // MARK: - Connection & Network Section

    private var networkSection: some View {
        Section {
            if server.localIPAddresses.isEmpty {
                LabeledContent("Local IP Address") {
                    HStack(spacing: 8) {
                        Text(hideSensitiveInfo ? "•••.•••.•••.•••" : "127.0.0.1")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(hideSensitiveInfo ? AppTheme.textSecondary : AppTheme.textPrimary)
                        CopyButton(text: "127.0.0.1", tooltip: "Copy IP address")
                    }
                }
            } else {
                ForEach(Array(server.localIPAddresses.enumerated()), id: \.element) { index, ip in
                    LabeledContent(index == 0 ? "Local IP Address" : "Additional IP") {
                        HStack(spacing: 8) {
                            Text(hideSensitiveInfo ? "•••.•••.•••.•••" : ip)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(hideSensitiveInfo ? AppTheme.textSecondary : AppTheme.textPrimary)
                            CopyButton(text: ip, tooltip: "Copy IP address")
                        }
                    }
                }
            }

            LabeledContent("Port") {
                HStack(spacing: 8) {
                    TextField("Port", text: $portDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .font(.system(.body, design: .monospaced))
                        .focused($isPortFocused)
                        .onSubmit { commitPortDraft() }
                        .onChange(of: isPortFocused) { _, focused in
                            if !focused { commitPortDraft() }
                        }
                        .onChange(of: portDraft) { _, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue {
                                portDraft = filtered
                            }
                            validatePortDraft()
                        }

                    if isPortInvalid {
                        Text("1024–65535")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.danger)
                    }

                    if companionServerPort != Int(CompanionServer.defaultPort) {
                        Button("Reset (\(CompanionServer.defaultPort))") {
                            companionServerPort = Int(CompanionServer.defaultPort)
                            portDraft = String(CompanionServer.defaultPort)
                            isPortInvalid = false
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    CopyButton(text: String(companionServerPort), tooltip: "Copy port")
                }
            }

            LabeledContent("Bonjour Service") {
                HStack(spacing: 8) {
                    Text(CompanionServer.bonjourServiceType)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                    CopyButton(text: CompanionServer.bonjourServiceType, tooltip: "Copy Bonjour service name")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("USB Tethering Setup", systemImage: "cable.connector")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("For low-latency USB connections without Wi-Fi, run this command in Terminal:")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)

                HStack(spacing: 8) {
                    let adbCmd = "adb reverse tcp:\(companionServerPort) tcp:\(companionServerPort)"
                    Text(adbCmd)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))

                    CopyButton(text: adbCmd, label: "Copy Command", tooltip: "Copy adb reverse command")
                }

                Text("Then connect to 127.0.0.1 in the ReplayMac Companion app.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        } header: {
            HStack {
                Text("Connection & Network")
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hideSensitiveInfo.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hideSensitiveInfo ? "eye.slash.fill" : "eye")
                        Text(hideSensitiveInfo ? "Hidden" : "Hide IP")
                    }
                    .font(.caption)
                    .foregroundStyle(hideSensitiveInfo ? AppTheme.accent : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(hideSensitiveInfo ? "Reveal IP addresses" : "Hide IP addresses from view")
            }
        } footer: {
            Text("Connect phones and tablets running the ReplayMac Companion app on the same local Wi-Fi or via USB tethering.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Paired Devices Section

    private var pairedDevicesSection: some View {
        Section {
            if pairingManager.pairedDevices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text("No Paired Devices")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Open the ReplayMac Companion app on your phone or tablet on the same network to connect. New devices will prompt for authorization on your Mac.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(pairingManager.pairedDevices) { device in
                    let isConnected = server.isDeviceConnected(id: device.id)
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.accent.opacity(0.12))
                                .frame(width: 34, height: 34)

                            Image(systemName: deviceSymbol(for: device.name))
                                .font(.system(size: 15))
                                .foregroundStyle(AppTheme.accent)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(device.name)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))

                                if isConnected {
                                    HStack(spacing: 3) {
                                        Circle()
                                            .fill(AppTheme.success)
                                            .frame(width: 5, height: 5)
                                        Text("Active")
                                            .font(.system(size: 10, weight: .medium, design: .rounded))
                                            .foregroundStyle(AppTheme.success)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.success.opacity(0.12), in: Capsule())
                                }
                            }

                            Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }

                        Spacer(minLength: 8)

                        Button("Revoke") {
                            pairingManager.revokeDevice(id: device.id)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.danger)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showRevokeAllAlert = true
                    } label: {
                        Label("Revoke All Devices…", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.danger)
                }
                .padding(.top, 4)
            }
        } header: {
            HStack {
                Text("Paired Devices")
                Spacer()
                if !pairingManager.pairedDevices.isEmpty {
                    Text("\(pairingManager.pairedDevices.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    // MARK: - Validation & Helpers

    private func validatePortDraft() {
        if let val = Int(portDraft), (1024...65535).contains(val) {
            isPortInvalid = false
        } else {
            isPortInvalid = true
        }
    }

    private func commitPortDraft() {
        if let val = Int(portDraft), (1024...65535).contains(val) {
            isPortInvalid = false
            if val != companionServerPort {
                companionServerPort = val
            }
        } else {
            isPortInvalid = true
            portDraft = String(companionServerPort)
        }
    }

    private func deviceSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("ipad") {
            return "ipad"
        } else if lower.contains("iphone") {
            return "iphone"
        } else if lower.contains("mac") {
            return "macbook"
        } else {
            return "smartphone"
        }
    }
}

// MARK: - Subviews

private struct ServerStatusDot: View {
    let isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(isRunning ? AppTheme.success : Color.secondary.opacity(0.4))
            .frame(width: 10, height: 10)
            .overlay {
                if isRunning && !reduceMotion {
                    PulseRing()
                }
            }
    }

    private struct PulseRing: View {
        @State private var expanded = false

        var body: some View {
            Circle()
                .stroke(AppTheme.success.opacity(0.45), lineWidth: 1.5)
                .scaleEffect(expanded ? 2.5 : 1)
                .opacity(expanded ? 0 : 1)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                        expanded = true
                    }
                }
        }
    }
}

private struct CopyButton: View {
    let text: String
    var label: String? = nil
    var tooltip: String = "Copy"

    @State private var justCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            justCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                justCopied = false
            }
        } label: {
            if let label {
                HStack(spacing: 4) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    Text(justCopied ? "Copied" : label)
                }
                .font(.caption)
            } else {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(justCopied ? AppTheme.success : AppTheme.textSecondary)
            }
        }
        .buttonStyle(.borderless)
        .help(justCopied ? "Copied!" : tooltip)
        .accessibilityLabel(justCopied ? "Copied" : tooltip)
    }
}
