import Foundation

/// One-shot scheduling: idle static pointers need a watchdog, not 120 wakeups
/// per second. Actual input still requests an immediate frame.
public enum PointerSchedule {
    public static func delay(now: Double, polling: Bool, paused: Bool,
                             frameDeadline: Double?, transitionDeadline: Double?, idleDeadline: Double?) -> Double {
        if paused { return 1 }
        var delay = polling ? 1.0 / 120 : 0.2
        for deadline in [frameDeadline, transitionDeadline, idleDeadline].compactMap({ $0 }) where deadline > now {
            delay = min(delay, max(0.001, deadline - now))
        }
        return max(0.001, delay)
    }
}
