import Foundation

/// A monitor callback and the session counter can become visible in either
/// order. Credits acknowledge the same physical edge when its counter arrives.
public struct MouseCounterLedger {
    private var downs: UInt32
    private var ups: UInt32
    private var observedDowns = 0
    private var observedUps = 0
    public init(downs: UInt32, ups: UInt32) { self.downs = downs; self.ups = ups }
    public mutating func acknowledge(_ edge: MouseEdge) {
        if edge == .down { observedDowns = min(64, observedDowns + 1) }
        else { observedUps = min(64, observedUps + 1) }
    }
    public mutating func poll(downs: UInt32, ups: UInt32, isDown: Bool) -> [MouseEdge] {
        let newDowns = Int(downs &- self.downs), newUps = Int(ups &- self.ups)
        self.downs = downs; self.ups = ups
        let downCredits = min(newDowns, observedDowns), upCredits = min(newUps, observedUps)
        observedDowns -= downCredits; observedUps -= upCredits
        let missingDown = newDowns > downCredits, missingUp = newUps > upCredits
        if missingDown && missingUp { return isDown ? [.up, .down] : [.down, .up] }
        if missingDown { return [.down] }
        if missingUp { return [.up] }
        return []
    }
}
