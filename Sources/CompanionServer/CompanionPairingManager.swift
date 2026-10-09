import Foundation
import AppKit

public struct PairedDevice: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let pairedAt: Date
    public let isCustomName: Bool?

    public init(id: String, name: String, pairedAt: Date = Date(), isCustomName: Bool? = nil) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.isCustomName = isCustomName
    }
}

@MainActor
public final class CompanionPairingManager: ObservableObject {
    public static let shared = CompanionPairingManager()
    public static let userDefaultsKey = "pairedCompanionDevices"

    @Published public private(set) var pairedDevices: [PairedDevice] = []
    public var onDeviceRevoked: ((String) -> Void)?
    public var onDeviceRenamed: ((String, String) -> Void)?
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

    public func device(for id: String) -> PairedDevice? {
        pairedDevices.first { $0.id == id }
    }

    public func approveDevice(id: String, name: String) {
        let cleanName = name.isEmpty ? "Companion Device" : name
        if let idx = pairedDevices.firstIndex(where: { $0.id == id }) {
            let existing = pairedDevices[idx]
            let resolvedName = (existing.isCustomName == true) ? existing.name : cleanName
            pairedDevices[idx] = PairedDevice(id: id, name: resolvedName, pairedAt: existing.pairedAt, isCustomName: existing.isCustomName)
        } else {
            pairedDevices.append(PairedDevice(id: id, name: cleanName, pairedAt: Date()))
        }
        saveDevices()
    }

    public func renameDevice(id: String, newName: String) {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        if let idx = pairedDevices.firstIndex(where: { $0.id == id }) {
            let existing = pairedDevices[idx]
            pairedDevices[idx] = PairedDevice(id: id, name: cleanName, pairedAt: existing.pairedAt, isCustomName: true)
            saveDevices()
            onDeviceRenamed?(id, cleanName)
        }
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

        // A phone that retries while the prompt is up must not open a second one.
        if inFlightPrompts[id] != nil {
            return await withCheckedContinuation { continuation in
                inFlightPrompts[id]?.append(continuation)
            }
        }
        inFlightPrompts[id] = []

        let displayName = name.isEmpty ? "Companion Device" : name
        let result: Bool
        if let customHandler = promptHandler {
            result = await customHandler(id, displayName)
        } else {
            result = askUserToApprove(displayName: displayName)
        }
        if result {
            approveDevice(id: id, name: displayName)
        }

        let pending = inFlightPrompts.removeValue(forKey: id) ?? []
        for continuation in pending {
            continuation.resume(returning: result)
        }
        return result
    }

    private func askUserToApprove(displayName: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Allow '\(displayName)' to connect?"
        alert.informativeText = "This device will be able to start/stop recordings, save clips, and access clip previews on your Mac."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.window.level = .floating

        return alert.runModal() == .alertFirstButtonReturn
    }
}
