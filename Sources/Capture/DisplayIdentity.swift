import CoreGraphics
import Foundation

/// Stable identity for a display.
///
/// `CGDirectDisplayID` is assigned at runtime: it changes across reboots, display
/// reconnects, dock/KVM renegotiation and GPU switches. Persisting it means a saved
/// "record this screen" choice silently stops matching any attached display, so it
/// must never be stored on its own. We store persistent UUIDs and EDID triples
/// (vendor, model, serial) instead and resolve them back to a live display ID at the
/// point of use.
public enum DisplayIdentity {
    public static let edidPrefix = "edid:"
    public static let sizePrefix = "size:"
    public static let rawPrefix = "raw:"
    public static let builtinKey = "builtin:main"

    /// Physical millimeter size for a display (from EDID)
    public static func physicalSize(for displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        let size = CGDisplayScreenSize(displayID)
        return (Int(size.width), Int(size.height))
    }

    /// EDID triple (vendor:model:serial) key for a display.
    public static func edidKey(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        return "\(edidPrefix)\(vendor):\(model):\(serial)"
    }

    /// Whether the display is the built-in screen of a portable Mac.
    public static func isBuiltin(displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    /// Persistable key for a display.
    ///
    /// Stores the EDID triple (vendor, model, serial). Displays reporting no EDID
    /// fall back to built-in, physical size, or raw ID.
    public static func stableKey(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        if vendor != 0 || model != 0 || serial != 0 {
            return "\(edidPrefix)\(vendor):\(model):\(serial)"
        }

        if isBuiltin(displayID: displayID) {
            return builtinKey
        }

        let size = physicalSize(for: displayID)
        if size.width > 0 && size.height > 0 {
            return "\(sizePrefix)\(size.width)x\(size.height)"
        }

        return "\(rawPrefix)\(displayID)"
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

    /// Whether a stored key represents the built-in screen.
    public static func isBuiltinDisplayKey(
        _ stored: String,
        among displayIDs: [CGDirectDisplayID] = onlineDisplayIDs()
    ) -> Bool {
        if stored == builtinKey { return true }
        for displayID in displayIDs where isBuiltin(displayID: displayID) {
            if matches(stored, displayID: displayID) {
                return true
            }
        }
        return false
    }

    /// Whether a stored key likely represents an external (non-builtin) display.
    public static func isExternalDisplayKey(
        _ stored: String,
        among displayIDs: [CGDirectDisplayID] = onlineDisplayIDs()
    ) -> Bool {
        guard !stored.isEmpty else { return false }
        return !isBuiltinDisplayKey(stored, among: displayIDs)
    }

    /// Resolve a stored selection to a currently attached display.
    ///
    /// Accepts stable EDID keys, size keys, builtin keys, and legacy raw IDs. Returns `nil` when the display is
    /// not attached — callers must treat that as "not connected right now", never as a
    /// reason to overwrite the stored selection.
    ///
    /// If an exact match is not found (for instance, if an external display's raw ID changed or
    /// EDID serial was unassigned), it attempts an intelligent fallback (e.g. matching the single
    /// attached external display).
    public static func resolve(
        _ stored: String,
        among displayIDs: [CGDirectDisplayID] = onlineDisplayIDs()
    ) -> CGDirectDisplayID? {
        guard !stored.isEmpty else { return nil }

        if isLegacyRawValue(stored) {
            guard let raw = UInt32(stored) else { return nil }
            return displayIDs.first { $0 == raw }
        }

        // Step 1: Direct matches
        let directMatches = displayIDs.filter { matches(stored, displayID: $0) }
        if let first = directMatches.min() {
            return first
        }

        // Step 2: Intelligent fallback for external displays whose runtime ID or serial changed
        let externalDisplays = displayIDs.filter { !isBuiltin(displayID: $0) }
        let builtinDisplays = displayIDs.filter { isBuiltin(displayID: $0) }

        if isExternalDisplayKey(stored, among: displayIDs) {
            if externalDisplays.count == 1, let singleExternal = externalDisplays.first {
                return singleExternal
            }
        } else if isBuiltinDisplayKey(stored) {
            if let firstBuiltin = builtinDisplays.first {
                return firstBuiltin
            }
        }

        return nil
    }

    /// Whether a stored selection matches this display.
    public static func matches(_ stored: String?, displayID: CGDirectDisplayID) -> Bool {
        guard let stored, !stored.isEmpty else { return false }

        // 1. Direct match with current stable key
        if stableKey(for: displayID) == stored {
            return true
        }

        // 2. EDID triple match
        if stored.hasPrefix(edidPrefix) {
            if edidKey(for: displayID) == stored {
                return true
            }
            // Also check partial EDID match (vendor + model) when serial numbers are 0/unassigned
            let storedParts = stored.dropFirst(edidPrefix.count).split(separator: ":")
            if storedParts.count == 3,
               let sVendor = UInt32(storedParts[0]),
               let sModel = UInt32(storedParts[1]) {
                let dVendor = CGDisplayVendorNumber(displayID)
                let dModel = CGDisplayModelNumber(displayID)
                if sVendor != 0, sVendor == dVendor, sModel == dModel {
                    return true
                }
            }
        }

        // 3. Physical size match
        if stored.hasPrefix(sizePrefix) {
            let size = physicalSize(for: displayID)
            if stored == "\(sizePrefix)\(size.width)x\(size.height)" {
                return true
            }
        }

        // 4. Built-in display key match
        if stored == builtinKey {
            return isBuiltin(displayID: displayID)
        }

        // 5. Raw display ID match (handles both "raw:123" and bare "123")
        if stored.hasPrefix(rawPrefix) {
            let rawStr = String(stored.dropFirst(rawPrefix.count))
            if let raw = UInt32(rawStr), raw == displayID {
                return true
            }
        }

        if isLegacyRawValue(stored) {
            return UInt32(stored) == displayID
        }

        return false
    }

    /// Upgrade a legacy raw ID to a stable key, if that display is attached right now.
    ///
    /// Returns `nil` when the value needs no migration or cannot be migrated yet — an
    /// unattached display keeps its stored raw ID and migrates on a later launch.
    public static func migratedKey(
        forLegacyValue stored: String,
        among displayIDs: [CGDirectDisplayID] = onlineDisplayIDs()
    ) -> String? {
        guard isLegacyRawValue(stored) || stored.hasPrefix(rawPrefix),
              let displayID = resolve(stored, among: displayIDs) else {
            return nil
        }
        return stableKey(for: displayID)
    }
}
