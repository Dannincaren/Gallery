import Foundation

/// One-shot scheduling: idle static pointers need a watchdog, not 120 wakeups
/// per second. Actual input still requests an immediate frame.
public enum PointerSchedule {
    public static func delay(now: Double, polling: Bool, paused: Bool,
                             frameDeadline: Double?, transitionDeadline: Double?, idleDeadline: Double?) -> Double {
        if paused { return 1 }
        var delay = polling ? 1.0 / 120 : 0.2
        // Avoid allocating an array and compactMap result for each input or
        // frame. The deadline comparisons and polling intervals are unchanged.
        if let deadline = frameDeadline, deadline > now { delay = min(delay, max(0.001, deadline - now)) }
        if let deadline = transitionDeadline, deadline > now { delay = min(delay, max(0.001, deadline - now)) }
        if let deadline = idleDeadline, deadline > now { delay = min(delay, max(0.001, deadline - now)) }
        return max(0.001, delay)
    }
}
