import SwiftUI
import AppKit
import Defaults
import CompanionServer

public struct CompanionSettingsView: View {
    @Default(.companionServerEnabled) private var companionServerEnabled
    @Default(.companionServerPort) private var companionServerPort
    @ObservedObject private var server = CompanionServer.shared
    @ObservedObject private var pairingManager = CompanionPairingManager.shared

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Enable Companion Server", isOn: $companionServerEnabled)
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

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(server.isRunning ? AppTheme.success : .secondary)
                            .frame(width: 8, height: 8)
                        Text(server.isRunning ? "Running" : "Stopped")
                            .foregroundStyle(server.isRunning ? AppTheme.success : AppTheme.textSecondary)
                    }
                }

                LabeledContent("Port") {
                    Text("\(companionServerPort)")
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Bonjour Service") {
                    Text(CompanionServer.bonjourServiceType)
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Local IP Addresses") {
                    VStack(alignment: .trailing, spacing: 3) {
                        if server.localIPAddresses.isEmpty {
                            Text("127.0.0.1")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary)
                        } else {
                            ForEach(server.localIPAddresses, id: \.self) { ip in
                                Text(ip)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }
                }

                LabeledContent("Connected Clients") {
                    Text("\(server.connectedClientsCount)")
                        .foregroundStyle(AppTheme.textSecondary)
                }
            } header: {
                Text("Companion Server")
            } footer: {
                Text("Connect using the ReplayMac Android app on the same local network. For USB tethering, run `adb reverse tcp:\(companionServerPort) tcp:\(companionServerPort)` and connect to `127.0.0.1`.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Section {
                if pairingManager.pairedDevices.isEmpty {
                    Text("No paired devices. New devices will prompt for authorization when connecting.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(pairingManager.pairedDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }

                            Spacer()

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
                        Button("Revoke All Devices") {
                            pairingManager.revokeAllDevices()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.danger)
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("Paired Devices")
            }
        }
    }
}
