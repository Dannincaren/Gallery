import Foundation

/// Pure state machine. The app supplies a monotonic clock; delayed timers never
/// keep a cursor pressed after mouse-up or steal a release from a newer click.
public struct InteractionMachine {
    public private(set) var motion: Motion = .normal
    public private(set) var buttonDown = false
    public private(set) var lastActivity: Double
    public private(set) var motionStartedAt: Double
    public var transitionDeadline: Double? { deadline }
    private var deadline: Double?
    private var splitClick = true
    private var automaticRelease: Double?
    public init(now: Double) { lastActivity = now; motionStartedAt = now }
    public mutating func reset(now: Double) {
        motion = .normal; buttonDown = false; deadline = nil; automaticRelease = nil; lastActivity = now; motionStartedAt = now
    }
    public mutating func activity(now: Double) {
        lastActivity = max(lastActivity, now)
        if motion == .idle { motion = .normal; deadline = nil; motionStartedAt = now }
    }
    public mutating func down(now: Double, pressDuration: Double?, enabled: Bool, split: Bool = true, releaseDuration: Double? = nil) {
        lastActivity = max(lastActivity, now); buttonDown = true; deadline = nil; motionStartedAt = now
        splitClick = split
        automaticRelease = split ? nil : releaseDuration
        guard enabled else { motion = .normal; return }
        motion = pressDuration == nil ? (split ? .hold : .normal) : .press
        if let duration = pressDuration { deadline = now + duration }
        else if !split, let duration = automaticRelease { motion = .release; deadline = now + duration; automaticRelease = nil }
    }
    public mutating func up(now: Double, releaseDuration: Double?, enabled: Bool) {
        lastActivity = max(lastActivity, now)
        guard buttonDown else { return }
        buttonDown = false
        if !splitClick { return }
        deadline = nil
        motionStartedAt = now
        if enabled, let duration = releaseDuration {
            motion = .release; deadline = now + duration
        } else { motion = .normal }
    }
    public mutating func tick(now: Double, idleDelay: Double, idleEnabled: Bool) {
        while let deadline, now >= deadline {
            if !splitClick, motion == .press, let duration = automaticRelease {
                motion = .release; motionStartedAt = deadline; self.deadline = deadline + duration; automaticRelease = nil
            } else {
                self.deadline = nil
                motion = buttonDown && splitClick ? .hold : .normal; motionStartedAt = deadline
            }
        }
        if !buttonDown, motion == .normal, idleEnabled, now - lastActivity >= idleDelay {
            motion = .idle; motionStartedAt = lastActivity + idleDelay
        }
    }
}
