import Foundation

/// A native resource contains at most 24 equally timed frames. Longer loops
/// overlap two frames so a scheduled handover occurs before the old strip wraps.
public struct NativeLoopWindow: Equatable, Sendable {
    public static let limit = 24
    public let sourceCount: Int
    public let startStep: Int
    public var count: Int { min(Self.limit, sourceCount) }
    public var offset: Int { startStep % sourceCount }
    public var nextStep: Int? { sourceCount > Self.limit ? startStep + Self.limit - 2 : nil }
    public var indices: [Int] { (0..<count).map { (offset + $0) % sourceCount } }
    public init?(sourceCount: Int, startStep: Int) {
        guard (2...240).contains(sourceCount), startStep >= 0 else { return nil }
        self.sourceCount = sourceCount; self.startStep = startStep
    }
    public static func eligible(count: Int, motion: Motion, resize: Bool, expanded: Bool, visibleChanges: Int? = nil) -> Bool {
        // Long idle clips must keep one source clock. Foreground reselection
        // can restart a bounded native strip without changing its image bank.
        // Until phase can be observed, use cached paired frames for this case.
        (2...240).contains(count) && !resize && motion.loops
            && (motion != .idle || count <= limit)
            // Sparse normal animations are cheaper and phase-safe as held
            // frames. Reselecting a 24-frame strip can replay a partial pose
            // sequence even when the strip's image bank is unchanged.
            && !(motion == .normal && count > limit && (visibleChanges ?? count) <= min(limit, count / 2))
            && (expanded || (motion == .normal && count <= limit))
    }
    /// Prepare off the input path, aiming at a future source-frame boundary.
    /// If that boundary is missed, keep paired-frame playback and try a new one.
    public static func preparationLead(frameDuration: Double) -> Int {
        guard frameDuration.isFinite, frameDuration > 0 else { return 1 }
        return max(1, Int(min(12, ceil(0.04 / frameDuration))))
    }
}
