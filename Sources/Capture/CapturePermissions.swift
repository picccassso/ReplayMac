import ScreenCaptureKit
import Synchronization

public enum CapturePermissionError: Error, CustomStringConvertible {
    case denied
    case noDisplaysAvailable
    case pickerFailed(Error)
    
    public var description: String {
        switch self {
        case .denied:
            return "Screen recording permission was denied. Please enable it in System Settings > Privacy & Security > Screen Recording."
        case .noDisplaysAvailable:
            return "No displays available for capture."
        case .pickerFailed(let error):
            return "Picker failed: \(error.localizedDescription)"
        }
    }
}

public struct CapturePermissions {
    public init() {}
    
    public func requestAccess(interactive: Bool = true) async throws -> SCShareableContent {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else {
                throw CapturePermissionError.noDisplaysAvailable
            }
            return content
        } catch let error as CapturePermissionError {
            throw error
        } catch {
            guard interactive else {
                throw error
            }
            return try await requestViaPicker()
        }
    }
    
    private func requestViaPicker() async throws -> SCShareableContent {
        let observer = PickerObserver()
        
        await MainActor.run {
            let picker = SCContentSharingPicker.shared
            picker.add(observer)
            picker.present()
        }
        
        defer {
            Task { @MainActor in
                let picker = SCContentSharingPicker.shared
                picker.remove(observer)
            }
        }
        
        do {
            try await observer.waitForCompletion()
        } catch {
            throw CapturePermissionError.denied
        }
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else {
                throw CapturePermissionError.noDisplaysAvailable
            }
            return content
        } catch let error as CapturePermissionError {
            throw error
        } catch {
            throw CapturePermissionError.denied
        }
    }
}

/// Bridges the picker's observer callbacks to the one caller awaiting them.
/// The callbacks and the wait start on different threads, so both go through
/// the mutex, and a result that lands before the wait begins is kept for it
/// rather than dropped (which would leave the caller suspended forever).
final class PickerObserver: NSObject, SCContentSharingPickerObserver, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var pendingResult: Result<Void, Error>?
        var isFinished = false
    }

    private let state = Mutex(State())

    nonisolated func waitForCompletion() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending: Result<Void, Error>? = state.withLock { state in
                if let result = state.pendingResult {
                    state.pendingResult = nil
                    return result
                }
                state.continuation = continuation
                return nil
            }
            if let pending {
                continuation.resume(with: pending)
            }
        }
    }

    /// Delivers the picker's outcome once; later callbacks are ignored.
    func finish(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            guard let continuation = state.continuation else {
                state.pendingResult = result
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finish(.success(()))
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(.failure(CapturePermissionError.denied))
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(CapturePermissionError.pickerFailed(error)))
    }
}
