import Foundation

/// Preserve a loop across brief cursor-region rebuilds (text -> arrow -> text),
/// while a real departure or click starts a new animation on return.
public struct RoleAnimationClocks {
    private var clocks: [String: (start: Double, seen: Double)] = [:]
    public init() {}
    public mutating func start(for role: String, suggested: Double, now: Double) -> Double {
        let previous = clocks[role]
        let start = previous.flatMap { now - $0.seen < 0.35 ? $0.start : nil } ?? suggested
        clocks[role] = (start, now)
        return start
    }
    public mutating func reset() { clocks.removeAll(keepingCapacity: true) }
}
