import Foundation
import ScreenCaptureKit

public enum CaptureInterruptionClassifier {
    public static func isSystemStoppedStream(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var visited: Set<ObjectIdentifier> = []

        while let nsError = current, visited.insert(ObjectIdentifier(nsError)).inserted {
            if nsError.domain == SCStreamErrorDomain,
               SCStreamError.Code(rawValue: nsError.code) == .systemStoppedStream {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
