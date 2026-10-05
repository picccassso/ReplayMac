import Foundation

enum TrimTime {
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let value = Double(part), value.isFinite, value >= 0,
                  (index == parts.count - 1 || !part.contains(".")),
                  (index == 0 || value < 60) else { return nil }
            total = total * 60 + value
        }
        return total.isFinite ? total : nil
    }

    static func label(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let tenths = Int((safe * 10).rounded())
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

enum TrimPreviewPosition {
    static func seconds(sourceSeconds: Double, previewSourceStart: Double) -> Double {
        max(0, sourceSeconds - previewSourceStart)
    }
}
