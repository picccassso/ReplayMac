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

public enum PairingPromptResult: Sendable, Equatable {
    case approved
    case denied
    /// Nobody answered the prompt in time.
    case timedOut
    /// The phone went away, the server stopped, or another prompt was already up.
    case cancelled
}

@MainActor
public final class CompanionPairingManager: ObservableObject {
    public static let shared = CompanionPairingManager()
    public static let userDefaultsKey = "pairedCompanionDevices"
    static let secretsDefaultsKey = "pairedCompanionDeviceSecrets"
    public static let defaultPromptTimeout: TimeInterval = 60

    @Published public private(set) var pairedDevices: [PairedDevice] = []
    public var onDeviceRevoked: ((String) -> Void)?
    public var onDeviceRenamed: ((String, String) -> Void)?
    /// Allows tests to simulate user approval/denial without showing native dialogs.
    /// Receives the device id, display name and pairing code.
    public var promptHandler: (@MainActor (String, String, String) async -> Bool)?
    public var promptTimeout: TimeInterval = defaultPromptTimeout

    /// Base64 pairing secrets by device id, kept apart from `pairedDevices` so
    /// they never reach the UI.
    private var secrets: [String: String] = [:]
    private var activePrompt: ActivePrompt?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadDevices()
    }

    public func loadDevices() {
        secrets = defaults.dictionary(forKey: Self.secretsDefaultsKey) as? [String: String] ?? [:]
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
        defaults.set(secrets, forKey: Self.secretsDefaultsKey)
    }

    public func isDeviceApproved(id: String) -> Bool {
        pairedDevices.contains { $0.id == id }
    }

    public func device(for id: String) -> PairedDevice? {
        pairedDevices.first { $0.id == id }
    }

    /// The secret a paired device proves it holds. Devices paired before
    /// secrets existed have none and must be approved again.
    public func secret(for id: String) -> Data? {
        guard isDeviceApproved(id: id) else { return nil }
        return secrets[id].flatMap { Data(base64Encoded: $0) }
    }

    /// Pairs the device, or re-pairs it, and returns a fresh secret for it.
    /// Any secret it held before stops working.
    @discardableResult
    public func approveDevice(id: String, name: String) -> Data {
        refreshReportedName(id: id, name: name)
        let secret = CompanionAuth.makeSecret()
        secrets[id] = secret.base64EncodedString()
        saveDevices()
        return secret
    }

    /// Records the name a phone reports, unless the user has renamed it on the Mac.
    public func refreshReportedName(id: String, name: String) {
        let cleanName = name.isEmpty ? "Companion Device" : name
        if let idx = pairedDevices.firstIndex(where: { $0.id == id }) {
            let existing = pairedDevices[idx]
            let resolvedName = (existing.isCustomName == true) ? existing.name : cleanName
            guard resolvedName != existing.name else { return }
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
        secrets.removeValue(forKey: id)
        saveDevices()
        onDeviceRevoked?(id)
    }

    public func revokeAllDevices() {
        let allIDs = pairedDevices.map { $0.id }
        pairedDevices.removeAll()
        secrets.removeAll()
        saveDevices()
        for id in allIDs {
            onDeviceRevoked?(id)
        }
    }

    // MARK: - Approval Prompt

    public var isPromptActive: Bool { activePrompt != nil }

    /// Asks the user whether `id` may pair. Only one prompt is ever on screen;
    /// a second request while one is up returns `.cancelled` straight away.
    /// Approving does not pair the device: call ``approveDevice(id:name:)``.
    public func requestApproval(id: String, name: String, code: String) async -> PairingPromptResult {
        guard activePrompt == nil else { return .cancelled }
        let displayName = name.isEmpty ? "Companion Device" : name

        return await withCheckedContinuation { continuation in
            let prompt = ActivePrompt(deviceId: id, continuation: continuation)
            activePrompt = prompt

            let timeout = promptTimeout
            prompt.timeoutTask = Task { [weak self, weak prompt] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let prompt else { return }
                self?.finish(prompt, with: .timedOut)
            }

            if let handler = promptHandler {
                prompt.handlerTask = Task { [weak self, weak prompt] in
                    let allowed = await handler(id, displayName, code)
                    guard let prompt else { return }
                    self?.finish(prompt, with: allowed ? .approved : .denied)
                }
            } else {
                let alert = PairingAlert(displayName: displayName, code: code) { [weak self, weak prompt] allowed in
                    guard let prompt else { return }
                    self?.finish(prompt, with: allowed ? .approved : .denied)
                }
                prompt.alert = alert
                alert.show()
            }
        }
    }

    /// Dismisses the prompt for `id`, if it's the one on screen.
    public func cancelPrompt(for id: String) {
        guard let prompt = activePrompt, prompt.deviceId == id else { return }
        finish(prompt, with: .cancelled)
    }

    private func finish(_ prompt: ActivePrompt, with result: PairingPromptResult) {
        guard activePrompt === prompt else { return }
        activePrompt = nil
        prompt.timeoutTask?.cancel()
        prompt.handlerTask?.cancel()
        prompt.alert?.close()
        prompt.continuation.resume(returning: result)
    }
}

@MainActor
private final class ActivePrompt {
    let deviceId: String
    let continuation: CheckedContinuation<PairingPromptResult, Never>
    var timeoutTask: Task<Void, Never>?
    var handlerTask: Task<Void, Never>?
    var alert: PairingAlert?

    init(deviceId: String, continuation: CheckedContinuation<PairingPromptResult, Never>) {
        self.deviceId = deviceId
        self.continuation = continuation
    }
}

/// The Allow/Deny prompt, shown as a floating window rather than a modal
/// session so it can be dismissed when the phone gives up or the request
/// times out, and so it never blocks the main thread.
@MainActor
private final class PairingAlert: NSObject {
    private let alert = NSAlert()
    private let onDecision: (Bool) -> Void

    init(displayName: String, code: String, onDecision: @escaping (Bool) -> Void) {
        self.onDecision = onDecision
        super.init()

        alert.messageText = "Allow “\(displayName)” to connect?"
        alert.informativeText = "Only allow it if the device shows this code. It will be able to start and stop recording, save and delete clips, and see clip previews on this Mac."
        alert.alertStyle = .informational
        alert.accessoryView = Self.codeLabel(code)

        let allow = alert.addButton(withTitle: "Allow")
        let deny = alert.addButton(withTitle: "Deny")
        // Allow has to be clicked: a stray Return mid-game must not pair a device.
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\u{1b}"
        allow.target = self
        allow.action = #selector(allowClicked)
        deny.target = self
        deny.action = #selector(denyClicked)
    }

    func show() {
        alert.layout()
        let window = alert.window
        window.level = .floating
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        alert.window.orderOut(nil)
    }

    @objc private func allowClicked() { onDecision(true) }
    @objc private func denyClicked() { onDecision(false) }

    private static func codeLabel(_ code: String) -> NSView {
        let spaced = code.map(String.init).joined(separator: " ")
        let label = NSTextField(labelWithString: spaced)
        label.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        label.alignment = .center
        label.setAccessibilityLabel("Pairing code \(spaced)")
        label.frame = NSRect(x: 0, y: 0, width: 220, height: 36)
        return label
    }
}
