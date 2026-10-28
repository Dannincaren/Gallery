import Foundation

/// A narrow enter band and wider exit band avoid arrow/resize oscillation.
public struct ResizeCornerLatch {
    public private(set) var active = false
    public init() {}
    public mutating func reset() { active = false }
    public mutating func update(rightDistance: Double, bottomDistance: Double) -> Bool {
        let threshold = active ? 7.0 : 5.0
        active = abs(rightDistance) <= threshold && abs(bottomDistance) <= threshold
        return active
    }
}
