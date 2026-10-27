import Foundation

/// Pure state machine. The app supplies a monotonic clock; delayed timers never
/// keep a cursor pressed after mouse-up or steal a release from a newer click.
public struct InteractionMachine {
    public private(set) var motion: Motion = .normal
    public private(set) var buttonDown = false
    public private(set) var lastActivity: Double
    private var deadline: Double?
    public init(now: Double) { lastActivity = now }
    public mutating func reset(now: Double) {
        motion = .normal; buttonDown = false; deadline = nil; lastActivity = now
    }
    public mutating func activity(now: Double) {
        lastActivity = now
        if motion == .idle { motion = .normal; deadline = nil }
    }
    public mutating func down(now: Double, pressDuration: Double?, enabled: Bool) {
        lastActivity = now; buttonDown = true; deadline = nil
        guard enabled else { motion = .normal; return }
        motion = pressDuration == nil ? .hold : .press
        if let duration = pressDuration { deadline = now + duration }
    }
    public mutating func up(now: Double, releaseDuration: Double?, enabled: Bool) {
        lastActivity = now
        guard buttonDown else { return }
        buttonDown = false; deadline = nil
        if enabled, let duration = releaseDuration {
            motion = .release; deadline = now + duration
        } else { motion = .normal }
    }
    public mutating func tick(now: Double, idleDelay: Double, idleEnabled: Bool) {
        if let deadline, now >= deadline {
            self.deadline = nil
            motion = buttonDown ? .hold : .normal
        }
        if !buttonDown, motion == .normal, idleEnabled, now - lastActivity >= idleDelay {
            motion = .idle
        }
    }
}
