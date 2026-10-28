import Foundation

/// A deliberate shake requires three fast reversals, not one large movement.
public struct PointerShake {
    private var anchor: (Double, Double, Double)?
    private var direction: (Double, Double)?
    private var turns: [Double] = []
    private var travel: [(Double, Double)] = []
    private var triggered = -Double.infinity
    public init() {}
    public mutating func reset() { self = PointerShake() }
    public mutating func observe(x: Double, y: Double, at time: Double) {
        guard x.isFinite, y.isFinite, time.isFinite else { return }
        guard let old = anchor else { anchor = (x, y, time); return }
        let dx = x - old.0, dy = y - old.1, length = hypot(dx, dy), dt = time - old.2
        guard dt > 0, length >= 8 else { return }
        anchor = (x, y, time)
        if dt > 0.2 || length / dt < 500 { direction = nil; turns.removeAll(); travel.removeAll(); return }
        travel.append((time, length)); travel.removeAll { time - $0.0 > 0.45 }
        turns.removeAll { time - $0 > 0.45 }
        let next = (dx / length, dy / length)
        if let direction, direction.0 * next.0 + direction.1 * next.1 < -0.35 { turns.append(time) }
        direction = next
        if turns.count >= 3 && travel.reduce(0, { $0 + $1.1 }) >= 180 { triggered = time; turns.removeAll(); travel.removeAll() }
    }
    public func scale(at time: Double) -> Double {
        let elapsed = time - triggered
        guard elapsed >= 0, elapsed < 0.65 else { return 1 }
        if elapsed < 0.08 { return 1 + elapsed / 0.08 }
        if elapsed > 0.4 { return 1 + (0.65 - elapsed) / 0.25 }
        return 2
    }
    public func nextDeadline(at time: Double) -> Double? {
        time - triggered < 0.65 ? time + 1.0 / 30 : nil
    }
}
