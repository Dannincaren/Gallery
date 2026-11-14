/// Keeps each role's click timeline separate from the physical button ledger.
/// Inactive roles advance by elapsed time on return, without background timers.
public struct RoleInteractionMachine {
    private var active: InteractionMachine
    private var role: String?
    private var inactive: [String: InteractionMachine] = [:]
    private var gestureRole: String?
    private var releaseDuration: Double?
    public private(set) var buttonDown = false
    public var motion: Motion { active.motion }
    public var motionStartedAt: Double { active.motionStartedAt }
    public var lastActivity: Double { active.lastActivity }
    public var transitionDeadline: Double? { active.transitionDeadline }

    public init(now: Double) { active = InteractionMachine(now: now) }

    /// The caller supplies canonical role IDs, so alias-only changes are a no-op.
    public mutating func selectRole(_ selected: String?, now: Double) {
        guard selected != role else { return }
        if let role { inactive[role] = active }
        role = selected
        active = selected.flatMap { inactive.removeValue(forKey: $0) } ?? InteractionMachine(now: now)
        active.activity(now: now)
        active.tick(now: now, idleDelay: 0, idleEnabled: false)
        if active.motion == .normal, !active.buttonDown { active.reset(now: now) }
    }

    public mutating func reset(now: Double) {
        active.reset(now: now)
        inactive.removeAll(keepingCapacity: true)
        gestureRole = nil; releaseDuration = nil; buttonDown = false
    }

    public mutating func activity(now: Double) { active.activity(now: now) }

    public mutating func down(now: Double, pressDuration: Double?, enabled: Bool, split: Bool = true, releaseDuration: Double? = nil) {
        guard !buttonDown else { return }
        buttonDown = true; gestureRole = role; self.releaseDuration = releaseDuration
        active.down(now: now, pressDuration: pressDuration, enabled: enabled, split: split, releaseDuration: releaseDuration)
    }

    public mutating func up(now: Double, enabled: Bool) {
        guard buttonDown else { return }
        buttonDown = false
        // A mouse-up belongs to the role that accepted the mouse-down, even
        // when the application changes its cursor during a drag or focus change.
        if gestureRole == role {
            active.up(now: now, releaseDuration: releaseDuration, enabled: enabled)
        } else if let owner = gestureRole, var state = inactive[owner] {
            state.up(now: now, releaseDuration: releaseDuration, enabled: enabled)
            inactive[owner] = state
        }
        active.activity(now: now)
        gestureRole = nil; releaseDuration = nil
    }

    public mutating func tick(now: Double, idleDelay: Double, idleEnabled: Bool) {
        active.tick(now: now, idleDelay: idleDelay, idleEnabled: idleEnabled && !buttonDown)
    }
}
