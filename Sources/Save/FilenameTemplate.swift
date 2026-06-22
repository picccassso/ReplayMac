import Foundation

/// Resolves a user-defined clip file-name template into a safe base name.
///
/// Supported tokens are substituted, then the result is sanitized so empty
/// tokens (e.g. an unknown foreground app) can't leave stray or illegal
/// characters in the file name.
public enum FilenameTemplate {
    /// Reproduces the historical `ReplayMac_<date>_<time>` naming.
    public static let `default` = "ReplayMac_{date}_{time}"

    /// Tokens shown in Settings, paired with a short description.
    public static let tokens: [(token: String, description: String)] = [
        ("{app}", "Foreground app name"),
        ("{date}", "Date, e.g. 2026-06-22"),
        ("{time}", "Time, e.g. 11-00-21")
    ]

    public static func resolve(template: String, appName: String?, date: Date = Date()) -> String {
        let dateString = formatted(date, as: "yyyy-MM-dd")
        let timeString = formatted(date, as: "HH-mm-ss")

        var result = template
        result = result.replacingOccurrences(of: "{app}", with: appName ?? "")
        result = result.replacingOccurrences(of: "{date}", with: dateString)
        result = result.replacingOccurrences(of: "{time}", with: timeString)

        let sanitized = sanitize(result)
        return sanitized.isEmpty ? defaultBaseName(date: date) : sanitized
    }

    private static func formatted(_ date: Date, as format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var cleaned = name.components(separatedBy: illegal).joined(separator: "-")

        // Collapse separator runs left by empty tokens (e.g. "{app}_{date}"
        // with no app → "_2026-…").
        while cleaned.contains("__") {
            cleaned = cleaned.replacingOccurrences(of: "__", with: "_")
        }

        let trimSet = CharacterSet(charactersIn: "_-. ").union(.whitespaces)
        return cleaned.trimmingCharacters(in: trimSet)
    }

    private static func defaultBaseName(date: Date) -> String {
        ClipMetadata.defaultBaseName(date: date)
    }
}
