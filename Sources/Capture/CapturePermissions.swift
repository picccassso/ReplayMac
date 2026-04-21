import ScreenCaptureKit

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

private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    
    nonisolated func waitForCompletion() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
        }
    }
    
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        continuation?.resume()
        continuation = nil
    }
    
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        continuation?.resume(throwing: CapturePermissionError.denied)
        continuation = nil
    }
    
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        continuation?.resume(throwing: CapturePermissionError.pickerFailed(error))
        continuation = nil
    }
}
