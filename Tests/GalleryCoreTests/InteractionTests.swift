import GalleryCore

final class InteractionTests {
    func testReleaseInterruptsPressAndExpires() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 1, enabled: true)
        expectEqual(m.motion, .press)
        m.up(now: 1.1, releaseDuration: 0.3, enabled: true)
        expectEqual(m.motion, .release)
        m.tick(now: 1.41, idleDelay: 8, idleEnabled: true)
        expectEqual(m.motion, .normal)
        expectFalse(m.buttonDown)
    }
    func testNewClickReplacesOldReleaseDeadline() {
        var m = InteractionMachine(now: 0)
        m.down(now: 0, pressDuration: 0.2, enabled: true)
        m.up(now: 0.1, releaseDuration: 0.8, enabled: true)
        m.down(now: 0.2, pressDuration: 0.3, enabled: true)
        m.tick(now: 0.51, idleDelay: 2, idleEnabled: true)
        expectEqual(m.motion, .hold)
        m.tick(now: 1, idleDelay: 2, idleEnabled: true)
        expectEqual(m.motion, .hold)
    }
    func testIdleIsCancelledByActivityAndNeverStartsWhileHeld() {
        var m = InteractionMachine(now: 0)
        m.tick(now: 5, idleDelay: 5, idleEnabled: true)
        expectEqual(m.motion, .idle)
        m.activity(now: 5.1)
        expectEqual(m.motion, .normal)
        m.down(now: 6, pressDuration: nil, enabled: true)
        m.tick(now: 60, idleDelay: 5, idleEnabled: true)
        expectEqual(m.motion, .hold)
        m.reset(now: 61)
        expectEqual(m.motion, .normal)
        expectFalse(m.buttonDown)
    }
    func testDisabledFeaturesDoNotEnterAnimationStates() {
        var m = InteractionMachine(now: 0)
        m.down(now: 1, pressDuration: 1, enabled: false)
        m.up(now: 2, releaseDuration: 1, enabled: false)
        m.tick(now: 100, idleDelay: 5, idleEnabled: false)
        expectEqual(m.motion, .normal)
    }
}
