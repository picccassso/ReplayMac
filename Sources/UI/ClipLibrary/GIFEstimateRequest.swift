import Foundation
import CoreGraphics

struct GIFEstimateRequest: Equatable {
    let sourceURL: URL
    let start: Double
    let end: Double
    let width: CGFloat
    let crop: NormalizedVideoCrop?
    let enabled: Bool
}

/// A request must still be current when background work finishes.
struct GIFEstimateGeneration {
    private var current = UUID()
    mutating func begin() -> UUID {
        invalidate()
        return current
    }
    mutating func invalidate() { current = UUID() }
    func accepts(_ id: UUID) -> Bool { current == id }
}
