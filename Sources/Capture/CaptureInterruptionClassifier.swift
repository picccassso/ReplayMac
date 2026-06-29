import Foundation
import ScreenCaptureKit

public enum CaptureInterruptionClassifier {
    public static func isSystemStoppedStream(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && SCStreamError.Code(rawValue: nsError.code) == .systemStoppedStream
    }
}
