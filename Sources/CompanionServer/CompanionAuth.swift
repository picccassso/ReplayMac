import Foundation
import CryptoKit

/// The crypto and input hygiene behind companion pairing.
///
/// Pairing hands the phone a random secret once, right after the user clicks
/// Allow. Every later connection proves the phone still holds it by answering
/// a fresh nonce with an HMAC, so the secret never crosses the network again
/// and a captured `deviceId` is useless on its own.
public enum CompanionAuth {
    /// Phones older than this get an "update the app" error instead of a session.
    public static let protocolVersion = 2
    static let proofContext = "replaycap-companion-auth-v1"

    static let maxDeviceIdLength = 128
    static let maxDeviceNameLength = 40

    public static func makeSecret() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func makeNonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    /// Four digits shown on both the Mac's prompt and the phone, so the user
    /// can tell their own phone's request from anyone else's on the network.
    public static func makePairingCode() -> String {
        String(format: "%04u", UInt32.random(in: 0..<10_000))
    }

    public static func proof(secret: Data, serverId: String, deviceId: String, nonce: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: proofMessage(serverId: serverId, deviceId: deviceId, nonce: nonce),
            using: SymmetricKey(data: secret)
        )
        return Data(code)
    }

    /// Constant-time check of a base64 proof from the phone.
    public static func isValidProof(_ proofBase64: String?, secret: Data, serverId: String, deviceId: String, nonce: String) -> Bool {
        guard let proofBase64, let proof = Data(base64Encoded: proofBase64) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: proofMessage(serverId: serverId, deviceId: deviceId, nonce: nonce),
            using: SymmetricKey(data: secret)
        )
    }

    private static func proofMessage(serverId: String, deviceId: String, nonce: String) -> Data {
        Data("\(proofContext)\n\(serverId)\n\(deviceId)\n\(nonce)".utf8)
    }

    /// A device id is an opaque token the phone generated; anything else is rejected.
    public static func sanitizedDeviceId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= maxDeviceIdLength,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else {
            return nil
        }
        return trimmed
    }

    /// The phone picks its own name and the Mac shows it in the Allow prompt,
    /// so strip anything that could make it misleading: control and
    /// bidirectional-override characters, line breaks, runs of spaces, and
    /// names long enough to push the real text out of view.
    public static func sanitizedDeviceName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let spaced = raw.unicodeScalars.map { $0.properties.isWhitespace ? " " : $0 }
        let allowed = spaced.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                return false
            default:
                return true
            }
        }
        let collapsed = String(String.UnicodeScalarView(allowed))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxDeviceNameLength {
            return collapsed
        }
        return String(collapsed.prefix(maxDeviceNameLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
