import Foundation
import AppKit

public struct PairedDevice: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let pairedAt: Date

    public init(id: String, name: String, pairedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
    }
}

@MainActor
public final class CompanionPairingManager: ObservableObject {
    public static let shared = CompanionPairingManager()
    public static let userDefaultsKey = "pairedCompanionDevices"

    @Published public private(set) var pairedDevices: [PairedDevice] = []
    public var onDeviceRevoked: ((String) -> Void)?
    /// Allows tests to simulate user approval/denial without showing native modal dialogs.
    public var promptHandler: (@MainActor (String, String) async -> Bool)?

    private var inFlightPrompts: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadDevices()
    }

    public func loadDevices() {
        guard let data = defaults.data(forKey: Self.userDefaultsKey),
              let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            pairedDevices = []
            return
        }
        pairedDevices = list
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }

    public func isDeviceApproved(id: String) -> Bool {
        pairedDevices.contains { $0.id == id }
    }

    public func approveDevice(id: String, name: String) {
        let cleanName = name.isEmpty ? "Android Device" : name
        if let idx = pairedDevices.firstIndex(where: { $0.id == id }) {
            pairedDevices[idx] = PairedDevice(id: id, name: cleanName, pairedAt: pairedDevices[idx].pairedAt)
        } else {
            pairedDevices.append(PairedDevice(id: id, name: cleanName, pairedAt: Date()))
        }
        saveDevices()
    }

    public func revokeDevice(id: String) {
        pairedDevices.removeAll { $0.id == id }
        saveDevices()
        onDeviceRevoked?(id)
    }

    public func revokeAllDevices() {
        let allIDs = pairedDevices.map { $0.id }
        pairedDevices.removeAll()
        saveDevices()
        for id in allIDs {
            onDeviceRevoked?(id)
        }
    }

    public func promptApprovalForDevice(id: String, name: String) async -> Bool {
        if isDeviceApproved(id: id) {
            return true
        }

        if let customHandler = promptHandler {
            let approved = await customHandler(id, name)
            if approved {
                approveDevice(id: id, name: name)
            }
            return approved
        }

        if inFlightPrompts[id] != nil {
            return await withCheckedContinuation { continuation in
                inFlightPrompts[id]?.append(continuation)
            }
        }
        inFlightPrompts[id] = []

        NSApp.activate(ignoringOtherApps: true)

        let displayName = name.isEmpty ? "Android Device" : name
        let alert = NSAlert()
        alert.messageText = "Allow Android device '\(displayName)' to connect?"
        alert.informativeText = "This device will be able to start/stop recordings, save clips, and access clip previews on your Mac."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.window.level = .floating

        let response = alert.runModal()
        let result: Bool
        if response == .alertFirstButtonReturn {
            approveDevice(id: id, name: displayName)
            result = true
        } else {
            result = false
        }

        let pending = inFlightPrompts.removeValue(forKey: id) ?? []
        for continuation in pending {
            continuation.resume(returning: result)
        }
        return result
    }
}
