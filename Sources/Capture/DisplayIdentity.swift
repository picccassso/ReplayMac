import CoreGraphics
import Foundation

/// Stable identity for a display.
///
/// `CGDirectDisplayID` is assigned at runtime: it changes across reboots, display
/// reconnects, dock/KVM renegotiation and GPU switches. Persisting it means a saved
/// "record this screen" choice silently stops matching any attached display, so it
/// must never be stored on its own. We store the EDID triple (vendor, model, serial)
/// instead and resolve it back to a live display ID at the point of use.
public enum DisplayIdentity {
    private static let edidPrefix = "edid:"
    private static let rawPrefix = "raw:"

    /// Persistable key for a display.
    ///
    /// Displays that report no EDID data at all (some virtual and mirrored displays)
    /// fall back to the raw ID, which still round-trips within a single boot.
    public static func stableKey(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        if vendor == 0, model == 0, serial == 0 {
            return "\(rawPrefix)\(displayID)"
        }
        return "\(edidPrefix)\(vendor):\(model):\(serial)"
    }

    /// Display IDs currently attached, in the order CoreGraphics reports them.
    ///
    /// Uses CoreGraphics rather than ScreenCaptureKit so this works before (or
    /// without) screen-recording permission.
    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Whether a stored value is a bare `CGDirectDisplayID` written by a version of
    /// the app that persisted the runtime ID directly.
    public static func isLegacyRawValue(_ stored: String) -> Bool {
        !stored.isEmpty && stored.allSatisfy(\.isNumber)
    }

    /// Resolve a stored selection to a currently attached display.
    ///
    /// Accepts both stable keys and legacy raw IDs. Returns `nil` when the display is
    /// not attached — callers must treat that as "not connected right now", never as a
    /// reason to overwrite the stored selection.
    ///
    /// Two identical monitors that report the same serial number are indistinguishable
    /// by EDID; in that case the lowest-numbered matching display wins so the choice is
    /// at least deterministic.
    public static func resolve(
        _ stored: String,
        among displayIDs: [CGDirectDisplayID] = onlineDisplayIDs()
    ) -> CGDirectDisplayID? {
        guard !stored.isEmpty else { return nil }

        if isLegacyRawValue(stored) {
            guard let raw = UInt32(stored) else { return nil }
            return displayIDs.first { $0 == raw }
        }

        return displayIDs
            .filter { stableKey(for: $0) == stored }
            .min()
    }

    /// Whether a stored selection matches this display.
    public static func matches(_ stored: String?, displayID: CGDirectDisplayID) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        if isLegacyRawValue(stored) {
            return UInt32(stored) == displayID
        }
        return stableKey(for: displayID) == stored
    }

    /// Upgrade a legacy raw ID to a stable key, if that display is attached right now.
    ///
    /// Returns `nil` when the value needs no migration or cannot be migrated yet — an
    /// unattached display keeps its stored raw ID and migrates on a later launch.
    public static func migratedKey(
        forLegacyValue stored: String,
        among displayIDs: [CGDirectDisplayID] = onlineDisplayIDs()
    ) -> String? {
        guard isLegacyRawValue(stored), let displayID = resolve(stored, among: displayIDs) else {
            return nil
        }
        return stableKey(for: displayID)
    }
}
