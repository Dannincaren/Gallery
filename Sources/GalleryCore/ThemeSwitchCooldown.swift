import Foundation

/// Monotonic time, no repeating timer. Internal recovery and quitting bypass
/// this user-action gate so cursor restoration is never delayed.
public struct ThemeSwitchCooldown {
    public enum Action { case activate, deactivate }
    public private(set) var deadline = -Double.infinity
    public init() {}
    public func permits(at time: Double) -> Bool { time >= deadline }
    @discardableResult public mutating func begin(_ action: Action, at time: Double) -> Bool {
        guard time.isFinite, permits(at: time) else { return false }
        deadline = time + (action == .activate ? 4 : 1); return true
    }
}
